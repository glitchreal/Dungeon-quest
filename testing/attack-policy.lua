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
vector.__index = function(a,key)
    if key == "Magnitude" then return math.sqrt(a.X*a.X+a.Y*a.Y+a.Z*a.Z) end
end
local function v(x,y,z) return setmetatable({X=x,Y=y,Z=z}, vector) end
vector.__sub = function(a, b)
    return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z)
end
assert(Policy.inRange(v(0,0,0), v(8,20,0), 26), "elevated target within 3D range is attackable")
assert(not Policy.inRange(v(0,0,0), v(8,30,0), 26), "horizontal proximity cannot bypass vertical range")
assert(Policy.horizontalRange(25,20) == 15, "ground spacing accounts for height")
assert(Policy.horizontalRange(25,30) == 0)
assert(Policy.range({mode="target",range=40},26) == 40)
assert(Policy.range({mode="self",radius=10},26) == 10)
assert(Policy.range({mode="heal",range=40},26) == nil)
assert(Policy.approachScore(34, 16, true, 26, 20) < Policy.approachScore(50, 0, true, 26, 20),
    "approach can improve while both positions are outside casting range")
assert(Policy.approachScore(21, 5, true, 26, 20) < Policy.approachScore(26, 0, true, 26, 20),
    "being barely in range does not prevent closing to combat spacing")
local Planner = assert(loadfile("src/FarmPlanner.luau"))()
local geyser = Planner.profile({name="Geyser",metadata={name="Fireball",abilitytype="spell"}})
assert(geyser.geometry == "forwardBurst" and geyser.forwardOffset == 40 and geyser.radius == 46)
assert(not geyser.verifiedRange, "client-effect dimensions are not verified server damage metadata")
assert(Policy.range(geyser,26) == 86)
assert(Policy.canHit(geyser,v(0,0,0),v(40,30,0),26,function() return true end),
    "elevated boss inside Geyser burst can be attempted despite direct range/LOS rejection")
assert(not Policy.canHit(geyser,v(0,0,0),v(40,47,0),26), "AoE retains vertical limits")
assert(not Policy.canHit(geyser,v(0,0,0),v(87,0,0),26), "outside burst reach is rejected")
assert(not Policy.canHit(geyser,v(0,0,0),v(40,30,0),26,nil,v(-1,0,0)),
    "actual facing must place the burst over the target before activation")
assert(Policy.canHit(geyser,v(0,0,0),v(40,30,0),26,nil,v(1,0,0)))
local small = Planner.profile({name="Geyser",metadata={explosionradius=10}})
assert(not Policy.canHit(small,v(0,0,0),v(40,11,0),26), "explicit radius metadata overrides visual envelope")
assert(not Policy.canHit({mode="target",range=26},v(0,0,0),v(20,0,0),26,function() return true end),
    "direct-hit spells still require their normal visibility")
assert(not Policy.canHit({mode="target"},v(0,0,0),v(40,0,0),26),
    "another unknown spell does not inherit Geyser's larger reach")
print("Attack policy checks passed")
