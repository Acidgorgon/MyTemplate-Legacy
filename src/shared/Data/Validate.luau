--!strict
-- Tiny validator kit for player data (t-style combinators).
--
-- A validator walks a value and records every problem it finds as an Issue with
-- the path to the bad value, e.g. "Inventory.Items[3].Count: expected integer, got 1.5".
--
--   local V = require("./Validate")
--   local Item = V.Record({ Id = V.String(64, 1), Count = V.Integer(1, 999) })
--   local ok, err = V.Check(V.Array(Item, 50), items)
--
-- Pure Luau: no Roblox services, so the specs in tests/ run under Lune.

export type PathKey = string | number
export type Path = { PathKey }

-- Fix tells the load-time repair what to do instead of resetting to defaults:
--   "Truncate" - the array is too long; keep the first Max entries.
--   "Compact"  - the array has holes; close them up.
export type Issue = {
	Path: Path,
	Message: string,
	Fix: ("Truncate" | "Compact")?,
	Max: number?,
}

export type Validator = (value: any, path: Path, issues: { Issue }) -> ()

local Validate = {}

local function report(issues: { Issue }, path: Path, message: string, fix: ("Truncate" | "Compact")?, max: number?)
	table.insert(issues, {
		Path = table.clone(path),
		Message = message,
		Fix = fix,
		Max = max,
	})
end

local function describe(value: any): string
	local kind = type(value)
	if kind == "number" then
		if value ~= value then
			return "NaN"
		end
		return tostring(value)
	elseif kind == "string" then
		if #value > 24 then
			return `string "{string.sub(value, 1, 24)}..."`
		end
		return `"{value}"`
	end
	return kind
end

