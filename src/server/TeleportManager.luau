local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RobloxTeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TeleportConfig"))
local TeleportNet = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TeleportService"))

local remotes = TeleportNet.getRemotes()

local manager = {}

-- Store room state per area name
local rooms = {}
local playerAreaLookup = {}
local areaStatusGuis = {}
local areaStatusLabels = {}
local touchDebounceByUserIdAndArea = {}
local areaConnections = {}

local function createRoomState()
	return {
		phase = "idle",
		masterUserId = nil,
		masterName = nil,
		capacity = nil,
		countdownEndsAt = nil,
		reservedServerAccessCode = nil,
		activeOccupants = {},
		occupiedLookup = {},
		lastBroadcastKey = "",
	}
end

local function getRoomState(areaName)
	if not rooms[areaName] then
		rooms[areaName] = createRoomState()
	end
	return rooms[areaName]
end

local function findTeleportAreaInstance(areaName)
	return Workspace:FindFirstChild(areaName, true)
end

local function isTeleportAreaName(name)
	if not name then
		return false
	end

	local prefix = Config.AREA_NAME_PREFIX or Config.AREA_NAME
	return name:match("^" .. prefix .. "_?%d+$") ~= nil
end

local function getAreaBounds(areaName)
	local area = findTeleportAreaInstance(areaName)
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

local function getAreaAdornee(areaName)
	local area = findTeleportAreaInstance(areaName)
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

local function buildAreaStatusText(areaName)
	local room = getRoomState(areaName)
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

local function updateAreaStatusText(areaName)
	local label = areaStatusLabels[areaName]
	if label then
		label.Text = buildAreaStatusText(areaName)
	end
end

local function ensureAreaStatusGui(areaName)
	if areaStatusGuis[areaName] and areaStatusGuis[areaName].Parent then
		return
	end

	local adornee = getAreaAdornee(areaName)
	if not adornee then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TeleportAreaStatus_" .. areaName
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

	areaStatusGuis[areaName] = billboard
	areaStatusLabels[areaName] = label
	updateAreaStatusText(areaName)
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

local function getInsideSpawnCFrame(areaName)
	local areaCFrame, areaSize = getAreaBounds(areaName)
	if not areaCFrame or not areaSize then
		return nil
	end

	return areaCFrame + Vector3.new(0, (areaSize.Y * 0.5) + 3, 0)
end

local function getOutsideSpawnCFrame(areaName)
	local areaCFrame, areaSize = getAreaBounds(areaName)
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

local function setMaster(areaName, player)
	local room = getRoomState(areaName)
	room.masterUserId = player and player.UserId or nil
	room.masterName = player and player.Name or nil
end

local function resetRoom(areaName)
	local room = getRoomState(areaName)
	room.phase = "idle"
	room.masterUserId = nil
	room.masterName = nil
	room.capacity = nil
	room.countdownEndsAt = nil
	room.reservedServerAccessCode = nil
	room.activeOccupants = {}
	room.occupiedLookup = {}
end

local function buildPayload(areaName)
	local room = getRoomState(areaName)
	local occupants = {}
	for _, player in ipairs(room.activeOccupants) do
		table.insert(occupants, {
			userId = player.UserId,
			name = player.Name,
			displayName = player.DisplayName,
		})
	end

	return {
		areaName = areaName,
		phase = room.phase,
		masterUserId = room.masterUserId,
		masterName = room.masterName,
		capacity = room.capacity,
		countdownEndsAt = room.countdownEndsAt,
		occupants = occupants,
	}
end

