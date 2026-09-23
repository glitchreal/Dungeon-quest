-- Offline policy checks with real block hazard geometry, no Roblox execution.
math.clamp = math.clamp or function(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local vector = {}
vector.__index = function(v, key)
    if key == "Magnitude" then return math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z) end
    if key == "Unit" then return v * (1 / v.Magnitude) end
    return vector[key]
end
local function v(x,y,z) return setmetatable({ X=x, Y=y, Z=z }, vector) end
vector.__add = function(a,b) return v(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
vector.__sub = function(a,b) return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
vector.__mul = function(a,n) return v(a.X*n,a.Y*n,a.Z*n) end
function vector:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
function vector:Lerp(b,t) return self+(b-self)*t end
function vector:Cross(b) return v(self.Y*b.Z-self.Z*b.Y,self.Z*b.X-self.X*b.Z,self.X*b.Y-self.Y*b.X) end
local Navigation = assert(loadfile("src/AdaptiveNavigation.luau"))()
local points = { {Position=v(0,0,0)}, {Position=v(8,0,0)}, {Position=v(9,10,0)} }
assert(Navigation.StartWaypoint(points,v(8,0,0),function(p) return p.Y == 0 end) == 2)
assert(Navigation.StartWaypoint(points,v(9,10,0),function(p) return p.Y == 0 end) ~= 3,
    "nearest point on another floor is rejected when not walkable")
assert(Navigation.StartWaypoint(points,v(100,0,0),function() return true end) == nil,
    "stale path start far behind the player is discarded")
points[1].Action = "Enum.PathWaypointAction.Jump"
assert(Navigation.StartWaypoint(points,v(8,0,0),function() return true end) == 1,
    "joining a path cannot bypass a jump")
local nav = Navigation.new({})
nav:Progress(v(0,0,0),v(20,0,0),nil,0)
nav:Cancel("room graph complete")
assert(nav.watch ~= nil, "room observation must not reset a local objective's progress timer")

local Geometry = assert(loadfile("src/ThreatGeometry.luau"))()
local function block(x, width)
    local frame = {Position=v(x,0,0),RightVector=v(1,0,0),LookVector=v(0,0,-1)}
    function frame:PointToObjectSpace(p) return p-self.Position end
    function frame:VectorToObjectSpace(p) return p end
    return {frame=frame,size=v(width,10,30),shape="Block"}
end
local hazard = block(0,24)
assert(Geometry.escapeStepSafe({hazard},v(0,0,0),v(15,0,0),0), "allow escaping an existing overlap")
assert(not Geometry.escapeStepSafe({hazard},v(8,0,0),v(0,0,0),0), "reject deeper exposure")
assert(not Geometry.escapeStepSafe({hazard},v(20,0,0),v(0,0,0),0), "no bypass when starting safe")
assert(not Geometry.escapeStepSafe({hazard,block(11,2)},v(0,0,0),v(15,0,0),0),
    "reducing overlap cannot authorize entering a new beam")

Vector3 = { new=v, yAxis=v(0,1,0) }
Color3 = { fromRGB=function() return {} end }
CFrame = { fromAxisAngle=function(_, angle)
    return { VectorToWorldSpace=function(_, point)
        return v(point.X*math.cos(angle)+point.Z*math.sin(angle),point.Y,
            -point.X*math.sin(angle)+point.Z*math.cos(angle))
    end }
end }
local Northern = assert(loadfile("src/NorthernLandsController.luau"))()
local solver = setmetatable({ _geometry=Geometry, _intentUntil=0, _sectorSide=1,
    State={CurrentMechanic="BEAM_AVOIDANCE"} }, Northern)
local context = {now=1,rootPart={Position=v(0,0,0)},targetRoot={Position=v(40,0,0)},
    humanoid={WalkSpeed=16},attackRange=26,ground=function(p) return p end,walkable=function() return true end}
local distantBeam=block(100,2)
context.zones={distantBeam}
assert(solver:_beamSector(context,{distantBeam}) == nil,
    "passive beam outside the approach lane cannot take movement ownership")
assert(solver.State.CurrentMechanic == "NORMAL", "release stale beam hold immediately")
local crossingBeam=block(10,2)
context.zones={crossingBeam}
local intent=solver:_beamSector(context,{crossingBeam})
assert(intent and not intent.hold and (intent.goal-context.rootPart.Position).Magnitude > 2,
    "out-of-range boss with a blocking beam selects safe movement instead of parking")
assert(Geometry.segmentSafe(context.zones,context.rootPart.Position,intent.goal,5),
    "beam approach cannot exchange safety for DPS")
solver._intent={mechanic="PROJECTILE_ESCAPE",goal=v(25,0,0)}
solver._intentUntil=10
assert(solver:_reuse(context,"PROJECTILE_ESCAPE",nil,0.2) == nil,
    "a newly unsafe crossing invalidates a leased mechanic route even when its endpoint is safe")
local slam = block(0,67)
slam.shape, slam.size, slam.id, slam.live = "Sphere", v(67,67,67), {}, true
assert(Geometry.clearance(slam,v(34,0,0),0) == Geometry.clearance(slam,v(0,0,34),0),
    "spherical slam clearance must not depend on the warning cylinder's axis")
assert(Geometry.radialRadiusAtHeight(slam,v(0,0,0),5) == 38.5)
assert(Geometry.radialRadiusAtHeight(slam,v(0,50,0),5) == nil)
context.zones, context.now = {slam}, 2
solver._intent, solver._slam = nil, nil
solver._escapeSide = 1
local escape = solver:_slamIntent(context,slam)
assert(solver._slam.committed, "visible overlapping slam starts escape without waiting in bait phase")
assert(escape and Geometry.clearance(slam,escape.goal,5) > 0,
    "escape must clear the 67-stud hitbox rather than stop at the old 21-stud sample radius")
assert(escape.allowAttack, "slam movement must permit independently validated casting")
local shot = block(0,8)
context.zones = {shot}
solver._intent = nil
assert(solver:_projectileIntent(context,shot).allowAttack,
    "projectile evasion does not disable eligible abilities")
print("Movement policy checks passed")
