--!nonstrict
--[[
	Anchor / Core

	A port of loleris' ProfileStore 1.0.3 (MAD STUDIO, Apache-2.0; see
	reference/ProfileStore-1.0.3.luau). The lock protocol, constants, UpdateAsync
	transform rules, MessagingService topic/payload, message queue handling, critical
	state, Mock and BindToClose behaviour are stock. Deviations (all marked [Anchor]):

	  * Data format: Compat (default, stock bytes) or Compact (Codec blob + poisoned
	    stock counter, see Envelope.luau). Readers accept both.
	  * Cost (SPEC section 9): Compat runs no Codec work on the happy path (stock-identical
	    load copy and LastSavedData); Codec.validate runs only after a failed write, to put
	    the bad path in that call's OnError message. Compact: one encode + one verify
	    (decode + equal) per save; that blob is the write, the clean-skip baseline and
	    the lazily decoded LastSavedData; load decodes once and keeps the stored buffer.
	  * Clean-save skip, only when it can trigger (effective LockRefresh >= AUTO_SAVE_PERIOD):
	    an autosave whose Data (IsDirty hook, or byte compare), UserIds, RobloxMetaData and
	    MetaData.Anchor are unchanged since the last successful write, with no processed
	    messages to clear, is skipped while the last write is fresh enough that the lock
	    can't look dead. Manual saves, releases, forced saves and message pings are never
	    skipped.
	  * Write verification (VerifyWrites, default on) for Compact blobs; on mismatch the
	    save is written Compat.
	  * Same-server quick reload waits for this server's pending release of that key.
	  * O(1) autosave list (circular doubly linked list with stock's cursor semantics).
	  * Profile:SaveAsync(): yielding forced save -> true once a write that contains the
	    current state succeeded while this session still owns the profile.
	  * Hooks for trades / receipts / easy API (Core.Hooks); options.Mock routes a whole
	    store to the in-memory store (dev option, guarded in init.luau).
--]]

local Signal = require(script.Parent.Signal)
local Envelope = require(script.Parent.Envelope)
local Codec = require(script.Parent.Codec)

local LIB = "Anchor"

local AUTO_SAVE_PERIOD = 300 -- (Seconds) Time between when changes to a profile are saved to the DataStore
local LOAD_REPEAT_PERIOD = 10 -- (Seconds) Time between successive profile reads when handling a session conflict
local FIRST_LOAD_REPEAT = 5 -- (Seconds) Time between first and second profile read when handling a session conflict
local SESSION_STEAL = 40 -- (Seconds) Time until a session conflict is resolved with the waiting server stealing the session
local ASSUME_DEAD = 630 -- (Seconds) If a profile hasn't had updates for this long, quickly assume an active session belongs to a crashed server
local START_SESSION_TIMEOUT = 120 -- (Seconds) If a session can't be started for a profile for this long, stop repeating calls to the DataStore

local CRITICAL_STATE_ERROR_COUNT = 5 -- Assume critical state if this many issues happen in a short amount of time
local CRITICAL_STATE_ERROR_EXPIRE = 120 -- (Seconds) Individual issue expiration
local CRITICAL_STATE_EXPIRE = 120 -- (Seconds) Critical state expiration

local MAX_MESSAGE_QUEUE = 1000 -- Max messages saved in a profile that were sent using "ProfileStore:MessageAsync()"

-- [Anchor]
local DEFAULT_LOCK_REFRESH = 300 -- (Seconds) Clean autosaves may be skipped only while the last write is younger than this
local LOCK_REFRESH_DEAD_FRACTION = 0.75 -- A skip must leave the next autosave before ASSUME_DEAD * this
local SIZE_WARN_BYTES = 3.5 * 1024 * 1024
local DATA_ERROR_REPORT_INTERVAL = 60 -- (Seconds) Rate limit for repeated data-validation OnError reports per profile

----- Private -----

local ActiveSessionCheck = {} -- {[session_token] = profile, ...}
-- [Anchor] {[session_token] = number of release saves still in flight on this server}
local PendingReleases = {}
local IssueQueue = {} -- {issue_time, ...}

-- [Anchor] Autosave ring: circular doubly linked list through profile._as_next/_as_prev.
-- AutoSaveCursor is stock's AutoSaveList[AutoSaveIndex]; new profiles are inserted right
-- behind the cursor (stock: table.insert at AutoSaveIndex, then AutoSaveIndex += 1).
local AutoSaveCursor = nil
local AutoSaveCount = 0

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local PlaceId = game.PlaceId
local JobId = game.JobId

local LastAutoSave = os.clock()

local LoadIndex = 0

local ActiveProfileLoadJobs = 0 -- Number of active threads that are loading in profiles
local ActiveProfileSaveJobs = 0 -- Number of active threads that are saving profiles

local CriticalStateStart = 0 -- os.clock()

local IsStudio = RunService:IsStudio()
local DataStoreState: "NotReady" | "NoInternet" | "NoAccess" | "Access" = "NotReady"

local MockStore = {}
local UserMockStore = {}
local MockFlag = false

local OnError = Signal.New() -- (message, store_name, profile_key)
local OnOverwrite = Signal.New() -- (store_name, profile_key)

-- [Anchor] Extension points for feature modules (Trade, Receipts, easy API).
local Hooks = {
	-- fn(profile, message_copy: table, processed: () -> ()) -> boolean
	-- Runs before user MessageHandlers, for new messages and for messages present at
	-- session start. Return true to claim the message (user handlers never see it);
	-- call processed() once its effect is in profile state so the next save drops it.
	Message = {},
	-- fn(profile) after a session starts, before StartSessionAsync returns it.
	Loaded = {},
	-- fn(profile, latest_data) inside the save transform, only when this session owns
	-- the key and is about to write it.
	BeforeWrite = {},
	-- fn(profile, wrote: boolean, raw: table) after a save reached the DataStore; wrote =
	-- our state was written while this session owned the key; raw = the stored envelope
	-- returned by the call (when wrote, exactly what was written, MetaData.Anchor included).
	AfterSave = {},
}

local UpdateQueue = { -- For stability sake, we won't do UpdateAsync calls for the same key until all previous calls finish
	--[[
		[session_token] = {
			coroutine, ...
		},
		...
	--]]
}

local function WaitInUpdateQueue(session_token) --> next_in_queue()
	local is_first = false

	if UpdateQueue[session_token] == nil then
		is_first = true
		UpdateQueue[session_token] = {}
	end

	local queue = UpdateQueue[session_token]

	if is_first == false then
		table.insert(queue, coroutine.running())
		coroutine.yield()
	end

	return function()
		local next_co = table.remove(queue, 1)
		if next_co ~= nil then
			coroutine.resume(next_co)
		else
			UpdateQueue[session_token] = nil
		end
	end
end

local function SessionToken(store_name, profile_key, is_mock)
	local session_token = "L_" -- Live

	if is_mock == true then
		session_token = "U_" -- User mock
	elseif DataStoreState ~= "Access" then
		session_token = "M_" -- Mock, cause no DataStore access
	end

	session_token ..= store_name .. "\0" .. profile_key

	return session_token
end

local function DeepCopyTable(t)
	local copy = {}
	for key, value in pairs(t) do
		if type(value) == "table" then
			copy[key] = DeepCopyTable(value)
		else
			copy[key] = value
		end
	end
	return copy
end

local function ReconcileTable(target, template)
	for k, v in pairs(template) do
		if type(k) == "string" then -- Only string keys will be reconciled
			if target[k] == nil then
				if type(v) == "table" then
					target[k] = DeepCopyTable(v)
				else
					target[k] = v
				end
			elseif type(target[k]) == "table" and type(v) == "table" then
				ReconcileTable(target[k], v)
			end
		end
	end
end

local ModuleTable -- forward: the public ProfileStore table (IsClosing etc.)

local function RegisterError(error_message, store_name, profile_key) -- Called when a DataStore API call errors
	warn(`[{LIB}]: DataStore API error (STORE:{store_name}; KEY:{profile_key}) - {tostring(error_message)}`)
	table.insert(IssueQueue, os.clock()) -- Adding issue time to queue
	OnError:Fire(tostring(error_message), store_name, profile_key)
end

local function RegisterOverwrite(store_name, profile_key) -- Called when a corrupted profile is loaded
	warn(`[{LIB}]: Invalid profile was overwritten (STORE:{store_name}; KEY:{profile_key})`)
	OnOverwrite:Fire(store_name, profile_key)
end

