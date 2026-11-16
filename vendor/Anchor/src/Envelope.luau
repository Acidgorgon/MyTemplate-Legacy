--!nonstrict
--[[
	Anchor / Envelope

	Everything that knows how a profile is laid out inside the DataStore value.
	The envelope is the stock ProfileStore one, field for field:

		{ Data = {...},
		  MetaData = { ProfileCreateTime, SessionLoadCount, ActiveSession, ForceLoadSession,
		               LastUpdate, MetaTags, Anchor = {...ours} },
		  RobloxMetaData = {}, UserIds = {},
		  GlobalUpdates = { lastIndex, { {index, data}, ... } } }

	Two Data formats:
	  * Compat  : Data is the plain table (what stock writes).
	  * Compact : Data = { AnchorBlob = <Codec buffer> } AND the stock load counter is
	              poisoned: MetaData.SessionLoadCount = "Anchor" (non-numeric) with the
	              real count in MetaData.Anchor.LoadCount. Every stock session-start path
	              runs `SessionLoadCount + 1` inside its UpdateAsync transform, which throws
	              on the string, so a stock server can never claim (and later overwrite) a
	              Compact profile.

	Readers: any Data holding an AnchorBlob buffer is Compact (keys beside it, e.g. from a
	stock view-mode overwrite, are ignored and reported); a poisoned counter without a
	blob is refused, never read as plain data.

	INVARIANT: a blob in Data <=> the counter is poisoned. Both are written together
	in the same transform (writeData), so no stored version ever has one without the other.

	Readers accept both formats regardless of the writer mode. ProfileService-era
	GlobalUpdates entries ({id, version, locked, data}) are read the way stock reads
	them: index = entry[1], payload = entry[#entry].
--]]

local Codec = require(script.Parent.Codec)

local Envelope = {}

Envelope.POISON = "Anchor" -- MetaData.SessionLoadCount value of a Compact profile
Envelope.BLOB_KEY = "AnchorBlob"

----- Load counter -----

function Envelope.isPoisoned(meta: any): boolean
	return type(meta) == "table" and meta.SessionLoadCount == Envelope.POISON
end

-- Real session load count of a stored profile (number), whatever the format.
-- Returns stock's raw value for non-poisoned profiles (may be nil on malformed data,
-- exactly what stock would compare against).
function Envelope.getLoadCount(meta: any): any
	if type(meta) ~= "table" then
		return nil
	end
	local count = meta.SessionLoadCount
	if count == Envelope.POISON then
		local anchor = meta.Anchor
		if type(anchor) == "table" and type(anchor.LoadCount) == "number" then
			return anchor.LoadCount
		end
		return nil
	end
	return count
end

-- Session start: the stock `SessionLoadCount + 1`, on whichever counter is real.
-- Errors (aborting the UpdateAsync write) on malformed counters, like stock does.
function Envelope.bumpLoadCount(meta: any)
	if meta.SessionLoadCount == Envelope.POISON then
		local anchor = meta.Anchor
		if type(anchor) ~= "table" or type(anchor.LoadCount) ~= "number" then
			error("[Anchor]: Compact profile has no MetaData.Anchor.LoadCount; refusing to start a session")
		end
		anchor.LoadCount = anchor.LoadCount + 1
	else
		meta.SessionLoadCount = meta.SessionLoadCount + 1
	end
end

local function poison(meta: any): boolean
	if meta.SessionLoadCount == Envelope.POISON then
		return true
	end
	local count = meta.SessionLoadCount
	if type(count) ~= "number" then
		return false -- can't move a counter we don't understand; caller writes Compat
	end
	local anchor = meta.Anchor
	if type(anchor) ~= "table" then
		anchor = {}
		meta.Anchor = anchor
	end
	anchor.LoadCount = count
	meta.SessionLoadCount = Envelope.POISON
	return true
end

-- Compact -> Compat: put the real count back where stock looks for it.
function Envelope.unpoison(meta: any)
	if type(meta) ~= "table" or meta.SessionLoadCount ~= Envelope.POISON then
		return
	end
	local anchor = meta.Anchor
	local count = if type(anchor) == "table" then anchor.LoadCount else nil
	if type(count) ~= "number" then
		-- Corrupt poison (no real count). Leave it poisoned: stock still can't claim it,
		-- and our own readers treat the count as unknown (no ownership -> no write).
		return
	end
	meta.SessionLoadCount = count
	anchor.LoadCount = nil
	if next(anchor) == nil then
		meta.Anchor = nil
	end
end

----- Data -----

-- Any Data holding an AnchorBlob buffer is Compact, whatever sits beside it: a stock
-- view-mode overwrite (GetAsync + Reconcile/edit + SetAsync) adds template keys next to
-- the blob, and the blob is still the player's data.
function Envelope.isCompactData(data: any): boolean
	return type(data) == "table" and type(data[Envelope.BLOB_KEY]) == "buffer"
end

