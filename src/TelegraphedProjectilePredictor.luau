-- Client-observed Northern event payloads. All forecasts become ordinary
-- ThreatGeometry zones, so movement owners share the same safety decisions.
local Predictor = {}
Predictor.events = {
    ["First Boss Seeking Spike"] = { template = "firstBossSeekingSpikes", beam = "firstBossBeamPart", kind = "SHURIKEN_ESCAPE" },
    ["First Boss Big Spike"] = { template = "firstBossBigSpike", beam = "firstBossBeamPart", kind = "SHURIKEN_ESCAPE" },
    ["First Boss Criss Cross Projectile"] = { template = "firstBossCrissCross", kind = "SHURIKEN_ESCAPE" },
    ["Third Boss Sideways Missile"] = { template = "thirdBossMissile", beam = "thirdBossBeamPart", offset = -10, kind = "ROCKET_ESCAPE" },
    ["Second Boss Moving Beam"] = { template = "secondBossMovingBeam", kind = "LASER_ESCAPE" },
}

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

function Predictor.decode(action, data, size, now, serverNow)
    local spec = Predictor.events[action]
    if not spec or type(data) ~= "table" or not size then return nil end
    for index = 1, 4 do if not finite(data[index]) then return nil end end
    if typeof(data[5]) ~= "CFrame" or data[2] <= 0 or data[2] > 15
        or data[1] <= 0 or data[1] > 2000 then return nil end
    local remaining = data[4] - serverNow
    if remaining < 0 or remaining > 15 or data[4] < data[3] then return nil end
    local origin = data[5] + data[5].LookVector * (spec.offset or 0)
    -- Spinning effects need an orientation-independent envelope. This is a
    -- conservative client-effect estimate, never claimed as a server hitbox.
    return { frame = origin, origin = origin, travel = origin.LookVector * data[1],
        duration = data[2], starts = now + data[3] - serverNow,
        expires = now + remaining, velocity = origin.LookVector * (data[1] / data[2]),
        size = size, shape = "Projectile", lookahead = 0.8, id = {}, name = action,
        predictive = true, strategy = spec.kind, beamName = spec.beam,
        projectileRadius = math.max(size.X, size.Y, size.Z) * 0.5 }
end

function Predictor.advance(zone, now)
    zone.frame = zone.origin + zone.travel * math.clamp((now - zone.starts) / zone.duration, 0, 1)
    zone.lookahead = math.min(0.8, math.max(0, zone.expires - math.max(now, zone.starts)))
end

-- Time until the leading edge reaches a stationary position, and the two
-- perpendicular distances needed to leave its corridor. Ignore spent lanes.
function Predictor.intersection(zone, position, now, margin)
    if not zone.predictive or now > zone.expires then return nil end
    local speed = zone.velocity.Magnitude
    if speed < 0.01 then return nil end
    local direction = zone.velocity.Unit
    local offset = position - zone.origin.Position
    local along = offset:Dot(direction)
    local lateral = offset - direction * along
    local radius = zone.projectileRadius + (margin or 4)
    local horizontal = Vector3.new(-direction.Z, 0, direction.X)
    if horizontal.Magnitude < 0.01 or math.abs(lateral.Y) >= radius then return nil end
    horizontal = horizontal.Unit
    local signed = lateral:Dot(horizontal)
    local width = math.sqrt(math.max(0, radius * radius - lateral.Y * lateral.Y))
    if math.abs(signed) >= width or along < -radius or along > zone.travel.Magnitude + radius then return nil end
    local halfLength = math.sqrt(math.max(0, radius * radius - lateral:Dot(lateral)))
    local enter = zone.starts + math.max(0, along - halfLength) / speed
    local leave = math.min(zone.expires, zone.starts + (along + halfLength) / speed)
    if leave < now then return nil end
    return math.max(0, enter - now), horizontal, width - signed + 2, width + signed + 2
end

-- Suppress the static dotted corridor only when an event forecast for the
-- same line is present. A late attach/missed event retains the beam fallback.
function Predictor.matchesBeam(zone, name, first, last, now)
    if not zone.predictive or zone.beamName ~= name or now >= zone.expires then return false end
    local offset = Predictor.events[zone.name].offset or 0
    local start = zone.origin.Position - zone.origin.LookVector * offset
    return (first - start).Magnitude < 4 and (last - start - zone.travel).Magnitude < 5
end

return Predictor
