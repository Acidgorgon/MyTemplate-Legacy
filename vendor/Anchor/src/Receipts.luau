--!nonstrict
--[[
	Anchor / Receipts - exactly-once developer product grants (docs/design/spec.md section 4).

	USAGE (one line, for a store managed by Data:Bind()):
		Data:HandleReceipts({
			[123456] = function(data) data.Coins += 100 end,     -- by ProductId
			[654321] = function(data, info, player) data.Gems += 10 end,
		})
		-- or one function for every product:
		Data:HandleReceipts(function(data, info, player) ... end)

	Or call it from your own MarketplaceService.ProcessReceipt:
		return Data:ProcessReceipt(receiptInfo, function(data, info, player) ... end)

	Rules:
	  * The grant runs on a copy of the player's data. Its changes are applied (through the
	    Ripple state if UseRipple is on) together with the PurchaseId in a dedup ledger
	    (MetaData.Anchor.Receipts: every unconfirmed id, plus the newest 100 confirmed ones;
	    an id is "confirmed" only once PurchaseGranted was actually returned for it, a flag
	    persisted in MetaData.Anchor.ReceiptsAck) in the same tick, then the profile is
	    force-saved. PurchaseGranted is returned only after a save containing the PurchaseId
	    succeeded; otherwise NotProcessedYet and Roblox retries later.
	  * A retried / duplicate receipt whose id is in the ledger is never granted again.
	  * grant erroring or returning false -> NotProcessedYet, nothing changed. (Return false
	    for products this handler doesn't know.)
	  * The player must be in this server with their profile loaded; otherwise
	    NotProcessedYet (Roblox delivers it again when they join).
--]]

local LEDGER_SIZE = 100

local Receipts = {}

