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
    DODGE_COOLDOWN = 0.5,
    DODGE_LATERAL_DISTANCE = 8,
    DODGE_WINDOW = 3,
    DODGE_MAX_PER_WINDOW = 3,
    DODGE_DISTANCE_BUDGET = 18,
    DODGE_SAME_THREAT_COOLDOWN = 3,
    THREAT_RADIUS = 90,
    PROJECTILE_LOOKAHEAD = 1.35,
    PRECAST_MARGIN = 3,
    HAZARD_MARGIN_BASE = 6,
    HAZARD_MARGIN = 6,
    THREAT_MAX_AGE = 2,
    AUTO_ABILITIES = true,
    AUTO_DODGE = true,
    HITLESS_SOLO = true,
    TELEPORT_DODGE = true,
    SHOW_THREAT_LABELS = true,
    REACTION_TIME = 0,
    MELEE_DANGER_DISTANCE = 11,
    MELEE_ESCAPE_LEASE = 0.9,
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
    unreachableTargets = setmetatable({}, { __mode = "k" }),
    combatIntent = nil,

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
    hazardMarginBonus = 0,
    hazardMarginBonusAt = 0,
    hazardMemory = {},
    hazardMemorySequence = 0,
    hazardMemoryDirty = false,
    aimObservations = setmetatable({}, { __mode = "k" }),
    observedThreats = setmetatable({}, { __mode = "k" }),
    activeZones = {},
    nearbyEnemies = {},
    safetyUntil = 0,
    lastSafetyScan = -math.huge,
    lastEscapePlan = -math.huge,
    enemyMotion = setmetatable({}, { __mode = "k" }),
    retreating = false,
    pathComputations = 0,
    threatLog = {},
    routeDungeon = nil,
    routeAnchors = {},
    routeAnchorIndex = 1,
    routeProgress = nil,
    routeInitialized = false,
    routeHasCombat = false,
    routeScannedAt = -math.huge,
    hazardSnapshot = { at = 0, risk = 0, items = {}, plan = "idle", goalDistance = 0 },
    hazardLabelFolder = nil,
    hazardLabels = {},
}

-- Ring-buffer recorder: zone sightings, escapes, teleports, hits.
-- Lets a later hit be explained from the previous ~60s of decisions.
local function logThreat(kind, info)
    local entry = { at = os.clock(), kind = kind }
    if type(info) == "table" then
        for key, value in pairs(info) do entry[key] = value end
    else
        entry.detail = info
    end
    table.insert(state.threatLog, entry)
    while #state.threatLog > 160 do table.remove(state.threatLog, 1) end
end

local function hazardDisplayName(zone)
    if zone.name and zone.name ~= "" then return tostring(zone.name) end
    local instance = zone.id
    if typeof(instance) == "Instance" then
        if (instance.Name == "precast" or instance.Name == "hitBox") and instance.Parent then
            instance = instance.Parent
        end
        return instance.Name
    end
    return zone.shape or "attack"
end

local function hazardDisplayShape(zone)
    if zone.shape == "Cylinder" or zone.shape == "Sphere" then return "radial" end
    if zone.shape == "Projectile" then return "projectile" end
    if zone.shape == "ProtectorSmash" then return "expanding" end
    if zone.shape == "Block" then
        local size = zone.size
        if size and ((size.X * 2.25 <= size.Z) or (size.Z * 2.25 <= size.X)) then return "line" end
    end
    return string.lower(tostring(zone.shape or "zone"))
end

local function hazardMemoryKey(zone)
    return string.sub(hazardDisplayName(zone), 1, 48) .. "|" .. hazardDisplayShape(zone)
end

local function memoryFor(key)
    local memory = state.hazardMemory
    local entry = memory[key]
    if not entry then
        local count, oldestKey, oldestSequence = 0, nil, math.huge
        for candidate, value in pairs(memory) do
            count = count + 1
            if value.sequence < oldestSequence then oldestKey, oldestSequence = candidate, value.sequence end
        end
        if count >= 24 and oldestKey then memory[oldestKey] = nil end
        entry = { hits = 0, bonus = 0, sequence = 0, sides = {}, aimSamples = 0, aimFollow = 0 }
        memory[key] = entry
    end
    return entry
end

-- Learn whether a visible attack marker follows the player's movement.
-- Each marker contributes at most one result, after two movement observations.
-- Several separate attacks must agree before forecasting influences dodging.
local function observeAttackAim(zones, rootPart, now)
    local playerPosition = rootPart.Position
    for _, zone in ipairs(zones) do
        local id = zone.id
        if zone.live and zone.shape ~= "Projectile" and typeof(id) == "Instance"
            and math.max(zone.size.X, zone.size.Z) < 100
            and ThreatGeometry.clearance(zone, playerPosition, 0) < 15 then
            local sample = state.aimObservations[id]
            local attackPosition = zone.frame.Position
            if not sample then
                state.aimObservations[id] = { at = now, player = playerPosition, attack = attackPosition }
            elseif now - sample.at >= 0.12 then
                local playerMove = Vector3.new(playerPosition.X - sample.player.X, 0, playerPosition.Z - sample.player.Z)
                local attackMove = Vector3.new(attackPosition.X - sample.attack.X, 0, attackPosition.Z - sample.attack.Z)
                if playerMove.Magnitude >= 1.5
                    and attackMove.Magnitude <= math.min(14, playerMove.Magnitude * 1.6) then
                    local follow = 0
                    if attackMove.Magnitude >= 0.5 and attackMove.Unit:Dot(playerMove.Unit) >= 0.7 then
                        follow = math.clamp(attackMove.Magnitude / playerMove.Magnitude, 0, 1)
                    end
                    if not sample.committed then
                        sample.count = (sample.count or 0) + 1
                        sample.follow = (sample.follow or 0) + follow
                        if sample.count >= 2 then
                            local result = sample.follow / sample.count
                            local key = hazardMemoryKey(zone)
                            if result >= 0.5 or state.hazardMemory[key] then
                                local entry = memoryFor(key)
                                entry.aimSamples = math.min(16, (entry.aimSamples or 0) + 1)
                                entry.aimFollow = entry.aimSamples == 1 and result
                                    or math.clamp((entry.aimFollow or 0) * 0.75 + result * 0.25, 0, 1)
                                state.hazardMemorySequence = state.hazardMemorySequence + 1
                                entry.sequence = state.hazardMemorySequence
                                state.hazardMemoryDirty = true
                            end
                            sample.committed = true
                        end
                    end
                end
                sample.at, sample.player, sample.attack = now, playerPosition, attackPosition
            end
        end
    end
end

local function forecastAttackAim(zones, rootPart)
    local velocity = rootPart.AssemblyLinearVelocity
    local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
    if horizontal.Magnitude < 4 then return end
    for _, zone in ipairs(zones) do
        if zone.live and zone.shape ~= "Projectile" and not zone.moving
            and ThreatGeometry.clearance(zone, rootPart.Position, 0) < 20 then
            local entry = state.hazardMemory[hazardMemoryKey(zone)]
            if entry and (entry.aimSamples or 0) >= 3 and (entry.aimFollow or 0) >= 0.6 then
                local offset = horizontal * (0.3 * entry.aimFollow)
                if offset.Magnitude > 5 then offset = offset.Unit * 5 end
                zone.aimForecast = { frame = zone.frame + offset, size = zone.size, shape = zone.shape,
                    velocity = zone.velocity, moving = false, lookahead = 0 }
                zone.aimOffset = offset
            end
        end
    end
end

local function observeEscape(key, side, success)
    if not key or not side then return end
    local entry = memoryFor(key)
    entry.sides = entry.sides or {}
    local sample = entry.sides[tostring(side)] or { count = 0, value = 0.5 }
    sample.count = math.min(32, sample.count + 1)
    sample.value = math.clamp(sample.value + 0.25 * ((success and 1 or 0) - sample.value), 0, 1)
    entry.sides[tostring(side)] = sample
    if not success then entry.avoidSide = side end
    state.hazardMemorySequence = state.hazardMemorySequence + 1
    entry.sequence = state.hazardMemorySequence
    state.hazardMemoryDirty = true
end

local function rememberHazardHit(zone)
    local key = hazardMemoryKey(zone)
    local entry = memoryFor(key)
    local learning = state.escapeLearning
    if learning and not learning.done and learning.key == key
        and os.clock() - learning.at < 2 then
        observeEscape(key, learning.side, false)
        learning.done = true
    end
    if entry.lastHitAt and os.clock() - entry.lastHitAt < 2 then return end
    state.hazardMemorySequence = state.hazardMemorySequence + 1
    entry.hits = math.min(100, entry.hits + 1)
    entry.bonus = math.min(5, entry.bonus + 1)
    entry.sequence = state.hazardMemorySequence
    entry.lastHitAt = os.clock()
    state.hazardMemoryDirty = true
end

local function learnedHazardMargin(position)
    local bonus = 0
    for _, zone in ipairs(state.activeZones) do
        -- A long beam can reach the player while its center is over a hundred
        -- studs away. Distance to the hitbox, not its center, decides whether
        -- past damage from this attack should widen the dodge margin.
        if ThreatGeometry.clearance(zone, position, 0) < 40 then
            local entry = state.hazardMemory[hazardMemoryKey(zone)]
            if entry then bonus = math.max(bonus, entry.bonus) end
        end
    end
    return bonus
end

local function learnedEscapeSide(entry, fallback)
    if not entry then return fallback end
    local left = entry.sides and entry.sides["-1"]
    local right = entry.sides and entry.sides["1"]
    local count = (left and left.count or 0) + (right and right.count or 0)
    if count >= 2 then
        local leftScore = left and left.value or 0.5
        local rightScore = right and right.value or 0.5
        if math.abs(leftScore - rightScore) >= 0.1 then
            return leftScore > rightScore and -1 or 1
        end
    end
    return entry.avoidSide and -entry.avoidSide or fallback
end

local function clearHazardLabels()
    for key, entry in pairs(state.hazardLabels) do
        if entry.gui then entry.gui:Destroy() end
        if entry.anchor and entry.anchor.Parent == state.hazardLabelFolder then entry.anchor:Destroy() end
        state.hazardLabels[key] = nil
    end
    if state.hazardLabelFolder then
        state.hazardLabelFolder:Destroy()
        state.hazardLabelFolder = nil
    end
    state.lastHazardLabelUpdate = nil
end

