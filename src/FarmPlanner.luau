local Planner = {}

-- Only confirmed ability types get special handling; unknown spells retain
-- normal targeting. Grouping radius is a heuristic, not a claimed damage radius.
function Planner.profile(name)
    if name == "Fireball" or name == "Blue Fireball" then return "splash" end
    if name == "Whirlwind" then return "self" end
    return "target"
end

function Planner.select(candidates, radius, connected)
    local best, bestCount, bestSpread = nil, 0, math.huge
    local radiusSquared = radius * radius
    for _, candidate in ipairs(candidates) do
        local count, spread = 1, 0
        for _, other in ipairs(candidates) do
            if other ~= candidate then
                local delta = other.position - candidate.position
                local squared = delta:Dot(delta)
                if squared <= radiusSquared and (not connected or connected(candidate, other)) then
                    count, spread = count + 1, spread + squared
                end
            end
        end
        if count > bestCount or (count == bestCount and (spread < bestSpread
            or (spread == bestSpread and (not best or candidate.distance < best.distance)))) then
            best, bestCount, bestSpread = candidate, count, spread
        end
    end
    return best, bestCount
end

function Planner.coolingDown(snapshots, usable)
    local equipped = false
    for _, snapshot in pairs(snapshots) do
        equipped = true
        if snapshot.cooldown <= 0 and (not usable or usable(snapshot)) then return false end
    end
    return equipped
end

return Planner