function Receipts.install(Anchor, Core)
	local Patch = require(script.Parent.Patch)
	local Players = game:GetService("Players")

	local function decision(name)
		local ok, item = pcall(function()
			return (Enum :: any).ProductPurchaseDecision[name]
		end)
		return if ok and item ~= nil then item else name
	end

	local function report(profile, message)
		local store_name = profile.ProfileStore.Name
		warn(`[Anchor]: {message} (STORE:{store_name}; KEY:{tostring(profile.Key)})`)
		Anchor.OnError:Fire(message, store_name, profile.Key)
	end

	local function savedSet(profile)
		local saved = rawget(profile, "_anchor_receipts_saved")
		if saved == nil then
			saved = {}
			rawset(profile, "_anchor_receipts_saved", saved)
		end
		return saved
	end

	local function inLedger(profile, id): boolean
		local ledger = profile.anchor_meta.Receipts
		return type(ledger) == "table" and table.find(ledger, id) ~= nil
	end

	Core.AddHook("Loaded", function(profile)
		local ledger = profile.anchor_meta.Receipts
		if type(ledger) == "table" then
			local saved = savedSet(profile)
			for _, id in ipairs(ledger) do
				saved[id] = true
			end
		end
	end)

	Core.AddHook("AfterSave", function(profile, wrote, raw)
		if wrote ~= true or type(raw) ~= "table" or type(raw.MetaData) ~= "table" then
			return
		end
		local stored = raw.MetaData.Anchor
		local ledger = type(stored) == "table" and stored.Receipts or nil
		if type(ledger) == "table" then
			local saved = savedSet(profile)
			for _, id in ipairs(ledger) do
				saved[id] = true
			end
		end
	end)

	local function findProfile(store, user_id)
		local player = Players:GetPlayerByUserId(user_id)
		if store.bind_state ~= nil then
			if player == nil then
				return nil, nil
			end
			local profile = store:Get(player)
			return profile, player
		end
		local key = (store.key_prefix or "Player_") .. tostring(user_id)
		return Core.GetActiveProfile(store, key, store.anchor_options.Mock == true), player
	end

	-- store:ProcessReceipt(receiptInfo, grant(data, receiptInfo, player) -> false?) -> Enum.ProductPurchaseDecision
	function Anchor:ProcessReceipt(info, grant)
		local NOT_YET = decision("NotProcessedYet")
		local GRANTED = decision("PurchaseGranted")
		if type(self) ~= "table" or self.template == nil then
			error("[Anchor]: ProcessReceipt must be called on a store (Data:ProcessReceipt(info, grant))")
		end
		if type(info) ~= "table" and type(info) ~= "userdata" then
			return NOT_YET
		end
		local id = tostring(info.PurchaseId)
		local profile, player = findProfile(self, info.PlayerId)
		if profile == nil or not profile:IsActive() or profile.view_mode == true then
			return NOT_YET
		end

		-- Marks id "confirmed": PurchaseGranted is being returned for it right now. Only
		-- confirmed ids may ever be trimmed from the ledger (persisted with the next save).
		local function acknowledge()
			local acks = profile.anchor_meta.ReceiptsAck
			if type(acks) ~= "table" then
				acks = {}
				profile.anchor_meta.ReceiptsAck = acks
			end
			if acks[id] ~= true then
				acks[id] = true
				profile:MarkMetaDirty()
			end
			return GRANTED
		end

		local function confirm()
			if savedSet(profile)[id] == true then
				return acknowledge()
			end
			if profile:SaveAsync() == true then
				savedSet(profile)[id] = true
				return acknowledge()
			end
			return NOT_YET
		end

		if inLedger(profile, id) then
			return confirm() -- already granted: never grant twice
		end

		local base = Patch.deepCopy(profile.Data)
		local draft = Patch.deepCopy(base)
		local ok, result = pcall(grant, draft, info, player)
		if ok == false then
			report(profile, `Receipt {id} grant errored: {tostring(result)}`)
			return NOT_YET
		end
		if result == false then
			return NOT_YET
		end
		local patch = Patch.diff(base, draft)
		local ok_patch, problem = Patch.check(patch)
		if ok_patch ~= true then
			report(profile, `Receipt {id} grant produced unsavable data ({tostring(problem)})`)
			return NOT_YET
		end

		-- Same tick: the grant and its ledger entry (re-checked: grant may have yielded).
		if not profile:IsActive() then
			return NOT_YET
		end
		if inLedger(profile, id) then
			return confirm()
		end
		Patch.apply(profile.Data, patch, rawget(profile, "_anchor_live"), function(message)
			report(profile, message)
		end)
		local ledger = profile.anchor_meta.Receipts
		if type(ledger) ~= "table" then
			ledger = {}
			profile.anchor_meta.Receipts = ledger
		end
		table.insert(ledger, id)
		-- Trim only confirmed ids (PurchaseGranted was returned for them), oldest first,
		-- keeping the newest LEDGER_SIZE; an unconfirmed id is never dropped, however old,
		-- because Roblox may still retry it.
		local acks = profile.anchor_meta.ReceiptsAck
		if type(acks) == "table" then
			local excess = #ledger - LEDGER_SIZE
			local i = 1
			while excess > 0 and i <= #ledger do
				local old_id = ledger[i]
				if acks[old_id] == true then
					table.remove(ledger, i)
					acks[old_id] = nil
					excess -= 1
				else
					i += 1
				end
			end
		end
		profile:MarkMetaDirty()

		return confirm()
	end

	-- store:HandleReceipts(grant | {[ProductId] = grant}) sets MarketplaceService.ProcessReceipt.
	function Anchor:HandleReceipts(handlers)
		if type(handlers) ~= "function" and type(handlers) ~= "table" then
			error("[Anchor]: HandleReceipts needs a function or a {[ProductId] = function} table")
		end
		local store = self
		local grant = handlers
		if type(handlers) == "table" then
			grant = function(data, info, player)
				local fn = handlers[info.ProductId]
				if fn == nil then
					warn(`[Anchor]: No receipt handler for ProductId {tostring(info.ProductId)}`)
					return false
				end
				return fn(data, info, player)
			end
		end
		local MarketplaceService = game:GetService("MarketplaceService")
		MarketplaceService.ProcessReceipt = function(info)
			return store:ProcessReceipt(info, grant)
		end
		return self
	end
end

return Receipts
