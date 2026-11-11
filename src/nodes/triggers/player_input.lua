-- Player Input (`trigger.player_input`). The three checks are config, not data-in pins:
-- a wire cannot target them, and a Preset cannot mark them as Variables. Values live
-- in the graph's control map so a new node and a saved node keep them.

local GraphConfig = require("src/graph_config")

local PlayerInput = {}

local CHECKS = {
    { name = "mouseMove", label = "Mouse move" },
    { name = "keyboard", label = "Keyboard" },
    { name = "mouseClick", label = "Mouse click" },
}

local function configOf(checks)
    local config = {}
    for _, check in ipairs(checks) do
        config[#config + 1] = {
            name = check.name,
            label = check.label,
            dataType = "bool",
            default = true,
        }
    end
    return config
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function PlayerInput.Register(registry, runtime)
    GraphConfig.Install(registry)
    registry:RegisterNodeType("trigger.player_input", {
        category = "trigger",
        displayName = "Player Input",
        description = "Fires on a checked local input",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
        },
        config = configOf(CHECKS),
        run = function(ctx)
            -- The exec output does not name which input happened. Downstream sees no payload.
            ctx:Fire("out")
        end,
    })

    local function checkOn(name)
        return function(_, node)
            return node.GetControl(name) == true
        end
    end

    local clickOn = checkOn("mouseClick")
    runtime:BindTrigger("trigger.player_input", {
        { event = "KeyDown", filter = checkOn("keyboard") },
        { event = "MiniMenuOpened", filter = clickOn },
        { event = "MiniMenuEntrySelected", filter = clickOn },
        { event = "MiniMenuClosed", filter = clickOn },
    })
    runtime:BindCursorMove("trigger.player_input", checkOn("mouseMove"))
end

return PlayerInput
