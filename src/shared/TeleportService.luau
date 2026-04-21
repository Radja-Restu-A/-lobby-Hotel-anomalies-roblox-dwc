local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent:WaitForChild("TeleportConfig"))

local TeleportService = {}

local cachedRemotes = nil

local function ensureRemoteFolder()
	local root = ReplicatedStorage:FindFirstChild(Config.REMOTE_FOLDER_NAME)
	if root then
		return root
	end

	if RunService:IsServer() then
		root = Instance.new("Folder")
		root.Name = Config.REMOTE_FOLDER_NAME
		root.Parent = ReplicatedStorage
		return root
	end

	return ReplicatedStorage:WaitForChild(Config.REMOTE_FOLDER_NAME)
end

local function ensureRemoteEvent(parent, name)
	local remote = parent:FindFirstChild(name)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end

	if RunService:IsServer() then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = parent
		return remote
	end

	return parent:WaitForChild(name)
end

function TeleportService.getRemotes()
	if cachedRemotes then
		return cachedRemotes
	end

	local folder = ensureRemoteFolder()
	cachedRemotes = {
		Folder = folder,
		StateChanged = ensureRemoteEvent(folder, Config.STATE_EVENT_NAME),
		SystemMessage = ensureRemoteEvent(folder, Config.SYSTEM_MESSAGE_EVENT_NAME),
		RequestCapacity = ensureRemoteEvent(folder, Config.REQUEST_CAPACITY_EVENT_NAME),
		RequestFriendOnly = ensureRemoteEvent(folder, Config.REQUEST_FRIEND_ONLY_EVENT_NAME),
		RequestKick = ensureRemoteEvent(folder, Config.REQUEST_KICK_EVENT_NAME),
		RequestExit = ensureRemoteEvent(folder, Config.REQUEST_EXIT_EVENT_NAME),
	}

	return cachedRemotes
end

function TeleportService.requestCapacity(areaName, capacity)
	if capacity == nil then
		capacity = areaName
		areaName = nil
	end

	local remotes = TeleportService.getRemotes()
	remotes.RequestCapacity:FireServer(areaName, capacity)
end

function TeleportService.requestKick(areaName, userId)
	if userId == nil then
		userId = areaName
		areaName = nil
	end

	local remotes = TeleportService.getRemotes()
	remotes.RequestKick:FireServer(areaName, userId)
end

function TeleportService.requestFriendOnly(areaName, enabled)
	if enabled == nil then
		enabled = areaName
		areaName = nil
	end

	local remotes = TeleportService.getRemotes()
	remotes.RequestFriendOnly:FireServer(areaName, enabled)
end

function TeleportService.requestExit(areaName)
	local remotes = TeleportService.getRemotes()
	remotes.RequestExit:FireServer(areaName)
end

function TeleportService.onStateChanged(callback)
	local remotes = TeleportService.getRemotes()
	return remotes.StateChanged.OnClientEvent:Connect(callback)
end

function TeleportService.onSystemMessage(callback)
	local remotes = TeleportService.getRemotes()
	return remotes.SystemMessage.OnClientEvent:Connect(callback)
end

return TeleportService