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
    SKILL_COOLDOWN = 1.5,
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
    STUCK_TIMEOUT = 1.4,
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
    THREAT_MAX_AGE = 2,
    AUTO_ABILITIES = true,
    AUTO_DODGE = true,
    REACTION_TIME = 0.05,
    FARM_POSITION = "Nearest",

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
}

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
    threatParts[instance] = nil
    humanoidModels[instance] = nil
end)
for _, instance in ipairs(Workspace:GetDescendants()) do trackInstance(instance) end

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

local function getClosestEnemy(rootPart, now)
    refreshTargets(rootPart, now)
    if isValidTarget(state.lockedTarget) then
        local root = getRootPart(state.lockedTarget)
        local distance = (rootPart.Position - root.Position).Magnitude
        if distance <= CFG.DETECTION_RADIUS and state.lockedTarget:IsDescendantOf(Workspace) then
            return state.lockedTarget, distance
        end
    end
    state.lockedTarget = nil
    local closest, closestDistance
    for _, model in ipairs(state.cachedTargets) do
        if isValidTarget(model) then
            local root = getRootPart(model)
            local distance = (rootPart.Position - root.Position).Magnitude
            if not closestDistance or distance < closestDistance then
                closest, closestDistance = model, distance
            end
        end
    end
    state.lockedTarget = closest
    return closest, closestDistance or CFG.DETECTION_RADIUS
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

local function hasBlockingRay(origin, destination, character, target)
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

local function pathKey(startPosition, endPosition, mode)
    local function quantize(value) return math.floor(value / 4 + 0.5) end
    return string.format("%s:%d,%d,%d>%d,%d,%d", mode or "combat", quantize(startPosition.X), quantize(startPosition.Y), quantize(startPosition.Z), quantize(endPosition.X), quantize(endPosition.Y), quantize(endPosition.Z))
end

local function clearPath()
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

local function issueMove(humanoid, position, mode, now)
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
    for _, direction in ipairs(directions) do
        local candidate = groundPosition(rootPart.Position + direction * 8, rootPart.Parent, target)
        if not hasBlockingRay(rootPart.Position + Vector3.new(0, 2, 0), candidate + Vector3.new(0, 2, 0), rootPart.Parent, target) then
            return candidate
        end
    end
    return nil
end

