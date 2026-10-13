--!strict
-- The decision logic behind Receipts, with every Roblox call passed in so it can be
-- tested with fakes. See Receipts.luau for the real wiring.
--
-- For one receipt:
--   1. The buyer must be in this server with data loaded, else NotProcessedYet
--      (Roblox retries on their next join or purchase).
--   2. PurchaseId already in data.PurchaseIds -> already granted, skip to step 4.
--   3. One Update runs the product's Grant on the draft AND records the PurchaseId
--      (oldest dropped past MaxPurchaseIds). Validation applies, so a grant that would
--      break the schema is rejected and nothing is granted.
--   4. Wait until a DataStore save that contains the PurchaseId has landed, then
--      return Granted. If the session ends first, return NotProcessedYet: the change
--      was never saved, so the retry grants it once.
--
-- Pure Luau: no Roblox services.

export type Decision = "Granted" | "NotProcessedYet"

export type ReceiptInfo = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string,
	[string]: any,
}

export type Handler = {
	Grant: (draft: any, receipt: ReceiptInfo, player: any) -> (),
	AfterGrant: ((receipt: ReceiptInfo, player: any) -> ())?,
}

export type Deps = {
	GetPlayer: (userId: number) -> any?,
	-- Yields until loaded; nil when the player left or it timed out.
	WaitForData: (player: any) -> { [string]: any }?,
	GetHandler: (productId: number) -> Handler?,
	Update: (player: any, fn: (draft: any) -> ()) -> (boolean, string?),
	-- Yields until a save where check(savedData) is true; false if that cannot happen.
	WaitForSave: (player: any, check: (saved: { [string]: any }) -> boolean) -> boolean,
	Warn: (message: string) -> (),
	MaxPurchaseIds: number,
}

local ReceiptProcessor = {}

local function hasId(data: { [string]: any }?, purchaseId: string): boolean
	local ids = data and data.PurchaseIds
	return type(ids) == "table" and table.find(ids, purchaseId) ~= nil
end

function ReceiptProcessor.Process(info: ReceiptInfo, deps: Deps): Decision
	local player = deps.GetPlayer(info.PlayerId)
	if player == nil then
		return "NotProcessedYet"
	end

	local data = deps.WaitForData(player)
	if data == nil then
		return "NotProcessedYet"
	end

	local purchaseId = info.PurchaseId
	if not hasId(data, purchaseId) then
		local handler = deps.GetHandler(info.ProductId)
		if handler == nil then
			deps.Warn(
				`[Receipts] no handler registered for product {info.ProductId}; purchase {purchaseId} left pending`
			)
			return "NotProcessedYet"
		end

		local granted = false
		local ok, err = deps.Update(player, function(draft)
			-- Another receipt thread may have granted it since `data` was read.
			if table.find(draft.PurchaseIds, purchaseId) then
				return
			end
			handler.Grant(draft, info, player)
			table.insert(draft.PurchaseIds, purchaseId)
			while #draft.PurchaseIds > deps.MaxPurchaseIds do
				table.remove(draft.PurchaseIds, 1)
			end
			granted = true
		end)
		if not ok then
			deps.Warn(`[Receipts] product {info.ProductId} purchase {purchaseId} not granted: {err}`)
			return "NotProcessedYet"
		end

		if granted and handler.AfterGrant then
			local afterOk, afterErr = pcall(handler.AfterGrant :: any, info, player)
			if not afterOk then
				deps.Warn(`[Receipts] AfterGrant for product {info.ProductId} errored: {afterErr}`)
			end
		end
	end

	if deps.WaitForSave(player, function(saved)
		return hasId(saved, purchaseId)
	end) then
		return "Granted"
	end
	return "NotProcessedYet"
end

return ReceiptProcessor
