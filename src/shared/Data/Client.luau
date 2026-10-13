--!strict
-- Read-only player data on the client, as Charm selectors.
--
--   local PlayerData = require(ReplicatedStorage.Shared.Data.Client)
--
--   PlayerData.Coins()                         -- number (template default until loaded)
--   PlayerData.Loaded()                        -- false until the server sends the data
--   local level = PlayerData.Select(function(data) return data.Level end)
--   PlayerData.Public(otherPlayer.UserId)()    -- PublicData? of anyone in the server
--
--   -- Vide (inside a component or Vide.root):
--   local coins = PlayerData.Use(PlayerData.Coins)
--   create("TextLabel")({ Text = function() return `Coins: {coins()}` end })
--
-- The server owns the data. Nothing here can change it: to ask for a change, fire a
-- feature's Blink event and let the server validate it, rate limit it and Update.
--
-- Use() is here because vide-charm 0.3 is built for Vide 0.3 while this template
-- uses Vide 0.4; a source from one Vide does not track inside the other.
-- Outside a running game (UI Labs stories) the selectors return the template.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Charm = require(ReplicatedStorage.Packages.Charm)
local CharmSync = require(ReplicatedStorage.Packages.Charmsync)

local Immutable = require("./Immutable")
local Schema = require("./Schema")

type PlayerData = Schema.PlayerData
type PublicData = Schema.PublicData

local isLiveClient = RunService:IsRunning() and RunService:IsClient()
local localPlayer = Players.LocalPlayer
local localKey = if localPlayer then tostring(localPlayer.UserId) else "0"

local privateAtom = Charm.atom({} :: { [string]: PlayerData })
local publicAtom = Charm.atom({} :: { [string]: PublicData })

local PlayerData = {}

-- The whole snapshot. Frozen.
PlayerData.Data = Charm.computed(function(): PlayerData
	return privateAtom()[localKey] or Schema.Template
end)

PlayerData.Loaded = Charm.computed(function(): boolean
	return privateAtom()[localKey] ~= nil
end)

-- A memoised selector over the data; it only notifies when its result changes.
function PlayerData.Select<T>(selector: (data: PlayerData) -> T): () -> T
	return Charm.computed(function()
		return selector(PlayerData.Data())
	end)
end

PlayerData.Coins = PlayerData.Select(function(data)
	return data.Coins
end)
PlayerData.Gems = PlayerData.Select(function(data)
	return data.Gems
end)
PlayerData.Level = PlayerData.Select(function(data)
	return data.Level
end)
PlayerData.Experience = PlayerData.Select(function(data)
	return data.Experience
end)
PlayerData.Inventory = PlayerData.Select(function(data)
	return data.Inventory
end)
PlayerData.Settings = PlayerData.Select(function(data)
	return data.Settings
end)

-- Another player's public data (Schema.ToPublic), or nil if they are not here.
function PlayerData.Public(userId: number): () -> PublicData?
	local key = tostring(userId)
	return Charm.computed(function()
		return publicAtom()[key]
	end)
end

-- Current snapshot without subscribing.
function PlayerData.Get(): PlayerData
	return Charm.peek(PlayerData.Data)
end

-- Yields until the server has sent this player's data.
function PlayerData.WaitForData(): PlayerData
	while not Charm.peek(PlayerData.Loaded) do
		task.wait()
	end
	return PlayerData.Get()
end

-- Calls listener(new, old) whenever the selector's result changes. Returns a disconnect.
function PlayerData.Subscribe<T>(selector: () -> T, listener: (new: T, old: T) -> ()): () -> ()
	return Charm.subscribe(selector, listener)
end

-- Turns a selector into a Vide source; call inside a Vide scope.
function PlayerData.Use<T>(selector: () -> T): () -> T
	local Vide = require(ReplicatedStorage.Packages.Vide) :: any
	local source = Vide.source(Charm.peek(selector))
	local unsubscribe = Charm.subscribe(selector, function(value)
		task.spawn(source, value)
	end)
	Vide.cleanup(unsubscribe)
	return source
end

if isLiveClient then
	local Events = require(ReplicatedStorage.Shared.events.client) :: any
	local syncer = CharmSync.client({
		atoms = {
			Private = privateAtom,
			Public = publicAtom,
		},
	})

	Events.PlayerDataSync.On(function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		syncer:sync(payload)
		-- charm-sync rebuilds changed tables unfrozen; keep the client's copy read-only.
		Immutable.DeepFreeze(privateAtom())
		Immutable.DeepFreeze(publicAtom())
	end)
end

return PlayerData
