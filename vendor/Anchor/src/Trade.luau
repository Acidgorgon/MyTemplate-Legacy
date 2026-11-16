--!nonstrict
--[[
	Anchor / Trade - two-phase escrow trades and exactly-once gifts (docs/SPEC.md section 4).

	USAGE
		local ok, reason = Anchor.Trade(Data:Get(a), Data:Get(b), function(da, db)
			if da.Coins < 100 or db.Items.Gem == nil then
				return false                    -- cancel: nothing changes
			end
			da.Coins -= 100; db.Coins += 100
			da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
		end)

		Data:Gift(userId, function(data) data.Coins += 50 end)   -- online anywhere or offline

	RESULT (what the game should show)
		true                    Committed: both sides have their new data now (a side that left
		                        mid-trade gets its incoming items when it next loads).
		false, "Cancelled"      fn returned false. Nothing changed.
		false, "Error", msg     fn (or the trade) errored. Nothing changed.
		false, "Invalid", msg   Bad arguments, same profile twice, view-mode profile, or the drafts
		                        hold values a DataStore can't store. Nothing changed.
		false, "Inactive"       A or B is not loaded on this server. Nothing changed.
		false, "Busy"           Another trade on A or B did not finish within opts.Timeout (30 s).
		false, "TooBig"         A side would exceed the DataStore's 4 MB value limit. Nothing changed.
		false, "SaveFailed"     An escrow save failed; the trade was aborted and refunded.
		false, "SessionLost"    A side left / lost its session before its escrow saved; aborted.
		false, "Aborted"        Another server resolved the trade first (it aborted); refunded.
		false, "Pending"        The decision key could not be reached. Traded items stay in escrow
		                        (unspendable) and the trade resolves itself (commit or refund) as
		                        soon as the key is reachable. Show "Trade pending".
		Every abort refunds both sides. Nothing is ever duplicated or lost.

	PROTOCOL (two-phase escrow, one neutral decision key per trade)
		1. ONE tick, no yield: fn(draftA, draftB) on copies; diff -> each side's patch split into
		   OUTGOING (Remove, Pull, negative Inc; a Set that replaces an existing value also
		   escrows it as Remove(path), refund Set(path, old)) and INCOMING (Set, Push, positive
		   Inc). Outgoing
		   is applied to both live profiles immediately and each side gets
		   MetaData.Anchor.Tx[id] = {role, refund = inverse of outgoing, incoming, peer, t}.
		   From here the traded items can't be spent, and every save of either side (autosave,
		   release on leave, shutdown) carries the escrow.
		2. Save A and B in parallel (2 tries each). Both landed -> "commit", else "abort".
		3. The decision: UpdateAsync on DataStore "AnchorTx", key "tx_<id>": first writer wins
		   (empty -> write mine, else adopt the stored one). This is the single commit point.
		4. Each side still loaded here: commit -> apply incoming, abort -> apply refund, and
		   drop its Tx record in the SAME tick; then save. A record present == unresolved, so
		   resolution is idempotent (no applied-id sets, nothing to prune).
		5. Recovery: a profile that loads with a Tx record resolves it through step 3 with
		   "abort" as its proposal (safe: "commit" is only ever written after both escrows
		   landed). If the key can't be reached the record stays (items stay escrowed),
		   OnError fires, and it retries with backoff; it never guesses.
		6. Before step 1's tick ends nothing is written; if either side's escrow or committed
		   size estimate exceeds the limit the trade is refused ("TooBig"). Resolution onto
		   changed data: missing parents are recreated; an Inc onto a non-number (or a write
		   below a non-table, or a Set onto a non-nil, different value) is never forced: the
		   record is kept, OnError says NEEDS MANUAL REVIEW, and store:PendingTrades(profile)
		   lists it. A Set onto an equal value counts as applied.

	While a trade commits, profile:IsTrading() is true and Data:Update(player, fn) waits for
	it. Direct writes to profile.Data in that window (~1-2 saves) can still race.

	Gifts ride the profile's message queue: the patch is applied when the owner processes the
	message, and the stock "processed" removal lands in the same save as the data, so each
	message applies exactly once. Each gift also carries an internal id; the receiver keeps
	the last GIFT_RING (1000) applied ids in MetaData.Anchor.Gifts (count-bounded, never
	time-pruned) and skips a redelivered id. Gift patches never recreate a parent the player no longer
	has (a sold pet doesn't come back as a stub) unless the template defines it.

	Live proxies: opts.Live = {liveA, liveB} (Ripple states wrapping profile.Data in place),
	or the states from store:UseRipple(). A proxy write that errors is written to the plain
	table instead and Anchor.OnError fires.
--]]

