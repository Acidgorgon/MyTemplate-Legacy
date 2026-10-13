-- Starts player data before anything else on the server needs it.
-- Other server code requires the modules under this script:
--   require(ServerScriptService.Server.Data.PlayerDataService)
--   require(ServerScriptService.Server.Data.Receipts)
-- Init and Start are idempotent, so a loader that also finds these modules is fine.

local PlayerDataService = require(script.PlayerDataService)
local Receipts = require(script.Receipts)

PlayerDataService:Init()
Receipts:Init()

PlayerDataService:Start()
Receipts:Start()
