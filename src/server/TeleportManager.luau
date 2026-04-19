local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RobloxTeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TeleportConfig"))
local TeleportNet = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TeleportService"))

local remotes = TeleportNet.getRemotes()

local manager = {}

local room = {
	phase = "idle",
	masterUserId = nil,
	masterName = nil,
	capacity = nil,
	countdownEndsAt = nil,
	activeOccupants = {},
	occupiedLookup = {},
	lastBroadcastKey = "",
}

local touchDebounceByUserId = {}
local areaConnections = {}
local areaStatusGui = nil
local areaStatusLabel = nil

local function getAreaBounds()
	local area = Workspace:FindFirstChild(Config.AREA_NAME)
	if not area then
		return nil
	end

	if area:IsA("BasePart") then
		return area.CFrame, area.Size
	end

	if area:IsA("Model") then
		return area:GetBoundingBox()
	end

	return nil
end

local function getAreaAdornee()
	local area = Workspace:FindFirstChild(Config.AREA_NAME)
	if not area then
		return nil
	end

	if area:IsA("BasePart") then
		return area
	end

	if area:IsA("Model") then
		if area.PrimaryPart then
			return area.PrimaryPart
		end

		for _, descendant in ipairs(area:GetDescendants()) do
			if descendant:IsA("BasePart") then
				return descendant
			end
		end
	end

	return nil
end

local function buildAreaStatusText()
	if #room.activeOccupants == 0 then
		return "Kosong"
	end

	local capacityText = room.capacity and tostring(room.capacity) or "-"
	local countText = string.format("Player: %d/%s", #room.activeOccupants, capacityText)

	local countdownText = "Countdown: -"
	if room.phase == "awaiting_capacity" then
		countdownText = "(menunggu..)"
	elseif room.phase == "countdown" and room.countdownEndsAt then
		local remaining = math.max(0, math.ceil(room.countdownEndsAt - Workspace:GetServerTimeNow()))
		countdownText = string.format("Countdown: %ds", remaining)
	elseif room.phase == "teleporting" then
		countdownText = "Countdown: teleporting"
	end

	return countText .. "\n" .. countdownText
end

local function updateAreaStatusText()
	if areaStatusLabel then
		areaStatusLabel.Text = buildAreaStatusText()
	end
end

local function ensureAreaStatusGui()
	if areaStatusGui and areaStatusGui.Parent then
		return
	end

	local adornee = getAreaAdornee()
	if not adornee then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TeleportAreaStatus"
	billboard.Adornee = adornee
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 140
	billboard.Size = UDim2.fromOffset(160, 41)
	billboard.StudsOffset = Vector3.new(0, 8, 0)
	billboard.Parent = adornee

	local back = Instance.new("Frame")
	back.BackgroundColor3 = Color3.fromRGB(17, 21, 29)
	back.BackgroundTransparency = 0.2
	back.BorderSizePixel = 0
	back.Size = UDim2.fromScale(1, 1)
	back.Parent = billboard

	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 12)
	backCorner.Parent = back

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(240, 244, 255)
	label.TextScaled = true
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = back

	areaStatusGui = billboard
	areaStatusLabel = label
	updateAreaStatusText()
end

local function isPointInsideArea(point)
	local areaCFrame, areaSize = getAreaBounds()
	if not areaCFrame or not areaSize then
		return false
	end

	local localPoint = areaCFrame:PointToObjectSpace(point)
	local halfSize = areaSize * 0.5
	return math.abs(localPoint.X) <= halfSize.X and math.abs(localPoint.Y) <= halfSize.Y and math.abs(localPoint.Z) <= halfSize.Z
end

local function getPlayerRoot(player)
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
end

local function getPlayerFromHit(hit)
	if not hit then
		return nil
	end

	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end

	return Players:GetPlayerFromCharacter(character)
end

local function getInsideSpawnCFrame()
	local areaCFrame, areaSize = getAreaBounds()
	if not areaCFrame or not areaSize then
		return nil
	end

	return areaCFrame + Vector3.new(0, (areaSize.Y * 0.5) + 3, 0)
end

