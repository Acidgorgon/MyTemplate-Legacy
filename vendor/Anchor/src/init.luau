--!nonstrict
--[[
	Anchor - session-locked profiles for Roblox, a drop-in upgrade of ProfileStore 1.0.3.

	QUICK START (3 lines):
		local Data = require(game.ServerScriptService.Anchor).new("Main", { Coins = 0, Items = {} })
		Data:Bind()                                          -- loads on join, saves on leave/shutdown
		Data:Update(player, function(data) data.Coins += 10 end)

	Easy API (store methods):
		Anchor.new(name, template, options?) -> store
		Data:Bind({ Key = fn(player) -> string, OnLoaded = fn(player, profile), KickMessage, LoadTimeout })
		Data:Get(player) -> profile?             Data:Await(player) -> profile?
		Data:Update(player, fn(data)) -> boolean (fn gets the Ripple state when UseRipple is on)
		Data.Loaded:Connect(fn(player, profile))  Data.Leaving:Connect(fn(player, profile))
		Data:Send(userIdOrKey, topic, payload) -> boolean   (reaches the player on any server, or on next join)
		Data:OnMessage(topic, fn(player, payload) -> false?)  (return false to keep it for later)
		Data:UseRipple(fn(player, profile) -> state)          (Update / Trade / Gift / receipts write through it)
		Data:Reset(player)                                    (Studio: refill Data from the template now)
		Anchor.Trade(profileA, profileB, fn(draftA, draftB)) -> (ok, reason?)   see Trade.luau
		Data:Gift(userIdOrKey, fn(data) | patch, { Id? })     -> (ok, reason?)   see Trade.luau
		Data:ProcessReceipt(info, grant) / Data:HandleReceipts(grants)          see Receipts.luau

	Options (third argument of Anchor.new):
		Format = "Compat" (default) | "Compact", VerifyWrites = true, LockRefresh = 300,
		IsDirty = fn(profile) -> boolean, ClearDirty = fn(profile),
		LastSavedData = true                  -- false: no load copy; profile.LastSavedData stays nil
		KeyPrefix = "Player_"                 -- Bind's key is KeyPrefix .. UserId

		Dev options (Studio only; also settable as attributes on this ModuleScript, code wins):
		Mock = true                           -- in-memory store, nothing touches the DataStore
		Reset = true                          -- every join starts from the template (old save kept in version history)
		PlayAs = userId                       -- the first player to join plays on that user's save
		View = userId                         -- read-only look at that user's save, never saves
		                                         (PlayAs/View keys come from Bind's Key function, given a
		                                         stand-in player whose UserId is the target's)
		NoSave = true                         -- your own save, never written (no session lock either)
		AllowDevOptionsLive = true            -- (code only) honour dev options on live servers too.
		                                         Without it they are ignored there with one warning.

	Stock API (unchanged; swap the module and existing code keeps working):
		Anchor.New(store_name, template?, options?) -> store
		Anchor.SetConstant(name, value)
		Anchor.IsClosing, Anchor.IsCriticalState, Anchor.DataStoreState
		Anchor.OnError(message, store_name, key), Anchor.OnOverwrite(store_name, key),
		Anchor.OnCriticalToggle(is_critical)
		store:StartSessionAsync(key, {Steal?, Cancel?}) / :MessageAsync / :GetAsync /
		      :VersionQuery / :RemoveAsync, store.Mock
		profile.Data / .LastSavedData / .FirstSessionTime / .SessionLoadCount / .Session /
		        .RobloxMetaData / .UserIds / .KeyInfo / .OnSave / .OnLastSave / .OnSessionEnd /
		        .OnAfterSave / .ProfileStore / .Key
		profile:IsActive / :Reconcile / :EndSession / :AddUserId / :RemoveUserId /
		        :MessageHandler / :Save / :SetAsync
		profile:SaveAsync() -> boolean     -- [Anchor] yields; true once a write with the current state succeeded

	Feature modules (Trade, Receipts) placed as children of this module are installed
	automatically: each returns { install = function(Anchor, Core) }.
--]]

local Core = require(script.Core)
local Signal = require(script.Signal)
local Patch = require(script.Patch)

local Anchor = Core.Module

export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer

export type Options = {
	Format: ("Compat" | "Compact")?,
	VerifyWrites: boolean?,
	LockRefresh: number?,
	IsDirty: ((profile: any) -> boolean)?,
	ClearDirty: ((profile: any) -> ())?,
	KeyPrefix: string?,
	Mock: boolean?,
	Reset: boolean?,
	PlayAs: number?,
	View: number?,
	NoSave: boolean?,
	AllowDevOptionsLive: boolean?,
}

export type BindOptions = {
	Key: ((player: Player) -> string)?,
	OnLoaded: ((player: Player, profile: any) -> ())?,
	KickMessage: string?,
	LoadTimeout: number?,
}

local DEFAULT_KICK_MESSAGE = "Your data could not be loaded. Please rejoin."
local DEFAULT_LOAD_TIMEOUT = 120 -- stock START_SESSION_TIMEOUT
local DEFAULT_KEY_PREFIX = "Player_"

local DEV_OPTIONS = { "Mock", "Reset", "PlayAs", "View", "NoSave" }

local RunService = game:GetService("RunService")

local function isStudio(): boolean
	local ok, result = pcall(function()
		return RunService:IsStudio()
	end)
	return ok == true and result == true
end

local function moduleAttribute(name)
	local ok, value = pcall(function()
		return script:GetAttribute(name)
	end)
	return if ok then value else nil
end

-- Reads dev options from code, then from attributes on this ModuleScript. Returns the
-- active set (empty table when none apply).
local function resolveDevOptions(store_name, options)
	local requested = {}
	local names = {}
	for _, name in ipairs(DEV_OPTIONS) do
		local value = options[name]
		if value == nil then
			value = moduleAttribute(name)
		end
		if name == "PlayAs" or name == "View" then
			if type(value) == "string" then
				value = tonumber(value)
			end
			if type(value) ~= "number" or value == 0 then
				value = nil
			end
		else
			value = if value == true then true else nil
		end
		if value ~= nil then
			requested[name] = value
			table.insert(names, name)
		end
	end
	if #names == 0 then
		return {}
	end
	local list = table.concat(names, ", ")
	if not isStudio() and options.AllowDevOptionsLive ~= true then
		warn(
			`[Anchor]: Store "{store_name}": dev options ({list}) are IGNORED on this live server - they would `
				.. `lose or overwrite real saves. Remove them (check the Anchor ModuleScript's attributes), or pass `
				.. `AllowDevOptionsLive = true for a private test place.`
		)
		return {}
	end
	print(`[Anchor]: Store "{store_name}" dev options: {list}`)
	return requested
end

local function devAllowed(store): boolean
	return isStudio() or store.allow_dev_live == true
end

----- Store construction -----

local CoreNew = Anchor.New

Anchor._stores = {} -- [name] = first store created with that name (trade delivery)

function Anchor.New(store_name, template, options: Options?)
	if options ~= nil and type(options) ~= "table" then
		error("[Anchor]: Invalid options argument")
	end
	options = options or {}
	if options.KeyPrefix ~= nil and (type(options.KeyPrefix) ~= "string" or options.KeyPrefix == "") then
		error("[Anchor]: KeyPrefix must be a non-empty string")
	end
	local dev = resolveDevOptions(store_name, options)
	local core_options = table.clone(options)
	core_options.Mock = dev.Mock == true

	local store = CoreNew(store_name, template, core_options)
	store.Loaded = Signal.New() -- (player, profile), fired by Bind
	store.Leaving = Signal.New() -- (player, profile), fired by Bind before the session ends
	store.key_prefix = options.KeyPrefix or DEFAULT_KEY_PREFIX
	store.dev = dev
	store.allow_dev_live = options.AllowDevOptionsLive == true
	store.topic_handlers = {}
	if Anchor._stores[store_name] == nil then
		Anchor._stores[store_name] = store
	end
	return store
end

Anchor.new = Anchor.New

----- Helpers -----

local function checkStore(self, method)
	if type(self) ~= "table" or self.template == nil then
		error(`[Anchor]: {method} must be called on a store (Data:{method}(...))`)
	end
end

local function keyFor(store, target)
	if type(target) == "number" then
		return store.key_prefix .. tostring(target)
	elseif type(target) == "string" then
		return target
	end
	error("[Anchor]: expected a UserId (number) or a profile key (string)")
end

local function usable(profile)
	return profile ~= nil and (profile:IsActive() or rawget(profile, "_anchor_view") == true)
end

local function reportLive(profile)
	return function(message)
		local store_name = profile.ProfileStore.Name
		warn(`[Anchor]: {message} (STORE:{store_name}; KEY:{tostring(profile.Key)})`)
		Anchor.OnError:Fire(message, store_name, profile.Key)
	end
end

-- Refills profile.Data from the template in place (through the Ripple state if any).
local function refill(store, profile)
	local patch = Patch.replace(profile.Data, store.template)
	Patch.apply(profile.Data, patch, rawget(profile, "_anchor_live"), reportLive(profile))
	profile:MarkMetaDirty() -- the next autosave must write it
end

local function attachRipple(store, player, profile)
	local fn = store.ripple_fn
	if fn == nil or rawget(profile, "_anchor_live") ~= nil then
		return
	end
	local ok, state = pcall(fn, player, profile)
	if ok == false then
		reportLive(profile)(`UseRipple function errored: {tostring(state)}`)
	elseif state ~= nil then
		rawset(profile, "_anchor_live", state)
	end
end

----- Easy API (store methods; stores use the module table as __index) -----

function Anchor:Bind(bind_options: BindOptions?)
	checkStore(self, "Bind")
	if self.bind_state ~= nil then
		error(`[Anchor]: Store "{self.Name}" is already bound`)
	end
	bind_options = bind_options or {}

	local store = self
	local Players = game:GetService("Players")
	local prefix = self.key_prefix
	local key_fn = bind_options.Key or function(player)
		return prefix .. player.UserId
	end
	local kick_message = bind_options.KickMessage or DEFAULT_KICK_MESSAGE
	local on_loaded = bind_options.OnLoaded
	local load_timeout = bind_options.LoadTimeout or DEFAULT_LOAD_TIMEOUT
	local dev = self.dev

	local state = {
		profiles = {}, -- [player] = profile
		loading = {}, -- [player] = true
		changed = Signal.New(),
		play_as = nil, -- player currently on the PlayAs save
	}
	self.bind_state = state

	local function in_game(player)
		return player.Parent == Players
	end

	-- PlayAs / View: the target's key, built by the same Key function as everyone else's.
	-- The function gets a stand-in whose UserId is the target's (other fields read through
	-- to the joining player). Returns nil (and reports) if the function can't build it.
	local function key_for_user(player, user_id)
		if bind_options.Key == nil then
			return prefix .. user_id
		end
		local stand_in = setmetatable({ UserId = user_id }, {
			__index = function(_, field)
				return player[field]
			end,
		})
		local ok, key = pcall(key_fn, stand_in)
		if ok == true and type(key) == "string" and key ~= "" then
			return key
		end
		local message = `Bind Key function could not build the key for dev option user {user_id}: {tostring(key)}`
		warn(`[Anchor]: {message} (STORE:{store.Name})`)
		Anchor.OnError:Fire(message, store.Name, nil)
		return nil
	end

	local function load_view(player, key)
		local profile = store:GetAsync(key)
		if profile == nil then
			profile = Core.NewViewProfile(store, key, Patch.deepCopy(store.template), dev.Mock == true)
		end
		rawset(profile, "_anchor_view", true)
		return profile
	end

	local function on_player_added(player)
		if state.profiles[player] ~= nil or state.loading[player] == true then
			return
		end
		state.loading[player] = true

		local key = key_fn(player)
		local read_only = false
		local own_save = true
		if dev.View ~= nil then
			key = key_for_user(player, dev.View)
			read_only = true
			own_save = false
		elseif dev.PlayAs ~= nil and state.play_as == nil then
			key = key_for_user(player, dev.PlayAs)
			state.play_as = player
			own_save = false
		end
		if dev.NoSave == true then
			read_only = true
		end

		local profile
		if key == nil then
			profile = nil -- reported above; kicked below (never falls back to another key)
		elseif read_only then
			profile = load_view(player, key)
		else
			local started = os.clock()
			profile = self:StartSessionAsync(key, {
				Cancel = function()
					-- Stock applies no timeout when Cancel is given; Bind kicks after LoadTimeout.
					return in_game(player) == false or os.clock() - started > load_timeout
				end,
			})
		end

		state.loading[player] = nil

		if profile == nil then
			if state.play_as == player then
				state.play_as = nil
			end
			if in_game(player) then
				player:Kick(kick_message)
			end
			state.changed:Fire()
			return
		end

		if own_save and not read_only then
			profile:AddUserId(player.UserId)
		end
		if dev.Reset == true then
			refill(store, profile) -- the old save stays in the key's version history
		end
		profile:Reconcile()

		if not read_only then
			profile.OnSessionEnd:Connect(function()
				if state.profiles[player] == profile then
					-- Ended without the player leaving (another server took it, or shutdown):
					state.profiles[player] = nil
					if in_game(player) then
						player:Kick(kick_message)
					end
					state.changed:Fire()
				end
			end)
		end

		if in_game(player) and usable(profile) then
			state.profiles[player] = profile
			attachRipple(store, player, profile)
			if not read_only then
				profile:MessageHandler(function(message, processed)
					if type(message) ~= "table" or message.AnchorTopic == nil then
						return
					end
					local handler = store.topic_handlers[message.AnchorTopic]
					if handler == nil then
						return -- kept until a handler for this topic exists
					end
					local ok, result = pcall(handler, player, message.Payload)
					if ok == false then
						reportLive(profile)(`OnMessage("{tostring(message.AnchorTopic)}") errored: {tostring(result)}`)
					elseif result ~= false then
						processed()
					end
				end)
			end
			if on_loaded ~= nil then
				task.spawn(on_loaded, player, profile)
			end
			self.Loaded:Fire(player, profile)
		else
			profile:EndSession()
		end
		state.changed:Fire()
	end

	Players.PlayerAdded:Connect(on_player_added)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(on_player_added, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local profile = state.profiles[player]
		if state.play_as == player then
			state.play_as = nil
		end
		if profile ~= nil then
			state.profiles[player] = nil
			self.Leaving:Fire(player, profile)
			profile:EndSession()
		end
		state.changed:Fire()
	end)

	return self
