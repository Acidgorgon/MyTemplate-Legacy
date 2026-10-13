local SyncFilter = require("../src/server/Data/SyncFilter")

local NONE = { __none = "__none" }

return function(t)
	t.test("init keeps only the player's own private entry", function()
		local payload = {
			type = "init",
			data = {
				Private = { ["1"] = { Coins = 1 }, ["2"] = { Coins = 2 } },
				Public = { ["1"] = { Level = 1 }, ["2"] = { Level = 5 } },
			},
		}
		local out = SyncFilter.ForPlayer(payload, "1")
		t.equal(out.type, "init")
		t.deepEqual(out.data.Private, { ["1"] = { Coins = 1 } })
		t.deepEqual(out.data.Public, payload.data.Public)
		t.equal(payload.data.Private["2"].Coins, 2, "shared payload untouched")
	end)

	t.test("init for a player without data still hydrates", function()
		local out = SyncFilter.ForPlayer({ type = "init", data = { Private = { ["2"] = {} }, Public = {} } }, "1")
		t.deepEqual(out, { type = "init", data = { Private = {}, Public = {} } })
	end)

	t.test("patch about someone else is dropped", function()
		local out = SyncFilter.ForPlayer({ type = "patch", data = { Private = { ["2"] = { Coins = 9 } } } }, "1")
		t.equal(out, nil)
	end)

	t.test("patch about the player passes, with public changes", function()
		local out = SyncFilter.ForPlayer({
			type = "patch",
			data = {
				Private = { ["1"] = { Coins = 3 }, ["2"] = { Coins = 9 } },
				Public = { ["2"] = { Level = 6 } },
			},
		}, "1")
		t.deepEqual(out.data.Private, { ["1"] = { Coins = 3 } })
		t.deepEqual(out.data.Public, { ["2"] = { Level = 6 } })
	end)

	t.test("public-only patch reaches everyone", function()
		local out = SyncFilter.ForPlayer({ type = "patch", data = { Public = { ["2"] = NONE } } }, "1")
		t.deepEqual(out.data, { Public = { ["2"] = NONE } })
	end)

	t.test("removal of the player's own entry passes through", function()
		local out = SyncFilter.ForPlayer({ type = "patch", data = { Private = { ["1"] = NONE } } }, "1")
		t.equal(out.data.Private["1"], NONE)
	end)
end