local function updateHazardLabels(rootPart)
    if not CFG.SHOW_THREAT_LABELS or not rootPart then
        clearHazardLabels()
        return
    end
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return end
    local now = os.clock()
    if state.lastHazardLabelUpdate and now - state.lastHazardLabelUpdate < 0.15 then return end
    state.lastHazardLabelUpdate = now
    if state.hazardLabelFolder and not state.hazardLabelFolder.Parent then clearHazardLabels() end
    if not state.hazardLabelFolder then
        state.hazardLabelFolder = Instance.new("Folder")
        state.hazardLabelFolder.Name = "ObsidianHazardLabelAnchors"
        state.hazardLabelFolder.Parent = Workspace
    end
    local nearby = {}
    for _, zone in ipairs(state.activeZones) do
        local clearance = ThreatGeometry.clearance(zone, rootPart.Position, 0)
        if clearance < 30 then table.insert(nearby, { zone = zone, clearance = clearance }) end
    end
    table.sort(nearby, function(a, b) return a.clearance < b.clearance end)
    local active = {}
    for index = 1, math.min(6, #nearby) do
        local zone = nearby[index].zone
        local name, shape = hazardDisplayName(zone), hazardDisplayShape(zone)
        local position = zone.frame.Position
        local key = zone.id or table.concat({ name, shape, math.floor(position.X / 3), math.floor(position.Y / 3), math.floor(position.Z / 3) }, ":")
        if not active[key] then
            active[key] = true
            local clearance = nearby[index].clearance
            local planningClearance = ThreatGeometry.clearance(zone, rootPart.Position, CFG.HAZARD_MARGIN)
            local decision = planningClearance < 0 and "DODGE" or "WATCH"
            local entry = state.hazardLabels[key]
            if entry and (not entry.anchor or entry.anchor.Parent ~= state.hazardLabelFolder or not entry.gui or not entry.gui.Parent) then
                if entry.gui then entry.gui:Destroy() end
                if entry.anchor and entry.anchor.Parent == state.hazardLabelFolder then entry.anchor:Destroy() end
                state.hazardLabels[key] = nil
                entry = nil
            end
            if not entry then
                local anchor = Instance.new("Part")
                anchor.Name = "HazardLabelAnchor"
                anchor.Anchored, anchor.CanCollide, anchor.CanTouch, anchor.CanQuery = true, false, false, false
                anchor.Transparency, anchor.Size = 1, Vector3.new(0.2, 0.2, 0.2)
                anchor.Parent = state.hazardLabelFolder
                local gui = Instance.new("BillboardGui")
                gui.Name = "HazardLabel"
                gui.AlwaysOnTop, gui.MaxDistance = true, 180
                gui.Size, gui.StudsOffset = UDim2.fromOffset(230, 42), Vector3.new(0, 3, 0)
                gui.Adornee, gui.Parent = anchor, playerGui
                local label = Instance.new("TextLabel")
                label.Name = "Text"
                label.BackgroundTransparency = 1
                label.Size = UDim2.fromScale(1, 1)
                label.Font = Enum.Font.GothamBold
                label.TextSize, label.TextStrokeTransparency = 12, 0.35
                label.TextWrapped = true
                label.Parent = gui
                entry = { gui = gui, anchor = anchor, label = label }
                state.hazardLabels[key] = entry
            end
            entry.anchor.CFrame = zone.frame
            entry.label.Text = string.format("%s | %s\n%s %.1f", decision, name, shape, clearance)
            entry.label.TextColor3 = planningClearance < 0 and Color3.fromRGB(255, 90, 80)
                or planningClearance < 3 and Color3.fromRGB(255, 210, 80)
                or Color3.fromRGB(100, 255, 150)
            entry.gui.StudsOffset = Vector3.new(0, math.clamp(zone.size.Y * 0.5 + 2, 3, 14), 0)
        end
    end
    for key, entry in pairs(state.hazardLabels) do
        if not active[key] then
            if entry.gui then entry.gui:Destroy() end
            if entry.anchor and entry.anchor.Parent == state.hazardLabelFolder then entry.anchor:Destroy() end
            state.hazardLabels[key] = nil
        end
    end
end

local function refreshHazardSnapshot(rootPart, risk)
    local items = {}
    if rootPart then
        for _, zone in ipairs(state.activeZones) do
            local clearance = ThreatGeometry.clearance(zone, rootPart.Position, 0)
            local planningClearance = ThreatGeometry.clearance(zone, rootPart.Position, CFG.HAZARD_MARGIN)
            table.insert(items, {
                name = hazardDisplayName(zone),
                shape = hazardDisplayShape(zone),
                clearance = clearance,
                planningClearance = planningClearance,
                decision = planningClearance < 0 and "DODGE" or "WATCH",
                expiresIn = zone.expires and math.max(0, zone.expires - os.clock()) or nil,
            })
        end
    end
    table.sort(items, function(a, b)
        if a.planningClearance ~= b.planningClearance then return a.planningClearance < b.planningClearance end
        return a.name < b.name
    end)
    while #items > 12 do table.remove(items) end
    local goalDistance = 0
    if rootPart and state.escapeGoal then goalDistance = (state.escapeGoal - rootPart.Position).Magnitude end
    state.hazardSnapshot = {
        at = os.clock(),
        risk = risk or 0,
        items = items,
        plan = state.escapeReason or (state.escapeGoal and "committed escape" or "pursuit"),
        goalDistance = goalDistance,
    }
    updateHazardLabels(rootPart)
end

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

local adaptiveMemory = AdaptiveMemory.new()
local adaptiveNavigation = AdaptiveNavigation.new(adaptiveMemory)
local northernMechanics = NorthernLandsController.new({
    projectilePredictor = TelegraphedProjectilePredictor,
    workspace = Workspace,
    player = player,
    threatGeometry = ThreatGeometry,
    connect = connect,
    memory = adaptiveMemory,
})
state.mechanicState = northernMechanics.State

local humanoidModels = {}
-- PrecastHitbox and similar effects are transient BaseParts. Tracking additions
-- lets the dodge check remain cheap and catches indicators created under Workspace.
local threatParts = {}
local announcedZones = {}
local safeSpots = {}
local beamParts = {}
local loggedThreats = setmetatable({}, { __mode = "k" })
local aquaticLineTemplates = {}
local function soloHitless()
    return CFG.HITLESS_SOLO and #Players:GetPlayers() == 1
end
local function dangerousName(instance)
    local name = instance:GetFullName():lower()
    return name:find("damage", 1, true) or name:find("hitbox", 1, true)
        or name:find("hazard", 1, true) or name:find("telegraph", 1, true)
        or name:find("precast", 1, true) or name:find("warning", 1, true)
        or name:find("danger", 1, true) or name:find("attack", 1, true)
        or name:find("projectile", 1, true) or name:find("missile", 1, true)
        or name:find("shot", 1, true) or name:find("bomb", 1, true)
        or name:find("spike", 1, true) or name:find("orb", 1, true)
        or name:find("blast", 1, true) or name:find("slam", 1, true)
        or name:find("flame", 1, true) or name:find("beam", 1, true)
        or name:find("laser", 1, true) or name:find("spinninglaser", 1, true)
        or name:find("bigcircle", 1, true) or name:find("bouncingorbbeam", 1, true)
end
do
    local templates = game:GetService("ReplicatedStorage"):FindFirstChild("enemyProjectiles")
    for _, name in ipairs({ "firstBossRightHandShot", "secondBossRandomLine" }) do
        local model = templates and templates:FindFirstChild(name)
        local warning = model and model:FindFirstChild("precast")
        local hitbox = model and model:FindFirstChild("hitBox")
        if warning and warning:IsA("BasePart") and hitbox and hitbox:IsA("BasePart") then
            table.insert(aquaticLineTemplates, { name = name, warningSize = warning.Size, hitboxSize = hitbox.Size })
        end
    end
end
local function trackInstance(instance)
    if instance:IsA("BasePart") and instance.Name:lower() == "checkpoint" then
        state.routeAnchors, state.routeScannedAt = {}, -math.huge
    end
    if state.hazardLabelFolder and instance:IsDescendantOf(state.hazardLabelFolder) then return end
    if instance:IsA("Humanoid") and instance.Parent and instance.Parent:IsA("Model") then
        humanoidModels[instance] = instance.Parent
    end
    if instance:IsA("Beam") then
        beamParts[instance] = true
    end
    if instance:IsA("BasePart") then
        local now = os.clock()
        if not instance.CanCollide and (not state.waypointFolder or not instance:IsDescendantOf(state.waypointFolder)) then
            threatParts[instance] = { createdAt = now, lastPosition = instance.Position, lastAt = now }
            local parentThreat = instance.Parent and dangerousName(instance.Parent)
            if dangerousName(instance) or parentThreat then
                -- DescendantAdded can arrive between the 0.1s safety scans.
                -- Invalidate the cached scan immediately; the control owner
                -- will perform the actual geometry and movement decision.
                state.lastSafetyScan = -math.huge
                state.lastEscapePlan = -math.huge
            end
        end
        local safeName = instance:GetFullName():lower()
        if safeName:find("safespot", 1, true) or safeName:find("safezone", 1, true) then
            safeSpots[instance] = true
        end
    end
end
connect(Workspace.DescendantAdded, trackInstance)
connect(Workspace.DescendantRemoving, function(instance)
    if instance:IsA("BasePart") and instance.Name:lower() == "checkpoint" then
        state.routeAnchors, state.routeScannedAt = {}, -math.huge
    end
    local sample = threatParts[instance]
    if sample and sample.zone then sample.removedAt = os.clock() else threatParts[instance] = nil end
    safeSpots[instance] = nil
    beamParts[instance] = nil
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

pcall(function()
    local storage = game:GetService("ReplicatedStorage")
    local remotes = storage:FindFirstChild("remotes")
    local remote = remotes and remotes:FindFirstChild("aquaticBossSpecficEvents")
    local templates = storage:FindFirstChild("enemyProjectiles")
    local template = templates and templates:FindFirstChild("firstBossLaserPrecast")
    local marker = template and template:FindFirstChild("precast")
    local syncModule = storage:FindFirstChild("timeSync")
    if not remote or not marker or not template.PrimaryPart or not syncModule then return end
    local timeSync = require(syncModule)
    local offset = template.PrimaryPart.CFrame:ToObjectSpace(marker.CFrame)
    local size = marker.Size
    connect(remote.OnClientEvent, function(action, data)
        if not state.closed and action == "second boss show damage parts" then
            state.lastSafetyScan = -math.huge
            state.escapeGoal = nil
            state.lastEscapePlan = -math.huge
            return
        end
        if not state.closed and type(data) == "table"
            and (action == "first boss moving orb" or action == "last boss moving orb") then
            local orb = templates:FindFirstChild(action == "first boss moving orb" and "firstBossMoveOrb" or "finalBossOrbShot")
            if not orb or not orb:IsA("BasePart") or typeof(data[1]) ~= "CFrame"
                or type(data[2]) ~= "number" or type(data[3]) ~= "number"
                or type(data[4]) ~= "number" or type(data[5]) ~= "number" or data[5] <= 0 then return end
            local serverNow, now = timeSync:GetTime(), os.clock()
            local remaining = data[3] - serverNow
            if remaining < 0 or remaining > 30 then return end
            table.insert(announcedZones, { frame = data[1], origin = data[1], size = orb.Size,
                shape = "Projectile", velocity = data[1].LookVector * (data[4] / data[5]),
                starts = now + data[2] - serverNow, duration = data[5],
                travel = data[1].LookVector * data[4], lookahead = CFG.PROJECTILE_LOOKAHEAD,
                expires = now + remaining + 0.2, id = {}, name = action })
            state.lastSafetyScan = -math.huge
            return
        end
        if state.closed or action ~= "first boss laser shot" or type(data) ~= "table"
            or type(data[2]) ~= "number" or typeof(data[3]) ~= "CFrame" then return end
        local remaining = data[2] - timeSync:GetTime()
        if remaining < 0 or remaining > 30 then return end
        table.insert(announcedZones, { frame = data[3] * offset, size = size, shape = "Block",
            expires = os.clock() + remaining + 0.2, id = {} })
        state.lastSafetyScan = -math.huge
    end)
end)

-- Northern Lands announces first-boss projectiles before it creates their
-- Workspace markers. The client map-local script confirms the payload shape:
-- distance, travel duration, server start, server end, origin CFrame. Model
-- these as announced projectile corridors so the controller can move before
-- a seeking spike or Big Spike reaches the character.
pcall(function()
    local storage = game:GetService("ReplicatedStorage")
    local remotes = storage:FindFirstChild("remotes")
    local remote = remotes and remotes:FindFirstChild("northernBossSpecficEvents")
    local templates = storage:FindFirstChild("enemyProjectiles")
    local syncModule = storage:FindFirstChild("timeSync")
    if not remote or not templates or not syncModule then return end
    local timeSync = require(syncModule)
    connect(remote.OnClientEvent, function(action, data)
        local spec = TelegraphedProjectilePredictor.events[action]
        if state.closed or not spec then return end
        local template = templates:FindFirstChild(spec.template)
        if not template then return end
        local size
        if template:IsA("BasePart") then size = template.Size
        elseif template:IsA("Model") then local _, bounds = template:GetBoundingBox(); size = bounds end
        local zone = TelegraphedProjectilePredictor.decode(action, data, size, os.clock(), timeSync:GetTime())
        if not zone then return end
        table.insert(announcedZones, zone)
        state.lastSafetyScan = -math.huge
        state.lastEscapePlan = -math.huge
    end)
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

local function dungeonName()
    local value = Workspace:FindFirstChild("dungeonName")
    return value and value:IsA("ValueBase") and tostring(value.Value) or nil
end

-- Dungeon maps expose their intended room order through checkPoint parts. Use
-- that authored route whenever replicated enemies are visible through a wall;
-- direct nearest-enemy steering otherwise cuts across folded rooms and doors.
local function refreshRouteAnchors(now)
    local name = dungeonName()
    if state.routeDungeon == name and #state.routeAnchors > 0 then return end
    if state.routeDungeon == name and now - state.routeScannedAt < 2 then return end
    if state.routeDungeon ~= name then
        state.routeProgress = nil
        state.routeInitialized = false
    end
    state.routeDungeon, state.routeAnchors, state.routeAnchorIndex = name, {}, 1
    state.routeScannedAt = now
    local dungeon = Workspace:FindFirstChild("dungeon")
    if not dungeon then return end
    for _, instance in ipairs(dungeon:GetDescendants()) do
        if instance:IsA("BasePart") and instance.Name:lower() == "checkpoint" then
            local room = instance.Parent and instance.Parent.Name or ""
            local number = tonumber(room:lower():match("room(%d+)"))
            local order = number or (room:lower():find("boss", 1, true) and 1000 or 900)
            table.insert(state.routeAnchors, { part = instance, order = order, name = room })
        end
    end
    table.sort(state.routeAnchors, function(a, b)
        return a.order < b.order or a.order == b.order and a.name < b.name
    end)
    local progress = state.routeProgress
    if progress then
        while state.routeAnchors[state.routeAnchorIndex] do
            local anchor = state.routeAnchors[state.routeAnchorIndex]
            if anchor.order > progress.order or anchor.order == progress.order and anchor.name > progress.name then break end
            state.routeAnchorIndex = state.routeAnchorIndex + 1
        end
    end
end

local hasBlockingRay

local function syncRouteToCurrentRoom(rootPart, maxDistance)
    local nearestIndex, nearestDistance
    for index = state.routeAnchorIndex, #state.routeAnchors do
        local anchor = state.routeAnchors[index]
        if anchor.part.Parent then
            local delta = rootPart.Position - anchor.part.Position
            local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
            if flat <= maxDistance and math.abs(delta.Y) <= 12
                and (not nearestDistance or flat < nearestDistance)
                and not hasBlockingRay(rootPart.Position, anchor.part.Position, rootPart.Parent, anchor.part) then
                nearestIndex, nearestDistance = index, flat
            end
        end
    end
    if nearestIndex then
        local anchor = state.routeAnchors[nearestIndex]
        state.routeProgress = { order = anchor.order, name = anchor.name }
        state.routeAnchorIndex = nearestIndex + 1
    end
    return nearestIndex, nearestDistance
end

local function initializeRouteProgress(rootPart)
    -- The loader may start in the middle of a run. Controller-local kill and
    -- combat counters are then still zero, so using them to decide whether to
    -- synchronize sends the route back to room one. Always accept a nearby,
    -- visible checkpoint as authored proof of the current room.
    local synced = syncRouteToCurrentRoom(rootPart, 55)
    if synced or #state.routeAnchors < 2 then return end

    -- Large rooms can put their checkpoint outside the local radius. Only use
    -- the broader search when a later visible checkpoint is substantially
    -- closer than the first remaining anchor; this avoids skipping room one
    -- from the dungeon spawn while still repairing mid-run attachment.
    local first = state.routeAnchors[state.routeAnchorIndex]
    if not first or not first.part.Parent then return end
    local firstDistance = Vector3.new(rootPart.Position.X - first.part.Position.X, 0,
        rootPart.Position.Z - first.part.Position.Z).Magnitude
    local bestIndex, bestDistance
    for index = state.routeAnchorIndex + 1, #state.routeAnchors do
        local anchor = state.routeAnchors[index]
        if anchor.part.Parent then
            local delta = rootPart.Position - anchor.part.Position
            local distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
            if distance <= 120 and math.abs(delta.Y) <= 14
                and distance + 28 < firstDistance
                and (not bestDistance or distance < bestDistance)
                and not hasBlockingRay(rootPart.Position, anchor.part.Position, rootPart.Parent, anchor.part) then
                bestIndex, bestDistance = index, distance
            end
        end
    end
    if bestIndex then
        local anchor = state.routeAnchors[bestIndex]
        state.routeProgress = { order = anchor.order, name = anchor.name }
        state.routeAnchorIndex = bestIndex + 1
    end
end

local function mapRouteGoal(rootPart, now, observeOnly)
    refreshRouteAnchors(now)
    if not state.routeInitialized and #state.routeAnchors > 0 then
        state.routeInitialized = true
        initializeRouteProgress(rootPart)
    end
    local edge = adaptiveNavigation.edge
    if edge and edge.anchor and edge.anchor.part.Parent
        and (rootPart.Position - edge.goal).Magnitude < 12
        and not hasBlockingRay(rootPart.Position, edge.goal, rootPart.Parent, edge.anchor.part) then
        local reached = edge.anchor
        adaptiveNavigation:Outcome(true, "chosen room entrance reached", now)
        if not state.routeProgress or reached.order > state.routeProgress.order
            or reached.order == state.routeProgress.order and reached.name > state.routeProgress.name then
            state.routeProgress = { order = reached.order, name = reached.name }
        end
        while state.routeAnchors[state.routeAnchorIndex] do
            local item = state.routeAnchors[state.routeAnchorIndex]
            if item.order > reached.order or item.order == reached.order and item.name > reached.name then break end
            state.routeAnchorIndex = state.routeAnchorIndex + 1
        end
    end
    while true do
        local anchor = state.routeAnchors[state.routeAnchorIndex]
        if not anchor then adaptiveNavigation:Cancel("room graph complete"); return nil end
        if not anchor.part.Parent then
            state.routeAnchors, state.routeScannedAt = {}, -math.huge
            refreshRouteAnchors(now)
            anchor = state.routeAnchors[state.routeAnchorIndex]
            if not anchor then return nil end
        end
        local delta = rootPart.Position - anchor.part.Position
        local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
        -- An anchor across a door or on a different floor is not reached just
        -- because its XZ projection is nearby.
        if flat <= 12 and math.abs(delta.Y) <= 9
            and not hasBlockingRay(rootPart.Position, anchor.part.Position, rootPart.Parent, anchor.part) then
            if adaptiveNavigation.edge and adaptiveNavigation.edge.anchor == anchor then
                adaptiveNavigation:Outcome(true, "checkpoint advancement", now)
            else
                adaptiveNavigation:Cancel("different checkpoint reached")
            end
            state.routeProgress = { order = anchor.order, name = anchor.name }
            state.routeAnchorIndex = state.routeAnchorIndex + 1
        else
            if observeOnly then return nil end
            local goal, selected = adaptiveNavigation:Goal(rootPart, state.currentTarget, state.routeAnchors,
                state.routeProgress, state.routeDungeon, now, function(position)
                    local blocked = hasBlockingRay(rootPart.Position, position, rootPart.Parent, anchor.part)
                    local risk = ThreatGeometry.risk(state.activeZones, position, CFG.HAZARD_MARGIN)
                    local safe = ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, position, CFG.HAZARD_MARGIN)
                    return (blocked and 100 or 0) + risk * 1000 + (safe and 0 or 1000)
                end)
            state.adaptiveNavigation = adaptiveNavigation.debug
            return goal, selected
        end
    end
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
    if now - (state.lastTargetChoice or 0) < 0.15 and isValidTarget(state.lockedTarget)
        and now >= (state.unreachableTargets[state.lockedTarget] or 0) then
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
    -- Prefer the reachable edge of a nearby pack when several enemies are
    -- close together. This keeps melee mobs stacked for splash damage while
    -- the combat orbit circles their local center. The search distance below
    -- still prevents pulling a separate room-wide pack.
    local clusterRadius = 18
    for _, candidate in ipairs(candidates) do
        local count, center = 0, Vector3.zero
        for _, other in ipairs(candidates) do
            if (other.root.Position - candidate.root.Position).Magnitude <= clusterRadius then
                count, center = count + 1, center + other.root.Position
            end
        end
        candidate.cluster = count
        candidate.clusterCenter = count > 0 and center / count or candidate.root.Position
    end
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    local searchDistance = candidates[1] and math.max(CFG.THREAT_RADIUS, candidates[1].distance + 24) or 0
    local hasReachable = false
    for _, candidate in ipairs(candidates) do
        if candidate.distance > searchDistance then break end
        if now >= (state.unreachableTargets[candidate.model] or 0) then hasReachable = true; break end
    end
    local closest
    local closestIsVisible = false
    if #candidates > 0 then
        -- Prefer nearby enemies we can engage over a closer one behind a wall.
        local function engageScore(candidate)
            local clusterBonus = math.min(4, math.max(0, (candidate.cluster or 1) - 1)) * 8
            return candidate.distance - clusterBonus
        end
        for index, candidate in ipairs(candidates) do
            if index > 24 or candidate.distance > searchDistance then break end
            if (not hasReachable or now >= (state.unreachableTargets[candidate.model] or 0))
                and not hasBlockingRay(rootPart.Position, candidate.root.Position, rootPart.Parent, candidate.model) then
                if not closest or engageScore(candidate) < engageScore(closest) then
                    closest = candidate
                    closestIsVisible = true
                end
            end
        end
        if not closest then
            for _, candidate in ipairs(candidates) do
                if not hasReachable or now >= (state.unreachableTargets[candidate.model] or 0) then
                    if not closest or engageScore(candidate) < engageScore(closest) then closest = candidate end
                end
            end
        end
    end
    state.packCount = closest and closest.cluster or 0
    state.packCenter = closest and closest.clusterCenter or nil
    local previousLock = state.lockedTarget
    state.lockedTarget = closest and closest.model
    local pickDist = closest and closest.distance or CFG.DETECTION_RADIUS
    -- Hysteresis: two far targets in opposite directions flip-flop the lock
    -- every step and the bot paces between them forever. Only switch when the
    -- challenger is clearly closer or the lock is invalid/gone.
    if previousLock and previousLock ~= state.lockedTarget and isValidTarget(previousLock)
        and previousLock:IsDescendantOf(Workspace) then
        local lockedRoot = getRootPart(previousLock)
        if lockedRoot then
            local lockedDist = (rootPart.Position - lockedRoot.Position).Magnitude
            local lockedVisible = not hasBlockingRay(rootPart.Position, lockedRoot.Position, rootPart.Parent, previousLock)
            if now >= (state.unreachableTargets[previousLock] or 0)
                and (not closestIsVisible or lockedVisible) and lockedDist <= pickDist + 20
                and lockedDist <= CFG.DETECTION_RADIUS then
                state.lockedTarget = previousLock
                for _, candidate in ipairs(candidates) do
                    if candidate.model == previousLock then
                        state.packCount, state.packCenter = candidate.cluster, candidate.clusterCenter
                        break
                    end
                end
                return previousLock, lockedDist
            end
        end
    end
    return state.lockedTarget, pickDist
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
    params.RespectCanCollide = true
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
    if flat.Magnitude < 0.1 then return math.abs(destination.Y - startPosition.Y) <= 4.5 end
    local previousY = startFloor.Position.Y
    local steps = math.max(1, math.ceil(flat.Magnitude / 3))
    for i = 1, steps do
        local sample = startPosition + flat * (i / steps)
        sample = Vector3.new(sample.X, previousY + 6, sample.Z)
        local ground = Workspace:Raycast(sample, Vector3.new(0, -12, 0), params)
        if not ground or ground.Normal.Y < 0.55 then return false end
        -- Asymmetric steps: climbing more than ~2.5 needs stairs or a jump,
        -- but stepping DOWN is just falling. Allow drops up to 6 so slab
        -- edges and tiers stay walkable; anything deeper risks a pit trap.
        local dy = ground.Position.Y - previousY
        if dy > 2.5 or dy < -6 then return false end
        if ground.Instance.Name:lower():find("lava", 1, true) and not startFloor.Instance.Name:lower():find("lava", 1, true) then return false end
        previousY = ground.Position.Y
    end
    local endPosition = startPosition + flat + Vector3.new(0, previousY - startFloor.Position.Y, 0)
    -- A clear XZ projection is not a walk to a platform above that floor.
    -- Waypoint floor positions may be one hip-height below the root goal.
    if math.abs(destination.Y - endPosition.Y) > 4.5 then return false end
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
    local bestPath, bestPoints, bestCost, bestExposure
    for _, configuration in ipairs(configurations) do
        local path = PathfindingService:CreatePath(configuration)
        state.pathComputations = state.pathComputations + 1
        local ok = pcall(function() path:ComputeAsync(startPosition, endPosition) end)
        if ok and path.Status == Enum.PathStatus.Success then
            local waypoints = path:GetWaypoints()
            if #waypoints >= 2 then
                local cost, exposure, previous = 0, 0, startPosition
                for _, waypoint in ipairs(waypoints) do
                    local point = waypoint.Position + Vector3.new(0, 2.5, 0)
                    local learned = adaptiveNavigation:LocalCost(previous, point)
                    cost = cost + (point - previous).Magnitude + learned / #waypoints
                    exposure = exposure + ThreatGeometry.risk(state.activeZones, point, CFG.HAZARD_MARGIN)
                    if not ThreatGeometry.segmentSafe(state.activeZones, previous, point, CFG.HAZARD_MARGIN) then
                        exposure = exposure + 1
                    end
                    for _, enemy in ipairs(state.nearbyEnemies) do
                        if enemy.root.Parent then cost = cost + math.max(0, enemy.radius - (enemy.root.Position - point).Magnitude) * 8 end
                    end
                    previous = point
                end
                if not bestCost or exposure < bestExposure or exposure == bestExposure and cost < bestCost then
                    if bestPath then bestPath:Destroy() end
                    bestPath, bestPoints, bestCost, bestExposure = path, waypoints, cost, exposure
                else path:Destroy() end
            else
                path:Destroy()
            end
        else
            path:Destroy()
        end
    end
    if bestPath then state.failedPaths[key] = nil; return bestPath, bestPoints end
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

-- Steering uses Humanoid:MoveTo. (Humanoid:Move is input-path and gets
-- swallowed from an executor context, which once froze the bot solid.)
local function issueMove(humanoid, position, mode, now, bypass)
    if mode == "evade" or mode == "mechanic" or mode == "hold" then
        state.adaptiveLocalAttempt = nil
    end
    local function safetyHold(root)
        state.adaptiveLocalAttempt = nil
        if state.motionMode ~= "safety-hold" or now - state.lastMoveToCall >= 0.35 then
            humanoid:MoveTo(root.Position)
            state.lastMoveToCall = now
            state.lastMoveToPosition = root.Position
        end
        state.motionMode = "safety-hold"
    end
    if not bypass and CFG.AUTO_DODGE and #state.activeZones > 0 then
        local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
        if root then
            local delta = position - root.Position
            local nextPosition = delta.Magnitude > 12 and root.Position + delta.Unit * 12 or position
            if not ThreatGeometry.segmentSafe(state.activeZones, root.Position, nextPosition, CFG.HAZARD_MARGIN)
                and not (mode == "evade" and ThreatGeometry.escapeStepSafe(
                    state.activeZones, root.Position, nextPosition, CFG.HAZARD_MARGIN)) then
                safetyHold(root)
                state.movementBlocked = true
                state.blockedByHazard = true
                return
            end
        end
    end
    if not bypass and CFG.AUTO_DODGE and #state.nearbyEnemies > 0 then
        local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
        if root then
            local delta = position - root.Position
            local reach = math.max(3, humanoid.WalkSpeed * 0.3)
            local step = delta.Magnitude > reach and root.Position + delta.Unit * reach or position
            if not safeEnemyStep(root.Position, step) then
                safetyHold(root)
                state.movementBlocked = true
                state.lastEscapePlan = -math.huge
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
    state.movementBlocked, state.blockedByHazard = false, false
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
        if walkingSegmentClear(rootPart, candidate, target)
            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
            and safeEnemyStep(rootPart.Position, candidate) then
            local key = math.floor(candidate.X / 6) .. ":" .. math.floor(candidate.Z / 6)
            local learned = adaptiveNavigation:LocalCost(rootPart.Position, candidate)
            local score = (candidate - goal).Magnitude + (state.fallbackVisits[key] and 40 or 0) + learned
                + math.max(0, 8 - enemyClearance(candidate)) * 12
            if not bestScore or score < bestScore then best, bestScore = candidate, score end
        end
    end
    if best then state.fallbackVisits[math.floor(best.X / 6) .. ":" .. math.floor(best.Z / 6)] = now end
    return best
end

-- Uphill survey: cast a transect from the player toward a higher goal and
-- return the base of the nearest up-step (stairs/ramp), so long climbs chain
-- stair-base -> local climb instead of walking the flat route underneath.
local function surveyUphill(rootPart, targetPos)
    local flat = Vector3.new(targetPos.X - rootPart.Position.X, 0, targetPos.Z - rootPart.Position.Z)
    local dist = flat.Magnitude
    if dist < 12 then return nil end
    local dir = flat.Unit
    local params = buildRaycastParams(rootPart.Parent, nil)
    params.RespectCanCollide = true
    local prev = rootPart.Position + Vector3.new(0, 2, 0)
    local prevGround = Workspace:Raycast(prev, Vector3.new(0, -14, 0), params)
    local prevY = (prevGround and prevGround.Position.Y) or rootPart.Position.Y
    local step, i = 10, 1
    while i * step < math.min(dist, 150) do
        local sample = rootPart.Position + dir * (i * step)
        local hit = Workspace:Raycast(sample + Vector3.new(0, 30, 0), Vector3.new(0, -70, 0), params)
        if hit and hit.Normal.Y > 0.6 and not hit.Instance.Name:lower():find("lava", 1, true) then
            if hit.Position.Y - prevY > 4 then
                -- Walk to just before the step; close-range climb takes over.
                local base = rootPart.Position + dir * ((i - 1) * step)
                local baseHit = Workspace:Raycast(base + Vector3.new(0, 30, 0), Vector3.new(0, -70, 0), params)
                if baseHit and baseHit.Normal.Y > 0.55 then
                    return baseHit.Position + Vector3.new(0, 2.5, 0)
                end
                return nil
            end
            prevY = hit.Position.Y
        end
        i = i + 1
    end
    return nil
end

local function findRecoveryPath(rootPart, goal, target, minRise)    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    local start = rootPart.Position
    minRise = minRise or 4
    local candidates = {}
    for _, radius in ipairs({ 24, 48, 64 }) do
        for index = 0, 11 do
            local angle = index * math.pi / 6
            local sample = start + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            local hit = Workspace:Raycast(sample + Vector3.new(0, 60, 0), Vector3.new(0, -100, 0), params)
            if hit and hit.Normal.Y > 0.65 and hit.Position.Y > start.Y + minRise
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
    if mode ~= "map-route" and adaptiveNavigation.edge then
        adaptiveNavigation:Cancel("local objective owns movement")
    end
    local localAttempt = state.adaptiveLocalAttempt
    -- Only score a continuously pursued fallback for the same objective.
    -- Mechanics, waiting, and replacement goals cancel evidence, not fail it.
    if localAttempt and (now - localAttempt.lastAt > 1 or localAttempt.mode ~= mode
        or (localAttempt.objective - goal).Magnitude > 2 or state.fallbackGoal ~= localAttempt.goal) then
        state.adaptiveLocalAttempt, localAttempt = nil, nil
    end
    if localAttempt then localAttempt.lastAt = now end
    if localAttempt and (rootPart.Position - localAttempt.goal).Magnitude < 4 then
        adaptiveNavigation:LocalOutcome(localAttempt.start, localAttempt.goal, true)
        state.adaptiveLocalAttempt = nil
    elseif localAttempt and now - localAttempt.at > 8 then
        adaptiveNavigation:LocalOutcome(localAttempt.start, localAttempt.goal, false)
        state.adaptiveLocalAttempt = nil
    end
    if state.fallbackGoal and not state.adaptiveLocalAttempt then
        state.adaptiveLocalAttempt = { start = rootPart.Position, goal = state.fallbackGoal, at = now,
            lastAt = now, objective = goal, mode = mode }
    end
    -- Flying targets bob up and down; a climb goal set during an upward bob
    -- goes stale when the target comes back down. Drop it instead of pacing
    -- between tiers.
    if state.terrainRecovery and target and target.Parent then
        local targetRoot = getRootPart(target)
        if targetRoot and targetRoot.Position.Y - rootPart.Position.Y < 4 then
            state.terrainRecovery = nil
            clearPath()
        end
    end
    -- Gap jumps: dungeon bridges break into jumpable platforms. When grounded
    -- with no floor just ahead but a landing in jump reach, hop the gap while
    -- running at it. Ignores water so wading stays on foot.
    if humanoid.FloorMaterial ~= Enum.Material.Air then
        local toGoal = goal - rootPart.Position
        local flat = Vector3.new(toGoal.X, 0, toGoal.Z)
        if flat.Magnitude >= 3 then
            local dir = flat.Unit
            local params = buildRaycastParams(rootPart.Parent, target)
            params.IgnoreWater = true
            local edge = Workspace:Raycast(rootPart.Position + dir * 3 + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), params)
            if not edge then
                local land = Workspace:Raycast(rootPart.Position + dir * 10 + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), params)
                if land and math.abs(land.Position.Y - rootPart.Position.Y) < 6
                    and not land.Instance.Name:lower():find("lava", 1, true) then
                    humanoid.Jump = true
                end
            end
        end
    end
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

    local shouldRepath = state.pathBlocked or #state.waypoints == 0 or not state.pathGoal or (goal - state.pathGoal).Magnitude > 12
    if shouldRepath and not state.pathPending and now - state.pathUpdateTime >= CFG.PATH_UPDATE_INTERVAL and (goal - rootPart.Position).Magnitude > CFG.WAYPOINT_REACH_THRESHOLD then
        state.pathUpdateTime = now
        state.pathPending = true
        local generation = state.pathGeneration
        local routeEpoch = adaptiveNavigation.epoch
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
            or player.Character ~= rootPart.Parent or target and not target.Parent
            or mode == "map-route" and routeEpoch ~= adaptiveNavigation.epoch
            or not state.motionGoal or (state.motionGoal - goal).Magnitude > 8 then
            if path then path:Destroy() end
            return
        end
        if path and waypoints then
            local joinIndex = AdaptiveNavigation.StartWaypoint(waypoints, rootPart.Position, function(position)
                return walkingSegmentClear(rootPart, position, target)
            end)
            if not joinIndex then
                path:Destroy()
                state.pathUpdateTime = 0
                state.pathStatus = "Path start no longer reachable: replanning"
                return
            end
            clearPath()
            state.terrainRecovery = recoveryGoal
            state.pathObject = path
            state.pathBlocked = false
            state.pathGoal, state.pathMode = recoveryGoal or goal, recoveryGoal and "terrain-recovery" or mode
            if recoveryGoal then state.motionGoal, state.motionGoalMode = recoveryGoal, "terrain-recovery" end
            state.waypoints = waypoints
            state.currentWaypointIndex = joinIndex
            state.pathBlockedConn = path.Blocked:Connect(function(blockedIndex)
                if blockedIndex >= state.currentWaypointIndex then state.pathBlocked = true end
            end)
            visualizeWaypoints(waypoints, state.currentWaypointIndex)
            state.pathStatus = (recoveryGoal and "Recovering to higher ground: " or "Pathfinding: ") .. #waypoints .. " waypoints"
        else
            if mode == "map-route" then adaptiveNavigation:Outcome(false, "local path unavailable", os.clock()) end
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
    -- Watchdog: a waypoint we fail to close on for 4s is skipped, not rammed
    -- forever. Deterministic repaths regenerate the same stuck point, so
    -- skipping is what breaks the loop. Progress refreshes the window.
    if waypoint then
        local flatDist = (Vector3.new(rootPart.Position.X - waypoint.Position.X, 0, rootPart.Position.Z - waypoint.Position.Z)).Magnitude
        if state.watchWp ~= waypoint then
            state.watchWp, state.watchSince, state.watchDist, state.watchSkips = waypoint, now, flatDist, 0
        elseif now - state.watchSince >= 4 and flatDist > state.watchDist - 1 then
            local nextWaypoint = state.waypoints[state.currentWaypointIndex + 1]
            if nextWaypoint and walkingSegmentClear(rootPart, nextWaypoint.Position, target) then
                state.currentWaypointIndex = state.currentWaypointIndex + 1
                state.watchWp, state.watchSince = nil, 0
                waypoint = nextWaypoint
            else
                -- A blocked waypoint is evidence that the current path is
                -- stale. Skipping it without a clear next segment cuts walls.
                state.failedPaths[pathKey(rootPart.Position, goal, mode)] = now
                clearPath()
                local detour = chooseFallbackStep(rootPart, goal, target)
                if detour then
                    state.fallbackGoal, state.fallbackUntil = detour, now + 1.6
                    issueMove(humanoid, detour, mode, now)
                end
                return
            end
        elseif flatDist < state.watchDist - 1 then
            state.watchSince, state.watchDist = now, flatDist
        end
    end
    -- Path waypoints are grounded positions while HumanoidRootPart is elevated
    -- by the hip height. Compare XZ distance so a small height delta cannot pin
    -- the controller on the first waypoint of a bridge or stair transition.
    -- But require rough height agreement too: on staircases stacked waypoints
    -- share one XZ, and skipping them all strands the bot walking in place.
    while waypoint
        and (Vector3.new(rootPart.Position.X - waypoint.Position.X, 0, rootPart.Position.Z - waypoint.Position.Z)).Magnitude <= CFG.WAYPOINT_REACH_THRESHOLD
        and math.abs(rootPart.Position.Y - waypoint.Position.Y) <= 6 do
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
            if now - (state.lastPendingStep or -math.huge) >= 0.2 then
                state.lastPendingStep = now
                local fallback = chooseFallbackStep(rootPart, goal, target)
                if fallback then
                    if (goal - rootPart.Position).Magnitude > 50 then
                        state.routeFails = (state.routeFails or 0) + 1
                    end
                    state.fallbackGoal, state.fallbackUntil = fallback, now + 0.6
                    issueMove(humanoid, fallback, mode, now)
                else
                    issueMove(humanoid, rootPart.Position, "recovery-hold", now, true)
                end
            end
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
    -- Recovery must obey the same hazard/enemy checks and visited-cell costs
    -- as normal local navigation, otherwise it repeatedly walks into a guard.
    return chooseFallbackStep(rootPart, goal, target)
