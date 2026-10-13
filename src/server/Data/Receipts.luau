--!strict
-- The one and only MarketplaceService.ProcessReceipt. Do not set ProcessReceipt
-- anywhere else; register a handler per developer product instead:
--
--   local Receipts = require(ServerScriptService.Server.Data.Receipts)
--
--   Receipts.Register(1234567, function(draft, receipt, player)
--   	draft.Coins += 500
--   end)
--
-- Grant edits the player's data draft only and must not yield. It runs inside
-- PlayerDataService:Update together with recording the PurchaseId, so the grant and
-- the "already granted" mark commit (and save) together or not at all.
-- For effects outside the data (a sound, a chat message) pass AfterGrant; it runs
-- once, after the grant is committed. PurchaseGranted is returned to Roblox only
-- after a DataStore save containing the PurchaseId has landed.
-- Flow details: ReceiptProcessor.luau.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Schema = require(ReplicatedStorage.Shared.Data.Schema)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ReceiptProcessor = require(script.Parent.ReceiptProcessor)

export type ReceiptInfo = ReceiptProcessor.ReceiptInfo
export type Grant = (draft: Schema.PlayerData, receipt: ReceiptInfo, player: Player) -> ()
export type AfterGrant = (receipt: ReceiptInfo, player: Player) -> ()

local handlers: { [number]: ReceiptProcessor.Handler } = {}
local started = false

local Receipts = {}
Receipts.Priority = 90

function Receipts.Register(productId: number, grant: Grant, afterGrant: AfterGrant?)
	assert(type(productId) == "number", "Receipts.Register: productId must be a number")
	assert(handlers[productId] == nil, `Receipts.Register: product {productId} already has a handler`)
	handlers[productId] = {
		Grant = grant :: any,
		AfterGrant = afterGrant :: any,
	}
end

local deps: ReceiptProcessor.Deps = {
	GetPlayer = function(userId)
		return Players:GetPlayerByUserId(userId)
	end,
	WaitForData = function(player)
		return PlayerDataService:WaitForData(player) :: any
	end,
	GetHandler = function(productId)
		return handlers[productId]
	end,
	Update = function(player, fn)
		return PlayerDataService:TryUpdate(player, fn)
	end,
	WaitForSave = function(player, check)
		return PlayerDataService:WaitForSave(player, check)
	end,
	Warn = function(message)
		warn(message)
	end,
	MaxPurchaseIds = Schema.MaxPurchaseIds,
}

local function processReceipt(info: ReceiptInfo): Enum.ProductPurchaseDecision
	local ok, decision = pcall(ReceiptProcessor.Process, info, deps)
	if not ok then
		warn(`[Receipts] error processing purchase {info.PurchaseId}: {decision}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if decision == "Granted" then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function Receipts.Init(_self: typeof(Receipts), _janitor: any?) end

function Receipts.Start(_self: typeof(Receipts))
	if started then
		return
	end
	started = true
	MarketplaceService.ProcessReceipt = processReceipt :: any
end

return Receipts
