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
local TREE_DEBOUNCE_SECONDS = 1.5
local TREE_MAX_WAIT_SECONDS = 10
local TREE_RESCAN_SECONDS = 30
local TREE_CHUNK_BYTES = 400000
-- never listed in the tree
local TREE_SKIP_CLASSES: { [string]: boolean } = { Camera = true, Players = true }
-- Folders shown without their contents (Wally output)
local TREE_OPAQUE: { [string]: boolean } = { Packages = true, ServerPackages = true, _Index = true }
-- a few properties worth showing an AI, by class (IsA)
local TREE_PROPS: { { Class: string, Props: { string } } } = {
	{ Class = "BasePart", Props = { "Size" } },
	{ Class = "MeshPart", Props = { "MeshId", "TextureID" } },
	{ Class = "SpecialMesh", Props = { "MeshId", "TextureId" } },
	{ Class = "Sound", Props = { "SoundId" } },
	{ Class = "Decal", Props = { "Texture" } },
	{ Class = "ImageLabel", Props = { "Image" } },
	{ Class = "ImageButton", Props = { "Image" } },
	{ Class = "Animation", Props = { "AnimationId" } },
}
local TREE_TRACKED: { [string]: boolean } = { Name = true }
for _, entry in TREE_PROPS do
	for _, name in entry.Props do
		TREE_TRACKED[name] = true
	end
end

type TreeNode = {
	name: string,
	className: string,
	children: { TreeNode },
	props: { [string]: any }?,
	truncated: boolean?,
	childCount: number?,
}

local toolbar = plugin:CreateToolbar("Repo Sync")
local button = toolbar:CreateButton("Studio Sync", "Send script edits and the place's instance tree from Studio to the repo", "rbxassetid://0")
button.ClickableWhenViewportHidden = true

local enabled = plugin:GetSetting(SETTING) ~= false
local connected = false
local roots: { { Instance: Instance, Path: { string } } } = {}
local connections: { RBXScriptConnection } = {}
local watched: { [Instance]: RBXScriptConnection } = {}
local sent: { [Instance]: string } = {}
local pending: { [Instance]: boolean } = {}
local propNames: { [string]: { string } } = {}
local treeServices: { string }? = nil
local treeDepth = 12
local treeMaxNodes = 20000
local treeDirty = false
local treeFirstChange = 0
local treeLastChange = 0
local treeLastScan = 0
local treeSent: string? = nil

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
	treeServices = nil
	treeSent = nil
	treeDirty = false
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

local function round(value: number): number
	return math.round(value * 1000) / 1000
end

local function propsOf(instance: Instance): { [string]: any }?
	local className = instance.ClassName
	local names = propNames[className]
	if not names then
		local found = {}
		if className ~= "Terrain" then
			for _, entry in TREE_PROPS do
				if instance:IsA(entry.Class) then
					for _, name in entry.Props do
						table.insert(found, name)
					end
				end
			end
		end
		propNames[className] = found
		names = found
	end
	if #names == 0 then
		return nil
	end

	local props = {}
	local has = false
	for _, name in names do
		local ok, value = pcall(function()
			return (instance :: any)[name]
		end)
		if ok and typeof(value) == "Vector3" then
			props[name] = { round(value.X), round(value.Y), round(value.Z) }
			has = true
		elseif ok and type(value) == "string" and value ~= "" then
			props[name] = value
			has = true
		end
	end
	return if has then props else nil
end

