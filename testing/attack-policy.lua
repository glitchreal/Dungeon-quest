local Policy = assert(loadfile("src/AttackPolicy.luau"))()
local function instance(attributes, children)
    return {
        GetAttributes = function() return attributes or {} end,
        GetChildren = function() return children or {} end,
    }
end
local humanoid = instance()
humanoid.Health = 100
local boss = instance({ Anchored = true, Active = false })
boss.Parent = {}
boss.FindFirstChildOfClass = function() return humanoid end
assert(Policy.damageable(boss), "generic activity/anchoring is not immunity")
boss.GetAttributes = function() return { Invulnerable = true } end
assert(not Policy.damageable(boss))
boss.GetAttributes = function() return { Invulnerable = false, Damageable = true } end
assert(Policy.damageable(boss))
humanoid.GetChildren = function()
    return { { Name = "CanBeDamaged", Value = false, IsA = function(_, class) return class == "BoolValue" end } }
end
assert(not Policy.damageable(boss), "explicit BoolValue denies damage")
humanoid.GetChildren = function() return {} end
humanoid.Health = 0
assert(not Policy.damageable(boss))
humanoid.Health = 100
local vector = {}
vector.__sub = function(a, b)
    return { Magnitude = math.sqrt((a.X-b.X)^2 + (a.Y-b.Y)^2 + (a.Z-b.Z)^2) }
end
local function v(x,y,z) return setmetatable({X=x,Y=y,Z=z}, vector) end
assert(Policy.inRange(v(0,0,0), v(8,20,0), 26), "elevated target within 3D range is attackable")
assert(not Policy.inRange(v(0,0,0), v(8,30,0), 26), "horizontal proximity cannot bypass vertical range")
assert(Policy.horizontalRange(25,20) == 15, "ground spacing accounts for height")
assert(Policy.horizontalRange(25,30) == 0)
assert(Policy.range({mode="target",range=40},26) == 40)
assert(Policy.range({mode="self",radius=10},26) == 10)
assert(Policy.range({mode="heal",range=40},26) == nil)
print("Attack policy checks passed")
