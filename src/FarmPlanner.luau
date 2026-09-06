local Planner = {}

function Planner.profile(snapshot)
    local metadata = snapshot.metadata or {}
    local function number(...)
        for _, key in ipairs({ ... }) do
            local value = tonumber(metadata[key])
            if value and value > 0 then return value end
        end
    end
    local kind = tostring(metadata.abilitytype or ""):lower()
    local description = tostring(snapshot.description or ""):lower()
    local shape = tostring(metadata.targettype or metadata.targeting or metadata.shape or ""):lower()
    local range = number("range", "castrange", "attackrange", "maxdistance", "distance")
    local radius = number("radius", "aoeradius", "explosionradius", "hitradius")
    local mode = "target"
    if kind == "heal" or metadata.healamount then mode = "heal"
    elseif kind == "shield" then mode = "shield"
    elseif metadata.buffpower then mode = "buff"
    elseif shape == "self" or description:find("around you", 1, true) or description:find("around yourself", 1, true) then mode = "self"
    elseif shape == "splash" or shape == "area" or radius or description:find("explod", 1, true)
        or description:find("nearby enemies", 1, true) then mode = "splash" end
    return { mode = mode, range = range, radius = radius, verifiedRange = range ~= nil }
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
