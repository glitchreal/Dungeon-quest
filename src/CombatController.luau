-- Obsidian dungeon combat controller; creates no separate UI.
-- The controller has one movement owner: dodge goals preempt combat goals,
-- and path recovery invalidates the active path instead of issuing random jumps.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local player = Players.LocalPlayer

local CFG = {
    ATTACK_RANGE = 26,
    COMBAT_DISTANCE = 20,
    COMBAT_MIN_DISTANCE = 16,
    COMBAT_MAX_DISTANCE = 24,
    SKILL_COOLDOWN = 0.2,
    CONTROL_INTERVAL = 1 / 30,
    UI_INTERVAL = 0.15,
    THREAT_SCAN_INTERVAL = 0.2,
    DETECTION_RADIUS = 1000,

    PATH_UPDATE_INTERVAL = 0.8,
    WAYPOINT_REACH_THRESHOLD = 3,
    DIRECT_PATH_DISTANCE = 40,
    MOVETO_REFRESH_INTERVAL = 0.45,
    AGENT_RADIUS = 2.0,
    AGENT_HEIGHT = 5.5,
    AGENT_CAN_JUMP = true,
    AGENT_JUMP_HEIGHT = 12,
    AGENT_MAX_SLOPE = 70,
    WAYPOINT_SPACING = 4,

    STUCK_CHECK_INTERVAL = 0.35,
    STUCK_MOVE_THRESHOLD = 0.45,
    STUCK_TIMEOUT = 0.75,
    FAILED_PATH_COOLDOWN = 2.5,
    TARGET_SCAN_INTERVAL = 0.25,
    DODGE_COOLDOWN = 1,
    DODGE_LATERAL_DISTANCE = 3,
    DODGE_WINDOW = 3,
    DODGE_MAX_PER_WINDOW = 2,
    DODGE_DISTANCE_BUDGET = 6,
    DODGE_SAME_THREAT_COOLDOWN = 3,
    THREAT_RADIUS = 90,
    PROJECTILE_LOOKAHEAD = 1.35,
    PRECAST_MARGIN = 3,
    HAZARD_MARGIN = 6,
    THREAT_MAX_AGE = 2,
    AUTO_ABILITIES = true,
    AUTO_DODGE = true,
    REACTION_TIME = 0.05,
    MELEE_DANGER_DISTANCE = 11,
    RETREAT_RELEASE_MARGIN = 5,
    FARM_POSITION = "Nearest",
    SMART_FARM = true,
    GROUP_RADIUS = 6,
    CLOSE_AOE_RANGE = 8,
    SPELL_RANGE_OVERRIDE = 0,

    SHOW_WAYPOINTS = true,
    WAYPOINT_NODE_SIZE = 0.5,
    WAYPOINT_LINE_THICKNESS = 0.15,
    WAYPOINT_COLOR = Color3.fromRGB(0, 255, 255),
    CURRENT_WAYPOINT_COLOR = Color3.fromRGB(255, 255, 0),
}

local state = {
    running = false,
    closed = false,
    updateBusy = false,
    skillToggle = false,
    lastSkillTime = 0,
    targetName = "Scanning...",
    targetDist = 0,
    skillQ_count = 0,
    skillE_count = 0,
    status = "Idle",
    kills = 0,
    prevHealth = setmetatable({}, { __mode = "k" }),
    currentTarget = nil,
    lockedTarget = nil,
    cachedTargets = {},
    lastTargetScan = 0,

    motionMode = "idle",
    motionGoal = nil,
    motionGoalMode = nil,
    lastMoveToCall = 0,
    lastMoveToPosition = Vector3.zero,
    waypoints = {},
    currentWaypointIndex = 1,
    pathObject = nil,
    pathBlocked = false,
    pathBlockedConn = nil,
    pathGoal = nil,
    pathMode = nil,
    pathUpdateTime = 0,
    failedPaths = {},
    fallbackGoal = nil,
    fallbackUntil = 0,

    lastPosition = Vector3.zero,
    lastStuckCheck = 0,
    lastProgressDistance = math.huge,
    lastProgressAt = 0,
    stuckRetries = 0,
    stuckCount = 0,
    stuckStartTime = 0,

    dodgeGoal = nil,
    lastDodgeTime = 0,
    lastThreatPart = nil,
    lastDodgeThreat = nil,
    lastDodgeThreatAt = 0,
    dodgeSide = 1,
    dodgeCount = 0,
    damageEvents = 0,
    lastPlayerHealth = nil,

    waypointFolder = nil,
    visualNodes = {},
    pathGeneration = 0,
    pathPending = false,
    lastThreatScan = 0,
    dodgeHistory = {},
    dodgedThreats = setmetatable({}, { __mode = "k" }),
    observedThreats = setmetatable({}, { __mode = "k" }),
    activeZones = {},
    nearbyEnemies = {},
    safetyUntil = 0,
    lastSafetyScan = -math.huge,
    lastEscapePlan = -math.huge,
    enemyMotion = setmetatable({}, { __mode = "k" }),
    retreating = false,
    pathComputations = 0,
}

local abilities = AbilityController.new(player, function(slot)
    if state.closed then return end
    local key = slot == "q" and "skillQ_count" or "skillE_count"
    state[key] = state[key] + 1
end)

local connections = {}
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

local humanoidModels = {}
-- PrecastHitbox and similar effects are transient BaseParts. Tracking additions
-- lets the dodge check remain cheap and catches indicators created under Workspace.
local threatParts = {}
local announcedZones = {}
local function trackInstance(instance)
    if instance:IsA("Humanoid") and instance.Parent and instance.Parent:IsA("Model") then
        humanoidModels[instance] = instance.Parent
    end
    if instance:IsA("BasePart") then
        local now = os.clock()
        if not instance.CanCollide and (not state.waypointFolder or not instance:IsDescendantOf(state.waypointFolder)) then
            threatParts[instance] = { createdAt = now, lastPosition = instance.Position, lastAt = now }
        end
    end
end
connect(Workspace.DescendantAdded, trackInstance)
connect(Workspace.DescendantRemoving, function(instance)
    local sample = threatParts[instance]
    if sample and sample.zone then sample.removedAt = os.clock() else threatParts[instance] = nil end
    humanoidModels[instance] = nil
end)
for _, instance in ipairs(Workspace:GetDescendants()) do trackInstance(instance) end

-- The game announces boss telegraphs before their Parts become visible.
pcall(function()
    local storage = game:GetService("ReplicatedStorage")
    local utility = storage:FindFirstChild("Utility")
    local module = utility and utility:FindFirstChild("BridgeNet2")
    if not module then return end
    local bridge = require(module)
    local action = bridge.ReferenceIdentifier("action")
    local connection = bridge.ReferenceBridge("precastHitbox"):Connect(function(data)
        if state.closed or type(data) ~= "table" then return end
        local kind = data[action]
        if kind ~= "Circle" and kind ~= "Cube" then return end
        local now = os.clock()
        local remaining = (tonumber(data.delayUntilAttack) or 0) - (Workspace:GetServerTimeNow() - (tonumber(data.startTime) or Workspace:GetServerTimeNow()))
        local frame, size, shape
        if kind == "Circle" and typeof(data.position) == "Vector3" and type(data.radius) == "number" then
            frame = CFrame.new(data.position) * CFrame.Angles(0, 0, math.pi / 2)
            size, shape = Vector3.new(0.5, data.radius * 2, data.radius * 2), "Cylinder"
        elseif kind == "Cube" and typeof(data.cframe) == "CFrame" and typeof(data.size) == "Vector3" then
            frame, size, shape = data.cframe, data.size, "Block"
        end
        if frame and remaining > -0.35 then
            table.insert(announcedZones, { frame = frame, size = size, shape = shape, expires = now + math.max(0, remaining) + 0.4, id = {} })
        end
    end)
    table.insert(connections, connection)
end)

local function getChar()
    local character = player.Character
    if not character then return nil, nil, nil end
    return character, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function createWaypointFolder()
    if state.waypointFolder then state.waypointFolder:Destroy() end
    local folder = Instance.new("Folder")
    folder.Name = "PathWaypoints_" .. player.Name
    folder.Parent = Workspace
    state.waypointFolder = folder
    return folder
end

local function clearWaypointVisuals()
    if #state.visualNodes > 0 and state.waypointFolder then state.waypointFolder:ClearAllChildren() end
    state.visualNodes = {}