local function getOutsideSpawnCFrame()
	local areaCFrame, areaSize = getAreaBounds()
	if not areaCFrame or not areaSize then
		return nil
	end

	local offset = (areaSize.X * 0.5) + Config.EXIT_OFFSET
	return areaCFrame + Vector3.new(0, (areaSize.Y * 0.5) + 3, 0) + (areaCFrame.RightVector * offset)
end

local function movePlayerToCFrame(player, targetCFrame)
	if not player or not targetCFrame then
		return
	end

	local root = getPlayerRoot(player)
	if not root then
		return
	end

	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = targetCFrame
end

local function setMaster(player)
	room.masterUserId = player and player.UserId or nil
	room.masterName = player and player.Name or nil
end

local function resetRoom()
	room.phase = "idle"
	room.masterUserId = nil
	room.masterName = nil
	room.capacity = nil
	room.countdownEndsAt = nil
	room.activeOccupants = {}
	room.occupiedLookup = {}
end

local function buildPayload()
	local occupants = {}
	for _, player in ipairs(room.activeOccupants) do
		table.insert(occupants, {
			userId = player.UserId,
			name = player.Name,
			displayName = player.DisplayName,
		})
	end

	return {
		phase = room.phase,
		masterUserId = room.masterUserId,
		masterName = room.masterName,
		capacity = room.capacity,
		countdownEndsAt = room.countdownEndsAt,
		occupants = occupants,
	}
end

local function buildBroadcastKey()
	local keyParts = {
		room.phase,
		tostring(room.masterUserId or ""),
		tostring(room.capacity or ""),
		tostring(room.countdownEndsAt or ""),
	}

	for _, player in ipairs(room.activeOccupants) do
		table.insert(keyParts, tostring(player.UserId))
	end

	return table.concat(keyParts, "|")
end

local function broadcastState(force)
	local key = buildBroadcastKey()
	if not force and key == room.lastBroadcastKey then
		updateAreaStatusText()
		return
	end

	room.lastBroadcastKey = key
	updateAreaStatusText()
	remotes.StateChanged:FireAllClients(buildPayload())
end

local function findOccupantIndex(userId)
	for index, occupant in ipairs(room.activeOccupants) do
		if occupant.UserId == userId then
			return index
		end
	end

	return nil
end

local function ensureMasterAfterRemoval()
	if room.masterUserId and room.occupiedLookup[room.masterUserId] then
		return
	end

	if #room.activeOccupants > 0 then
		setMaster(room.activeOccupants[1])
		return
	end

	setMaster(nil)
end

local function removeOccupant(userId, moveOutside)
	local index = findOccupantIndex(userId)
	if not index then
		return false
	end

	table.remove(room.activeOccupants, index)
	room.occupiedLookup[userId] = nil

	if moveOutside then
		local player = Players:GetPlayerByUserId(userId)
		if player then
			movePlayerToCFrame(player, getOutsideSpawnCFrame())
		end
	end

	ensureMasterAfterRemoval()

	if #room.activeOccupants == 0 then
		resetRoom()
	else
		if room.phase ~= "countdown" and room.phase ~= "teleporting" then
			room.phase = "awaiting_capacity"
		end
		if room.phase ~= "countdown" then
			room.countdownEndsAt = nil
		end
	end

	broadcastState(true)
	return true
end

local function addOccupant(player)
	if room.occupiedLookup[player.UserId] then
		return false
	end

	if room.capacity and #room.activeOccupants >= room.capacity then
		return false
	end

	table.insert(room.activeOccupants, player)
	room.occupiedLookup[player.UserId] = true

	if not room.masterUserId then
		setMaster(player)
		room.phase = "awaiting_capacity"
		room.capacity = nil
		room.countdownEndsAt = nil
	elseif room.phase == "idle" then
		room.phase = "awaiting_capacity"
	end

	broadcastState(true)
	return true
end

local function handleAreaTouch(player)
	if not player or room.phase == "teleporting" then
		return
	end

	if not room.masterUserId then
		setMaster(player)
		room.phase = "awaiting_capacity"
	end

	if addOccupant(player) then
		movePlayerToCFrame(player, getInsideSpawnCFrame())
	end
end

