--!strict
-- Read-only replication of player data with charm-sync over the PlayerDataSync Blink
-- event (server -> client only; there is no client -> server data event).
--
--   Private atom: { [userId]: PlayerData }  each player only receives their own entry.
--   Public atom:  { [userId]: PublicData }  everyone receives everything (Schema.ToPublic).
--
-- Snapshots share unchanged subtables (see Immutable.Share), so charm-sync's diff
-- only walks and sends what actually changed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Charm = require(ReplicatedStorage.Packages.Charm)
local CharmSync = require(ReplicatedStorage.Packages.Charmsync)

local Immutable = require(ReplicatedStorage.Shared.Data.Immutable)
local Schema = require(ReplicatedStorage.Shared.Data.Schema)
local SyncFilter = require(script.Parent.SyncFilter)

type PlayerData = Schema.PlayerData
type PublicData = Schema.PublicData

-- Blink's server output lives in ReplicatedStorage on master and in
-- ServerScriptService once it is moved there; take whichever exists.
local function requireServerEvents(): any
	local server = ServerScriptService:FindFirstChild("Server")
	local events = server and server:FindFirstChild("events")
	local module = events and events:FindFirstChild("server")
	if module and module:IsA("ModuleScript") then
		return require(module) :: any
	end
	return require(ReplicatedStorage.Shared.events.server) :: any
end

local privateAtom = Charm.atom({} :: { [string]: PlayerData })
local publicAtom = Charm.atom({} :: { [string]: PublicData })

local syncer = CharmSync.server({
	atoms = {
		Private = privateAtom,
		Public = publicAtom,
	},
	interval = 0,
})

local started = false
local Events: any = nil

local Replication = {}

function Replication.Start()
	if started then
		return
	end
	started = true
	Events = requireServerEvents()

	syncer:connect(function(player: Player, ...)
		local key = tostring(player.UserId)
		for index = 1, select("#", ...) do
			local payload = SyncFilter.ForPlayer((select(index, ...)), key)
			if payload then
				Events.PlayerDataSync.Fire(player, payload)
			end
		end
	end)
end

local function withKey<T>(map: { [string]: T }, key: string, value: T?): { [string]: T }
	local nextMap: { [string]: any } = table.clone(map)
	nextMap[key] = value
	return nextMap
end

function Replication.Set(player: Player, data: PlayerData)
	local key = tostring(player.UserId)

	if privateAtom()[key] ~= data then
		privateAtom(withKey(privateAtom(), key, data))
	end

	local public = Schema.ToPublic(data)
	if not Immutable.DeepEqual(publicAtom()[key], public) then
		publicAtom(withKey(publicAtom(), key, Immutable.DeepFreeze(public)))
	end
end

function Replication.Remove(player: Player)
	local key = tostring(player.UserId)
	if privateAtom()[key] ~= nil then
		privateAtom(withKey(privateAtom(), key, nil))
	end
	if publicAtom()[key] ~= nil then
		publicAtom(withKey(publicAtom(), key, nil))
	end
end

-- Sends the full current state (their own data + everyone's public data).
function Replication.Hydrate(player: Player)
	syncer:hydrate(player)
end

return Replication
