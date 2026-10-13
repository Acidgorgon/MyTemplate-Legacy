--!strict
-- Typed, schema-checked player data on top of DataService (leifstout/dataservice,
-- which wraps ProfileStore: session locking, autosave, release on leave).
--
-- Server only and server-authoritative: nothing here listens to the client. Clients
-- get a read-only copy of their own data through Replication (charm-sync over Blink)
-- and read it with ReplicatedStorage.Shared.Data.Client.
--
--   local PlayerDataService = require(ServerScriptService.Server.Data.PlayerDataService)
--
--   local data = PlayerDataService:WaitForData(player)        -- yields; frozen snapshot or nil
--   local coins = PlayerDataService:Get(player).Coins          -- Get never yields; nil if not loaded
--
--   PlayerDataService:Update(player, function(draft)           -- errors if the result is invalid
--   	table.insert(draft.Inventory.Items, { Id = "Sword", Count = 1 })
--   end)
--
--   if PlayerDataService:Increment(player, "Coins", -price) then  -- false if it would go below 0
--   	-- bought
--   end
--
--   PlayerDataService.Changed:Connect(function(player, new, old) end)
--
-- Rules:
--   - Update callbacks get a plain copy (a draft). Edit it freely; do not yield in it.
--     The whole result is validated against Schema before it is committed.
--   - Never write profile data through DataService:set/arrayInsert directly: those
--     skip validation, and the stored tables are frozen so they will error anyway.
--   - Studio without API access uses ProfileStore's in-memory mock (warned below).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DataService = require(ReplicatedStorage.Packages.Dataservice).server
local Signal = require(ReplicatedStorage.Packages.Signal)

local Schema = require(ReplicatedStorage.Shared.Data.Schema)
local PlayerDataCore = require(ReplicatedStorage.Shared.Data.PlayerDataCore)
local Migrations = require(script.Parent.Migrations)
local Replication = require(script.Parent.Replication)

type PlayerData = Schema.PlayerData

local Config = {
	-- ProfileStore name. Changing it starts everyone from scratch.
	StoreName = "PlayerData",
	-- Studio only: always use an in-memory store, even with API access on.
	MockInStudio = false,
	-- How long WaitForData waits by default, in seconds.
	LoadTimeout = 30,
	-- How long WaitForSave waits for a confirmed save, in seconds.
	SaveTimeout = 30,
}

local PlayerDataService = {}
PlayerDataService.Priority = 100
PlayerDataService.Config = Config

-- (player, data): data is loaded, migrated, repaired and replicated.
PlayerDataService.Loaded = Signal.new() :: Signal.Signal<Player, PlayerData>
-- (player, data): the player is leaving and the profile is about to be saved and
-- released. Handlers can still Update, as long as they do so without yielding first.
PlayerDataService.Releasing = Signal.new() :: Signal.Signal<Player, PlayerData>
-- (player, new, old): after every committed change.
PlayerDataService.Changed = Signal.new() :: Signal.Signal<Player, PlayerData, PlayerData>

local initialized = false
local joinTimes: { [Player]: number } = {}
local waiting: { [Player]: { thread } } = {}

local core = PlayerDataCore.new({
	Template = Schema.Template,
	Version = Schema.Version,
	VersionKey = Schema.VersionKey,
	Validator = Schema.Validator,
	Migrate = function(data, from)
		return Migrations.Run(data, from, Schema.Version, Schema.VersionKey)
	end,
	OnChanged = function(player, new, old, changed)
		-- Mirror the changed top-level keys into the profile that ProfileStore saves.
		if DataService:hasProfile(player) then
			for _, field in changed do
				DataService:set(player, field, new[field], true)
			end
		end
		Replication.Set(player, new :: any)
		PlayerDataService.Changed:Fire(player, new :: any, old :: any)
	end,
})

local function resumeWaiting(player: Player)
	local threads = waiting[player]
	if threads then
		waiting[player] = nil
		for _, thread in threads do
			if coroutine.status(thread) == "suspended" then
				task.spawn(thread)
			end
		end
	end
