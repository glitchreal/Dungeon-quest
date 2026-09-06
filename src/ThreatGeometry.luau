local Geometry = {}

function Geometry.segmentDistance(position, startPosition, endPosition)
    local delta = endPosition - startPosition
    local lengthSquared = delta:Dot(delta)
    local fraction = lengthSquared > 0.001 and math.clamp((position - startPosition):Dot(delta) / lengthSquared, 0, 1) or 0
    return (position - (startPosition + delta * fraction)).Magnitude
end

function Geometry.clearance(zone, position, margin)
    local point = zone.frame:PointToObjectSpace(position)
    local half = zone.size * 0.5
    if zone.shape == "Cylinder" then
        return math.max(math.abs(point.X) - half.X - 4,
            Vector2.new(point.Y, point.Z).Magnitude - math.max(half.Y, half.Z) - margin)
    end
    if zone.shape == "Projectile" then
        return Geometry.segmentDistance(position, zone.frame.Position, zone.frame.Position + zone.velocity * zone.lookahead)
            - math.max(half.X, half.Y, half.Z) - margin
    end
    return math.max(math.abs(point.X) - half.X - margin,
        math.abs(point.Y) - half.Y - 4, math.abs(point.Z) - half.Z - margin)
end

function Geometry.risk(zones, position, margin)
    local risk, nearest = 0, nil
    for _, zone in ipairs(zones) do
        local clearance = Geometry.clearance(zone, position, margin)
        if clearance < 0 then
            risk = risk + 1 + clearance * clearance
            if not nearest or clearance < nearest.clearance then nearest = { zone = zone, clearance = clearance } end
        end
    end
    return risk, nearest and nearest.zone
end

function Geometry.segmentSafe(zones, startPosition, endPosition, margin)
    local steps = math.max(1, math.ceil((endPosition - startPosition).Magnitude * 2))
    local initial = {}
    local previousRisk = 0
    for index, zone in ipairs(zones) do
        local clearance = Geometry.clearance(zone, startPosition, margin)
        initial[index] = clearance
        if clearance < 0 then previousRisk = previousRisk + 1 + clearance * clearance end
    end
    -- Overlapping telegraphs can require moving toward one edge while escaping
    -- the others. Reject new hazards, but judge existing overlaps together.
    for i = 1, steps do
        local position = startPosition:Lerp(endPosition, i / steps)
        local risk = 0
        for index, zone in ipairs(zones) do
            local clearance = Geometry.clearance(zone, position, margin)
            if initial[index] >= 0 and clearance < -0.02 then return false end
            if clearance < 0 then risk = risk + 1 + clearance * clearance end
        end
        if risk > previousRisk + 0.02 then return false end
        previousRisk = risk
    end
    return true
end

return Geometry
