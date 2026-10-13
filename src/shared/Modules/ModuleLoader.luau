--!strict
-- Requires every ModuleScript under a folder and runs its lifecycle.
--
--   Init(janitor)  called one module at a time, in order. Set up state and connections here.
--   Start()        called in its own thread once every Init has finished.
--   Shutdown()     server only: called from game:BindToClose, in reverse order.
--   OnCharacterAdded(character) / OnCharacterRemoving(character)  client only.
--
-- Optional field:
--   Priority = number  higher loads first (default 0). Equal priorities go by module name.
--
-- A module that errors is reported as "[ModuleLoader] <Module>.<Phase> failed: ..." and the rest keep loading.
-- If its Init fails, its Start and Shutdown are skipped.
-- When everything has been started the folder gets the attribute Ready = true.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Janitor = require(ReplicatedStorage.Packages.Janitor)

type Entry = {
	Name: string,
	Module: any,
	Priority: number,
}

local ModuleLoader = {}
ModuleLoader.Janitors = {} :: { [any]: any }
ModuleLoader.Modules = {} :: { [string]: any }
-- Loaded modules in the order they were initialised.
ModuleLoader.Order = {} :: { Entry }

-- Set once InitFolder has run. Only one folder is loaded per Luau VM.
ModuleLoader.ClientLoaded = false

local function run(name: string, phase: string, callback: (...any) -> ...any, ...: any): boolean
	return xpcall(callback, function(err)
		warn(`[ModuleLoader] {name}.{phase} failed: {debug.traceback(tostring(err), 2)}`)
	end, ...)
end

local function hasMethod(module: any, method: string): boolean
	return type(module) == "table" and type(module[method]) == "function"
end

local function sortEntries(a: Entry, b: Entry): boolean
	if a.Priority ~= b.Priority then
		return a.Priority > b.Priority
	end
	return a.Name < b.Name
end

function ModuleLoader.InitFolder(Folder: Instance)
	if ModuleLoader.ClientLoaded then
		warn(`[ModuleLoader] InitFolder already ran; ignoring {Folder:GetFullName()}`)
		return
	end
	ModuleLoader.ClientLoaded = true

	for _, v in Folder:GetDescendants() do
		if v:IsA("ModuleScript") then
			if ModuleLoader.Modules[v.Name] ~= nil then
				warn(`[ModuleLoader] two modules are named {v.Name}; the later one replaces the earlier`)
			end
			local ok, module = xpcall(require, function(err)
				warn(`[ModuleLoader] {v.Name}.require failed: {debug.traceback(tostring(err), 2)}`)
			end, v)
			if ok then
				ModuleLoader.Modules[v.Name] = module
			end
		end
	end

	local entries: { Entry } = {}
	for name, module in ModuleLoader.Modules do
		local priority = if type(module) == "table" and type(module.Priority) == "number" then module.Priority else 0
		table.insert(entries, { Name = name, Module = module, Priority = priority })
	end
	table.sort(entries, sortEntries)

	local order: { Entry } = {}
	for _, entry in entries do
		local module = entry.Module
		if hasMethod(module, "Init") then
			local janitor = Janitor.new()
			ModuleLoader.Janitors[module] = janitor

			if not run(entry.Name, "Init", module.Init, module, janitor) then
				ModuleLoader.Janitors[module] = nil
				janitor:Destroy()
				continue
			end
		end
		table.insert(order, entry)
	end
	ModuleLoader.Order = order

	for _, entry in order do
		local module = entry.Module
		if hasMethod(module, "Start") then
			task.spawn(run, entry.Name, "Start", module.Start, module)
		end
	end

	if RunService:IsServer() then
		game:BindToClose(function()
			for i = #order, 1, -1 do
				local entry = order[i]
				if hasMethod(entry.Module, "Shutdown") then
					run(entry.Name, "Shutdown", entry.Module.Shutdown, entry.Module)
				end
			end

			for _, janitor in ModuleLoader.Janitors do
				janitor:Destroy()
			end
			ModuleLoader.Janitors = {}
		end)
	end

	if RunService:IsClient() then
		local Player = Players.LocalPlayer

		local function OnCharacterAdded(Character: Model)
			for _, entry in order do
				if hasMethod(entry.Module, "OnCharacterAdded") then
					task.spawn(
						run,
						entry.Name,
						"OnCharacterAdded",
						entry.Module.OnCharacterAdded,
						entry.Module,
						Character
					)
				end
			end
		end

		local function OnCharacterRemoving(Character: Model)
			for _, entry in order do
				if hasMethod(entry.Module, "OnCharacterRemoving") then
					task.spawn(
						run,
						entry.Name,
						"OnCharacterRemoving",
						entry.Module.OnCharacterRemoving,
						entry.Module,
						Character
					)
				end
			end
		end

		Player.CharacterAdded:Connect(OnCharacterAdded)
		Player.CharacterRemoving:Connect(OnCharacterRemoving)

		if Player.Character then
			task.spawn(OnCharacterAdded, Player.Character)
		end

		Players.PlayerRemoving:Connect(function(Leaver)
			if Leaver == Player then
				for _, janitor in ModuleLoader.Janitors do
					janitor:Destroy()
				end

				ModuleLoader.Janitors = {}
			end
		end)
	end

	Folder:SetAttribute("Ready", true)
end

return ModuleLoader
