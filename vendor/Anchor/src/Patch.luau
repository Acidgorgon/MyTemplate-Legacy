--!nonstrict
--[[
	Anchor / Patch

	Diffs a draft against the data it was copied from and applies the result as a list of
	small, re-playable operations. Used by trades, gifts, receipts and Reset.

	A patch is a JSON-acceptable array of ops (it is stored in MetaData.Anchor and sent in
	messages):
		{ "Inc",    path, delta }   numbers: t[k] = (t[k] or 0) + delta
		{ "Set",    path, value }   t[k] = deep copy of value
		{ "Remove", path }          t[k] = nil
		{ "Push",   path, value }   arrays: append a deep copy of value
		{ "Pull",   path, value }   arrays: remove the first element deep-equal to value
	path = { key1, key2, ... } from the data root.

	Why these ops: a patch can be applied again later onto newer data (a trade redo on
	another server, a gift to an offline player) without clobbering progress. Numbers are
	increments, maps are edited key by key, and arrays are treated as bags (items are
	pulled / pushed by value, never written by index, so an array that grew or shrank in
	the meantime is never left with holes). Reordering an array is not a change.

	apply(root, patch, live?, report?) -> inverse
		Applies every op to `root` (the plain profile.Data). When `live` is given (a Ripple
		state wrapping `root` in place) each write goes through it so it replicates;
		assigned tables are always fresh deep copies. A live write that errors (or does not
		reach the plain table) is redone directly on the plain table and report(message) is
		called: the data stays correct and saved, only replication of that field is missed.
		Missing parents are created; ops never fail half way.
		Returns the inverse patch (apply it to undo, newest first).
--]]

local Patch = {}

local OPS = { Inc = true, Set = true, Remove = true, Push = true, Pull = true }

----- Helpers -----

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in next, value do
		copy[k] = if type(v) == "table" then deepCopy(v) else v
	end
	return copy
end
Patch.deepCopy = deepCopy

local function deepEqual(a, b): boolean
	if a == b then
		return true
	end
	local ta = type(a)
	if ta ~= type(b) then
		return false
	end
	if ta == "buffer" then
		return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
	end
	if ta ~= "table" then
		return false
	end
	for k, v in next, a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in next, b do
		if a[k] == nil then
			return false
		end
	end
	return true
end
Patch.deepEqual = deepEqual

-- 0 = empty table, 1 = array (keys 1..n), 2 = anything else
local function tableKind(t): number
	local n = #t
	local count = 0
	for k in next, t do
		count += 1
		if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
			return 2
		end
	end
	if count == 0 then
		return 0
	end
	return if count == n then 1 else 2
end