end

local function updateProgress(humanoid, rootPart, goal, target, now)
    if now - state.lastStuckCheck < CFG.STUCK_CHECK_INTERVAL then return false end
    state.lastStuckCheck = now
    local remaining
    if #state.waypoints > 0 then
        remaining = 0
        local previous = rootPart.Position
        for index = state.currentWaypointIndex, #state.waypoints do
            local point = state.waypoints[index].Position
            remaining = remaining + (point - previous).Magnitude
            previous = point
        end
        remaining = remaining + (previous - goal).Magnitude
    end
    if adaptiveNavigation:Progress(rootPart.Position, goal, remaining, now) then
        local attempt = state.adaptiveLocalAttempt
        if attempt then
            adaptiveNavigation:LocalOutcome(attempt.start, attempt.goal, false)
            state.adaptiveLocalAttempt = nil
        end
        state.pathBlocked = true
        state.pathUpdateTime = 0
        state.fallbackGoal = nil
        state.routeFails = (state.routeFails or 0) + 1
    end
    -- Follow the active waypoint, not the distant enemy: a valid path may
    -- initially lead away from the final goal to get around a wall.
    local waypoint = state.waypoints[state.currentWaypointIndex]
    local progressGoal = waypoint and waypoint.Position or state.fallbackGoal or goal
    if not state.lastProgressGoal or (progressGoal - state.lastProgressGoal).Magnitude > 3 then
        state.lastProgressGoal = progressGoal
        state.lastProgressDistance = math.huge
        state.stuckStartTime = 0
    end
    local distance = (progressGoal - rootPart.Position).Magnitude
    state.lastPosition = rootPart.Position
    if distance < state.lastProgressDistance - 0.35 then
        state.stuckCount = 0
        state.stuckStartTime = 0
        state.lastProgressDistance = distance
        state.lastProgressAt = now
        state.routeFails = 0
        if target then state.unreachableTargets[target] = nil end
        return false
    end
    state.stuckCount = state.stuckCount + 1
    if state.stuckStartTime == 0 then state.stuckStartTime = now end
    if now - state.stuckStartTime < CFG.STUCK_TIMEOUT then return false end
    -- Rate-limit recoveries: chained lateral hops every 0.75s read as
    -- oscillation. One committed recovery per 2s, then keep walking it.
    if now - (state.lastRecoveryAt or -math.huge) < 2 then return true end
    state.lastRecoveryAt = now

    state.stuckRetries = state.stuckRetries + 1
    state.stuckStartTime = now
    state.stuckCount = 0
    state.routeFails = (state.routeFails or 0) + 1
    if target and state.routeFails >= 6 then
        state.unreachableTargets[target] = now + 6
    end
    -- NOTE: no clearPath() here. Clearing bumps the path generation, which
    -- discards the in-flight repath result, which stalls again, which clears
    -- again: a permanent loop where no path ever survives to be walked.
    -- Keep the current path; the Blocked event repaths if truly blocked.
    local recovery = chooseRecoveryGoal(rootPart, goal, target)
    if recovery then
        state.fallbackGoal, state.fallbackUntil = recovery, now + 1.6
        issueMove(humanoid, recovery, "recovery", now)
        state.pathStatus = "Pathfinding: lateral recovery"
    end
    return true
end

local function refreshSafety(rootPart, now)
    local interval = #state.activeZones > 0 and CFG.CONTROL_INTERVAL * 0.75 or 0.1
    if now - state.lastSafetyScan < interval then return end
    state.lastSafetyScan = now
    local zones, enemies = {}, {}
    -- These sections are created with the map and activated much later. They
    -- must remain discoverable after the transient effect index has aged out.
    local protectorFloor = Workspace:FindFirstChild("secondBossDamageParts")
    if protectorFloor then
        for _, part in ipairs(protectorFloor:GetChildren()) do
            if part:IsA("BasePart") and not threatParts[part] then trackInstance(part) end
        end
    end
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
                -- Honest body radius: half the footprint plus a small buffer.
                -- The old floor (combat distance) flagged every enemy within
                -- 16+ studs as a crowd threat, so the bot backed away from
                -- anything that approached and never held DPS range on bosses.
                -- Real contact is still covered by the melee-threat response.
                local footprint = math.max(root.Size.X, root.Size.Z) * 0.5
                local radius = math.min(22, math.max(6, footprint + 5))
                table.insert(enemies, { model = model, root = root, distance = distance, velocity = velocity, radius = radius })
            end
        end
    end
    state.nearbyEnemies = enemies
    state.safeSpots = {}
    for part in pairs(safeSpots) do
        if part.Parent and part:IsDescendantOf(Workspace) then
            if (part.Position - rootPart.Position).Magnitude <= 120 then
                table.insert(state.safeSpots, part.Position + Vector3.new(0, 2.5, 0))
            end
        else
            safeSpots[part] = nil
        end
    end
    for i = #announcedZones, 1, -1 do
        local zone = announcedZones[i]
        if zone.predictive then
            TelegraphedProjectilePredictor.advance(zone, now)
        elseif zone.origin then
            zone.frame = zone.origin + zone.travel * math.clamp((now - zone.starts) / zone.duration, 0, 1)
            zone.lookahead = math.min(CFG.PROJECTILE_LOOKAHEAD, math.max(0, zone.starts + zone.duration - now))
        end
        if zone.expires < now then table.remove(announcedZones, i)
        elseif (zone.predictive and ThreatGeometry.segmentDistance(rootPart.Position,
            zone.origin.Position, zone.origin.Position + zone.travel) <= CFG.THREAT_RADIUS + zone.size.Magnitude)
            or (zone.frame.Position - rootPart.Position).Magnitude <= CFG.THREAT_RADIUS + zone.size.Magnitude then
            table.insert(zones, zone)
        end
    end
    for beam in pairs(beamParts) do
        if not beam.Parent then
            beamParts[beam] = nil
        elseif beam.Enabled and (soloHitless() or beam.Name ~= "Beam" and dangerousName(beam)
            or beam.Parent and dangerousName(beam.Parent)) then
            local first, second = beam.Attachment0, beam.Attachment1
            if first and second and first.Parent and second.Parent
                and not first:IsDescendantOf(rootPart.Parent) and not second:IsDescendantOf(rootPart.Parent) then
                local startPosition, endPosition = first.WorldPosition, second.WorldPosition
                local forecasted = false
                for _, zone in ipairs(announcedZones) do
                    if TelegraphedProjectilePredictor.matchesBeam(zone, beam.Parent.Name, startPosition, endPosition, now) then
                        forecasted = true
                        break
                    end
                end
                local delta = endPosition - startPosition
                local width = math.max(1, beam.Width0, beam.Width1)
                if not forecasted and delta.Magnitude > 0.1
                    and ThreatGeometry.segmentDistance(rootPart.Position, startPosition, endPosition) <= CFG.THREAT_RADIUS then
                    table.insert(zones, { frame = CFrame.lookAt((startPosition + endPosition) * 0.5, endPosition),
                        size = Vector3.new(width, math.max(6, width), delta.Magnitude), shape = "Block",
                        velocity = Vector3.zero, moving = false, live = true, lookahead = 0, id = beam })
                end
            end
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
            local ownStunPart = part.Name == player.Name and part.Parent and part.Parent.Name:lower() == "stunparts"
            if not playerBody and not ownStunPart and distance < CFG.THREAT_RADIUS + part.Size.Magnitude then
                local name = part:GetFullName():lower()
                local smashBox = part.Name == "precast" and part.Size.Y == 1 and part.Size.Z == 10
                    and part.Size.X >= 10 and part.Size.X <= 150 and part.Parent:FindFirstChild("hitBox")
                local protectorSmash = smashBox and smashBox:IsA("BasePart") and smashBox.Size.Y == 150
                    and smashBox.Size.X == part.Size.X and smashBox.Size.Z == 10
                local lineBox, lineName
                local dungeonName = Workspace:FindFirstChild("dungeonName")
                if part.Name == "precast" and dungeonName and dungeonName.Value == "Aquatic Temple" then
                    local hitbox = part.Parent:FindFirstChild("hitBox")
                    if hitbox and hitbox:IsA("BasePart") then
                        for _, template in ipairs(aquaticLineTemplates) do
                            if (part.Size - template.warningSize).Magnitude < 0.05
                                and (hitbox.Size - template.hitboxSize).Magnitude < 0.05 then
                                sample.lineVisible = sample.lineVisible or part.Transparency < 0.95
                                if sample.lineVisible then lineBox, lineName = hitbox, template.name end
                                break
                            end
                        end
                    end
                end
                local damageContainer = part.Transparency < 0.95 and (name:find("damageparts", 1, true)
                    or name:find("hitboxes", 1, true) or name:find("hazards", 1, true) or name:find("telegraphs", 1, true))
                local elapsed = math.max(0.001, now - sample.lastAt)
                local velocity = part.AssemblyLinearVelocity
                if velocity.Magnitude < 1 then velocity = (part.Position - sample.lastPosition) / elapsed end
                local moved = (part.Position - sample.lastPosition).Magnitude > 0.5
                local projectile = (name:find("projectile") or name:find("missile") or name:find("shot")) and velocity.Magnitude > 1
                local potential = dangerousName(part)
                local parentIsAttack = part.Parent and dangerousName(part.Parent)
                local attackMarker = (part.Name == "precast" or part.Name == "hitBox" or name:find("hitbox", 1, true))
                    and parentIsAttack
                -- Northern Lands keeps several real attack markers fully
                -- transparent. A marker and its sibling hitbox describe one
                -- attack; use the marker once and skip the duplicate hitbox.
                local duplicateHitbox = part.Name == "hitBox" and part.Parent:FindFirstChild("precast") ~= nil
                local attributed = part:GetAttribute("Attack") == true or part:GetAttribute("Hitbox") == true or part:GetAttribute("Damage") ~= nil
                local fresh = now - sample.createdAt < 0.45
                local activeMarker = part.Transparency < 0.95 or attributed or damageContainer or projectile
                    or lineBox or protectorSmash or moved or fresh
                local named = not duplicateHitbox and potential
                    and (part.Transparency < 0.95 or attackMarker and activeMarker)
                local floorMarker = part:IsA("Part") and ((part.Shape == Enum.PartType.Block and part.Size.Y <= 4)
                    or (part.Shape == Enum.PartType.Cylinder and part.Size.X <= 4))
                local precast = floorMarker and part.Parent == Workspace and part.Anchored and not part.CanCollide
                    and not part.CanQuery and not part.CanTouch and part.Material == Enum.Material.Neon and part.Size.Magnitude > 3
                if not (name:find("safespot") or name:find("safezone")) and (projectile or named or attributed or precast or damageContainer or protectorSmash or lineBox) then
                    local geometryPart = part
                    if part.Name == "precast" and part.Parent then
                        local hitbox = part.Parent:FindFirstChild("hitBox")
                        if hitbox and hitbox:IsA("BasePart") then geometryPart = hitbox end
                    end
                    local geometryVelocity = geometryPart.AssemblyLinearVelocity
                    if geometryVelocity.Magnitude < 1 then geometryVelocity = velocity end
                    local cylinder = geometryPart:IsA("Part") and geometryPart.Shape == Enum.PartType.Cylinder
                    local sphere = geometryPart:IsA("Part") and geometryPart.Shape == Enum.PartType.Ball
                    local shape = projectile and "Projectile" or (sphere and "Sphere" or (cylinder and "Cylinder" or "Block"))
                    local radialGrowth = 0
                    if shape == "Cylinder" and geometryPart.Size.X <= 4 then
                        local radius = math.max(geometryPart.Size.Y, geometryPart.Size.Z) * 0.5
                        if sample.lastRadius and sample.radiusAt and now > sample.radiusAt then
                            local increase = radius - sample.lastRadius
                            if increase > 0.05 then
                                local measured = math.clamp(increase / (now - sample.radiusAt), 0, 60)
                                sample.radialGrowth = sample.radialGrowth and sample.radialGrowth * 0.5 + measured * 0.5 or measured
                                sample.lastGrowthAt = now
                            elseif increase < -0.05 or now - (sample.lastGrowthAt or 0) > 0.25 then
                                sample.radialGrowth = 0
                            end
                        end
                        sample.lastRadius, sample.radiusAt = radius, now
                        radialGrowth = sample.radialGrowth or 0
                    end
                    local horizontal = Vector3.new(geometryVelocity.X, 0, geometryVelocity.Z)
                    local moving = sample.zone ~= nil and horizontal.Magnitude > 2 and horizontal.Magnitude < 160
                    sample.geometryPart = geometryPart
                    sample.zone = { frame = geometryPart.CFrame, size = geometryPart.Size, shape = shape,
                        velocity = geometryVelocity, moving = not projectile and moving, live = true,
                        radialGrowth = radialGrowth,
                        followPart = true,
                        lookahead = projectile and CFG.PROJECTILE_LOOKAHEAD or 0.5, id = part }
                    if protectorSmash then
                        local travel = 150 - part.Size.X
                        local humanoid = rootPart.Parent:FindFirstChildOfClass("Humanoid")
                        sample.zone = { frame = smashBox.CFrame, size = Vector3.new(150, 150, travel * 2 + 10),
                            shape = "ProtectorSmash", startWidth = part.Size.X, travelDistance = travel, id = part,
                            forecastAge = now - sample.createdAt, born = now, walkSpeed = humanoid and humanoid.WalkSpeed or 16,
                            followPart = false }
                        sample.geometryPart = nil
                    elseif lineBox then
                        sample.zone = { frame = lineBox.CFrame, size = lineBox.Size, shape = "Block",
                            id = part, kind = "AquaticDelayedLine", name = lineName, followPart = false }
                        sample.geometryPart = nil
                    end
                    sample.lastActive = now
                    table.insert(zones, sample.zone)
                elseif sample.zone and now - (sample.lastActive or 0) < 0.35 then
                    table.insert(zones, sample.zone)
                elseif now - sample.createdAt > CFG.THREAT_MAX_AGE and (not potential or attackMarker) then
                    threatParts[part] = nil
                end
                -- Homing/expanding rectangles: re-snapshot frame, size, and a
                -- speed-scaled lookahead every scan. Frozen snapshots go stale
                -- within a frame against parts that chase and grow.
                if sample.zone and sample.zone.live and sample.zone.followPart ~= false then
                    local geometryPart = sample.geometryPart and sample.geometryPart.Parent and sample.geometryPart or part
                    sample.zone.frame = geometryPart.CFrame
                    sample.zone.size = geometryPart.Size
                    sample.zone.velocity = geometryPart.AssemblyLinearVelocity
                    local hSpeed = Vector3.new(sample.zone.velocity.X, 0, sample.zone.velocity.Z).Magnitude
                    sample.zone.moving = hSpeed > 2 and hSpeed < 160
                    sample.zone.lookahead = math.clamp(hSpeed / 40, 0.5, 1.5)
                end
                sample.lastPosition, sample.lastAt = part.Position, now
            elseif now - sample.createdAt > CFG.THREAT_MAX_AGE and not sample.zone and not dangerousName(part) then
                threatParts[part] = nil
            end
        end
    end
    for _, zone in ipairs(zones) do
        zone.aimForecast, zone.aimOffset = nil, nil
    end
    observeAttackAim(zones, rootPart, now)
    forecastAttackAim(zones, rootPart)
    state.activeZones = zones
    refreshHazardSnapshot(rootPart, ThreatGeometry.risk(zones, rootPart.Position, CFG.HAZARD_MARGIN))
    for _, zone in ipairs(zones) do
        if not loggedThreats[zone.id] then
            loggedThreats[zone.id] = true
            local fp = zone.frame.Position
            logThreat("zone", {
                name = typeof(zone.id) == "Instance" and zone.id:GetFullName() or ("announced:" .. tostring(zone.name or zone.shape)),
                shape = zone.shape,
                zat = string.format("%d,%d,%d", math.floor(fp.X), math.floor(fp.Y), math.floor(fp.Z)),
                size = tostring(zone.size),
            })
        end
    end
