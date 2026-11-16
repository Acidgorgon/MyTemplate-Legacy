--!strict
--!native
--!optimize 2
--[[
	Anchor Codec: schemaless binary encoding of DataStore-acceptable Luau
	values into a `buffer`. Pure Luau; uses only the built-in `buffer`, `utf8`,
	`table`, `string` and `math` libraries, so it runs in a plain Luau VM.

	API
		Codec.encode(value, rootName?) -> buffer      errors with a path on invalid input
		Codec.decode(buf) -> any                       errors on malformed input
		Codec.decodeInto(buf, target)                  root must be a table; decodes fully
		                                               first, then clears `target` (raw) and
		                                               refills it, keeping its identity
		Codec.validate(value, rootName?) -> (ok, path?, reason?)
		Codec.equal(a, b) -> boolean                   deep; buffers by content; -0 ~= 0
		Codec.VERSION, Codec.MAX_DEPTH

	`rootName` (default "Data") is the first segment of reported paths,
	e.g. `Data.Owned.i42.Level`, `Data.Inventory[3]`, `Data["odd key"]`.

	What is accepted (mirrors what Roblox DataStores store without loss):
		boolean, finite numbers, valid UTF-8 strings, buffers, and tables that are
		either a contiguous 1..n array or a map with only string keys.
	Rejected (with path + reason):
		nil / NaN / +-inf / functions / userdata / vectors / threads; invalid
		UTF-8 strings (DataStores refuse them); tables mixing array items and
		string keys; integer keys that do not form a contiguous 1..n array
		(sparse arrays, key 0, negative keys; JSON would turn them into string
		keys or drop them); non-integer number keys and keys of other types;
		cycles; nesting deeper than MAX_DEPTH (root table = depth 1).
	Tables are read raw (`next`, `rawlen`, `rawget`): metatables are neither
	invoked nor stored. A table referenced twice (not a cycle) is encoded twice,
	like JSON.

	Wire format (version 1, all multi-byte numbers little-endian):
		header  "ANC" <version u8 = 1> <flags u8 = 0>; then one value; no trailing bytes.
		varint  unsigned LEB128, at most 8 bytes, value < 2^53, canonical (no
		        trailing zero byte).
		value tags:
			0x01 false            0x02 true
			0x03 INT  zigzag varint (integers with |x| < 2^52)
			0x04 F64  8 bytes     0x05 F32 4 bytes (used when the f32 is exact)
			0x06 STR  varint len, bytes   (new string, appended to string table)
			0x07 REF  varint index        (string table back-reference)
			0x08 ARR  varint n, n values
			0x09 MAP  varint n, n x (key, value)
			0x0A BUF  varint len, bytes
			0x11..0x16 DEC zigzag varint m; value = m / 10^s with s = tag - 0x10
			           (short decimals such as 73.4 or 1.99; only emitted when
			           that division reproduces the exact double)
			0x20..0x3F STR with len 0..31 inline
			0x40..0x5F REF with index 0..31 inline
			0x60..0x6F ARR with n 0..15 inline
			0x70..0x7F MAP with n 0..15 inline
			0x80..0xFF integer 0..127 inline
			anything else is malformed.
		map key: varint k; k even -> REF index k/2; k odd -> new string, length
		         (k-1)/2, bytes follow, appended to string table.
		Every string (keys and values) is interned: the string table is built in
		stream order by both sides, so no table is stored up front.
		Integers with 2^52 <= |x| (and -0) are stored as floats; -0 round trips
		as -0 (F32 with the sign bit). The empty table is ARR 0 and decodes to {}.
	The decoder bounds-checks every read, rejects unknown versions/flags/tags,
	non-canonical or oversized varints, counts larger than the remaining bytes,
	NaN/inf, invalid UTF-8, duplicate map keys, depth > MAX_DEPTH and trailing
	bytes. It errors rather than return partial data.

	Encoding is deterministic for a given table state (iteration order of
	`next`), not canonical across equal tables built in different orders: equal
	bytes imply equal data, not the converse.
]]

