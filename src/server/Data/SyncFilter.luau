--!strict
-- charm-sync 0.3 builds one payload per sync and hands the same payload to every
-- player. The "Private" atom holds every player's full data keyed by UserId, so it
-- must be cut down to the receiving player's own entry before it leaves the server.
-- Any other atom ("Public") is sent as-is.
--
-- Payload shapes (from charm-sync):
--   { type = "init",  data = { Private = { [userKey] = data }, Public = {...} } }
--   { type = "patch", data = { Private = { [userKey] = diff }, Public = diff } }
-- An atom that did not change is missing from a patch. A removed entry is the
-- table { __none = "__none" }.
--
-- Pure Luau: no Roblox services.

local PRIVATE = "Private"

export type Payload = {
	type: string,
	data: { [any]: any },
}

local SyncFilter = {}

-- The payload `userKey` may receive, or nil when nothing in it is theirs to see.
-- Never mutates `payload` (it is shared between players).
function SyncFilter.ForPlayer(payload: Payload, userKey: string): Payload?
	local data: { [any]: any } = {}
	local hasData = false

	for atomKey, value in payload.data do
		if atomKey == PRIVATE then
			if type(value) == "table" and value.__none == nil then
				local own = value[userKey]
				if own ~= nil then
					data[PRIVATE] = { [userKey] = own }
					hasData = true
				elseif payload.type == "init" then
					data[PRIVATE] = {}
				end
			end
		else
			data[atomKey] = value
			hasData = true
		end
	end

	if payload.type == "init" then
		if data[PRIVATE] == nil then
			data[PRIVATE] = {}
		end
		return { type = "init", data = data }
	end

	if not hasData then
		return nil
	end
	return { type = payload.type, data = data }
end

return SyncFilter