end

local function findProfileStoreModule(): ModuleScript?
	local index = ReplicatedStorage.Packages:FindFirstChild("_Index")
	if not index then
		return nil
	end
	for _, package in index:GetChildren() do
		if string.find(package.Name, "profilestore@", 1, true) then
			local module = package:FindFirstChild("profilestore")
			if module and module:IsA("ModuleScript") then
				return module
			end
		end
	end
	return nil
end

local function warnIfMock(useMock: boolean)
	if not RunService:IsStudio() then
		return
	end
	if useMock then
		warn("[PlayerData] Config.MockInStudio is on: using an in-memory store. Nothing will be saved.")
		return
	end
	task.spawn(function()
		local module = findProfileStoreModule()
		if not module then
			return
		end
		local ok, ProfileStore = pcall(require, module)
		if not ok then
			return
		end
		local started = os.clock()
		while ProfileStore.DataStoreState == "NotReady" and os.clock() - started < 15 do
			task.wait(0.25)
		end
		local state = ProfileStore.DataStoreState
		if state ~= "Access" then
			warn(
				`[PlayerData] DataStores unavailable in Studio ({state}). Using an in-memory mock store:`
					.. " data resets every playtest. To test saving, publish the place and turn on"
					.. " Game Settings > Security > Enable Studio Access to API Services."
			)
		end
	end)
end

local function onProfileLoaded(player: Player, profileData: { [string]: any })
	local result = core:Load(profileData)

	if not result.Ok then
		warn(`[PlayerData] could not load data for {player.Name} ({player.UserId}): {result.Error}`)
		-- The saved data is untouched (Load works on a copy), so the session ends and
		-- saves it unchanged.
		player:Kick("Your data could not be loaded safely. Please rejoin later.")
		return
	end

	for _, line in result.Repairs do
		warn(`[PlayerData] repaired {player.Name} ({player.UserId}): {line}`)
	end
	if result.MigratedFrom then
		print(`[PlayerData] migrated {player.Name} from version {result.MigratedFrom} to {Schema.Version}`)
	end

	local data = result.Data :: { [string]: any }

	-- Swap the profile's contents for the checked data, in place: ProfileStore and
	-- DataService both hold this exact table.
	for key in profileData do
		profileData[key] = nil
	end
	for key, value in data do
		profileData[key] = value
	end

	core:Open(player, data)
	joinTimes[player] = os.clock()

	Replication.Set(player, data :: any)
	Replication.Hydrate(player)

	resumeWaiting(player)
	PlayerDataService.Loaded:Fire(player, data :: any)

	core:Update(player, function(draft)
		draft.Stats.Joins += 1
	end)
end

local function closeSession(player: Player)
	joinTimes[player] = nil
	core:Close(player)
	Replication.Remove(player)
	resumeWaiting(player)
end

local function onProfileReleasing(player: Player)
	if core:Get(player) == nil then
		resumeWaiting(player)
		return
	end

	local joined = joinTimes[player]
	joinTimes[player] = nil
	if joined then
		core:Update(player, function(draft)
			draft.Stats.TimePlayed += os.clock() - joined
		end)
	end

	PlayerDataService.Releasing:Fire(player, core:Get(player) :: any)

	closeSession(player)
end

function PlayerDataService.Init(_self: typeof(PlayerDataService), _janitor: any?)
	if initialized then
		return
	end
	initialized = true

	local useMock = Config.MockInStudio and RunService:IsStudio()
	warnIfMock(useMock)

	Replication.Start()

	-- Runs inside DataService after ProfileStore has loaded and locked the profile,
	-- before DataService exposes the data anywhere else.
	DataService.onPlayerInit = function(_dataService: any, player: Player, data: any)
		local ok, err = pcall(onProfileLoaded :: any, player, data)
		if not ok then
			warn(`[PlayerData] load failed for {player.Name}: {err}`)
			player:Kick("Your data could not be loaded. Please rejoin.")
		end
	end

	DataService:addPlayerRemovingCallback(function(player: Player)
		onProfileReleasing(player)
	end)

	-- DataService skips its removing callbacks when the profile is already gone (the
	-- session was taken by another server) or never loaded. Clean up after it either way.
	Players.PlayerRemoving:Connect(function(player)
		task.defer(closeSession, player)
	end)

	DataService:init({
		-- Empty on purpose: PlayerDataService fills defaults itself, after migrations,
		-- so old saves are not padded with new fields before they are migrated.
		template = {},
		profileStoreIndex = Config.StoreName,
		useMock = useMock,
	})