end

local function crowdDistance(position)
    return math.min(28, enemyClearance(position) + math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22))
end

local function findEscapeGoal(rootPart, targetRoot)
    local params = buildRaycastParams(rootPart.Parent, targetRoot.Parent)
    params.RespectCanCollide = true
    local floor = Workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), params)
    if not floor then return nil end
    local candidates = {}
    local originalRisk, dangerZone = ThreatGeometry.risk(state.activeZones, rootPart.Position, CFG.HAZARD_MARGIN)
    local targetOffset = rootPart.Position - targetRoot.Position
    local targetRadial = Vector3.new(targetOffset.X, 0, targetOffset.Z)
    if targetRadial.Magnitude < 0.1 then targetRadial = Vector3.new(1, 0, 0) end
    targetRadial = targetRadial.Unit
    local memory = dangerZone and state.hazardMemory[hazardMemoryKey(dangerZone)]
    local preferredSide = learnedEscapeSide(memory, state.dodgeSide)
    local orbitDirection = Vector3.new(-targetRadial.Z, 0, targetRadial.X) * preferredSide
    local originalTargetDistance = Vector3.new(targetOffset.X, 0, targetOffset.Z).Magnitude
    local function combatShapeScore(candidate)
        local candidateOffset = candidate - targetRoot.Position
        local targetDistance = Vector3.new(candidateOffset.X, 0, candidateOffset.Z).Magnitude
        local movement = candidate - rootPart.Position
        movement = Vector3.new(movement.X, 0, movement.Z)
        local orbitAlignment = movement.Magnitude > 0.1 and movement.Unit:Dot(orbitDirection) or 0
        local outward = math.max(0, targetDistance - originalTargetDistance)
        local desiredError = math.abs(targetDistance - CFG.COMBAT_DISTANCE)
        return orbitAlignment * 18 - outward * 24 - desiredError * 2, targetDistance
    end
    if targetRoot.Parent.Name == "Ancient Temple Protector" then
        local toward = targetRoot.Position - rootPart.Position
        toward = Vector3.new(toward.X, 0, toward.Z)
        local originalDistance = toward.Magnitude
        if originalDistance > 0.1 then
            toward = toward.Unit
            local lateral = Vector3.new(-toward.Z, 0, toward.X)
            local best, bestScore, bestSide
            local now = os.clock()
            state.protectorEscapeVisits = state.protectorEscapeVisits or {}
            for key, at in pairs(state.protectorEscapeVisits) do
                if now - at >= 12 then state.protectorEscapeVisits[key] = nil end
            end
            for _, radius in ipairs({ 5, 10, 18 }) do
                for _, angle in ipairs({ math.pi / 6, math.pi / 3, math.pi / 2, math.pi * 2 / 3, math.pi }) do
                    for _, side in ipairs({ preferredSide, -preferredSide }) do
                        local candidate = rootPart.Position + (toward * math.cos(angle) + lateral * math.sin(angle) * side) * radius
                        local offset = candidate - targetRoot.Position
                        local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
                        local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                        local progress = originalDistance - distance
                        local key = math.floor(candidate.X / 6) .. ":" .. math.floor(candidate.Z / 6)
                        local score = -risk * 1000 + progress * 10 - radius
                            + (side == state.protectorOrbitSide and 1 or 0)
                            - (state.protectorEscapeVisits[key] and 150 or 0)
                        if distance >= CFG.COMBAT_MIN_DISTANCE
                            and (originalRisk == 0 and risk == 0 or risk < originalRisk - 0.1)
                            and (not bestScore or score + 80 > bestScore)
                            and safeEnemyStep(rootPart.Position, candidate)
                            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
                            and walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor) then
                            local exits = 0
                            for _, direction in ipairs({ toward, -toward, lateral, -lateral }) do
                                local exit = candidate + direction * 6
                                local support = Workspace:Raycast(exit + Vector3.new(0, 3, 0), Vector3.new(0, -9, 0), params)
                                if support and support.Normal.Y >= 0.55
                                    and not Workspace:Raycast(candidate, direction * 6, params)
                                    and ThreatGeometry.segmentSafe(state.activeZones, candidate, exit, CFG.HAZARD_MARGIN) then
                                    exits = exits + 1
                                end
                            end
                            score = score + exits * 20
                            if not bestScore or score > bestScore then
                                best, bestScore, bestSide = candidate, score, side
                            end
                        end
                    end
                end
            end
            if best then
                state.protectorOrbitSide = bestSide
                state.protectorEscapeVisits[math.floor(best.X / 6) .. ":" .. math.floor(best.Z / 6)] = now
                return best
            end
        end
    end
    local originalCrowd = crowdDistance(rootPart.Position)
    local originalDist = (rootPart.Position - targetRoot.Position).Magnitude
    local isProt = targetRoot.Parent and targetRoot.Parent.Name == "Ancient Temple Protector"
    -- Young smash corridors: exit strictly sideways. Generic gradient steps
    -- waste the ~1s windup on diagonals that never leave the corridor.
    do
        local need, lateral
        for _, activeZone in ipairs(state.activeZones) do
            local exitNeed, exitDir = ThreatGeometry.smashExit(activeZone, rootPart.Position, CFG.HAZARD_MARGIN)
            if exitNeed and (not need or exitNeed < need) then need, lateral = exitNeed, exitDir end
        end
        if need and lateral then
            for _, extra in ipairs({ 2, 6, 10 }) do
                for _, dir in ipairs({ lateral, -lateral }) do
                    local candidate = groundPosition(rootPart.Position + dir * (need + extra), rootPart.Parent, targetRoot.Parent)
                    if safeEnemyStep(rootPart.Position, candidate)
                        and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
                        and walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor) then
                        return candidate
                    end
                end
            end
        end
    end
    -- Moving first-boss corridors need a perpendicular escape. Treating a
    -- projectile path like a radial zone can send the player along its lane,
    -- especially when a beam or slam is active at the same time.
    do
        local initialRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2)
        local playerHumanoid = rootPart.Parent:FindFirstChildOfClass("Humanoid")
        local walkSpeed = math.max(1, playerHumanoid and playerHumanoid.WalkSpeed or 16)
        local severeNonProjectile = false
        for _, activeZone in ipairs(state.activeZones) do
            if activeZone.shape ~= "Projectile"
                and ThreatGeometry.clearance(activeZone, rootPart.Position, 2) < -1 then
                severeNonProjectile = true
                break
            end
        end
        local best, bestScore
        for _, activeZone in ipairs(state.activeZones) do
            if not severeNonProjectile and activeZone.shape == "Projectile" then
                local velocity = activeZone.velocity or Vector3.zero
                local lateral = Vector3.new(-velocity.Z, 0, velocity.X)
                if lateral.Magnitude > 0.1 then
                    lateral = lateral.Unit
                    for _, side in ipairs({ 1, -1 }) do
                        for _, distance in ipairs({ 8, 14, 20, 28, 36 }) do
                            local candidate = groundPosition(rootPart.Position + lateral * side * distance,
                                rootPart.Parent, targetRoot.Parent)
                            if walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor)
                                and safeEnemyStep(rootPart.Position, candidate)
                                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, 2) then
                                local arrival = math.min(1.5, distance / walkSpeed)
                                local survivalRisk = math.max(
                                    ThreatGeometry.risk(state.activeZones, candidate, 2),
                                    ThreatGeometry.risk(state.activeZones, candidate, 2, arrival))
                                local comfortRisk = math.max(
                                    ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN),
                                    ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN, arrival))
                                local targetDistance = (candidate - targetRoot.Position).Magnitude
                                local moveSide = (candidate - rootPart.Position):Dot(
                                    Vector3.new(-targetRadial.Z, 0, targetRadial.X)) >= 0 and 1 or -1
                                local score = survivalRisk * 10000 + comfortRisk * 100 + distance
                                    + math.max(0, targetDistance - math.max(CFG.ATTACK_RANGE, originalTargetDistance + 6)) * 80
                                    + (moveSide == preferredSide and 0 or 15)
                                if survivalRisk < initialRisk - 0.1
                                    and (not bestScore or score < bestScore) then
                                    best, bestScore = candidate, score
                                end
                            end
                        end
                    end
                end
            end
        end
        if best and not severeNonProjectile then return best, 2, "Crossing projectile corridor" end
    end
    -- Circular ground telegraphs need a radial exit before a line exit. In
    -- Northern Lands several rings can overlap; a perpendicular line escape
    -- may reduce one lane while leaving the player inside the ring stack.
    do
        local exits = {}
        for _, activeZone in ipairs(state.activeZones) do
            local near, nearDirection, far, farDirection = ThreatGeometry.circleExits(
                activeZone, rootPart.Position, CFG.HAZARD_MARGIN
            )
            if near then
                table.insert(exits, { distance = near + 4, direction = nearDirection })
                table.insert(exits, { distance = far + 4, direction = farDirection })
            end
        end
        local best, bestScore
        local initialRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2)
        local hasImmediateLine = false
        for _, activeZone in ipairs(state.activeZones) do
            local near = ThreatGeometry.lineExits(activeZone, rootPart.Position, CFG.HAZARD_MARGIN)
            if near then hasImmediateLine = true; break end
        end
        for _, exit in ipairs(exits) do
            for _, extra in ipairs({ 0, 6, 12 }) do
                local distance = math.min(40, exit.distance + extra)
                local candidate = groundPosition(rootPart.Position + exit.direction * distance,
                    rootPart.Parent, targetRoot.Parent)
                if walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor)
                    and safeEnemyStep(rootPart.Position, candidate)
                    and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, 2) then
                    local survivalRisk = ThreatGeometry.risk(state.activeZones, candidate, 2)
                    local comfortRisk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                    local shapeScore, targetDistance = combatShapeScore(candidate)
                    local score = survivalRisk * 10000 + comfortRisk * 100 + distance - shapeScore
                        + math.max(0, targetDistance - math.max(CFG.ATTACK_RANGE, originalTargetDistance + 4)) * 500
                    if (survivalRisk < initialRisk - 0.1 or initialRisk == 0)
                        and (not bestScore or score < bestScore) then
                        best, bestScore = candidate, score
                    end
                end
            end
        end
        -- Do not accept a single-circle exit while multiple rings overlap the
        -- current area. The joint scorer below must get first choice in that
        -- case, otherwise a plausible edge from ring A can remain inside
        -- ring B and recreate the Northern Lands boss failure.
        local overlappingRadials = initialRisk > 0 and (#exits > 1 or #state.activeZones > 1)
        if best and not hasImmediateLine and not overlappingRadials then return best, 2, "Exiting radial attack" end

        -- When circles overlap, every single-circle exit can still land in a
        -- neighboring ring. If the player is already exposed, choose the
        -- reachable point with the lowest combined exposure instead of
        -- repeatedly committing to the first ring's edge. This is a walk
        -- fallback, not a teleport: the normal 8-stud blink and rolling
        -- dodge budget remain enforced by dodgeAlongEscape.
        if initialRisk > 0 and not hasImmediateLine then
            local overlapBest, overlapScore
            for _, radius in ipairs({ 8, 14, 20, 28, 36, 40 }) do
                for index = 0, 15 do
                    local angle = index * math.pi / 8
                    local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
                    local candidate = groundPosition(rootPart.Position + direction * radius,
                        rootPart.Parent, targetRoot.Parent)
                    if walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor)
                        and safeEnemyStep(rootPart.Position, candidate) then
                        local survivalRisk = ThreatGeometry.risk(state.activeZones, candidate, 2)
                        local comfortRisk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                        local peakRisk, routeRisk = initialRisk, 0
                        for sample = 1, 8 do
                            local sampleRisk = ThreatGeometry.risk(state.activeZones,
                                rootPart.Position:Lerp(candidate, sample / 8), 2)
                            peakRisk = math.max(peakRisk, sampleRisk)
                            routeRisk = routeRisk + sampleRisk
                        end
                        local shapeScore, targetDistance = combatShapeScore(candidate)
                        local severeOverlap = initialRisk > 4
                        local leashPenalty = severeOverlap and 80 or 500
                        local score = survivalRisk * 10000 + peakRisk * 700
                            + routeRisk * 80 + comfortRisk * 40 + radius - shapeScore
                            + math.max(0, targetDistance - math.max(CFG.ATTACK_RANGE, originalTargetDistance + 6)) * leashPenalty
                        if survivalRisk < initialRisk - 0.1
                            and (not overlapScore or score < overlapScore) then
                            overlapBest, overlapScore = candidate, score
                        end
                    end
                end
            end
            if overlapBest then return overlapBest, 2, "Leaving overlapping radial attacks" end
        end
        if best and not hasImmediateLine then return best, 2, "Exiting radial attack" end
    end
    -- Long rectangular attacks (Northern Mage shots, spearman strikes, boss
    -- beams, and equivalent attacks on other maps) must be crossed sideways.
    -- Test both edges because overlapping lanes can make the nearest edge the
    -- worse one.  A small survival margin permits leaving an overlap without
    -- accepting a path that enters a new attack.
    do
        local exits = {}
        for _, activeZone in ipairs(state.activeZones) do
            local near, nearDirection, far, farDirection = ThreatGeometry.lineExits(
                activeZone, rootPart.Position, CFG.HAZARD_MARGIN
            )
            if near then
                table.insert(exits, { distance = near + 4, direction = nearDirection })
                table.insert(exits, { distance = far + 4, direction = farDirection })
            end
        end
        local best, bestScore, fallback, fallbackScore
        local initialSurvivalRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2)
        for _, exit in ipairs(exits) do
            for _, extra in ipairs({ 0, 6, 12 }) do
                local distance = math.min(40, exit.distance + extra)
                local candidate = groundPosition(rootPart.Position + exit.direction * distance,
                    rootPart.Parent, targetRoot.Parent)
                if walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor)
                    and safeEnemyStep(rootPart.Position, candidate) then
                    local survivalRisk = ThreatGeometry.risk(state.activeZones, candidate, 2)
                    local comfortRisk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                    local shapeScore, targetDistance = combatShapeScore(candidate)
                    local score = survivalRisk * 10000 + comfortRisk * 100 + distance - shapeScore
                        + math.max(0, targetDistance - math.max(CFG.ATTACK_RANGE, originalTargetDistance + 4)) * 500
                    if ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, 2)
                        and (not bestScore or score < bestScore) then
                        best, bestScore = candidate, score
                    end
                    -- Crossing grids can make every perpendicular route brush
                    -- another already active strip.  Still choose a committed
                    -- exit instead of falling back to a five-stud radial move.
                    -- Penalize exposure sampled along the route so this is
                    -- used only when no fully clear lateral crossing exists.
                    local peakRisk, accumulatedRisk = initialSurvivalRisk, 0
                    for sample = 1, 8 do
                        local sampleRisk = ThreatGeometry.risk(state.activeZones,
                            rootPart.Position:Lerp(candidate, sample / 8), 2)
                        peakRisk = math.max(peakRisk, sampleRisk)
                        accumulatedRisk = accumulatedRisk + sampleRisk
                    end
                    local fallbackCandidateScore = survivalRisk * 10000 + peakRisk * 1000
                        + accumulatedRisk * 100 + comfortRisk * 10 + distance - shapeScore
                        + math.max(0, targetDistance - math.max(CFG.ATTACK_RANGE, originalTargetDistance + 7)) * 500
                    if not fallbackScore or fallbackCandidateScore < fallbackScore then
                        fallback, fallbackScore = candidate, fallbackCandidateScore
                    end
                end
            end
        end
        if best then return best, 2, "Crossing out of line attack" end
        if fallback then return fallback, 2, "Crossing overlapping line attacks" end
    end
    if originalRisk > 0 and state.safeSpots and #state.safeSpots > 0 then
        local bestSpot, bestSpotDist
        for _, spot in ipairs(state.safeSpots) do
            local dist = (spot - rootPart.Position).Magnitude
            local spotTargetDistance = (spot - targetRoot.Position).Magnitude
            if dist <= 80 and (not bestSpotDist or dist < bestSpotDist)
                and spotTargetDistance <= math.max(CFG.ATTACK_RANGE, originalTargetDistance + 4)
                and ThreatGeometry.risk(state.activeZones, spot, CFG.HAZARD_MARGIN) == 0
                and safeEnemyStep(rootPart.Position, spot)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, spot, CFG.HAZARD_MARGIN)
                and walkingSegmentClear(rootPart, spot, targetRoot.Parent, params, floor) then
                bestSpot, bestSpotDist = spot, dist
            end
        end
        if bestSpot then return bestSpot end
    end
    local crowdLimit = math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22)
    local radii = originalRisk > 0 and { 5, 10, 18, 28, 40 } or { 3, 8, 14 }
    local angleSteps = 16
    for _, radius in ipairs(radii) do
        for i = 0, angleSteps - 1 do
            local angle = i * math.pi * 2 / angleSteps
            local candidate = rootPart.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            do
                -- Keep every combat escape on a tight target-centered leash.
                -- A few studs of outward travel are allowed to clear a body,
                -- but repeated hazards cannot walk the character to a wall.
                local targetDistance = (candidate - targetRoot.Position).Magnitude
                local backLimit = math.max(CFG.COMBAT_DISTANCE + 6,
                    originalDist + (originalDist > CFG.ATTACK_RANGE and 1 or 4))
                local backOk = targetDistance <= backLimit
                local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                local crowd = crowdDistance(candidate)
                local hazardClearance = 12
                for _, activeZone in ipairs(state.activeZones) do
                    hazardClearance = math.min(hazardClearance, ThreatGeometry.clearance(activeZone, candidate, CFG.HAZARD_MARGIN))
                end
                local crowdOk = originalRisk > 0 and crowd >= originalCrowd - 0.5
                    or (originalCrowd >= crowdLimit and not state.retreating)
                    or crowd > originalCrowd + 0.25
                if backOk and (originalRisk == 0 or risk < originalRisk - 0.1) and crowdOk then
                    local desiredDistance = CFG.COMBAT_DISTANCE + (state.retreating and CFG.RETREAT_RELEASE_MARGIN or 0)
                    local shapeScore = combatShapeScore(candidate)
                    local score = -risk * 1000 + math.min(hazardClearance, 12) + math.min(crowd, 28)
                        - radius * 2 - math.abs(targetDistance - desiredDistance)
                        - math.max(0, targetDistance - CFG.ATTACK_RANGE) * 4
                        + shapeScore
                    if isProt then
                        -- Dodge FORWARD, never back: reward closing on the
                        -- boss, punish backing off. Retreating from the
                        -- Protector just sets up the next volley at range.
                        score = score + math.max(0, originalDist - targetDistance) * 8
                            - math.max(0, targetDistance - originalDist) * 12
                    end
                    table.insert(candidates, { position = candidate, score = score, risk = risk, radius = radius })
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local checked = {}
    local function valid(entry)
        checked[entry] = true
        local candidate = entry.position
        if safeEnemyStep(rootPart.Position, candidate)
            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
            and walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor) then
            return candidate
        end
    end
    for i = 1, math.min(16, #candidates) do
        local candidate = valid(candidates[i])
        if candidate then return candidate end
    end
    -- Clear endpoints can all be unreachable inside overlapping attacks.
    -- Reserve bounded checks for short steps that reduce current exposure.
    if originalRisk > 0 then
        table.sort(candidates, function(a, b)
            if a.radius ~= b.radius then return a.radius < b.radius end
            return a.risk < b.risk
        end)
        local attempts = 0
        for _, entry in ipairs(candidates) do
            if not checked[entry] then
                attempts = attempts + 1
                local candidate = valid(entry)
                if candidate then return candidate end
                if attempts >= 16 then break end
            end
        end
    end
    return nil
end

local function findLeastBadStep(rootPart, target)
    -- No fully safe route exists. Standing still inside an active hitbox is
    -- the worst option, so walk the reachable step with the lowest exposure.
    -- Scores with a body-radius survival margin (2) instead of the comfort
    -- margin: corridor blankets can still hold tight safe cells that the
    -- planning margin would erase. Teleports keep their strict checks; only
    -- the walk relaxes.
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    -- Anchor escapes to the boss: without a distance term the gradient walks
    -- away from everything, backing out of DPS range forever. Penalize steps
    -- that leave a 34-stud leash on the target.
    local bossPosition
    if target and target.Parent then
        local bossRoot = getRootPart(target)
        if bossRoot then bossPosition = bossRoot.Position end
    end
    local originalLbDist = (bossPosition and (rootPart.Position - bossPosition).Magnitude) or nil
    local radial, tangent
    if bossPosition and originalLbDist and originalLbDist > 0.1 then
        radial = Vector3.new(rootPart.Position.X - bossPosition.X, 0, rootPart.Position.Z - bossPosition.Z).Unit
        tangent = Vector3.new(-radial.Z, 0, radial.X) * state.dodgeSide
    end
    local best, bestScore
    for _, radius in ipairs({ 3, 6, 10 }) do
        for index = 0, 15 do
            local angle = index * math.pi / 8
            local candidate = rootPart.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            if walkingSegmentClear(rootPart, candidate, target, params)
                and safeEnemyStep(rootPart.Position, candidate) then
                local risk = ThreatGeometry.risk(state.activeZones, candidate, 2)
                local score = risk * 1000 + radius
                if bossPosition and originalLbDist then
                    local candDist = (candidate - bossPosition).Magnitude
                    local movement = candidate - rootPart.Position
                    movement = Vector3.new(movement.X, 0, movement.Z)
                    local alignment = tangent and movement.Magnitude > 0.1 and movement.Unit:Dot(tangent) or 0
                    score = score + math.max(0, candDist - originalLbDist) * 50
                        + math.abs(candDist - CFG.COMBAT_DISTANCE) * 3 - alignment * 12
                end
                if not bestScore or score < bestScore then best, bestScore = candidate, score end
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
            if ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN) == 0
                and safeEnemyStep(rootPart.Position, candidate)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
                and walkingSegmentClear(rootPart, candidate, target, params) then
                return candidate
            end
        end
    end
    return nil
