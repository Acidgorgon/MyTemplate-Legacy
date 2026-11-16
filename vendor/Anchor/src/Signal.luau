--!nonstrict
--[[
	Anchor / Signal

	GoodSignal-style signal, ported 1:1 from the one embedded in ProfileStore 1.0.3
	(yield-safe coroutine reuse by stravant). Listeners run in a reused runner
	thread via task.spawn, so a listener runs synchronously until it yields.

	API: Signal.New() / Signal.new()
	     signal:Connect(fn) -> connection   connection:Disconnect()
	     signal:Fire(...)   signal:Wait()   signal:GetListenerCount()
--]]

local LIB = "Anchor"

local FreeRunnerThread: thread? = nil

local function AcquireRunnerThreadAndCallEventHandler(fn, ...)
	local acquired_runner_thread = FreeRunnerThread
	FreeRunnerThread = nil
	fn(...)
	-- The handler finished running, this runner thread is free again.
	FreeRunnerThread = acquired_runner_thread
end

local function RunEventHandlerInFreeThread(...)
	AcquireRunnerThreadAndCallEventHandler(...)
	while true do
		AcquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end

export type Connection = {
	Disconnect: (self: Connection) -> (),
	is_connected: boolean,
}

export type Signal = {
	Connect: (self: Signal, listener: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	GetListenerCount: (self: Signal) -> number,
}

local Connection = {}
Connection.__index = Connection

local SignalClass = {}
SignalClass.__index = SignalClass

function Connection:Disconnect()
	if self.is_connected == false then
		return
	end

	local signal = self.signal
	self.is_connected = false
	signal.listener_count -= 1

	if signal.head == self then
		signal.head = self.next
	else
		local prev = signal.head
		while prev ~= nil and prev.next ~= self do
			prev = prev.next
		end
		if prev ~= nil then
			prev.next = self.next
		end
	end
end

function SignalClass.New(): Signal
	local self = {
		head = nil,
		listener_count = 0,
	}
	return setmetatable(self, SignalClass) :: any
end

function SignalClass:Connect(listener: (...any) -> ())
	if type(listener) ~= "function" then
		error(`[{LIB}]: "listener" must be a function; Received {typeof(listener)}`)
	end

	local connection = {
		listener = listener,
		signal = self,
		next = self.head,
		is_connected = true,
	}
	setmetatable(connection, Connection)

	self.head = connection
	self.listener_count += 1

	return connection
end

function SignalClass:GetListenerCount(): number
	return self.listener_count
end

function SignalClass:Fire(...)
	local item = self.head
	while item ~= nil do
		if item.is_connected == true then
			if not FreeRunnerThread then
				FreeRunnerThread = coroutine.create(RunEventHandlerInFreeThread)
			end
			task.spawn(FreeRunnerThread :: thread, item.listener, ...)
		end
		item = item.next
	end
end

function SignalClass:Wait()
	local co = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(co, ...)
	end)
	return coroutine.yield()
end

return table.freeze({
	New = SignalClass.New,
	new = SignalClass.New,
})