end

local function visualizeWaypoints(waypoints, currentIndex)
    clearWaypointVisuals()
    if not CFG.SHOW_WAYPOINTS or not waypoints or #waypoints == 0 then return end
    if not state.waypointFolder then createWaypointFolder() end
    for index, waypoint in ipairs(waypoints) do
        local node = Instance.new("Part")
        node.Name = "WaypointNode"
        node.Shape = Enum.PartType.Ball
        node.Size = Vector3.new(CFG.WAYPOINT_NODE_SIZE, CFG.WAYPOINT_NODE_SIZE, CFG.WAYPOINT_NODE_SIZE)
        node.Position = waypoint.Position
        node.Anchored = true
        node.CanCollide = false
        node.CanTouch = false
        node.CanQuery = false
        node.Material = Enum.Material.Neon
        node.Transparency = 0.3
        node.Color = index == currentIndex and CFG.CURRENT_WAYPOINT_COLOR or CFG.WAYPOINT_COLOR
        node.Parent = state.waypointFolder
        table.insert(state.visualNodes, node)
        if index < #waypoints then
            local nextPosition = waypoints[index + 1].Position
            local distance = (nextPosition - waypoint.Position).Magnitude
            local line = Instance.new("Part")
            line.Name = "WaypointLine"
            line.Size = Vector3.new(CFG.WAYPOINT_LINE_THICKNESS, CFG.WAYPOINT_LINE_THICKNESS, distance)
            line.CFrame = CFrame.new((waypoint.Position + nextPosition) / 2, nextPosition)
            line.Anchored = true
            line.CanCollide = false
            line.CanTouch = false
            line.CanQuery = false
            line.Material = Enum.Material.Neon
            line.Transparency = 0.5
            line.Color = CFG.WAYPOINT_COLOR
            line.Parent = state.waypointFolder
            table.insert(state.visualNodes, line)
        end
    end
end

local function updateWaypointHighlight(index)
    local visualIndex = 1
    for waypointIndex = 1, #state.waypoints do
        local node = state.visualNodes[visualIndex]
        if node then
            node.Color = waypointIndex == index and CFG.CURRENT_WAYPOINT_COLOR or CFG.WAYPOINT_COLOR
        end
        visualIndex = visualIndex + 2
    end
end

-- Enemy discovery is based on Humanoid-bearing ancestor Models. Child parts,
-- attachments, and decorative geometry are therefore never separate targets.
local function getRootPart(model)
    local root = model:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then return root end
    local head = model:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head end
    return model.PrimaryPart
end

local function isValidTarget(model)
    if not model or not model.Parent or not model:IsA("Model") then return false end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local root = getRootPart(model)
    return humanoid ~= nil and humanoid.Health > 0 and root ~= nil and root:IsA("BasePart")
end

local function isPlayerOrLobbyCharacter(model)
    if Players:GetPlayerFromCharacter(model) then return true end
    local fullName = model:GetFullName():lower()
    if fullName:find(".lobby") or fullName:find(".aesthetic") then return true end
    if model.Name == player.Name or model.Name == "Seller" or model.Name == "Blacksmith" then return true end
    return false
end

local function refreshTargets(rootPart, now)
    if now - state.lastTargetScan < CFG.TARGET_SCAN_INTERVAL then return end
    state.lastTargetScan = now
    local targets = {}
    for humanoid, model in pairs(humanoidModels) do
        if humanoid.Parent ~= model then
            humanoidModels[humanoid] = humanoid.Parent and humanoid.Parent:IsA("Model") and humanoid.Parent or nil
        elseif model:IsDescendantOf(Workspace) and not isPlayerOrLobbyCharacter(model) and isValidTarget(model) then
            local root = getRootPart(model)
            if (root.Position - rootPart.Position).Magnitude <= CFG.DETECTION_RADIUS then
                table.insert(targets, model)
            end
        end
    end
    state.cachedTargets = targets
end

local hasBlockingRay

local function getClosestEnemy(rootPart, now)
    refreshTargets(rootPart, now)
    if now - (state.lastTargetChoice or 0) < 0.15 and isValidTarget(state.lockedTarget) then
        local root = getRootPart(state.lockedTarget)
        local distance = (rootPart.Position - root.Position).Magnitude
        if distance <= CFG.DETECTION_RADIUS and state.lockedTarget:IsDescendantOf(Workspace) then
            return state.lockedTarget, distance
        end
    end
    state.lastTargetChoice = now
    local candidates = {}
    for _, model in ipairs(state.cachedTargets) do
        if isValidTarget(model) and model:IsDescendantOf(Workspace) then
            local root = getRootPart(model)
            local distance = (rootPart.Position - root.Position).Magnitude
            if distance <= CFG.DETECTION_RADIUS then
                table.insert(candidates, { model = model, root = root, distance = distance })
            end
        end
    end
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    local closest = candidates[1]
    if closest then
        -- Prefer nearby enemies we can engage over a closer one behind a wall.
        local searchDistance = math.max(CFG.THREAT_RADIUS, closest.distance + 24)
        for _, candidate in ipairs(candidates) do
            if candidate.distance > searchDistance then break end
            if not hasBlockingRay(rootPart.Position, candidate.root.Position, rootPart.Parent, candidate.model) then
                closest = candidate
                break
            end
        end
    end
    state.lockedTarget = closest and closest.model
    return state.lockedTarget, closest and closest.distance or CFG.DETECTION_RADIUS
end

local function buildRaycastParams(character, target)
    local ignored = { character }
    if target then table.insert(ignored, target) end
    if state.waypointFolder then table.insert(ignored, state.waypointFolder) end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignored
    params.IgnoreWater = true
    return params
end

hasBlockingRay = function(origin, destination, character, target)
    local direction = destination - origin
    local params = buildRaycastParams(character, target)
    for _ = 1, 6 do
        local hit = Workspace:Raycast(origin, direction, params)
        if not hit then return false end
        local instance = hit.Instance
        local ancestorModel = instance:FindFirstAncestorOfClass("Model")
        local isHumanoidPart = ancestorModel and ancestorModel:FindFirstChildOfClass("Humanoid") ~= nil
        -- Humanoid bodies, invisible hitboxes, and attached effects are dynamic
        -- gameplay geometry, not walls. Static collidable map parts remain blockers.
        if (instance:IsA("BasePart") and not instance.CanCollide) or isHumanoidPart then
            local ignored = params.FilterDescendantsInstances
            table.insert(ignored, isHumanoidPart and ancestorModel or instance)
            params.FilterDescendantsInstances = ignored
        else
            return true
        end
    end
    return true
end

local function groundPosition(position, character, target)
    local hit = Workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), buildRaycastParams(character, target))
    if hit then return Vector3.new(position.X, hit.Position.Y + 2.5, position.Z) end
    return position
end

local function walkingSegmentClear(rootPart, destination, target, params, startFloor)
    params = params or buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    startFloor = startFloor or Workspace:Raycast(rootPart.Position, Vector3.new(0, -12, 0), params)
    if not startFloor then return false end
    local startPosition = rootPart.Position
    local flat = Vector3.new(destination.X - startPosition.X, 0, destination.Z - startPosition.Z)
    if flat.Magnitude < 0.1 then return true end
    local previousY = startFloor.Position.Y
    local steps = math.max(1, math.ceil(flat.Magnitude / 3))
    for i = 1, steps do
        local sample = startPosition + flat * (i / steps)
        sample = Vector3.new(sample.X, previousY + 6, sample.Z)
        local ground = Workspace:Raycast(sample, Vector3.new(0, -12, 0), params)
        if not ground or ground.Normal.Y < 0.55 or math.abs(ground.Position.Y - previousY) > 2 then return false end
        if ground.Instance.Name:lower():find("lava", 1, true) and not startFloor.Instance.Name:lower():find("lava", 1, true) then return false end
        previousY = ground.Position.Y
    end
    local endPosition = startPosition + flat + Vector3.new(0, previousY - startFloor.Position.Y, 0)
    local right = Vector3.new(-flat.Z, 0, flat.X).Unit * math.min(CFG.AGENT_RADIUS, 1.5)
    for _, offset in ipairs({ Vector3.zero, right, -right }) do
        if hasBlockingRay(startPosition + offset, endPosition + offset, rootPart.Parent, target) then return false end
    end
    return true
end