end

local function threatIsSmash(threat)
    if typeof(threat) == "string" then
        return threat:find("smash", 1, true) ~= nil or threat:find("windup", 1, true)
    end
    for _, zone in ipairs(state.activeZones) do
        if zone.id == threat and zone.shape == "ProtectorSmash" then return true end
    end
    return false
end

local function canTeleportDodge(now, distance, threat, exposed)
    local history = state.dodgeHistory
    while history[1] and now - history[1].at >= CFG.DODGE_WINDOW do table.remove(history, 1) end
    if not distance or distance < 0.1 or distance > CFG.DODGE_LATERAL_DISTANCE + 0.001 then return false end
    if #history >= CFG.DODGE_MAX_PER_WINDOW then return false end
    if history[#history] and now - history[#history].at < CFG.DODGE_COOLDOWN then return false end
    local previous = state.dodgedThreats[threat]
    -- A persistent attack may need a second bounded step if the first leaves
    -- the character exposed; otherwise avoid spending budget on the same ID.
    if previous and now - previous < (exposed and 0.6 or CFG.DODGE_SAME_THREAT_COOLDOWN) then return false end
    local spent = 0
    for _, entry in ipairs(history) do spent = spent + entry.distance end
    -- Reserve a full blink for smash windups: anything else may only spend
    -- what leaves 8 studs of budget. Gridshot clips are survivable; the slam
    -- is not, and a dry budget at windup time is death.
    if not threatIsSmash(threat) and spent + distance > CFG.DODGE_DISTANCE_BUDGET - 8 then
        return false
    end
    return spent + distance <= CFG.DODGE_DISTANCE_BUDGET + 0.001
end

local function effectiveSpellRange(profile)
    -- Positive game metadata is authoritative; the UI value fills only unknown ranges.
    return profile.range or (CFG.SPELL_RANGE_OVERRIDE > 0 and CFG.SPELL_RANGE_OVERRIDE) or 26
end

local function performDodgeTeleport(humanoid, rootPart, destination, target, threat, now)
    if not destination or humanoid.FloorMaterial == Enum.Material.Air then return false end
    local delta = destination - rootPart.Position
    local exposed = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2) > 0
    if not canTeleportDodge(now, delta.Magnitude, threat, exposed) then return false end
    if not safeEnemyStep(rootPart.Position, destination) then return false end
    if not walkingSegmentClear(rootPart, destination, target) then return false end
    local currentRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2)
    local destinationRisk = ThreatGeometry.risk(state.activeZones, destination, 2)
    local hazardThreat = threat ~= nil and not (typeof(threat) == "Instance" and threat:IsA("Model"))
    -- A blink is specifically for leaving an already-overlapping attack, so
    -- the swept segment may cross that attack. Prefer a clear landing cell,
    -- but when a large expanding zone fills the whole 8-stud step, allow a
    -- strictly lower combined exposure cell so the next bounded dodge can
    -- finish the exit. Never blink into equal or worse exposure.
    if destinationRisk > 0 and destinationRisk >= currentRisk - 0.5 then return false end
    if currentRisk == 0
        and not ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, destination, CFG.HAZARD_MARGIN)
        and not (hazardThreat and destinationRisk == 0) then
        return false
    end
    -- Check several body-width rays before applying the bounded horizontal step.
    for _, offset in ipairs({ Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }) do
        if hasBlockingRay(rootPart.Position + offset, destination + offset, rootPart.Parent, target) then return false end
    end
    rootPart.CFrame = rootPart.CFrame + delta
    table.insert(state.dodgeHistory, { at = now, distance = delta.Magnitude })
    if threat ~= nil then state.dodgedThreats[threat] = now end
    logThreat("tp", { distance = math.floor(delta.Magnitude * 10) / 10 })
    state.lastDodgeTime = now
    state.safetyUntil = now + 0.75
    state.dodgeCount = state.dodgeCount + 1
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
    if profile.mode == "buff" then
        return #state.nearbyEnemies > 0 or state.retreating or state.motionMode == "evade"
            or state.motionMode == "safety-hold" or state.lastThreatPart ~= nil
    end
    if profile.mode == "self" then
        for _, enemy in ipairs(state.nearbyEnemies) do
            if isValidTarget(enemy.model) and AttackPolicy.damageable(enemy.model)
                and not hasBlockingRay(rootPart.Position, enemy.root.Position, rootPart.Parent, enemy.model)
                and (enemy.root.Position - rootPart.Position).Magnitude <= (profile.radius or profile.range or CFG.CLOSE_AOE_RANGE) then
                return true
            end
        end
        return false
    end
    local target = state.currentTarget
    local targetRoot = target and getRootPart(target)
    return isValidTarget(target) and AttackPolicy.damageable(target) and targetRoot ~= nil
        and AttackPolicy.canHit(profile, rootPart.Position, targetRoot.Position, effectiveSpellRange(profile),
            function(origin, destination) return hasBlockingRay(origin, destination, rootPart.Parent, target) end)
end

local function prepareSpell(_, snapshot)
    local character, humanoid, rootPart = getChar()
    if not character or not humanoid or not rootPart then return false end
    if not spellUsable(snapshot, rootPart) then return false, "no damageable target in spell reach" end
    local profile = FarmPlanner.profile(snapshot)
    if profile.geometry == "forwardBurst" then
        local target = state.currentTarget
        local targetRoot = target and getRootPart(target)
        if not targetRoot then return false end
        state.castAimTarget, state.castAimUntil, state.groupCount = target, os.clock() + 0.35, 1
        faceEnemy(humanoid, rootPart, targetRoot)
        -- AlignOrientation takes time to turn. Recheck the actual facing before
        -- activation so the forward burst is not fired behind the boss.
        local aligned = AttackPolicy.canHit(profile, rootPart.Position, targetRoot.Position,
            effectiveSpellRange(profile), nil, rootPart.CFrame.LookVector)
        if not aligned then return false, "turning Geyser toward target" end
        return true
    end
    if not CFG.SMART_FARM then return true end
    if profile.mode == "target" and state.targetDist > effectiveSpellRange(profile) then return false end
    if profile.mode ~= "splash" then return true end
    local range, radius = effectiveSpellRange(profile), profile.radius or CFG.GROUP_RADIUS
    local now = os.clock()
    local plan = state.farmPlan
    if not plan or plan.spell ~= snapshot.name or plan.range ~= range or plan.radius ~= radius
        or now - plan.at >= 0.2 or not isValidTarget(plan.target) then
        local candidates = {}
        for _, model in ipairs(state.cachedTargets) do
            if isValidTarget(model) and AttackPolicy.damageable(model) then
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
    if not isValidTarget(target) or not AttackPolicy.damageable(target) then return false end
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
    if not CFG.AUTO_ABILITIES then state.castStatus = "abilities disabled"; return end
    local now = os.clock()
    local requested, reason = abilities.TryCast(now, CFG.SKILL_COOLDOWN, prepareSpell)
    state.castStatus = reason
    if requested then state.lastSkillTime = now end
end

local function stopMovement(humanoid, rootPart)
    state.adaptiveLocalAttempt = nil
    if state.motionMode == "hold" and not state.motionGoal then return end
    humanoid:MoveTo(rootPart.Position)
    state.motionMode = "hold"
    state.motionGoal = nil
    state.fallbackGoal, state.fallbackUntil = nil, 0
    clearPath()
end

-- Protector windup tell: hands rest at body level; a fast raise starts the
-- smash volley. A freshly started animation track on the boss counts too.
-- So does the boss snapping to face the player (the slam aims at whoever it
-- faces). Returns true on the tick the tell is detected.
local function protectorWindup(target, targetRoot, rootPart, now)
    if not target or target.Name ~= "Ancient Temple Protector" then
        state.windHands, state.windTracks, state.faceHist = nil, nil, nil
        return false
    end
    local humanoid = target:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if animator then
        local seen, fresh, nowSeen = state.windTracks, false, {}
        local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
        if ok and tracks then
            for _, track in ipairs(tracks) do
                local id = (track.Animation and track.Animation.AnimationId) or track.Name
                nowSeen[id] = true
                if not (seen and seen[id]) then fresh = true end
            end
        end
        state.windTracks = nowSeen
        if fresh and seen then return true end
    end
    -- Facing snap: the slam aims at whoever it faces. Was looking away
    -- (>40deg sometime in the last 1.2s), now dead-on (<15deg).
    if targetRoot and rootPart then
        local facing = targetRoot.CFrame.LookVector
        facing = Vector3.new(facing.X, 0, facing.Z)
        local toPlayer = rootPart.Position - targetRoot.Position
        toPlayer = Vector3.new(toPlayer.X, 0, toPlayer.Z)
        if facing.Magnitude > 0.01 and toPlayer.Magnitude > 0.01 then
            local ang = math.acos(math.clamp(facing.Unit:Dot(toPlayer.Unit), -1, 1))
            local hist = state.faceHist or {}
            table.insert(hist, { at = now, ang = ang })
            while hist[1] and now - hist[1].at > 1.2 do table.remove(hist, 1) end
            state.faceHist = hist
            local was = math.huge
            for _, h in ipairs(hist) do was = math.min(was, h.ang) end
            if ang < 0.26 and was > 0.7 then return true end
        end
    end
    local left = target:FindFirstChild("leftHandModel")
    local right = target:FindFirstChild("rightHandModel")
    if not (left and right) then return false end
    local ly, ry
    pcall(function()
        ly = left:GetPivot().Position.Y
        ry = right:GetPivot().Position.Y
    end)
    if not (ly and ry) then return false end
    local sample = state.windHands
    state.windHands = { at = now, ly = ly, ry = ry }
    if not sample then return false end
    local dt = now - sample.at
    if dt < 0.12 or dt > 2.0 then return false end
    return math.max(ly - sample.ly, ry - sample.ry) > 4
end

local function meleeThreat(rootPart)    local threat, closest = nil, math.huge
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

local function dodgeAlongEscape(humanoid, rootPart, goal, target, threat, now, forceBlink)
    if not threat then return end
    local delta = goal - rootPart.Position
    if delta.Magnitude < 0.5 then return end
    local step = rootPart.Position + delta.Unit * math.min(CFG.DODGE_LATERAL_DISTANCE, delta.Magnitude)
    if not forceBlink and enemyClearance(step) <= enemyClearance(rootPart.Position)
        and typeof(threat) == "Instance" and threat:IsA("Model") then return end
    -- Teleport budget is normally reserved for telegraphed attacks. A
    -- confirmed melee contact may use one bounded blink too, but only after
    -- forceSeparationGoal has validated the short lateral destination.
    local telegraphed = not (typeof(threat) == "Instance" and threat:IsA("Model"))
    -- Favor confirmed overlaps and smash windups, while allowing a short
    -- telegraphed escape to blink if the bounded landing cell passes checks.
    local currentRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, 0)
    local smashThreat = typeof(threat) == "string"
        and (threat:find("smash", 1, true) ~= nil or threat:find("windup", 1, true) ~= nil)
    local urgent = currentRisk > 0 or smashThreat
    -- A validated hazard escape may need to cross the edge of a line or ring
    -- before the walking controller can clear it. Use one bounded blink for
    -- that preemptive crossing when the landing cell is clear; the teleport
    -- function still enforces the 8-stud limit, wall checks, and budget.
    local shouldBlink = forceBlink and (urgent or telegraphed) or telegraphed and delta.Magnitude > 4
    if CFG.TELEPORT_DODGE and shouldBlink then
        performDodgeTeleport(humanoid, rootPart, step, target, threat, now)
    end
end

-- Protector separation goes sideways, never backward. Radial escapes back
-- the bot into the arena pit/edge and strand every fight at range, which is
-- exactly where the slam one-shots it.
local function protectorLateralSeparation(rootPart, targetRoot, target)
    local away = Vector3.new(rootPart.Position.X - targetRoot.Position.X, 0, rootPart.Position.Z - targetRoot.Position.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) else away = away.Unit end
    local tangent = Vector3.new(-away.Z, 0, away.X)
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    local ground = Workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), params)
    if not ground then return nil end
    local best, bestScore
    for _, side in ipairs({ 1, -1 }) do
        for _, distance in ipairs({ 6, 10 }) do
            local candidate = groundPosition(rootPart.Position + tangent * side * distance, rootPart.Parent, target)
            if walkingSegmentClear(rootPart, candidate, target, params, ground)
                and safeEnemyStep(rootPart.Position, candidate)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN) then
                local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                local score = risk * 1000 + distance
                if not bestScore or score < bestScore then best, bestScore = candidate, score end
            end
        end
    end
    return best
end

local function forceSeparationGoal(rootPart, targetRoot, target)
    local away = Vector3.new(rootPart.Position.X - targetRoot.Position.X, 0, rootPart.Position.Z - targetRoot.Position.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) else away = away.Unit end
    local tangent = Vector3.new(-away.Z, 0, away.X)
    local params = buildRaycastParams(rootPart.Parent, target)
    local originalDistance = (rootPart.Position - targetRoot.Position).Magnitude
    local best, bestScore, bestSide
    for _, side in ipairs({ state.dodgeSide, -state.dodgeSide }) do
        -- Mostly tangent with only enough outward motion to break body contact.
        -- This keeps the fight centered instead of retreating toward a wall.
        local direction = (tangent * side + away * 0.22).Unit
        for _, distance in ipairs({ 5, 8, 12, 16 }) do
            local candidate = groundPosition(rootPart.Position + direction * distance, rootPart.Parent, target)
            if walkingSegmentClear(rootPart, candidate, target, params)
                and safeEnemyStep(rootPart.Position, candidate)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN) then
                local candidateDistance = (candidate - targetRoot.Position).Magnitude
                local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                local score = risk * 1000 + math.max(0, candidateDistance - originalDistance) * 30
                    + math.abs(candidateDistance - CFG.COMBAT_DISTANCE) * 2 + distance
                    + (side == state.dodgeSide and 0 or 18)
                if not bestScore or score < bestScore then
                    best, bestScore, bestSide = candidate, score, side
                end
            end
        end
    end
    if bestSide then state.dodgeSide = bestSide end
    return best
end

local function shortEscapeGoal(rootPart, target, goal)
    local delta = goal - rootPart.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)
    if flat.Magnitude <= 12 then return goal, false end
    local startRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2)
    local best, bestScore, bestRisk
    for _, distance in ipairs({ 6, 8, 12 }) do
        local candidate = groundPosition(rootPart.Position + flat.Unit * distance, rootPart.Parent, target)
        if walkingSegmentClear(rootPart, candidate, target)
            and safeEnemyStep(rootPart.Position, candidate) then
            local risk = ThreatGeometry.risk(state.activeZones, candidate, 2)
            local score = risk - distance * 0.01
            if (startRisk > 0 or risk == 0) and (not bestScore or score < bestScore) then
                best, bestScore, bestRisk = candidate, score, risk
            end
        end
    end
    if not best or startRisk > 0 and bestRisk >= startRisk then
        local alternate = findLeastBadStep(rootPart, target)
        if alternate then
            local alternateRisk = ThreatGeometry.risk(state.activeZones, alternate, 2)
            if alternateRisk < (bestRisk or math.huge) then return alternate, startRisk > 0 end
        end
    end
    return best or goal, best ~= nil and startRisk > 0
