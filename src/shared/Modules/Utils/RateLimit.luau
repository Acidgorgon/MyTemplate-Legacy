--!strict
-- Token bucket rate limit. Make one per action and check it at the top of every
-- client -> server Blink handler, before validating or acting on the arguments.
--
-- RateLimit.new(maxCalls, perSeconds) allows bursts of `maxCalls`, refilling to
-- that many over `perSeconds`. Keys are usually players; a player's bucket is
-- dropped when they leave. Other keys are cleared with :Clear(key) or :Reset().
--
-- Example (server):
--
--   local RateLimit = require(ReplicatedStorage.Shared.Modules.Utils.RateLimit)
--   local Events = require(<the Blink ServerOutput module>)
--
--   local buyLimit = RateLimit.new(5, 5) -- 5 calls per 5 seconds, bursts of 5
--
--   Events.BuyItem.On(function(player, itemId)
--   	if not buyLimit:Check(player) then
--   		return
--   	end
--   	if typeof(itemId) ~= "string" or not Items[itemId] then
--   		return
--   	end
--   	-- act on the request
--   end)

local Players = game:GetService("Players")

type Bucket = {
	tokens: number,
	updated: number,
}

local RateLimit = {}
RateLimit.__index = RateLimit

type Fields = {
	capacity: number,
	refillPerSecond: number,
	clock: () -> number,
	buckets: { [any]: Bucket },
	connection: RBXScriptConnection?,
}

export type RateLimit = typeof(setmetatable({} :: Fields, RateLimit))

-- `clock` defaults to os.clock; pass another for tests.
function RateLimit.new(maxCalls: number, perSeconds: number, clock: (() -> number)?): RateLimit
	assert(maxCalls > 0, "RateLimit maxCalls must be above 0")
	assert(perSeconds > 0, "RateLimit perSeconds must be above 0")

	local self = setmetatable(
		{
			capacity = maxCalls,
			refillPerSecond = maxCalls / perSeconds,
			clock = clock or os.clock,
			buckets = {},
			connection = nil,
		} :: Fields,
		RateLimit
	)

	self.connection = Players.PlayerRemoving:Connect(function(player)
		self.buckets[player] = nil
	end)

	return self
end

-- Spends one token for `key`. Returns false, spending nothing, when none are left.
function RateLimit.Check(self: RateLimit, key: any): boolean
	-- A request can arrive after PlayerRemoving; do not create a bucket that is never cleaned up.
	if typeof(key) == "Instance" and key:IsA("Player") and key.Parent ~= Players then
		return false
	end

	local now = self.clock()
	local bucket = self.buckets[key]
	if bucket == nil then
		bucket = { tokens = self.capacity, updated = now }
		self.buckets[key] = bucket
	else
		bucket.tokens = math.min(self.capacity, bucket.tokens + (now - bucket.updated) * self.refillPerSecond)
		bucket.updated = now
	end

	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- Gives `key` a full bucket again.
function RateLimit.Clear(self: RateLimit, key: any)
	self.buckets[key] = nil
end

-- Gives every key a full bucket again.
function RateLimit.Reset(self: RateLimit)
	table.clear(self.buckets)
end

function RateLimit.Destroy(self: RateLimit)
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	table.clear(self.buckets)
end

return RateLimit