end

function Anchor:Get(player)
	checkStore(self, "Get")
	local state = self.bind_state
	if state == nil then
		error("[Anchor]: Call store:Bind() before store:Get()")
	end
	local profile = state.profiles[player]
	if usable(profile) then
		return profile
	end
	return nil
end

function Anchor:Await(player)
	checkStore(self, "Await")
	local state = self.bind_state
	if state == nil then
		error("[Anchor]: Call store:Bind() before store:Await()")
	end
	local Players = game:GetService("Players")
	while true do
		local profile = state.profiles[player]
		if usable(profile) then
			return profile
		end
		if player.Parent ~= Players then
			return nil
		end
		if profile == nil and state.loading[player] ~= true and Anchor.IsClosing == true then
			return nil
		end
		state.changed:Wait()
	end
end

-- fn receives the Ripple state when UseRipple is on (so writes replicate), else profile.Data.
function Anchor:Update(player, fn: (data: any) -> ()): boolean
	checkStore(self, "Update")
	local profile = self:Get(player)
	if profile == nil then
		return false
	end
	fn(rawget(profile, "_anchor_live") or profile.Data)
	return true
end

-- Studio only (or AllowDevOptionsLive): refills the player's Data from the template in
-- place. Nothing is deleted from the DataStore; the old save stays in version history.
function Anchor:Reset(player): boolean
	checkStore(self, "Reset")
	if not devAllowed(self) then
		warn("[Anchor]: Data:Reset(player) is Studio-only (pass AllowDevOptionsLive = true to allow it live)")
		return false
	end
	local profile = self:Get(player)
	if profile == nil then
		return false
	end
	refill(self, profile)
	return true
