local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TeleportConfig"))
local TeleportService = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TeleportService"))

local currentState = {
	areaName = nil,
	phase = "idle",
	masterUserId = nil,
	capacity = nil,
	occupants = {},
}

local currentAreaName = nil

local function isLocalMaster()
	return currentState.masterUserId == LocalPlayer.UserId
end

local function stateHasLocalPlayer(state)
	if state.masterUserId == LocalPlayer.UserId then
		return true
	end

	for _, occupant in ipairs(state.occupants or {}) do
		if occupant.userId == LocalPlayer.UserId then
			return true
		end
	end

	return false
end

local function hasLocalPlayerInRoom()
	for _, occupant in ipairs(currentState.occupants) do
		if occupant.userId == LocalPlayer.UserId then
			return true
		end
	end
	return currentState.masterUserId == LocalPlayer.UserId
end

local gui = Instance.new("ScreenGui")
gui.Name = "TeleportLobbyGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local root = Instance.new("Frame")
root.BackgroundTransparency = 1
root.Size = UDim2.fromScale(1, 1)
root.Parent = gui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.75)
panel.Size = UDim2.fromOffset(400, 320)
panel.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
panel.BackgroundTransparency = 0.75
panel.BorderSizePixel = 0
panel.Parent = root

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel

local panelPadding = Instance.new("UIPadding")
panelPadding.PaddingTop = UDim.new(0, 16)
panelPadding.PaddingBottom = UDim.new(0, 16)
panelPadding.PaddingLeft = UDim.new(0, 16)
panelPadding.PaddingRight = UDim.new(0, 16)
panelPadding.Parent = panel

local contentFrame = Instance.new("Frame")
contentFrame.BackgroundTransparency = 1
contentFrame.Size = UDim2.new(1, 0, 1, -52)
contentFrame.Parent = panel

local selectionFrame = Instance.new("Frame")
selectionFrame.BackgroundTransparency = 1
selectionFrame.Size = UDim2.fromScale(1, 1)
selectionFrame.Visible = false
selectionFrame.Parent = contentFrame

local selectionGrid = Instance.new("UIGridLayout")
selectionGrid.CellPadding = UDim2.fromOffset(8, 8)
selectionGrid.CellSize = UDim2.fromOffset(84, 84)
selectionGrid.FillDirectionMaxCells = 4
selectionGrid.SortOrder = Enum.SortOrder.LayoutOrder
selectionGrid.Parent = selectionFrame

local rosterFrame = Instance.new("Frame")
rosterFrame.BackgroundTransparency = 1
rosterFrame.Size = UDim2.fromScale(1, 1)
rosterFrame.Visible = false
rosterFrame.Parent = contentFrame

local rosterGrid = Instance.new("UIGridLayout")
rosterGrid.CellPadding = UDim2.fromOffset(8, 8)
rosterGrid.CellSize = UDim2.fromOffset(84, 120)
rosterGrid.FillDirectionMaxCells = 4
rosterGrid.SortOrder = Enum.SortOrder.LayoutOrder
rosterGrid.Parent = rosterFrame

local exitButton = Instance.new("TextButton")
exitButton.AnchorPoint = Vector2.new(0.5, 1)
exitButton.Position = UDim2.new(0.5, 0, 1, 0)
exitButton.Size = UDim2.fromOffset(120, 42)
exitButton.BackgroundColor3 = Color3.fromRGB(236, 102, 86)
exitButton.BorderSizePixel = 0
exitButton.AutoButtonColor = false
exitButton.Font = Enum.Font.GothamSemibold
exitButton.Text = "Keluar"
exitButton.TextColor3 = Color3.fromRGB(255, 255, 255)
exitButton.TextSize = 18
exitButton.Parent = panel

local exitCorner = Instance.new("UICorner")
exitCorner.CornerRadius = UDim.new(0, 10)
exitCorner.Parent = exitButton

exitButton.MouseButton1Click:Connect(function()
	TeleportService.requestExit(currentAreaName)
end)

local seatButtons = {}
local avatarSlots = {}
local thumbnailCache = {}

local function setSeatButtonVisual(button, isActive, enabled)
	if isActive then
		button.BackgroundColor3 = Color3.fromRGB(95, 147, 255)
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
	elseif enabled then
		button.BackgroundColor3 = Color3.fromRGB(36, 42, 57)
		button.TextColor3 = Color3.fromRGB(231, 236, 248)
	else
		button.BackgroundColor3 = Color3.fromRGB(30, 34, 45)
		button.TextColor3 = Color3.fromRGB(130, 137, 156)
	end
end

for capacity = 1, Config.MAX_ROOM_SIZE do
	local button = Instance.new("TextButton")
	button.Name = "Seat" .. tostring(capacity)
	button.Text = tostring(capacity)
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.TextSize = 28
	button.Parent = selectionFrame

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 12)
	buttonCorner.Parent = button

	button.MouseButton1Click:Connect(function()
		if not isLocalMaster() then
			return
		end
		if currentState.phase ~= "awaiting_capacity" then
			return
		end
		TeleportService.requestCapacity(currentAreaName, capacity)
	end)

	seatButtons[capacity] = button
end

