--!strict
-- Ordered player data migrations.
--
-- Migrations.List[n] upgrades a profile from version n - 1 to version n, editing
-- the table in place. Steps run in order on load, before missing fields are filled
-- from the template and before validation, so a step sees the old data as it was
-- saved (fields added since then are simply missing).
--
-- To change the shape of saved data:
--   1. Bump Schema.Version (say to 2) and update the PlayerData type, Template and Validator.
--   2. Add List[2] below. Never edit or remove a step that has shipped.
--
--   [2] = function(data)
--   	-- v1 stored "Gold"; v2 calls it "Coins".
--   	if data.Gold ~= nil then
--   		data.Coins = data.Gold
--   		data.Gold = nil
--   	end
--   end,
--
-- A step that errors stops the load: the player is kicked with a message and their
-- saved data is left untouched. Pure Luau: no Roblox services.

export type Data = { [string]: any }
export type Migration = (data: Data) -> ()

local Migrations = {}

Migrations.List = {
	-- 0 -> 1: profiles saved before versioning existed. Nothing to change; the
	-- template fill and validation that follow handle missing or bad fields.
	[1] = function(_data: Data) end,
} :: { Migration }

-- Runs list[from + 1] .. list[to] on `data` in place and stamps the version after
-- each step. Returns false and a message when a step is missing or errors, or when
-- the data is newer than this server knows about.
function Migrations.Run(
	data: Data,
	from: number,
	to: number,
	versionKey: string,
	list: { Migration }?
): (boolean, string?)
	local steps = list or Migrations.List

	if from > to then
		return false, `data is version {from} but this server only knows up to version {to}`
	end

	for version = from + 1, to do
		local step = steps[version]
		if step == nil then
			return false, `no migration to version {version}`
		end
		local ok, err = pcall(step :: any, data)
		if not ok then
			return false, `migration to version {version} failed: {err}`
		end
		data[versionKey] = version
	end

	return true, nil
end

return Migrations
