-- Alert Presets on the Pack named Watchdog Starter Pack.

local StarterAlerts = {}

-- Pack layout is the same { id, x, y } array an Alert save uses.
---@param layout table<integer, { x: number, y: number }>
---@return { id: integer, x: number, y: number }[]
local function layoutArray(layout)
    local arr = {}
    for id, pos in pairs(layout) do
        arr[#arr + 1] = { id = id, x = pos.x, y = pos.y }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

---@param graph LibNodeGraph.Graph
---@param label string
---@param fromNode integer
---@param fromPin string
---@param toNode integer
---@param toPin string
local function connect(graph, label, fromNode, fromPin, toNode, toPin)
    local id, reason = graph:Connect(fromNode, fromPin, toNode, toPin)
    if id == nil then
        error(string.format("%s graph: %s %s -> %s", label, tostring(reason), fromPin, toPin))
    end
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function friendLogin(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local message = graph:AddNode("trigger.game_message", {
        type = "login",
        contains = { needle = "", mode = "substring" },
    }, { name = "Login/logout" })
    local toast = graph:AddNode("action.toast", {
        color = { r = 0, g = 255, b = 240, a = 255 },
        icon = id.Sprite.ICON_STAR_FILL,
        sticky = false,
        hold = 5,
    }, { name = "Toast" })
    local sound = graph:AddNode("action.sound", {
        soundId = id.Sound.DEVCOM_MINIGAME_ALERT,
    }, { name = "Ding a ling" })
    connect(graph, "Friend login", message, "out", sound, "in")
    connect(graph, "Friend login", message, "out", toast, "show")
    connect(graph, "Friend login", message, "message", toast, "text")
    return {
        authorId = "friend-login",
        name = "Friend login",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [message] = { x = 135, y = 50 },
            [toast] = { x = 515, y = 26 },
            [sound] = { x = 514, y = 264 },
        }),
    }
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function idleXp(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local logic = graph:AddNode("trigger.logic", { interval = 50 }, { name = "1/sec" })
    local counter = graph:AddNode("std.counter", { step = 1, start = 0 }, { name = "Second counter" })
    local compare = graph:AddNode("std.compare", { operation = ">=", a = 0, b = 10 }, { name = "X seconds" })
    local branch = graph:AddNode("std.branch", { condition = false }, { name = "If true" })
    local xp = graph:AddNode("trigger.xp_drop", { skillFilter = "any" }, { name = "Any xp drop" })
    local once = graph:AddNode("std.doonce", { startClosed = true }, { name = "Only ding once" })
    local sound = graph:AddNode("action.sound", { soundId = id.Sound.TOWN_CRIER_BELL_RING_1 }, { name = "Ding" })
    connect(graph, "Idle XP", logic, "out", counter, "in")
    connect(graph, "Idle XP", counter, "count", compare, "a")
    connect(graph, "Idle XP", counter, "out", branch, "in")
    connect(graph, "Idle XP", compare, "result", branch, "condition")
    connect(graph, "Idle XP", branch, "true", once, "in")
    connect(graph, "Idle XP", xp, "out", once, "reset")
    connect(graph, "Idle XP", xp, "out", counter, "reset")
    connect(graph, "Idle XP", once, "out", sound, "in")
    return {
        authorId = "idle-xp",
        name = "Idle XP",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [logic] = { x = 6, y = 10 },
            [counter] = { x = 282, y = 9 },
            [compare] = { x = 580, y = 13 },
            [branch] = { x = 61, y = 279 },
            [xp] = { x = 6, y = 112 },
            [once] = { x = 343, y = 279 },
            [sound] = { x = 615, y = 279 },
        }),
        variables = {
            { nodeId = compare, pinName = "b" },
            { nodeId = xp,      pinName = "skillFilter" },
        },
    }
end

local PERCENT_DEFAULT = 25
local FLASH_RED = { r = 255, g = 0, b = 0, a = 127 }
local FLASH_PRAYER = { r = 89, g = 0, b = 255, a = 127 }