local function followGoal(humanoid, rootPart, goal, mode, now, target)
    if not goal then return end
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

    local shouldRepath = state.pathBlocked or #state.waypoints == 0 or not state.pathGoal or (goal - state.pathGoal).Magnitude > 2
    if shouldRepath and not state.pathPending and now - state.pathUpdateTime >= CFG.PATH_UPDATE_INTERVAL and (goal - rootPart.Position).Magnitude > CFG.WAYPOINT_REACH_THRESHOLD then
        state.pathUpdateTime = now
        state.pathPending = true
        local generation = state.pathGeneration
        local startPosition = rootPart.Position
        task.spawn(function()
        local ok, path, waypoints = pcall(createPath, startPosition, goal, mode, now)
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
            state.pathObject = path
            state.pathBlocked = false
            state.pathGoal, state.pathMode = goal, mode
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
            state.pathStatus = "Pathfinding: " .. #waypoints .. " waypoints"
        else
            if #state.waypoints > 0 and not state.pathBlocked then return end
            clearPath()
            local fallback = nil
            if not hasBlockingRay(rootPart.Position + Vector3.new(0, 2, 0), goal + Vector3.new(0, 2, 0), rootPart.Parent, target) then
                fallback = goal
            else
                -- A failed long path still gets a short, collision-checked step.
                -- This keeps the agent moving around a wall while the failed-path
                -- cache prevents repeated identical ComputeAsync calls.
                fallback = chooseFallbackStep(rootPart, goal, target)
            end
            if fallback then
                state.fallbackGoal, state.fallbackUntil = fallback, os.clock() + 1.6
                state.pathStatus = "Pathfinding: direct clear route"
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
        if #state.waypoints > 0 then clearPath() end
        if (goal - rootPart.Position).Magnitude <= CFG.DIRECT_PATH_DISTANCE
            and not hasBlockingRay(rootPart.Position, goal, rootPart.Parent, target) then
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
        if not hasBlockingRay(rootPart.Position + Vector3.new(0, 2, 0), candidate + Vector3.new(0, 2, 0), rootPart.Parent, target) then return candidate end
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

local function findThreat(rootPart, target, now)
    local character = rootPart.Parent
    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    local overlapIgnore = { character }
    if state.waypointFolder then table.insert(overlapIgnore, state.waypointFolder) end
    overlapParams.FilterDescendantsInstances = overlapIgnore
    local nearbyParts = {}
    if now - state.lastThreatScan >= CFG.THREAT_SCAN_INTERVAL then
    state.lastThreatScan = now
    pcall(function()
        nearbyParts = Workspace:GetPartBoundsInRadius(rootPart.Position, CFG.THREAT_RADIUS, overlapParams)
    end)
    -- DescendantAdded catches new projectiles; the overlap pass also catches
    -- telegraphs that existed before this LocalScript was injected.
    for _, part in ipairs(nearbyParts) do
        if part:IsA("BasePart") and not part.CanCollide and not threatParts[part] then
            threatParts[part] = { createdAt = now, lastPosition = part.Position, lastAt = now }
        end
    end
    end
    for part, sample in pairs(threatParts) do
        if not part.Parent or now - sample.createdAt > CFG.THREAT_MAX_AGE then
            threatParts[part] = nil
        elseif not part:IsDescendantOf(character) and (not target or not part:IsDescendantOf(target)) and (not state.waypointFolder or not part:IsDescendantOf(state.waypointFolder)) then
            local distance = (part.Position - rootPart.Position).Magnitude
            if distance <= CFG.THREAT_RADIUS then
                local name = part.Name:lower()
                local parentName = part.Parent and part.Parent.Name:lower() or ""
                local model = part:FindFirstAncestorOfClass("Model")
                local modelName = model and model.Name:lower() or ""
                local halfSize = part.Size * 0.5
                local localPosition = part.CFrame:PointToObjectSpace(rootPart.Position)
                local shape = part:IsA("Part") and part.Shape or nil
                local hitboxRelevant
                if shape == Enum.PartType.Cylinder then
                    -- PrecastHitbox rotates cylinders to match terrain, so use
                    -- a conservative sphere around the two largest dimensions
                    -- instead of assuming the cylinder axis is world Y.
                    local radius = math.max(halfSize.X, halfSize.Y, halfSize.Z) + CFG.PRECAST_MARGIN
                    hitboxRelevant = localPosition.Magnitude <= radius
                else
                    hitboxRelevant = math.abs(localPosition.X) <= halfSize.X + CFG.PRECAST_MARGIN and math.abs(localPosition.Y) <= halfSize.Y + CFG.PRECAST_MARGIN and math.abs(localPosition.Z) <= halfSize.Z + CFG.PRECAST_MARGIN
                end
                local visible = part.Transparency < 0.9
                local named = name:find("attack") or name:find("hitbox") or name:find("projectile") or name:find("danger") or name:find("warning") or name:find("telegraph") or name:find("precast")
                local namedThreat = named and visible and hitboxRelevant
                local tagged = parentName:find("attack") or parentName:find("hitbox") or parentName:find("projectile") or parentName:find("precast")
                local taggedThreat = tagged and visible and hitboxRelevant
                local attributesThreat = (part:GetAttribute("Attack") == true or part:GetAttribute("Damage") ~= nil or part:GetAttribute("Hitbox") == true) and hitboxRelevant
                -- PrecastHitbox uses generic, non-queryable Parts. Restrict
                -- them to large transient geometry close to the locked mob;
                -- this filters player skill VFX and map lighting.
                local color = part.Color
                local redPrecast = part.Material == Enum.Material.Neon and not part.CanCollide and not part.CanQuery and visible and hitboxRelevant and part.Size.Magnitude > 5 and color.R > color.G * 1.35 and color.R > color.B * 1.2 and target and (part.Position - getRootPart(target).Position).Magnitude < 30
                local genericPrecast = part.Parent == Workspace and not part.CanCollide and not part.CanQuery and visible and hitboxRelevant and part.Size.Magnitude > 3 and target and (part.Position - getRootPart(target).Position).Magnitude < 40 and now - sample.createdAt > 0.12 and now - state.lastSkillTime > 0.35
                -- Canal projectile hitboxes are intentionally invisible. Infer
                -- motion from AssemblyLinearVelocity or two observed samples,
                -- and dodge when their trajectory points at the player.
                local projectileModel = modelName:find("shot") or modelName:find("projectile") or modelName:find("missile") or modelName:find("orb") or parentName:find("shot") or parentName:find("projectile")
                local previousPosition = sample.lastPosition
                local elapsed = math.max(now - sample.lastAt, 1 / 60)
                local displacement = part.Position - previousPosition
                local observedVelocity = displacement / elapsed
                sample.lastPosition, sample.lastAt = part.Position, now
                local velocity = part.AssemblyLinearVelocity
                if velocity.Magnitude < 1 then velocity = observedVelocity end
                local toPlayer = rootPart.Position - part.Position
                local heading = velocity.Magnitude > 1 and toPlayer.Magnitude > 0.001 and velocity.Unit:Dot(toPlayer.Unit) or 0
                local timeToPlayer = velocity.Magnitude > 1 and toPlayer.Magnitude / velocity.Magnitude or math.huge
                local sweptPoint = previousPosition
                if displacement:Dot(displacement) > 0 then
                    local fraction = math.clamp((rootPart.Position - previousPosition):Dot(displacement) / displacement:Dot(displacement), 0, 1)
                    sweptPoint = previousPosition + displacement * fraction
                end
                local sweptThreat = (rootPart.Position - sweptPoint).Magnitude <= 8
                local projectileThreat = projectileModel and (distance < 8 or sweptThreat or (heading > 0.08 and timeToPlayer <= CFG.PROJECTILE_LOOKAHEAD))
                if namedThreat or taggedThreat or attributesThreat or redPrecast or genericPrecast or projectileThreat then
                    return part
                end
            end
        end
    end
    return nil
end

local function findDodgeGoal(rootPart, targetRoot, threat)
    local away = rootPart.Position - targetRoot.Position
    if threat then away = rootPart.Position - threat.Position end
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
    away = away.Unit
    local right = Vector3.new(-away.Z, 0, away.X)
    local left = -right
    local firstSide, secondSide = right, left
    if state.dodgeSide < 0 then firstSide, secondSide = left, right end
    local currentGround = Workspace:Raycast(rootPart.Position, Vector3.new(0, -8, 0), buildRaycastParams(rootPart.Parent, targetRoot.Parent))
    if not currentGround then return nil end

    local function usable(candidate, minimumTargetDistance)
        local ground = Workspace:Raycast(candidate + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), buildRaycastParams(rootPart.Parent, targetRoot.Parent))
        if not ground or not ground.Instance.CanCollide then return nil end
        if math.abs(ground.Position.Y - currentGround.Position.Y) > 1.5 then return nil end
        candidate = Vector3.new(candidate.X, rootPart.Position.Y, candidate.Z)
        if (candidate - rootPart.Position).Magnitude > CFG.DODGE_LATERAL_DISTANCE + 0.001 then return nil end
        local targetDistance = (candidate - targetRoot.Position).Magnitude
        if targetDistance < (minimumTargetDistance or CFG.COMBAT_MIN_DISTANCE - 1) then return nil end
        if hasBlockingRay(rootPart.Position + Vector3.new(0, 2, 0), candidate + Vector3.new(0, 2, 0), rootPart.Parent, targetRoot.Parent) then return nil end
        return candidate
    end

    -- A dodge is a strafe: try alternating right/left steps before any
    -- forward or backward displacement. This breaks wall/bridge soft-locks
    -- while preserving enough distance from the target to keep fighting.
    local lateralDistance = CFG.DODGE_LATERAL_DISTANCE
    for _, side in ipairs({ firstSide, secondSide }) do
        local lateral = usable(rootPart.Position + side * lateralDistance)
        if lateral then return lateral end
    end

    -- If one side is partially blocked, use a diagonal strafe around it.
    for _, side in ipairs({ firstSide, secondSide }) do
        for _, forwardSign in ipairs({ 1, -1 }) do
            local diagonal = (side + away * forwardSign).Unit
            local candidate = usable(rootPart.Position + diagonal * lateralDistance)
            if candidate then return candidate end
        end
    end

    return usable(rootPart.Position + away * lateralDistance, 0)
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
    -- Check several body-width rays before applying the bounded horizontal step.
    for _, offset in ipairs({ Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }) do
        if hasBlockingRay(rootPart.Position + offset, destination + offset, rootPart.Parent, target) then return false end
    end
    rootPart.CFrame = rootPart.CFrame + delta
    table.insert(state.dodgeHistory, { at = now, distance = delta.Magnitude })
    state.dodgedThreats[threat] = now
    state.lastDodgeTime = now
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