local Codec = {}

Codec.VERSION = 1
Codec.MAX_DEPTH = 200

local VERSION = 1
local MAX_DEPTH = 200
local DEFAULT_ROOT = "Data"

local INT_LIMIT = 2 ^ 52 -- zigzag(x) < 2^53 stays exact in a double
local VARINT_LIMIT = 2 ^ 53
local INF = math.huge

local T_FALSE = 0x01
local T_TRUE = 0x02
local T_INT = 0x03
local T_F64 = 0x04
local T_F32 = 0x05
local T_STR = 0x06
local T_REF = 0x07
local T_ARR = 0x08
local T_MAP = 0x09
local T_BUF = 0x0A
local T_DEC0 = 0x10 -- 0x11..0x16: DEC with scale 1..6
local POW10 = { 10, 100, 1000, 10000, 100000, 1000000 } -- exact doubles
local T_STR0 = 0x20
local T_REF0 = 0x40
local T_ARR0 = 0x60
local T_MAP0 = 0x70
local T_FIX0 = 0x80

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local writef32 = buffer.writef32
local readf32 = buffer.readf32
local writef64 = buffer.writef64
local readf64 = buffer.readf64
local writestring = buffer.writestring
local readstring = buffer.readstring
local bufcopy = buffer.copy
local buflen = buffer.len
local bufcreate = buffer.create
local utf8len = utf8.len
local tclear = table.clear

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------

local function keySegment(k: any): string
	if type(k) == "string" then
		if string.find(k, "^[%a_][%w_]*$") then
			return "." .. k
		end
		local pattern = if utf8len(k) then '[%c"\\]' else '[%c"\\\128-\255]'
		local quoted = string.gsub(k, pattern, function(c: string): string
			return "\\" .. string.byte(c)
		end)
		return '["' .. quoted .. '"]'
	elseif type(k) == "number" then
		return "[" .. tostring(k) .. "]"
	elseif type(k) == "boolean" then
		return "[" .. tostring(k) .. "]"
	else
		return "[<" .. type(k) .. ">]"
	end
end

local function formatPath(root: string, keys: { any }, n: number): string
	local parts = table.create(n + 1)
	parts[1] = root
	for i = 1, n do
		parts[i + 1] = keySegment(keys[i])
	end
	return table.concat(parts)
end

---------------------------------------------------------------------------
-- Encoder state (module-level, reset on every call; encode never yields and
-- never runs user code, so it cannot be re-entered)
---------------------------------------------------------------------------

local SCRATCH_KEEP = 256 * 1024 -- keep the scratch buffer if it stays below this

local out: buffer = bufcreate(4096)
local cap = 4096
local pos = 0
local intern: { [string]: number } = {}
local nintern = 0
local pathKeys: { any } = {}
local tableStack: { any } = {}
local rootName = DEFAULT_ROOT
local f32probe = bufcreate(4)

-- error sentinel so encode/validate can tell our errors from VM errors
local ENCODE_ERROR = table.freeze({ "Codec.encode error sentinel" })
local errPath = ""
local errReason = ""

local function fail(reason: string, depth: number): never
	errPath = formatPath(rootName, pathKeys, depth)
	errReason = reason
	error(ENCODE_ERROR, 0)
end

local function grow(need: number)
	local newCap = cap * 2
	while newCap < pos + need do
		newCap *= 2
	end
	local nb = bufcreate(newCap)
	bufcopy(nb, 0, out, 0, pos)
	out = nb
	cap = newCap
end

local function writeVarint(v: number)
	-- caller guarantees 0 <= v < 2^53 integer and 8 bytes of room
	while v >= 128 do
		writeu8(out, pos, v % 128 + 128)
		pos += 1
		v = v // 128
	end
	writeu8(out, pos, v)
	pos += 1
