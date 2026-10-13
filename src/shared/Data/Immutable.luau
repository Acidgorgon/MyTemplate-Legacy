--!strict
-- Copy / freeze / structural sharing for player data snapshots.
--
-- Snapshots handed out by PlayerDataService are deep-frozen. An update copies the
-- snapshot into a plain mutable draft, lets the caller edit it (table.insert and
-- friends work, unlike proxy drafts), then Share() rebuilds a frozen snapshot that
-- reuses every unchanged subtable of the old one. Reused subtables keep the same
-- reference, so `new.Inventory == old.Inventory` means "Inventory did not change"
-- and charm-sync's diff skips it.
--
-- Pure Luau: no Roblox services.

local Immutable = {}

-- Plain, unfrozen deep copy. Metatables are not copied.
function Immutable.DeepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value :: any
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = Immutable.DeepCopy(child)
	end
	return copy :: any
end

-- Freezes `value` and every table inside it, in place. Already-frozen tables are
-- assumed to be deep-frozen and skipped.
function Immutable.DeepFreeze<T>(value: T): T
	if type(value) ~= "table" or table.isfrozen(value :: any) then
		return value :: any
	end
	for _, child in value :: any do
		Immutable.DeepFreeze(child)
	end
	table.freeze(value :: any)
	return value :: any
end

function Immutable.DeepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not Immutable.DeepEqual(value, b[key]) then
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

-- Returns a deep-frozen version of `new` that reuses `old`'s subtables wherever the
-- contents are equal. Returns `old` itself when nothing changed.
-- `new` must be a draft (fresh tables owned by the caller); it is frozen in place.
function Immutable.Share(old: any, new: any): any
	if old == new or type(new) ~= "table" then
		return new
	end
	if type(old) ~= "table" then
		return Immutable.DeepFreeze(new)
	end
	if table.isfrozen(new) then
		-- An existing snapshot was assigned into the draft; it is already frozen.
		return if Immutable.DeepEqual(old, new) then old else new
	end

	local same = true
	for key, value in new do
		local shared = Immutable.Share(old[key], value)
		if shared ~= value then
			new[key] = shared
		end
		if shared ~= old[key] then
			same = false
		end
	end
	if same then
		for key in old do
			if new[key] == nil then
				same = false
				break
			end
		end
	end

	if same then
		return old
	end
	table.freeze(new)
	return new
end

return Immutable
