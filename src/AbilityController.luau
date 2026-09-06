-- Matches the game's UIS / MobileLayout slot checks and localEvent activation.
local Abilities = {}

function Abilities.new(player, onConfirmed)
    local requests = setmetatable({}, { __mode = "k" })
    local slots, snapshots = {}, {}
    local lastRefresh, lastAttempt, preferred = -math.huge, -math.huge, "q"
    local userInput = game:GetService("UserInputService")
    local remotes = game:GetService("ReplicatedStorage"):WaitForChild("remotes")

    local function refresh(now)
        if now - lastRefresh < 0.05 then return end
        lastRefresh = now
        slots, snapshots = {}, {}
        local containers = { player:FindFirstChild("Backpack"), player.Character }
        for _, container in pairs(containers) do
            for _, tool in ipairs(container:GetChildren()) do
                local slot = tool:FindFirstChild("abilitySlot")
                local cooldown = tool:FindFirstChild("cooldown")
                if slot and cooldown and (slot.Value == "q" or slot.Value == "e") then
                    local remaining = math.max(0, tonumber(cooldown.Value) or 0)
                    local pending = requests[tool]
                    if pending and not pending.confirmed and remaining > 0 and now - pending.at < 1.5 then
                        pending.confirmed = true
                        onConfirmed(slot.Value, tool.Name)
                    end
                    slots[slot.Value] = tool
                    snapshots[slot.Value] = { name = tool.Name, cooldown = remaining }
                end
            end
        end
    end

    return {
        Snapshot = function(now)
            refresh(now)
            return snapshots
        end,
        TryCast = function(now, interval, prepare)
            refresh(now)
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local busy = character and character:FindFirstChild("busyCasting")
            local peaceful = player:FindFirstChild("peaceful")
            if not humanoid or humanoid.Health <= 0 or (busy and busy.Value)
                or (peaceful and peaceful.Value) or userInput:GetFocusedTextBox() then return false end
            if now - lastAttempt < interval then return false end
            for _, slot in ipairs({ preferred, preferred == "q" and "e" or "q" }) do
                local tool = slots[slot]
                local snapshot = snapshots[slot]
                local pending = tool and requests[tool]
                if tool and snapshot.cooldown <= 0 and (not pending or now >= pending.retryAt)
                    and (not prepare or prepare(slot, snapshot)) then
                    local event = tool:FindFirstChild("localEvent")
                    local remote = remotes:FindFirstChild("abilityUsed")
                    if event and event:IsA("BindableEvent") and remote and remote:IsA("RemoteEvent") then
                        local length = tool:FindFirstChild("cooldownLength")
                        local retry = math.max(0.75, tonumber(length and length.Value) or 1)
                        requests[tool] = { at = now, retryAt = now + retry, confirmed = false }
                        lastAttempt, preferred = now, slot == "q" and "e" or "q"
                        event:Fire()
                        remote:FireServer(slot, tool)
                        return true
                    end
                end
            end
            return false
        end,
    }
end

return Abilities