end

local function varintSize(v: number): number
	local n = 1
	while v >= 128 do
		v = v // 128
		n += 1
	end
	return n
end

local function writeNumber(x: number, depth: number)
	if x // 1 == x then -- integer or +-inf (NaN fails this)
		if x >= 0 then
			if x < 128 then
				if x == 0 and 1 / x < 0 then -- -0
					writeu8(out, pos, T_F32)
					writef32(out, pos + 1, x)
					pos += 5
					return
				end
				writeu8(out, pos, T_FIX0 + x)
				pos += 1
				return
			elseif x < INT_LIMIT then
				writeu8(out, pos, T_INT)
				pos += 1
				writeVarint(x * 2)
				return
			elseif x == INF then
				fail("number is +inf (DataStores reject inf)", depth)
			end
		else
			if x > -INT_LIMIT then
				writeu8(out, pos, T_INT)
				pos += 1
				writeVarint(-x * 2 - 1)
				return
			elseif x == -INF then
				fail("number is -inf (DataStores reject inf)", depth)
			end
		end
		writeu8(out, pos, T_F64)
		writef64(out, pos + 1, x)
		pos += 9
		return
	elseif x ~= x then
		fail("number is NaN (DataStores reject NaN)", depth)
	end
	-- finite non-integer: try a short decimal m / 10^s (s = 1..6). The check
	-- uses the exact expression the decoder evaluates (IEEE division is
	-- correctly rounded everywhere), so the decoded double is bit-identical.
	local decZ = -1
	local decScale = 0
	for s = 1, 6 do
		local p = POW10[s]
		local m = math.round(x * p)
		if m / p == x then
			if m < INT_LIMIT and m > -INT_LIMIT then
				decZ = if m >= 0 then m * 2 else -m * 2 - 1
				decScale = s
			end
			break
		end
	end
	local decSize = if decZ >= 0 then 1 + varintSize(decZ) else 99
	if decSize <= 5 then
		writeu8(out, pos, T_DEC0 + decScale)
		pos += 1
		writeVarint(decZ)
		return
	end
	writef32(f32probe, 0, x)
	if readf32(f32probe, 0) == x then
		writeu8(out, pos, T_F32)
		writef32(out, pos + 1, x)
		pos += 5
	elseif decSize < 9 then
		writeu8(out, pos, T_DEC0 + decScale)
		pos += 1
		writeVarint(decZ)
	else
		writeu8(out, pos, T_F64)
		writef64(out, pos + 1, x)
		pos += 9
	end
end

-- returns the string table index if already interned, else interns it,
-- validates it and returns nil
local function newString(s: string, depth: number): number?
	local idx = intern[s]
	if idx ~= nil then
		return idx
	end
	if utf8len(s) == nil then
		fail("string is not valid UTF-8 (DataStores reject it)", depth)
	end
	intern[s] = nintern
	nintern += 1
	return nil
end

local function writeStringValue(s: string, depth: number)
	local idx = newString(s, depth)
	if idx ~= nil then
		if idx < 32 then
			writeu8(out, pos, T_REF0 + idx)
			pos += 1
		else
			writeu8(out, pos, T_REF)
			pos += 1
			writeVarint(idx)
		end
		return
	end
	local len = #s
	if pos + len + 9 > cap then
		grow(len + 9)
	end
	if len < 32 then
		writeu8(out, pos, T_STR0 + len)
		pos += 1
	else
		writeu8(out, pos, T_STR)
		pos += 1
		writeVarint(len)
	end
	writestring(out, pos, s)
	pos += len
end

local function writeKey(s: string, depth: number)
	local idx = newString(s, depth)
	if idx ~= nil then
		writeVarint(idx * 2)
		return
	end
	local len = #s
	if pos + len + 9 > cap then
		grow(len + 9)
	end
	writeVarint(len * 2 + 1)
	writestring(out, pos, s)
	pos += len
end