-- "Inventory.Items[3].Count". Keys that are not plain identifiers use ["key"].
function Validate.FormatPath(path: Path): string
	if #path == 0 then
		return "<root>"
	end
	local parts = table.create(#path)
	for index, key in path do
		if type(key) == "number" then
			table.insert(parts, `[{key}]`)
		elseif type(key) ~= "string" then
			-- Data from a store can hold keys of other types; show them, never error here.
			table.insert(parts, `[{tostring(key)}]`)
		elseif string.match(key, "^[%a_][%w_]*$") then
			table.insert(parts, if index == 1 then key else "." .. key)
		else
			table.insert(parts, `["{key}"]`)
		end
	end
	return table.concat(parts)
end

function Validate.FormatIssue(issue: Issue): string
	return `{Validate.FormatPath(issue.Path)}: {issue.Message}`
end

-- Every issue in `value`. Empty when valid.
function Validate.Issues(validator: Validator, value: any): { Issue }
	local issues: { Issue } = {}
	validator(value, {}, issues)
	return issues
end

-- true, or false and the first issue as text ("Coins: expected integer, got 1.5").
function Validate.Check(validator: Validator, value: any): (boolean, string?)
	local issues = Validate.Issues(validator, value)
	if #issues == 0 then
		return true, nil
	end
	local message = Validate.FormatIssue(issues[1])
	if #issues > 1 then
		message ..= ` (and {#issues - 1} more)`
	end
	return false, message
end

-- Primitives

function Validate.Any(_value: any, _path: Path, _issues: { Issue }) end

function Validate.Boolean(value: any, path: Path, issues: { Issue })
	if type(value) ~= "boolean" then
		report(issues, path, `expected boolean, got {describe(value)}`)
	end
end

local function checkRange(value: number, path: Path, issues: { Issue }, min: number?, max: number?)
	if min and value < min then
		report(issues, path, `must be >= {min}, got {value}`)
	elseif max and value > max then
		report(issues, path, `must be <= {max}, got {value}`)
	end
end

-- Finite number (NaN and +-inf are rejected), optionally within [min, max].
function Validate.Number(min: number?, max: number?): Validator
	return function(value, path, issues)
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			report(issues, path, `expected number, got {describe(value)}`)
			return
		end
		checkRange(value, path, issues, min, max)
	end
end

-- Whole number, optionally within [min, max]. Keep max below 2^53 so it stays exact.
function Validate.Integer(min: number?, max: number?): Validator
	return function(value, path, issues)
		if type(value) ~= "number" or value ~= value or value % 1 ~= 0 then
			report(issues, path, `expected integer, got {describe(value)}`)
			return
		end
		checkRange(value, path, issues, min, max)
	end
end

-- String with a byte length within [minLength, maxLength].
function Validate.String(maxLength: number?, minLength: number?): Validator
	return function(value, path, issues)
		if type(value) ~= "string" then
			report(issues, path, `expected string, got {describe(value)}`)
			return
		end
		if maxLength and #value > maxLength then
			report(issues, path, `string longer than {maxLength} bytes`)
		elseif minLength and #value < minLength then
			report(issues, path, `string shorter than {minLength} bytes`)
		end
	end
end

-- One of a fixed set of strings: V.Enum({ "Low", "Medium", "High" }).
function Validate.Enum(values: { string }): Validator
	local allowed: { [string]: boolean } = {}
	for _, name in values do
		allowed[name] = true
	end
	local list = table.concat(values, ", ")
	return function(value, path, issues)
		if type(value) ~= "string" or not allowed[value] then
			report(issues, path, `expected one of {list}, got {describe(value)}`)
		end
	end
end

function Validate.Literal(expected: any): Validator
	return function(value, path, issues)
		if value ~= expected then
			report(issues, path, `expected {describe(expected)}, got {describe(value)}`)
		end
	end
end

-- Combinators

function Validate.Optional(inner: Validator): Validator
	return function(value, path, issues)
		if value ~= nil then
			inner(value, path, issues)
		end
	end
end

-- Passes when any one of the validators passes; otherwise reports the last one's issues.
function Validate.Union(...: Validator): Validator
	local options = { ... }
	return function(value, path, issues)
		local last: { Issue } = {}
		for _, option in options do
			local attempt: { Issue } = {}
			option(value, path, attempt)
			if #attempt == 0 then
				return
			end
			last = attempt
		end
		table.move(last, 1, #last, #issues + 1, issues)
	end
end

-- check(value) -> (ok, message?). For rules the kit does not cover.
function Validate.Custom(check: (value: any) -> (boolean, string?)): Validator
	return function(value, path, issues)
		local ok, message = check(value)
		if not ok then
			report(issues, path, message or "failed custom check")
		end
	end
end

-- Dense array (keys 1..n, no holes) of `item`, with at most `maxSize` entries.
function Validate.Array(item: Validator, maxSize: number?): Validator
	return function(value, path, issues)
		if type(value) ~= "table" then
			report(issues, path, `expected array, got {describe(value)}`)
			return
		end

		local count = 0
		local highest = 0
		for key in value do
			if type(key) == "number" and key % 1 == 0 and key >= 1 then
				count += 1
				highest = math.max(highest, key)
			else
				table.insert(path, key)
				report(issues, path, "unexpected key in array")
				table.remove(path)
			end
		end

		if highest ~= count then
			report(issues, path, "array has holes", "Compact")
		end
		if maxSize and count > maxSize then
			report(issues, path, `array has {count} entries, max {maxSize}`, "Truncate", maxSize)
		end

		for index = 1, highest do
			local entry = value[index]
			if entry ~= nil then
				table.insert(path, index)
				item(entry, path, issues)
				table.remove(path)
			end
		end
	end
end

-- Dictionary whose keys pass `key` and values pass `entry`, with at most `maxSize` entries.
function Validate.Map(key: Validator, entry: Validator, maxSize: number?): Validator
	return function(value, path, issues)
		if type(value) ~= "table" then
			report(issues, path, `expected map, got {describe(value)}`)
			return
		end

		local count = 0
		for k, v in value do
			count += 1
			table.insert(path, k)
			local keyIssues: { Issue } = {}
			key(k, path, keyIssues)
			if #keyIssues > 0 then
				report(issues, path, `invalid key: {keyIssues[1].Message}`)
			else
				entry(v, path, issues)
			end
			table.remove(path)
		end

		if maxSize and count > maxSize then
			report(issues, path, `map has {count} entries, max {maxSize}`)
		end
	end
end

-- Table with known fields. Every listed field is checked (missing = nil, so wrap
-- optional fields in V.Optional). Extra keys are allowed unless `strict` is true.
function Validate.Record(fields: { [string]: Validator }, strict: boolean?): Validator
	return function(value, path, issues)
		if type(value) ~= "table" then
			report(issues, path, `expected table, got {describe(value)}`)
			return
		end

		for name, field in fields do
			table.insert(path, name)
			field(value[name], path, issues)
			table.remove(path)
		end

		if strict then
			for k in value do
				if type(k) ~= "string" or fields[k] == nil then
					table.insert(path, k)
					report(issues, path, "unexpected key")
					table.remove(path)
				end
			end
		end
	end
end

return Validate
