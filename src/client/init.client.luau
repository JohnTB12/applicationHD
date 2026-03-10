local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local fireRemote = remotesFolder:WaitForChild("FireProjectile")
if not fireRemote:IsA("RemoteEvent") then
	error("Remotes.FireProjectile must be a RemoteEvent")
end

local settings = {
	toolName = "PewPewTool",
	localCooldown = 0.08,
	aimRayDistance = 500,
}

local lastFireTime = 0
local connectedTools = setmetatable({}, { __mode = "k" })

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude
aimParams.IgnoreWater = true
local aimIgnore = {}

local function getBackpack()
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		return backpack
	end
	return player:WaitForChild("Backpack")
end

local function createTool()
	local tool = Instance.new("Tool")
	tool.Name = settings.toolName
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool.ToolTip = "Left click to launch a projectile."
	return tool
end

local function getOrCreateTool(backpack)
	local tool = backpack:FindFirstChild(settings.toolName)
	if not tool and player.Character then
		tool = player.Character:FindFirstChild(settings.toolName)
	end

	if tool and tool:IsA("Tool") then
		return tool
	end

	tool = createTool()
	tool.Parent = backpack
	return tool
end

local function canFire()
	local now = os.clock()
	if now - lastFireTime < settings.localCooldown then
		return false
	end
	lastFireTime = now
	return true
end

local function getTargetPosition()
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local character = player.Character

	aimIgnore[1] = character
	aimParams.FilterDescendantsInstances = aimIgnore

	local hit = Workspace:Raycast(ray.Origin, ray.Direction * settings.aimRayDistance, aimParams)
	if hit then
		return hit.Position
	end
	return ray.Origin + ray.Direction * settings.aimRayDistance
end

local function fireAtCursor()
	if not canFire() then
		return
	end

	local target = getTargetPosition()
	if not target then
		return
	end

	fireRemote:FireServer(target)
end

local function connectTool(tool)
	if connectedTools[tool] then
		return
	end
	connectedTools[tool] = true
	tool.Activated:Connect(fireAtCursor)
end

local function setupTool()
	local backpack = getBackpack()
	local tool = getOrCreateTool(backpack)

	if tool.Parent ~= backpack and tool.Parent ~= player.Character then
		tool.Parent = backpack
	end

	connectTool(tool)
end

setupTool()
player.CharacterAdded:Connect(function()
	task.defer(setupTool)
end)