-- Keys stored beside the blob in a Compact Data table (sorted), or nil when there are none.
function Envelope.strayKeys(data: any): { string }?
	if type(data) ~= "table" then
		return nil
	end
	local keys = nil
	for key in next, data do
		if key ~= Envelope.BLOB_KEY then
			keys = keys or {}
			table.insert(keys, tostring(key))
		end
	end
	if keys ~= nil then
		table.sort(keys)
	end
	return keys
end

-- Reads Data out of a stored envelope.
-- Returns ok, data, blob (the stored blob when Compact), err, stray (keys stored beside
-- the blob, which are ignored; the caller reports them).
-- A Compact blob that fails to decode is an error, and so is a poisoned load counter
-- (proof the profile is Compact) with no blob: the caller must NOT treat the profile as
-- missing or as plain data (that would overwrite the player's data).
function Envelope.readData(raw: any): (boolean, any, buffer?, string?, { string }?)
	local data = raw.Data
	if Envelope.isCompactData(data) then
		local blob = data[Envelope.BLOB_KEY]
		local ok, result = pcall(Codec.decode, blob)
		if ok == false then
			return false, nil, nil, tostring(result), nil
		end
		if type(result) ~= "table" then
			return false, nil, nil, "Compact blob did not decode to a table", nil
		end
		return true, result, blob, nil, Envelope.strayKeys(data)
	end
	if Envelope.isPoisoned(raw.MetaData) then
		return false,
			nil,
			nil,
			`profile is Compact (MetaData.SessionLoadCount = "{Envelope.POISON}") but Data has no {Envelope.BLOB_KEY} buffer`,
			nil
	end
	return true, data or {}, nil, nil, nil
end

-- Writes Data into latest_data inside the UpdateAsync transform.
-- `compact` true and a (verified) blob -> Compact + poison; otherwise Compat + un-poison.
-- Returns the format actually written ("Compact" | "Compat").
function Envelope.writeData(latest_data: any, data: any, blob: buffer?, compact: boolean): string
	local meta = latest_data.MetaData
	if compact == true and blob ~= nil and type(meta) == "table" and poison(meta) then
		latest_data.Data = { [Envelope.BLOB_KEY] = blob }
		return "Compact"
	end
	latest_data.Data = data
	Envelope.unpoison(meta)
	return "Compat"
end

----- MetaData.Anchor -----

-- The owning session's copy of MetaData.Anchor (minus LoadCount) is authoritative:
-- it was loaded from the stored value at session start, so keys we don't know about
-- survive; keys removed in-session are removed. Never creates an empty Anchor table.
function Envelope.writeAnchorMeta(meta: any, mine: any)
	if type(meta) ~= "table" then
		return
	end
	local stored = meta.Anchor
	if type(stored) ~= "table" then
		if mine == nil or next(mine) == nil then
			return
		end
		stored = {}
	end
	for key in next, stored do
		if key ~= "LoadCount" and (mine == nil or mine[key] == nil) then
			stored[key] = nil
		end
	end
	if mine ~= nil then
		for key, value in next, mine do
			if key ~= "LoadCount" then
				stored[key] = value
			end
		end
	end
	meta.Anchor = if next(stored) ~= nil then stored else nil
end

-- Session-side copy of MetaData.Anchor (without LoadCount). Shallow: the loaded
-- value is already a private copy returned by UpdateAsync.
function Envelope.readAnchorMeta(meta: any): { [string]: any }
	local result = {}
	if type(meta) == "table" and type(meta.Anchor) == "table" then
		for key, value in next, meta.Anchor do
			if key ~= "LoadCount" then
				result[key] = value
			end
		end
	end
	return result
end

----- GlobalUpdates (messages) -----

-- ProfileStore: {index, data}; ProfileService: {index, version, locked, data}
function Envelope.messageIndex(update: any): any
	return update[1]
end

function Envelope.messageData(update: any): any
	return update[#update]
end

----- Blobs -----

@native
function Envelope.blobEqual(a: buffer?, b: buffer?): boolean
	if a == nil or b == nil then
		return false
	end
	if a == b then
		return true
	end
	local n = buffer.len(a)
	if n ~= buffer.len(b) then
		return false
	end
	local i = 0
	while i + 8 <= n do
		if buffer.readu32(a, i) ~= buffer.readu32(b, i) or buffer.readu32(a, i + 4) ~= buffer.readu32(b, i + 4) then
			return false
		end
		i += 8
	end
	while i < n do
		if buffer.readu8(a, i) ~= buffer.readu8(b, i) then
			return false
		end
		i += 1
	end
	return true
end

-- Rough serialized-size estimate for the 4 MB DataStore limit guard.
-- Compact: base64 of the blob. Compat: JSON is larger than the binary blob; we use 2x
-- the blob as a conservative estimate (Studio-only fact: real JSON length may differ).
function Envelope.estimateSize(blob: buffer, compact: boolean): number
	local n = buffer.len(blob)
	if compact then
		return math.ceil(n / 3) * 4 + 64
	end
	return n * 2
end

return table.freeze(Envelope)