local function cleanupInvalidOccupants()
	local changed = false
	for index = #room.activeOccupants, 1, -1 do
		local occupant = room.activeOccupants[index]
		if not occupant or not occupant.Parent then
			local userId = occupant and occupant.UserId
			table.remove(room.activeOccupants, index)
			if userId then
				room.occupiedLookup[userId] = nil
			end
			changed = true
		end
	end

	if changed then
		ensureMasterAfterRemoval()
		if #room.activeOccupants == 0 then
			resetRoom()
		elseif room.phase ~= "countdown" and room.phase ~= "teleporting" then
			room.phase = "awaiting_capacity"
		end
		broadcastState(true)
	end
end

local function startCountdown(capacity)
	if #room.activeOccupants == 0 or not room.masterUserId then
		return
	end

	room.capacity = capacity
	while #room.activeOccupants > room.capacity do
		removeOccupant(room.activeOccupants[#room.activeOccupants].UserId, true)
	end

	room.phase = "countdown"
	room.countdownEndsAt = Workspace:GetServerTimeNow() + Config.COUNTDOWN_SECONDS
	broadcastState(true)
end

local function teleportActivePlayers()
	if #room.activeOccupants == 0 then
		resetRoom()
		broadcastState(true)
		return
	end

	room.phase = "teleporting"
	broadcastState(true)

	local teleportTargets = table.clone(room.activeOccupants)
	local success, err = pcall(function()
		RobloxTeleportService:TeleportAsync(Config.PLACE_ID, teleportTargets)
	end)

	if not success then
		warn("Teleport failed:", err)
	end

	resetRoom()
	broadcastState(true)
end

local function connectTouchOnPart(part)
	table.insert(areaConnections, part.Touched:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		if not player then
			return
		end

		local now = Workspace:GetServerTimeNow()
		local lastTouch = touchDebounceByUserId[player.UserId] or 0
		if now - lastTouch < Config.TOUCH_DEBOUNCE_SECONDS then
			return
		end

		touchDebounceByUserId[player.UserId] = now
		handleAreaTouch(player)
	end))
end

local function bindAreaTouch()
	local area = Workspace:FindFirstChild(Config.AREA_NAME)
	if not area then
		warn("Teleport area not found:", Config.AREA_NAME)
		return
	end

	if area:IsA("BasePart") then
		connectTouchOnPart(area)
		return
	end

	if area:IsA("Model") then
		for _, descendant in ipairs(area:GetDescendants()) do
			if descendant:IsA("BasePart") then
				connectTouchOnPart(descendant)
			end
		end

		table.insert(areaConnections, area.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				connectTouchOnPart(descendant)
			end
		end))
		return
	end

	warn("Teleport area must be BasePart or Model:", area:GetFullName())
end

function manager.start()
	ensureAreaStatusGui()
	bindAreaTouch()

	remotes.RequestCapacity.OnServerEvent:Connect(function(player, requestedCapacity)
		if player.UserId ~= room.masterUserId then
			return
		end

		if room.phase ~= "awaiting_capacity" then
			return
		end

		local numericCapacity = tonumber(requestedCapacity)
		if not numericCapacity then
			return
		end

		numericCapacity = math.clamp(math.floor(numericCapacity), Config.MIN_ROOM_SIZE, Config.MAX_ROOM_SIZE)
		startCountdown(numericCapacity)
	end)

	remotes.RequestKick.OnServerEvent:Connect(function(player, targetUserId)
		if player.UserId ~= room.masterUserId then
			return
		end

		local numericTargetUserId = tonumber(targetUserId)
		if not numericTargetUserId then
			return
		end

		if numericTargetUserId == room.masterUserId then
			return
		end

		removeOccupant(numericTargetUserId, true)
	end)

	remotes.RequestExit.OnServerEvent:Connect(function(player)
		removeOccupant(player.UserId, true)
	end)

	Players.PlayerRemoving:Connect(function(player)
		removeOccupant(player.UserId, false)
		touchDebounceByUserId[player.UserId] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(Config.AREA_POLL_INTERVAL)
			updateAreaStatusText()
			cleanupInvalidOccupants()
			if room.phase == "countdown" and room.countdownEndsAt and Workspace:GetServerTimeNow() >= room.countdownEndsAt then
				teleportActivePlayers()
			end
		end
	end)

	broadcastState(true)
end

return manager