end

local function trackEscapeChoice(rootPart, targetRoot, zone, goal, now)
    state.escapeThreatId = zone and zone.id or nil
    local radial = rootPart.Position - targetRoot.Position
    radial = Vector3.new(radial.X, 0, radial.Z)
    if radial.Magnitude <= 0.1 then return end
    local tangent = Vector3.new(-radial.Z, 0, radial.X).Unit
    local side = (goal - rootPart.Position):Dot(tangent) >= 0 and 1 or -1
    state.escapeSide, state.escapePlannedAt = side, now
    if zone then
        local key = hazardMemoryKey(zone)
        local learning = state.escapeLearning
        if not learning or learning.done or learning.key ~= key or learning.side ~= side
            or now - learning.at > 1.5 then
            state.escapeLearning = { key = key, id = zone.id, side = side, at = now,
                startPosition = rootPart.Position, startDamage = state.damageEvents, done = false }
        end
    end
end

local function updateEscapeLearning(rootPart, now)
    local learning = state.escapeLearning
    if not learning or learning.done or now - learning.at < 0.45 then return end
    if state.damageEvents ~= learning.startDamage then learning.done = true; return end
    if (rootPart.Position - learning.startPosition).Magnitude >= 3 then
        for _, zone in ipairs(state.activeZones) do
            if zone.id == learning.id
                and ThreatGeometry.clearance(zone, rootPart.Position, 2) > 2 then
                observeEscape(learning.key, learning.side, true)
                learning.done = true
                return
            end
        end
    end
    if now - learning.at > 1.5 then learning.done = true end
end


local function handleSafety(humanoid, rootPart, target, targetRoot, now)
    if not CFG.AUTO_DODGE then
        state.escapeGoal, state.lastThreatPart, state.movementBlocked, state.retreating = nil, nil, false, false
        return false
    end
    local hazardBonus = now - (state.hazardMarginBonusAt or 0) < 1.5 and (state.hazardMarginBonus or 0) or 0
    CFG.HAZARD_MARGIN = CFG.HAZARD_MARGIN_BASE
        + math.max(math.clamp(hazardBonus, 0, 8), learnedHazardMargin(rootPart.Position))
    updateEscapeLearning(rootPart, now)
    local risk, zone = ThreatGeometry.risk(state.activeZones, rootPart.Position, CFG.HAZARD_MARGIN)
    -- Forecast where the current MoveTo will carry the body in the next
    -- fraction of a second. The hazard geometry itself already projects
    -- moving hitboxes; this adds the character's own motion to the check.
    if #state.activeZones > 0 and risk == 0 then
        local velocity = rootPart.AssemblyLinearVelocity
        local movement = Vector3.new(velocity.X, 0, velocity.Z) * 0.35
        if state.motionMode ~= "hold" and now - state.lastMoveToCall < 0.5 then
            local toward = state.lastMoveToPosition - rootPart.Position
            toward = Vector3.new(toward.X, 0, toward.Z)
            if toward.Magnitude > 0.1 then
                movement = toward.Unit * math.min(toward.Magnitude, humanoid.WalkSpeed * 0.35)
            end
        end
        if movement.Magnitude > 0.5 then
            local predictedRisk, predictedZone = ThreatGeometry.risk(state.activeZones,
                rootPart.Position + movement, CFG.HAZARD_MARGIN)
            if predictedRisk > 0 then risk, zone = predictedRisk, predictedZone end
        end
    end
    -- Inspect the next movement segment, not a straight chord through all
    -- intervening rooms. The path may already go around the distant hazard.
    local waypoint = state.waypoints[state.currentWaypointIndex]
    local routeStep = state.fallbackGoal or (waypoint and waypoint.Position + Vector3.new(0, 2.5, 0))
        or state.motionGoal
    if routeStep then
        local delta = routeStep - rootPart.Position
        routeStep = delta.Magnitude >= 0.1 and rootPart.Position + delta.Unit * math.min(delta.Magnitude, 12) or nil
    end
    local routeThreat = routeStep and state.motionGoalMode == "map-route"
        and not ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, routeStep, CFG.HAZARD_MARGIN)
    state.lastThreatPart = zone and zone.id
    -- Jump-over: thin homing rectangles are cleared by leaving the ground as
    -- they pass under. Only when the zone top is within jump apex (~6 studs)
    -- so tall smash volumes never trigger it.
    if now - (state.lastJumpAt or -math.huge) >= 0.4 and humanoid.FloorMaterial ~= Enum.Material.Air then
        for _, activeZone in ipairs(state.activeZones) do
            if activeZone.live then
                local top = activeZone.frame.Position.Y + activeZone.size.Y * 0.5
                local groundCylinder = activeZone.shape == "Cylinder" and activeZone.size.X <= 4
                    and math.abs(activeZone.frame.Position.Y - rootPart.Position.Y) < 6
                if top - rootPart.Position.Y < 2 or groundCylinder then
                    local shouldJump = ThreatGeometry.clearance(activeZone, rootPart.Position, CFG.HAZARD_MARGIN) < 0
                        and ((activeZone.shape == "Block" and activeZone.size.Y <= 4)
                            or (activeZone.shape == "Cylinder" and activeZone.size.X <= 4))
                    local velocity = activeZone.velocity or Vector3.zero
                    local toPlayer = rootPart.Position - activeZone.frame.Position
                    if not shouldJump and velocity.Magnitude > 0.01 and toPlayer.Magnitude > 0.01 then
                        local closing = velocity:Dot(toPlayer.Unit)
                        local clearanceNow = ThreatGeometry.clearance(activeZone, rootPart.Position, 0)
                        shouldJump = closing > 4 and clearanceNow / closing < 0.4
                    end
                    if shouldJump then
                        humanoid.Jump = true
                        state.lastJumpAt = now
                        logThreat("jump", activeZone.shape or "?")
                        break
                    end
                end
            end
        end
    end
    local crowd = crowdDistance(rootPart.Position)
    local crowdLimit = math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22)
    local clearance = enemyClearance(rootPart.Position)
    local isProt = target.Name == "Ancient Temple Protector"
    -- No crowd-retreats against the Protector: backing off for spacing is
    -- what walks the fight backward into the pit and strands it at range.
    -- Zones and real contact still dodge; spacing alone never retreats.
    if clearance < 0 and not isProt then state.retreating = true
    elseif clearance >= CFG.RETREAT_RELEASE_MARGIN then state.retreating = false end
    local contactThreat = meleeThreat(rootPart)
    local contactDistance = (targetRoot.Position - rootPart.Position).Magnitude
    local inMeleeContact = contactThreat and (contactThreat == target or contactDistance <= CFG.MELEE_DANGER_DISTANCE)
    local meleeEscapeActive = state.escapeReason == "Breaking melee contact"
        and state.escapeGoal and now < (state.escapeUntil or 0)
    local hazardEscapeActive = state.escapeGoal and now < (state.escapeUntil or 0)
        and state.escapeReason ~= "Breaking melee contact"
    if meleeEscapeActive and (not inMeleeContact or risk > 0) then
        state.escapeGoal, state.escapeUntil, state.escapeReason = nil, 0, nil
        state.escapeClear, state.retreating = false, false
        meleeEscapeActive = false
    end
    if meleeEscapeActive and risk == 0 then
        if now - (state.lastEscapeCheck or 0) >= 0.2 then
            state.escapeClear = walkingSegmentClear(rootPart, state.escapeGoal, target)
                and safeEnemyStep(rootPart.Position, state.escapeGoal)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, state.escapeGoal, CFG.HAZARD_MARGIN)
            state.lastEscapeCheck = now
        end
        if state.escapeClear and (state.escapeGoal - rootPart.Position).Magnitude > 2 then
            state.retreating = true
            state.status = state.escapeReason
            dodgeAlongEscape(humanoid, rootPart, state.escapeGoal, target, contactThreat, now, true)
            issueMove(humanoid, state.escapeGoal, "evade", now, true)
            return true
        end
        state.escapeGoal, state.escapeUntil, state.escapeReason = nil, 0, nil
    end
    if inMeleeContact and risk == 0 and not hazardEscapeActive then
        local separation = nil
        if isProt then
            separation = protectorLateralSeparation(rootPart, targetRoot, target)
        else
            separation = forceSeparationGoal(rootPart, targetRoot, target)
        end
        state.retreating = true
        if separation then
            clearPath()
            state.escapeGoal, state.escapeUntil = separation, now + CFG.MELEE_ESCAPE_LEASE
            state.escapeMargin = CFG.HAZARD_MARGIN
            state.escapeStartRisk = risk
            state.escapeClear, state.lastEscapeCheck = true, now
            state.escapeReason = "Breaking melee contact"
            state.status = state.escapeReason
            logThreat("melee-escape", { distance = math.floor(contactDistance * 10) / 10 })
            dodgeAlongEscape(humanoid, rootPart, separation, target, contactThreat, now, true)
            issueMove(humanoid, separation, "evade", now, true)
            return true
        end
        -- A blocked backward step still permits a lateral escape search.
    end
    -- Smash response (Protector only): the slam is a full-arena expanding
    -- rectangle wall. Backing away corners you against the arena edge, so
    -- this does the opposite: phase 1 closes distance toward the boss while
    -- the rectangles are small, phase 2 strafes the side with more open
    -- space. Regular attacks keep the normal backward dodge below; only
    -- Smash behaves this way (attack-dependent dodge direction).
    if target.Name == "Ancient Temple Protector" then
        if protectorWindup(target, targetRoot, rootPart, now) then
            state.smashStrafeUntil = now + 2.2
            logThreat("windup", "smash")
        end
        if state.smashStrafeUntil and now < state.smashStrafeUntil then
            local away = Vector3.new(rootPart.Position.X - targetRoot.Position.X, 0, rootPart.Position.Z - targetRoot.Position.Z)
            local dist = away.Magnitude
            if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) else away = away.Unit end
            local goal
            if dist > 20 then
                -- Phase 1: close distance fast while rectangles are small.
                local toward = Vector3.new(-away.X, 0, -away.Z)
                goal = rootPart.Position + toward * math.min(14, dist - 14)
            else
                -- Phase 2: strafe whichever side has more open space.
                local tangent = Vector3.new(-away.Z, 0, away.X)
                local bestSide, bestScore
                for _, side in ipairs({ 1, -1 }) do
                    local probe = rootPart.Position + tangent * side * 12
                    local probeRisk = ThreatGeometry.risk(state.activeZones, probe, 2)
                    local wallParams = buildRaycastParams(rootPart.Parent, target)
                    wallParams.RespectCanCollide = true
                    local wall = Workspace:Raycast(rootPart.Position, tangent * side * 20, wallParams)
                    local score = probeRisk * 100 + (wall and (20 - (wall.Position - rootPart.Position).Magnitude) * 10 or 0)
                    if not bestScore or score < bestScore then
                        bestScore, bestSide = score, side
                    end
                end
                bestSide = bestSide or 1
                goal = rootPart.Position + tangent * bestSide * 14
            end
            goal = groundPosition(goal, rootPart.Parent, target)
            if walkingSegmentClear(rootPart, goal, target)
                and safeEnemyStep(rootPart.Position, goal) then
                clearPath()
                state.escapeGoal, state.escapeUntil = goal, now + 0.5
                state.escapeMargin = CFG.HAZARD_MARGIN
                state.escapeStartRisk = risk
                state.escapeReason = dist > 20 and "Closing on smash windup" or "Strafing smash by open space"
                state.status = state.escapeReason
                dodgeAlongEscape(humanoid, rootPart, goal, target, "smash", now, true)
                issueMove(humanoid, goal, "evade", now)
                return true
            end
            -- No valid smash goal: fall through to the regular escape logic.
        end
    end
    if state.blockedByHazard then
        state.escapeGoal = nil
        state.lastEscapePlan = -math.huge
    end
    local committedEscape = state.escapeGoal and now < (state.escapeCommitUntil or 0)
        and (state.escapeGoal - rootPart.Position).Magnitude > 2
    if risk == 0 and not committedEscape and not routeThreat and not state.retreating
        and not contactThreat and crowd >= crowdLimit
        and not state.movementBlocked and not state.blockedByHazard then
        state.escapeGoal, state.threatReactionAt = nil, nil
        return false
    end
    if routeThreat and risk == 0 then
        state.status = "Replanning route around active hazard"
        state.lastEscapePlan = -math.huge
    end
    if state.escapeGoal and now < (state.escapeUntil or 0) then
        if now - (state.lastEscapeCheck or 0) >= 0.2 then
            state.escapeClear = walkingSegmentClear(rootPart, state.escapeGoal, target)
            state.lastEscapeCheck = now
        end
        -- Keep the escape owner, but do not keep following an old route when
        -- a newly spawned attack becomes the nearest hazard. This matters for
        -- Northern Lands beam/radial overlaps: the radial exit may be valid
        -- when selected, then a beam can appear during its short commitment.
        -- Replanning here avoids handing movement back to pursuit while still
        -- reacting before the next damage window.
        if zone and state.escapeThreatId and zone.id ~= state.escapeThreatId and risk > 0 then
            state.escapeGoal = nil
            state.escapeThreatId = nil
            state.lastEscapePlan = -math.huge
        end
        -- A familiar attack can move or expand without changing its ID.
        -- Check the next walking step against the latest geometry so a
        -- committed route cannot carry us deeper into that same hitbox.
        if state.escapeGoal then
            local delta = state.escapeGoal - rootPart.Position
            if delta.Magnitude > 0.1 then
                local nextStep = rootPart.Position + delta.Unit * math.min(delta.Magnitude, humanoid.WalkSpeed * 0.25)
                local currentExposure = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2)
                local nextExposure = ThreatGeometry.risk(state.activeZones, nextStep, 2)
                if nextExposure > currentExposure + 0.1 then
                    state.escapeGoal = nil
                    state.lastEscapePlan = -math.huge
                end
            end
        end
        -- Commit to the escape walk: the plan was validated at selection and
        -- replans correct course within a fraction of a second. Re-validating
        -- strict per-tick checks is what used to freeze the character
        -- (safety-hold) inside resolving hitboxes. Only abort into something
        -- much worse than when the plan was made.
        local startRisk = state.escapeStartRisk or 0
        local riskEscalated = risk > startRisk + 2.5
        local postCommitRisk = now >= (state.escapeCommitUntil or 0) and risk > startRisk + 0.5
        if riskEscalated or postCommitRisk then
            state.escapeGoal = nil
            state.lastEscapePlan = -math.huge
        elseif state.escapeGoal and (state.escapeGoal - rootPart.Position).Magnitude > math.max(3, humanoid.WalkSpeed * 0.25)
            and state.escapeClear then
            local contMargin = state.escapeMargin or CFG.HAZARD_MARGIN
            -- Survival-margin escapes already accepted crossing exposure at
            -- selection time; re-validating the strict segment would jitter
            -- between cells instead of committing to the least-bad one.
            -- They also bypass issueMove's guards, which would otherwise
            -- freeze the walk mid-escape (safety-hold inside a hitbox).
            if now >= (state.escapeCommitUntil or 0) and contMargin >= CFG.HAZARD_MARGIN
                and not ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, state.escapeGoal, contMargin) then
                state.escapeGoal = nil
                state.lastEscapePlan = -math.huge
            else
            state.status = state.escapeReason or "Avoiding nearby enemies"
            dodgeAlongEscape(humanoid, rootPart, state.escapeGoal, target, zone and zone.id or contactThreat, now)
            issueMove(humanoid, state.escapeGoal, "evade", now, contMargin < CFG.HAZARD_MARGIN)
            return true
            end
        end
    end
    if state.escapeGoal and risk > 0 then state.lastEscapePlan = -math.huge end
    state.escapeGoal = nil
    if zone then
        state.threatReactionAt = state.threatReactionAt or now
        if now - state.threatReactionAt < CFG.REACTION_TIME then
            state.status = "Reacting to attack"
            return true
        end
    end
    if risk == 0 and now - state.lastEscapePlan < 0.12 then return true end
    state.lastEscapePlan = now
    local goal, escapeMargin, escapeReason = findEscapeGoal(rootPart, targetRoot)
    if not goal and (risk > 0 or state.blockedByHazard) then
        goal = findEmergencySideStep(rootPart, target)
    end
    state.movementBlocked, state.blockedByHazard = false, false
    if not goal then
        state.blockedByHazard = false
        if risk > 0 then
            local backup = findLeastBadStep(rootPart, target)
            if backup then
                clearPath()
                state.escapeGoal, state.escapeUntil = backup, now + 0.8
                state.escapeCommitUntil = now + 0.35
                state.escapeMargin = 2
                state.escapeStartRisk = risk
                state.escapeClear, state.lastEscapeCheck = true, now
                state.escapeReason = "Cutting through weakest exposure"
                state.status = state.escapeReason
                trackEscapeChoice(rootPart, targetRoot, zone, backup, now)
                logThreat("escape", state.escapeReason)
                dodgeAlongEscape(humanoid, rootPart, backup, target, zone and zone.id or contactThreat, now, true)
                issueMove(humanoid, backup, "evade", now, true)
                return true
            end
        end
        state.status = "Waiting for safe escape route"
        stopMovement(humanoid, rootPart)
        return true
    end
    local shortGoal, needsBypass = shortEscapeGoal(rootPart, target, goal)
    goal = shortGoal
    if needsBypass and not escapeMargin then escapeMargin = 2 end
    clearPath()
    state.motionGoal, state.fallbackGoal = nil, nil
    state.escapeGoal, state.escapeUntil = goal, now + 1.5
    state.escapeMargin = escapeMargin or CFG.HAZARD_MARGIN
    state.escapeCommitUntil = escapeMargin and now + 0.9 or now + 0.45
    state.escapeStartRisk = risk
    trackEscapeChoice(rootPart, targetRoot, zone, goal, now)
    state.escapeClear, state.lastEscapeCheck = true, now
    state.safetyUntil = now + 0.75
    dodgeAlongEscape(humanoid, rootPart, goal, target, zone and zone.id or contactThreat, now,
        escapeMargin ~= nil)
    state.escapeReason = escapeReason or (zone and "Escaping attack area" or "Avoiding nearby enemies")
    state.status = state.escapeReason
    logThreat("escape", state.escapeReason)
    issueMove(humanoid, goal, "evade", now, escapeMargin ~= nil)
    return true
end

local function northernMechanicIntent(humanoid, rootPart, target, targetRoot, now)
    local waypoint = state.waypoints[state.currentWaypointIndex]
    local profiles = {}
    for _, snapshot in pairs(abilities.Snapshot(now)) do table.insert(profiles, FarmPlanner.profile(snapshot)) end
    local previous = state.routeAnchors[math.max(1, state.routeAnchorIndex - 1)]
    local nextAnchor = state.routeAnchors[state.routeAnchorIndex]
    local rayParams = buildRaycastParams(rootPart.Parent, target)
    rayParams.RespectCanCollide = true
    return northernMechanics:Update({
        now = now,
        humanoid = humanoid,
        rootPart = rootPart,
        target = target,
        targetRoot = targetRoot,
        attackRange = CFG.ATTACK_RANGE,
        enemies = state.nearbyEnemies,
        roomEntry = previous and previous.part.Position,
        forward = previous and nextAnchor and (nextAnchor.part.Position - previous.part.Position),
        canAttack = function(position, model, enemyRoot)
            model, enemyRoot = model or target, enemyRoot or targetRoot
            if not enemyRoot or not AttackPolicy.damageable(model) then return false end
            for _, profile in ipairs(profiles) do
                if AttackPolicy.canHit(profile, position, enemyRoot.Position,
                    profile.mode == "self" and CFG.CLOSE_AOE_RANGE or effectiveSpellRange(profile),
                    function(a, b) return hasBlockingRay(a, b, rootPart.Parent, model) end) then return true end
            end
            return false
        end,
        wallPoint = function(center, direction)
            local origin = Vector3.new(center.X, rootPart.Position.Y, center.Z)
            local hit = Workspace:Raycast(origin, direction * 100, rayParams)
            if hit and math.abs(hit.Normal.Y) < 0.3 and hit.Distance > 18 then
                return hit.Position - direction * 7
            end
            return nil
        end,
        approachGoal = state.fallbackGoal or (waypoint and waypoint.Position + Vector3.new(0, 2.5, 0)),
        zones = state.activeZones,
        ground = function(position)
            return groundPosition(position, rootPart.Parent, target)
        end,
        walkable = function(position)
            return walkingSegmentClear(rootPart, position, target)
                and safeEnemyStep(rootPart.Position, position)
        end,
    })
end

