-- Runs every spec. From the repo root:
--   lune run tests/run.luau
--   luau tests/run.luau
-- Exits non-zero (by erroring) when a test fails.

local TestKit = require("./TestKit")

local specs = {
	Validate = require("./Validate.spec"),
	Immutable = require("./Immutable.spec"),
	Migrations = require("./Migrations.spec"),
	PlayerDataCore = require("./PlayerDataCore.spec"),
	Schema = require("./Schema.spec"),
	SyncFilter = require("./SyncFilter.spec"),
	ReceiptProcessor = require("./ReceiptProcessor.spec"),
}

local names = {}
for name in specs do
	table.insert(names, name)
end
table.sort(names)

local result: TestKit.Result = { passed = 0, failed = {} }
for _, name in names do
	specs[name](TestKit.new(name, result))
end

for _, failure in result.failed do
	print("FAIL " .. failure)
end
print(`{result.passed} passed, {#result.failed} failed`)

if #result.failed > 0 then
	error(`{#result.failed} test(s) failed`, 0)
end
