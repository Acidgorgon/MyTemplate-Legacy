--!strict
-- The storage-independent part of PlayerDataService: load pipeline and
-- update -> validate -> commit. Used only by the server; it lives in shared so it can
-- reach Validate and Immutable with plain string requires and run under Lune.
--
-- Load(raw)
--   empty raw        -> fresh copy of the template
--   otherwise        -> migrate from raw[VersionKey] (missing = 0), fill missing fields
--                       from the template, then validate. Each issue is repaired on its
--                       own (bad template field -> its default, bad array/map entry ->
--                       removed, long array -> truncated) and reported back as text.
--
-- Update(key, fn)
--   fn gets a plain mutable deep copy (a draft). It must not yield. The whole result
--   is validated; any issue rejects the update and leaves the data as it was. On
--   success the draft becomes a new frozen snapshot that shares unchanged subtables
--   with the old one, and OnChanged(key, new, old, changedTopLevelKeys) runs.

local Immutable = require("./Immutable")
local Validate = require("./Validate")

export type Data = { [string]: any }

export type Options = {
	Template: Data,
	Version: number,
	VersionKey: string,
	Validator: Validate.Validator,
	-- Upgrades `data` in place from version `from` to Version.
	Migrate: (data: Data, from: number) -> (boolean, string?),
	OnChanged: ((key: any, new: Data, old: Data, changed: { string }) -> ())?,
	-- Max single repairs on load before falling back to a full reset. Default 100.
	MaxRepairs: number?,
}

export type LoadResult = {
	Ok: boolean,
	Data: Data?,
	Error: string?,
	Fresh: boolean,
	-- Version the data was saved with, when it had to be migrated.
	MigratedFrom: number?,
	-- One line per repair, e.g. "Coins: expected integer, got NaN -> reset to default".
	Repairs: { string },
}

type Fields = {
	_options: Options,
	_sessions: { [any]: Data },
	_updating: { [any]: boolean },
}

local PlayerDataCore = {}
PlayerDataCore.__index = PlayerDataCore

export type PlayerDataCore = typeof(setmetatable({} :: Fields, PlayerDataCore))

function PlayerDataCore.new(options: Options): PlayerDataCore
	return setmetatable(
		{
			_options = options,
			_sessions = {},
			_updating = {},
		} :: Fields,
		PlayerDataCore
	)
end

local function isDictionary(value: any): boolean
	return type(value) == "table" and next(value) ~= nil and value[1] == nil
end

-- Fills keys missing from `data` with copies of the template's. Recurses into
-- dictionaries only; arrays and maps are left as saved.
local function reconcile(data: Data, template: Data)
	for key, default in template do
		local current = data[key]
		if current == nil then
			data[key] = Immutable.DeepCopy(default)
		elseif isDictionary(default) and type(current) == "table" then
			reconcile(current, default)
		end
	end
end

local function compact(array: { [any]: any })
	local indices = {}
	for key in array do
		if type(key) == "number" and key % 1 == 0 and key >= 1 then
			table.insert(indices, key)
		end
	end
	table.sort(indices)
	local values = {}
	for _, index in indices do
		table.insert(values, array[index])
		array[index] = nil
	end
	for index, value in values do
		array[index] = value
	end
end

-- Repairs one issue in place and says what it did.
local function repair(data: Data, template: Data, issue: Validate.Issue): string
	local path = issue.Path

	if issue.Fix then
		local target: any = data
		for _, key in path do
			target = if type(target) == "table" then target[key] else nil
		end
		if type(target) == "table" then
			if issue.Fix == "Compact" then
				compact(target)
				return "closed holes"
			elseif issue.Fix == "Truncate" and issue.Max then
				compact(target)
				for index = #target, issue.Max + 1, -1 do
					target[index] = nil
				end
				return `kept first {issue.Max}`
			end
		end
	end

	local parent: any = data
	local defaults: any = template
	for index, key in path do
		local hasDefault = type(key) == "string" and isDictionary(defaults) and defaults[key] ~= nil
		if not hasDefault then
			-- An entry the template does not describe (array item, map entry, unknown key).
			if type(key) == "number" and parent[1] ~= nil then
				table.remove(parent, key)
			else
				parent[key] = nil
			end
			return "removed"
		end
		if index == #path then
			parent[key] = Immutable.DeepCopy(defaults[key])
			return "reset to default"
		end
		if type(parent[key]) ~= "table" then
			parent[key] = Immutable.DeepCopy(defaults[key])
			return "reset to default"
		end
		parent = parent[key]
		defaults = defaults[key]
	end

	return "unrepairable"
end