local function appendPath(path, key)
	local p = table.clone(path)
	p[#p + 1] = key
	return p
end

----- Diff -----

local diffValue

local function diffArray(base, draft, path, out)
	local nb, nd = #base, #draft
	local usedBase = {}
	local matchedDraft = {}
	-- fast path: same position
	for i = 1, math.min(nb, nd) do
		if deepEqual(base[i], draft[i]) then
			usedBase[i] = true
			matchedDraft[i] = true
		end
	end
	-- remaining: match by value (bag semantics)
	for i = 1, nd do
		if matchedDraft[i] ~= true then
			local value = draft[i]
			for j = 1, nb do
				if usedBase[j] ~= true and deepEqual(base[j], value) then
					usedBase[j] = true
					matchedDraft[i] = true
					break
				end
			end
		end
	end
	for j = 1, nb do
		if usedBase[j] ~= true then
			table.insert(out, { "Pull", path, deepCopy(base[j]) })
		end
	end
	for i = 1, nd do
		if matchedDraft[i] ~= true then
			table.insert(out, { "Push", path, deepCopy(draft[i]) })
		end
	end
end

local function diffTable(base, draft, path, out)
	for k, bv in next, base do
		local dv = draft[k]
		if dv == nil then
			table.insert(out, { "Remove", appendPath(path, k) })
		else
			diffValue(bv, dv, appendPath(path, k), out)
		end
	end
	for k, dv in next, draft do
		if base[k] == nil then
			table.insert(out, { "Set", appendPath(path, k), deepCopy(dv) })
		end
	end
end

diffValue = function(bv, dv, path, out)
	if bv == dv then
		return
	end
	local tb, td = type(bv), type(dv)
	if tb == "number" and td == "number" then
		local delta = dv - bv
		if delta ~= 0 then
			table.insert(out, { "Inc", path, delta })
		end
	elseif tb == "table" and td == "table" then
		local kb, kd = tableKind(bv), tableKind(dv)
		if (kb == 1 and kd ~= 2) or (kd == 1 and kb ~= 2) then
			diffArray(bv, dv, path, out)
		elseif kb == 1 or kd == 1 then
			table.insert(out, { "Set", path, deepCopy(dv) }) -- array <-> map: replace
		else
			diffTable(bv, dv, path, out)
		end
	elseif tb == "buffer" and td == "buffer" and deepEqual(bv, dv) then
		return
	else
		table.insert(out, { "Set", path, deepCopy(dv) })
	end
end

-- Patch.diff(base, draft) -> patch: the ops that turn `base` into `draft`.
function Patch.diff(base, draft)
	local out = {}
	diffTable(base, draft, {}, out)
	return out
end

----- Validation -----

local function badValue(value, depth): string?
	local t = type(value)
	if t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "NaN or infinite number"
		end
	elseif t == "table" then
		if depth > 200 then
			return "table nested too deep (or cyclic)"
		end
		for k, v in next, value do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				return `table key of type {typeof(k)}`
			end
			local problem = badValue(v, depth + 1)
			if problem ~= nil then
				return problem
			end
		end
	elseif t ~= "string" and t ~= "boolean" and t ~= "buffer" then
		return `value of type {typeof(value)}`
	end
	return nil
end

-- Patch.check(patch) -> (ok, problem?) : shape and storable values.
function Patch.check(patch): (boolean, string?)
	if type(patch) ~= "table" then
		return false, "patch is not a table"
	end
	for i, op in ipairs(patch) do
		if type(op) ~= "table" or OPS[op[1]] ~= true then
			return false, `op {i}: unknown operation {tostring(type(op) == "table" and op[1] or op)}`
		end
		local path = op[2]
		if type(path) ~= "table" or #path == 0 then
			return false, `op {i}: invalid path`
		end
		for _, key in ipairs(path) do
			if type(key) ~= "string" and type(key) ~= "number" then
				return false, `op {i}: invalid path key`
			end
		end
		if op[1] == "Inc" and type(op[3]) ~= "number" then
			return false, `op {i}: Inc needs a number`
		end
		if op[1] ~= "Remove" then
			if op[1] ~= "Inc" and op[3] == nil then
				return false, `op {i}: missing value`
			end
			local problem = badValue(op[3], 0)
			if problem ~= nil then
				return false, `op {i}: {problem}`
			end
		end
	end
	if #patch ~= rawlen(patch) then
		return false, "patch is not an array"
	end
	return true, nil
end

----- Apply -----

-- One write: through the live proxy when there is one, verified, else plain.
local function write(plain, live, key, value, ctx)
	if live ~= nil then
		local ok, err = pcall(function()
			live[key] = value
		end)
		if ok then
			local now = plain[key]
			if now == value or (type(value) == "table" and deepEqual(now, value)) then
				return
			end
			err = "live write did not reach the data table"
		end
		if ctx.report ~= nil then
			ctx.report(`live write failed at {ctx.pathText}: {tostring(err)}; wrote the plain table instead`)
		end
	end
	plain[key] = value
end

local function liveChild(live, key)
	if live == nil then
		return nil
	end
	local ok, child = pcall(function()
		return live[key]
	end)
	if ok and (type(child) == "table" or type(child) == "userdata") then
		return child
	end
	return nil
end

local function pathText(path, n)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring(path[i])
	end
	return "Data." .. table.concat(parts, ".")
end

local function skip(ctx, path, n, why)
	ctx.missed += 1
	if ctx.report ~= nil then
		ctx.report(`patch op skipped at {pathText(path, n)}: {why}`)
	end
end

-- May a missing parent at path[1..i] be created? "create": yes. "template": only where
-- the template has a table at that path (a sold item never comes back as a stub).
local function mayCreate(ctx, path, i): boolean
	if ctx.parents ~= "template" then
		return true
	end
	local t = ctx.template
	for j = 1, i do
		if type(t) ~= "table" then
			return false
		end
		t = t[path[j]]
	end
	return type(t) == "table"
end

local function applyOp(root, live, op, ctx, inverse)
	local kind, path, value = op[1], op[2], op[3]
	local n = #path
	local creates = kind ~= "Remove" and kind ~= "Pull"
	-- For Push / Pull the path names the array itself.
	local last = if kind == "Push" or kind == "Pull" then n else n - 1

	local plain = root
	local created_at = nil
	for i = 1, last do
		local key = path[i]
		local child = plain[key]
		if type(child) ~= "table" then
			if not creates then
				return -- nothing to remove
			end
			if child ~= nil then
				return skip(ctx, path, i, "parent is not a table (never replaced)")
			end
			if not mayCreate(ctx, path, i) then
				return skip(ctx, path, i, "parent no longer exists")
			end
			ctx.pathText = pathText(path, i)
			if created_at == nil then
				created_at = i
				table.insert(inverse, { "Remove", table.move(path, 1, i, 1, {}) })
			end
			write(plain, live, key, {}, ctx)
			child = plain[key]
			if type(child) ~= "table" then
				child = {}
				plain[key] = child
			end
		end
		live = liveChild(live, key)
		plain = child
	end
	ctx.pathText = pathText(path, n)

	if kind == "Push" or kind == "Pull" then
		local arr = plain
		local count = #arr
		if kind == "Push" then
			write(arr, live, count + 1, deepCopy(value), ctx)
			if created_at == nil then
				table.insert(inverse, { "Pull", path, deepCopy(value) })
			end
		else
			local index = nil
			for i = 1, count do
				if deepEqual(arr[i], value) then
					index = i
					break
				end
			end
			if index == nil then
				return skip(ctx, path, n, "array item to remove is not there")
			end
			if live == nil then
				table.remove(arr, index)
			else
				for j = index, count - 1 do
					write(arr, live, j, deepCopy(arr[j + 1]), ctx)
				end
				write(arr, live, count, nil, ctx)
			end
			table.insert(inverse, { "Push", path, deepCopy(value) })
		end
		return
	end

	local key = path[n]
	local old = plain[key]
	if kind == "Inc" then
		if old ~= nil and type(old) ~= "number" then
			return skip(ctx, path, n, `Inc onto a {typeof(old)} (never replaced)`)
		end
		write(plain, live, key, (old or 0) + value, ctx)
		if created_at == nil then
			table.insert(inverse, if old == nil then { "Remove", path } else { "Inc", path, -value })
		end
	elseif kind == "Set" then
		if ctx.strict and old ~= nil then
			if deepEqual(old, value) then
				return -- already there (idempotent)
			end
			return skip(ctx, path, n, "Set onto an existing, different value (never overwritten)")
		end
		write(plain, live, key, deepCopy(value), ctx)
		if created_at == nil then
			table.insert(inverse, if old == nil then { "Remove", path } else { "Set", path, deepCopy(old) })
		end
	elseif kind == "Remove" then
		if old ~= nil then
			write(plain, live, key, nil, ctx)
			table.insert(inverse, { "Set", path, deepCopy(old) })
		end
	end
end

-- Patch.apply(root, patch, live?, report?, opts?) -> inverse_patch, skipped_ops
-- opts.Parents = "create" (default: missing parent tables are created) | "template"
-- (created only where opts.Template has a table at that path).
-- opts.Strict = true: a Set never overwrites an existing value (equal -> already applied,
-- different -> skipped and reported). Used for trade incoming / refund. An op is skipped (and
-- reported) rather than ever replacing an existing non-table value with a table, or an
-- existing non-number with an Inc.
function Patch.apply(root, patch, live, report, opts)
	local ctx = {
		report = report,
		pathText = "Data",
		missed = 0,
		parents = opts and opts.Parents or "create",
		template = opts and opts.Template,
		strict = opts ~= nil and opts.Strict == true,
	}
	local inverse = {}
	for _, op in ipairs(patch) do
		applyOp(root, live, op, ctx, inverse)
	end
	-- the inverse must run newest-first
	local reversed = table.create(#inverse)
	for i = #inverse, 1, -1 do
		reversed[#reversed + 1] = inverse[i]
	end
	return reversed, ctx.missed
end

-- Patch.conflict(root, patch) -> problem? : would apply() (create + strict mode) skip any
-- op on `root` because a value has the wrong type or a Set would overwrite a different
-- value? (Pulls of missing items are not conflicts.)
function Patch.conflict(root, patch): string?
	local scratch = deepCopy(root)
	local problem = nil
	Patch.apply(scratch, patch, nil, function(message)
		if problem == nil and not string.find(message, "array item to remove", 1, true) then
			problem = message
		end
	end, { Strict = true })
	return problem
end

local function valueAt(root, path)
	local node = root
	for _, key in ipairs(path) do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return node
end

-- Patch.split(patch, base) -> outgoing, incoming
-- outgoing: what leaves this side (Remove, Pull, negative Inc, and the old value of a Set
-- that overwrites one: Remove(path)); incoming: the rest (Set onto an empty key, Push,
-- positive Inc).
function Patch.split(patch, base)
	local outgoing, incoming = {}, {}
	for _, op in ipairs(patch) do
		local kind = op[1]
		if kind == "Remove" or kind == "Pull" or (kind == "Inc" and op[3] < 0) then
			table.insert(outgoing, op)
		elseif kind == "Set" and base ~= nil and valueAt(base, op[2]) ~= nil then
			table.insert(outgoing, { "Remove", op[2] })
			table.insert(incoming, op)
		else
			table.insert(incoming, op)
		end
	end
	return outgoing, incoming
end

-- Patch.size(value) -> approximate JSON byte length (buffers as base64).
function Patch.size(value, depth): number
	depth = depth or 0
	local t = type(value)
	if t == "string" then
		return #value + 2
	elseif t == "number" then
		return #tostring(value)
	elseif t == "boolean" then
		return 5
	elseif t == "buffer" then
		return math.ceil(buffer.len(value) / 3) * 4 + 40
	elseif t == "table" then
		if depth > 200 then
			return 0
		end
		local n = 2
		for k, v in next, value do
			n += Patch.size(v, depth + 1) + 1
			if type(k) == "string" then
				n += #k + 3
			end
		end
		return n
	end
	return 4
end

-- Patch.replace(current, target) -> patch that makes `current` deep-equal `target` with
-- plain Set / Remove ops at the top level (used by Reset).
function Patch.replace(current, target)
	local out = {}
	for k in next, current do
		if target[k] == nil then
			table.insert(out, { "Remove", { k } })
		end
	end
	for k, v in next, target do
		table.insert(out, { "Set", { k }, deepCopy(v) })
	end
	return out
end

return table.freeze(Patch)
