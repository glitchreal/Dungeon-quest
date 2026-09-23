-- Focused deterministic checks; runs with lua testing/adaptive-memory.lua.
local Memory = assert(loadfile("src/AdaptiveMemory.luau"))()
local now = 1000000
local memory = Memory.new(function() return now end)
local function observe(success, count)
    for _ = 1, count do memory:Observe("boss", "Bob/orb/red", { "side:1", "standOff:4" }, success) end
end
observe(false, 1)
local single, confidence = memory:Cost("boss", "Bob/orb/red", { "side:1" })
assert(single > 0 and single < 1 and confidence < 0.2, "one failure must have little influence")
observe(false, 12)
local repeated = memory:Cost("boss", "Bob/orb/red", { "side:1" })
assert(repeated > single)
observe(true, 30)
local reversed = memory:Cost("boss", "Bob/orb/red", { "side:1" })
assert(reversed < 0, "new successes reverse an old failure preference")
now = now + 7 * 86400 * 8
assert(math.abs(memory:Cost("boss", "Bob/orb/red", { "side:1" })) < math.abs(reversed) / 10)
local copy = Memory.new(function() return now end)
copy:Load(memory:Export())
assert(copy:Cost("boss", "Bob/orb/red", { "side:1" }) == memory:Cost("boss", "Bob/orb/red", { "side:1" }))
local exported = copy:Export()
exported.Groups.boss["Bob/orb/red"].wins = 999
assert(copy:Export().Groups.boss["Bob/orb/red"].wins < 999, "exports are detached")
copy:Load({ Version = 9 })
assert(copy:Cost("boss", "Bob/orb/red", { "side:1" }) ~= 0)
copy:Load({ Version = 1, Groups = { boss = { bad = { at = now, wins = 0/0, losses = 1 } } } })
assert(next(copy.groups.boss) == nil, "NaN cannot poison candidate costs")
for i = 1, 100 do memory:Observe("boss", "key" .. i, { "direction" }, false) end
local count = 0
for _ in pairs(memory.groups.boss) do count = count + 1 end
assert(count == 32)
for i = 1, 200 do memory:Observe("route", "edge" .. i, { "cell" .. i }, i % 2 == 0) end
count = 0
for _ in pairs(memory.groups.route) do count = count + 1 end
assert(count == 96)
for i = 1, 100 do memory:Observe("boss", "bins", { "feature" .. i }, true) end
count = 0
for _ in pairs(memory.groups.boss.bins.bins) do count = count + 1 end
assert(count == 48)

-- Minimal vectors let the graph/progress policy run without a Roblox client.
local vector = {}
vector.__index = function(v, key)
    if key == "Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
    return vector[key]
end
vector.__add = function(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
Vector3 = { new = function(x,y,z) return setmetatable({X=x,Y=y,Z=z},vector) end }
local Navigation = assert(loadfile("src/AdaptiveNavigation.luau"))()
local nav = Navigation.new(Memory.new(function() return now end))
local function anchor(x, room, order)
    return { part = { Parent = {}, Position = Vector3.new(x,0,0) }, name=room, order=order }
end
local anchors = { anchor(20,"room2",2), anchor(32,"room2",2), anchor(60,"room3",3) }
local root = { Position = Vector3.new(0,2.5,0) }
local goal = nav:Goal(root,nil,anchors,{order=1,name="room1"},"Northern Lands",0,function() return 0 end)
assert(goal.X == 20)
local firstEdge = nav.edge.key
nav:Outcome(false,"blocked",1)
goal = nav:Goal(root,nil,anchors,{order=1,name="room1"},"Northern Lands",1.1,function() return 0 end)
assert(goal.X == 32, "failed edge selects available alternate entrance")
assert(nav.memory:Cost("route",firstEdge,{}) > 0)
local successEdge = nav.edge.key
nav:Outcome(true,"arrived",2)
assert(nav.memory:Cost("route", successEdge, {}) < 0)
nav:Goal(root,nil,anchors,{order=1,name="room1"},"Northern Lands",3,function() return 0 end)
local cancelledEdge, epoch = nav.edge.key, nav.epoch
local beforeCancel = nav.memory:Cost("route", cancelledEdge, {})
nav:Cancel("objective replaced")
assert(nav.edge == nil and nav.choice == nil and nav.epoch > epoch)
assert(nav.memory:Cost("route", cancelledEdge, {}) == beforeCancel, "abandoning a route invents no outcome")
nav:Reset()
nav:Rebuild(anchors,"Northern Lands")
nav.edge = { key="cycle",goal=Vector3.new(100,0,0) }
local stalled = false
for i=0,18 do
    -- Moving sideways and replacing waypoints does not improve the objective.
    stalled = nav:Progress(Vector3.new(0,0,i%2),Vector3.new(100,0,0),120+i%2,i*0.5) or stalled
end
assert(stalled, "circling with no best-distance progress is stuck")
assert(nav.memory:Cost("route","cycle",{}) > 0)
nav:Reset()
nav:Progress(root.Position,Vector3.new(100,0,0),120,0)
assert(not nav:Progress(root.Position,Vector3.new(100,0,0),120,20), "mechanic interruption does not fail route")
Color3 = { fromRGB = function(r,g,b) return {R=r/255,G=g/255,B=b/255} end }
local Northern = assert(loadfile("src/NorthernLandsController.luau"))()
local solver = setmetatable({State={},_policy="test",_memory=Memory.new(function() return now end)},Northern)
solver._policyKey = function() return "test" end
solver._features = function(_,_,candidate) return {candidate.name} end
solver._candidateScore = function(_,_,candidate) return candidate.score,candidate,candidate.risk,candidate.safe end
for _=1,20 do solver._memory:Observe("boss","test",{"favored"},true) end
local favored = {name="favored",score=2,risk=0.00001,safe=true}
local safer = {name="safe",score=0,risk=0,safe=true}
assert(solver:_pick({}, {favored,safer}, {}) == safer, "history cannot override even small current risk differences")
favored.risk = 0
assert(solver:_pick({}, {favored,safer}, {}) == favored, "history can rank equally safe options")
favored.safe = false
assert(solver:_pick({}, {favored,safer}, {}) == safer, "historical success cannot authorize an unsafe crossing")
print("Adaptive memory and navigation checks passed")
