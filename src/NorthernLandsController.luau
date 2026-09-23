local NorthernLands = {}
NorthernLands.__index = NorthernLands

NorthernLands.Objective = {
    ESCAPE_AREA = "ESCAPE_AREA",
    CROSS_CORRIDOR = "CROSS_CORRIDOR",
    ENTER_SAFE_ZONE = "ENTER_SAFE_ZONE",
    MATCH_COLOR = "MATCH_COLOR",
    GUIDE_PROJECTILE = "GUIDE_PROJECTILE",
    BAIT_POSITION = "BAIT_POSITION",
    HOLD_POSITION = "HOLD_POSITION",
    ROTATE_AROUND_CENTER = "ROTATE_AROUND_CENTER",
}

local ORB_COLORS = {
    secondbossredorb = "red",
    secondbossgreenorb = "green",
    secondbossyelloworb = "yellow",
}

local COLOR_VALUES = {
    red = Color3.fromRGB(255, 89, 89),
    yellow = Color3.fromRGB(255, 250, 94),
    green = Color3.fromRGB(78, 255, 69),
}

local RUNE_COLORS = {
    ["house rune"] = "red",
    ["star rune"] = "yellow",
    ["hex rune"] = "green",
}

local function flat(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end

local function unitOr(vector, fallback)
    vector = flat(vector)
    if vector.Magnitude < 0.01 then return fallback or Vector3.new(1, 0, 0) end
    return vector.Unit
end

local function rotate(vector, angle)
    return CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(vector)
end

local function containsColorName(value)
    local name = tostring(value or ""):lower()
    for _, color in ipairs({ "red", "yellow", "green" }) do
        if name:find(color, 1, true) then return color end
    end
    for rune, color in pairs(RUNE_COLORS) do
        if name:find(rune, 1, true) then return color end
    end
    return nil
end

local function closestColor(color)
    if typeof(color) ~= "Color3" then return nil end
    local best, bestDistance
    for name, expected in pairs(COLOR_VALUES) do
        local delta = Vector3.new(color.R - expected.R, color.G - expected.G, color.B - expected.B)
        local distance = delta.Magnitude
        if not bestDistance or distance < bestDistance then best, bestDistance = name, distance end
    end
    return bestDistance and bestDistance <= 0.65 and best or nil
end

local function instanceColor(instance)
    local named = containsColorName(instance and instance.Name)
    if named then return named end
    if not instance then return nil end
    for _, key in ipairs({ "Color", "color", "ColorName", "colorName", "RequiredColor", "SourceRune" }) do
        local value = instance:GetAttribute(key)
        local color = containsColorName(value)
        if color then return color end
    end
    local rune = instance:FindFirstChild("ColorblindRune")
    if rune then
        local source = rune:GetAttribute("SourceRune")
        local color = containsColorName(source)
        if color then return color end
    end
    if instance:IsA("BasePart") then return closestColor(instance.Color) end
    return nil
end

local function instancePosition(instance)
    if not instance or not instance.Parent then return nil end
    if instance:IsA("BasePart") then return instance.Position end
    if instance:IsA("Model") then
        local ok, pivot = pcall(instance.GetPivot, instance)
        if ok then return pivot.Position end
    end
    local part = instance:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function hasAncestorNamed(instance, wanted)
    local parent = instance and instance.Parent
    while parent and parent ~= workspace do
        if parent.Name == wanted then return true end
        parent = parent.Parent
    end
    return false
end

local function zoneName(zone)
    if type(zone.name) == "string" and zone.name ~= "" then return zone.name:lower() end
    local id = zone.id
    if typeof(id) == "Instance" then return id:GetFullName():lower() end
    return ""
end

local function isSlam(zone)
    local name = zoneName(zone)
    return name:find("firstbossjumpslam", 1, true)
        or name:find("first boss jump slam", 1, true)
        or name:find("jump slam", 1, true)
end

local function isPassiveBeam(zone)
    local name = zoneName(zone)
    return name:find("firstbosspassivebeam", 1, true)
        or name:find("first boss passive beam", 1, true)
end

local function isFirstBossProjectile(zone)
    local name = zoneName(zone)
    return name:find("crisscross", 1, true) or name:find("criss cross", 1, true)
        or name:find("seekingspike", 1, true) or name:find("seeking spike", 1, true)
        or name:find("bigspike", 1, true) or name:find("big spike", 1, true)
end

local function isOdinAttack(zone)
    local name = zoneName(zone)
    return name:find("thirdboss", 1, true) or name:find("third boss", 1, true)
        or name:find("bonusboss", 1, true) or name:find("bonus boss", 1, true)
        or name:find("ring", 1, true) or name:find("flame", 1, true)
end

local function bossKind(target)
    local name = target and target.Name:lower() or ""
    if name:find("midgard", 1, true) then return "MIDGARDIAN_CHAMPION" end
    if name:find("bob", 1, true) or name:find("frost giant", 1, true) then return "BOB_THE_FROST_GIANT" end
    if name:find("odin reincarnation", 1, true) then return "ODIN_REINCARNATION" end
    if name:find("odin", 1, true) then return "ODIN" end
    return nil
end

local function isNorthernLands(workspaceService)
    local value = workspaceService:FindFirstChild("dungeonName")
    return value and value:IsA("StringValue") and value.Value == "Northern Lands"
end

function NorthernLands.new(options)
    local self = setmetatable({}, NorthernLands)
    self._workspace = options.workspace or workspace
    self._player = options.player
    self._geometry = options.threatGeometry
    self._connect = options.connect or function(signal, callback) return signal:Connect(callback) end
    self._crystals = {}
    self._safeZoneParts = setmetatable({}, { __mode = "k" })
    self._orbs = setmetatable({}, { __mode = "k" })
    self._orbSamples = setmetatable({}, { __mode = "k" })
    self._intent = nil
    self._intentUntil = 0
    self._lastPlanAt = -math.huge
    self._escapeSide = 1
    self._sectorSide = 1
    self._slam = nil
    self._requiredColor = nil
    self._safeColorActive = false
    self._safeDeadline = 0
    self.State = {
        CurrentBoss = nil,
        CurrentPhase = "NORMAL",
        CurrentMechanic = "NORMAL",
        MechanicTarget = nil,
        MechanicStartedAt = 0,
        MechanicDeadline = 0,
        LastMechanic = nil,
    }

    local function track(instance) self:_track(instance) end
    local function untrack(instance) self:_untrack(instance) end
    self._connect(self._workspace.DescendantAdded, track)
    self._connect(self._workspace.DescendantRemoving, untrack)
    for _, instance in ipairs(self._workspace:GetDescendants()) do track(instance) end

    local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("remotes")
    local remote = remotes and remotes:FindFirstChild("northernBossSpecficEvents")
    if remote and remote:IsA("RemoteEvent") then
        self._connect(remote.OnClientEvent, function(action, data)
            self:_onEvent(action, data)
        end)
    end
    return self
end

function NorthernLands:_track(instance)
    if not instance:IsA("BasePart") then return end
    local lowered = instance.Name:lower():gsub("[^%w]", "")
    local orbColor = ORB_COLORS[lowered]
    if orbColor and instance:IsDescendantOf(self._workspace) then
        self._orbs[instance] = orbColor
    end
    if instance.Parent and instance.Parent.Name == "secondBossCrystals" then
        local color = instanceColor(instance)
        if color then self._crystals[color] = instance end
    end
    if hasAncestorNamed(instance, "bonusBossColorSafeSpots") then
        self._safeZoneParts[instance] = true
    end
end

function NorthernLands:_untrack(instance)
    self._orbs[instance] = nil
    self._orbSamples[instance] = nil
    self._safeZoneParts[instance] = nil
    for color, crystal in pairs(self._crystals) do
        if crystal == instance then self._crystals[color] = nil end
    end
    if self.State.MechanicTarget == instance then self._intentUntil = 0 end
end

function NorthernLands:_onEvent(action, data)
    if type(action) ~= "string" then return end
    local now = os.clock()
    if action == "First Boss Jump Up" then
        self._slam = { startedAt = now, committed = false, lastPosition = nil, stableAt = now }
        self:_setMechanic("SLAM_BAIT", data, now, now + 2.5)
    elseif action == "First Boss Jump Down" then
        self._slam = self._slam or { startedAt = now - 0.4 }
        self._slam.committed = true
        self._slam.landing = typeof(data) == "Vector3" and data or nil
        self._slam.committedAt = now
        self._intentUntil = 0
    elseif action == "First Boss Slam Land" then
        if self._slam then self._slam.landedAt = now end
    elseif action == "Second Boss Orb Explosion" then
        self._intentUntil = 0
    elseif action == "Bonus Boss Tall Swirly" or action == "Bonus Boss Tall Swirly Recolor" then
        if type(data) == "table" then
            local color = containsColorName(data[1])
            if color then
                self._requiredColor = color
                local serverDeadline = tonumber(data[2])
                local remaining = serverDeadline and serverDeadline - self._workspace:GetServerTimeNow() or 6
                self._safeDeadline = now + math.clamp(remaining, 0.2, 15)
                self._intentUntil = 0
            end
        end
    elseif action == "Bonus Boss Safe Color Zone Activated" then
        self._safeColorActive = true
        self._intentUntil = 0
    elseif action == "Bonus Boss Safe Color Zone Deactivated" then
        self._safeColorActive = false
        self._requiredColor = nil
        self._safeDeadline = 0
        if self.State.CurrentMechanic == "COLOR_MECHANIC" then self:_beginRecovery(now) end
    end
end

function NorthernLands:_setMechanic(mechanic, target, now, deadline)
    local state = self.State
    if state.CurrentMechanic ~= mechanic or state.MechanicTarget ~= target then
        if state.CurrentMechanic ~= "NORMAL" and state.CurrentMechanic ~= "RECOVERY" then
            state.LastMechanic = state.CurrentMechanic
        end
        state.CurrentMechanic = mechanic
        state.CurrentPhase = mechanic
        state.MechanicTarget = target
        state.MechanicStartedAt = now
        self._intent = nil
        self._intentUntil = 0
    end
    state.MechanicDeadline = deadline or 0
end

function NorthernLands:_beginRecovery(now, goal)
    local state = self.State
    if state.CurrentMechanic ~= "NORMAL" and state.CurrentMechanic ~= "RECOVERY" then
        state.LastMechanic = state.CurrentMechanic
    end
    state.CurrentMechanic = "RECOVERY"
    state.CurrentPhase = "RECOVERY"
    state.MechanicTarget = nil
    state.MechanicStartedAt = now
    state.MechanicDeadline = now + 0.55
    self._recoveryGoal = goal or (self._intent and self._intent.goal)
    self._intent = nil
    self._intentUntil = 0
end

function NorthernLands:_normal(now)
    local state = self.State
    if state.CurrentMechanic ~= "NORMAL" then state.LastMechanic = state.CurrentMechanic end
    state.CurrentMechanic = "NORMAL"
    state.CurrentPhase = "NORMAL"
    state.MechanicTarget = nil
    state.MechanicStartedAt = now
    state.MechanicDeadline = 0
    self._recoveryGoal = nil
    self._intent = nil
    self._intentUntil = 0
end

function NorthernLands:Reset()
    self._slam = nil
    self._requiredColor = nil
    self._safeColorActive = false
    self._safeDeadline = 0
    self.State.CurrentBoss = nil
    self:_normal(os.clock())
end

function NorthernLands:Snapshot()
    local copy = {}
    for key, value in pairs(self.State) do copy[key] = value end
    return copy
end

function NorthernLands:_risk(context, position, margin, arrival)
    return self._geometry.risk(context.zones, position, margin or 4, arrival)
end

function NorthernLands:_pathRisk(context, position, margin)
    local start = context.rootPart.Position
    local distance = flat(position - start).Magnitude
    local worst, sum = 0, 0
    local steps = math.max(2, math.min(8, math.ceil(distance / 4)))
    for index = 1, steps do
        local risk = self:_risk(context, start:Lerp(position, index / steps), margin or 3,
            distance * index / steps / math.max(context.humanoid.WalkSpeed, 1))
        worst = math.max(worst, risk)
        sum = sum + math.min(risk, 100)
    end
    return worst, sum
end

function NorthernLands:_ground(context, position)
    local grounded = context.ground and context.ground(position) or position
    return Vector3.new(grounded.X, grounded.Y, grounded.Z)
end

function NorthernLands:_candidateScore(context, candidate, desired, options)
    options = options or {}
    candidate = self:_ground(context, candidate)
    if context.walkable and not context.walkable(candidate) then return nil end
    local distance = flat(candidate - context.rootPart.Position).Magnitude
    local arrival = math.min(1.5, distance / math.max(context.humanoid.WalkSpeed, 1))
    local risk = self:_risk(context, candidate, options.margin or 4, arrival)
    local worst, sum = self:_pathRisk(context, candidate, options.margin or 3)
    local pathSafe = self._geometry.segmentSafe(context.zones, context.rootPart.Position, candidate,
        options.margin or 3)
    local score = risk * 1200 + worst * 240 + sum * 14
        + (pathSafe and 0 or (options.allowExposure and 140 or 1200))
        + flat(candidate - desired).Magnitude * (options.desiredWeight or 1)
        + distance * (options.distanceWeight or 0.15)
    return score, candidate, risk, pathSafe
end

function NorthernLands:_pick(context, candidates, desired, options, extraScore)
    local best, bestScore, bestRisk, bestSafe
    for _, candidate in ipairs(candidates) do
        local score, grounded, risk, pathSafe = self:_candidateScore(context, candidate, desired, options)
        if score then
            if extraScore then score = score + (extraScore(grounded) or 0) end
            if not bestScore or score < bestScore then
                best, bestScore, bestRisk, bestSafe = grounded, score, risk, pathSafe
            end
        end
    end
    return best, bestRisk, bestSafe
end

function NorthernLands:_commitIntent(context, mechanic, objective, goal, reason, lease, fields)
    self:_setMechanic(mechanic, fields and fields.target or nil, context.now,
        fields and fields.deadline or context.now + lease)
    local intent = {
        mechanic = mechanic,
        objective = objective,
        goal = goal,
        reason = reason,
        mandatory = fields and fields.mandatory or false,
        allowAttack = fields and fields.allowAttack or false,
        forceBlink = fields and fields.forceBlink or false,
        hold = fields and fields.hold or false,
        threat = fields and fields.threat or nil,
        emergencyFirst = fields and fields.emergencyFirst or false,
    }
    self._intent = intent
    self._intentUntil = context.now + lease
    return intent
end

function NorthernLands:_reuse(context, mechanic, target, drift)
    local intent = self._intent
    if not intent or intent.mechanic ~= mechanic or context.now >= self._intentUntil then return nil end
    if target and self.State.MechanicTarget ~= target then return nil end
    if intent.goal then
        if flat(intent.goal - context.rootPart.Position).Magnitude <= 1.5 then return nil end
        local goalRisk = self:_risk(context, intent.goal, 3)
        local currentRisk = self:_risk(context, context.rootPart.Position, 3)
        if goalRisk > currentRisk + (drift or 0.2) then return nil end
    end
    return intent
end

function NorthernLands:_activeOrb(context)
    local current = (self.State.CurrentMechanic == "ORB_GUIDE" or self.State.CurrentMechanic == "ORB_SETUP")
        and self.State.MechanicTarget or nil
    if current and current.Parent and self._orbs[current] and self:_orbTargetsPlayer(current, context) then
        return current, self._orbs[current]
    end
    local best, bestColor, bestDistance
    for orb, color in pairs(self._orbs) do
        if orb.Parent and orb.Transparency < 0.95 and self:_orbTargetsPlayer(orb, context) then
            local distance = flat(orb.Position - context.rootPart.Position).Magnitude
            if not bestDistance or distance < bestDistance then
                best, bestColor, bestDistance = orb, color, distance
            end
        end
    end
    return best, bestColor
end

function NorthernLands:_orbVelocity(orb, now)
    local sample = self._orbSamples[orb]
    local observed = Vector3.zero
    if sample and now > sample.at then observed = (orb.Position - sample.position) / (now - sample.at) end
    local assembly = orb.AssemblyLinearVelocity
    local velocity = flat(assembly.Magnitude > observed.Magnitude and assembly or observed)
    if velocity.Magnitude > 90 then velocity = velocity.Unit * 90 end
    self._orbSamples[orb] = { at = now, position = orb.Position, velocity = velocity }
    return velocity
end

function NorthernLands:_orbTargetsPlayer(orb, context)
    local character = context.rootPart.Parent
    for _, descendant in ipairs(orb:GetDescendants()) do
        if descendant:IsA("ObjectValue") and descendant.Name:lower():find("target", 1, true) then
            if descendant.Value == self._player or descendant.Value == character
                or descendant.Value and descendant.Value:IsDescendantOf(character) then return true end
            if descendant.Value then return false end
        elseif descendant:IsA("Beam") then
            for _, attachment in ipairs({ descendant.Attachment0, descendant.Attachment1 }) do
                if attachment and attachment:IsDescendantOf(character) then return true end
            end
        end
    end
    for _, key in ipairs({ "Target", "target", "TargetUserId", "targetUserId" }) do
        local value = orb:GetAttribute(key)
        if value == self._player or value == character or tostring(value) == self._player.Name
            or tonumber(value) == self._player.UserId then return true end
        if value ~= nil and value ~= self._player.Name then return false end
    end
    if #game:GetService("Players"):GetPlayers() == 1 then return true end
    local sample = self._orbSamples[orb]
    local velocity = sample and sample.velocity or flat(orb.AssemblyLinearVelocity)
    local toward = flat(context.rootPart.Position - orb.Position)
    if velocity.Magnitude > 2 and toward.Magnitude > 0.1 and velocity.Unit:Dot(toward.Unit) > 0.65 then
        local nearest = math.huge
        for _, other in ipairs(game:GetService("Players"):GetPlayers()) do
            local root = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
            if root then nearest = math.min(nearest, flat(root.Position - orb.Position).Magnitude) end
        end
        return toward.Magnitude <= nearest + 3
    end
    return false
end

function NorthernLands:_guideOrb(context, orb, color)
    local crystal = self._crystals[color]
    if not crystal or not crystal.Parent then
        return self:_commitIntent(context, "ORB_SETUP", NorthernLands.Objective.MATCH_COLOR,
            context.rootPart.Position, "Locating " .. color .. " crystal", 0.15,
            { target = orb, mandatory = true, hold = true })
    end
    local velocity = self:_orbVelocity(orb, context.now)
    local predictedOrb = orb.Position + velocity * 0.25
    local towardCrystal = unitOr(crystal.Position - predictedOrb)
    local standOff = math.clamp(9 + velocity.Magnitude * 0.06, 9, 14)
    local desired = crystal.Position + towardCrystal * standOff
    local tangent = Vector3.new(-towardCrystal.Z, 0, towardCrystal.X)
    local candidates = {}
    for _, along in ipairs({ standOff, standOff + 3, math.max(8, standOff - 2) }) do
        local base = crystal.Position + towardCrystal * along
        table.insert(candidates, base)
        table.insert(candidates, base + tangent * 3)
        table.insert(candidates, base - tangent * 3)
    end
    local orbDistance = flat(orb.Position - context.rootPart.Position).Magnitude
    if orbDistance < 14 then
        local away = unitOr(context.rootPart.Position - predictedOrb, tangent)
        table.insert(candidates, context.rootPart.Position + rotate(away, math.pi / 2) * 10)
        table.insert(candidates, context.rootPart.Position + rotate(away, -math.pi / 2) * 10)
    end
    local function trajectoryPenalty(candidate)
        local penalty = self._geometry.segmentDistance(crystal.Position, predictedOrb, candidate) * 28
        if flat(candidate - crystal.Position):Dot(towardCrystal) < 4 then penalty = penalty + 900 end
        local distanceFromOrb = flat(candidate - predictedOrb).Magnitude
        if distanceFromOrb < 11 then penalty = penalty + (11 - distanceFromOrb) * 180 end
        for otherColor, wrong in pairs(self._crystals) do
            if otherColor ~= color and wrong.Parent
                and self._geometry.segmentDistance(wrong.Position, predictedOrb, candidate) < 8 then
                penalty = penalty + 1400
            end
        end
        return penalty
    end
    local goal, goalRisk = self:_pick(context, candidates, desired,
        { margin = 4, allowExposure = true, desiredWeight = 1.5 }, trajectoryPenalty)
    if not goal then
        return self:_commitIntent(context, "ORB_GUIDE", NorthernLands.Objective.GUIDE_PROJECTILE,
            context.rootPart.Position, "Holding orb line for " .. color .. " crystal", 0.12,
            { target = orb, mandatory = true, hold = true, emergencyFirst = true })
    end
    local currentRisk = self:_risk(context, context.rootPart.Position, 4)
    local emergencyFirst = currentRisk > 2 and goalRisk >= currentRisk - 0.1
    return self:_commitIntent(context, "ORB_GUIDE", NorthernLands.Objective.GUIDE_PROJECTILE,
        goal, "Guiding " .. color .. " orb into matching crystal", orbDistance < 14 and 0.18 or 0.4,
        { target = orb, mandatory = true, forceBlink = orbDistance < 9 and goalRisk < currentRisk,
            threat = orb, emergencyFirst = emergencyFirst })
end

function NorthernLands:_matchingSafeZones(color)
    local zones = {}
    for part in pairs(self._safeZoneParts) do
        if part.Parent then
            local zoneColor = instanceColor(part)
            local parent = part.Parent
            while not zoneColor and parent and parent.Name ~= "bonusBossColorSafeSpots" do
                zoneColor = instanceColor(parent)
                if not zoneColor then
                    local beam = parent:FindFirstChildWhichIsA("Beam", true)
                    local keypoint = beam and beam.Color.Keypoints[1]
                    zoneColor = keypoint and closestColor(keypoint.Value) or nil
                end
                parent = parent.Parent
            end
            if zoneColor == color then table.insert(zones, part) end
        end
    end
    return zones
end

function NorthernLands:_safeZone(context)
    local color = self._requiredColor
    if not color then return nil end
    local zones = self:_matchingSafeZones(color)
    if #zones == 0 then
        return self:_commitIntent(context, "COLOR_MECHANIC", NorthernLands.Objective.MATCH_COLOR,
            context.rootPart.Position, "Waiting for " .. color .. " safe zone", 0.12,
            { mandatory = true, hold = true, deadline = self._safeDeadline })
    end
    local best, bestScore, bestRadius
    for _, part in ipairs(zones) do
        local position = instancePosition(part)
        if position then
            local radius = math.max(6, math.min(18, math.max(part.Size.X, part.Size.Z) * 0.45))
            local distance = flat(position - context.rootPart.Position).Magnitude
            local risk = self:_risk(context, position, 2)
            local pathPenalty = self._geometry.segmentSafe(context.zones, context.rootPart.Position, position, 2) and 0 or 90
            local score = distance + risk * 500 + pathPenalty
            if not bestScore or score < bestScore then best, bestScore, bestRadius = position, score, radius end
        end
    end
    if not best then return nil end
    if flat(context.rootPart.Position - best).Magnitude <= bestRadius then
        return self:_commitIntent(context, "COLOR_MECHANIC", NorthernLands.Objective.HOLD_POSITION,
            context.rootPart.Position, "Holding inside " .. color .. " safe zone", 0.18,
            { mandatory = true, hold = true, deadline = self._safeDeadline })
    end
    local direction = unitOr(best - context.rootPart.Position)
    local tangent = Vector3.new(-direction.Z, 0, direction.X)
    local candidates = { best }
    local directSafe = self._geometry.segmentSafe(context.zones, context.rootPart.Position, best, 2)
        and (not context.walkable or context.walkable(best))
    if not directSafe then
        local step = math.min(12, flat(best - context.rootPart.Position).Magnitude)
        for _, side in ipairs({ 0, 1, -1 }) do
            table.insert(candidates, context.rootPart.Position + direction * step + tangent * side * 5)
        end
    end
    local goal, goalRisk = self:_pick(context, candidates, best,
        { margin = 2, allowExposure = true, desiredWeight = 2.5 })
    if not goal then
        return self:_commitIntent(context, "COLOR_MECHANIC", NorthernLands.Objective.MATCH_COLOR,
            context.rootPart.Position, "Searching for a safe route to " .. color .. " zone", 0.12,
            { mandatory = true, hold = true, deadline = self._safeDeadline, emergencyFirst = true })
    end
    local currentRisk = self:_risk(context, context.rootPart.Position, 3)
    return self:_commitIntent(context, "COLOR_MECHANIC", NorthernLands.Objective.ENTER_SAFE_ZONE,
        goal, "Entering " .. color .. " safe zone", 0.22,
        { mandatory = true, deadline = self._safeDeadline,
            forceBlink = currentRisk > 0 and (goalRisk or math.huge) < currentRisk,
            emergencyFirst = currentRisk > 3 and (goalRisk or math.huge) >= currentRisk })
end

function NorthernLands:_slamZone(context)
    for _, zone in ipairs(context.zones) do if isSlam(zone) then return zone end end
    return nil
end

function NorthernLands:_combinedEscape(context, threat, preferSide)
    local root = context.rootPart.Position
    local bossPosition = context.targetRoot and context.targetRoot.Position or root - Vector3.new(0, 0, 1)
    local radial = unitOr(root - bossPosition)
    local tangent = Vector3.new(-radial.Z, 0, radial.X)
    local candidates = {}
    for _, distance in ipairs({ 10, 15, 21 }) do
        for index = 0, 11 do
            local direction = rotate(radial, index * math.pi / 6)
            table.insert(candidates, root + direction * distance)
        end
    end
    local function extra(candidate)
        local move = unitOr(candidate - root)
        local side = move:Dot(tangent) >= 0 and 1 or -1
        local bossDistance = flat(candidate - bossPosition).Magnitude
        local rangePenalty = math.abs(math.clamp(bossDistance, 14, 32) - bossDistance) * 12
        return rangePenalty + (side == preferSide and 0 or 26)
    end
    local goal, goalRisk = self:_pick(context, candidates, root,
        { margin = 5, allowExposure = true, desiredWeight = 0.05 }, extra)
    if goal then
        local side = unitOr(goal - root):Dot(tangent) >= 0 and 1 or -1
        self._escapeSide = side
    end
    return goal, goalRisk
end

function NorthernLands:_slamIntent(context, zone)
    self._slam = self._slam or { startedAt = context.now, committed = false, stableAt = context.now }
    local slam = self._slam
    local position = zone and zone.frame.Position or slam.landing
    if position then
        if slam.lastPosition then
            if flat(position - slam.lastPosition).Magnitude <= 0.35 then
                slam.stableAt = slam.stableAt or context.now
            else
                slam.stableAt = context.now
            end
        end
        slam.lastPosition = position
    end
    if zone and zone.live and slam.stableAt and context.now - slam.stableAt >= 0.12 then slam.committed = true end
    if context.now - slam.startedAt >= 0.55 then slam.committed = true end

    if not slam.committed then
        local currentRisk = self:_risk(context, context.rootPart.Position, 4)
        if currentRisk > 0 then
            local goal, goalRisk = self:_combinedEscape(context, zone, self._escapeSide)
            if goal and goalRisk < currentRisk then
                return self:_commitIntent(context, "SLAM_BAIT", NorthernLands.Objective.BAIT_POSITION,
                    goal, "Preserving a clear slam escape lane", 0.2,
                    { target = zone and zone.id, threat = zone and zone.id })
            end
        end
        return self:_commitIntent(context, "SLAM_BAIT", NorthernLands.Objective.BAIT_POSITION,
            context.rootPart.Position, "Baiting Midgardian jump slam", 0.14,
            { target = zone and zone.id, hold = true })
    end

    local reused = self:_reuse(context, "SLAM_ESCAPE", zone and zone.id, 0.5)
    if reused then return reused end
    local currentRisk = self:_risk(context, context.rootPart.Position, 5)
    local goal, goalRisk = self:_combinedEscape(context, zone, self._escapeSide)
    if not goal then return nil end
    slam.escapeGoal = goal
    slam.escapeAt = context.now
    return self:_commitIntent(context, "SLAM_ESCAPE", NorthernLands.Objective.ESCAPE_AREA,
        goal, "Escaping committed slam and beam geometry", 0.55,
        { target = zone and zone.id, threat = zone and zone.id,
            forceBlink = currentRisk > 0 and goalRisk < currentRisk })
end

function NorthernLands:_projectileIntent(context, zone)
    local clearance = self._geometry.clearance(zone, context.rootPart.Position, 7, 0.35)
    if clearance > 12 then return nil end
    local reused = self:_reuse(context, "PROJECTILE_ESCAPE", zone.id, 0.25)
    if reused then return reused end
    local velocity = unitOr(zone.velocity or zone.frame.LookVector)
    local perpendicular = Vector3.new(-velocity.Z, 0, velocity.X)
    local towardBoss = context.targetRoot and unitOr(context.targetRoot.Position - context.rootPart.Position) or Vector3.zero
    local candidates = {}
    for _, distance in ipairs({ 10, 15, 20 }) do
        table.insert(candidates, context.rootPart.Position + perpendicular * distance + towardBoss * 3)
        table.insert(candidates, context.rootPart.Position - perpendicular * distance + towardBoss * 3)
    end
    local function extra(candidate)
        local side = flat(candidate - context.rootPart.Position):Dot(perpendicular) >= 0 and 1 or -1
        return side == self._escapeSide and 0 or 24
    end
    local goal, goalRisk = self:_pick(context, candidates, context.rootPart.Position,
        { margin = 4, allowExposure = true, desiredWeight = 0.1 }, extra)
    if not goal then return nil end
    self._escapeSide = flat(goal - context.rootPart.Position):Dot(perpendicular) >= 0 and 1 or -1
    local currentRisk = self:_risk(context, context.rootPart.Position, 4)
    return self:_commitIntent(context, "PROJECTILE_ESCAPE", NorthernLands.Objective.CROSS_CORRIDOR,
        goal, "Crossing Northern projectile corridor", 0.38,
        { target = zone.id, threat = zone.id, forceBlink = currentRisk > 0 and goalRisk < currentRisk })
end

function NorthernLands:_beamSector(context, beams)
    local reused = self:_reuse(context, "BEAM_AVOIDANCE", beams[1] and beams[1].id, 0.35)
    if reused then return reused end
    local boss = context.targetRoot.Position
    local radial = unitOr(context.rootPart.Position - boss)
    local distance = math.clamp(flat(context.rootPart.Position - boss).Magnitude, 17, 24)
    local candidates = { context.rootPart.Position }
    for _, angle in ipairs({ 0, math.pi / 10, -math.pi / 10, math.pi / 5, -math.pi / 5 }) do
        table.insert(candidates, boss + rotate(radial, angle) * distance)
    end
    local function extra(candidate)
        local direction = unitOr(candidate - boss)
        local side = radial:Cross(direction).Y >= 0 and 1 or -1
        local anglePenalty = (1 - math.clamp(radial:Dot(direction), -1, 1)) * 35
        local tangent = Vector3.new(-direction.Z, 0, direction.X)
        local openLanes = 0
        for _, laneSide in ipairs({ 1, -1 }) do
            local probe = self:_ground(context, candidate + tangent * laneSide * 14)
            if (not context.walkable or context.walkable(probe)) and self:_risk(context, probe, 4) == 0 then
                openLanes = openLanes + 1
            end
        end
        return anglePenalty + (side == self._sectorSide and 0 or 12) + (2 - openLanes) * 55
    end
    local goal = self:_pick(context, candidates, context.rootPart.Position,
        { margin = 5, desiredWeight = 0.2 }, extra)
    if not goal then return nil end
    local direction = unitOr(goal - boss)
    self._sectorSide = radial:Cross(direction).Y >= 0 and 1 or -1
    local holding = flat(goal - context.rootPart.Position).Magnitude <= 1.75
    return self:_commitIntent(context, "BEAM_AVOIDANCE",
        holding and NorthernLands.Objective.HOLD_POSITION or NorthernLands.Objective.ROTATE_AROUND_CENTER,
        holding and context.rootPart.Position or goal, "Holding a local lane between passive beams", 0.5,
        { target = beams[1] and beams[1].id, allowAttack = true, hold = holding })
end

function NorthernLands:_odinGap(context)
    local attacks = {}
    for _, zone in ipairs(context.zones) do if isOdinAttack(zone) then table.insert(attacks, zone) end end
    if #attacks == 0 then return nil end
    local reused = self:_reuse(context, "SAFE_GAP_TRAVEL", attacks[1].id, 0.4)
    if reused then return reused end
    local center = context.targetRoot.Position
    local current = unitOr(context.rootPart.Position - center)
    local radius = math.clamp(flat(context.rootPart.Position - center).Magnitude, 16, 25)
    local candidates = { context.rootPart.Position }
    for index = -6, 6 do
        table.insert(candidates, center + rotate(current, index * math.pi / 18) * radius)
    end
    local function extra(candidate)
        local direction = unitOr(candidate - center)
        return (1 - math.clamp(current:Dot(direction), -1, 1)) * 80
    end
    local goal, goalRisk = self:_pick(context, candidates, context.rootPart.Position,
        { margin = 4, allowExposure = true, desiredWeight = 0.15 }, extra)
    if not goal then return nil end
    local currentRisk = self:_risk(context, context.rootPart.Position, 4)
    local holding = currentRisk == 0 and flat(goal - context.rootPart.Position).Magnitude <= 1.75
    return self:_commitIntent(context, "SAFE_GAP_TRAVEL",
        holding and NorthernLands.Objective.HOLD_POSITION or NorthernLands.Objective.ROTATE_AROUND_CENTER,
        holding and context.rootPart.Position or goal, "Using nearest safe gap in Odin attack", 0.45,
        { target = attacks[1].id, allowAttack = true, hold = holding,
            forceBlink = currentRisk > 0 and goalRisk < currentRisk })
end

function NorthernLands:Update(context)
    if not isNorthernLands(self._workspace) then
        if self.State.CurrentBoss or self.State.CurrentMechanic ~= "NORMAL" then self:Reset() end
        return nil
    end
    context.now = context.now or os.clock()
    context.zones = context.zones or {}
    local kind = bossKind(context.target)
    local orb, orbColor = self:_activeOrb(context)
    if orb and not kind then kind = "BOB_THE_FROST_GIANT" end
    if not kind and self._slam and context.now - self._slam.startedAt < 3 then
        kind = self.State.CurrentBoss or "MIDGARDIAN_CHAMPION"
    end
    if kind ~= self.State.CurrentBoss then
        self.State.CurrentBoss = kind
        self._intent = nil
        self._intentUntil = 0
        self._slam = nil
        if self.State.CurrentMechanic ~= "COLOR_MECHANIC" then self:_normal(context.now) end
    end

    if self._requiredColor and context.now <= self._safeDeadline + 0.5 then
        local intent = self:_safeZone(context)
        if intent then return intent end
    elseif self._requiredColor and context.now > self._safeDeadline + 0.5 then
        self._requiredColor = nil
        self._safeColorActive = false
        self:_beginRecovery(context.now)
    end

    if kind == "BOB_THE_FROST_GIANT" or self.State.CurrentMechanic == "ORB_GUIDE"
        or self.State.CurrentMechanic == "ORB_SETUP" then
        if orb and orbColor then
            local reused = self:_reuse(context, "ORB_GUIDE", orb, 0.35)
            if reused then
                local crystal = self._crystals[orbColor]
                if crystal then
                    local error = self._geometry.segmentDistance(crystal.Position, orb.Position,
                        reused.goal or context.rootPart.Position)
                    if error <= 5 then return reused end
                end
            end
            return self:_guideOrb(context, orb, orbColor)
        elseif self.State.CurrentMechanic == "ORB_GUIDE" or self.State.CurrentMechanic == "ORB_SETUP" then
            self:_beginRecovery(context.now)
        end
    end

    if kind == "MIDGARDIAN_CHAMPION" then
        local slamZone = self:_slamZone(context)
        if slamZone or self._slam and context.now - self._slam.startedAt < 3 then
            local intent = self:_slamIntent(context, slamZone)
            if intent then return intent end
        elseif self.State.CurrentMechanic == "SLAM_ESCAPE" or self.State.CurrentMechanic == "SLAM_BAIT" then
            self:_beginRecovery(context.now, self._slam and self._slam.escapeGoal)
            self._slam = nil
        end
        for _, zone in ipairs(context.zones) do
            if isFirstBossProjectile(zone) then
                local intent = self:_projectileIntent(context, zone)
                if intent then return intent end
            end
        end
        local beams = {}
        for _, zone in ipairs(context.zones) do if isPassiveBeam(zone) then table.insert(beams, zone) end end
        if #beams > 0 and context.targetRoot then
            local intent = self:_beamSector(context, beams)
            if intent then return intent end
        end
    elseif kind == "ODIN" or kind == "ODIN_REINCARNATION" then
        if context.targetRoot then
            local intent = self:_odinGap(context)
            if intent then return intent end
        end
    end

    if self.State.CurrentMechanic == "RECOVERY" then
        if context.now < self.State.MechanicDeadline then
            local goal = self._recoveryGoal
            if goal and flat(goal - context.rootPart.Position).Magnitude > 1.5
                and self:_risk(context, goal, 3) <= self:_risk(context, context.rootPart.Position, 3) then
                return {
                    mechanic = "RECOVERY",
                    objective = NorthernLands.Objective.HOLD_POSITION,
                    goal = goal,
                    reason = "Recovering from " .. tostring(self.State.LastMechanic or "mechanic"),
                    allowAttack = true,
                }
            end
        else
            self:_normal(context.now)
        end
    elseif self.State.CurrentMechanic ~= "NORMAL" then
        self:_beginRecovery(context.now)
    end
    return nil
end

return NorthernLands
