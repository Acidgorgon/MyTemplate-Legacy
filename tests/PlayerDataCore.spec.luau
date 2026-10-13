-- Update / validate / commit and the load pipeline, against an in-memory fake store.
local Migrations = require("../src/server/Data/Migrations")
local PlayerDataCore = require("../src/shared/Data/PlayerDataCore")
local Schema = require("../src/shared/Data/Schema")

-- Stands in for DataService + ProfileStore: keeps the "saved" profile table per key
-- and mirrors changed top-level keys into it, like PlayerDataService does.
local function newFakeStore(migrations)
	local store = { profiles = {}, changes = {} }
	store.core = PlayerDataCore.new({
		Template = Schema.Template,
		Version = Schema.Version,
		VersionKey = Schema.VersionKey,
		Validator = Schema.Validator,
		Migrate = function(data, from)
			return Migrations.Run(data, from, Schema.Version, Schema.VersionKey, migrations)
		end,
		OnChanged = function(key, new, old, changed)
			table.insert(store.changes, { key = key, new = new, old = old, changed = changed })
			local profile = store.profiles[key]
			for _, field in changed do
				profile[field] = new[field]
			end
		end,
	})
	function store.join(key, saved)
		store.profiles[key] = saved or {}
		local result = store.core:Load(store.profiles[key])
		if result.Ok then
			store.core:Open(key, result.Data)
			table.clear(store.profiles[key])
			for field, value in result.Data do
				store.profiles[key][field] = value
			end
		end
		return result
	end
	return store
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