local function executeNorthernMechanic(intent, humanoid, rootPart, target, targetRoot, now, distance)
    if not intent then return false end
    state.adaptiveLocalAttempt = nil
    if state.motionMode ~= "mechanic" and state.motionMode ~= "mechanic-hold" then
        clearPath()
        state.motionGoal, state.fallbackGoal = nil, nil
    end
    state.escapeGoal, state.escapeUntil, state.escapeReason = nil, 0, nil
    state.combatIntent, state.lastProgressGoal = nil, nil
    state.navigationPhase = "mechanic"
    state.status = intent.reason or ("Solving " .. tostring(intent.mechanic))
    if intent.hold or not intent.goal
        or Vector3.new(intent.goal.X - rootPart.Position.X, 0, intent.goal.Z - rootPart.Position.Z).Magnitude <= 1.5 then
        stopMovement(humanoid, rootPart)
        state.motionMode = "mechanic-hold"
    else
        if intent.forceBlink then
            dodgeAlongEscape(humanoid, rootPart, intent.goal, target, intent.threat, now, true)
        end
        issueMove(humanoid, intent.goal, "mechanic", now, true)
    end
    if targetRoot then faceEnemy(humanoid, rootPart, targetRoot) end
    if intent.allowAttack and target and targetRoot then
        castSkill()
    end
    return true
end

-- Keep a chosen combat orbit point briefly. Re-sample when the enemy moves,
-- the route becomes unsafe, or a dodge takes ownership of movement.
local function combatPosition(rootPart, target, targetRoot, baseGoal, now)
    local intent = state.combatIntent
    if intent and intent.target == target and now < intent.untilAt
        and (intent.goal - rootPart.Position).Magnitude > 1.5
        and (targetRoot.Position - intent.targetPosition).Magnitude < 3
        and ThreatGeometry.risk(state.activeZones, intent.goal, CFG.HAZARD_MARGIN) == 0
        and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, intent.goal, CFG.HAZARD_MARGIN) then
        local recentlyChecked = now - intent.routeCheckedAt < 0.15
            and (rootPart.Position - intent.routeCheckedFrom).Magnitude < 3
        if recentlyChecked then return intent.goal end
        if walkingSegmentClear(rootPart, intent.goal, target) then
            intent.routeCheckedAt, intent.routeCheckedFrom = now, rootPart.Position
            return intent.goal
        end
    end
    local radial = baseGoal - targetRoot.Position
    radial = Vector3.new(radial.X, 0, radial.Z)
    if radial.Magnitude < 0.1 then radial = rootPart.Position - targetRoot.Position end
    radial = Vector3.new(radial.X, 0, radial.Z)
    if radial.Magnitude < 0.1 then radial = Vector3.new(1, 0, 0) end
    local tangent = Vector3.new(-radial.Z, 0, radial.X).Unit
    local best, bestSide, bestScore
    for _, side in ipairs({ state.dodgeSide, -state.dodgeSide }) do
        local candidate = groundPosition(baseGoal + tangent * side * 4, rootPart.Parent, target)
        if walkingSegmentClear(rootPart, candidate, target)
            and safeEnemyStep(rootPart.Position, candidate)
            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN) then
            local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
            local targetDistance = (candidate - targetRoot.Position).Magnitude
            local score = risk * 1000 + math.abs(targetDistance - CFG.COMBAT_DISTANCE) * 2
                + (side == state.dodgeSide and 0 or 12)
            if not bestScore or score < bestScore then
                best, bestSide, bestScore = candidate, side, score
            end
        end
    end
    if best then state.dodgeSide = bestSide end
    local goal = best or baseGoal
    state.combatIntent = { target = target, targetPosition = targetRoot.Position,
        goal = goal, untilAt = now + 0.65, routeCheckedAt = now,
        routeCheckedFrom = rootPart.Position }
    return goal
end

local function firingPosition(rootPart, target, targetRoot, now)
    local range = 0
    local profiles = {}
    for _, snapshot in pairs(abilities.Snapshot(now)) do
        local profile = FarmPlanner.profile(snapshot)
        local reach = AttackPolicy.range(profile, profile.mode == "self" and CFG.CLOSE_AOE_RANGE
            or effectiveSpellRange(profile))
        range = math.max(range, reach or 0)
        if reach then table.insert(profiles, profile) end
    end
    if range == 0 or not AttackPolicy.damageable(target) then return nil end
    local targetDistance = (targetRoot.Position - rootPart.Position).Magnitude
    -- Leave travel across rooms to the room graph.
    if targetDistance > math.max(60, range + 16) then return nil end
    local spacing = math.min(CFG.COMBAT_DISTANCE, range * 0.85)
    local function canFire(position)
        for _, profile in ipairs(profiles) do
            if AttackPolicy.canHit(profile, position, targetRoot.Position,
                profile.mode == "self" and CFG.CLOSE_AOE_RANGE or effectiveSpellRange(profile),
                function(origin, destination) return hasBlockingRay(origin, destination, rootPart.Parent, target) end) then
                return true
            end
        end
        return false
    end
    local currentCanFire = canFire(rootPart.Position)
    if currentCanFire and targetDistance <= spacing + 2 then return rootPart.Position end
    local cached = state.firingPosition
    if cached and cached.target == target and now - cached.at < 0.5
        and (cached.origin - rootPart.Position).Magnitude < 4
        and (cached.targetPosition - targetRoot.Position).Magnitude < 3
        and cached.range == range
        and (not cached.goal or ThreatGeometry.risk(state.activeZones, cached.goal, CFG.HAZARD_MARGIN) == 0) then
        return cached.goal
    end
    local best, bestCost
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    local currentVisible = currentCanFire or not hasBlockingRay(rootPart.Position, targetRoot.Position, rootPart.Parent, target)
    local currentCost = AttackPolicy.approachScore(targetDistance, 0, currentVisible, range, spacing)
    local function consider(sample, requireWalk)
        local floor = Workspace:Raycast(sample + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), params)
        if not floor or floor.Normal.Y < 0.55 or floor.Instance.Name:lower():find("lava", 1, true) then return end
        local point = floor.Position + Vector3.new(0, 2.5, 0)
        local travel = (point - rootPart.Position).Magnitude
        if travel <= 2 or ThreatGeometry.risk(state.activeZones, point, CFG.HAZARD_MARGIN) > 0 then return end
        local visible = canFire(point) or not hasBlockingRay(point, targetRoot.Position, rootPart.Parent, target)
        local distance = (point - targetRoot.Position).Magnitude
        local direct = walkingSegmentClear(rootPart, point, target)
            and safeEnemyStep(rootPart.Position, point)
            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, point, CFG.HAZARD_MARGIN)
        if requireWalk and not direct then return end
        if not requireWalk and not (visible and distance <= range) then return end
        local cost = AttackPolicy.approachScore(distance, travel, visible, range, spacing)
            + math.max(0, adaptiveNavigation:LocalCost(rootPart.Position, point))
        if requireWalk and cost >= currentCost - 1 then return end
        if not direct then cost = cost + 12 end
        if not bestCost or cost < bestCost then best, bestCost = point, cost end
    end
    -- Close the distance in safe ground steps even before a firing point is
    -- within reach. The old all-or-nothing search returned only in-range spots.
    for _, radius in ipairs({ 8, 16 }) do
        for index = 0, 7 do
            local angle = index * math.pi / 4
            consider(rootPart.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius), true)
        end
    end
    -- A wall may require a path to the firing point, rather than a clear
    -- straight walk. Feed grounded arena-side points to the normal navmesh.
    if not best then
        local radius = math.max(6, AttackPolicy.horizontalRange(spacing, targetRoot.Position.Y - rootPart.Position.Y))
        for index = 0, 7 do
            local angle = index * math.pi / 4
            consider(Vector3.new(targetRoot.Position.X + math.cos(angle) * radius,
                rootPart.Position.Y, targetRoot.Position.Z + math.sin(angle) * radius), false)
        end
    end
    if not best and currentCanFire then best = rootPart.Position end
    state.firingPosition = { target = target, targetPosition = targetRoot.Position,
        origin = rootPart.Position, at = now, goal = best, range = range }
    return best
end

local function combatGroundPosition(rootPart, target, targetRoot, direction)
    local height = targetRoot.Position.Y - rootPart.Position.Y
    local spacing = math.min(CFG.COMBAT_DISTANCE, AttackPolicy.horizontalRange(CFG.ATTACK_RANGE * 0.9, height))
    local center = Vector3.new(targetRoot.Position.X, rootPart.Position.Y, targetRoot.Position.Z)
    return groundPosition(center + direction * spacing, rootPart.Parent, target)
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
    CFG.ATTACK_RANGE = CFG.SPELL_RANGE_OVERRIDE > 0 and CFG.SPELL_RANGE_OVERRIDE or 26
    for _, snapshot in pairs(abilities.Snapshot(now)) do
        local profile = FarmPlanner.profile(snapshot)
        local reach = AttackPolicy.range(profile, effectiveSpellRange(profile))
        if reach then CFG.ATTACK_RANGE = math.max(CFG.ATTACK_RANGE, reach) end
    end
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
    refreshSafety(rootPart, now)
    local target, distance = getClosestEnemy(rootPart, now)
    if not target then
        state.castAimTarget, state.farmPlan, state.groupCount, state.groupCenter = nil, nil, 0, nil
        state.packCount, state.packCenter = 0, nil
        state.retreating = false
        state.targetName, state.targetDist = "None", 0
        state.currentTarget, state.lockedTarget = nil, nil
        local mechanicIntent = northernMechanicIntent(humanoid, rootPart, nil, nil, now)
        if executeNorthernMechanic(mechanicIntent, humanoid, rootPart, nil, nil, now, math.huge) then return end
        if CFG.AUTO_DODGE then
            local currentRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, CFG.HAZARD_MARGIN)
            if currentRisk > 0 then
                local goal = state.escapeGoal
                if not goal or now >= (state.escapeUntil or 0) or (goal - rootPart.Position).Magnitude <= 2
                    or ThreatGeometry.risk(state.activeZones, goal, CFG.HAZARD_MARGIN) >= currentRisk - 0.1
                    or not walkingSegmentClear(rootPart, goal, nil) then
                    goal = findEmergencySideStep(rootPart, nil) or findLeastBadStep(rootPart, nil)
                    state.escapeGoal, state.escapeUntil = goal, now + 0.5
                end
                if goal and ThreatGeometry.risk(state.activeZones, goal, CFG.HAZARD_MARGIN) < currentRisk - 0.1 then
                    state.status = "Escaping lingering attack"
                    issueMove(humanoid, goal, "evade", now, true)
                    return
                end
            end
        end
        state.escapeGoal, state.lastThreatPart = nil, nil
        state.status = "Waiting for wave"
        stopMovement(humanoid, rootPart)
        state.pathStatus = "Pathfinding: waiting for next wave"
        return
    end

    -- Burn phase: while the Protector lives, it is the only target. Chasing
    -- adds walks the bot across resolving volleys for no damage gain.
    if target.Name ~= "Ancient Temple Protector" then
        for _, model in ipairs(state.cachedTargets) do
            if model.Name == "Ancient Temple Protector" and isValidTarget(model) and model:IsDescendantOf(Workspace) then
                target = model
                state.lockedTarget = model
                local bossRoot = getRootPart(model)
                if bossRoot then distance = (bossRoot.Position - rootPart.Position).Magnitude end
                break
            end
        end
    end

    local targetHumanoid, targetRoot = target:FindFirstChildOfClass("Humanoid"), getRootPart(target)
    if not targetHumanoid or targetHumanoid.Health <= 0 or not targetRoot then
        state.lockedTarget = nil
        return
    end
    if state.currentTarget ~= target then
        state.adaptiveLocalAttempt = nil
        state.combatIntent = nil
        state.lastProgressGoal = nil
        local previousRoot = state.currentTarget and getRootPart(state.currentTarget)
        if not previousRoot or (previousRoot.Position - targetRoot.Position).Magnitude > 4 then
            clearPath()
            state.motionGoal, state.fallbackGoal = nil, nil
            state.pathUpdateTime = 0
        end
        state.lastProgressDistance, state.stuckStartTime = math.huge, 0
        state.routeFails, state.wanderGoal, state.wallSide = 0, nil, nil
        state.wallVisits, state.wallFlips = {}, 0
    end
    state.currentTarget, state.targetName, state.targetDist = target, target.Name, distance
    -- Record arrivals without selecting a room route before the movement owner
    -- is known. Creating then cancelling an edge every combat tick reset the
    -- objective stall timer and invalidated asynchronous paths unnecessarily.
    if #state.routeAnchors > 0 then mapRouteGoal(rootPart, now, true) end
    -- Doomed round: same target for 3 minutes with zero kills and zero damage
    -- dealt (e.g. mob under the map behind a wall that never opens). Solo
    -- only, so nobody else's run is ever touched. Leaves via teleToLobby.
    do
        local dw = state.doomWatch
        local hp = targetHumanoid and targetHumanoid.Health or 0
        if not dw or dw.target ~= target then
            state.doomWatch = { target = target, since = now, kills = state.kills, hp = hp }
        elseif now - dw.since >= 180 and state.kills == dw.kills and hp >= dw.hp and not state.doomFired then
            if #Players:GetPlayers() <= 1 then
                state.doomFired = true
                logThreat("doomed", target.Name)
                warn("[EnemyWalker] doomed round, leaving: " .. target.Name)
                pcall(function()
                    game:GetService("ReplicatedStorage"):WaitForChild("remotes"):WaitForChild("teleToLobby", 5):FireServer()
                end)
            end
        end
    end
    local protectorRear = target.Name == "Ancient Temple Protector"
    local protectorApproach
    if protectorRear then
        local offset = rootPart.Position - targetRoot.Position
        if Vector3.new(offset.X, 0, offset.Z).Magnitude > 40 then
            local side = offset:Dot(targetRoot.CFrame.RightVector) >= 0 and 1 or -1
            protectorApproach = groundPosition(targetRoot.Position + targetRoot.CFrame.RightVector * side * 24
                - targetRoot.CFrame.LookVector * 16, character, target)
        end
    end
    state.prevHealth[target] = targetHumanoid.Health
    local mechanicIntent = northernMechanicIntent(humanoid, rootPart, target, targetRoot, now)
    local unsafeHold = mechanicIntent and mechanicIntent.hold
        and ThreatGeometry.risk(state.activeZones, rootPart.Position, 2, 0.25) > 0
    -- A persistent mechanic objective remains alive while ordinary attacks
    -- temporarily take movement ownership. Re-run the shared safety planner
    -- whenever a hazard is present so an orb route cannot walk through Bob's
    -- other attacks; NorthernLandsController will resume the same objective
    -- on the next tick.
    local mechanicEmergency = mechanicIntent and (mechanicIntent.emergencyFirst or unsafeHold
        or #state.activeZones > 0)
        and handleSafety(humanoid, rootPart, target, targetRoot, now)
    if mechanicEmergency then
        state.combatIntent, state.lastProgressGoal = nil, nil
        state.navigationPhase = "evade"
        faceEnemy(humanoid, rootPart, targetRoot)
        castSkill()
        return
    end
    if executeNorthernMechanic(mechanicIntent, humanoid, rootPart, target, targetRoot, now, distance) then return end
    if handleSafety(humanoid, rootPart, target, targetRoot, now) then
        state.combatIntent, state.lastProgressGoal = nil, nil
        state.navigationPhase = "evade"
        if CFG.AUTO_ABILITIES and CFG.SMART_FARM then
            abilities.TryCast(now, CFG.SKILL_COOLDOWN, function(slot, snapshot)
                return FarmPlanner.profile(snapshot).mode == "buff" and prepareSpell(slot, snapshot)
            end)
        end
        faceEnemy(humanoid, rootPart, targetRoot)
        castSkill() -- Per-ability preparation decides whether its hit volume reaches the target.
        return
    end

    if not AttackPolicy.damageable(target) then
        state.status = "Waiting for damageable phase: " .. target.Name
        stopMovement(humanoid, rootPart)
        faceEnemy(humanoid, rootPart, targetRoot)
        return
    end
    -- Mechanic/safety owners ran first. Attack eligibility does not depend on
    -- reaching the target's floor or entering a particular boss animation.
    faceEnemy(humanoid, rootPart, targetRoot)
    castSkill()
    if not protectorRear and math.abs(targetRoot.Position.Y - rootPart.Position.Y) > 6 then
        local firingGoal = firingPosition(rootPart, target, targetRoot, now)
        if firingGoal then
            state.navigationPhase = "combat"
            state.status = (firingGoal - rootPart.Position).Magnitude <= 2
                and "Attacking from ground: " .. target.Name or "Approaching elevated target: " .. target.Name
            state.climbDySince = nil
            state.unreachableTargets[target] = nil
            if adaptiveNavigation.edge then adaptiveNavigation:Cancel("ground approach owns movement") end
            if (firingGoal - rootPart.Position).Magnitude <= 2 then
                stopMovement(humanoid, rootPart)
            else
                followGoal(humanoid, rootPart, firingGoal, "combat", now, target)
                updateProgress(humanoid, rootPart,
                    Vector3.new(targetRoot.Position.X, rootPart.Position.Y, targetRoot.Position.Z), target, now)
            end
            return
        end
    end

    -- Long approaches use the room graph even when a replicated enemy is
    -- visible across several rooms. Combat and mandatory mechanics remain local.
    if distance > math.max(60, CFG.ATTACK_RANGE + 12) then
        local routeGoal, routeAnchor = mapRouteGoal(rootPart, now)
        if routeGoal then
            state.navigationPhase = "approach"
            state.status = "Following room graph: " .. routeAnchor.name
            restoreFacing()
            followGoal(humanoid, rootPart, routeGoal, "map-route", now, target)
            updateProgress(humanoid, rootPart, routeGoal, target, now)
            return
        end
    end

    -- A combat-distance point on this side of a wall is not an attack position.
    -- Route to the enemy's reachable area before holding distance or casting.
    if hasBlockingRay(rootPart.Position, targetRoot.Position, character, target) then
        state.navigationPhase = "approach"
        state.lastThreatPart, state.dodgeGoal = nil, nil
        restoreFacing()
        local routeGoal, routeAnchor = mapRouteGoal(rootPart, now)
        if routeGoal and distance > 35 then
            state.status = "Following map route: " .. routeAnchor.name
            followGoal(humanoid, rootPart, routeGoal, "map-route", now, target)
            updateProgress(humanoid, rootPart, routeGoal, target, now)
            return
        end
        -- Target on a higher level: the flat navmesh route walks underneath
        -- and never climbs. Chain upward recovery steps toward the target
        -- until the height gap closes. Gated on SUSTAINED elevation so flying
        -- trash bobbing up and down doesn't yo-yo the bot up every slope, and
        -- on horizontal closeness so far targets route normally instead of
        -- climbing random hills hundreds of studs away.
        local climbDy = targetRoot.Position.Y - rootPart.Position.Y
        local climbFlat = Vector3.new(targetRoot.Position.X - rootPart.Position.X, 0, targetRoot.Position.Z - rootPart.Position.Z).Magnitude
        if climbDy > 8 and climbFlat < 80 then
            state.climbDySince = state.climbDySince or now
        else
            state.climbDySince = nil
        end
        if state.climbDySince and now - state.climbDySince >= 3 and now - (state.lastClimbTry or -math.huge) >= 2.5 then
            state.lastClimbTry = now
            local climbPath, climbPoints, higher = findRecoveryPath(rootPart, targetRoot.Position, target, 2.5)
            if higher and climbPath and climbPoints then
                clearPath()
                state.terrainRecovery = higher
                state.pathObject = climbPath
                state.pathBlocked = false
                state.pathGoal, state.pathMode = higher, "terrain-recovery"
                state.motionGoal, state.motionGoalMode = higher, "terrain-recovery"
                state.waypoints = climbPoints
                state.currentWaypointIndex = 1
                state.pathStatus = "Climbing to " .. target.Name
                state.status = state.pathStatus
                updateProgress(humanoid, rootPart, higher, target, now)
                return
            end
        end
        -- Unreachable target (locked door, unspawned wave, or geometry we
        -- cannot close on): holding and wandering beats ramming forever.
        -- Far targets hold after ~20 failures; close ones only after ~40, so
        -- ordinary approaches never park within sight of the enemy.
        local holdFails = state.routeFails or 0
        local shouldHold = holdFails > 20 and (distance > 50 or holdFails > 40)
        if shouldHold then
            -- Re-probe periodically: an opened door makes the far target
            -- reachable again, which resumes the advance below.
            if now - (state.lastHoldProbe or -math.huge) >= 2 then
                state.lastHoldProbe = now
                if walkingSegmentClear(rootPart, targetRoot.Position, target) then
                    state.routeFails = 0
                    state.wanderGoal = nil
                    shouldHold = (state.routeFails or 0) > 20 and (distance > 50 or (state.routeFails or 0) > 40)
                end
            end
        end
        if shouldHold then
            state.unreachableTargets[target] = now + 8
            if not state.wanderGoal or now > (state.wanderUntil or 0)
                or (state.wanderGoal - rootPart.Position).Magnitude <= CFG.WAYPOINT_REACH_THRESHOLD then
                -- Wall-follow: the target sits behind a wall and pacing into
                -- it loops forever. Walk ALONG the wall on a fixed side;
                -- doors, stairs and ramps are found by traversal, and the 2s
                -- re-probe resumes the advance when the ray clears. Fixed
                -- side plus visited-ground memory is what breaks circles:
                -- flipping sides or re-walking fresh ground is penalized.
                local bearing = math.atan2(targetRoot.Position.Z - rootPart.Position.Z, targetRoot.Position.X - rootPart.Position.X)
                state.wallSide = state.wallSide or (math.random() < 0.5 and 1 or -1)
                state.wallVisits = state.wallVisits or {}
                for key, at in pairs(state.wallVisits) do
                    if now - at > 45 then state.wallVisits[key] = nil end
                end
                local function visitPenalty(pos)
                    local penalty = 0
                    for key in pairs(state.wallVisits) do
                        local cx, cz = key:match("([^:]+):([^:]+)")
                        cx, cz = tonumber(cx), tonumber(cz)
                        if cx and cz then
                            local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(cx, 0, cz)).Magnitude
                            if d < 14 then penalty = penalty + (14 - d) * 6 end
                        end
                    end
                    return penalty
                end
                local bestGoal, bestScore, bestSide
                for _, side in ipairs({ state.wallSide, -state.wallSide }) do
                    local tangent = Vector3.new(-math.sin(bearing), 0, math.cos(bearing)) * side
                    local forward = Vector3.new(math.cos(bearing), 0, math.sin(bearing))
                    local goal = rootPart.Position + (tangent * 0.92 + forward * 0.39).Unit * 26
                    local candidate = groundPosition(goal, character, target)
                    if walkingSegmentClear(rootPart, candidate, target) then
                        local score = (side == state.wallSide and 0 or 60) + visitPenalty(candidate)
                        if not bestScore or score < bestScore then
                            bestScore, bestSide, bestGoal = score, side, candidate
                        end
                    end
                end
                if bestGoal then
                    -- Only adopt a flipped side after repeated forced flips;
                    -- a single blocked pick must not reverse the whole traverse.
                    if bestSide ~= state.wallSide then
                        state.wallFlips = (state.wallFlips or 0) + 1
                        if state.wallFlips >= 3 then
                            state.wallSide, state.wallFlips = bestSide, 0
                        end
                    else
                        state.wallFlips = 0
                    end
                    state.wallVisits[math.floor(bestGoal.X / 7) .. ":" .. math.floor(bestGoal.Z / 7)] = now
                    state.wanderGoal = bestGoal
                else
                    local goal = rootPart.Position + Vector3.new(math.cos(bearing), 0, math.sin(bearing)) * 20
                    state.wanderGoal = chooseFallbackStep(rootPart, goal, target)
                end
                state.wanderUntil = now + 6
            end
            state.status = "Holding for wave/door: " .. target.Name
            if state.wanderGoal then issueMove(humanoid, state.wanderGoal, "hold", now) end
            if distance <= CFG.ATTACK_RANGE then castSkill() end
            return
        elseif distance <= 50 and (state.routeFails or 0) < 40 then
            state.routeFails = 0
            state.wanderGoal = nil
        end
        state.status = "Routing around obstacle to " .. target.Name
        local approachGoal = protectorApproach or (protectorRear
            and groundPosition(targetRoot.Position - targetRoot.CFrame.LookVector * 16, character, target)) or targetRoot.Position
        followGoal(humanoid, rootPart, approachGoal, "approach", now, target)
        updateProgress(humanoid, rootPart, approachGoal, target, now)
        return
    end
    state.navigationPhase = "combat"
    if distance <= CFG.ATTACK_RANGE then
        state.routeHasCombat = true
        if #state.routeAnchors > 0 and now - (state.lastRouteSync or -math.huge) >= 1 then
            state.lastRouteSync = now
            syncRouteToCurrentRoom(rootPart, 18)
        end
    end
    faceEnemy(humanoid, rootPart, targetRoot)

    if protectorApproach then
        state.status = "Approaching Protector flank"
        followGoal(humanoid, rootPart, protectorApproach, "approach", now, target)
        updateProgress(humanoid, rootPart, protectorApproach, target, now)
        if distance <= CFG.ATTACK_RANGE then castSkill() end
        return
    end
    if not protectorRear and CFG.FARM_POSITION == "Nearest" and distance >= CFG.COMBAT_MIN_DISTANCE and distance <= CFG.COMBAT_MAX_DISTANCE then
        state.status = "Attacking " .. target.Name
        -- Keep a small combat orbit while casting so a target in range does not
        -- turn the character into a stationary hitbox.
        local offset = rootPart.Position - targetRoot.Position
        local flat = Vector3.new(offset.X, 0, offset.Z)
        if flat.Magnitude < 0.1 then flat = Vector3.new(1, 0, 0) end
        local basePosition = combatGroundPosition(rootPart, target, targetRoot, flat.Unit)
        if (state.packCount or 0) >= 2 and state.packCenter then
            local groupOffset = rootPart.Position - state.packCenter
            groupOffset = Vector3.new(groupOffset.X, 0, groupOffset.Z)
            if groupOffset.Magnitude < 0.1 then groupOffset = flat.Unit end
            local groupSpacing = math.min(CFG.COMBAT_DISTANCE, math.max(10, CFG.ATTACK_RANGE * 0.72))
            local grouped = groundPosition(state.packCenter + groupOffset.Unit * groupSpacing, character, target)
            -- Keep the pack center only when the locked enemy remains inside
            -- a real ability range. Otherwise the edge target gets priority.
            if (grouped - targetRoot.Position).Magnitude <= CFG.ATTACK_RANGE then basePosition = grouped end
        end
        local desiredPosition = combatPosition(rootPart, target, targetRoot, basePosition, now)
        if (desiredPosition - rootPart.Position).Magnitude > 1 then
            followGoal(humanoid, rootPart, desiredPosition, "combat", now, target)
        end
        castSkill()
        return
    end

    local offset = rootPart.Position - targetRoot.Position
    local flat = Vector3.new(offset.X, 0, offset.Z)
    if protectorRear or CFG.FARM_POSITION == "Behind" then flat = -targetRoot.CFrame.LookVector
    elseif CFG.FARM_POSITION == "Front" then flat = targetRoot.CFrame.LookVector
    elseif CFG.FARM_POSITION == "Left" then flat = -targetRoot.CFrame.RightVector
    elseif CFG.FARM_POSITION == "Right" then flat = targetRoot.CFrame.RightVector end
    flat = Vector3.new(flat.X, 0, flat.Z)
    if flat.Magnitude < 0.1 then flat = Vector3.new(1, 0, 0) end
    if protectorRear then
        local radial = Vector3.new(offset.X, 0, offset.Z)
        if radial.Magnitude > 0.1 then
            radial = radial.Unit
            state.protectorOrbitSide = state.protectorOrbitSide or 1
            flat = CFrame.fromAxisAngle(Vector3.yAxis, state.protectorOrbitSide * math.pi / 6):VectorToWorldSpace(radial)
        end
    end
    local basePosition = protectorRear
        and groundPosition(targetRoot.Position + flat.Unit * CFG.COMBAT_DISTANCE, character, target)
        or combatGroundPosition(rootPart, target, targetRoot, flat.Unit)
    local desiredPosition = protectorRear
        and combatPosition(rootPart, target, targetRoot, basePosition, now) or basePosition
    if (Vector3.new(desiredPosition.X - rootPart.Position.X, 0, desiredPosition.Z - rootPart.Position.Z)).Magnitude < 2 then
        stopMovement(humanoid, rootPart)
        if distance <= CFG.ATTACK_RANGE then castSkill() end
        return
    end
    state.status = protectorRear and "Circling Protector in spell range"
        or (distance > CFG.COMBAT_MAX_DISTANCE and "Moving to " .. target.Name or "Creating space from " .. target.Name)
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
    adaptiveNavigation:Reset()
    northernMechanics:Reset()
    state.adaptiveLocalAttempt = nil
    if state.running then
        state.unreachableTargets = setmetatable({}, { __mode = "k" })
        state.combatIntent, state.lastProgressGoal = nil, nil
        state.escapeLearning = nil
        state.castAimTarget, state.farmPlan, state.groupCount, state.groupCenter = nil, nil, 0, nil
        state.packCount, state.packCenter = 0, nil
        state.retreating = false
        state.escapeGoal, state.escapeUntil, state.safetyUntil = nil, 0, 0
        state.movementBlocked, state.lastSafetyScan, state.lastEscapePlan = false, -math.huge, -math.huge
        state.skillQ_count, state.skillE_count, state.kills, state.stuckRetries = 0, 0, 0, 0
        state.skillToggle, state.lastSkillTime = false, 0
        state.lockedTarget, state.currentTarget = nil, nil
        state.cachedTargets, state.prevHealth = {}, setmetatable({}, { __mode = "k" })
        state.lastTargetScan, state.lastTargetChoice = 0, 0
        state.lastDodgeTime, state.dodgeGoal = 0, nil
        table.clear(state.dodgeHistory)
        table.clear(state.dodgedThreats)
        state.hazardMarginBonus, state.hazardMarginBonusAt = 0, 0
        CFG.HAZARD_MARGIN = CFG.HAZARD_MARGIN_BASE
        state.motionGoal, state.motionGoalMode, state.motionMode = nil, nil, "idle"
        state.fallbackGoal, state.fallbackUntil = nil, 0
        state.stuckStartTime, state.stuckCount, state.pathUpdateTime = 0, 0, 0
        state.routeFails, state.wanderGoal, state.wanderUntil = 0, nil, 0
        state.wallSide, state.wallVisits, state.wallFlips = nil, {}, 0
        state.routeDungeon, state.routeAnchors, state.routeAnchorIndex = nil, {}, 1
        state.routeProgress, state.routeInitialized, state.routeHasCombat = nil, false, false
        state.routeScannedAt = -math.huge
        state.doomWatch, state.doomFired = nil, nil
        state.lastDodgeThreat, state.lastDodgeThreatAt = nil, 0
        state.dodgeCount, state.damageEvents, state.lastPlayerHealth = 0, 0, nil
        createWaypointFolder()
        state.pathStatus = "Pathfinding: active"
    else
        state.castAimTarget, state.farmPlan, state.groupCount, state.groupCenter = nil, nil, 0, nil
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
    clearHazardLabels()
    if state.waypointFolder then state.waypointFolder:Destroy() end
    for _, connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
    table.clear(threatParts)
    table.clear(safeSpots)
    table.clear(humanoidModels)
    table.clear(announcedZones)
