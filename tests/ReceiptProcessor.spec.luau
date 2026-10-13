-- Receipt flow against fakes for Players, PlayerDataService and ProfileStore saves.
local Migrations = require("../src/server/Data/Migrations")
local PlayerDataCore = require("../src/shared/Data/PlayerDataCore")
local ReceiptProcessor = require("../src/server/Data/ReceiptProcessor")
local Schema = require("../src/shared/Data/Schema")

local PRODUCT = 111

local function newWorld()
	local world = {
		players = {},
		handlers = {},
		warnings = {},
		saved = {},
		saveFails = false,
		afterGrants = 0,
	}
	world.core = PlayerDataCore.new({
		Template = Schema.Template,
		Version = Schema.Version,
		VersionKey = Schema.VersionKey,
		Validator = Schema.Validator,
		Migrate = function(data, from)
			return Migrations.Run(data, from, Schema.Version, Schema.VersionKey)
		end,
	})
	world.deps = {
		GetPlayer = function(userId)
			return world.players[userId]
		end,
		WaitForData = function(player)
			return world.core:Get(player)
		end,
		GetHandler = function(productId)
			return world.handlers[productId]
		end,
		Update = function(player, fn)
			local ok, err = world.core:Update(player, fn)
			return ok, err
		end,
		WaitForSave = function(player, check)
			if world.saveFails then
				return false
			end
			-- A save writes the current data.
			world.saved[player] = world.core:Get(player)
			return check(world.saved[player])
		end,
		Warn = function(message)
			table.insert(world.warnings, message)
		end,
		MaxPurchaseIds = 3,
	}
	function world.join(userId)
		local player = { UserId = userId }
		world.players[userId] = player
		world.core:Open(player, world.core:Load({}).Data)
		return player
	end
	world.handlers[PRODUCT] = {
		Grant = function(draft)
			draft.Coins += 100
		end,
		AfterGrant = function()
			world.afterGrants += 1
		end,
	}
	return world
end

local function receipt(id, product)
	return { PlayerId = 1, ProductId = product or PRODUCT, PurchaseId = id }
end

return function(t)
	t.test("grants once, records the id, waits for the save", function()
		local world = newWorld()
		local player = world.join(1)
		t.equal(ReceiptProcessor.Process(receipt("a"), world.deps), "Granted")
		local data = world.core:Get(player)
		t.equal(data.Coins, 100)
		t.deepEqual(data.PurchaseIds, { "a" })
		t.equal(world.afterGrants, 1)
	end)

	t.test("a retried receipt is not granted twice", function()
		local world = newWorld()
		local player = world.join(1)
		ReceiptProcessor.Process(receipt("a"), world.deps)
		t.equal(ReceiptProcessor.Process(receipt("a"), world.deps), "Granted")
		t.equal(world.core:Get(player).Coins, 100)
		t.equal(world.afterGrants, 1)
	end)

	t.test("buyer not in the server -> NotProcessedYet", function()
		local world = newWorld()
		t.equal(ReceiptProcessor.Process(receipt("a"), world.deps), "NotProcessedYet")
	end)

	t.test("unknown product -> NotProcessedYet with a warning", function()
		local world = newWorld()
		local player = world.join(1)
		t.equal(ReceiptProcessor.Process(receipt("a", 999), world.deps), "NotProcessedYet")
		t.equal(#world.core:Get(player).PurchaseIds, 0)
		t.contains(world.warnings[1], "no handler")
	end)

	t.test("a grant that breaks the schema is rejected whole", function()
		local world = newWorld()
		local player = world.join(1)
		world.handlers[PRODUCT].Grant = function(draft)
			draft.Coins = -1
		end
		t.equal(ReceiptProcessor.Process(receipt("a"), world.deps), "NotProcessedYet")
		local data = world.core:Get(player)
		t.equal(data.Coins, 0)
		t.equal(#data.PurchaseIds, 0, "id not recorded either")
		t.equal(world.afterGrants, 0)
	end)

	t.test("a grant that errors grants nothing", function()
		local world = newWorld()
		local player = world.join(1)
		world.handlers[PRODUCT].Grant = function()
			error("broken handler")
		end
		t.equal(ReceiptProcessor.Process(receipt("a"), world.deps), "NotProcessedYet")
		t.equal(#world.core:Get(player).PurchaseIds, 0)
		t.contains(world.warnings[1], "broken handler")
	end)

	t.test("unsaved grant -> NotProcessedYet; the retry does not grant again", function()
		local world = newWorld()
		local player = world.join(1)
		world.saveFails = true
		t.equal(ReceiptProcessor.Process(receipt("a"), world.deps), "NotProcessedYet")
		t.equal(world.core:Get(player).Coins, 100)
		world.saveFails = false
		t.equal(ReceiptProcessor.Process(receipt("a"), world.deps), "Granted")
		t.equal(world.core:Get(player).Coins, 100)
	end)

	t.test("purchase id ring keeps the newest ids", function()
		local world = newWorld()
		local player = world.join(1)
		for _, id in { "a", "b", "c", "d" } do
			t.equal(ReceiptProcessor.Process(receipt(id), world.deps), "Granted")
		end
		local data = world.core:Get(player)
		t.deepEqual(data.PurchaseIds, { "b", "c", "d" })
		t.equal(data.Coins, 400)
	end)
end
