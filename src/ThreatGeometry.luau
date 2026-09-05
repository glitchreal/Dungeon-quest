local Geometry = {}

function Geometry.clearance(zone, position, margin)
    local point = zone.frame:PointToObjectSpace(position)
    local half = zone.size * 0.5
    if zone.shape == "Cylinder" then
        return math.max(math.abs(point.X) - half.X - 4,
            Vector2.new(point.Y, point.Z).Magnitude - math.max(half.Y, half.Z) - margin)
    end
    if zone.shape == "Projectile" then
        local delta = zone.velocity * zone.lookahead
        local offset = position - zone.frame.Position
        local fraction = delta:Dot(delta) > 0.001 and math.clamp(offset:Dot(delta) / delta:Dot(delta), 0, 1) or 0
        return (offset - delta * fraction).Magnitude - math.max(half.X, half.Y, half.Z) - margin
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
    local steps = math.max(1, math.ceil((endPosition - startPosition).Magnitude))
    for _, zone in ipairs(zones) do
        local previous = Geometry.clearance(zone, startPosition, margin)
        for i = 1, steps do
            local clearance = Geometry.clearance(zone, startPosition:Lerp(endPosition, i / steps), margin)
            if clearance < math.min(0, previous) - 0.02 then return false end
            previous = clearance
        end
    end
    return true
end

return Geometry