-- Slow path: explain why table `t` (at depth `depth`, path keys 1..depth-1)
-- is not a valid array or string-keyed map. Never returns.
local function explainTable(t: { [any]: any }, depth: number): never
	local n = rawlen(t)
	local strCount, intCount = 0, 0
	local firstInt: number? = nil
	local maxInt = 0
	for k in next, t do
		local kt = type(k)
		if kt == "string" then
			strCount += 1
		elseif kt == "number" then
			if k // 1 ~= k or k ~= k or k == INF or k == -INF then
				pathKeys[depth] = k
				fail("non-integer number key (DataStores only accept string keys or 1..n arrays)", depth)
			elseif k < 1 then
				pathKeys[depth] = k
				fail("integer key " .. tostring(k) .. " is not part of a 1..n array (use string keys)", depth)
			end
			intCount += 1
			if firstInt == nil then
				firstInt = k
			end
			if k > maxInt then
				maxInt = k
			end
		else
			pathKeys[depth] = k
			fail("key of type " .. kt .. " (only string keys or 1..n arrays can be stored)", depth)
		end
	end
	if strCount > 0 and intCount > 0 then
		fail(
			string.format(
				"mixed table: has %d string keys and %d integer keys (e.g. [%s]); DataStores mangle these, use one or the other",
				strCount,
				intCount,
				tostring(firstInt)
			),
			depth - 1
		)
	end
	if intCount > 0 then
		local hole = 1
		while rawget(t, hole) ~= nil do
			hole += 1
		end
		fail(
			string.format(
				"sparse array: %d integer keys up to %d but index %d is nil (only contiguous 1..n arrays can be stored; use string keys)",
				intCount,
				maxInt,
				hole
			),
			depth - 1
		)
	end
	error("Codec: internal error classifying table (n=" .. n .. ")")
end

local encodeValue: (v: any, depth: number) -> ()

local function encodeTable(t: { [any]: any }, depth: number)
	-- `depth` is this table's depth (root = 1); its own path is keys 1..depth-1
	if depth > MAX_DEPTH then
		for i = 1, depth - 1 do
			for j = i + 1, depth - 1 do
				if rawequal(tableStack[i], tableStack[j]) then
					fail(
						"cycle: table refers back to its ancestor " .. formatPath(rootName, pathKeys, i - 1),
						j - 1
					)
				end
			end
		end
		fail("nesting deeper than " .. MAX_DEPTH .. " levels", depth - 1)
	end
	tableStack[depth] = t
	local n = rawlen(t)
	if n > 0 then
		local count = 0
		for _ in next, t do
			count += 1
		end
		if count ~= n then
			explainTable(t, depth)
		end
		if pos + 9 > cap then
			grow(9)
		end
		if n < 16 then
			writeu8(out, pos, T_ARR0 + n)
			pos += 1
		else
			writeu8(out, pos, T_ARR)
			pos += 1
			writeVarint(n)
		end
		for i = 1, n do
			local v = rawget(t, i)
			if v == nil then
				explainTable(t, depth)
			end
			pathKeys[depth] = i
			encodeValue(v, depth)
		end
		tableStack[depth] = nil
		return
	end
	if next(t) == nil then
		if pos + 1 > cap then
			grow(1)
		end
		writeu8(out, pos, T_ARR0)
		pos += 1
		tableStack[depth] = nil
		return
	end
	-- map: one pass, header patched afterwards
	if pos + 1 > cap then
		grow(1)
	end
	local headerPos = pos
	pos += 1
	local count = 0
	for k, v in next, t do
		if type(k) ~= "string" then
			explainTable(t, depth)
		end
		if pos + 9 > cap then
			grow(9)
		end
		pathKeys[depth] = k
		writeKey(k, depth)
		encodeValue(v, depth)
		count += 1
	end
	if count < 16 then
		writeu8(out, headerPos, T_MAP0 + count)
	else
		local shift = varintSize(count)
		if pos + shift > cap then
			grow(shift)
		end
		bufcopy(out, headerPos + 1 + shift, out, headerPos + 1, pos - headerPos - 1)
		local endPos = pos + shift
		pos = headerPos
		writeu8(out, pos, T_MAP)
		pos += 1
		writeVarint(count)
		pos = endPos
	end
	tableStack[depth] = nil