-- [Anchor] Data problems (not DataStore API errors): OnError + warn, no critical-state count.
-- warn_only: just warn (used when we defer to the DataStore exactly like stock does,
-- so OnError fires once, from the DataStore's own error, as in stock).
local function ReportDataError(profile, message, rate_limit_key, warn_only)
	if rate_limit_key ~= nil then
		local reported = profile.data_error_reports
		if reported == nil then
			reported = {}
			profile.data_error_reports = reported
		end
		local last = reported[rate_limit_key]
		if last ~= nil and os.clock() - last < DATA_ERROR_REPORT_INTERVAL then
			return
		end
		reported[rate_limit_key] = os.clock()
	end
	local store_name = profile.ProfileStore.Name
	warn(`[{LIB}]: {message} (STORE:{store_name}; KEY:{profile.Key})`)
	if warn_only ~= true then
		OnError:Fire(message, store_name, profile.Key)
	end
end

local function NewMockDataStoreKeyInfo(params)
	local version_id_string = tostring(params.VersionId or 0)
	local meta_data = params.MetaData or {}
	local user_ids = params.UserIds or {}

	return {
		CreatedTime = params.CreatedTime,
		UpdatedTime = params.UpdatedTime,
		Version = string.rep("0", 16)
			.. "."
			.. string.rep("0", 10 - string.len(version_id_string))
			.. version_id_string
			.. "."
			.. string.rep("0", 16)
			.. "."
			.. "01",

		GetMetadata = function()
			return DeepCopyTable(meta_data)
		end,

		GetUserIds = function()
			return DeepCopyTable(user_ids)
		end,
	}
end

local function MockUpdateAsync(mock_data_store, profile_store_name, key, transform_function, is_get_call) --> loaded_data, key_info
	local profile_store = mock_data_store[profile_store_name]

	if profile_store == nil then
		profile_store = {}
		mock_data_store[profile_store_name] = profile_store
	end

	local epoch_time = math.floor(os.time() * 1000)
	local mock_entry = profile_store[key]
	local mock_entry_was_nil = false

	if mock_entry == nil then
		mock_entry_was_nil = true
		if is_get_call ~= true then
			mock_entry = {
				Data = nil,
				CreatedTime = epoch_time,
				UpdatedTime = epoch_time,
				VersionId = 0,
				UserIds = {},
				MetaData = {},
			}
			profile_store[key] = mock_entry
		end
	end

	local mock_key_info = mock_entry_was_nil == false and NewMockDataStoreKeyInfo(mock_entry) or nil

	local transform, user_ids, roblox_meta_data = transform_function(mock_entry and mock_entry.Data, mock_key_info)

	if transform == nil then
		return nil
	else
		if mock_entry ~= nil and is_get_call ~= true then
			mock_entry.Data = DeepCopyTable(transform)
			mock_entry.UserIds = DeepCopyTable(user_ids or {})
			mock_entry.MetaData = DeepCopyTable(roblox_meta_data or {})
			mock_entry.VersionId += 1
			mock_entry.UpdatedTime = epoch_time
		end

		return DeepCopyTable(transform), mock_entry ~= nil and NewMockDataStoreKeyInfo(mock_entry) or nil
	end
end

local function UpdateAsync(profile_store, profile_key, transform_params, is_user_mock, is_get_call, version) --> loaded_data, key_info
	--transform_params = {
	--	ExistingProfileHandle = function(latest_data),
	--	MissingProfileHandle = function(latest_data),
	--	EditProfile = function(latest_data),
	--}

	local loaded_data, key_info

	local next_in_queue = WaitInUpdateQueue(SessionToken(profile_store.Name, profile_key, is_user_mock))

	local success, error_message = pcall(function()
		local transform_function = function(latest_data)
			local missing_profile = false
			local overwritten = false
			local global_updates = { 0, {} }

			if latest_data == nil then
				missing_profile = true
			elseif type(latest_data) ~= "table" then
				missing_profile = true
				overwritten = true
			else
				if
					type(latest_data.Data) == "table"
					and type(latest_data.MetaData) == "table"
					and type(latest_data.GlobalUpdates) == "table"
				then
					-- Regular profile structure detected:

					latest_data.WasOverwritten = false -- Must be set to false if set previously
					global_updates = latest_data.GlobalUpdates

					if transform_params.ExistingProfileHandle ~= nil then
						transform_params.ExistingProfileHandle(latest_data)
					end
				elseif
					latest_data.Data == nil
					and latest_data.MetaData == nil
					and type(latest_data.GlobalUpdates) == "table"
				then
					-- Regular structure not detected, but GlobalUpdate data exists:

					latest_data.WasOverwritten = false -- Must be set to false if set previously
					global_updates = latest_data.GlobalUpdates or global_updates
					missing_profile = true
				else
					missing_profile = true
					overwritten = true
				end
			end

			-- Profile was not created or corrupted and no GlobalUpdate data exists:
			if missing_profile == true then
				latest_data = {
					-- Data = nil,
					-- MetaData = nil,
					GlobalUpdates = global_updates,
				}
				if transform_params.MissingProfileHandle ~= nil then
					transform_params.MissingProfileHandle(latest_data)
				end
			end

			-- Editing profile:
			if transform_params.EditProfile ~= nil then
				transform_params.EditProfile(latest_data)
			end

			-- Invalid data handling (Silently override with empty profile)
			if overwritten == true then
				latest_data.WasOverwritten = true -- Temporary tag that will be removed on first save
			end

			return latest_data, latest_data.UserIds, latest_data.RobloxMetaData
		end

		if is_user_mock == true then -- Used when the profile is accessed through ProfileStore.Mock
			loaded_data, key_info =
				MockUpdateAsync(UserMockStore, profile_store.Name, profile_key, transform_function, is_get_call)
			task.wait() -- Simulate API call yield
		elseif DataStoreState ~= "Access" then -- Used when API access is disabled
			loaded_data, key_info =
				MockUpdateAsync(MockStore, profile_store.Name, profile_key, transform_function, is_get_call)
			task.wait() -- Simulate API call yield
		else
			if is_get_call == true then
				if version ~= nil then
					local success, error_message = pcall(function()
						loaded_data, key_info = profile_store.data_store:GetVersionAsync(profile_key, version)
					end)

					if
						success == false
						and type(error_message) == "string"
						and string.find(error_message, "not valid") ~= nil
					then
						warn(`[{LIB}]: Passed version argument is not valid; Traceback:\n` .. debug.traceback())
					end
				else
					loaded_data, key_info = profile_store.data_store:GetAsync(profile_key)
				end

				loaded_data = transform_function(loaded_data)
			else
				loaded_data, key_info = profile_store.data_store:UpdateAsync(profile_key, transform_function)
			end
		end
	end)

	next_in_queue()

	if success == true and type(loaded_data) == "table" then
		-- Invalid data handling:
		if loaded_data.WasOverwritten == true and is_get_call ~= true then
			RegisterOverwrite(profile_store.Name, profile_key)
		end
		-- Return loaded_data:
		return loaded_data, key_info
	else
		-- Error handling:
		local message = error_message or "Undefined error"
		if transform_params.DescribeFailure ~= nil then
			-- [Anchor] e.g. the path of the value the DataStore refused (validated only now)
			local ok_detail, detail = pcall(transform_params.DescribeFailure)
			if ok_detail == true and detail ~= nil then
				message = `{tostring(message)} [Anchor: {detail}]`
			end
		end
		RegisterError(message, profile_store.Name, profile_key)
		-- Return nothing:
		return nil
	end
end

local function IsThisSession(session_tag)
	return session_tag[1] == PlaceId and session_tag[2] == JobId
end

local function ReadMockFlag(profile_store): boolean
	local is_mock = MockFlag
	MockFlag = false
	-- [Anchor] a store created with options.Mock = true always uses the in-memory store:
	if is_mock == false and profile_store ~= nil and profile_store.anchor_options ~= nil then
		is_mock = profile_store.anchor_options.Mock == true
	end
	return is_mock
end

local function WaitForStoreReady(profile_store)
	while profile_store.is_ready == false do
		task.wait()
	end
end

-- [Anchor] O(1) autosave ring

local function AddProfileToAutoSave(profile)
	ActiveSessionCheck[profile.session_token] = profile

	if profile._as_in == true then
		return
	end
	profile._as_in = true

	if AutoSaveCursor == nil then
		profile._as_next = profile
		profile._as_prev = profile
		AutoSaveCursor = profile
		AutoSaveCount = 1
		-- First profile created - make sure it doesn't get immediately auto saved:
		LastAutoSave = os.clock()
	else
		-- Insert right behind the cursor (saved last in the current cycle):
		local cursor = AutoSaveCursor
		local prev = cursor._as_prev
		prev._as_next = profile
		profile._as_prev = prev
		profile._as_next = cursor
		cursor._as_prev = profile
		AutoSaveCount += 1
	end
end

local function RemoveProfileFromAutoSave(profile)
	if ActiveSessionCheck[profile.session_token] == profile then
		ActiveSessionCheck[profile.session_token] = nil
	end

	if profile._as_in ~= true then
		return
	end
	profile._as_in = false
	AutoSaveCount -= 1

	if AutoSaveCount == 0 then
		AutoSaveCursor = nil
	else
		local prev, nxt = profile._as_prev, profile._as_next
		prev._as_next = nxt
		nxt._as_prev = prev
		if AutoSaveCursor == profile then
			AutoSaveCursor = nxt -- stock: contents shift left onto the cursor (wrapping to 1)
		end
	end
	profile._as_next = nil
	profile._as_prev = nil
end

local function AutoSaveSnapshot()
	local list = {}
	local node = AutoSaveCursor
	for i = 1, AutoSaveCount do
		list[i] = node
		node = node._as_next
	end
	return list
end

-- [Anchor] Encoding helpers
--
-- Cost model (SPEC section 9): Compat adds no Luau work over stock on the happy path;
-- Codec runs only when a clean-save skip can actually happen, or after a failed write
-- (to name the bad path). Compact pays one encode + one verify (decode + equal) per save.

local function StoreOptions(profile)
	return profile.ProfileStore.anchor_options
end

local function EffectiveLockRefresh(options): number
	return math.min(options.LockRefresh, ASSUME_DEAD * LOCK_REFRESH_DEAD_FRACTION - AUTO_SAVE_PERIOD)
end

-- A clean autosave can only be skipped if the lock-refresh window is at least one
-- autosave period long; otherwise skip bookkeeping is never paid for.
local function SkipPossible(options): boolean
	return EffectiveLockRefresh(options) >= AUTO_SAVE_PERIOD
end

local function EncodeAux(profile): buffer
	return Codec.encode({ u = profile.UserIds, r = profile.RobloxMetaData, a = profile.anchor_meta })
end

-- Verify = decode + deep-equal against the data the blob was encoded from.
local function VerifyBlob(blob: buffer, data): string?
	local ok_verify, same = pcall(function()
		return Codec.equal(Codec.decode(blob), data)
	end)
	if ok_verify == false then
		return `Codec verification errored: {tostring(same)}`
	elseif same ~= true then
		return "Codec verification mismatch (decoded blob differs from Data)"
	end
	return nil
end

-- Only called after a write failed: names the first value Codec rejects, if any.
local function DescribeInvalid(data): string?
	local ok, valid, path, reason = pcall(Codec.validate, data)
	if ok == true and valid == false then
		return `{tostring(reason)} at {tostring(path)}`
	end
	return nil
end

-- LastSavedData: either a plain table (stock semantics: deep copy at load, the table
-- UpdateAsync returned after a save) or a stored Compact blob decoded on first read
-- (profile.lsd_blob). Option LastSavedData = false keeps neither (always nil).
local function SetLastSavedTable(profile, plain_table)
	profile.lsd_blob = nil
	if StoreOptions(profile).LastSavedData ~= false then
		rawset(profile, "LastSavedData", plain_table)
	else
		rawset(profile, "LastSavedData", nil)
	end
end

local function SetLastSavedBlob(profile, blob)
	profile.lsd_blob = blob
	rawset(profile, "LastSavedData", nil)
end

-- [Anchor] Keys stored beside a Compact blob (a stock view-mode overwrite adds them):
-- the blob is the data; the stray keys are ignored and dropped by the next write.
local function ReportStrayKeys(store_name, profile_key, stray)
	if stray == nil then
		return
	end
	local message = `Data has keys beside the Compact blob ({table.concat(stray, ", ")}), likely written by a stock ProfileStore overwrite; they were ignored and the blob was loaded`
	warn(`[{LIB}]: {message} (STORE:{store_name}; KEY:{profile_key})`)
	OnError:Fire(message, store_name, profile_key)
end

local function SetLastSavedFromRaw(profile, raw)
	-- Data written by someone else (we didn't write in this call): read whatever format it is.
	if Envelope.isCompactData(raw.Data) then
		SetLastSavedBlob(profile, raw.Data[Envelope.BLOB_KEY])
	else
		SetLastSavedTable(profile, raw.Data)
	end
end

----- Saving -----

-- [Anchor] Clean-save skip decision for autosaves. Returns skip, blob: blob is non-nil when
-- Data had to be encoded to decide (and differed). It is never written: the write takes
-- its own snapshot inside the transform.
local function CheckAutoSave(profile): (boolean, buffer?)
	local options = StoreOptions(profile)
	if profile.last_write_clock == nil or SkipPossible(options) == false then
		return false, nil
	end
	if os.clock() - profile.last_write_clock >= EffectiveLockRefresh(options) then
		return false, nil -- the lock must be refreshed
	end
	if next(profile.locked_global_updates) ~= nil then
		return false, nil -- processed messages must be cleared from the stored queue
	end
	if profile.meta_dirty == true or profile.saved_aux == nil then
		return false, nil
	end
	local ok_aux, aux = pcall(EncodeAux, profile)
	if ok_aux == false or Envelope.blobEqual(aux, profile.saved_aux) == false then
		return false, nil
	end
	local is_dirty = options.IsDirty
	if is_dirty ~= nil and profile.hook_unsaved ~= true then
		local ok_hook, dirty = pcall(is_dirty, profile)
		if ok_hook == true and dirty == false then
			return true, nil
		elseif ok_hook == true and dirty == true and options.Format ~= "Compact" then
			return false, nil -- trust the hook; no compare encode
		end
	end
	if profile.saved_blob == nil then
		return false, nil
	end
	local ok, blob = pcall(Codec.encode, profile.Data)
	if ok == false then
		return false, nil
	end
	if Envelope.blobEqual(blob, profile.saved_blob) then
		return true, nil
	end
	return false, blob
end

local function RunMessageHooks(profile, index, update_data): boolean
	if #Hooks.Message == 0 or type(update_data) ~= "table" then
		return false
	end
	local locked_updates = profile.locked_global_updates
	for _, hook in ipairs(Hooks.Message) do
		local processed_callback = function()
			locked_updates[index] = true
		end
		local ok, claimed = pcall(hook, profile, DeepCopyTable(update_data), processed_callback)
		if ok == false then
			ReportDataError(profile, `Internal message handler error: {tostring(claimed)}`)
		elseif claimed == true then
			profile.claimed_global_updates[index] = true
			return true
		end
	end
	return false
end

local function RunHookList(list, profile, ...)
	for _, hook in ipairs(list) do
		local ok, err = pcall(hook, profile, ...)
		if ok == false then
			ReportDataError(profile, `Internal hook error: {tostring(err)}`)
		end
	end
end

local SaveProfileAsync

-- save_kind: nil (stock: manual / message ping / release), "Auto", "Forced"
-- Returns true when this call wrote our state while this session owned the key.
SaveProfileAsync = function(profile, is_ending_session, is_overwriting, last_save_reason, save_kind): boolean
	if type(profile.Data) ~= "table" then
		error(
			`[{LIB}]: Developer code likely set "Profile.Data" to a non-table value! (STORE:{profile.ProfileStore.Name}; KEY:{profile.Key})`
		)
	end

	profile.OnSave:Fire()
	if is_ending_session == true then
		profile.OnLastSave:Fire(last_save_reason or "Manual")
	end

	-- [Anchor] Clean-save skip (autosaves only):
	local pre_blob = nil
	if save_kind == "Auto" and is_ending_session ~= true and is_overwriting ~= true then
		local skip
		skip, pre_blob = CheckAutoSave(profile)
		if skip == true then
			profile.skipped_saves += 1
			return false
		end
	end

	local release_token = nil
	if is_ending_session == true and is_overwriting ~= true then
		-- [Anchor] a new session for this key on this server waits for this release to land
		release_token = profile.session_token
		PendingReleases[release_token] = (PendingReleases[release_token] or 0) + 1

		if profile.roblox_message_subscription ~= nil then
			profile.roblox_message_subscription:Disconnect()
		end
		RemoveProfileFromAutoSave(profile)
		profile.OnSessionEnd:Fire()
	end

	ActiveProfileSaveJobs = ActiveProfileSaveJobs + 1

	local options = StoreOptions(profile)
	local result = false

	-- Compare "SessionLoadCount" when writing to profile to prevent a rare case of repeat last save when the profile is loaded on the same server again

	local repeat_save_flag = true -- Released Profile save calls have to repeat until they succeed
	local exp_backoff = 1

	while repeat_save_flag == true do
		if is_ending_session ~= true then
			repeat_save_flag = false
		end

		-- [Anchor] Compact: one encode (also validates) + verify per transform run, taken
		-- INSIDE the transform from the live Data table, at the same instant as the
		-- bookkeeping (messages, MetaData.Anchor, ClearDirty), exactly where Compat and
		-- stock take the live table. The blob is what gets written, so it is also the skip
		-- baseline and LastSavedData.
		local encode_problem = nil
		local verify_problem = nil
		-- Compat byte-compare mode: if this autosave already paid a compare encode (and
		-- found a change), don't encode again for a new baseline; the next autosave then
		-- writes without comparing and takes its baseline from that write. <= 1 encode per
		-- autosave, never a skip against a baseline that isn't exactly what was written.
		-- (A Compact skip-check blob is never written: Data may change before the transform.)
		local compat_compare_paid = pre_blob ~= nil and options.Format ~= "Compact"
		local skip_bookkeeping = SkipPossible(options)
		pre_blob = nil

		local wrote = false
		local written_blob = nil
		local compare_blob = nil
		local written_aux = nil
		local written_format = nil
		local cleared_hook_dirty = false

		local loaded_data, key_info = UpdateAsync(profile.ProfileStore, profile.Key, {
			ExistingProfileHandle = nil,
			MissingProfileHandle = nil,
			DescribeFailure = function()
				return DescribeInvalid(profile.Data) -- [Anchor] only runs after a failed call
			end,
			EditProfile = function(latest_data)
				wrote = false
				written_blob = nil
				compare_blob = nil
				written_aux = nil
				encode_problem = nil
				verify_problem = nil

				-- Check if this session still owns the profile:

				local session_owns_profile = false

				if is_overwriting ~= true then
					local active_session = latest_data.MetaData.ActiveSession
					local session_load_count = Envelope.getLoadCount(latest_data.MetaData)

					if type(active_session) == "table" then
						session_owns_profile = IsThisSession(active_session)
							and session_load_count == profile.load_index
					end
				else
					session_owns_profile = true
				end

				-- We may only edit the profile if this server has ownership of the profile:

				if session_owns_profile == true then
					-- Clear processed updates (messages):

					local locked_updates = profile.locked_global_updates -- [index] = true, ...
					local active_updates = latest_data.GlobalUpdates[2]
					-- ProfileService module format: {{update_id, version_id, update_locked, update_data}, ...}
					-- ProfileStore module format: {{update_id, update_data}, ...}

					if next(locked_updates) ~= nil then
						local i = 1
						while i <= #active_updates do
							local update = active_updates[i]
							if locked_updates[update[1]] == true then
								table.remove(active_updates, i)
							else
								i += 1
							end
						end
					end

					-- [Anchor] feature hooks + our bookkeeping:

					if #Hooks.BeforeWrite > 0 then
						RunHookList(Hooks.BeforeWrite, profile, latest_data)
					end
					Envelope.writeAnchorMeta(latest_data.MetaData, profile.anchor_meta)

					-- Save profile data:

					if options.ClearDirty ~= nil and is_overwriting ~= true then
						pcall(options.ClearDirty, profile)
						cleared_hook_dirty = true
					end

					local compact_blob = nil
					if options.Format == "Compact" then
						local ok_enc, result_blob = pcall(Codec.encode, profile.Data)
						if ok_enc == true then
							compact_blob = result_blob
						else
							encode_problem = tostring(result_blob)
						end
						if compact_blob ~= nil and options.VerifyWrites == true then
							verify_problem = VerifyBlob(compact_blob, profile.Data)
							if verify_problem ~= nil then
								compact_blob = nil
							end
						end
					end

					written_format = Envelope.writeData(latest_data, profile.Data, compact_blob, compact_blob ~= nil)
					if written_format == "Compact" then
						written_blob = compact_blob
						compare_blob = compact_blob
					elseif skip_bookkeeping == true and options.IsDirty == nil and compat_compare_paid == false then
						-- Compat byte-compare baseline, only when a skip can happen: exactly
						-- the Data being written (live table, serialized after this returns).
						local ok_enc, blob = pcall(Codec.encode, profile.Data)
						compare_blob = if ok_enc then blob else nil
					end

					latest_data.RobloxMetaData = profile.RobloxMetaData
					latest_data.UserIds = profile.UserIds

					if skip_bookkeeping == true then
						local ok_aux, aux = pcall(EncodeAux, profile)
						written_aux = if ok_aux then aux else nil
					end

					if is_overwriting ~= true then
						latest_data.MetaData.LastUpdate = os.time()

						if is_ending_session == true then
							latest_data.MetaData.ActiveSession = nil
						end
					else
						latest_data.MetaData.ActiveSession = nil
						latest_data.MetaData.ForceLoadSession = nil
					end

					wrote = true
				end
			end,
		}, profile.is_mock)

		if verify_problem ~= nil then
			ReportDataError(profile, `{verify_problem}; this save was written in the plain stock format`, "verify")
		elseif encode_problem ~= nil then
			-- Codec rejects it: write it plain like stock; if the DataStore rejects it too,
			-- that call's OnError names the path.
			ReportDataError(
				profile,
				`Data is not Codec-encodable ({encode_problem}); saving in the plain stock format`,
				"encode",
				true
			)
		end

		if cleared_hook_dirty == true and not (loaded_data ~= nil and key_info ~= nil and wrote == true) then
			-- ClearDirty ran but the write didn't land: stop trusting IsDirty until a write succeeds.
			profile.hook_unsaved = true
		end

		if loaded_data ~= nil and key_info ~= nil then
			-- [Anchor] Bookkeeping for a successful write of our state:
			if wrote == true then
				profile.last_write_clock = os.clock()
				profile.saved_aux = written_aux
				profile.meta_dirty = false
				if cleared_hook_dirty == true then
					profile.hook_unsaved = false
				end
				profile.saved_blob = compare_blob
				if written_blob ~= nil then
					SetLastSavedBlob(profile, written_blob)
				else
					SetLastSavedTable(profile, loaded_data.Data)
				end
				profile.written_format = written_format
				if written_blob ~= nil then
					local size = Envelope.estimateSize(written_blob, written_format == "Compact")
					if size > SIZE_WARN_BYTES then
						ReportDataError(
							profile,
							`Profile is about {math.floor(size / 1024)} KB serialized; the DataStore limit is 4 MB`,
							"size"
						)
					end
				end
			end

			if is_overwriting == true then
				result = wrote
				break
			end

			repeat_save_flag = false

			local active_session = loaded_data.MetaData.ActiveSession
			local session_load_count = Envelope.getLoadCount(loaded_data.MetaData)
			local session_owns_profile = false

			if type(active_session) == "table" then
				session_owns_profile = IsThisSession(active_session) and session_load_count == profile.load_index
			end

			local force_load_session = loaded_data.MetaData.ForceLoadSession
			local force_load_pending = false
			if type(force_load_session) == "table" then
				force_load_pending = not IsThisSession(force_load_session)
			end

			local is_active = profile:IsActive()

			result = wrote

			-- If another server is trying to start a session for this profile - end the session:

			if force_load_pending == true and session_owns_profile == true then
				if is_active == true then
					SaveProfileAsync(profile, true, false, "External")
				end
				break
			end

			-- Clearing processed update list / Detecting new updates:

			local locked_updates = profile.locked_global_updates -- [index] = true, ...
			local received_updates = profile.received_global_updates -- [index] = true, ...
			local active_updates = loaded_data.GlobalUpdates[2]

			local new_updates = {} -- {}, ...
			local still_pending = {} -- [index] = true, ...

			for _, update in ipairs(active_updates) do
				if locked_updates[update[1]] == true then
					still_pending[update[1]] = true
				elseif received_updates[update[1]] ~= true then
					received_updates[update[1]] = true
					table.insert(new_updates, update)
				end
			end

			for index in pairs(locked_updates) do
				if still_pending[index] ~= true then
					locked_updates[index] = nil
				end
			end

			-- Updating profile values:

			profile.KeyInfo = key_info
			if wrote ~= true then
				SetLastSavedFromRaw(profile, loaded_data)
			end
			profile.global_updates = loaded_data.GlobalUpdates and loaded_data.GlobalUpdates[2] or {}

			if session_owns_profile == true then
				if is_active == true and is_ending_session ~= true then
					-- Processing new global updates (messages):

					for _, update in ipairs(new_updates) do
						local index = update[1]
						local update_data = update[#update] -- Backwards compatibility with ProfileService

						-- [Anchor] internal handlers (trades, gifts) first:
						if RunMessageHooks(profile, index, update_data) == true then
							continue
						end

						for _, handler in ipairs(profile.message_handlers) do
							local is_processed = false
							local processed_callback = function()
								is_processed = true
								locked_updates[index] = true
							end

							local send_update_data = DeepCopyTable(update_data)

							task.spawn(handler, send_update_data, processed_callback)

							if is_processed == true then
								break
							end
						end
					end
				end
			else
				result = false

				if profile.roblox_message_subscription ~= nil then
					profile.roblox_message_subscription:Disconnect()
				end

				if is_active == true then
					RemoveProfileFromAutoSave(profile)
					profile.OnSessionEnd:Fire()
				end
			end

			if #Hooks.AfterSave > 0 then
				-- `wrote`, not `result`: a release save writes our state but ends the session.
				RunHookList(Hooks.AfterSave, profile, wrote, loaded_data)
			end

			if profile.OnAfterSave:GetListenerCount() > 0 then
				profile.OnAfterSave:Fire(profile.LastSavedData)
			end
		elseif repeat_save_flag == true then
			-- DataStore call likely resulted in an error; Repeat the DataStore call shortly
			task.wait(exp_backoff)
			exp_backoff = math.min(if last_save_reason == "Shutdown" then 8 else 20, exp_backoff * 2)
		end
	end

	ActiveProfileSaveJobs = ActiveProfileSaveJobs - 1

	if release_token ~= nil then
		local pending = PendingReleases[release_token] - 1
		PendingReleases[release_token] = if pending > 0 then pending else nil
	end

	return result
end

-- [Anchor] Ends a session we just claimed but can't use (e.g. undecodable Compact data):
-- clears ActiveSession only if we still own it, never touches Data.
local function ReleaseLockOnly(profile_store, profile_key, is_mock, load_index)
	UpdateAsync(profile_store, profile_key, {
		ExistingProfileHandle = nil,
		MissingProfileHandle = nil,
		EditProfile = function(latest_data)
			local meta = latest_data.MetaData
			if type(meta) ~= "table" then
				return
			end
			local active_session = meta.ActiveSession
			if
				type(active_session) == "table"
				and IsThisSession(active_session)
				and Envelope.getLoadCount(meta) == load_index
			then
				meta.ActiveSession = nil
				meta.LastUpdate = os.time()
			end
		end,
	}, is_mock)
end

----- Public -----

--[[
	Saved profile structure:

	{
		Data = {},  -- [Anchor] or { AnchorBlob = buffer } in Compact format

		MetaData = {
			ProfileCreateTime = 0,
			SessionLoadCount = 0,  -- [Anchor] "Anchor" in Compact format (real count in Anchor.LoadCount)
			ActiveSession = {place_id, game_job_id, unique_session_id} / nil,
			ForceLoadSession = {place_id, game_job_id} / nil,
			LastUpdate = 0, -- os.time()
			MetaTags = {}, -- Backwards compatibility with ProfileService
			Anchor = {...} / nil, -- [Anchor] our bookkeeping only
		},

		RobloxMetaData = {},
		UserIds = {},

		GlobalUpdates = {
			update_index,
			{
				{update_index, data}, ...
			},
		},
	}
--]]

local ProfileMethods = {}

local Profile = {}
Profile.__index = function(self, key)
	local method = ProfileMethods[key]
	if method ~= nil then
		return method
	end
	if key == "LastSavedData" then
		-- [Anchor] lazy decode of the last saved Compact blob:
		local blob = rawget(self, "lsd_blob")
		if blob ~= nil and self.ProfileStore.anchor_options.LastSavedData ~= false then
			local ok, value = pcall(Codec.decode, blob)
			if ok == true then
				rawset(self, "LastSavedData", value)
				return value
			end
			ReportDataError(self, `LastSavedData could not be decoded: {tostring(value)}`, "lsd")
		end
	end
	return nil
end

-- data: decoded Data table; blob: the stored Compact blob it came from (or nil)
function Profile.New(raw_data, data, blob, key_info, profile_store, key, is_mock, session_token)
	local meta = raw_data.MetaData
	local session = meta and meta.ActiveSession or nil

	local global_updates = raw_data.GlobalUpdates and raw_data.GlobalUpdates[2] or {}
	local received_global_updates = {}

	for _, update in ipairs(global_updates) do
		received_global_updates[update[1]] = true
	end

	local load_count = Envelope.getLoadCount(meta) or 0

	local self = {
		Data = data,
		-- LastSavedData: lazy (see Profile.__index)

		FirstSessionTime = meta and meta.ProfileCreateTime or 0,
		SessionLoadCount = load_count,
		Session = session and { PlaceId = session[1], JobId = session[2] },

		RobloxMetaData = raw_data.RobloxMetaData or {},
		UserIds = raw_data.UserIds or {},
		KeyInfo = key_info,

		OnAfterSave = Signal.New(),
		OnSave = Signal.New(),
		OnLastSave = Signal.New(),
		OnSessionEnd = Signal.New(),

		ProfileStore = profile_store,
		Key = key,

		load_timestamp = os.clock(),
		is_mock = is_mock,
		session_token = session_token or "",
		load_index = load_count,
		locked_global_updates = {},
		received_global_updates = received_global_updates,
		message_handlers = {},
		global_updates = global_updates,

		-- [Anchor]
		anchor_meta = Envelope.readAnchorMeta(meta),
		claimed_global_updates = {},
		saved_blob = nil, -- blob of the last written Data, for the clean-save skip (or nil)
		lsd_blob = nil, -- Compact blob LastSavedData is lazily decoded from (or nil)
		saved_aux = nil,
		last_write_clock = nil,
		meta_dirty = false,
		hook_unsaved = false,
		skipped_saves = 0,
		written_format = if blob ~= nil then "Compact" else "Compat",
	}
	setmetatable(self, Profile)

	-- LastSavedData snapshot (SPEC section 9): a stored Compact blob is reused as is
	-- (decoded on first read); plain data gets stock's deep copy, unless the store set
	-- LastSavedData = false. No encode or verify on load.
	local options = profile_store.anchor_options
	if blob ~= nil then
		self.saved_blob = blob -- equals what's stored: the clean-skip baseline too
		self.lsd_blob = blob
	elseif options.LastSavedData ~= false then
		rawset(self, "LastSavedData", DeepCopyTable(data)) -- stock
	end
	if SkipPossible(options) then
		local ok_aux, aux = pcall(EncodeAux, self)
		if ok_aux == true then
			self.saved_aux = aux
		end
	end

	return self
end

function ProfileMethods:IsActive()
	return ActiveSessionCheck[self.session_token] == self
end

function ProfileMethods:Reconcile()
	ReconcileTable(self.Data, self.ProfileStore.template)
end

function ProfileMethods:EndSession()
	if self:IsActive() == true then
		task.spawn(SaveProfileAsync, self, true, nil, "Manual") -- Call save function in a new thread with release_from_session = true
	end
end

function ProfileMethods:AddUserId(user_id) -- Associates user_id with profile (GDPR compliance)
	if type(user_id) ~= "number" or user_id % 1 ~= 0 then
		warn(`[{LIB}]: Invalid UserId argument for :AddUserId() ({tostring(user_id)}); Traceback:\n` .. debug.traceback())
		return
	end

	if user_id < 0 and self.is_mock ~= true and DataStoreState == "Access" then
		return -- Avoid giving real Roblox APIs negative UserId's
	end

	if table.find(self.UserIds, user_id) == nil then
		table.insert(self.UserIds, user_id)
	end
end

function ProfileMethods:RemoveUserId(user_id) -- Removes user_id association with profile (safe function)
	if type(user_id) ~= "number" or user_id % 1 ~= 0 then
		warn(
			`[{LIB}]: Invalid UserId argument for :RemoveUserId() ({tostring(user_id)}); Traceback:\n`
				.. debug.traceback()
		)
		return
	end

	local index = table.find(self.UserIds, user_id)

	if index ~= nil then
		table.remove(self.UserIds, index)
	end
end

function ProfileMethods:SetAsync() -- Saves the profile to the DataStore and removes the session lock
	if self.view_mode ~= true then
		error(`[{LIB}]: :SetAsync() can only be used in view mode`)
	end

	SaveProfileAsync(self, nil, true)
end

function ProfileMethods:MessageHandler(fn)
	if type(fn) ~= "function" then
		error(`[{LIB}]: fn argument is not a function`)
	end

	if self.view_mode ~= true and self:IsActive() ~= true then
		return -- Don't process messages if the profile session was ended
	end

	local locked_updates = self.locked_global_updates
	local claimed_updates = self.claimed_global_updates
	table.insert(self.message_handlers, fn)

	for _, update in ipairs(self.global_updates) do
		local index = update[1]
		local update_data = update[#update] -- Backwards compatibility with ProfileService

		if locked_updates[index] ~= true and claimed_updates[index] ~= true then
			local processed_callback = function()
				locked_updates[index] = true
			end

			local send_update_data = DeepCopyTable(update_data)

			task.spawn(fn, send_update_data, processed_callback)
		end
	end
end

function ProfileMethods:Save()
	if self.view_mode == true then
		error(`[{LIB}]: Can't save profile in view mode; Should you be calling :SetAsync() instead?`)
	end

	if self:IsActive() == false then
		warn(
			`[{LIB}]: Attempted saving an inactive profile (STORE:{self.ProfileStore.Name}; KEY:{self.Key});`
				.. ` Traceback:\n`
				.. debug.traceback()
		)
		return
	end

	-- Move the profile right behind the auto save index to delay the next auto save for it:
	RemoveProfileFromAutoSave(self)
	AddProfileToAutoSave(self)

	-- Perform save in new thread:
	task.spawn(SaveProfileAsync, self)
end

-- [Anchor] Yielding forced save. Returns true once a DataStore write that includes the
-- profile's current state (Data, RobloxMetaData, UserIds, MetaData.Anchor) succeeded
-- while this session owned the key; false if the write failed, was blocked by
-- validation, or the session was lost. Never skipped as "clean".
function ProfileMethods:SaveAsync(): boolean
	if self.view_mode == true then
		error(`[{LIB}]: Can't save profile in view mode; Should you be calling :SetAsync() instead?`)
	end

	if self:IsActive() == false then
		return false
	end

	RemoveProfileFromAutoSave(self)
	AddProfileToAutoSave(self)

	return SaveProfileAsync(self, nil, nil, nil, "Forced") == true
end

-- [Anchor] Marks MetaData.Anchor (profile.anchor_meta) as changed so the next autosave
-- is not skipped. Feature modules call this after editing anchor_meta.
function ProfileMethods:MarkMetaDirty()
	self.meta_dirty = true
end

local ProfileStore = {
	IsClosing = false,
	IsCriticalState = false,
	OnError = OnError, -- (message, store_name, profile_key)
	OnOverwrite = OnOverwrite, -- (store_name, profile_key)
	OnCriticalToggle = Signal.New(), -- (is_critical)
	DataStoreState = "NotReady", -- ("NotReady", "NoInternet", "NoAccess", "Access")
}
ProfileStore.__index = ProfileStore
ModuleTable = ProfileStore

function ProfileStore.SetConstant(name, value)
	if type(value) ~= "number" then
		error(`[{LIB}]: Invalid value type`)
	end

	if name == "AUTO_SAVE_PERIOD" then
		AUTO_SAVE_PERIOD = value
	elseif name == "LOAD_REPEAT_PERIOD" then
		LOAD_REPEAT_PERIOD = value
	elseif name == "FIRST_LOAD_REPEAT" then
		FIRST_LOAD_REPEAT = value
	elseif name == "SESSION_STEAL" then
		SESSION_STEAL = value
	elseif name == "ASSUME_DEAD" then
		ASSUME_DEAD = value
	elseif name == "START_SESSION_TIMEOUT" then
		START_SESSION_TIMEOUT = value
	elseif name == "CRITICAL_STATE_ERROR_COUNT" then
		CRITICAL_STATE_ERROR_COUNT = value
	elseif name == "CRITICAL_STATE_ERROR_EXPIRE" then
		CRITICAL_STATE_ERROR_EXPIRE = value
	elseif name == "CRITICAL_STATE_EXPIRE" then
		CRITICAL_STATE_EXPIRE = value
	elseif name == "MAX_MESSAGE_QUEUE" then
		MAX_MESSAGE_QUEUE = value
	else
		error(`[{LIB}]: Invalid constant name was provided`)
	end
end

function ProfileStore.Test()
	return {
		ActiveSessionCheck = ActiveSessionCheck,
		AutoSaveList = AutoSaveSnapshot(),
		ActiveProfileLoadJobs = ActiveProfileLoadJobs,
		ActiveProfileSaveJobs = ActiveProfileSaveJobs,
		MockStore = MockStore,
		UserMockStore = UserMockStore,
		UpdateQueue = UpdateQueue,
	}
end

local VALID_FORMATS = { Compat = true, Compact = true }

local function ResolveOptions(options)
	if options ~= nil and type(options) ~= "table" then
		error(`[{LIB}]: Invalid options argument`)
	end
	options = options or {}
	local format = options.Format or "Compat"
	if VALID_FORMATS[format] ~= true then
		error(`[{LIB}]: Invalid Format "{tostring(format)}" (expected "Compat" or "Compact")`)
	end
	local lock_refresh = options.LockRefresh or DEFAULT_LOCK_REFRESH
	if type(lock_refresh) ~= "number" or lock_refresh < 0 then
		error(`[{LIB}]: Invalid LockRefresh`)
	end
	if options.IsDirty ~= nil and type(options.IsDirty) ~= "function" then
		error(`[{LIB}]: IsDirty must be a function`)
	end
	if options.ClearDirty ~= nil and type(options.ClearDirty) ~= "function" then
		error(`[{LIB}]: ClearDirty must be a function`)
	end
	return {
		Format = format,
		VerifyWrites = options.VerifyWrites ~= false,
		LockRefresh = lock_refresh,
		IsDirty = options.IsDirty,
		ClearDirty = options.ClearDirty,
		Mock = options.Mock == true, -- [Anchor] every call on this store uses the in-memory store
		LastSavedData = options.LastSavedData ~= false, -- false: never keep profile.LastSavedData
	}
end

-- [Anchor] third argument `options` is ours (stock ignores extra args):
--   { Format = "Compat"|"Compact", VerifyWrites = true, LockRefresh = 300,
--     IsDirty = fn(profile) -> boolean, ClearDirty = fn(profile),
--     Mock = false -- true: every call on this store uses the in-memory (store.Mock) store,
--     LastSavedData = true -- false: skip the load deep copy; profile.LastSavedData stays nil }
function ProfileStore.New(store_name, template, options)
	template = template or {}

	if type(store_name) ~= "string" then
		error(`[{LIB}]: Invalid or missing "store_name"`)
	elseif string.len(store_name) == 0 then
		error(`[{LIB}]: store_name cannot be an empty string`)
	elseif string.len(store_name) > 50 then
		error(`[{LIB}]: store_name is too long`)
	end

	if type(template) ~= "table" then
		error(`[{LIB}]: Invalid template argument`)
	end

	local self
	self = {

		Mock = {

			Name = store_name,

			StartSessionAsync = function(_, profile_key, params)
				MockFlag = true
				return self:StartSessionAsync(profile_key, params)
			end,
			MessageAsync = function(_, profile_key, message)
				MockFlag = true
				return self:MessageAsync(profile_key, message)
			end,
			GetAsync = function(_, profile_key, version)
				MockFlag = true
				return self:GetAsync(profile_key, version)
			end,
			VersionQuery = function(_, profile_key, sort_direction, min_date, max_date)
				MockFlag = true
				return self:VersionQuery(profile_key, sort_direction, min_date, max_date)
			end,
			RemoveAsync = function(_, profile_key)
				MockFlag = true
				return self:RemoveAsync(profile_key)
			end,
		},

		Name = store_name,

		template = template,
		data_store = nil,
		load_jobs = {},
		mock_load_jobs = {},
		is_ready = true,

		anchor_options = ResolveOptions(options), -- [Anchor]
	}
	setmetatable(self, ProfileStore)

	local datastore_options = Instance.new("DataStoreOptions")
	datastore_options:SetExperimentalFeatures({ v2 = true })

	if DataStoreState == "NotReady" then
		-- The module is not sure whether DataStores are accessible yet:

		self.is_ready = false

		task.spawn(function()
			repeat
				task.wait()
			until DataStoreState ~= "NotReady"

			if DataStoreState == "Access" then
				self.data_store = DataStoreService:GetDataStore(store_name, nil, datastore_options)
			end

			self.is_ready = true
		end)
	elseif DataStoreState == "Access" then
		self.data_store = DataStoreService:GetDataStore(store_name, nil, datastore_options)
	end

	return self
end

local function RobloxMessageSubscription(profile, unique_session_id)
	local last_roblox_message = 0

	local ok, roblox_message_subscription = pcall(function()
		return MessagingService:SubscribeAsync("PS_" .. unique_session_id, function(message)
			local load_count = type(message.Data) == "table" and message.Data.LoadCount or nil
			-- [Anchor] a stock server reading a Compact profile sends the poison string
			if load_count ~= nil and (load_count == profile.SessionLoadCount or load_count == Envelope.POISON) then
				-- High reaction rate, based on numPlayers × 10 DataStore budget as of writing
				if os.clock() - last_roblox_message > 6 then
					last_roblox_message = os.clock()
					if profile:IsActive() == true then
						if message.Data.EndSession == true then
							SaveProfileAsync(profile, true, false, "External")
						else
							profile:Save()
						end
					end
				end
			end
		end)
	end)

	if ok == false then
		warn(`[{LIB}]: MessagingService subscription failed - {tostring(roblox_message_subscription)}`)
		return
	end

	if profile:IsActive() == true then
		profile.roblox_message_subscription = roblox_message_subscription
	else
		roblox_message_subscription:Disconnect()
	end
end

-- [Anchor] Messages present at session start go to internal handlers right away.
local function RunLoadHooks(profile)
	if #Hooks.Message > 0 then
		for _, update in ipairs(profile.global_updates) do
			local index = update[1]
			if profile.locked_global_updates[index] ~= true then
				RunMessageHooks(profile, index, update[#update])
			end
		end
	end
	if #Hooks.Loaded > 0 then
		RunHookList(Hooks.Loaded, profile)
	end
end

function ProfileStore:StartSessionAsync(profile_key, params)
	local is_mock = ReadMockFlag(self)

	if type(profile_key) ~= "string" then
		error(`[{LIB}]: profile_key must be a string`)
	elseif string.len(profile_key) == 0 then
		error(`[{LIB}]: Invalid profile_key`)
	elseif string.len(profile_key) > 50 then
		error(`[{LIB}]: profile_key is too long`)
	end

	if params ~= nil and type(params) ~= "table" then
		error(`[{LIB}]: Invalid params`)
	end

	params = params or {}

	if ProfileStore.IsClosing == true then
		return nil
	end

	WaitForStoreReady(self)

	local session_token = SessionToken(self.Name, profile_key, is_mock)

	if ActiveSessionCheck[session_token] ~= nil then
		error(`[{LIB}]: Profile (STORE:{self.Name}; KEY:{profile_key}) is already loaded in this session`)
	end

	ActiveProfileLoadJobs = ActiveProfileLoadJobs + 1

	local is_user_cancel = false

	local function cancel_condition()
		if is_user_cancel == false then
			if params.Cancel ~= nil then
				is_user_cancel = params.Cancel() == true
			end
			return is_user_cancel
		end
		return true
	end

	-- [Anchor] Same-server quick rejoin: if this server is still saving the previous
	-- session's release (e.g. retrying after DataStore errors), wait for it. Stock loads
	-- immediately: the stored ActiveSession still names this server, so the new session
	-- claims it with the OLD data and the pending release then no longer owns the key,
	-- silently dropping the previous session's last changes.
	local release_wait_start = os.clock()
	while PendingReleases[session_token] ~= nil do
		local timed_out = params.Cancel == nil and os.clock() - release_wait_start >= START_SESSION_TIMEOUT
		if timed_out or ProfileStore.IsClosing == true or cancel_condition() == true then
			ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
			return nil
		end
		task.wait()
	end

	local user_steal = params.Steal == true

	local force_load_steps = 0 -- Session conflict handling values
	local request_force_load = true
	local steal_session = false

	local start = os.clock()
	local exp_backoff = 1

	while ProfileStore.IsClosing == false and cancel_condition() == false do
		-- Load profile:

		-- SPECIAL CASE - If StartSessionAsync is called for the same key again before another StartSessionAsync finishes,
		-- grab the DataStore return for the new call. The early call will return nil. This is supposed to retain
		-- expected and efficient behavior in cases where a player would quickly rejoin the same server.

		LoadIndex += 1
		local load_id = LoadIndex
		local profile_load_jobs = is_mock == true and self.mock_load_jobs or self.load_jobs
		local profile_load_job = profile_load_jobs[profile_key] -- {load_id, {loaded_data, key_info} or nil}

		local loaded_data, key_info
		local unique_session_id = HttpService:GenerateGUID(false)

		if profile_load_job ~= nil then
			profile_load_job[1] = load_id -- Steal load job
			while profile_load_job[2] == nil do -- Wait for job to finish
				task.wait()
			end
			if profile_load_job[1] == load_id then -- Load job hasn't been double-stolen
				loaded_data, key_info = table.unpack(profile_load_job[2])
				profile_load_jobs[profile_key] = nil
			else
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil
			end
		else
			profile_load_job = { load_id, nil }
			profile_load_jobs[profile_key] = profile_load_job

			profile_load_job[2] = table.pack(UpdateAsync(self, profile_key, {
				ExistingProfileHandle = function(latest_data)
					if ProfileStore.IsClosing == true or cancel_condition() == true then
						return
					end

					local active_session = latest_data.MetaData.ActiveSession
					local force_load_session = latest_data.MetaData.ForceLoadSession

					if active_session == nil then
						latest_data.MetaData.ActiveSession = { PlaceId, JobId, unique_session_id }
						latest_data.MetaData.ForceLoadSession = nil
					elseif type(active_session) == "table" then
						if IsThisSession(active_session) == false then
							local last_update = latest_data.MetaData.LastUpdate
							if last_update ~= nil then
								if os.time() - last_update > ASSUME_DEAD then
									latest_data.MetaData.ActiveSession = { PlaceId, JobId, unique_session_id }
									latest_data.MetaData.ForceLoadSession = nil
									return
								end
							end
							if steal_session == true or user_steal == true then
								local force_load_interrupted = if force_load_session ~= nil
									then not IsThisSession(force_load_session)
									else true
								if force_load_interrupted == false or user_steal == true then
									latest_data.MetaData.ActiveSession = { PlaceId, JobId, unique_session_id }
									latest_data.MetaData.ForceLoadSession = nil
								end
							elseif request_force_load == true then
								latest_data.MetaData.ForceLoadSession = { PlaceId, JobId }
							end
						else
							latest_data.MetaData.ForceLoadSession = nil
						end
					end
				end,
				MissingProfileHandle = function(latest_data)
					local is_cancel = ProfileStore.IsClosing == true or cancel_condition() == true

					latest_data.Data = DeepCopyTable(self.template)
					latest_data.MetaData = {
						ProfileCreateTime = os.time(),
						SessionLoadCount = 0,
						ActiveSession = if is_cancel == false then { PlaceId, JobId, unique_session_id } else nil,
						ForceLoadSession = nil,
						MetaTags = {}, -- Backwards compatibility with ProfileService
					}
				end,
				EditProfile = function(latest_data)
					if ProfileStore.IsClosing == true or cancel_condition() == true then
						return
					end

					local active_session = latest_data.MetaData.ActiveSession
					if active_session ~= nil and IsThisSession(active_session) == true then
						Envelope.bumpLoadCount(latest_data.MetaData) -- [Anchor] stock: SessionLoadCount + 1
						latest_data.MetaData.LastUpdate = os.time()
					end
				end,
			}, is_mock))
			if profile_load_job[1] == load_id then -- Load job hasn't been stolen
				loaded_data, key_info = table.unpack(profile_load_job[2])
				profile_load_jobs[profile_key] = nil
			else
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil -- Load job stolen
			end
		end

		-- Handle load_data:

		if loaded_data ~= nil and key_info ~= nil then
			local active_session = loaded_data.MetaData.ActiveSession
			if type(active_session) == "table" then
				if IsThisSession(active_session) == true then
					-- Profile is now taken by this session:

					-- [Anchor] decode the stored format before handing out a profile:
					local ok_read, data, blob, read_error, stray = Envelope.readData(loaded_data)
					if ok_read == false then
						local message =
							`Profile data could not be decoded ({tostring(read_error)}); session not started and data left untouched`
						warn(`[{LIB}]: {message} (STORE:{self.Name}; KEY:{profile_key})`)
						OnError:Fire(message, self.Name, profile_key)
						ReleaseLockOnly(self, profile_key, is_mock, Envelope.getLoadCount(loaded_data.MetaData))
						ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
						return nil
					end

					ReportStrayKeys(self.Name, profile_key, stray)
					local profile =
						Profile.New(loaded_data, data, blob, key_info, self, profile_key, is_mock, session_token)
					profile.last_write_clock = os.clock() -- the session-start write refreshed the lock
					AddProfileToAutoSave(profile)

					if is_mock ~= true and DataStoreState == "Access" then
						-- Use MessagingService to quickly detect session conflicts and resolve them quickly:
						task.spawn(RobloxMessageSubscription, profile, unique_session_id) -- Blocking prevention
					end

					if ProfileStore.IsClosing == true or cancel_condition() == true then
						-- The server has initiated a shutdown by the time this profile was loaded
						SaveProfileAsync(profile, true) -- Release profile and yield until the DataStore call is finished
						profile = nil -- Don't return the profile object
					else
						RunLoadHooks(profile) -- [Anchor]
					end

					ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
					return profile
				else
					if ProfileStore.IsClosing == true or cancel_condition() == true then
						ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
						return nil
					end

					-- Profile is taken by some other session:

					local force_load_session = loaded_data.MetaData.ForceLoadSession
					local force_load_interrupted = if force_load_session ~= nil
						then not IsThisSession(force_load_session)
						else true

					if force_load_interrupted == false then
						if request_force_load == false then
							force_load_steps = force_load_steps + 1
							if force_load_steps >= math.ceil(SESSION_STEAL / LOAD_REPEAT_PERIOD) then
								steal_session = true
							end
						end

						-- Request the remote server to end its session:
						if type(active_session[3]) == "string" then
							local session_load_count = Envelope.getLoadCount(loaded_data.MetaData) or 0
							task.spawn(
								MessagingService.PublishAsync,
								MessagingService,
								"PS_" .. active_session[3],
								{ LoadCount = session_load_count, EndSession = true }
							)
						end

						-- Attempt to load the profile again after a delay
						local wait_until = os.clock()
							+ if request_force_load == true then FIRST_LOAD_REPEAT else LOAD_REPEAT_PERIOD
						repeat
							task.wait()
						until os.clock() >= wait_until or ProfileStore.IsClosing == true
					else
						-- Another session tried to load this profile:
						ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
						return nil
					end

					request_force_load = false -- Only request a force load once
				end
			else
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil -- In this scenario it is likely that this server started shutting down
			end
		else
			-- A DataStore call has likely ended in an error:

			local default_timeout = false

			if params.Cancel == nil then
				default_timeout = os.clock() - start >= START_SESSION_TIMEOUT
			end

			if default_timeout == true or ProfileStore.IsClosing == true or cancel_condition() == true then
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil
			end

			task.wait(exp_backoff) -- Repeat the call shortly
			exp_backoff = math.min(20, exp_backoff * 2)
		end
	end

	ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
	return nil -- Game started shutting down or the request was cancelled - don't return the profile
end

function ProfileStore:MessageAsync(profile_key, message)
	local is_mock = ReadMockFlag(self)

	if type(profile_key) ~= "string" then
		error(`[{LIB}]: profile_key must be a string`)
	elseif string.len(profile_key) == 0 then
		error(`[{LIB}]: Invalid profile_key`)
	elseif string.len(profile_key) > 50 then
		error(`[{LIB}]: profile_key is too long`)
	end

	if type(message) ~= "table" then
		error(`[{LIB}]: message must be a table`)
	end

	if ProfileStore.IsClosing == true then
		return false
	end

	WaitForStoreReady(self)

	local exp_backoff = 1

	while ProfileStore.IsClosing == false do
		-- Updating profile:

		local loaded_data = UpdateAsync(self, profile_key, {
			ExistingProfileHandle = nil,
			MissingProfileHandle = nil,
			EditProfile = function(latest_data)
				local global_updates = latest_data.GlobalUpdates
				local update_list = global_updates[2]
				--{
				--	update_index,
				--	{
				--		{update_index, data}, ...
				--	},
				--},

				global_updates[1] += 1
				table.insert(update_list, { global_updates[1], message })

				-- Clearing queue if above limit:

				while #update_list > MAX_MESSAGE_QUEUE do
					table.remove(update_list, 1)
				end
			end,
		}, is_mock)

		if loaded_data ~= nil then
			local session_token = SessionToken(self.Name, profile_key, is_mock)

			local profile = ActiveSessionCheck[session_token]

			if profile ~= nil then
				-- The message was sent to a profile that is active in this server:
				profile:Save()
			else
				local meta_data = loaded_data.MetaData or {}
				local active_session = meta_data.ActiveSession
				local session_load_count = Envelope.getLoadCount(meta_data) or 0

				if type(active_session) == "table" and type(active_session[3]) == "string" then
					-- Request the remote server to auto-save sooner and receive the message:
					task.spawn(
						MessagingService.PublishAsync,
						MessagingService,
						"PS_" .. active_session[3],
						{ LoadCount = session_load_count }
					)
				end
			end

			return true
		else
			task.wait(exp_backoff) -- A DataStore call has likely ended in an error - repeat the call shortly
			exp_backoff = math.min(20, exp_backoff * 2)
		end
	end

	return false
end

function ProfileStore:GetAsync(profile_key, version)
	local is_mock = ReadMockFlag(self)

	if type(profile_key) ~= "string" then
		error(`[{LIB}]: profile_key must be a string`)
	elseif string.len(profile_key) == 0 then
		error(`[{LIB}]: Invalid profile_key`)
	elseif string.len(profile_key) > 50 then
		error(`[{LIB}]: profile_key is too long`)
	end

	if ProfileStore.IsClosing == true then
		return nil
	end

	WaitForStoreReady(self)

	if version ~= nil and (is_mock or DataStoreState ~= "Access") then
		return nil -- No version support in mock mode
	end

	local exp_backoff = 1

	while ProfileStore.IsClosing == false do
		-- Load profile:

		local loaded_data, key_info = UpdateAsync(
			self,
			profile_key,
			{
				ExistingProfileHandle = nil,
				MissingProfileHandle = function(latest_data)
					latest_data.Data = DeepCopyTable(self.template)
					latest_data.MetaData = {
						ProfileCreateTime = os.time(),
						SessionLoadCount = 0,
						ActiveSession = nil,
						ForceLoadSession = nil,
						MetaTags = {}, -- Backwards compatibility with ProfileService
					}
				end,
				EditProfile = nil,
			},
			is_mock,
			true, -- Use :GetAsync()
			version -- DataStore key version
		)

		-- Handle load_data:

		if loaded_data ~= nil then
			if key_info == nil then
				return nil -- Load was successful, but the key was empty - return no profile object
			end

			-- [Anchor]
			local ok_read, data, blob, read_error, stray = Envelope.readData(loaded_data)
			if ok_read == false then
				local message = `Profile data could not be decoded ({tostring(read_error)})`
				warn(`[{LIB}]: {message} (STORE:{self.Name}; KEY:{profile_key})`)
				OnError:Fire(message, self.Name, profile_key)
				return nil
			end
			ReportStrayKeys(self.Name, profile_key, stray)

			local profile = Profile.New(loaded_data, data, blob, key_info, self, profile_key, is_mock)
			profile.view_mode = true

			return profile
		else
			task.wait(exp_backoff) -- A DataStore call has likely ended in an error - repeat the call shortly
			exp_backoff = math.min(20, exp_backoff * 2)
		end
	end

	return nil -- Game started shutting down - don't return the profile
end

function ProfileStore:RemoveAsync(profile_key)
	local is_mock = ReadMockFlag(self)

	if type(profile_key) ~= "string" or string.len(profile_key) == 0 then
		error(`[{LIB}]: Invalid profile_key`)
	end

	if ProfileStore.IsClosing == true then
		return false
	end

	WaitForStoreReady(self)

	local wipe_status = false

	local next_in_queue = WaitInUpdateQueue(SessionToken(self.Name, profile_key, is_mock))

	if is_mock == true then -- Used when the profile is accessed through ProfileStore.Mock
		local mock_data_store = UserMockStore[self.Name]

		if mock_data_store ~= nil then
			mock_data_store[profile_key] = nil
			if next(mock_data_store) == nil then
				UserMockStore[self.Name] = nil
			end
		end

		wipe_status = true
		task.wait() -- Simulate API call yield
	elseif DataStoreState ~= "Access" then -- Used when API access is disabled
		local mock_data_store = MockStore[self.Name]

		if mock_data_store ~= nil then
			mock_data_store[profile_key] = nil
			if next(mock_data_store) == nil then
				MockStore[self.Name] = nil
			end
		end

		wipe_status = true
		task.wait() -- Simulate API call yield
	else -- Live DataStore
		wipe_status = pcall(function()
			self.data_store:RemoveAsync(profile_key)
		end)
	end

	next_in_queue()

	return wipe_status
end

local ProfileVersionQuery = {}
ProfileVersionQuery.__index = ProfileVersionQuery

function ProfileVersionQuery.New(profile_store, profile_key, sort_direction, min_date, max_date, is_mock)
	local self = {
		profile_store = profile_store,
		profile_key = profile_key,
		sort_direction = sort_direction,
		min_date = min_date,
		max_date = max_date,

		query_pages = nil,
		query_index = 0,
		query_failure = false,

		is_query_yielded = false,
		query_queue = {},

		is_mock = is_mock,
	}
	setmetatable(self, ProfileVersionQuery)

	return self
end

local function MoveVersionQueryQueue(self) -- Hidden ProfileVersionQuery method
	while #self.query_queue > 0 do
		local queue_entry = table.remove(self.query_queue, 1)

		task.spawn(queue_entry)

		if self.is_query_yielded == true then
			break
		end
	end
end

local VersionQueryNextAsyncStackingFlag = false
local WarnAboutVersionQueryOnce = false

function ProfileVersionQuery:NextAsync()
	local is_stacking = VersionQueryNextAsyncStackingFlag == true
	VersionQueryNextAsyncStackingFlag = false

	WaitForStoreReady(self.profile_store)

	if ProfileStore.IsClosing == true then
		return nil -- Silently fail :NextAsync() requests
	end

	if self.is_mock == true or DataStoreState ~= "Access" then
		if IsStudio == true and WarnAboutVersionQueryOnce == false then
			WarnAboutVersionQueryOnce = true
			warn(`[{LIB}]: :VersionQuery() is not supported in mock mode!`)
		end
		return nil -- Silently fail :NextAsync() requests
	end

	local profile
	local is_finished = false

	local function query_job()
		if self.query_failure == true then
			is_finished = true
			return
		end

		-- First "next" call loads version pages:

		if self.query_pages == nil then
			self.is_query_yielded = true

			task.spawn(function()
				VersionQueryNextAsyncStackingFlag = true
				profile = self:NextAsync()
				is_finished = true
			end)

			local list_success, error_message = pcall(function()
				self.query_pages = self.profile_store.data_store:ListVersionsAsync(
					self.profile_key,
					self.sort_direction,
					self.min_date,
					self.max_date
				)
				self.query_index = 0
			end)

			if list_success == false or self.query_pages == nil then
				warn(`[{LIB}]: Version query fail - {tostring(error_message)}`)
				self.query_failure = true
			end

			self.is_query_yielded = false

			MoveVersionQueryQueue(self)

			return
		end

		local current_page = self.query_pages:GetCurrentPage()
		local next_item = current_page[self.query_index + 1]

		-- No more entries:

		if self.query_pages.IsFinished == true and next_item == nil then
			is_finished = true
			return
		end

		-- Load next page when this page is over:

		if next_item == nil then
			self.is_query_yielded = true
			task.spawn(function()
				VersionQueryNextAsyncStackingFlag = true
				profile = self:NextAsync()
				is_finished = true
			end)

			local success, error_message = pcall(function()
				self.query_pages:AdvanceToNextPageAsync()
				self.query_index = 0
			end)

			if success == false or #self.query_pages:GetCurrentPage() == 0 then
				self.query_failure = true
			end

			self.is_query_yielded = false
			MoveVersionQueryQueue(self)

			return
		end

		-- Next page item:

		self.query_index += 1
		profile = self.profile_store:GetAsync(self.profile_key, next_item.Version)
		is_finished = true
	end

	if self.is_query_yielded == false then
		query_job()
	else
		if is_stacking == true then
			table.insert(self.query_queue, 1, query_job)
		else
			table.insert(self.query_queue, query_job)
		end
	end

	while is_finished == false do
		task.wait()
	end

	return profile
end

function ProfileStore:VersionQuery(profile_key, sort_direction, min_date, max_date)
	local is_mock = ReadMockFlag(self)

	if type(profile_key) ~= "string" or string.len(profile_key) == 0 then
		error(`[{LIB}]: Invalid profile_key`)
	end

	-- Type check:

	if
		sort_direction ~= nil
		and (typeof(sort_direction) ~= "EnumItem" or sort_direction.EnumType ~= Enum.SortDirection)
	then
		error(`[{LIB}]: Invalid sort_direction ({tostring(sort_direction)})`)
	end

	if min_date ~= nil and typeof(min_date) ~= "DateTime" and typeof(min_date) ~= "number" then
		error(`[{LIB}]: Invalid min_date ({tostring(min_date)})`)
	end

	if max_date ~= nil and typeof(max_date) ~= "DateTime" and typeof(max_date) ~= "number" then
		error(`[{LIB}]: Invalid max_date ({tostring(max_date)})`)
	end

	min_date = typeof(min_date) == "DateTime" and min_date.UnixTimestampMillis or min_date
	max_date = typeof(max_date) == "DateTime" and max_date.UnixTimestampMillis or max_date

	return ProfileVersionQuery.New(self, profile_key, sort_direction, min_date, max_date, is_mock)
end

-- DataStore API access check:

if IsStudio == true then
	task.spawn(function()
		local new_state = "NoAccess"

		local status, message = pcall(function()
			-- This will error if current instance has no Studio API access:
			DataStoreService:GetDataStore("____PS"):SetAsync("____PS", os.time())
		end)

		local no_internet_access = status == false and string.find(message, "ConnectFail", 1, true) ~= nil

		if no_internet_access == true then
			warn(`[{LIB}]: No internet access - check your network connection`)
		end

		if
			status == false
			and (
				string.find(message, "403", 1, true) ~= nil -- Cannot write to DataStore from studio if API access is not enabled
				or string.find(message, "must publish", 1, true) ~= nil -- Game must be published to access live keys
				or no_internet_access == true
			)
		then -- No internet access
			new_state = if no_internet_access == true then "NoInternet" else "NoAccess"
			print(`[{LIB}]: Roblox API services unavailable - data will not be saved`)
		else
			new_state = "Access"
			print(`[{LIB}]: Roblox API services available - data will be saved`)
		end

		DataStoreState = new_state
		ProfileStore.DataStoreState = new_state
	end)
else
	DataStoreState = "Access"
	ProfileStore.DataStoreState = "Access"
end

-- Update loop:

RunService.Heartbeat:Connect(function()
	-- Auto saving:

	if AutoSaveCount > 0 then
		local auto_save_index_speed = AUTO_SAVE_PERIOD / AutoSaveCount
		local os_clock = os.clock()
		while os_clock - LastAutoSave > auto_save_index_speed do
			LastAutoSave = LastAutoSave + auto_save_index_speed
			local profile = AutoSaveCursor
			if profile == nil then
				break -- every profile was released by a listener during this step
			end
			if os_clock - profile.load_timestamp < AUTO_SAVE_PERIOD / 2 then
				-- This profile is freshly loaded - auto saving immediately is not necessary:
				profile = nil
				for _ = 1, AutoSaveCount - 1 do
					-- Move auto save cursor to the right:
					AutoSaveCursor = AutoSaveCursor._as_next
					profile = AutoSaveCursor
					if os_clock - profile.load_timestamp >= AUTO_SAVE_PERIOD / 2 then
						break
					else
						profile = nil
					end
				end
			end
			-- Move auto save cursor to the right:
			AutoSaveCursor = AutoSaveCursor._as_next
			-- Perform save call:
			if profile ~= nil then
				task.spawn(SaveProfileAsync, profile, nil, nil, nil, "Auto") -- Auto save profile in new thread
			end
		end
	end

	-- Critical state handling:

	if ProfileStore.IsCriticalState == false then
		if #IssueQueue >= CRITICAL_STATE_ERROR_COUNT then
			ProfileStore.IsCriticalState = true
			ProfileStore.OnCriticalToggle:Fire(true)
			CriticalStateStart = os.clock()
			warn(`[{LIB}]: Entered critical state`)
		end
	else
		if #IssueQueue >= CRITICAL_STATE_ERROR_COUNT then
			CriticalStateStart = os.clock()
		elseif os.clock() - CriticalStateStart > CRITICAL_STATE_EXPIRE then
			ProfileStore.IsCriticalState = false
			ProfileStore.OnCriticalToggle:Fire(false)
			warn(`[{LIB}]: Critical state ended`)
		end
	end

	-- Issue queue:

	while true do
		local issue_time = IssueQueue[1]
		if issue_time == nil then
			break
		elseif os.clock() - issue_time > CRITICAL_STATE_ERROR_EXPIRE then
			table.remove(IssueQueue, 1)
		else
			break
		end
	end
end)

-- Release all loaded profiles when the server is shutting down:

task.spawn(function()
	while DataStoreState == "NotReady" do
		task.wait()
	end

	if DataStoreState ~= "Access" then
		game:BindToClose(function()
			ProfileStore.IsClosing = true
			task.wait() -- Mock shutdown delay
		end)

		return -- Don't wait for profiles to properly save in mock mode so studio could end the simulation faster
	end

	game:BindToClose(function()
		ProfileStore.IsClosing = true

		-- Release all active profiles:
		-- (Snapshot the autosave ring because it changes when profiles are released)

		local on_close_save_job_count = 0
		local active_profiles = AutoSaveSnapshot()

		-- Release the profiles; Releasing profiles can trigger listeners that release other profiles, so check active state:
		for _, profile in ipairs(active_profiles) do
			if profile:IsActive() == true then
				on_close_save_job_count = on_close_save_job_count + 1
				task.spawn(function() -- Save profile on new thread
					SaveProfileAsync(profile, true, nil, "Shutdown")
					on_close_save_job_count = on_close_save_job_count - 1
				end)
			end
		end

		-- Yield until all active profile jobs are finished:
		while on_close_save_job_count > 0 or ActiveProfileLoadJobs > 0 or ActiveProfileSaveJobs > 0 do
			task.wait()
		end

		return -- We're done!
	end)
end)

return {
	Module = ProfileStore,
	Hooks = Hooks,
	Profile = ProfileMethods,
	Signal = Signal,
	Envelope = Envelope,
	DeepCopyTable = DeepCopyTable,
	SaveProfileAsync = SaveProfileAsync,
	IsThisSession = IsThisSession,
	-- [Anchor] A detached view-mode profile (never saves) holding `data`, for dev options
	-- (View / NoSave) when the key has never been saved.
	NewViewProfile = function(store, profile_key, data, is_mock)
		local raw = {
			Data = data,
			MetaData = { ProfileCreateTime = os.time(), SessionLoadCount = 0, MetaTags = {} },
			GlobalUpdates = { 0, {} },
		}
		local profile = Profile.New(raw, data, nil, nil, store, profile_key, is_mock == true)
		profile.view_mode = true
		return profile
	end,
	GetActiveProfile = function(store, profile_key, is_mock)
		return ActiveSessionCheck[SessionToken(store.Name, profile_key, is_mock)]
	end,
	GetConstant = function(name)
		if name == "AUTO_SAVE_PERIOD" then
			return AUTO_SAVE_PERIOD
		elseif name == "ASSUME_DEAD" then
			return ASSUME_DEAD
		end
		return nil
	end,
	-- Feature modules registering hooks:
	AddHook = function(kind: string, fn)
		local list = Hooks[kind]
		if list == nil then
			error(`[{LIB}]: Unknown hook kind "{tostring(kind)}"`)
		end
		table.insert(list, fn)
	end,
}