-- Read-only, breadth first so every service gets its top levels before the node cap is hit.
local function snapshot(): string?
	local services = treeServices
	if not services then
		return nil
	end

	local rootNodes: { TreeNode } = {}
	local queue: { { Instance: Instance, Node: TreeNode, Depth: number } } = {}
	local head, tail = 1, 0
	local count = 0
	local truncated = false

	for _, name in services do
		local found, service = pcall(game.FindService, game, name)
		if found and service and not TREE_SKIP_CLASSES[service.ClassName] then
			local node: TreeNode = { name = service.Name, className = service.ClassName, children = {} }
			table.insert(rootNodes, node)
			count += 1
			tail += 1
			queue[tail] = { Instance = service, Node = node, Depth = 0 }
		end
	end

	while head <= tail do
		local item = queue[head]
		queue[head] = nil
		head += 1

		local instance = item.Instance
		local node = item.Node
		if instance.ClassName == "Terrain" then
			continue
		end
		local children = instance:GetChildren()
		if #children == 0 then
			continue
		end
		if TREE_OPAQUE[instance.Name] and instance:IsA("Folder") then
			node.childCount = #children
			continue
		end
		if item.Depth >= treeDepth then
			node.truncated = true
			node.childCount = #children
			truncated = true
			continue
		end

		for _, child in children do
			if TREE_SKIP_CLASSES[child.ClassName] then
				continue
			end
			if count >= treeMaxNodes then
				node.truncated = true
				node.childCount = #children
				truncated = true
				break
			end
			count += 1
			local childNode: TreeNode = {
				name = child.Name,
				className = child.ClassName,
				children = {},
				props = propsOf(child),
			}
			table.insert(node.children, childNode)
			tail += 1
			queue[tail] = { Instance = child, Node = childNode, Depth = item.Depth + 1 }
		end
	end

	local ok, body = pcall(function()
		return HttpService:JSONEncode({
			placeId = game.PlaceId,
			truncated = truncated,
			nodeCount = count,
			roots = rootNodes,
		})
	end)
	return if ok then body else nil
end

-- Bodies over TREE_CHUNK_BYTES go as numbered pieces the server joins back together.
local function postTree(body: string): boolean
	if #body <= TREE_CHUNK_BYTES then
		return (request("POST", "/tree", body))
	end

	local pieces = {}
	local start = 1
	while start <= #body do
		local finish = math.min(start + TREE_CHUNK_BYTES - 1, #body)
		-- never cut through a multi-byte UTF-8 character
		while finish < #body and finish > start do
			local nextByte = string.byte(body, finish + 1)
			if nextByte < 0x80 or nextByte >= 0xC0 then
				break
			end
			finish -= 1
		end
		table.insert(pieces, string.sub(body, start, finish))
		start = finish + 1
	end

	local id = HttpService:GenerateGUID(false)
	for index, piece in pieces do
		local ok = request("POST", "/tree", HttpService:JSONEncode({ id = id, index = index - 1, count = #pieces, chunk = piece }))
		if not ok then
			return false
		end
	end
	return true
end

local function markTree()
	local now = os.clock()
	if not treeDirty then
		treeDirty = true
		treeFirstChange = now
	end
	treeLastChange = now
end

-- Unchanged snapshots are compared locally and never re-posted; a failed post is retried by the next rescan.
local function syncTree()
	treeDirty = false
	treeLastScan = os.clock()
	local body = snapshot()
	if body and body ~= treeSent and postTree(body) then
		treeSent = body
	end
end

local function watchTree(config: any)
	local services = config.treeServices
	if type(services) ~= "table" then
		return
	end

	local names = {}
	for _, name in services do
		if type(name) == "string" then
			table.insert(names, name)
		end
	end
	treeServices = names
	treeDepth = if type(config.treeDepth) == "number" then config.treeDepth else 12
	treeMaxNodes = if type(config.treeMaxNodes) == "number" then config.treeMaxNodes else 20000
	table.clear(propNames)

	for _, name in names do
		local found, service = pcall(game.FindService, game, name)
		if found and service then
			table.insert(connections, service.DescendantAdded:Connect(markTree))
			table.insert(connections, service.DescendantRemoving:Connect(markTree))
		end
	end

	-- one signal for renames and tracked property edits instead of a connection per instance
	pcall(function()
		table.insert(connections, (game :: any).ItemChanged:Connect(function(_, property: string)
			if TREE_TRACKED[property] then
				markTree()
			end
		end))
	end)
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

	if not send(all, true) then
		return false
	end

	watchTree(config)
	if treeServices then
		syncTree()
	end
	return true
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
			continue
		end

		local now = os.clock()
		if
			treeServices
			and (
				(treeDirty and (now - treeLastChange >= TREE_DEBOUNCE_SECONDS or now - treeFirstChange >= TREE_MAX_WAIT_SECONDS))
				or now - treeLastScan >= TREE_RESCAN_SECONDS
			)
		then
			syncTree()
		end
	end
end)