local TX_LOCK_TIMEOUT = 30
local ESCROW_SAVE_ATTEMPTS = 2
local DECISION_STORE = "AnchorTx"
local DECISION_WAIT = 10 -- (Seconds) Trade waits this long for the decision key before "Pending"
local RETRY_MAX = 60
local SIZE_LIMIT = 4000000
local GIFT_RING = 1000 -- gift ids remembered per profile (count-bounded, no time pruning) -- bytes; Roblox's limit is 4 MB per key, leave room for the envelope

local Trade = {}

function Trade.install(Anchor, Core)
	local Patch = require(script.Parent.Patch)
	local HttpService = game:GetService("HttpService")
	local DataStoreService = game:GetService("DataStoreService")
	local OnError = Anchor.OnError

	local function report(profile, message)
		local store_name = profile.ProfileStore and profile.ProfileStore.Name or "?"
		warn(`[Anchor]: {message} (STORE:{store_name}; KEY:{tostring(profile.Key)})`)
		OnError:Fire(message, store_name, profile.Key)
	end

	local function reporter(profile)
		return function(message)
			report(profile, message)
		end
	end

	local function liveFor(profile)
		return rawget(profile, "_anchor_live")
	end

	local function newId(): string
		return (string.gsub(HttpService:GenerateGUID(false), "-", ""))
	end

	-- In-memory per-profile state: [id] = "resolving" | "review"
	local function txState(profile)
		local state = rawget(profile, "_anchor_tx_state")
		if state == nil then
			state = {}
			rawset(profile, "_anchor_tx_state", state)
		end
		return state
	end

	----- Decision key -----

	-- Mock profiles / no DataStore access: decisions live in this server's memory (like the
	-- mock profiles themselves). Entries are dropped once both sides resolved here.
	local MemDecisions = {}

	local function usesMemory(rec): boolean
		return rec.mock == true or Anchor.DataStoreState ~= "Access"
	end

	-- First writer wins. Returns "commit" | "abort", or nil when the key can't be reached.
	local function decide(rec, id, mine)
		if usesMemory(rec) then
			local d = MemDecisions[id]
			if d == nil then
				d = mine
				MemDecisions[id] = d
			end
			return d
		end
		local adopted
		local ok = pcall(function()
			local ds = DataStoreService:GetDataStore(DECISION_STORE)
			ds:UpdateAsync("tx_" .. id, function(old)
				adopted = nil
				if type(old) == "table" and (old.D == "commit" or old.D == "abort") then
					adopted = old.D
					return nil -- keep the stored decision
				end
				return { D = mine, T = os.time() }
			end)
		end)
		if ok ~= true then
			return nil
		end
		return adopted or mine
	end

	----- Resolution -----

	local function dropRecord(P, id)
		local tx = P.anchor_meta.Tx
		if type(tx) == "table" then
			tx[id] = nil
			if next(tx) == nil then
				P.anchor_meta.Tx = nil
			end
		end
		txState(P)[id] = nil
		P:MarkMetaDirty()
	end

	-- Applies the decision to P in one tick (ops + record removal). false = kept for review.
	local function applyDecision(P, id, decision, live): boolean
		local tx = P.anchor_meta.Tx
		local rec = type(tx) == "table" and tx[id] or nil
		if rec == nil then
			return true
		end
		local ops = if decision == "commit" then rec.incoming else rec.refund
		if type(ops) ~= "table" or Patch.check(ops) ~= true then
			ops = nil
		end
		local problem = if ops ~= nil then Patch.conflict(P.Data, ops) else "record is malformed"
		if problem ~= nil then
			txState(P)[id] = "review"
			report(
				P,
				`Anchor trade {id} ({decision}) NEEDS MANUAL REVIEW: {problem}. The record is kept and the `
					.. `traded items stay in escrow; inspect with store:PendingTrades(profile).`
			)
			return false
		end
		Patch.apply(P.Data, ops, live or liveFor(P), reporter(P), { Strict = true })
		dropRecord(P, id)
		local mem = rec.mock == true or Anchor.DataStoreState ~= "Access"
		if mem then
			local peer = rec.peer
			local other = type(peer) == "table" and Core.GetActiveProfile({ Name = peer[1] }, peer[2], rec.mock == true)
			local other_tx = other ~= nil and other.anchor_meta.Tx or nil
			if type(other_tx) ~= "table" or other_tx[id] == nil then
				MemDecisions[id] = nil -- both sides resolved
			end
		end
		return true
	end

	-- Resolves P's record `id`, retrying the decision key with backoff while P is loaded
	-- here. `mine` = this server's proposal ("abort" unless it saw both escrows land).
	local function resolveLoop(P, id, mine, live)
		local state = txState(P)
		if state[id] == "resolving" or state[id] == "review" then
			return
		end
		state[id] = "resolving"
		local backoff = 1
		local warned = false
		while true do
			local tx = P.anchor_meta.Tx
			local rec = type(tx) == "table" and tx[id] or nil
			if rec == nil or not P:IsActive() then
				if state[id] == "resolving" then
					state[id] = nil
				end
				return
			end
			local decision = decide(rec, id, mine)
			if decision ~= nil then
				state[id] = nil
				if applyDecision(P, id, decision, live) then
					P:SaveAsync()
				end
				return
			end
			if not warned then
				warned = true
				report(P, `Anchor trade {id}: decision key unreachable; items stay in escrow, retrying`)
			end
			task.wait(backoff)
			backoff = math.min(RETRY_MAX, backoff * 2)
		end
	end

	Core.AddHook("Loaded", function(profile)
		local tx = profile.anchor_meta.Tx
		if type(tx) == "table" then
			for id in next, tx do
				task.spawn(resolveLoop, profile, id, "abort")
			end
		end
	end)

	----- Gifts: the message queue's own exactly-once -----

	local function seenThisSession(profile)
		local seen = rawget(profile, "_anchor_gifts_seen")
		if seen == nil then
			seen = {}
			rawset(profile, "_anchor_gifts_seen", seen)
		end
		return seen
	end

	-- Persistent ring of the last GIFT_RING gift ids applied (MetaData.Anchor.Gifts), saved
	-- with the data: a gift queued twice (a send retried after a committed-but-errored
	-- write) applies once even across sessions. Count-bounded, never time-pruned.
	local function giftApplied(profile, id): boolean
		if seenThisSession(profile)[id] == true then
			return true
		end
		local ring = profile.anchor_meta.Gifts
		return type(ring) == "table" and table.find(ring, id) ~= nil
	end

	local function rememberGift(profile, id)
		seenThisSession(profile)[id] = true
		local ring = profile.anchor_meta.Gifts
		if type(ring) ~= "table" then
			ring = {}
			profile.anchor_meta.Gifts = ring
		end
		table.insert(ring, id)
		local excess = #ring - GIFT_RING
		if excess > 0 then
			table.move(ring, excess + 1, #ring, 1)
			for i = #ring - excess + 1, #ring do
				ring[i] = nil
			end
		end
	end

	Core.AddHook("Message", function(profile, message, processed)
		if type(message) ~= "table" or type(message.AnchorTx) ~= "string" or type(message.Patch) ~= "table" then
			return false -- not ours (or not well-formed): user handlers see it
		end
		if not giftApplied(profile, message.AnchorTx) then
			rememberGift(profile, message.AnchorTx) -- same tick as the apply, same save
			local ok_patch, problem = Patch.check(message.Patch)
			if ok_patch ~= true then
				report(profile, `Anchor gift {message.AnchorTx} has an invalid patch ({tostring(problem)}); dropped`)
			else
				Patch.apply(profile.Data, message.Patch, liveFor(profile), reporter(profile), {
					Parents = "template",
					Template = profile.ProfileStore.template,
				})
				profile:MarkMetaDirty() -- this save must carry the change with the queue removal
			end
		end
		processed()
		return true
	end)

	----- Locks -----

	local function locked(profile)
		return rawget(profile, "_anchor_trade_lock") == true
	end

	local function setLock(profile, value)
		rawset(profile, "_anchor_trade_lock", if value then true else nil)
	end

	local function acquire(A, B, timeout): boolean
		local start = os.clock()
		while locked(A) or locked(B) do
			if os.clock() - start >= timeout then
				return false
			end
			task.wait()
		end
		setLock(A, true)
		setLock(B, true)
		return true
	end

	local function isProfile(p)
		return type(p) == "table" and type(p.Data) == "table" and type(p.anchor_meta) == "table"
	end

	----- Anchor.Trade -----

	local function escrowSize(P, base, draft, record): number
		return math.max(Patch.size(base), Patch.size(draft))
			+ Patch.size(P.anchor_meta)
			+ Patch.size(record)
			+ Patch.size(P.global_updates)
			+ Patch.size(P.RobloxMetaData)
			+ 2000
	end

	local function saveEscrow(P): boolean
		for attempt = 1, ESCROW_SAVE_ATTEMPTS do
			if not P:IsActive() then
				return false
			end
			if P:SaveAsync() == true then
				return true
			end
			if attempt < ESCROW_SAVE_ATTEMPTS then
				task.wait(1)
			end
		end
		return false
	end

	local commit

	function Anchor.Trade(A, B, fn, opts)
		opts = opts or {}
		if not isProfile(A) or not isProfile(B) or type(fn) ~= "function" then
			return false, "Invalid", "Trade(profileA, profileB, fn) needs two profiles and a function"
		end
		if A == B or (A.Key == B.Key and A.ProfileStore.Name == B.ProfileStore.Name) then
			return false, "Invalid", "A profile can't trade with itself"
		end
		if A.view_mode == true or B.view_mode == true then
			return false, "Invalid", "View-mode profiles can't trade"
		end
		if not A:IsActive() or not B:IsActive() then
			return false, "Inactive"
		end
		local timeout = opts.Timeout or TX_LOCK_TIMEOUT
		if not acquire(A, B, timeout) then
			return false, "Busy"
		end
		local results = table.pack(pcall(commit, A, B, fn, opts))
		setLock(A, false)
		setLock(B, false)
		if results[1] == false then
			report(A, `Trade errored: {tostring(results[2])}`)
			return false, "Error", tostring(results[2])
		end
		return table.unpack(results, 2, results.n)
	end

	commit = function(A, B, fn, opts)
		if not A:IsActive() or not B:IsActive() then
			return false, "Inactive"
		end

		local live = opts.Live
		local liveA = type(live) == "table" and live[1] or liveFor(A)
		local liveB = type(live) == "table" and live[2] or liveFor(B)

		-- 1. drafts (fn may yield; the diff is against the copies taken before it ran)
		local baseA, baseB = Patch.deepCopy(A.Data), Patch.deepCopy(B.Data)
		local draftA, draftB = Patch.deepCopy(baseA), Patch.deepCopy(baseB)
		local ok_fn, result = pcall(fn, draftA, draftB)
		if ok_fn == false then
			return false, "Error", tostring(result)
		end
		if result == false then
			return false, "Cancelled"
		end
		if not A:IsActive() or not B:IsActive() then
			return false, "Inactive"
		end

		local PA, PB = Patch.diff(baseA, draftA), Patch.diff(baseB, draftB)
		for _, p in { PA, PB } do
			local ok_patch, problem = Patch.check(p)
			if ok_patch ~= true then
				return false, "Invalid", problem
			end
		end
		if #PA == 0 and #PB == 0 then
			return true
		end
		if #PA == 0 or #PB == 0 then
			-- Only one side changes: a plain single-profile edit, atomic in its next save.
			local P = if #PA > 0 then A else B
			Patch.apply(P.Data, if #PA > 0 then PA else PB, if #PA > 0 then liveA else liveB, reporter(P))
			P:MarkMetaDirty()
			return true
		end

		local outA, inA = Patch.split(PA, baseA)
		local outB, inB = Patch.split(PB, baseB)
		local id = newId()
		local mock = A.is_mock == true or B.is_mock == true
		local function record(role, P, peer, refund, incoming)
			return {
				role = role,
				refund = refund,
				incoming = incoming,
				peer = { peer.ProfileStore.Name, peer.Key },
				t = os.time(),
				mock = if mock then true else nil,
			}
		end

		-- size guard before anything changes (refund is about the size of outgoing)
		local probeA = record("A", A, B, outA, inA)
		local probeB = record("B", B, A, outB, inB)
		if escrowSize(A, baseA, draftA, probeA) > SIZE_LIMIT or escrowSize(B, baseB, draftB, probeB) > SIZE_LIMIT then
			return false, "TooBig"
		end

		-- the escrow tick: data must still be what fn saw (fn may have yielded)
		if not Patch.deepEqual(A.Data, baseA) or not Patch.deepEqual(B.Data, baseB) then
			-- Something wrote to A or B while fn ran; diffing would be against stale data.
			return false, "Error", "profile data changed while the trade function ran; retry"
		end
		local refundA = Patch.apply(A.Data, outA, liveA, reporter(A))
		local refundB = Patch.apply(B.Data, outB, liveB, reporter(B))
		local recA = record("A", A, B, refundA, inA)
		local recB = record("B", B, A, refundB, inB)
		A.anchor_meta.Tx = A.anchor_meta.Tx or {}
		B.anchor_meta.Tx = B.anchor_meta.Tx or {}
		A.anchor_meta.Tx[id] = recA
		B.anchor_meta.Tx[id] = recB
		A:MarkMetaDirty()
		B:MarkMetaDirty()
		txState(A)[id] = "resolving" -- this thread resolves it; load recovery must not
		txState(B)[id] = "resolving"

		-- 2. both escrows durable?
		local okA, okB, doneA, doneB = false, false, false, false
		task.spawn(function()
			okA = saveEscrow(A)
			doneA = true
		end)
		task.spawn(function()
			okB = saveEscrow(B)
			doneB = true
		end)
		while not (doneA and doneB) do
			task.wait()
		end
		local mine = if okA and okB then "commit" else "abort"
		local why = if okA and okB then nil
			elseif A:IsActive() and B:IsActive() then "SaveFailed"
			else "SessionLost"

		-- 3. the decision
		local decision = nil
		local backoff = 1
		local start = os.clock()
		while true do
			decision = decide(recA, id, mine)
			if decision ~= nil or os.clock() - start >= DECISION_WAIT then
				break
			end
			task.wait(backoff)
			backoff = math.min(4, backoff * 2)
		end

		if decision == nil then
			-- Keep both records (escrowed) and keep trying in the background.
			report(A, `Anchor trade {id}: decision key unreachable; items stay in escrow until it resolves`)
			txState(A)[id] = nil
			txState(B)[id] = nil
			task.spawn(resolveLoop, A, id, mine, liveA)
			task.spawn(resolveLoop, B, id, mine, liveB)
			return false, "Pending"
		end

		-- 4. apply on each side still loaded here (others resolve on their next load)
		for _, side in { { A, liveA }, { B, liveB } } do
			local P = side[1]
			txState(P)[id] = nil
			if P:IsActive() then
				if applyDecision(P, id, decision, side[2]) then
					task.spawn(P.SaveAsync, P)
				end
			end
		end

		if decision == "commit" then
			return true
		end
		return false, why or "Aborted"
	end

	----- store:Gift -----

	local function keyFor(store, target)
		if type(target) == "number" then
			return (store.key_prefix or "Player_") .. tostring(target)
		elseif type(target) == "string" then
			return target
		end
		error("[Anchor]: Gift target must be a UserId or a profile key")
	end

	-- store:Gift(userIdOrKey, fn(data) | patch) -> (boolean, reason?)
	-- Queued on the profile and applied exactly once by whichever server owns it (now or at
	-- its next load). fn runs on a copy of the latest data; its changes travel as a patch
	-- (numbers as increments, so progress made in the meantime is kept).
	function Anchor:Gift(target, gift)
		if type(self) ~= "table" or self.template == nil then
			error("[Anchor]: Gift must be called on a store (Data:Gift(userId, fn))")
		end
		local key = keyFor(self, target)
		local patch
		if type(gift) == "function" then
			local base
			local is_mock = self.anchor_options.Mock == true
			local active = Core.GetActiveProfile(self, key, is_mock)
			if active ~= nil then
				base = Patch.deepCopy(active.Data)
			else
				local view = self:GetAsync(key)
				base = if view ~= nil then view.Data else Patch.deepCopy(self.template)
			end
			local draft = Patch.deepCopy(base)
			local ok, result = pcall(gift, draft)
			if ok == false then
				return false, "Error", tostring(result)
			end
			if result == false then
				return false, "Cancelled"
			end
			patch = Patch.diff(base, draft)
		elseif type(gift) == "table" then
			patch = gift
		else
			error("[Anchor]: Gift needs a function or a patch")
		end
		local ok_patch, problem = Patch.check(patch)
		if ok_patch ~= true then
			return false, "Invalid", problem
		end
		if #patch == 0 then
			return true
		end
		if self:MessageAsync(key, { AnchorTx = newId(), Patch = patch }) ~= true then
			return false, "Failed"
		end
		return true
	end

	----- Trading flag, Update waiting, pending records -----

	-- profile:IsTrading() -> true while a trade involving this profile is committing.
	Core.Profile.IsTrading = function(self)
		return locked(self)
	end

	-- Data:Update waits for a running trade on the player's profile to finish, so its write
	-- lands on the post-trade data. (Direct writes to profile.Data are not held back.)
	local BaseUpdate = Anchor.Update
	if BaseUpdate ~= nil then
		function Anchor:Update(player, fn)
			local Get = self.Get
			if self.bind_state ~= nil and Get ~= nil then
				local profile = Get(self, player)
				while profile ~= nil and locked(profile) and profile:IsActive() do
					task.wait()
				end
			end
			return BaseUpdate(self, player, fn)
		end
	end

	-- store:PendingTrades(profile) -> { {Id, Role, Store, Key, Refund, Incoming, Created, Status}, ... }
	-- Unresolved trade records (items in escrow). Status: "NeedsReview" (resolution would
	-- overwrite changed data; decide by hand), "Resolving", "Waiting" (resolves on next load).
	function Anchor:PendingTrades(profile)
		local out = {}
		local tx = type(profile) == "table" and type(profile.anchor_meta) == "table" and profile.anchor_meta.Tx
		if type(tx) ~= "table" then
			return out
		end
		local state = txState(profile)
		local names = { review = "NeedsReview", resolving = "Resolving" }
		for id, rec in next, tx do
			rec = if type(rec) == "table" then rec else {}
			local peer = type(rec.peer) == "table" and rec.peer or {}
			table.insert(out, {
				Id = id,
				Role = rec.role,
				Store = peer[1],
				Key = peer[2],
				Refund = Patch.deepCopy(rec.refund),
				Incoming = Patch.deepCopy(rec.incoming),
				Created = rec.t,
				Status = names[state[id]] or "Waiting",
			})
		end
		table.sort(out, function(a, b)
			return (a.Created or 0) < (b.Created or 0)
		end)
		return out
	end

	Anchor.Patch = Patch
	Anchor._Trade = {
		decide = decide,
		resolve = resolveLoop,
		DECISION_STORE = DECISION_STORE,
	}
end

return Trade
