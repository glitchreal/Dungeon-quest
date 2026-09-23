-- Attack reach is independent of whether the enemy's floor is walkable.
local Policy = {}
local blockedFlags = { invulnerable = true, invincible = true, immune = true,
    damageable = false, candamage = false, canbedamaged = false, attackable = false }

function Policy.damageable(model)
    if not model or not model.Parent then return false end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end
    -- Only explicit boolean damage-state evidence is authoritative. Anchored,
    -- elevation, animation and a generic Active flag do not imply immunity.
    for _, instance in ipairs({ model, humanoid }) do
        for name, value in pairs(instance:GetAttributes()) do
            if type(value) == "boolean" and blockedFlags[name:lower()] == value then return false end
        end
        for _, child in ipairs(instance:GetChildren()) do
            if child:IsA("BoolValue") and blockedFlags[child.Name:lower()] == child.Value then return false end
        end
    end
    return true
end

function Policy.range(profile, fallback)
    if profile.geometry == "forwardBurst" then return profile.forwardOffset + profile.radius end
    if profile.mode == "self" then return profile.radius or profile.range or fallback end
    if profile.mode == "target" or profile.mode == "splash" then return profile.range or fallback end
    return nil
end

function Policy.canHit(profile, origin, target, fallback, blocked, facing)
    if profile.geometry == "forwardBurst" then
        -- This effect is placed directly ahead; it is not a projectile that
        -- must raycast into the enemy root. Test the burst volume, including Y.
        local direction = facing or (target - origin)
        local length = math.sqrt(direction.X * direction.X + direction.Z * direction.Z)
        if length < 0.001 then return false end
        local x = target.X - origin.X - direction.X / length * profile.forwardOffset
        local y = target.Y - origin.Y
        local z = target.Z - origin.Z - direction.Z / length * profile.forwardOffset
        return x*x + y*y + z*z <= profile.radius * profile.radius
    end
    return Policy.inRange(origin, target, Policy.range(profile, fallback))
        and (not blocked or not blocked(origin, target))
end

function Policy.inRange(origin, target, range)
    return range ~= nil and (target - origin).Magnitude <= range
end

function Policy.horizontalRange(range, height)
    return math.sqrt(math.max(0, range * range - height * height))
end

function Policy.approachScore(distance, travel, visible, range, spacing)
    -- Out-of-range ground points still make useful approach objectives.
    -- Favor closing the range deficit before optimizing travel or spacing.
    return math.max(0, distance - range) * 8 + math.abs(distance - spacing)
        + travel * 0.2 + (visible and 0 or 20)
end

return Policy
