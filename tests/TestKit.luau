--!strict
-- Minimal test helpers for the *.spec.luau files. Pure Luau.

export type Kit = {
	test: (name: string, fn: () -> ()) -> (),
	equal: (actual: any, expected: any, label: string?) -> (),
	deepEqual: (actual: any, expected: any, label: string?) -> (),
	truthy: (value: any, label: string?) -> (),
	falsy: (value: any, label: string?) -> (),
	contains: (text: string?, fragment: string, label: string?) -> (),
	errors: (fn: () -> (), fragment: string?) -> (),
}

export type Result = { passed: number, failed: { string } }

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	local parts = {}
	for key, child in value do
		table.insert(parts, `{tostring(key)}={show(child)}`)
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local TestKit = {}

function TestKit.new(suite: string, result: Result): Kit
	local kit = {} :: Kit

	function kit.test(name, fn)
		local ok, err = pcall(fn :: any)
		if ok then
			result.passed += 1
		else
			table.insert(result.failed, `{suite} > {name}: {err}`)
		end
	end

	function kit.equal(actual, expected, label)
		if actual ~= expected then
			error(`{label or "equal"}: expected {show(expected)}, got {show(actual)}`, 2)
		end
	end

	function kit.deepEqual(actual, expected, label)
		if not deepEqual(actual, expected) then
			error(`{label or "deepEqual"}: expected {show(expected)}, got {show(actual)}`, 2)
		end
	end

	function kit.truthy(value, label)
		if not value then
			error(`{label or "truthy"}: got {show(value)}`, 2)
		end
	end

	function kit.falsy(value, label)
		if value then
			error(`{label or "falsy"}: got {show(value)}`, 2)
		end
	end

	function kit.contains(text, fragment, label)
		if type(text) ~= "string" or not string.find(text, fragment, 1, true) then
			error(`{label or "contains"}: expected {show(text)} to contain {show(fragment)}`, 2)
		end
	end

	function kit.errors(fn, fragment)
		local ok, err = pcall(fn :: any)
		if ok then
			error("expected an error", 2)
		end
		if fragment and not string.find(tostring(err), fragment, 1, true) then
			error(`error {show(tostring(err))} does not contain {show(fragment)}`, 2)
		end
	end

	return kit
end

return TestKit