local function pathKey(startPosition, endPosition, mode)
    local function quantize(value) return math.floor(value / 4 + 0.5) end
    return string.format("%s:%d,%d,%d>%d,%d,%d", mode or "combat", quantize(startPosition.X), quantize(startPosition.Y), quantize(startPosition.Z), quantize(endPosition.X), quantize(endPosition.Y), quantize(endPosition.Z))
end

local function clearPath()
    state.terrainRecovery = nil
    state.directTravel = false
    state.pathGeneration = state.pathGeneration + 1
    if state.pathBlockedConn then state.pathBlockedConn:Disconnect() end
    state.pathBlockedConn = nil
    if state.pathObject then state.pathObject:Destroy() end
    state.pathObject = nil
    state.pathBlocked = false
    state.waypoints = {}
    state.currentWaypointIndex = 1
    state.pathGoal = nil
    state.pathMode = nil
    clearWaypointVisuals()
end

local function createPath(startPosition, endPosition, mode, now)
    for cachedKey, failedTime in pairs(state.failedPaths) do
        if now - failedTime >= CFG.FAILED_PATH_COOLDOWN then state.failedPaths[cachedKey] = nil end
    end
    local key = pathKey(startPosition, endPosition, mode)
    local failedAt = state.failedPaths[key]
    if failedAt and now - failedAt < CFG.FAILED_PATH_COOLDOWN then return nil end

    local configurations = {
        { AgentRadius = CFG.AGENT_RADIUS, AgentHeight = CFG.AGENT_HEIGHT, AgentCanJump = CFG.AGENT_CAN_JUMP, AgentJumpHeight = CFG.AGENT_JUMP_HEIGHT, AgentMaxSlope = CFG.AGENT_MAX_SLOPE, WaypointSpacing = CFG.WAYPOINT_SPACING },
        { AgentRadius = math.max(1.5, CFG.AGENT_RADIUS - 0.5), AgentHeight = CFG.AGENT_HEIGHT, AgentCanJump = true, AgentJumpHeight = CFG.AGENT_JUMP_HEIGHT + 2, AgentMaxSlope = CFG.AGENT_MAX_SLOPE, WaypointSpacing = 3 },
    }
    for _, configuration in ipairs(configurations) do
        local path = PathfindingService:CreatePath(configuration)
        state.pathComputations = state.pathComputations + 1
        local ok = pcall(function() path:ComputeAsync(startPosition, endPosition) end)
        if ok and path.Status == Enum.PathStatus.Success then
            local waypoints = path:GetWaypoints()
            if #waypoints >= 2 then
                state.failedPaths[key] = nil
                return path, waypoints
            end
        end
        path:Destroy()
    end
    state.failedPaths[key] = now
    return nil
end

local function clearanceFromEnemy(enemy, position)
    local current = enemy.root.Position
    return ThreatGeometry.segmentDistance(position, current, current + enemy.velocity * 0.5) - enemy.radius
end

local function enemyClearance(position)
    local nearest = math.huge
    for _, enemy in ipairs(state.nearbyEnemies) do
        if enemy.root.Parent then
            nearest = math.min(nearest, clearanceFromEnemy(enemy, position))
        end
    end
    return nearest
end

local function safeEnemyStep(startPosition, endPosition)
    for _, enemy in ipairs(state.nearbyEnemies) do
        if enemy.root.Parent then
            local original = clearanceFromEnemy(enemy, startPosition)
            for i = 1, 4 do
                local clearance = clearanceFromEnemy(enemy, startPosition:Lerp(endPosition, i / 4))
                if clearance < math.min(0, original) - 0.1 then return false end
                original = clearance
            end
        end
    end
    return true
end

local function issueMove(humanoid, position, mode, now)
    if CFG.AUTO_DODGE and #state.activeZones > 0 then
        local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
        if root then
            local delta = position - root.Position
            local nextPosition = delta.Magnitude > 12 and root.Position + delta.Unit * 12 or position
            if not ThreatGeometry.segmentSafe(state.activeZones, root.Position, nextPosition, CFG.HAZARD_MARGIN) then
                humanoid:MoveTo(root.Position)
                state.motionMode = "safety-hold"
                state.movementBlocked = true
                state.blockedByHazard = true
                state.lastEscapePlan = -math.huge
                state.safetyUntil = math.max(state.safetyUntil, now + 0.3)
                state.lastMoveToCall = 0
                return
            end
        end
    end
    if CFG.AUTO_DODGE and #state.nearbyEnemies > 0 then
        local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
        if root then
            local delta = position - root.Position
            local reach = math.max(3, humanoid.WalkSpeed * 0.3)
            local step = delta.Magnitude > reach and root.Position + delta.Unit * reach or position
            if not safeEnemyStep(root.Position, step) then
                humanoid:MoveTo(root.Position)
                state.motionMode, state.movementBlocked = "safety-hold", true
                state.lastEscapePlan = -math.huge
                state.lastMoveToCall = 0
                return
            end
        end
    end
    local changed = state.motionMode ~= mode or (position - state.lastMoveToPosition).Magnitude > 0.75
    if changed or now - state.lastMoveToCall >= CFG.MOVETO_REFRESH_INTERVAL then
        humanoid:MoveTo(position)
        state.lastMoveToCall = now
        state.lastMoveToPosition = position
    end
    state.motionMode = mode
end

local function chooseFallbackStep(rootPart, goal, target)
    local delta = goal - rootPart.Position
    local forward = Vector3.new(delta.X, 0, delta.Z)
    if forward.Magnitude < 0.1 then forward = Vector3.new(1, 0, 0) end
    forward = forward.Unit
    local directions = {
        forward, Vector3.new(-forward.Z, 0, forward.X), Vector3.new(forward.Z, 0, -forward.X),
        -forward, (forward + Vector3.new(-forward.Z, 0, forward.X)).Unit,
        (forward + Vector3.new(forward.Z, 0, -forward.X)).Unit,
    }
    local best, bestScore
    state.fallbackVisits = state.fallbackVisits or {}
    local now = os.clock()
    for key, at in pairs(state.fallbackVisits) do if now - at > 15 then state.fallbackVisits[key] = nil end end
    for _, direction in ipairs(directions) do
        local candidate = groundPosition(rootPart.Position + direction * 8, rootPart.Parent, target)
        if walkingSegmentClear(rootPart, candidate, target) then
            local key = math.floor(candidate.X / 6) .. ":" .. math.floor(candidate.Z / 6)
            local score = (candidate - goal).Magnitude + (state.fallbackVisits[key] and 40 or 0)
            if not bestScore or score < bestScore then best, bestScore = candidate, score end
        end
    end
    if best then state.fallbackVisits[math.floor(best.X / 6) .. ":" .. math.floor(best.Z / 6)] = now end
    return best
end