end

-- fn(player, profile) -> state, called once per loaded profile (and for players already in).
function Anchor:UseRipple(fn)
	checkStore(self, "UseRipple")
	if type(fn) ~= "function" then
		error("[Anchor]: UseRipple needs a function(player, profile) -> state")
	end
	self.ripple_fn = fn
	local state = self.bind_state
	if state ~= nil then
		for player, profile in pairs(state.profiles) do
			attachRipple(self, player, profile)
		end
	end
	return self
end

-- Sends payload to a player's profile on whichever server owns it (or at their next join).
function Anchor:Send(target, topic, payload): boolean
	checkStore(self, "Send")
	if type(topic) ~= "string" then
		error("[Anchor]: Send topic must be a string")
	end
	return self:MessageAsync(keyFor(self, target), { AnchorTopic = topic, Payload = payload })
end

-- handler(player, payload) -> false? ; return false to keep the message for later.
-- Register before players join (messages without a handler wait in the profile).
function Anchor:OnMessage(topic, handler)
	checkStore(self, "OnMessage")
	if type(topic) ~= "string" or type(handler) ~= "function" then
		error("[Anchor]: OnMessage(topic: string, handler: function)")
	end
	self.topic_handlers[topic] = handler
	return self
end

----- Internals for feature modules and tests -----

Anchor._Core = Core

----- Feature modules -----

do
	local ok, children = pcall(function()
		return script:GetChildren()
	end)
	if ok == true and type(children) == "table" then
		for _, name in ipairs({ "Trade", "Receipts" }) do
			for _, child in ipairs(children) do
				if child.Name == name then
					local feature = require(child)
					if type(feature) == "table" and type(feature.install) == "function" then
						feature.install(Anchor, Core)
					end
				end
			end
		end
	end
end

return Anchor