end

local function watchHealth(character)
    if not character then return end
    local humanoid = character:WaitForChild("Humanoid", 5)
    if not humanoid or state.closed or character ~= player.Character then return end
    if state.healthConnection then state.healthConnection:Disconnect() end
    local previous = humanoid.Health
    state.healthConnection = connect(humanoid.HealthChanged, function(health)
        if state.running and not state.closed and character == player.Character and health < previous - 0.01 then
            state.damageEvents = state.damageEvents + 1
            state.lastSafetyScan = -math.huge
            state.lastDamage = { amount = previous - health, at = os.clock(), health = health,
                mode = state.motionMode, status = state.status, hazards = #state.activeZones,
                distance = state.targetDist }
            local root = character:FindFirstChild("HumanoidRootPart")
            if root then
                northernMechanics:ObserveDamage(root, state.activeZones, os.clock())
                if state.motionGoal and state.motionMode ~= "mechanic" and state.motionMode ~= "mechanic-hold"
                    and ThreatGeometry.risk(state.activeZones, root.Position, 2) > 0 then
                    local attempt = state.adaptiveLocalAttempt
                    if attempt and os.clock() - attempt.lastAt <= 1 then
                        adaptiveNavigation:LocalOutcome(attempt.start, attempt.goal, false)
                        state.adaptiveLocalAttempt = nil
                    end
                    if adaptiveNavigation.edge and state.motionGoalMode == "map-route"
                        and state.motionMode ~= "evade"
                        and os.clock() - (state.lastRouteDamageAt or -math.huge) > 2 then
                        adaptiveMemory:Observe("route", adaptiveNavigation.edge.key, {}, false)
                        state.lastRouteDamageAt = os.clock()
                    end
                end
                local nearby = {}
                local nearestZone, nearestZoneClearance = nil, math.huge
                for _, zone in ipairs(state.activeZones) do
                    local zp = zone.frame.Position
                    local clearance = ThreatGeometry.clearance(zone, root.Position, 0)
                    if clearance < nearestZoneClearance then
                        nearestZone, nearestZoneClearance = zone, clearance
                    end
                    table.insert(nearby, {
                        name = typeof(zone.id) == "Instance" and zone.id:GetFullName()
                            or zone.name or "Announced telegraph",
                        clearance = clearance,
                        position = zone.frame.Position, size = zone.size, shape = zone.shape,
                        zoneAt = string.format("%d,%d,%d", math.floor(zp.X), math.floor(zp.Y), math.floor(zp.Z)),
                    })
                end
                table.sort(nearby, function(a, b) return a.clearance < b.clearance end)
                while #nearby > 4 do table.remove(nearby) end
                local nearestClearance = nearby[1] and nearby[1].clearance or 0
                if nearestZone and nearestZoneClearance <= 1 then
                    rememberHazardHit(nearestZone)
                end
                state.hazardMarginBonus = math.clamp(math.max(3, nearestClearance - CFG.HAZARD_MARGIN_BASE + 2), 3, 8)
                state.hazardMarginBonusAt = os.clock()
                state.lastDamage.position = root.Position
                state.lastDamage.goal = state.escapeGoal
                do
                    local boss = state.currentTarget
                    local bossRoot = boss and getRootPart(boss)
                    if bossRoot then
                        local bp = bossRoot.Position
                        state.lastDamage.boss = (boss and boss.Name or "?") .. string.format(" @%d,%d,%d", math.floor(bp.X), math.floor(bp.Y), math.floor(bp.Z))
                    end
                end
                state.lastDamage.speed = humanoid.WalkSpeed
                state.lastDamage.nearestHazards = nearby
            end
            local nearestName = state.lastDamage.nearestHazards and state.lastDamage.nearestHazards[1]
                and state.lastDamage.nearestHazards[1].name or "none"
            local nearest = state.lastDamage.nearestHazards and state.lastDamage.nearestHazards[1]
            local hazardSummary = {}
            for index = 1, math.min(4, #(state.lastDamage.nearestHazards or {})) do
                local item = state.lastDamage.nearestHazards[index]
                table.insert(hazardSummary, string.format("%s:%.1f", item.name, item.clearance))
            end
            warn(string.format("[EnemyWalker] damage event #%d (%.0f -> %.0f) mode=%s status=%s nearest=%s shape=%s clearance=%.1f size=%s",
                state.damageEvents, previous, health, tostring(state.motionMode), tostring(state.status), nearestName,
                tostring(nearest and nearest.shape or "?"), nearest and nearest.clearance or 0,
                tostring(nearest and nearest.size or "?")))
            if #hazardSummary > 0 then
                warn("[EnemyWalker] nearby hazards: " .. table.concat(hazardSummary, " | "))
            end
            logThreat("hit", { amount = math.floor(previous - health) })
        end
        previous = health
    end)
end

connect(player.CharacterAdded, function(character)
    adaptiveNavigation:Reset()
    northernMechanics:Reset()
    state.adaptiveLocalAttempt = nil
    state.combatIntent, state.lastProgressGoal = nil, nil
    state.escapeLearning = nil
    state.aimObservations = setmetatable({}, { __mode = "k" })
    state.protectorOrbitSide = nil
    state.protectorEscapeVisits = nil
    state.threatReactionAt = nil
    state.castAimTarget, state.farmPlan, state.groupCount, state.groupCenter = nil, nil, 0, nil
    state.packCount, state.packCenter = 0, nil
    state.retreating = false
    state.escapeGoal, state.escapeUntil, state.safetyUntil = nil, 0, 0
    state.movementBlocked, state.lastSafetyScan = false, -math.huge
    restoreFacing()
    state.lockedTarget, state.currentTarget = nil, nil
    state.cachedTargets, state.prevHealth = {}, setmetatable({}, { __mode = "k" })
    state.motionGoal, state.motionGoalMode, state.motionMode = nil, nil, "idle"
    state.fallbackGoal, state.fallbackUntil = nil, 0
    state.lastPlayerHealth, state.lastTargetScan = nil, 0
    state.routeDungeon, state.routeAnchors, state.routeAnchorIndex = nil, {}, 1
    state.routeProgress, state.routeInitialized, state.routeHasCombat = nil, false, false
    state.routeScannedAt = -math.huge
    state.pathUpdateTime = 0
    state.stuckStartTime, state.stuckCount = 0, 0
    state.dodgeGoal = nil
    state.lastDodgeThreat, state.lastDodgeThreatAt = nil, 0
    clearPath()
    task.spawn(watchHealth, character)
end)
task.spawn(watchHealth, player.Character)

local function loadDodgeMemory(data)
    if type(data) ~= "table" or data.Version ~= 1 or type(data.Entries) ~= "table" then return end
    local memory, count, sequence = {}, 0, 0
    for key, source in pairs(data.Entries) do
        if type(key) == "string" and #key > 0 and #key <= 64 and type(source) == "table"
            and count < 24 then
            local hits = math.clamp(math.floor(tonumber(source.Hits) or 0), 0, 100)
            local bonus = math.clamp(math.floor(tonumber(source.Bonus) or 0), 0, 5)
            local aimSamples = math.clamp(math.floor(tonumber(source.AimSamples) or 0), 0, 16)
            local aimFollow = math.clamp(tonumber(source.AimFollow) or 0, 0, 1)
            sequence = sequence + 1
            local avoidSide = source.AvoidSide == 1 and 1 or source.AvoidSide == -1 and -1 or nil
            local sides = {}
            if type(source.Sides) == "table" then
                for _, side in ipairs({ "-1", "1" }) do
                    local sample = source.Sides[side]
                    if type(sample) == "table" then
                        sides[side] = {
                            count = math.clamp(math.floor(tonumber(sample.Count) or 0), 0, 32),
                            value = math.clamp(tonumber(sample.Value) or 0.5, 0, 1),
                        }
                    end
                end
            end
            memory[key] = { hits = hits, bonus = bonus, sequence = sequence,
                avoidSide = avoidSide, sides = sides, aimSamples = aimSamples, aimFollow = aimFollow }
            count = count + 1
        end
    end
    state.hazardMemory, state.hazardMemorySequence, state.hazardMemoryDirty = memory, sequence, false
end

local function exportDodgeMemory()
    local entries = {}
    for key, entry in pairs(state.hazardMemory) do
        local sides = {}
        for side, sample in pairs(entry.sides or {}) do
            sides[side] = { Count = sample.count, Value = sample.value }
        end
        entries[key] = { Hits = entry.hits, Bonus = entry.bonus,
            AvoidSide = entry.avoidSide, Sides = sides,
            AimSamples = entry.aimSamples or 0, AimFollow = entry.aimFollow or 0 }
    end
    return { Version = 1, Entries = entries }
end

print("[EnemyWalker] loaded: northern-mechanics-v1, event-driven hazards, bounded teleport dodges")

return {
    Config = CFG,
    State = state,
    SetRunning = setRunning,
    Shutdown = shutdown,
    AbilityStatus = function() return abilities.Snapshot(os.clock()) end,
    SetAbilityInventory = abilities.SetInventory,
    AbilityProfile = FarmPlanner.profile,
    SetDodgeMemory = loadDodgeMemory,
    GetDodgeMemory = exportDodgeMemory,
    DodgeMemoryDirty = function() return state.hazardMemoryDirty end,
    MarkDodgeMemorySaved = function() state.hazardMemoryDirty = false end,
    SetAdaptiveMemory = function(data) adaptiveMemory:Load(data) end,
    GetAdaptiveMemory = function() return adaptiveMemory:Export() end,
    AdaptiveMemoryDirty = function() return adaptiveMemory.dirty end,
    MarkAdaptiveMemorySaved = function() adaptiveMemory.dirty = false end,
    SetWaypoints = function(enabled)
        CFG.SHOW_WAYPOINTS = enabled
        if enabled then visualizeWaypoints(state.waypoints, state.currentWaypointIndex) else clearWaypointVisuals() end
    end,
}