local function findRecoveryPath(rootPart, goal, target)
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    local start = rootPart.Position
    local candidates = {}
    for _, radius in ipairs({ 24, 48, 64 }) do
        for index = 0, 11 do
            local angle = index * math.pi / 6
            local sample = start + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            local hit = Workspace:Raycast(sample + Vector3.new(0, 60, 0), Vector3.new(0, -100, 0), params)
            if hit and hit.Normal.Y > 0.65 and hit.Position.Y > start.Y + 4
                and not hit.Instance.Name:lower():find("lava", 1, true) then
                table.insert(candidates, hit.Position + Vector3.new(0, 2.5, 0))
            end
        end
    end
    table.sort(candidates, function(a, b)
        return (a - goal).Magnitude < (b - goal).Magnitude
    end)
    for index = 1, math.min(6, #candidates) do
        if state.closed or not state.running or player.Character ~= rootPart.Parent then return nil end
        local path, waypoints = createPath(start, candidates[index], "terrain-recovery", os.clock())
        if path then return path, waypoints, candidates[index] end
    end
end

local function followGoal(humanoid, rootPart, goal, mode, now, target)
    if not goal then return end
    if state.terrainRecovery and #state.waypoints > 0 then
        goal, mode = state.terrainRecovery, "terrain-recovery"
    end
    local newGoal = not state.motionGoal or (state.motionGoal - goal).Magnitude > 2 or state.motionGoalMode ~= mode
    if newGoal then
        state.motionGoal, state.motionGoalMode = goal, mode
        state.fallbackGoal, state.fallbackUntil = nil, 0
        if state.pathMode and state.pathMode ~= mode then clearPath() end
        state.lastProgressDistance = math.huge
        state.lastProgressAt = now
    end

    -- Keep a short collision-checked escape step active between path attempts.
    -- MoveTo has an internal timeout, so refreshing it here prevents a wall
    -- corner from leaving the Humanoid idle while the long path is retried.
    if state.fallbackGoal and now < state.fallbackUntil then
        if (rootPart.Position - state.fallbackGoal).Magnitude > CFG.WAYPOINT_REACH_THRESHOLD then
            issueMove(humanoid, state.fallbackGoal, mode, now)
            return
        end
        state.fallbackGoal, state.fallbackUntil = nil, 0
    end

    if (goal - rootPart.Position).Magnitude <= CFG.DIRECT_PATH_DISTANCE then
        local probe = state.directProbe
        if not probe or now - probe.at > 0.2 or probe.target ~= target or probe.character ~= rootPart.Parent
            or (probe.origin - rootPart.Position).Magnitude > 5 or (probe.goal - goal).Magnitude > 4 then
            probe = { at = now, target = target, character = rootPart.Parent, origin = rootPart.Position, goal = goal,
                clear = walkingSegmentClear(rootPart, goal, target) }
            state.directProbe = probe
        end
        if probe.clear then
            if not state.directTravel then clearPath() end
            state.directTravel, state.pathMode = true, mode
            state.pathStatus = "Pathfinding: direct walk"
            issueMove(humanoid, goal, mode, now)
            return
        end
    end
    state.directTravel = false

    local shouldRepath = state.pathBlocked or #state.waypoints == 0 or not state.pathGoal or (goal - state.pathGoal).Magnitude > 2
    if shouldRepath and not state.pathPending and now - state.pathUpdateTime >= CFG.PATH_UPDATE_INTERVAL and (goal - rootPart.Position).Magnitude > CFG.WAYPOINT_REACH_THRESHOLD then
        state.pathUpdateTime = now
        state.pathPending = true
        local generation = state.pathGeneration
        local startPosition = rootPart.Position
        task.spawn(function()
        local recoveryGoal
        local ok, path, waypoints = pcall(function()
            local result, points = createPath(startPosition, goal, mode, now)
            if not result and goal.Y > rootPart.Position.Y + 6 and now - (state.lastTerrainProbe or -math.huge) > 6 then
                state.lastTerrainProbe = now
                result, points, recoveryGoal = findRecoveryPath(rootPart, goal, target)
            end
            return result, points
        end)
        state.pathPending = false
        if not ok then
            warn("[EnemyWalker] path error: " .. tostring(path))
            return
        end
        if state.closed or not state.running or humanoid.Health <= 0 or generation ~= state.pathGeneration
            or player.Character ~= rootPart.Parent or not target.Parent
            or not state.motionGoal or (state.motionGoal - goal).Magnitude > 8 then
            if path then path:Destroy() end
            return
        end
        if path and waypoints then
            clearPath()
            state.terrainRecovery = recoveryGoal
            state.pathObject = path
            state.pathBlocked = false
            state.pathGoal, state.pathMode = recoveryGoal or goal, recoveryGoal and "terrain-recovery" or mode
            if recoveryGoal then state.motionGoal, state.motionGoalMode = recoveryGoal, "terrain-recovery" end
            state.waypoints = waypoints
            state.currentWaypointIndex = 1
            -- Computation can finish after we have walked beyond its start.
            local nearestDistance = math.huge
            for index, waypoint in ipairs(waypoints) do
                local distance = (rootPart.Position - waypoint.Position).Magnitude
                if distance < nearestDistance then
                    nearestDistance = distance
                    state.currentWaypointIndex = index
                end
            end
            state.pathBlockedConn = path.Blocked:Connect(function(blockedIndex)
                if blockedIndex >= state.currentWaypointIndex then state.pathBlocked = true end
            end)
            visualizeWaypoints(waypoints, state.currentWaypointIndex)
            state.pathStatus = (recoveryGoal and "Recovering to higher ground: " or "Pathfinding: ") .. #waypoints .. " waypoints"
        else
            if #state.waypoints > 0 and not state.pathBlocked then return end
            clearPath()
            local fallback = nil
            if (goal - rootPart.Position).Magnitude <= CFG.DIRECT_PATH_DISTANCE and walkingSegmentClear(rootPart, goal, target) then
                fallback = goal
            else
                -- A failed long path still gets a short, collision-checked step.
                -- This keeps the agent moving around a wall while the failed-path
                -- cache prevents repeated identical ComputeAsync calls.
                fallback = chooseFallbackStep(rootPart, goal, target)
            end
            if fallback then
                state.fallbackGoal, state.fallbackUntil = fallback, os.clock() + 1.6
                state.pathStatus = "No full path: local recovery step"
            else
                state.pathStatus = "Pathfinding: blocked, probing alternate step"
            end
            clearWaypointVisuals()
            return
        end
        end)
    end

    local waypoint = state.waypoints[state.currentWaypointIndex]
    -- Path waypoints are grounded positions while HumanoidRootPart is elevated
    -- by the hip height. Compare XZ distance so a small height delta cannot pin
    -- the controller on the first waypoint of a bridge or stair transition.
    while waypoint and (Vector3.new(rootPart.Position.X - waypoint.Position.X, 0, rootPart.Position.Z - waypoint.Position.Z)).Magnitude <= CFG.WAYPOINT_REACH_THRESHOLD do
        state.currentWaypointIndex = state.currentWaypointIndex + 1
        waypoint = state.waypoints[state.currentWaypointIndex]
        updateWaypointHighlight(state.currentWaypointIndex)
    end
    if not waypoint then
        state.terrainRecovery = nil
        if #state.waypoints > 0 then clearPath() end
        if (goal - rootPart.Position).Magnitude <= CFG.DIRECT_PATH_DISTANCE
            and walkingSegmentClear(rootPart, goal, target) then
            issueMove(humanoid, goal, mode, now)
        else
            humanoid:MoveTo(rootPart.Position)
        end
        return
    end
    if hasBlockingRay(rootPart.Position + Vector3.new(0, 2, 0), waypoint.Position + Vector3.new(0, 2, 0), rootPart.Parent, target) then
        -- A path can become stale or can thread a child part that the navmesh
        -- did not include. Reject that segment before MoveTo pins the player
        -- against the wall, then let the short-step fallback route around it.
        state.pathBlocked = true
        clearPath()
        local fallback = chooseFallbackStep(rootPart, goal, target)
        if fallback then
            state.fallbackGoal, state.fallbackUntil = fallback, now + 1.6
            issueMove(humanoid, fallback, mode, now)
        end
        return
    end
    if waypoint.Action == Enum.PathWaypointAction.Jump and humanoid.FloorMaterial ~= Enum.Material.Air then humanoid.Jump = true end
    issueMove(humanoid, waypoint.Position, mode, now)
end

local function chooseRecoveryGoal(rootPart, goal, target)
    local delta = goal - rootPart.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)
    if flat.Magnitude < 0.1 then flat = Vector3.new(1, 0, 0) end
    flat = flat.Unit
    local candidates = {}
    for index = 0, 7 do
        local angle = index * math.pi / 4
        local direction = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), angle):VectorToWorldSpace(flat)
        table.insert(candidates, rootPart.Position + direction * 8)
    end
    for _, candidate in ipairs(candidates) do
        candidate = groundPosition(candidate, rootPart.Parent, target)
        if walkingSegmentClear(rootPart, candidate, target) then return candidate end
    end
    return nil
end

local function updateProgress(humanoid, rootPart, goal, target, now)
    if now - state.lastStuckCheck < CFG.STUCK_CHECK_INTERVAL then return false end
    state.lastStuckCheck = now
    local distance = (goal - rootPart.Position).Magnitude
    local moved = (rootPart.Position - state.lastPosition).Magnitude
    state.lastPosition = rootPart.Position
    if moved >= CFG.STUCK_MOVE_THRESHOLD or distance < state.lastProgressDistance - 0.25 then
        state.stuckCount = 0
        state.stuckStartTime = 0
        state.lastProgressDistance = distance
        state.lastProgressAt = now
        return false
    end
    state.stuckCount = state.stuckCount + 1
    if state.stuckStartTime == 0 then state.stuckStartTime = now end
    if now - state.stuckStartTime < CFG.STUCK_TIMEOUT then return false end

    state.stuckRetries = state.stuckRetries + 1
    state.stuckStartTime = now
    state.stuckCount = 0
    clearPath()
    local recovery = chooseRecoveryGoal(rootPart, goal, target)
    if recovery then
        state.fallbackGoal, state.fallbackUntil = recovery, now + 1.6
        issueMove(humanoid, recovery, "recovery", now)
        state.pathStatus = "Pathfinding: lateral recovery"
    end
    return true
