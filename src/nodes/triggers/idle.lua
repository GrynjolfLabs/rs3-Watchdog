local Idle = {}

local TICKS_PER_SECOND = 50 -- Logic rate, see trigger.logic

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Idle.Register(registry, runtime)
    -- Input is one fact about the client, so every Idle node shares this clock.
    local tick, lastActiveTick, lastActivity = 0, 0, nil

    registry:RegisterNodeType("trigger.idle", {
        category = "trigger",
        displayName = "Idle",
        description = "No key press, click or mouse movement for a while",
        pins = {
            { name = "seconds", kind = "data", direction = "in", dataType = "number", default = 60 },
            { name = "Idle", kind = "exec", direction = "out" },
            { name = "Active", kind = "exec", direction = "out" },
        },
        run = function(ctx)
            ctx:Fire(ctx.payload.edge == "Enter" and "Idle" or "Active")
        end,
    })

    runtime:BindTrigger("trigger.idle", { {
        kind = "poll",
        event = "Logic",
        -- Sample is seconds idle. Logged out => nil, which freezes the edge; the clock
        -- restarts on login. Input seen this tick happened since the previous one.
        transform = function()
            tick = tick + 1
            local activity = runtime.keyboardActivityTick + runtime.mouseActivityTick
                + runtime.miniMenuActivityTick
            local loggedIn = Player.IsAvailable()
            if activity ~= lastActivity or not loggedIn then
                lastActivity, lastActiveTick = activity, tick - 1
            end
            if loggedIn then
                return (tick - lastActiveTick) / TICKS_PER_SECOND
            end
        end,
        filter = function(idleSeconds, node)
            return idleSeconds >= math.max(tonumber(node.GetControl("seconds")) or 60, 1)
        end,
    } })
end

return Idle
