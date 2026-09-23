-- Offline policy checks with real block hazard geometry, no Roblox execution.
math.clamp = math.clamp or function(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local vector = {}
vector.__index = function(v, key)
    if key == "Magnitude" then return math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z) end
    return vector[key]
end
local function v(x,y,z) return setmetatable({ X=x, Y=y, Z=z }, vector) end
vector.__add = function(a,b) return v(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
vector.__sub = function(a,b) return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
vector.__mul = function(a,n) return v(a.X*n,a.Y*n,a.Z*n) end
function vector:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
function vector:Lerp(b,t) return self+(b-self)*t end
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
print("Movement policy checks passed")