return function(t)
	t.test("fresh profile gets the template", function()
		local store = newFakeStore()
		local result = store.join("p1")
		t.truthy(result.Ok)
		t.truthy(result.Fresh)
		t.deepEqual(store.core:Get("p1"), Schema.Template)
		t.truthy(table.isfrozen(store.core:Get("p1")))
		t.equal(#result.Repairs, 0)
	end)

	t.test("old save is migrated, then filled from the template", function()
		local store = newFakeStore()
		local result = store.join("p1", { Coins = 42 })
		t.truthy(result.Ok)
		t.equal(result.MigratedFrom, 0)
		local data = store.core:Get("p1")
		t.equal(data.Coins, 42)
		t.equal(data.DataVersion, Schema.Version)
		t.deepEqual(data.Settings, Schema.Template.Settings)
		t.equal(#result.Repairs, 0)
	end)

	t.test("bad fields are repaired one by one and reported", function()
		local store = newFakeStore()
		local saved = copy(Schema.Template)
		saved.Coins = 0 / 0
		saved.Settings.Quality = "Ultra"
		saved.Inventory.Items = {
			{ Id = "Sword", Count = 1 },
			{ Id = "Bad", Count = 1.5 },
			{ Id = "Shield", Count = 2 },
		}
		local result = store.join("p1", saved)
		t.truthy(result.Ok)
		local data = store.core:Get("p1")
		t.equal(data.Coins, 0)
		t.equal(data.Settings.Quality, "High")
		t.equal(#data.Inventory.Items, 2)
		t.equal(data.Inventory.Items[2].Id, "Shield")
		t.equal(#result.Repairs, 3)
		local all = table.concat(result.Repairs, "\n")
		t.contains(all, "Inventory.Items[2].Count: expected integer, got 1.5 -> removed")
		t.contains(all, "Settings.Quality")
		t.contains(all, "Coins: expected integer, got NaN -> reset to default")
	end)

	t.test("over-long arrays are truncated, holes closed", function()
		local store = newFakeStore()
		local saved = copy(Schema.Template)
		saved.PurchaseIds = {}
		for i = 1, Schema.MaxPurchaseIds + 5 do
			saved.PurchaseIds[i] = `id{i}`
		end
		saved.Inventory.Items = { [1] = { Id = "A", Count = 1 }, [3] = { Id = "B", Count = 1 } }
		local result = store.join("p1", saved)
		local data = store.core:Get("p1")
		t.equal(#data.PurchaseIds, Schema.MaxPurchaseIds)
		t.equal(data.PurchaseIds[1], "id1")
		t.deepEqual(data.Inventory.Items, { { Id = "A", Count = 1 }, { Id = "B", Count = 1 } })
		t.equal(#result.Repairs, 2)
	end)

	t.test("a field of the wrong type is reset to its default", function()
		local store = newFakeStore()
		local saved = copy(Schema.Template)
		saved.Inventory = "oops"
		store.join("p1", saved)
		t.deepEqual(store.core:Get("p1").Inventory, Schema.Template.Inventory)
	end)

	t.test("data newer than the server is refused and left untouched", function()
		local store = newFakeStore()
		local saved = { DataVersion = Schema.Version + 1, Coins = 7 }
		local result = store.join("p1", saved)
		t.falsy(result.Ok)
		t.contains(result.Error, "only knows up to")
		t.equal(store.core:Get("p1"), nil)
		t.deepEqual(store.profiles.p1, { DataVersion = Schema.Version + 1, Coins = 7 })
	end)

	t.test("a failing migration refuses the load", function()
		local store = newFakeStore({
			function()
				error("bad step")
			end,
		})
		local result = store.join("p1", { Coins = 1 })
		t.falsy(result.Ok)
		t.contains(result.Error, "bad step")
	end)

	t.test("Update commits a valid change and reports changed keys", function()
		local store = newFakeStore()
		store.join("p1")
		local before = store.core:Get("p1")
		local ok, err = store.core:Update("p1", function(draft)
			draft.Coins += 100
			table.insert(draft.Inventory.Items, { Id = "Sword", Count = 1 })
		end)
		t.truthy(ok, err)
		local after = store.core:Get("p1")
		t.equal(after.Coins, 100)
		t.equal(before.Coins, 0, "old snapshot unchanged")
		t.equal(after.Settings, before.Settings, "unchanged subtable shared")
		t.truthy(table.isfrozen(after.Inventory.Items[1]))
		local change = store.changes[#store.changes]
		table.sort(change.changed)
		t.deepEqual(change.changed, { "Coins", "Inventory" })
		t.equal(change.old, before)
		t.equal(store.profiles.p1.Coins, 100, "mirrored into the store")
	end)

	t.test("Update rejects invalid results and keeps the old data", function()
		local store = newFakeStore()
		store.join("p1")
		local before = store.core:Get("p1")
		local changes = #store.changes
		local ok, err = store.core:Update("p1", function(draft)
			draft.Coins = -5
			draft.Gems = 10
		end)
		t.falsy(ok)
		t.contains(err, "Coins: must be >= 0")
		t.equal(store.core:Get("p1"), before)
		t.equal(#store.changes, changes, "no change event")
		t.equal(store.profiles.p1.Gems, 0)
	end)

	t.test("Update rejects a callback that errors", function()
		local store = newFakeStore()
		store.join("p1")
		local ok, err = store.core:Update("p1", function(draft)
			draft.Coins = 5
			error("nope")
		end)
		t.falsy(ok)
		t.contains(err, "nope")
		t.equal(store.core:Get("p1").Coins, 0)
	end)

	t.test("Update rejects a callback that yields", function()
		local store = newFakeStore()
		store.join("p1")
		local ok, err = store.core:Update("p1", function(draft)
			draft.Coins = 5
			coroutine.yield()
		end)
		t.falsy(ok)
		t.contains(err, "yield")
		t.equal(store.core:Get("p1").Coins, 0)
	end)

	t.test("Update rejects nested updates for the same key", function()
		local store = newFakeStore()
		store.join("p1")
		local innerOk, innerErr
		local ok = store.core:Update("p1", function(draft)
			innerOk, innerErr = store.core:Update("p1", function(inner)
				inner.Gems = 1
			end)
			draft.Coins = 1
		end)
		t.truthy(ok)
		t.falsy(innerOk)
		t.contains(innerErr, "inside another Update")
		t.equal(store.core:Get("p1").Coins, 1)
		t.equal(store.core:Get("p1").Gems, 0)
	end)

	t.test("Update cannot change the version", function()
		local store = newFakeStore()
		store.join("p1")
		local ok, err = store.core:Update("p1", function(draft)
			draft.DataVersion = 99
		end)
		t.falsy(ok)
		t.contains(err, "DataVersion")
	end)

	t.test("Update with no effective change fires nothing", function()
		local store = newFakeStore()
		store.join("p1")
		local before = store.core:Get("p1")
		local changes = #store.changes
		t.truthy(store.core:Update("p1", function(draft)
			draft.Coins = 0
		end))
		t.equal(store.core:Get("p1"), before)
		t.equal(#store.changes, changes)
	end)

	t.test("Update fails when not loaded", function()
		local store = newFakeStore()
		local ok, err = store.core:Update("nobody", function() end)
		t.falsy(ok)
		t.contains(err, "not loaded")
	end)

	t.test("Increment applies schema rules", function()
		local store = newFakeStore()
		store.join("p1")
		t.truthy(store.core:Increment("p1", "Coins", 50))
		t.equal(store.core:Get("p1").Coins, 50)
		local ok, err = store.core:Increment("p1", "Coins", -51)
		t.falsy(ok)
		t.contains(err, "must be >= 0")
		t.equal(store.core:Get("p1").Coins, 50)
		t.falsy(store.core:Increment("p1", "Coins", 0.5), "integer field")
		t.falsy(store.core:Increment("p1", "Coins", 0 / 0))
		t.falsy(store.core:Increment("p1", "Settings", 1))
	end)

	t.test("players are independent and Close drops the session", function()
		local store = newFakeStore()
		store.join("p1")
		store.join("p2")
		store.core:Increment("p1", "Gems", 3)
		t.equal(store.core:Get("p2").Gems, 0)
		store.core:Close("p1")
		t.equal(store.core:Get("p1"), nil)
		t.falsy(store.core:Increment("p1", "Gems", 1))
	end)

	t.test("saved profile round-trips through a rejoin", function()
		local store = newFakeStore()
		store.join("p1")
		store.core:Update("p1", function(draft)
			draft.Coins = 10
			table.insert(draft.Inventory.Items, { Id = "Sword", Count = 2 })
		end)
		local saved = copy(store.profiles.p1)
		store.core:Close("p1")
		local result = store.join("p1", saved)
		t.truthy(result.Ok)
		t.falsy(result.Fresh)
		t.equal(result.MigratedFrom, nil)
		t.equal(#result.Repairs, 0)
		t.equal(store.core:Get("p1").Coins, 10)
		t.equal(store.core:Get("p1").Inventory.Items[1].Id, "Sword")
	end)
end