end

local function refreshSafety(rootPart, now)
    if now - state.lastSafetyScan < 0.1 then return end
    state.lastSafetyScan = now
    local zones, enemies = {}, {}
    for _, model in ipairs(state.cachedTargets) do
        if isValidTarget(model) then
            local root = getRootPart(model)
            local distance = (root.Position - rootPart.Position).Magnitude
            if distance < 48 and not hasBlockingRay(rootPart.Position, root.Position, rootPart.Parent, model) then
                local sample = state.enemyMotion[model]
                local velocity = root.AssemblyLinearVelocity
                if sample and now > sample.at then
                    local observed = (root.Position - sample.position) / (now - sample.at)
                    if observed.Magnitude > velocity.Magnitude then velocity = observed end
                end
                velocity = Vector3.new(velocity.X, 0, velocity.Z)
                if velocity.Magnitude > 40 then velocity = velocity.Unit * 40 end
                state.enemyMotion[model] = { at = now, position = root.Position }
                local radius = math.max(math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22), math.min(22, math.max(root.Size.X, root.Size.Z) * 0.5 + 8))
                table.insert(enemies, { model = model, root = root, distance = distance, velocity = velocity, radius = radius })
            end
        end
    end
    state.nearbyEnemies = enemies
    for i = #announcedZones, 1, -1 do
        local zone = announcedZones[i]
        if zone.expires < now then table.remove(announcedZones, i)
        elseif (zone.frame.Position - rootPart.Position).Magnitude <= CFG.THREAT_RADIUS + zone.size.Magnitude then
            table.insert(zones, zone)
        end
    end
    for part, sample in pairs(threatParts) do
        if sample.removedAt then
            if now - sample.removedAt > 0.35 then threatParts[part] = nil
            elseif sample.zone then table.insert(zones, sample.zone) end
        elseif not part.Parent then
            threatParts[part] = nil
        elseif not part:IsDescendantOf(rootPart.Parent)
            and (not state.waypointFolder or not part:IsDescendantOf(state.waypointFolder)) then
            local distance = (part.Position - rootPart.Position).Magnitude
            local model = part:FindFirstAncestorOfClass("Model")
            local playerBody = model and Players:GetPlayerFromCharacter(model)
            if not playerBody and distance < CFG.THREAT_RADIUS + part.Size.Magnitude then
                local name = part:GetFullName():lower()
                local elapsed = math.max(0.001, now - sample.lastAt)
                local velocity = part.AssemblyLinearVelocity
                if velocity.Magnitude < 1 then velocity = (part.Position - sample.lastPosition) / elapsed end
                local projectile = (name:find("projectile") or name:find("missile") or name:find("shot")) and velocity.Magnitude > 1
                local named = part.Transparency < 0.95 and (name:find("hitbox") or name:find("precast") or name:find("telegraph") or name:find("warning") or name:find("danger") or name:find("attack"))
                local attributed = part:GetAttribute("Attack") == true or part:GetAttribute("Hitbox") == true or part:GetAttribute("Damage") ~= nil
                local precast = part.Parent == Workspace and part.Anchored and not part.CanCollide
                    and not part.CanQuery and not part.CanTouch and part.Material == Enum.Material.Neon and part.Size.Magnitude > 3
                if not name:find("safespot") and (projectile or named or attributed or precast) then
                    local shape = projectile and "Projectile" or (part:IsA("Part") and part.Shape == Enum.PartType.Cylinder and "Cylinder" or "Block")
                    sample.zone = { frame = part.CFrame, size = part.Size, shape = shape,
                        velocity = velocity, lookahead = CFG.PROJECTILE_LOOKAHEAD, id = part }
                    sample.lastActive = now
                    table.insert(zones, sample.zone)
                elseif sample.zone and now - (sample.lastActive or 0) < 0.35 then
                    table.insert(zones, sample.zone)
                elseif now - sample.createdAt > CFG.THREAT_MAX_AGE then
                    threatParts[part] = nil
                end
                sample.lastPosition, sample.lastAt = part.Position, now
            elseif now - sample.createdAt > CFG.THREAT_MAX_AGE and not sample.zone then
                threatParts[part] = nil
            end
        end
    end
    state.activeZones = zones
end

local function crowdDistance(position)
    return math.min(28, enemyClearance(position) + math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22))
end

local function findEscapeGoal(rootPart, targetRoot)
    local params = buildRaycastParams(rootPart.Parent, targetRoot.Parent)
    params.RespectCanCollide = true
    local floor = Workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), params)
    if not floor then return nil end
    local best, bestScore = nil, -math.huge
    local originalRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, CFG.HAZARD_MARGIN)
    local originalCrowd = crowdDistance(rootPart.Position)
    local crowdLimit = math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22)
    for _, radius in ipairs({ 14, 8, 3 }) do
        for i = 0, 15 do
            local angle = i * math.pi / 8
            local candidate = rootPart.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            if safeEnemyStep(rootPart.Position, candidate)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN) then
                local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                local crowd = crowdDistance(candidate)
                local hazardClearance = math.huge
                for _, activeZone in ipairs(state.activeZones) do
                    hazardClearance = math.min(hazardClearance, ThreatGeometry.clearance(activeZone, candidate, CFG.HAZARD_MARGIN))
                end
                if (originalRisk == 0 or risk < originalRisk - 0.1)
                    and ((originalCrowd >= crowdLimit and not state.retreating) or crowd > originalCrowd + 0.25) then
                    local targetDistance = (candidate - targetRoot.Position).Magnitude
                    local desiredDistance = CFG.COMBAT_DISTANCE + (state.retreating and CFG.RETREAT_RELEASE_MARGIN or 0)
                    local score = hazardClearance * 20 + math.min(crowd, 28) * 2
                    if originalRisk == 0 then
                        score = score - math.abs(targetDistance - desiredDistance) * 0.1
                    else
                        score = score + radius * 0.5
                    end
                    if score > bestScore and walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor) then
                        best, bestScore = candidate, score
                    end
                end
            end
        end
    end
    return best
end

local function findEmergencySideStep(rootPart, target)
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    for _, radius in ipairs({ 3, 5, 8, 12 }) do
        for index = 0, 15 do
            local angle = index * math.pi / 8
            local candidate = rootPart.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            if ThreatGeometry.risk(state.activeZones, candidate, CFG.PRECAST_MARGIN) == 0
                and safeEnemyStep(rootPart.Position, candidate)
                and walkingSegmentClear(rootPart, candidate, target, params) then
                return candidate
            end
        end
    end
    return nil
end

local function canTeleportDodge(now, distance, threat)
    local history = state.dodgeHistory
    while history[1] and now - history[1].at >= CFG.DODGE_WINDOW do table.remove(history, 1) end
    if not distance or distance < 0.1 or distance > CFG.DODGE_LATERAL_DISTANCE + 0.001 then return false end
    if #history >= CFG.DODGE_MAX_PER_WINDOW then return false end
    if history[#history] and now - history[#history].at < CFG.DODGE_COOLDOWN then return false end
    local previous = state.dodgedThreats[threat]
    if previous and now - previous < CFG.DODGE_SAME_THREAT_COOLDOWN then return false end
    local spent = 0
    for _, entry in ipairs(history) do spent = spent + entry.distance end
    return spent + distance <= CFG.DODGE_DISTANCE_BUDGET + 0.001
end

local function performDodgeTeleport(humanoid, rootPart, destination, target, threat, now)
    if not destination or humanoid.FloorMaterial == Enum.Material.Air then return false end
    local delta = destination - rootPart.Position
    if not canTeleportDodge(now, delta.Magnitude, threat) then return false end
    if not safeEnemyStep(rootPart.Position, destination) then return false end
    if not walkingSegmentClear(rootPart, destination, target) then return false end
    if not ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, destination, CFG.HAZARD_MARGIN) then return false end
    -- Check several body-width rays before applying the bounded horizontal step.
    for _, offset in ipairs({ Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }) do
        if hasBlockingRay(rootPart.Position + offset, destination + offset, rootPart.Parent, target) then return false end
    end
    rootPart.CFrame = rootPart.CFrame + delta
    table.insert(state.dodgeHistory, { at = now, distance = delta.Magnitude })
    state.dodgedThreats[threat] = now
    state.lastDodgeTime = now
    state.safetyUntil = now + 0.75
    state.dodgeCount = state.dodgeCount + 1
    state.dodgeSide = -state.dodgeSide
    clearPath()
    state.motionGoal = nil
    state.fallbackGoal, state.fallbackUntil = nil, 0
    humanoid:MoveTo(destination)
    state.motionMode = "dodge"
    state.lastPosition, state.stuckStartTime = destination, 0
    return true
