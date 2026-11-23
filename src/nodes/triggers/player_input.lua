local PlayerInput = {}

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function PlayerInput.Register(registry, runtime)
    registry:RegisterNodeType("trigger.player_input", {
        category = "trigger",
        displayName = "Player Input",
        description = "Fires on a checked local input",
        pins = {
            { name = "mouseMove", label = "Mouse move", kind = "data", direction = "in", dataType = "bool", default = true },
            { name = "keyboard", label = "Keyboard", kind = "data", direction = "in", dataType = "bool", default = true },
            { name = "mouseClick", label = "Mouse click", kind = "data", direction = "in", dataType = "bool", default = true },
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function(ctx)
            ctx:Fire("out")
        end,
    })

    -- The filter runs before the node, so this is the read ctx:In would make.
    ---@param name string
    ---@return fun(payload: any, node: Watchdog.NodeHandle, graph: LibNodeGraph.Graph): boolean
    local function checkOn(name)
        return function(_, node, graph)
            return graph:_pull(graph.nodes[node.id], name, 0) == true
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
