-- Small, JSON-safe advisory memory. No Instance references or unbounded logs.
local Memory = {}
Memory.__index = Memory
local LIMITS = { boss = 32, route = 96 }
local HALF_LIFE = 7 * 24 * 60 * 60
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < 1e12 end
local function validKey(s) return type(s) == "string" and #s > 0 and #s <= 180 end
local function decay(row, now)
    return 0.5 ^ (math.max(0, now - row.at) / HALF_LIFE)
end
local function trim(rows, limit)
    local count, oldest, at = 0, nil, math.huge
    for key, row in pairs(rows) do
        count = count + 1
        if row.at < at then oldest, at = key, row.at end
    end
    if count >= limit and oldest then rows[oldest] = nil end
end
function Memory.new(clock)
    return setmetatable({ clock = clock or os.time, groups = { boss = {}, route = {} }, dirty = false }, Memory)
end
function Memory:Observe(group, key, features, success, weight)
    if not LIMITS[group] or not validKey(key) or type(success) ~= "boolean" then return end
    local rows, now = self.groups[group], self.clock()
    weight = finite(weight) and math.max(0.1, math.min(1, weight)) or 1
    local row = rows[key]
    if not row then
        trim(rows, LIMITS[group])
        row = { at = now, wins = 0, losses = 0, bins = {} }
        rows[key] = row
    end
    -- Recency within a session as well as wall-clock decay; new success can
    -- reverse an old preference without waiting for the time half-life.
    local factor = decay(row, now) * 0.96 ^ weight
    row.wins, row.losses = row.wins * factor, row.losses * factor
    for _, bin in pairs(row.bins) do
        bin.wins, bin.losses = bin.wins * factor, bin.losses * factor
    end
    local field = success and "wins" or "losses"
    row[field], row.at = row[field] + weight, now
    local seen, count = {}, 0
    for _, feature in ipairs(features or {}) do
        if validKey(feature) and not seen[feature] and count < 10 then
            count, seen[feature] = count + 1, true
            local bin = row.bins[feature]
            if not bin then trim(row.bins, 48); bin = { wins = 0, losses = 0, at = now }; row.bins[feature] = bin end
            bin[field], bin.at = bin[field] + weight, now
        end
    end
    self.dirty = true
end
function Memory:Cost(group, key, features)
    local row = self.groups[group] and self.groups[group][key]
    if not row then return 0, 0 end
    local factor, total, confidence, count = decay(row, self.clock()), 0, 0, 0
    local function add(wins, losses)
        wins, losses = wins * factor, losses * factor
        local n = wins + losses
        local c = n / (n + 6)
        total, confidence, count = total + (losses - wins) / (n + 4) * c, confidence + c, count + 1
    end
    if group == "route" then add(row.wins, row.losses) end
    for _, feature in ipairs(features or {}) do
        local bin = row.bins[feature]
        if bin then add(bin.wins, bin.losses) end
    end
    if count == 0 then return 0, 0 end
    return math.max(-24, math.min(24, total / count * 24)), confidence / count
end
function Memory:Export()
    -- Detached copy so serialization or a caller cannot mutate live evidence.
    local result = { Version = 1, Groups = { boss = {}, route = {} } }
    for group, rows in pairs(self.groups) do
        for key, row in pairs(rows) do
            local copy = { at = row.at, wins = row.wins, losses = row.losses, bins = {} }
            for feature, bin in pairs(row.bins) do
                copy.bins[feature] = { at = bin.at, wins = bin.wins, losses = bin.losses }
            end
            result.Groups[group][key] = copy
        end
    end
    return result
end
function Memory:Load(data)
    if type(data) ~= "table" or data.Version ~= 1 or type(data.Groups) ~= "table" then return end
    local now, groups = self.clock(), { boss = {}, route = {} }
    local function clean(row)
        if type(row) ~= "table" or not finite(row.at) or not finite(row.wins) or not finite(row.losses)
            or row.at > now + 60 or row.at < 0 or row.wins < 0 or row.losses < 0 then return nil end
        return { at = row.at, wins = math.min(32, row.wins), losses = math.min(32, row.losses) }
    end
    for group, limit in pairs(LIMITS) do
        local count = 0
        if type(data.Groups[group]) == "table" then
            for key, source in pairs(data.Groups[group]) do
                if count >= limit then break end
                local row = clean(source)
                if validKey(key) and row then
                    count, row.bins = count + 1, {}
                    local bins = 0
                    if type(source.bins) == "table" then
                        for feature, sample in pairs(source.bins) do
                            if bins >= 48 then break end
                            local bin = clean(sample)
                            if validKey(feature) and bin then row.bins[feature], bins = bin, bins + 1 end
                        end
                    end
                    groups[group][key] = row
                end
            end
        end
    end
    self.groups, self.dirty = groups, false
end
return Memory
