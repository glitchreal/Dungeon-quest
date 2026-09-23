-- Authored checkpoint layers form a directed room graph. Multiple checkpoints
-- in one room are alternative entrances, never evidence of an arbitrary shortcut.
local Navigation = {}
Navigation.__index = Navigation
local function flatDistance(a, b)
    local x, z = a.X - b.X, a.Z - b.Z
    return math.sqrt(x * x + z * z)
end
local function cell(p)
    return math.floor(p.X / 12 + 0.5) .. ":" .. math.floor(p.Y / 8 + 0.5) .. ":" .. math.floor(p.Z / 12 + 0.5)
end
function Navigation.StartWaypoint(waypoints, position, canReach)
    local best, bestDistance
    -- Only join a nearby, reachable prefix. A later waypoint across a wall
    -- or on a stacked floor is not a valid shortcut into the middle of a path.
    for index, waypoint in ipairs(waypoints) do
        if index > 12 then break end
        local distance = (waypoint.Position - position).Magnitude
        if distance <= 24 and canReach(waypoint.Position) and (not bestDistance or distance < bestDistance) then
            best, bestDistance = index, distance
        end
        if tostring(waypoint.Action) == "Enum.PathWaypointAction.Jump" then break end
    end
    return best
end
function Navigation.new(memory)
    return setmetatable({ memory = memory, debug = {}, failedUntil = {}, epoch = 0 }, Navigation)
end
function Navigation:Reset()
    self.edge, self.watch, self.choice, self.anchors = nil, nil, nil, nil
    self.failedUntil, self.debug = {}, {}
    self.epoch = self.epoch + 1
