local Migrations = require("../src/server/Data/Migrations")
local Schema = require("../src/shared/Data/Schema")

return function(t)
	t.test("shipped list covers every version up to Schema.Version", function()
		for version = 1, Schema.Version do
			t.truthy(Migrations.List[version], `missing migration {version}`)
		end
		local data = { Coins = 5 }
		local ok, err = Migrations.Run(data, 0, Schema.Version, "DataVersion")
		t.truthy(ok, err)
		t.equal(data.DataVersion, Schema.Version)
		t.equal(data.Coins, 5)
	end)

	t.test("runs steps in order and stamps each version", function()
		local seen = {}
		local list = {
			function(data)
				table.insert(seen, data.DataVersion or 0)
				data.Gold = 10
			end,
			function(data)
				table.insert(seen, data.DataVersion)
				data.Coins = data.Gold
				data.Gold = nil
			end,
			function(data)
				table.insert(seen, data.DataVersion)
				data.Coins *= 2
			end,
		}
		local data = {}
		local ok = Migrations.Run(data, 0, 3, "DataVersion", list)
		t.truthy(ok)
		t.deepEqual(seen, { 0, 1, 2 })
		t.deepEqual(data, { Coins = 20, DataVersion = 3 })
	end)

	t.test("starts from the saved version", function()
		local ran = {}
		local list = {
			function()
				table.insert(ran, 1)
			end,
			function()
				table.insert(ran, 2)
			end,
		}
		local data = { DataVersion = 1 }
		t.truthy(Migrations.Run(data, 1, 2, "DataVersion", list))
		t.deepEqual(ran, { 2 })
	end)

	t.test("same version is a no-op", function()
		local data = { DataVersion = 2, X = 1 }
		t.truthy(Migrations.Run(data, 2, 2, "DataVersion", {}))
		t.deepEqual(data, { DataVersion = 2, X = 1 })
	end)

	t.test("refuses data newer than the server", function()
		local ok, err = Migrations.Run({}, 3, 2, "DataVersion", {})
		t.falsy(ok)
		t.contains(err, "only knows up to version 2")
	end)

	t.test("reports a missing step", function()
		local ok, err = Migrations.Run({}, 0, 2, "DataVersion", { function() end })
		t.falsy(ok)
		t.contains(err, "no migration to version 2")
	end)

	t.test("reports a failing step and stops", function()
		local ranThird = false
		local list = {
			function() end,
			function()
				error("boom")
			end,
			function()
				ranThird = true
			end,
		}
		local data = {}
		local ok, err = Migrations.Run(data, 0, 3, "DataVersion", list)
		t.falsy(ok)
		t.contains(err, "migration to version 2 failed")
		t.contains(err, "boom")
		t.falsy(ranThird)
		t.equal(data.DataVersion, 1)
	end)
end
