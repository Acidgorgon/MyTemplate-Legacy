--!strict
-- Player data schema: the type, the defaults and the rules, in one place.
--
-- Adding a field:
--   1. Add it to the PlayerData type.
--   2. Add its default to Template.
--   3. Add its rule to Validator.
--   4. Numeric top-level field that Increment should accept? Add it to NumericField
--      and NumericFields.
-- New fields reach old saves automatically (missing keys are filled from Template).
-- Renaming, moving or changing the meaning of a field needs a migration instead:
-- bump Version and add the step in src/server/Data/Migrations.luau.
--
-- Feature slices: a feature can own its part of the schema and Schema just plugs it in.
--
--   -- src/shared/Features/Inventory/init.luau
--   local V = require(ReplicatedStorage.Shared.Data.Validate)
--
--   local Inventory = {}
--
--   export type Stack = { Id: string, Count: number }
--   export type Data = { Items: { Stack }, Equipped: string }
--
--   Inventory.MaxItems = 200
--   Inventory.DataTemplate = { Items = {}, Equipped = "" } :: Data
--   Inventory.DataValidator = V.Record({
--   	Items = V.Array(V.Record({ Id = V.String(64, 1), Count = V.Integer(1, 9999) }), Inventory.MaxItems),
--   	Equipped = V.String(64),
--   })
--
--   return Inventory
--
--   -- here in Schema (require the feature with require("../Features/Inventory")):
--   --   PlayerData type:  Inventory: Inventory.Data,
--   --   Template:         Inventory = Inventory.DataTemplate,
--   --   Validator:        Inventory = Inventory.DataValidator,
--
-- Pure Luau (string requires only), so tests/ can load it under Lune.

local Immutable = require("./Immutable")
local Validate = require("./Validate")

local V = Validate

export type ItemStack = {
	Id: string,
	Count: number,
}

export type Quality = "Low" | "Medium" | "High"

export type PlayerData = {
	-- Managed by PlayerDataService; do not write it yourself.
	DataVersion: number,

	Coins: number,
	Gems: number,
	Level: number,
	Experience: number,

	Inventory: {
		Items: { ItemStack },
		Equipped: string,
	},

	Settings: {
		MusicVolume: number,
		SfxVolume: number,
		Quality: Quality,
	},

	Stats: {
		Joins: number,
		TimePlayed: number,
	},

	-- Last purchase ids granted by Receipts (oldest first). Stops double grants.
	PurchaseIds: { string },
}

-- Top-level numeric fields. PlayerDataService:Increment only takes these keys.
export type NumericField = "Coins" | "Gems" | "Level" | "Experience"

-- The part of a player's data every other client can see (e.g. for name tags).
export type PublicData = {
	Level: number,
}

local Schema = {}

-- Bump when a saved profile needs a migration to match this file.
Schema.Version = 1

Schema.VersionKey = "DataVersion"
Schema.MaxItems = 200
Schema.MaxPurchaseIds = 100

-- 2^53: past this, numbers stop being exact integers.
local MAX_SAFE = 9007199254740991

local template: PlayerData = {
	DataVersion = Schema.Version,

	Coins = 0,
	Gems = 0,
	Level = 1,
	Experience = 0,

	Inventory = {
		Items = {},
		Equipped = "",
	},

	Settings = {
		MusicVolume = 0.5,
		SfxVolume = 0.5,
		Quality = "High",
	},

	Stats = {
		Joins = 0,
		TimePlayed = 0,
	},

	PurchaseIds = {},
}

-- Defaults for a brand-new profile. Frozen: copy it before editing.
Schema.Template = Immutable.DeepFreeze(template)

Schema.Validator = V.Record({
	DataVersion = V.Integer(0),

	Coins = V.Integer(0, MAX_SAFE),
	Gems = V.Integer(0, MAX_SAFE),
	Level = V.Integer(1, 1000),
	Experience = V.Integer(0, MAX_SAFE),

	Inventory = V.Record({
		Items = V.Array(
			V.Record({
				Id = V.String(64, 1),
				Count = V.Integer(1, 9999),
			}),
			Schema.MaxItems
		),
		Equipped = V.String(64),
	}),

	Settings = V.Record({
		MusicVolume = V.Number(0, 1),
		SfxVolume = V.Number(0, 1),
		Quality = V.Enum({ "Low", "Medium", "High" }),
	}),

	Stats = V.Record({
		Joins = V.Integer(0),
		TimePlayed = V.Number(0),
	}),

	PurchaseIds = V.Array(V.String(128, 1), Schema.MaxPurchaseIds),
})

Schema.NumericFields = table.freeze({
	Coins = true,
	Gems = true,
	Level = true,
	Experience = true,
}) :: { [NumericField]: true }

-- Build the public view of a player's data. Only what is returned here leaves the
-- server for other players.
function Schema.ToPublic(data: PlayerData): PublicData
	return {
		Level = data.Level,
	}
end

return Schema
