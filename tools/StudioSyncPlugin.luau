local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

if RunService:IsRunning() then
	return
end

local URL = "http://127.0.0.1:34873"
local RETRY_SECONDS = 4
local FLUSH_SECONDS = 1
local SWEEP_SECONDS = 15
local BATCH_BYTES = 400000
local SETTING = "RepoStudioSyncEnabled"

local toolbar = plugin:CreateToolbar("Repo Sync")
local button = toolbar:CreateButton("Studio Sync", "Send script edits made in Studio to the repo", "rbxassetid://0")
button.ClickableWhenViewportHidden = true

local enabled = plugin:GetSetting(SETTING) ~= false
local connected = false
local roots: { { Instance: Instance, Path: { string } } } = {}
local connections: { RBXScriptConnection } = {}
local watched: { [Instance]: RBXScriptConnection } = {}
local sent: { [Instance]: string } = {}
local pending: { [Instance]: boolean } = {}

local function request(method: string, path: string, body: string?): (boolean, any)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = URL .. path,
			Method = method,
			Body = body,
			Headers = if body then { ["Content-Type"] = "application/json" } else nil,
		})
	end)
	if not ok or not response.Success then
		return false, nil
	end

	local decoded
	local parsed = pcall(function()
		decoded = HttpService:JSONDecode(response.Body)
	end)
	return parsed, decoded
end

local function pathOf(instance: Instance): { string }?
	for _, root in roots do
		if instance == root.Instance or instance:IsDescendantOf(root.Instance) then
			local names = {}
			local current: Instance? = instance
			while current and current ~= root.Instance do
				table.insert(names, 1, current.Name)
				current = current.Parent
			end

			local full = table.clone(root.Path)
			for _, name in names do
				table.insert(full, name)
			end
			return full
		end
	end

	return nil
end

local function sourceOf(instance: Instance): string?
	local ok, source = pcall(function()
		return (instance :: any).Source
	end)
	return if ok and type(source) == "string" then source else nil
end

local function watch(instance: Instance)
	if watched[instance] or not instance:IsA("LuaSourceContainer") then
		return
	end

	watched[instance] = instance:GetPropertyChangedSignal("Source"):Connect(function()
		pending[instance] = true
	end)
end

local function unwatchAll()
	for _, connection in connections do
		connection:Disconnect()
	end
	for _, connection in watched do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(watched)
	table.clear(sent)
	table.clear(pending)
	table.clear(roots)
end

local function send(instances: { Instance }, initial: boolean): boolean
	local batch = {}
	local size = 0
	local sources: { [Instance]: string } = {}

	local function flush(): boolean
		if #batch == 0 then
			return true
		end

		local ok = request("POST", "/sync", HttpService:JSONEncode({ initial = initial, scripts = batch }))
		batch = {}
		size = 0
		return ok
	end

	for _, instance in instances do
		local source = sourceOf(instance)
		local path = if instance.Parent then pathOf(instance) else nil
		if source and path then
			table.insert(batch, { path = path, className = instance.ClassName, source = source })
			sources[instance] = source
			size += #source
			if size >= BATCH_BYTES and not flush() then
				return false
			end
		end
	end

	if not flush() then
		return false
	end

	for instance, source in sources do
		sent[instance] = source
	end
	return true
end

local function resolveRoot(path: { string }): Instance?
	local current: Instance = game
	for index, name in path do
		local child = if index == 1 then game:FindService(name) else current:FindFirstChild(name)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function connect(): boolean
	local ok, config = request("GET", "/config", nil)
	if not ok or type(config) ~= "table" then
		return false
	end

	local allowed = false
	for _, placeId in config.placeIds or {} do
		if placeId == game.PlaceId then
			allowed = true
		end
	end
	if not allowed then
		return false
	end

	unwatchAll()
	local all = {}
	for _, path in config.roots or {} do
		local instance = resolveRoot(path)
		if instance then
			table.insert(roots, { Instance = instance, Path = path })
		end
	end

	for _, root in roots do
		local list = root.Instance:GetDescendants()
		table.insert(list, root.Instance)
		for _, instance in list do
			if instance:IsA("LuaSourceContainer") then
				watch(instance)
				table.insert(all, instance)
			end
		end

		table.insert(connections, root.Instance.DescendantAdded:Connect(function(instance)
			if instance:IsA("LuaSourceContainer") then
				watch(instance)
				pending[instance] = true
			end
		end))
	end

	return send(all, true)
end

local function setConnected(value: boolean)
	connected = value
	button:SetActive(value)
	if not value then
		unwatchAll()
	end
end

button.Click:Connect(function()
	enabled = not enabled
	plugin:SetSetting(SETTING, enabled)
	if not enabled then
		setConnected(false)
	end
end)

plugin.Unloading:Connect(function()
	enabled = false
	unwatchAll()
end)

task.spawn(function()
	local lastSweep = os.clock()
	while true do
		if not enabled then
			task.wait(RETRY_SECONDS)
			continue
		end

		if not connected then
			setConnected(connect())
			if not connected then
				task.wait(RETRY_SECONDS)
			end
			continue
		end

		task.wait(FLUSH_SECONDS)
		if os.clock() - lastSweep >= SWEEP_SECONDS then
			lastSweep = os.clock()
			for instance in watched do
				if instance.Parent and sourceOf(instance) ~= sent[instance] then
					pending[instance] = true
				end
			end
		end

		local changed = {}
		for instance in pending do
			table.insert(changed, instance)
		end
		table.clear(pending)

		if #changed > 0 and not send(changed, false) then
			for _, instance in changed do
				pending[instance] = true
			end
			setConnected(false)
		end
	end
end)