end

encodeValue = function(v: any, depth: number)
	-- `depth` is the depth of the containing table (0 at the root); the
	-- value's path is keys 1..depth
	if pos + 9 > cap then
		grow(9)
	end
	local t = type(v)
	if t == "number" then
		writeNumber(v, depth)
	elseif t == "string" then
		writeStringValue(v, depth)
	elseif t == "table" then
		encodeTable(v, depth + 1)
	elseif t == "boolean" then
		writeu8(out, pos, if v then T_TRUE else T_FALSE)
		pos += 1
	elseif t == "buffer" then
		local len = buflen(v)
		if pos + len + 9 > cap then
			grow(len + 9)
		end
		writeu8(out, pos, T_BUF)
		pos += 1
		writeVarint(len)
		bufcopy(out, pos, v, 0, len)
		pos += len
	elseif t == "nil" then
		fail("value is nil", depth)
	else
		fail("cannot store a value of type '" .. t .. "'", depth)
	end
end

local function resetEncoder(name: string?)
	rootName = name or DEFAULT_ROOT
	pos = 0
	tclear(intern)
	nintern = 0
	tclear(tableStack)
end

local function finishEncoder()
	tclear(intern)
	tclear(tableStack)
	tclear(pathKeys)
	if cap > SCRATCH_KEEP then
		out = bufcreate(4096)
		cap = 4096
	end
end

local function runEncode(value: any)
	writeu8(out, 0, 0x41) -- A
	writeu8(out, 1, 0x4E) -- N
	writeu8(out, 2, 0x43) -- C
	writeu8(out, 3, VERSION)
	writeu8(out, 4, 0) -- flags
	pos = 5
	encodeValue(value, 0)
end

function Codec.encode(value: any, name: string?): buffer
	resetEncoder(name)
	local ok, err = pcall(runEncode, value)
	if not ok then
		finishEncoder()
		if err == ENCODE_ERROR then
			error("Codec.encode: " .. errReason .. " at " .. errPath, 2)
		end
		error(err, 0)
	end
	local result = bufcreate(pos)
	bufcopy(result, 0, out, 0, pos)
	finishEncoder()
	return result
end

function Codec.validate(value: any, name: string?): (boolean, string?, string?)
	resetEncoder(name)
	local ok, err = pcall(runEncode, value)
	finishEncoder()
	if ok then
		return true, nil, nil
	elseif err == ENCODE_ERROR then
		return false, errPath, errReason
	end
	return false, name or DEFAULT_ROOT, tostring(err)
end

---------------------------------------------------------------------------
-- Decoder
---------------------------------------------------------------------------

local EMPTY = bufcreate(0)
local rbuf: buffer = EMPTY
local rpos = 0
local rend = 0
local strs: { string } = {}
local nstrs = 0

local function dfail(reason: string): never
	error("Codec.decode: malformed input: " .. reason .. " (at byte " .. rpos .. ")", 0)
end

local function readVarint(): number
	if rpos >= rend then
		dfail("unexpected end of data in varint")
	end
	local b = readu8(rbuf, rpos)
	rpos += 1
	if b < 128 then
		return b
	end
	local result = b - 128
	local mult = 128
	for _ = 2, 8 do
		if rpos >= rend then
			dfail("unexpected end of data in varint")
		end
		b = readu8(rbuf, rpos)
		rpos += 1
		if b < 128 then
			if b == 0 then
				dfail("non-canonical varint")
			end
			result += b * mult
			if result >= VARINT_LIMIT then
				dfail("varint out of range")
			end
			return result
		end
		result += (b - 128) * mult
		mult *= 128
	end
	dfail("varint longer than 8 bytes")
