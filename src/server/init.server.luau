-- Basic projectile system with damage falloff and bullet drop.
-- Credit to @JohnTB12 (GitHub) @JohnTB14 (Roblox) johntb (Discord)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")

local cfg = {
	collisionGroup = "Projectiles",
	poolStart = 16,
	poolMax = 42,
	maxActive = 42,
	cooldown = 0.3,
	speed = 180,
	life = 4.2,
	range = 320,
	gravityScale = 0.35,
	baseDamage = 30,
	minDamage = 12,
	falloffStart = 80,
	falloffEnd = 300,
	allowFriendlyFire = false,
}

local gravity = Workspace.Gravity
local muzzleForwardOffset = 2
local muzzleHeightOffset = 1.5
local pooledPartParkCFrame = CFrame.new(0, -1000, 0)

local playerState = {}
local projectilePool = {}
local activeProjectiles = {}

local remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage

local fireRemote = remotes:FindFirstChild("FireProjectile") or Instance.new("RemoteEvent")
fireRemote.Name = "FireProjectile"
fireRemote.Parent = remotes

local assets = ReplicatedStorage:FindFirstChild("Assets") or Instance.new("Folder")
assets.Name = "Assets"
assets.Parent = ReplicatedStorage

local template = assets:FindFirstChild("ProjectileTemplate")
if not template then
	template = Instance.new("Part")
	template.Name = "ProjectileTemplate"
	template.Shape = Enum.PartType.Ball
	template.Size = Vector3.new(1, 1, 1)
	template.Material = Enum.Material.Neon
	template.Color = Color3.fromRGB(255, 170, 70)
	template.Transparency = 1
	template.Massless = true
	template.Anchored = true
	template.CanCollide = false
	template.CanQuery = false
	template.CanTouch = false
	template.Parent = assets
end

local projectileFolder = Workspace:FindFirstChild("Projectiles") or Instance.new("Folder")
projectileFolder.Name = "Projectiles"
projectileFolder.Parent = Workspace

local function setupCollisionGroup(groupName)
	-- collision groups persist between studio runs
	local ok, err = pcall(function()
		PhysicsService:RegisterCollisionGroup(groupName)
	end)
	if not ok then warn("collision group register:", err) end

	ok, err = pcall(function()
		PhysicsService:CollisionGroupSetCollidable(groupName, groupName, false)
	end)
	if not ok then warn("collision group collidable:", err) end
end

local function damageAt(distance)
	if distance <= cfg.falloffStart then
		return cfg.baseDamage
	end
	if distance >= cfg.falloffEnd then
		return cfg.minDamage
	end
	local t = (distance - cfg.falloffStart) / (cfg.falloffEnd - cfg.falloffStart)
	return math.round(cfg.baseDamage + (cfg.minDamage - cfg.baseDamage) * t)
end

local function findHumanoid(part)
	local model = part:FindFirstAncestorWhichIsA("Model")
	return model and model:FindFirstChildOfClass("Humanoid")
end

local function isFriendly(shooter, hum)
	if cfg.allowFriendlyFire then return false end
	local target = hum and Players:GetPlayerFromCharacter(hum.Parent)
	if not shooter or not target then return false end
	if shooter == target then return true end
	return shooter.Team ~= nil and shooter.Team == target.Team
end

local function canPlayerShoot(state)
	if not state then return false end
	return #activeProjectiles < cfg.maxActive and os.clock() - state.lastFire >= cfg.cooldown
end

local function getAliveRoot(player)
	local character = player.Character
	if not character then
		return nil
	end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
end

local function buildDirection(origin, target, fallbackLook)
	local dir = target - origin
	if dir.Magnitude < 0.01 then
		return fallbackLook
	end
	return dir.Unit
end

local function validateFire(player, target)
	if typeof(target) ~= "Vector3" then
		return false
	end
	if target.X ~= target.X or target.Y ~= target.Y or target.Z ~= target.Z then -- just checking for NaN:)
		return false
	end

	if not canPlayerShoot(playerState[player]) then
		return false
	end

	local root = getAliveRoot(player)
	if not root then
		return false
	end

	local origin = root.Position
		+ root.CFrame.LookVector * muzzleForwardOffset
		+ Vector3.yAxis * muzzleHeightOffset
	return true, origin, buildDirection(origin, target, root.CFrame.LookVector)
end

local Projectile = {}
Projectile.__index = Projectile

function Projectile.new(part)
	local self = setmetatable({}, Projectile)
	self.part = part
	self.active = false
	self.shooter = nil
	self.origin = Vector3.zero
	self.position = Vector3.zero
	self.velocity = Vector3.zero
	self.direction = Vector3.zero
	self.spawnTime = 0
	self.distance = 0
	self.ignore = {}
	self.raycastParams = RaycastParams.new()
	self.raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.raycastParams.IgnoreWater = true
	return self