end
function Navigation:Rebuild(anchors, dungeon)
    if self.anchors == anchors and self.dungeon == dungeon then return end
    self.anchors, self.dungeon, self.layers = anchors, dungeon, {}
    self.choice, self.edge, self.watch = nil, nil, nil
    self.epoch = self.epoch + 1
    for index, anchor in ipairs(anchors) do
        if index > 96 then break end
        local layer = self.layers[#self.layers]
        if not layer or layer.order ~= anchor.order or layer.name ~= anchor.name then
            layer = { order = anchor.order, name = anchor.name, nodes = {} }
            table.insert(self.layers, layer)
        end
        if #layer.nodes < 8 then
            table.insert(layer.nodes, { anchor = anchor, index = index,
                id = anchor.name .. "@" .. cell(anchor.part.Position) })
        end
    end
end
function Navigation:Key(from, node)
    return tostring(self.dungeon) .. "/" .. from .. ">" .. node.id
end
function Navigation:Cancel(reason)
    if self.edge or self.choice then
        self.epoch = self.epoch + 1
        self.watch = nil
    end
    self.choice, self.edge = nil, nil
    self.debug.CurrentRouteEdge, self.debug.RouteEdgeLearnedCost = nil, nil
    self.debug.ReplanReason = reason
end
function Navigation:Outcome(success, reason, now)
    local edge = self.edge
    if not edge then return end
    self.memory:Observe("route", edge.key, {}, success)
    if not success then
        self.failedUntil[edge.key] = now + 4
        local count = 0
        for key, expiry in pairs(self.failedUntil) do
            if expiry <= now then self.failedUntil[key] = nil else count = count + 1 end
        end
        if count > 96 then self.failedUntil = { [edge.key] = now + 4 } end
    end
    self.debug.ReplanReason = reason
    self.choice, self.edge, self.watch = nil, nil, nil
    self.epoch = self.epoch + 1
end
function Navigation:Goal(root, target, anchors, progress, dungeon, now, cost)
    self:Rebuild(anchors, dungeon)
    local targetLayer
    -- Prefer authored ancestry. Spatial assignment is bounded to checkpoint
    -- neighborhoods; unknown far enemies cannot pull the route across the map.
    local targetRoot = target and (target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart)
    if targetRoot then
        local best = 65
        for index, layer in ipairs(self.layers) do
            for _, node in ipairs(layer.nodes) do
                if node.anchor.part.Parent then
                    local parent = target.Parent
                    local inRoom = false
                    while parent and parent ~= workspace do
                        if parent == node.anchor.part.Parent then inRoom = true; break end
                        parent = parent.Parent
                    end
                    local distance = flatDistance(targetRoot.Position, node.anchor.part.Position)
                    if inRoom or distance < best and math.abs(targetRoot.Position.Y - node.anchor.part.Position.Y) < 14 then
                        targetLayer, best = index, inRoom and -1 or distance
                    end
                end
            end
        end
    end
    local nextLayer
    for index, layer in ipairs(self.layers) do
        if not progress or layer.order > progress.order or layer.order == progress.order and layer.name > progress.name then
            nextLayer = index; break
        end
    end
    if not nextLayer then self:Cancel("room graph complete"); return nil end
    if targetLayer and targetLayer < nextLayer then
        -- Explicit live target in a passed room is the only backward objective
        -- admitted here. Merely being close to an old checkpoint is insufficient.
        self:Cancel("live objective in current or previous room")
        return nil
    end
    local signature = tostring(nextLayer) .. ":" .. tostring(targetLayer)
    if self.choice and self.choice.signature == signature and now < self.choice.untilAt
        and self.choice.node.anchor.part.Parent then
        if now - (self.choice.checkedAt or 0) >= 0.15 then
            self.choice.checkedAt, self.choice.safe = now, cost(self.choice.goal) < 1000
        end
        if self.choice.safe then return self.choice.goal, self.choice.node.anchor end
    end
    local last = math.min(targetLayer or nextLayer, nextLayer + 3, #self.layers)
    local from = progress and progress.name or "entry"
    local downstream = {}
    -- Bounded backwards dynamic programming over forward room edges.
    for layerIndex = last, nextLayer, -1 do
        for _, node in ipairs(self.layers[layerIndex].nodes) do
            if node.anchor.part.Parent then
                local continuation
                if layerIndex < last then
                    for _, other in ipairs(self.layers[layerIndex + 1].nodes) do
                        if other.anchor.part.Parent and downstream[other] then
                            local learned = self.memory:Cost("route", self:Key(node.anchor.name, other), {})
                            local score = flatDistance(node.anchor.part.Position, other.anchor.part.Position)
                                + learned + downstream[other]
                            continuation = math.min(continuation or math.huge, score)
                        end
                    end
                end
                downstream[node] = continuation or 0
            end
        end
    end
    local best, bestScore, bestGoal, bestDanger, oldScore, oldDanger
    for _, node in ipairs(self.layers[nextLayer].nodes) do
        if node.anchor.part.Parent then
            local goal = node.anchor.part.Position + Vector3.new(0, 2.5, 0)
            local key = self:Key(from, node)
            local learned, confidence = self.memory:Cost("route", key, {})
            local liveCost = cost(goal)
            local danger = math.floor(liveCost / 1000)
            local score = flatDistance(root.Position, goal) + liveCost + learned + (downstream[node] or 0)
                + ((self.failedUntil[key] or 0) > now and 250 or 0)
            if self.choice and self.choice.signature == signature and self.choice.node == node then
                oldScore, oldDanger = score, danger
            end
            if not bestScore or danger < bestDanger or danger == bestDanger and score < bestScore then
                best, bestScore, bestGoal = node, score, goal
                bestDanger = danger
                self.debug.RouteEdgeLearnedCost, self.debug.RouteConfidence = learned, confidence
            end
        end
    end
    if not best then return nil end
    if oldScore and oldDanger == bestDanger and oldScore < bestScore + 12 then
        best, bestGoal = self.choice.node, self.choice.goal
    end
    local key = self:Key(from, best)
    self.debug.RouteEdgeLearnedCost, self.debug.RouteConfidence = self.memory:Cost("route", key, {})
    if not self.edge or self.edge.key ~= key then self.watch = nil; self.epoch = self.epoch + 1 end
    self.edge = { key = key, goal = bestGoal, anchor = best.anchor }
    self.choice = { node = best, goal = bestGoal, untilAt = now + 1.5, signature = signature,
        checkedAt = now, safe = bestDanger == 0 }
    self.debug.CurrentRouteEdge, self.debug.TargetRoom = key, targetLayer and self.layers[targetLayer].name or "next room"
    return bestGoal, best.anchor
end
function Navigation:Progress(position, goal, remaining, now)
    local watch = self.watch
    if not watch or flatDistance(goal, watch.goal) > 6 then
        self.watch = { goal = goal, best = flatDistance(position, goal), at = now, lastAt = now, remaining = remaining }
        return false
    end
    -- Hazard/mechanic owners suspend route progress monitoring; their elapsed
    -- time must not be attributed as a navigation failure on resumption.
    if now - watch.lastAt > 1 then watch.at = now end
    watch.lastAt = now
    local distance = flatDistance(position, goal)
    -- Remaining path length can improve during a necessary detour. It is a
    -- best-ever measure for this objective, so path replacement cannot reset it.
    if distance < watch.best - 2 or remaining and watch.remaining and remaining < watch.remaining - 3 then
        watch.best, watch.at = math.min(watch.best, distance), now
        if remaining then watch.remaining = math.min(watch.remaining or remaining, remaining) end
    elseif remaining and not watch.remaining then watch.remaining = remaining end
    self.debug.StuckScore = math.min(1, (now - watch.at) / 8)
    if now - watch.at >= 8 then
        self:Outcome(false, "objective progress stalled", now)
        self.watch = nil
        return true
    end
    return false
end
function Navigation:LocalCost(start, goal)
    return self.memory:Cost("route", tostring(self.dungeon) .. "/local/" .. cell(start) .. ">" .. cell(goal), {})
end
function Navigation:LocalOutcome(start, goal, success)
    self.memory:Observe("route", tostring(self.dungeon) .. "/local/" .. cell(start) .. ">" .. cell(goal), {}, success)
end
return Navigation