for slotIndex = 1, Config.MAX_ROOM_SIZE do
	local slotFrame = Instance.new("Frame")
	slotFrame.BackgroundTransparency = 1
	slotFrame.LayoutOrder = slotIndex
	slotFrame.Parent = rosterFrame

	local avatar = Instance.new("ImageLabel")
	avatar.AnchorPoint = Vector2.new(0.5, 0)
	avatar.Position = UDim2.new(0.5, 0, 0, 0)
	avatar.Size = UDim2.fromOffset(78, 78)
	avatar.BackgroundColor3 = Color3.fromRGB(10, 12, 17)
	avatar.BorderSizePixel = 0
	avatar.Image = ""
	avatar.Parent = slotFrame

	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(0, 12)
	avatarCorner.Parent = avatar

	local kickButton = Instance.new("TextButton")
	kickButton.AnchorPoint = Vector2.new(0.5, 0)
	kickButton.Position = UDim2.new(0.5, 0, 0, 86)
	kickButton.Size = UDim2.fromOffset(38, 28)
	kickButton.BackgroundColor3 = Color3.fromRGB(236, 96, 96)
	kickButton.BorderSizePixel = 0
	kickButton.AutoButtonColor = false
	kickButton.Font = Enum.Font.GothamBold
	kickButton.Text = "X"
	kickButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	kickButton.TextSize = 18
	kickButton.Parent = slotFrame

	local kickCorner = Instance.new("UICorner")
	kickCorner.CornerRadius = UDim.new(0, 8)
	kickCorner.Parent = kickButton

	avatarSlots[slotIndex] = {
		frame = slotFrame,
		avatar = avatar,
		kick = kickButton,
		userId = nil,
	}
end

local function rebuildRosterSlots()
	local occupantBySlot = {}
	for index = 1, Config.MAX_ROOM_SIZE do
		occupantBySlot[index] = currentState.occupants[index]
	end

	local visibleSlots = currentState.capacity
	if not visibleSlots then
		visibleSlots = math.max(1, #currentState.occupants)
	end
	visibleSlots = math.clamp(visibleSlots, 1, Config.MAX_ROOM_SIZE)

	local canKick = isLocalMaster() and currentState.phase ~= "teleporting"
	for slotIndex = 1, Config.MAX_ROOM_SIZE do
		local slot = avatarSlots[slotIndex]
		slot.frame.Visible = slotIndex <= visibleSlots
		if not slot.frame.Visible then
			slot.userId = nil
			slot.kick.Visible = false
			slot.kick.Active = false
			continue
		end

		local occupant = occupantBySlot[slotIndex]
		if occupant then
			slot.userId = occupant.userId
			slot.avatar.Image = thumbnailCache[occupant.userId] or ""
			slot.avatar.BackgroundTransparency = 0

			local isSelf = occupant.userId == LocalPlayer.UserId
			slot.kick.Visible = canKick and not isSelf
			slot.kick.Active = slot.kick.Visible
			slot.kick.BackgroundTransparency = slot.kick.Visible and 0 or 0.65

			task.spawn(function()
				local ok, image = pcall(function()
					return Players:GetUserThumbnailAsync(occupant.userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
				end)
				if ok and slot.userId == occupant.userId and slot.avatar.Parent then
					thumbnailCache[occupant.userId] = image
					slot.avatar.Image = image
				end
			end)
		else
			slot.userId = nil
			slot.avatar.Image = ""
			slot.avatar.BackgroundTransparency = 0
			slot.kick.Visible = false
			slot.kick.Active = false
		end
	end
end

for _, slot in ipairs(avatarSlots) do
	slot.kick.MouseButton1Click:Connect(function()
		if not isLocalMaster() then
			return
		end
		if not slot.userId then
			return
		end
		if slot.userId == LocalPlayer.UserId then
			return
		end
		TeleportService.requestKick(currentAreaName, slot.userId)
	end)
end

local function applyStateToUi()
	local inRoom = hasLocalPlayerInRoom()
	gui.Enabled = inRoom

	if not inRoom then
		selectionFrame.Visible = false
		rosterFrame.Visible = false
		return
	end

	local showSelection = isLocalMaster() and currentState.phase == "awaiting_capacity"
	selectionFrame.Visible = showSelection
	rosterFrame.Visible = not showSelection

	for capacity, button in pairs(seatButtons) do
		button.Active = showSelection
		setSeatButtonVisual(button, currentState.capacity == capacity, showSelection)
	end

	if rosterFrame.Visible then
		rebuildRosterSlots()
	end
end

local function applyState(state)
	if not state or not state.areaName then
		return
	end

	if currentAreaName and state.areaName ~= currentAreaName and not stateHasLocalPlayer(state) then
		return
	end

	if not currentAreaName and not stateHasLocalPlayer(state) then
		return
	end

	currentAreaName = currentAreaName or state.areaName
	currentState.phase = state.phase or "idle"
	currentState.areaName = state.areaName
	currentState.masterUserId = state.masterUserId
	currentState.capacity = state.capacity
	currentState.occupants = state.occupants or {}

	if currentAreaName == state.areaName and currentState.phase == "idle" and #currentState.occupants == 0 then
		currentAreaName = nil
		currentState.areaName = nil
	end

	applyStateToUi()
end

TeleportService.onStateChanged(applyState)
applyStateToUi()