end

local facingHumanoid, previousAutoRotate, facingRoot, facingAttachment, facingAlignment

local function restoreFacing()
    if facingAlignment then facingAlignment:Destroy(); facingAlignment = nil end
    if facingAttachment then facingAttachment:Destroy(); facingAttachment = nil end
    facingRoot = nil
    if facingHumanoid then
        facingHumanoid.AutoRotate = previousAutoRotate
        facingHumanoid = nil
        previousAutoRotate = nil
    end
end

local function faceEnemy(humanoid, rootPart, targetRoot)
    if CFG.SMART_FARM and state.castAimTarget and os.clock() < (state.castAimUntil or 0) and isValidTarget(state.castAimTarget) then
        targetRoot = getRootPart(state.castAimTarget)
    end
    if facingHumanoid ~= humanoid or facingRoot ~= rootPart then
        restoreFacing()
        facingHumanoid, previousAutoRotate = humanoid, humanoid.AutoRotate
        facingRoot = rootPart
        facingAttachment = Instance.new("Attachment")
        facingAttachment.Name = "ObsidianFacingAttachment"
        facingAttachment.Parent = rootPart
        facingAlignment = Instance.new("AlignOrientation")
        facingAlignment.Name = "ObsidianFacing"
        facingAlignment.Mode = Enum.OrientationAlignmentMode.OneAttachment
        facingAlignment.Attachment0 = facingAttachment
        facingAlignment.MaxTorque = 1000000
        facingAlignment.MaxAngularVelocity = 30
        facingAlignment.Responsiveness = 100
        facingAlignment.Parent = rootPart
    end
    humanoid.AutoRotate = false
    local position = rootPart.Position
    local lookAt = Vector3.new(targetRoot.Position.X, position.Y, targetRoot.Position.Z)
    if (lookAt - position).Magnitude > 0.01 then
        -- Writing the root CFrame cancels Humanoid.MoveTo. Rotate through physics
        -- so facing the target never interrupts the current walking command.
        facingAlignment.CFrame = CFrame.new(Vector3.zero, lookAt - position)
    end
end

local function spellUsable(snapshot, rootPart)
    local profile = FarmPlanner.profile(snapshot)
    local humanoid = rootPart.Parent:FindFirstChildOfClass("Humanoid")
    if profile.mode == "heal" then return humanoid and humanoid.Health < humanoid.MaxHealth * 0.85 end
    if profile.mode == "shield" then return state.retreating or #state.activeZones > 0 end
    if profile.mode == "buff" then return #state.nearbyEnemies > 0 end
    if profile.mode == "self" then
        for _, enemy in ipairs(state.nearbyEnemies) do
            if isValidTarget(enemy.model) and (enemy.root.Position - rootPart.Position).Magnitude <= (profile.radius or profile.range or CFG.CLOSE_AOE_RANGE) then
                return true
            end
        end
        return false
    end
    if state.targetDist > (profile.range or CFG.SPELL_RANGE_OVERRIDE > 0 and CFG.SPELL_RANGE_OVERRIDE or CFG.ATTACK_RANGE) then return false end
    return true
end

local function prepareSpell(_, snapshot)
    if not CFG.SMART_FARM then return true end
    local character, humanoid, rootPart = getChar()
    if not character or not humanoid or not rootPart then return false end
    if not spellUsable(snapshot, rootPart) then return false end
    local profile = FarmPlanner.profile(snapshot)
    if profile.mode == "target" and state.targetDist > (profile.range or CFG.SPELL_RANGE_OVERRIDE > 0 and CFG.SPELL_RANGE_OVERRIDE or CFG.ATTACK_RANGE) then return false end
    if profile.mode ~= "splash" then return true end
    local range, radius = profile.range or CFG.ATTACK_RANGE, profile.radius or CFG.GROUP_RADIUS
    local now = os.clock()
    local plan = state.farmPlan
    if not plan or plan.spell ~= snapshot.name or plan.range ~= range or plan.radius ~= radius
        or now - plan.at >= 0.2 or not isValidTarget(plan.target) then
        local candidates = {}
        for _, model in ipairs(state.cachedTargets) do
            if isValidTarget(model) then
                local root = getRootPart(model)
                local distance = (root.Position - rootPart.Position).Magnitude
                if distance <= range then
                    table.insert(candidates, { model = model, position = root.Position, distance = distance })
                end
            end
        end
        table.sort(candidates, function(a, b) return a.distance < b.distance end)
        local visible = {}
        for _, candidate in ipairs(candidates) do
            if #visible >= 16 then break end
            if not hasBlockingRay(rootPart.Position, candidate.position, character, candidate.model) then table.insert(visible, candidate) end
        end
        local visibilityCache = {}
        local best, count = FarmPlanner.select(visible, radius, function(a, b)
            local cached = visibilityCache[a.model]
            if cached and cached[b.model] ~= nil then return cached[b.model] end
            local clear = not hasBlockingRay(a.position, b.position, character, a.model)
            visibilityCache[a.model], visibilityCache[b.model] = visibilityCache[a.model] or {}, visibilityCache[b.model] or {}
            visibilityCache[a.model][b.model], visibilityCache[b.model][a.model] = clear, clear
            return clear
        end)
        plan = { at = now, target = best and best.model, count = count, spell = snapshot.name, range = range, radius = radius }
        state.farmPlan = plan
    end
    local target = plan.target
    if not isValidTarget(target) then return false end
    local targetRoot = getRootPart(target)
    if (targetRoot.Position - rootPart.Position).Magnitude > range
        or hasBlockingRay(rootPart.Position, targetRoot.Position, character, target) then return false end
    state.castAimTarget, state.castAimUntil, state.groupCount = target, now + 0.35, plan.count
    faceEnemy(humanoid, rootPart, targetRoot)
    local delta = targetRoot.Position - rootPart.Position
    delta = Vector3.new(delta.X, 0, delta.Z)
    return delta.Magnitude < 0.1 or rootPart.CFrame.LookVector:Dot(delta.Unit) >= 0.9985
end

local function castSkill()
    if not CFG.AUTO_ABILITIES then return end
    local now = os.clock()
    if CFG.AUTO_DODGE and (#state.activeZones > 0 or state.motionMode == "evade"
        or state.motionMode == "safety-hold" or state.motionMode == "hazard-escape") then return end
    if abilities.TryCast(now, CFG.SKILL_COOLDOWN, prepareSpell) then state.lastSkillTime = now end
end

local function stopMovement(humanoid, rootPart)
    if state.motionMode == "hold" and not state.motionGoal then return end
    humanoid:MoveTo(rootPart.Position)
    state.motionMode = "hold"
    state.motionGoal = nil
    state.fallbackGoal, state.fallbackUntil = nil, 0
    clearPath()
end

local function meleeThreat(rootPart)
    local threat, closest = nil, math.huge
    for _, enemy in ipairs(state.nearbyEnemies) do
        if enemy.root.Parent then
            local distance = (enemy.root.Position - rootPart.Position).Magnitude
            local offset = rootPart.Position - enemy.root.Position
            local closing = offset.Magnitude > 0.01 and enemy.velocity:Dot(offset.Unit) or 0
            local limit = math.max(CFG.MELEE_DANGER_DISTANCE, math.min(18, math.max(enemy.root.Size.X, enemy.root.Size.Z) * 0.5 + 6))
            if distance < closest and (distance <= limit or distance - math.max(0, closing) * 0.25 <= limit) then
                threat, closest = enemy.model, distance
            end
        end
    end
    return threat
end