local function castSkill()
    if not CFG.AUTO_ABILITIES then return end
    local now = os.clock()
    if now - state.lastSkillTime < CFG.SKILL_COOLDOWN then return end
    state.lastSkillTime = now
    local key = state.skillToggle and Enum.KeyCode.Q or Enum.KeyCode.E
    local ok = pcall(function()
        local virtualInput = game:GetService("VirtualInputManager")
        virtualInput:SendKeyEvent(true, key, false, game)
        task.delay(0.05, function()
            pcall(function() virtualInput:SendKeyEvent(false, key, false, game) end)
        end)
    end)
    if ok then
        if state.skillToggle then state.skillQ_count = state.skillQ_count + 1 else state.skillE_count = state.skillE_count + 1 end
    end
    state.skillToggle = not state.skillToggle
end

local function stopMovement(humanoid, rootPart)
    if state.motionMode == "hold" and not state.motionGoal then return end
    humanoid:MoveTo(rootPart.Position)
    state.motionMode = "hold"
    state.motionGoal = nil
    state.fallbackGoal, state.fallbackUntil = nil, 0
    clearPath()
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
        warn(string.format("[EnemyWalker] damage event #%d (%.0f -> %.0f)", state.damageEvents, state.lastPlayerHealth, humanoid.Health))
    end
    state.lastPlayerHealth = humanoid.Health
    local target, distance = getClosestEnemy(rootPart, now)
    if not target then
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
    state.currentTarget, state.targetName, state.targetDist = target, target.Name, distance
    state.prevHealth[target] = targetHumanoid.Health
    faceEnemy(humanoid, rootPart, targetRoot)

    local threat = findThreat(rootPart, target, now)
    state.lastThreatPart = threat
    if threat and not state.observedThreats[threat] then state.observedThreats[threat] = now end
    -- Distance is handled by the normal combat goal. Dodge state is entered
    -- only for an active precast/projectile, and the same persistent threat is
    -- not allowed to restart the dodge every Heartbeat.
    if CFG.AUTO_DODGE and threat and now - state.observedThreats[threat] >= CFG.REACTION_TIME and canTeleportDodge(now, CFG.DODGE_LATERAL_DISTANCE, threat) then
        local destination = findDodgeGoal(rootPart, targetRoot, threat)
        if performDodgeTeleport(humanoid, rootPart, destination, target, threat, now) then
            faceEnemy(humanoid, rootPart, targetRoot)
            state.status = "Dodging"
            return
        end
    end
    state.dodgeGoal = nil

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
    if not state.running or state.closed or not isValidTarget(target) or not target:IsDescendantOf(Workspace) then
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
        state.skillQ_count, state.skillE_count, state.kills, state.stuckRetries = 0, 0, 0, 0
        state.skillToggle, state.lastSkillTime = false, 0
        state.lockedTarget, state.currentTarget = nil, nil
        state.cachedTargets, state.prevHealth = {}, setmetatable({}, { __mode = "k" })
        state.lastTargetScan = 0
        state.lastDodgeTime, state.dodgeGoal = 0, nil
        state.motionGoal, state.motionGoalMode, state.motionMode = nil, nil, "idle"
        state.fallbackGoal, state.fallbackUntil = nil, 0
        state.stuckStartTime, state.stuckCount, state.pathUpdateTime = 0, 0, 0
        state.lastDodgeThreat, state.lastDodgeThreatAt = nil, 0
        state.dodgeCount, state.damageEvents, state.lastPlayerHealth = 0, 0, nil
        createWaypointFolder()
        state.pathStatus = "Pathfinding: active"
    else
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
end

connect(player.CharacterAdded, function()
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
    SetWaypoints = function(enabled)
        CFG.SHOW_WAYPOINTS = enabled
        if enabled then visualizeWaypoints(state.waypoints, state.currentWaypointIndex) else clearWaypointVisuals() end
    end,
}