end

function PlayerDataService.Start(_self: typeof(PlayerDataService)) end

-- Frozen snapshot, or nil if not loaded (yet). Never yields.
function PlayerDataService.Get(_self: typeof(PlayerDataService), player: Player): PlayerData?
	return core:Get(player) :: any
end

function PlayerDataService.IsLoaded(_self: typeof(PlayerDataService), player: Player): boolean
	return core:Get(player) ~= nil
end

-- Yields until the player's data is loaded. nil if they leave or it times out.
function PlayerDataService.WaitForData(_self: typeof(PlayerDataService), player: Player, timeout: number?): PlayerData?
	local data = core:Get(player)
	if data then
		return data :: any
	end
	if player.Parent ~= Players then
		return nil
	end

	local thread = coroutine.running()
	local list = waiting[player]
	if not list then
		list = {}
		waiting[player] = list
	end
	table.insert(list, thread)

	local timer = task.delay(timeout or Config.LoadTimeout, function()
		local threads = waiting[player]
		local index = threads and table.find(threads, thread)
		if threads and index then
			table.remove(threads, index)
			task.spawn(thread)
		end
	end)
	coroutine.yield()
	if coroutine.status(timer) == "suspended" then
		task.cancel(timer)
	end

	return core:Get(player) :: any
end

-- Applies `fn` to a draft, validates the result and commits it. Errors (with the
-- reason) when the player's data is not loaded or the result is invalid.
function PlayerDataService.Update(self: typeof(PlayerDataService), player: Player, fn: (draft: PlayerData) -> ())
	local ok, err = self:TryUpdate(player, fn)
	if not ok then
		error(`[PlayerData] Update for {player.Name} failed: {err}`, 2)
	end
end

-- Same as Update but returns false and the reason instead of erroring.
function PlayerDataService.TryUpdate(
	_self: typeof(PlayerDataService),
	player: Player,
	fn: (draft: PlayerData) -> ()
): (boolean, string?)
	local ok, err = core:Update(player, fn :: any)
	return ok, err
end

-- Adds `amount` (may be negative) to a numeric top-level field. Returns false when
-- not loaded or when the result would break the schema (e.g. Coins below 0).
function PlayerDataService.Increment(
	_self: typeof(PlayerDataService),
	player: Player,
	field: Schema.NumericField,
	amount: number
): (boolean, string?)
	if not Schema.NumericFields[field] then
		return false, `{field} is not in Schema.NumericFields`
	end
	return core:Increment(player, field, amount)
end

-- Asks ProfileStore to save now, then yields until a save where check(savedData)
-- is true has landed. false if the session ends or it times out first.
function PlayerDataService.WaitForSave(
	_self: typeof(PlayerDataService),
	player: Player,
	check: (saved: { [string]: any }) -> boolean,
	timeout: number?
): boolean
	if not DataService:hasProfile(player) then
		return false
	end
	local profile = DataService:getProfile(player)
	if check(profile.LastSavedData) then
		return true
	end

	local done = false
	local connection = profile.OnAfterSave:Connect(function(saved)
		if check(saved) then
			done = true
		end
	end)
	profile:Save()

	local deadline = os.clock() + (timeout or Config.SaveTimeout)
	while not done and profile:IsActive() and os.clock() < deadline do
		task.wait(0.1)
	end
	connection:Disconnect()

	return done
end

return PlayerDataService