local function dodgeAlongEscape(humanoid, rootPart, goal, target, threat, now)
    if not threat then return end
    local delta = goal - rootPart.Position
    if delta.Magnitude < 0.5 then return end
    local step = rootPart.Position + delta.Unit * math.min(CFG.DODGE_LATERAL_DISTANCE, delta.Magnitude)
    if enemyClearance(step) <= enemyClearance(rootPart.Position) and typeof(threat) == "Instance" and threat:IsA("Model") then return end
    performDodgeTeleport(humanoid, rootPart, step, target, threat, now)
end

local function forceSeparationGoal(rootPart, targetRoot, target)
    local away = Vector3.new(rootPart.Position.X - targetRoot.Position.X, 0, rootPart.Position.Z - targetRoot.Position.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) else away = away.Unit end
    local params = buildRaycastParams(rootPart.Parent, target)
    for _, distance in ipairs({ 3, 6, 10, 14 }) do
        local candidate = groundPosition(rootPart.Position + away * distance, rootPart.Parent, target)
        if walkingSegmentClear(rootPart, candidate, target, params)
            and safeEnemyStep(rootPart.Position, candidate)
            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN) then
            return candidate
        end
    end
    return nil
end

local function handleSafety(humanoid, rootPart, target, targetRoot, now)
    if not CFG.AUTO_DODGE then
        state.escapeGoal, state.lastThreatPart, state.movementBlocked, state.retreating = nil, nil, false, false
        return false
    end
    local risk, zone = ThreatGeometry.risk(state.activeZones, rootPart.Position, CFG.HAZARD_MARGIN)
    state.lastThreatPart = zone and zone.id
    local crowd = crowdDistance(rootPart.Position)
    local crowdLimit = math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22)
    local clearance = enemyClearance(rootPart.Position)
    if clearance < 0 then state.retreating = true
    elseif clearance >= CFG.RETREAT_RELEASE_MARGIN then state.retreating = false end
    local contactThreat = meleeThreat(rootPart)
    if contactThreat and (contactThreat == target or (targetRoot.Position - rootPart.Position).Magnitude <= CFG.MELEE_DANGER_DISTANCE) then
        local separation = forceSeparationGoal(rootPart, targetRoot, target)
        state.retreating = true
        if separation then
            clearPath()
            state.escapeGoal, state.escapeUntil = separation, now + 1.25
            state.escapeClear, state.lastEscapeCheck = true, now
            state.escapeReason = "Breaking melee contact"
            state.status = state.escapeReason
            dodgeAlongEscape(humanoid, rootPart, separation, target, contactThreat, now)
            issueMove(humanoid, separation, "evade", now)
            return true
        end
        state.status = "Breaking melee contact"
        humanoid:MoveTo(rootPart.Position)
        return true
    end
    if state.blockedByHazard then
        state.escapeGoal = nil
        state.lastEscapePlan = -math.huge
    end
    if state.escapeGoal and now < (state.escapeUntil or 0) then
        if now - (state.lastEscapeCheck or 0) >= 0.2 then
            state.escapeClear = walkingSegmentClear(rootPart, state.escapeGoal, target)
            state.lastEscapeCheck = now
        end
        if (state.escapeGoal - rootPart.Position).Magnitude > math.max(3, humanoid.WalkSpeed * 0.25)
            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, state.escapeGoal, CFG.HAZARD_MARGIN)
            and safeEnemyStep(rootPart.Position, state.escapeGoal)
            and state.escapeClear
            and (crowd >= crowdLimit or crowdDistance(state.escapeGoal) > crowd) then
            state.status = state.escapeReason or "Avoiding nearby enemies"
            dodgeAlongEscape(humanoid, rootPart, state.escapeGoal, target, zone and zone.id or contactThreat, now)
            issueMove(humanoid, state.escapeGoal, "evade", now)
            return true
        end
    end
    state.escapeGoal = nil
    if risk == 0 and not state.retreating and not contactThreat and crowd >= crowdLimit
        and not state.movementBlocked and not state.blockedByHazard then
        if now < state.safetyUntil then
            state.status = "Holding safe position"
            stopMovement(humanoid, rootPart)
            return true
        end
        return false
    end
    if zone then
        state.observedThreats[zone.id] = state.observedThreats[zone.id] or now
        if now - state.observedThreats[zone.id] < CFG.REACTION_TIME then
            stopMovement(humanoid, rootPart)
            state.status = "Reacting to attack"
            return true
        end
    end
    if now - state.lastEscapePlan < 0.05 then return true end
    state.lastEscapePlan = now
    local goal = findEscapeGoal(rootPart, targetRoot)
    if not goal and (risk > 0 or state.blockedByHazard) then
        goal = findEmergencySideStep(rootPart, target)
    end
    state.movementBlocked, state.blockedByHazard = false, false
    if not goal then
        state.blockedByHazard = false
        state.status = "Waiting for safe escape route"
        stopMovement(humanoid, rootPart)
        return true
    end
    clearPath()
    state.motionGoal, state.fallbackGoal = nil, nil
    state.escapeGoal, state.escapeUntil = goal, now + 1.5
    state.escapeClear, state.lastEscapeCheck = true, now
    state.safetyUntil = now + 0.75
    dodgeAlongEscape(humanoid, rootPart, goal, target, zone and zone.id or contactThreat, now)
    state.escapeReason = zone and "Escaping attack area" or "Avoiding nearby enemies"
    state.status = state.escapeReason
    issueMove(humanoid, goal, "evade", now)
    return true
end