end

local function readNewString(len: number): string
	if len > rend - rpos then
		dfail("string length " .. len .. " exceeds remaining data")
	end
	local s = readstring(rbuf, rpos, len)
	rpos += len
	if utf8len(s) == nil then
		dfail("string is not valid UTF-8")
	end
	nstrs += 1
	strs[nstrs] = s
	return s
end

local function readRef(idx: number): string
	if idx >= nstrs then
		dfail("string reference " .. idx .. " out of range")
	end
	return strs[idx + 1]
end

local function readFloat(width: number): number
	if rpos + width > rend then
		dfail("unexpected end of data in float")
	end
	local x = if width == 4 then readf32(rbuf, rpos) else readf64(rbuf, rpos)
	rpos += width
	if x ~= x or x == INF or x == -INF then
		dfail("non-finite number")
	end
	return x
end

local decodeValue: (depth: number) -> any

local function decodeArray(n: number, depth: number): { any }
	if depth > MAX_DEPTH then
		dfail("nesting deeper than " .. MAX_DEPTH)
	end
	if n > rend - rpos then
		dfail("array count " .. n .. " exceeds remaining data")
	end
	local t = table.create(n)
	for i = 1, n do
		t[i] = decodeValue(depth)
	end
	return t
end

local function decodeMap(n: number, depth: number): { [string]: any }
	if depth > MAX_DEPTH then
		dfail("nesting deeper than " .. MAX_DEPTH)
	end
	if n * 2 > rend - rpos then
		dfail("map count " .. n .. " exceeds remaining data")
	end
	local t = {}
	local b = rbuf
	for _ = 1, n do
		local key: string
		-- fast path: one-byte key reference (string table index < 64)
		local k = if rpos < rend then readu8(b, rpos) else 255
		if k < 128 and k % 2 == 0 and k // 2 < nstrs then
			rpos += 1
			key = strs[k // 2 + 1]
		else
			k = readVarint()
			if k % 2 == 0 then
				key = readRef(k // 2)
			else
				key = readNewString((k - 1) // 2)
			end
		end
		if t[key] ~= nil then
			dfail("duplicate map key")
		end
		t[key] = decodeValue(depth)
	end
	return t
end

decodeValue = function(depth: number): any
	-- `depth` is the depth of the containing table (0 at root)
	if rpos >= rend then
		dfail("unexpected end of data")
	end
	local tag = readu8(rbuf, rpos)
	rpos += 1
	if tag >= T_FIX0 then
		return tag - T_FIX0
	elseif tag >= T_ARR0 then
		if tag >= T_MAP0 then
			return decodeMap(tag - T_MAP0, depth + 1)
		end
		return decodeArray(tag - T_ARR0, depth + 1)
	elseif tag >= T_REF0 then
		return readRef(tag - T_REF0)
	elseif tag >= T_STR0 then
		return readNewString(tag - T_STR0)
	elseif tag == T_FALSE then
		return false
	elseif tag == T_TRUE then
		return true
	elseif tag == T_INT then
		local z = readVarint()
		if z % 2 == 0 then
			return z / 2
		end
		return -(z + 1) / 2
	elseif tag == T_F32 then
		return readFloat(4)
	elseif tag == T_F64 then
		return readFloat(8)
	elseif tag == T_STR then
		return readNewString(readVarint())
	elseif tag == T_REF then
		return readRef(readVarint())
	elseif tag == T_ARR then
		return decodeArray(readVarint(), depth + 1)
	elseif tag == T_MAP then
		return decodeMap(readVarint(), depth + 1)
	elseif tag > T_DEC0 and tag <= T_DEC0 + 6 then
		local z = readVarint()
		local m = if z % 2 == 0 then z / 2 else -(z + 1) / 2
		return m / POW10[tag - T_DEC0]
	elseif tag == T_BUF then
		local len = readVarint()
		if len > rend - rpos then
			dfail("buffer length " .. len .. " exceeds remaining data")
		end
		local b = bufcreate(len)
		bufcopy(b, 0, rbuf, rpos, len)
		rpos += len
		return b
	end
	rpos -= 1
	dfail(string.format("unknown tag 0x%02X", tag))
end

local function runDecode(buf: buffer): any
	local len = buflen(buf)
	rbuf = buf
	rpos = 0
	rend = len
	tclear(strs)
	nstrs = 0
	if len < 5 or readu8(buf, 0) ~= 0x41 or readu8(buf, 1) ~= 0x4E or readu8(buf, 2) ~= 0x43 then
		dfail("missing ANC header")
	end
	local version = readu8(buf, 3)
	if version ~= VERSION then
		rpos = 3
		dfail("unsupported codec version " .. version .. " (this build reads version " .. VERSION .. ")")
	end
	local flags = readu8(buf, 4)
	if flags ~= 0 then
		rpos = 4
		dfail(string.format("unknown flags 0x%02X", flags))
	end
	rpos = 5
	local value = decodeValue(0)
	if rpos ~= rend then
		dfail((rend - rpos) .. " trailing bytes")
	end
	return value
end

local function releaseDecoder()
	rbuf = EMPTY
	tclear(strs)
	nstrs = 0
end

function Codec.decode(buf: buffer): any
	if type(buf) ~= "buffer" then
		error("Codec.decode: expected a buffer, got " .. type(buf), 2)
	end
	local ok, result = pcall(runDecode, buf)
	releaseDecoder()
	if not ok then
		error(result, 0)
	end
	return result
end

function Codec.decodeInto(buf: buffer, target: { [any]: any })
	if type(target) ~= "table" then
		error("Codec.decodeInto: target must be a table, got " .. type(target), 2)
	end
	if table.isfrozen(target) then
		error("Codec.decodeInto: target table is frozen", 2)
	end
	-- decode fully before touching target: a malformed blob leaves it intact
	local value = Codec.decode(buf)
	if type(value) ~= "table" then
		error("Codec.decodeInto: encoded root is a " .. type(value) .. ", not a table", 2)
	end
	tclear(target)
	for k, v in next, value do
		rawset(target, k, v)
	end
end

---------------------------------------------------------------------------
-- Deep equality
---------------------------------------------------------------------------

local function buffersEqual(a: buffer, b: buffer): boolean
	local n = buflen(a)
	if n ~= buflen(b) then
		return false
	end
	local i = 0
	while i + 4 <= n do
		if buffer.readu32(a, i) ~= buffer.readu32(b, i) then
			return false
		end
		i += 4
	end
	while i < n do
		if readu8(a, i) ~= readu8(b, i) then
			return false
		end
		i += 1
	end
	return true
end

local function deepEqual(a: any, b: any, depth: number): boolean
	local ta = type(a)
	if ta ~= type(b) then
		return false
	end
	if ta == "number" then
		if a ~= b then
			return false
		end
		return a ~= 0 or (1 / a == 1 / b) -- distinguishes 0 and -0
	elseif ta == "table" then
		if rawequal(a, b) then
			return true
		end
		if depth > MAX_DEPTH + 1 then
			return false
		end
		local count = 0
		for k, va in next, a do
			local vb = rawget(b, k)
			if vb == nil or not deepEqual(va, vb, depth + 1) then
				return false
			end
			count += 1
		end
		for _ in next, b do
			count -= 1
			if count < 0 then
				return false
			end
		end
		return count == 0
	elseif ta == "buffer" then
		return rawequal(a, b) or buffersEqual(a, b)
	end
	return rawequal(a, b)
end

function Codec.equal(a: any, b: any): boolean
	return deepEqual(a, b, 1)
end

return table.freeze(Codec)