---@param registry LibNodeGraph.Registry
---@param resource string
---@param authorId string
---@param name string
---@param soundId number
---@param flashColor { r: integer, g: integer, b: integer, a: integer }
---@param triggerName string
---@return Watchdog.PackAlertPreset
local function lowResource(registry, resource, authorId, name, soundId, flashColor, triggerName)
    local graph = LibNodeGraph.NewGraph(registry)
    local trigger = graph:AddNode("trigger.resource_changed", { resource = resource }, { name = triggerName })
    local quarter = graph:AddNode("std.math", { operation = "*", a = 0, b = PERCENT_DEFAULT }, { name = "Percent" })
    local percent = graph:AddNode("std.math", { operation = "/", a = 0, b = 100 }, { name = "Percentify" })
    local compare = graph:AddNode("std.compare", { operation = "<=", a = 0, b = 0 }, { name = "Less than or equal" })
    local branch = graph:AddNode("std.branch", { condition = false }, { name = "Condition branch" })
    local once = graph:AddNode("std.doonce", { startClosed = false }, { name = "Only alert once" })
    local sound = graph:AddNode("action.sound", { soundId = soundId })
    local flash = graph:AddNode("action.screen_flash", {
        color = flashColor,
        inShape = "instant",
        outShape = "instant",
        dismissOn = "both",
    })
    connect(graph, name, trigger, "current", compare, "a")
    connect(graph, name, trigger, "max", quarter, "a")
    connect(graph, name, quarter, "result", percent, "a")
    connect(graph, name, percent, "result", compare, "b")
    connect(graph, name, trigger, "out", branch, "in")
    connect(graph, name, compare, "result", branch, "condition")
    connect(graph, name, branch, "true", once, "in")
    connect(graph, name, branch, "false", once, "reset")
    connect(graph, name, once, "out", sound, "in")
    connect(graph, name, once, "out", flash, "show")
    return {
        authorId = authorId,
        name = name,
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [trigger] = { x = 9, y = 9 },
            [quarter] = { x = 280, y = 17 },
            [compare] = { x = 565, y = 2 },
            [branch] = { x = 37, y = 379 },
            [once] = { x = 326, y = 328 },
            [sound] = { x = 605, y = 143 },
            [flash] = { x = 605, y = 328 },
            [percent] = { x = 279, y = 156 },
        }),
        variables = { { nodeId = quarter, pinName = "b" } },
    }
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function tickCounter(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local tick = graph:AddNode("trigger.server_logic", { interval = 1 }, { name = "Each tick" })
    local counter = graph:AddNode("std.counter", { step = 1, start = 0 }, { name = "Tick Counter" })
    local box = graph:AddNode("action.infobox", {
        icon = id.Sprite.RS3_ICON_CHECK_MARK_24PX_0,
        title = "",
        dismissWhenEmpty = false,
        color = { r = 255, g = 255, b = 255, a = 255 },
    }, { name = "Tick infobox" })
    local compare = graph:AddNode("std.greaterorequal", { a = 0, b = 4 }, { name = "Loop X ticks" })
    local branch = graph:AddNode("std.branch", { condition = false }, { name = "Reset loop" })
    connect(graph, "Tick Counter", tick, "out", counter, "in")
    connect(graph, "Tick Counter", counter, "count", box, "value")
    connect(graph, "Tick Counter", counter, "count", compare, "a")
    connect(graph, "Tick Counter", counter, "out", branch, "in")
    connect(graph, "Tick Counter", counter, "out", box, "update")
    connect(graph, "Tick Counter", compare, "result", branch, "condition")
    connect(graph, "Tick Counter", branch, "true", counter, "reset")
    return {
        authorId = "tick-counter",
        name = "Tick Counter",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [tick] = { x = 9, y = 11 },
            [counter] = { x = 304, y = 11 },
            [box] = { x = 611, y = 11 },
            [compare] = { x = 50, y = 221 },
            [branch] = { x = 348, y = 225 },
        }),
        variables = {
            { nodeId = box,     pinName = "icon" },
            { nodeId = compare, pinName = "b" },
        },
    }
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function lowOnFood(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local inventory = graph:AddNode("trigger.inventory", {
        container = config.Inv.INV,
    }, { name = "Inventory" })
    local count = graph:AddNode("inventory.item_count_changed", {
        noteFilter = "unnoted",
        nameMatch = { needle = "Shark", mode = "substring" },
    }, { name = "Item Count Changed" })
    local removed = graph:AddNode("std.compare", {
        operation = "<", a = 0, b = 0,
    }, { name = "only check if item is removed" })
    local low = graph:AddNode("std.compare", {
        operation = "<=", a = 0, b = 5,
    }, { name = "count <= x" })
    local both = graph:AddNode("std.and", { a = false, b = false }, { name = "And1" })
    local branch = graph:AddNode("std.branch", { condition = false }, { name = "Alert if true" })
    local sound = graph:AddNode("action.sound", { soundId = id.Sound.ARTISAN_METAL_DROP_05 })
    connect(graph, "Low on food", inventory, "prevSnapshot", count, "prevSnapshot")
    connect(graph, "Low on food", inventory, "snapshot", count, "snapshot")
    connect(graph, "Low on food", inventory, "out", branch, "in")
    connect(graph, "Low on food", count, "count", removed, "a")
    connect(graph, "Low on food", count, "prevCount", removed, "b")
    connect(graph, "Low on food", count, "count", low, "a")
    connect(graph, "Low on food", removed, "result", both, "a")
    connect(graph, "Low on food", low, "result", both, "b")
    connect(graph, "Low on food", both, "result", branch, "condition")
    connect(graph, "Low on food", branch, "true", sound, "in")
    return {
        authorId = "low-on-food",
        name = "Low on food",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [inventory] = { x = 9, y = 11 },
            [count] = { x = 295, y = 11 },
            [removed] = { x = 298, y = 188 },
            [low] = { x = 298, y = 338 },
            [branch] = { x = 606, y = 192 },
            [sound] = { x = 608, y = 19 },
            [both] = { x = 602, y = 330 },
        }),
        variables = {
            { nodeId = low,   pinName = "b" },
            { nodeId = count, pinName = "nameMatch" },
        },
    }