-- Turns raw saved data into a valid frozen snapshot. Does not open a session.
function PlayerDataCore.Load(self: PlayerDataCore, raw: Data?): LoadResult
	local options = self._options
	local repairs: { string } = {}

	if raw == nil or next(raw) == nil then
		return {
			Ok = true,
			Data = Immutable.DeepFreeze(Immutable.DeepCopy(options.Template)),
			Fresh = true,
			Repairs = repairs,
		}
	end

	local data = Immutable.DeepCopy(raw)
	local from = data[options.VersionKey]
	if from == nil then
		from = 0
	end
	if type(from) ~= "number" or from % 1 ~= 0 or from < 0 then
		return { Ok = false, Error = `invalid {options.VersionKey}: {tostring(from)}`, Fresh = false, Repairs = repairs }
	end

	local migratedFrom: number? = nil
	if from ~= options.Version then
		local ok, err = options.Migrate(data, from)
		if not ok then
			return { Ok = false, Error = err, Fresh = false, Repairs = repairs }
		end
		migratedFrom = from
	end
	data[options.VersionKey] = options.Version

	reconcile(data, options.Template)

	local limit = options.MaxRepairs or 100
	local issues = Validate.Issues(options.Validator, data)
	while #issues > 0 and #repairs < limit do
		local issue = issues[1]
		local action = repair(data, options.Template, issue)
		table.insert(repairs, `{Validate.FormatIssue(issue)} -> {action}`)
		if action == "unrepairable" then
			break
		end
		issues = Validate.Issues(options.Validator, data)
	end

	if #issues > 0 then
		table.insert(repairs, `still invalid after {#repairs} repairs -> reset everything to defaults`)
		data = Immutable.DeepCopy(options.Template)
	end

	return {
		Ok = true,
		Data = Immutable.DeepFreeze(data),
		Fresh = false,
		MigratedFrom = migratedFrom,
		Repairs = repairs,
	}
end

-- Starts tracking `key` with an already-loaded snapshot.
function PlayerDataCore.Open(self: PlayerDataCore, key: any, data: Data)
	self._sessions[key] = Immutable.DeepFreeze(data)
end

function PlayerDataCore.Close(self: PlayerDataCore, key: any)
	self._sessions[key] = nil
	self._updating[key] = nil
end

function PlayerDataCore.Get(self: PlayerDataCore, key: any): Data?
	return self._sessions[key]
end

-- Returns ok, error message. On success the new snapshot is returned third.
function PlayerDataCore.Update(self: PlayerDataCore, key: any, fn: (draft: any) -> ()): (boolean, string?, Data?)
	local options = self._options
	local current = self._sessions[key]
	if current == nil then
		return false, "data is not loaded", nil
	end
	if self._updating[key] then
		return false, "Update called from inside another Update for the same player", nil
	end

	local draft = Immutable.DeepCopy(current)

	self._updating[key] = true
	local thread = coroutine.create(fn)
	local ok, err = coroutine.resume(thread, draft)
	self._updating[key] = nil

	if not ok then
		return false, `update function errored: {debug.traceback(thread, tostring(err))}`, nil
	end
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, "update function yielded; Update callbacks must not yield", nil
	end
	if self._sessions[key] ~= current then
		-- Closed while the callback ran.
		return false, "data was released during the update", nil
	end

	if draft[options.VersionKey] ~= current[options.VersionKey] then
		return false, `{options.VersionKey} is managed by PlayerDataService`, nil
	end

	local valid, message = Validate.Check(options.Validator, draft)
	if not valid then
		return false, `rejected invalid data: {message}`, nil
	end

	local new = Immutable.Share(current, draft)
	if new == current then
		return true, nil, current
	end

	self._sessions[key] = new

	local changed: { string } = {}
	for field, value in new do
		if current[field] ~= value then
			table.insert(changed, field)
		end
	end
	for field in current do
		if new[field] == nil then
			table.insert(changed, field)
		end
	end

	if options.OnChanged then
		options.OnChanged(key, new, current, changed)
	end

	return true, nil, new
end

-- Adds `amount` to a top-level numeric field. Validation still applies, so taking
-- Coins below 0 is rejected and nothing changes.
function PlayerDataCore.Increment(self: PlayerDataCore, key: any, field: string, amount: number): (boolean, string?)
	if type(self._options.Template[field]) ~= "number" then
		return false, `{field} is not a numeric field`
	end
	if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
		return false, `invalid amount {tostring(amount)}`
	end
	local ok, err = self:Update(key, function(draft)
		draft[field] += amount
	end)
	return ok, err
end

return PlayerDataCore