local function controllerTick()
    if not state.running or state.closed then return end
    local character, humanoid, rootPart = getChar()
    if not character or not humanoid or not rootPart then state.status = "No character"; return end
    if humanoid.Health <= 0 then
        state.status = "Dead"
        if state.motionMode ~= "dead" then clearPath(); state.motionMode = "dead" end
        return
    end

    local now = os.clock()
    if CFG.SMART_FARM then
        local snapshots = abilities.Snapshot(now)
        for _, snapshot in pairs(snapshots) do
            local profile = FarmPlanner.profile(snapshot)
            if profile.range and (profile.mode == "target" or profile.mode == "splash") then
                CFG.ATTACK_RANGE = math.max(CFG.ATTACK_RANGE, profile.range)
            end
        end
        for _, snapshot in pairs(snapshots) do
            local profile = FarmPlanner.profile(snapshot)
            if profile.mode == "heal" or profile.mode == "shield" or profile.mode == "buff" then
                abilities.TryCast(now, CFG.SKILL_COOLDOWN, function(slot, candidate)
                    local candidateProfile = FarmPlanner.profile(candidate)
                    return (candidateProfile.mode == "heal" or candidateProfile.mode == "shield" or candidateProfile.mode == "buff")
                        and prepareSpell(slot, candidate)
                end)
                break
            end
        end
    end
    for model, health in pairs(state.prevHealth) do
        local trackedHumanoid = model:FindFirstChildOfClass("Humanoid")
        if trackedHumanoid and health > 0 and trackedHumanoid.Health <= 0 then
            state.kills = state.kills + 1
        end
        if not trackedHumanoid or trackedHumanoid.Health <= 0 or not model:IsDescendantOf(Workspace) then
            state.prevHealth[model] = nil
        else
            state.prevHealth[model] = trackedHumanoid.Health
        end
    end
    if state.lastPlayerHealth and humanoid.Health < state.lastPlayerHealth - 0.01 then
        state.damageEvents = state.damageEvents + 1
        state.lastDamage = { amount = state.lastPlayerHealth - humanoid.Health, at = now }
        warn(string.format("[EnemyWalker] damage event #%d (%.0f -> %.0f)", state.damageEvents, state.lastPlayerHealth, humanoid.Health))
    end
    state.lastPlayerHealth = humanoid.Health
    local target, distance = getClosestEnemy(rootPart, now)
    if not target then
        state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
        state.retreating = false
        state.escapeGoal, state.lastThreatPart = nil, nil
        state.status, state.targetName, state.targetDist = "Waiting for wave", "None", 0
        state.currentTarget, state.lockedTarget = nil, nil
        stopMovement(humanoid, rootPart)
        state.pathStatus = "Pathfinding: waiting for next wave"
        return
    end

    local targetHumanoid, targetRoot = target:FindFirstChildOfClass("Humanoid"), getRootPart(target)
    if not targetHumanoid or targetHumanoid.Health <= 0 or not targetRoot then
        state.lockedTarget = nil
        return
    end
    if state.currentTarget ~= target then
        local previousRoot = state.currentTarget and getRootPart(state.currentTarget)
        if not previousRoot or (previousRoot.Position - targetRoot.Position).Magnitude > 4 then
            clearPath()
            state.motionGoal, state.fallbackGoal = nil, nil
            state.pathUpdateTime = 0
        end
        state.lastProgressDistance, state.stuckStartTime = math.huge, 0
    end
    state.currentTarget, state.targetName, state.targetDist = target, target.Name, distance
    state.prevHealth[target] = targetHumanoid.Health
    refreshSafety(rootPart, now)
    if handleSafety(humanoid, rootPart, target, targetRoot, now) then
        state.navigationPhase = "evade"
        faceEnemy(humanoid, rootPart, targetRoot)
        if distance <= CFG.ATTACK_RANGE and not hasBlockingRay(rootPart.Position, targetRoot.Position, character, target) then castSkill() end
        return
    end

    -- A combat-distance point on this side of a wall is not an attack position.
    -- Route to the enemy's reachable area before holding distance or casting.
    if hasBlockingRay(rootPart.Position, targetRoot.Position, character, target) then
        state.navigationPhase = "approach"
        state.lastThreatPart, state.dodgeGoal = nil, nil
        restoreFacing()
        state.status = "Routing around obstacle to " .. target.Name
        followGoal(humanoid, rootPart, targetRoot.Position, "approach", now, target)
        updateProgress(humanoid, rootPart, targetRoot.Position, target, now)
        return
    end
    state.navigationPhase = "combat"
    faceEnemy(humanoid, rootPart, targetRoot)

    if CFG.SMART_FARM and CFG.AUTO_ABILITIES and distance >= CFG.COMBAT_MIN_DISTANCE
        and distance <= CFG.ATTACK_RANGE + 5 and FarmPlanner.coolingDown(abilities.Snapshot(now), function(snapshot)
            return spellUsable(snapshot, rootPart)
        end) then
        state.status = "Holding range during cooldown"
        stopMovement(humanoid, rootPart)
        return
    end

    if CFG.FARM_POSITION == "Nearest" and distance >= CFG.COMBAT_MIN_DISTANCE and distance <= CFG.COMBAT_MAX_DISTANCE then
        state.status = "Attacking " .. target.Name
        stopMovement(humanoid, rootPart)
        castSkill()
        return
    end

    local offset = rootPart.Position - targetRoot.Position
    local flat = Vector3.new(offset.X, 0, offset.Z)
    if CFG.FARM_POSITION == "Behind" then flat = -targetRoot.CFrame.LookVector
    elseif CFG.FARM_POSITION == "Front" then flat = targetRoot.CFrame.LookVector
    elseif CFG.FARM_POSITION == "Left" then flat = -targetRoot.CFrame.RightVector
    elseif CFG.FARM_POSITION == "Right" then flat = targetRoot.CFrame.RightVector end
    flat = Vector3.new(flat.X, 0, flat.Z)
    if flat.Magnitude < 0.1 then flat = Vector3.new(1, 0, 0) end
    local desiredPosition = groundPosition(targetRoot.Position + flat.Unit * CFG.COMBAT_DISTANCE, character, target)
    if (Vector3.new(desiredPosition.X - rootPart.Position.X, 0, desiredPosition.Z - rootPart.Position.Z)).Magnitude < 2 then
        stopMovement(humanoid, rootPart)
        if distance <= CFG.ATTACK_RANGE then castSkill() end
        return
    end
    state.status = distance > CFG.COMBAT_MAX_DISTANCE and "Moving to " .. target.Name or "Creating space from " .. target.Name
    followGoal(humanoid, rootPart, desiredPosition, "combat", now, target)
    updateProgress(humanoid, rootPart, desiredPosition, target, now)
    if distance <= CFG.ATTACK_RANGE then castSkill() end
end

connect(RunService.RenderStepped, function()
    local target = state.currentTarget
    if not state.running or state.closed or state.navigationPhase == "approach"
        or not isValidTarget(target) or not target:IsDescendantOf(Workspace) then
        restoreFacing()
        return
    end
    local _, humanoid, rootPart = getChar()
    if not humanoid or not rootPart or humanoid.Health <= 0 then
        restoreFacing()
        return
    end
    faceEnemy(humanoid, rootPart, getRootPart(target))
end)

local lastControl, lastError = 0, 0
connect(RunService.Heartbeat, function()
    local now = os.clock()
    if now - lastControl < CFG.CONTROL_INTERVAL then return end
    lastControl = now
    if not state.running or state.closed or state.updateBusy then return end
    state.updateBusy = true
    local ok, err = pcall(controllerTick)
    state.updateBusy = false
    if not ok and now - lastError >= 2 then
        lastError = now
        warn("[EnemyWalker] controller error: " .. tostring(err))
    end
end)

local function setRunning(running)
    if state.closed or state.running == running then return end
    state.running = running
    if state.running then
        state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
        state.retreating = false
        state.escapeGoal, state.escapeUntil, state.safetyUntil = nil, 0, 0
        state.movementBlocked, state.lastSafetyScan, state.lastEscapePlan = false, -math.huge, -math.huge
        state.skillQ_count, state.skillE_count, state.kills, state.stuckRetries = 0, 0, 0, 0
        state.skillToggle, state.lastSkillTime = false, 0
        state.lockedTarget, state.currentTarget = nil, nil
        state.cachedTargets, state.prevHealth = {}, setmetatable({}, { __mode = "k" })
        state.lastTargetScan, state.lastTargetChoice = 0, 0
        state.lastDodgeTime, state.dodgeGoal = 0, nil
        state.motionGoal, state.motionGoalMode, state.motionMode = nil, nil, "idle"
        state.fallbackGoal, state.fallbackUntil = nil, 0
        state.stuckStartTime, state.stuckCount, state.pathUpdateTime = 0, 0, 0
        state.lastDodgeThreat, state.lastDodgeThreatAt = nil, 0
        state.dodgeCount, state.damageEvents, state.lastPlayerHealth = 0, 0, nil
        createWaypointFolder()
        state.pathStatus = "Pathfinding: active"
    else
        state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
        restoreFacing()
        local _, humanoid, rootPart = getChar()
        if humanoid and rootPart then stopMovement(humanoid, rootPart) end
        state.status, state.targetName, state.targetDist = "Idle", "Scanning...", 0
        state.lockedTarget, state.currentTarget = nil, nil
        clearPath()
        state.pathStatus = "Pathfinding: stopped"
    end
end

local function shutdown()
    if state.closed then return end
    state.closed, state.running = true, false
    restoreFacing()
    local _, humanoid, rootPart = getChar()
    if humanoid and rootPart then stopMovement(humanoid, rootPart) end
    clearPath()
    if state.waypointFolder then state.waypointFolder:Destroy() end
    for _, connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
    table.clear(threatParts)
    table.clear(humanoidModels)
    table.clear(announcedZones)
end

connect(player.CharacterAdded, function()
    state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
    state.retreating = false
    state.escapeGoal, state.escapeUntil, state.safetyUntil = nil, 0, 0
    state.movementBlocked, state.lastSafetyScan = false, -math.huge
    restoreFacing()
    state.lockedTarget, state.currentTarget = nil, nil
    state.cachedTargets, state.prevHealth = {}, setmetatable({}, { __mode = "k" })
    state.motionGoal, state.motionGoalMode, state.motionMode = nil, nil, "idle"
    state.fallbackGoal, state.fallbackUntil = nil, 0
    state.lastPlayerHealth, state.lastTargetScan = nil, 0
    state.pathUpdateTime = 0
    state.stuckStartTime, state.stuckCount = 0, 0
    state.dodgeGoal = nil
    state.lastDodgeThreat, state.lastDodgeThreatAt = nil, 0
    clearPath()
end)

print("[EnemyWalker] loaded: indexed targets, asynchronous paths, bounded teleport dodges")

return {
    Config = CFG,
    State = state,
    SetRunning = setRunning,
    Shutdown = shutdown,
    AbilityStatus = function() return abilities.Snapshot(os.clock()) end,
    SetAbilityInventory = abilities.SetInventory,
    AbilityProfile = FarmPlanner.profile,
    SetWaypoints = function(enabled)
        CFG.SHOW_WAYPOINTS = enabled
        if enabled then visualizeWaypoints(state.waypoints, state.currentWaypointIndex) else clearWaypointVisuals() end
    end,
}