end

function Projectile:Activate(shooter, origin, direction)
	self.active = true
	self.shooter = shooter
	self.origin = origin
	self.position = origin
	self.direction = direction
	self.velocity = direction * cfg.speed
	self.spawnTime = os.clock()
	self.distance = 0
	self.ignore = { self.part, projectileFolder }
	if shooter.Character then
		table.insert(self.ignore, shooter.Character)
	end
	self.raycastParams.FilterDescendantsInstances = self.ignore

	self.part.Transparency = 0
	self.part.CFrame = CFrame.lookAt(origin, origin + direction)
end

function Projectile:Deactivate()
	self.active = false
	self.shooter = nil
	self.spawnTime = 0
	self.distance = 0
	self.ignore = {}
	self.raycastParams.FilterDescendantsInstances = {}
	self.part.Transparency = 1
	self.part.CFrame = pooledPartParkCFrame
end

function Projectile:Step(dt)
	if not self.active then
		return
	end
	if os.clock() - self.spawnTime >= cfg.life or self.distance >= cfg.range then
		self:Deactivate()
		return
	end

	local from = self.position
	self.velocity += Vector3.yAxis * (-gravity * cfg.gravityScale * dt)
	local delta = self.velocity * dt
	local to = from + delta

	local hit = Workspace:Raycast(from, delta, self.raycastParams)
	if hit then
		local hum = findHumanoid(hit.Instance)
		if hum and hum.Health > 0 and not isFriendly(self.shooter, hum) then
			local creator = Instance.new("ObjectValue")
			creator.Name = "creator"
			creator.Value = self.shooter
			creator.Parent = hum
			task.delay(1.25, function()
				creator:Destroy()
			end)
			hum:TakeDamage(damageAt((hit.Position - self.origin).Magnitude))
		end

		local impact = Instance.new("Part")
		impact.Name = "Impact"
		impact.Size = Vector3.new(0.35, 0.35, 0.35)
		impact.Material = Enum.Material.Neon
		impact.Color = Color3.fromRGB(255, 95, 95)
		impact.Anchored = true
		impact.CanCollide = false
		impact.CanQuery = false
		impact.CanTouch = false
		impact.CFrame = CFrame.lookAt(hit.Position, hit.Position + hit.Normal)
		impact.Parent = projectileFolder
		
		task.delay(0.12, function()
			impact:Destroy()
		end)

		self:Deactivate()
		return
	end

	self.position = to
	local magnitude = delta.Magnitude
	self.distance += magnitude
	if magnitude > 0 then
		self.direction = delta.Unit
	end

	self.part.CFrame = CFrame.lookAt(to, to + self.direction)
end

local function makePoolProjectile()
	local part = template:Clone()
	part.Transparency = 1
	part.Massless = true
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CollisionGroup = cfg.collisionGroup
	part.CFrame = pooledPartParkCFrame
	part.Parent = projectileFolder

	local projectile = Projectile.new(part)
	table.insert(projectilePool, projectile)
	return projectile
end

local function initPool()
	for _ = 1, cfg.poolStart do
		makePoolProjectile()
	end
end

local function acquireProjectile()
	for _, projectile in projectilePool do
		if not projectile.active then
			return projectile
		end
	end
	if #projectilePool < cfg.poolMax then
		return makePoolProjectile()
	end
	return nil
end

local function fire(player, target)
	local ok, origin, direction = validateFire(player, target)
	if not ok then
		return
	end

	local projectile = acquireProjectile()
	if not projectile then
		return
	end

	playerState[player].lastFire = os.clock()
	projectile:Activate(player, origin, direction)
	table.insert(activeProjectiles, projectile)
end

local function stepAll(dt)
	for i = #activeProjectiles, 1, -1 do
		local projectile = activeProjectiles[i]
		projectile:Step(dt)
		if not projectile.active then
			activeProjectiles[i] = activeProjectiles[#activeProjectiles] -- swap remove, don't care about order
			activeProjectiles[#activeProjectiles] = nil
		end
	end
end

local function init()
	setupCollisionGroup(cfg.collisionGroup)
	initPool()

	Players.PlayerAdded:Connect(function(player)
		playerState[player] = { lastFire = 0 }
		player.CharacterAdded:Connect(function()
			local state = playerState[player]
			if state then
				state.lastFire = 0
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerState[player] = nil
	end)

	for _, player in Players:GetPlayers() do
		playerState[player] = { lastFire = 0 }
	end

	fireRemote.OnServerEvent:Connect(fire)
	RunService.Heartbeat:Connect(stepAll)
end

init()