end

-- Rings once the player has been idle for X seconds.
---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function lobbyTimer(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local idle = graph:AddNode("trigger.idle", { seconds = 570 }, { name = "Idle for X seconds" })
    local sound = graph:AddNode("action.sound", { soundId = id.Sound.TOWN_CRIER_BELL_RING_1 }, { name = "Ding" })
    connect(graph, "Lobby Timer", idle, "Idle", sound, "in")
    return {
        authorId = "lobby-timer",
        name = "Lobby Timer",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [idle] = { x = 9, y = 11 },
            [sound] = { x = 300, y = 11 },
        }),
        variables = { { nodeId = idle, pinName = "seconds" } },
    }
end

---@param api { RegisterDataPack: fun(self, name: string, contributions: table|nil) }
---@param registry LibNodeGraph.Registry
function StarterAlerts.register(api, registry)
    local horn = id.Sound.FISHCOMP_KLAXON
    local alertBells = id.Sound.CHOSEN_HAM_BASE_ALARM
    local alertBellsLong = id.Sound.MAH3_HEIST_ALARM
    api:RegisterDataPack("Watchdog Starter Pack", {
        alertPresets = {
            friendLogin(registry),
            idleXp(registry),
            tickCounter(registry),
            lowOnFood(registry),
            lobbyTimer(registry),
            lowResource(registry, "life", "low-life-points", "Low life points", alertBells, FLASH_RED, "Life"),
            lowResource(registry, "prayer", "low-prayer", "Low prayer", horn, FLASH_PRAYER, "Prayer"),
        },
    })
end

return StarterAlerts