local function buildBroadcastKey(areaName)
	local room = getRoomState(areaName)
	local keyParts = {
		areaName,
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

local function broadcastState(areaName, force)
	local room = getRoomState(areaName)
	local key = buildBroadcastKey(areaName)
	if not force and key == room.lastBroadcastKey then
		updateAreaStatusText(areaName)
		return
	end

	room.lastBroadcastKey = key
	updateAreaStatusText(areaName)
	remotes.StateChanged:FireAllClients(buildPayload(areaName))
end

local function findOccupantIndex(areaName, userId)
	local room = getRoomState(areaName)
	for index, occupant in ipairs(room.activeOccupants) do
		if occupant.UserId == userId then
			return index
		end
	end

	return nil
end

local function ensureMasterAfterRemoval(areaName)
	local room = getRoomState(areaName)
	if room.masterUserId and room.occupiedLookup[room.masterUserId] then
		return
	end

	if #room.activeOccupants > 0 then
		setMaster(areaName, room.activeOccupants[1])
		return
	end

	setMaster(areaName, nil)
end

local function removeOccupant(areaName, userId, moveOutside)
	local room = getRoomState(areaName)
	local index = findOccupantIndex(areaName, userId)
	if not index then
		return false
	end

	table.remove(room.activeOccupants, index)
	room.occupiedLookup[userId] = nil
	if playerAreaLookup[userId] == areaName then
		playerAreaLookup[userId] = nil
	end

	if moveOutside then
		local player = Players:GetPlayerByUserId(userId)
		if player then
			movePlayerToCFrame(player, getOutsideSpawnCFrame(areaName))
		end
	end

	ensureMasterAfterRemoval(areaName)

	if #room.activeOccupants == 0 then
		resetRoom(areaName)
	else
		if room.phase ~= "countdown" and room.phase ~= "teleporting" then
			room.phase = "awaiting_capacity"
		end
		if room.phase ~= "countdown" then
			room.countdownEndsAt = nil
		end
	end

	broadcastState(areaName, true)
	return true
end

local function addOccupant(areaName, player)
	local room = getRoomState(areaName)
	local mappedArea = playerAreaLookup[player.UserId]
	if mappedArea and mappedArea ~= areaName then
		return false
	end

	if room.occupiedLookup[player.UserId] then
		return false
	end

	if room.capacity and #room.activeOccupants >= room.capacity then
		return false
	end

	table.insert(room.activeOccupants, player)
	room.occupiedLookup[player.UserId] = true
	playerAreaLookup[player.UserId] = areaName

	if not room.masterUserId then
		setMaster(areaName, player)
		room.phase = "awaiting_capacity"
		room.capacity = nil
		room.countdownEndsAt = nil
	elseif room.phase == "idle" then
		room.phase = "awaiting_capacity"
	end

	broadcastState(areaName, true)
	return true
end

local function handleAreaTouch(areaName, player)
	local room = getRoomState(areaName)
	if not player or room.phase == "teleporting" then
		return
	end

	if playerAreaLookup[player.UserId] and playerAreaLookup[player.UserId] ~= areaName then
		return
	end

	if not room.masterUserId then
		setMaster(areaName, player)
		room.phase = "awaiting_capacity"
	end

	if addOccupant(areaName, player) then
		movePlayerToCFrame(player, getInsideSpawnCFrame(areaName))
	end
end

local function cleanupInvalidOccupants(areaName)
	local room = getRoomState(areaName)
	local changed = false
	for index = #room.activeOccupants, 1, -1 do
		local occupant = room.activeOccupants[index]
		if not occupant or not occupant.Parent then
			local userId = occupant and occupant.UserId
			table.remove(room.activeOccupants, index)
			if userId then
				room.occupiedLookup[userId] = nil
				if playerAreaLookup[userId] == areaName then
					playerAreaLookup[userId] = nil
				end
			end
			changed = true
		end
	end

	if changed then
		ensureMasterAfterRemoval(areaName)
		if #room.activeOccupants == 0 then
			resetRoom(areaName)
		elseif room.phase ~= "countdown" and room.phase ~= "teleporting" then
			room.phase = "awaiting_capacity"
		end
		broadcastState(areaName, true)
	end
end

local function startCountdown(areaName, capacity)
	local room = getRoomState(areaName)
	if #room.activeOccupants == 0 or not room.masterUserId then
		return
	end

	room.capacity = capacity
	while #room.activeOccupants > room.capacity do
		removeOccupant(areaName, room.activeOccupants[#room.activeOccupants].UserId, true)
	end

	if not room.reservedServerAccessCode then
		local success, accessCode = pcall(function()
			return RobloxTeleportService:ReserveServer(Config.PLACE_ID)
		end)

		if success and accessCode then
			room.reservedServerAccessCode = accessCode
		else
			warn("ReserveServer failed for " .. areaName .. ":", accessCode)
		end
	end

	room.phase = "countdown"
	room.countdownEndsAt = Workspace:GetServerTimeNow() + Config.COUNTDOWN_SECONDS
	broadcastState(areaName, true)
end

local function teleportActivePlayers(areaName)
	local room = getRoomState(areaName)
	if #room.activeOccupants == 0 then
		resetRoom(areaName)
		broadcastState(areaName, true)
		return
	end

	room.phase = "teleporting"
	broadcastState(areaName, true)

	local teleportTargets = table.clone(room.activeOccupants)
	local teleportOptions = Instance.new("TeleportOptions")
	if room.reservedServerAccessCode then
		teleportOptions.ReservedServerAccessCode = room.reservedServerAccessCode
	end

	for _, occupant in ipairs(room.activeOccupants) do
		if playerAreaLookup[occupant.UserId] == areaName then
			playerAreaLookup[occupant.UserId] = nil
		end
	end
	local success, err = pcall(function()
		RobloxTeleportService:TeleportAsync(Config.PLACE_ID, teleportTargets, teleportOptions)
	end)
	teleportOptions:Destroy()

	if not success then
		warn("Teleport failed for " .. areaName .. ":", err)
	end

	resetRoom(areaName)
	broadcastState(areaName, true)
end

local function connectTouchOnPart(areaName, part)
	table.insert(areaConnections, part.Touched:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		if not player then
			return
		end

		local debounceKey = player.UserId .. "_" .. areaName
		local now = Workspace:GetServerTimeNow()
		local lastTouch = touchDebounceByUserIdAndArea[debounceKey] or 0
		if now - lastTouch < Config.TOUCH_DEBOUNCE_SECONDS then
			return
		end

		touchDebounceByUserIdAndArea[debounceKey] = now
		handleAreaTouch(areaName, player)
	end))
end

local function bindAreaTouch(areaName)
	local area = findTeleportAreaInstance(areaName)
	if not area then
		warn("Teleport area not found:", areaName)
		return
	end

	if area:IsA("BasePart") then
		connectTouchOnPart(areaName, area)
		return
	end

	if area:IsA("Model") then
		for _, descendant in ipairs(area:GetDescendants()) do
			if descendant:IsA("BasePart") then
				connectTouchOnPart(areaName, descendant)
			end
		end

		table.insert(areaConnections, area.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				connectTouchOnPart(areaName, descendant)
			end
		end))
		return
	end

	warn("Teleport area must be BasePart or Model:", area:GetFullName())
end

local function findAllAreas()
	local areas = {}
	for _, descendant in ipairs(Workspace:GetChildren()) do
		if isTeleportAreaName(descendant.Name) then
			table.insert(areas, descendant.Name)
		end
	end
	return areas
end

local function resolveAreaNameForPlayer(player, requestedAreaName)
	if requestedAreaName and rooms[requestedAreaName] then
		return requestedAreaName
	end

	return playerAreaLookup[player.UserId]
end

function manager.start()
	-- Discover all teleport areas
	local areas = findAllAreas()
	if #areas == 0 then
		warn("No teleport areas found with prefix:", Config.AREA_NAME_PREFIX)
		return
	end

	-- Initialize each area
	for _, areaName in ipairs(areas) do
		ensureAreaStatusGui(areaName)
		bindAreaTouch(areaName)
	end

	-- Watch for new areas being added
	table.insert(areaConnections, Workspace.ChildAdded:Connect(function(child)
		if isTeleportAreaName(child.Name) then
			if not rooms[child.Name] then
				ensureAreaStatusGui(child.Name)
				bindAreaTouch(child.Name)
			end
		end
	end))

	-- Remote: RequestCapacity
	remotes.RequestCapacity.OnServerEvent:Connect(function(player, areaName, requestedCapacity)
		local resolvedAreaName = resolveAreaNameForPlayer(player, areaName)
		if not resolvedAreaName or not requestedCapacity then
			return
		end

		local room = getRoomState(resolvedAreaName)
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
		startCountdown(resolvedAreaName, numericCapacity)
	end)

	-- Remote: RequestKick
	remotes.RequestKick.OnServerEvent:Connect(function(player, areaName, targetUserId)
		local resolvedAreaName = resolveAreaNameForPlayer(player, areaName)
		if not resolvedAreaName or not targetUserId then
			return
		end

		local room = getRoomState(resolvedAreaName)
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

		removeOccupant(resolvedAreaName, numericTargetUserId, true)
	end)

	-- Remote: RequestExit
	remotes.RequestExit.OnServerEvent:Connect(function(player, areaName)
		local resolvedAreaName = resolveAreaNameForPlayer(player, areaName)
		if not resolvedAreaName then
			return
		end

		removeOccupant(resolvedAreaName, player.UserId, true)
	end)

	-- PlayerRemoving handler
	Players.PlayerRemoving:Connect(function(player)
		-- Remove from all areas
		for areaName, room in pairs(rooms) do
			if room.occupiedLookup[player.UserId] then
				removeOccupant(areaName, player.UserId, false)
			end
		end
		playerAreaLookup[player.UserId] = nil
		-- Clear debounce entries for this player
		for key in pairs(touchDebounceByUserIdAndArea) do
			if key:match("^" .. player.UserId .. "_") then
				touchDebounceByUserIdAndArea[key] = nil
			end
		end
	end)

	-- Main update loop
	task.spawn(function()
		while true do
			task.wait(Config.AREA_POLL_INTERVAL)
			for areaName in pairs(rooms) do
				updateAreaStatusText(areaName)
				cleanupInvalidOccupants(areaName)
				local room = getRoomState(areaName)
				if room.phase == "countdown" and room.countdownEndsAt and Workspace:GetServerTimeNow() >= room.countdownEndsAt then
					teleportActivePlayers(areaName)
				end
			end
		end
	end)

	-- Initial broadcast for all areas
	for _, areaName in ipairs(areas) do
		broadcastState(areaName, true)
	end
end

return manager
