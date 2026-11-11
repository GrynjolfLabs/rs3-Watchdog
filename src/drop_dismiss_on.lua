-- Rewrites a serialized graph before Graph:AddNode runs. AddNode fills a missing
-- data-in control from the pin default and drops a control whose pin is gone, so
-- Dismiss On has to be read here, on the saved document.

local Theme = require("src/ui/theme")

local DropDismissOn = {}

---@param graph LibNodeGraph.SerializedGraph
---@param layout Watchdog.LayoutArray|nil
---@return integer
local function maxId(graph, layout)
    local maxId = 0
    local function consider(id)
        if type(id) == "number" and id > maxId then maxId = id end
    end
    for _, node in ipairs(graph.nodes or {}) do
        if type(node) == "table" then consider(node.id) end
    end
    for _, pos in ipairs(layout or {}) do
        if type(pos) == "table" then consider(pos.id) end
    end
    return maxId
end

---@param layout Watchdog.LayoutArray|nil
---@param id integer
---@return { id: integer, x: number, y: number }|nil
local function positionOf(layout, id)
    for _, pos in ipairs(layout or {}) do
        if type(pos) == "table" and pos.id == id then return pos end
    end
    return nil
end

-- Only these stored values add a node. Mouse click stays off: the old
-- Dismiss On control had no click.
local INPUT_FOR = {
    mouse = { mouseMove = true, keyboard = false },
    keyboard = { mouseMove = false, keyboard = true },
    both = { mouseMove = true, keyboard = true },
}

-- A missing check would load as on. False has to be stored.
---@param graph LibNodeGraph.SerializedGraph
---@param layout Watchdog.LayoutArray|nil
---@param flash LibNodeGraph.SerializedNode
---@param checks { mouseMove: boolean, keyboard: boolean }
local function addPlayerInput(graph, layout, flash, checks)
    local id = maxId(graph, layout) + 1
    graph.nodes[#graph.nodes + 1] = {
        id = id,
        type = "trigger.player_input",
        controls = {
            mouseMove = checks.mouseMove,
            keyboard = checks.keyboard,
            mouseClick = false,
        },
    }
    graph.connections = graph.connections or {}
    graph.connections[#graph.connections + 1] = {
        fromNode = id,
        fromPin = "out",
        toNode = flash.id,
        toPin = "dismiss",
    }
    local pos = positionOf(layout, flash.id)
    if pos ~= nil then
        -- Same row, one node width to the left, even when that point is taken.
        layout[#layout + 1] = { id = id, x = pos.x - Theme.NODE_WIDTH, y = pos.y }
    end
end

---@param graph LibNodeGraph.SerializedGraph|nil
---@param layout Watchdog.LayoutArray|nil
---@return Watchdog.LayoutArray|nil
function DropDismissOn.Apply(graph, layout)
    if type(graph) ~= "table" or type(graph.nodes) ~= "table" then
        return layout
    end
    local flashes = {}
    for _, node in ipairs(graph.nodes) do
        if type(node) == "table" and node.type == "action.screen_flash" then
            flashes[#flashes + 1] = node
        end
    end
    for _, flash in ipairs(flashes) do
        local controls = flash.controls
        if type(controls) ~= "table" then
            controls = {}
            flash.controls = controls
        end
        -- none, and any value that is not mouse, keyboard, or both, adds no node.
        -- The stored value is dropped either way.
        local dismissOn = controls.dismissOn
        if dismissOn ~= nil then
            local checks = INPUT_FOR[dismissOn]
            if checks ~= nil then
                addPlayerInput(graph, layout, flash, checks)
            end
            controls.dismissOn = nil
        end
        -- The pin default is off. An old save has no Sticky key and must keep
        -- looping, so the missing value is written true. Rise and Fall stay
        -- absent: their pin default of 1 is the duration those saves never stored.
        if controls.sticky == nil then
            controls.sticky = true
        end
    end
    return layout
end

-- Bucket load and Import both rewrite every alert, including one nested in a group.
---@param entries (Watchdog.Entry|Watchdog.ExportEntry)[]|nil
function DropDismissOn.ApplyEntries(entries)
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" then
            if entry.kind == "alert" and type(entry.graph) == "table" then
                entry.layout = DropDismissOn.Apply(entry.graph, entry.layout)
            end
            if entry.children ~= nil then
                DropDismissOn.ApplyEntries(entry.children)
            end
        end
    end
end

return DropDismissOn
