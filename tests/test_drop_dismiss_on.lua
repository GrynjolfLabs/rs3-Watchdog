-- Saved graphs drop Dismiss On through one function. The loaders call it;
-- they do not each re-prove the matrix.

local luaunit = require("luaunit")
local DropDismissOn = require("src/drop_dismiss_on")

TestDropDismissOn = {}

-- Flash at x=605. Editor nodes are 250 wide, so the input lands at 355
-- even though a sound node already sits there.
local function mouseGraph()
    return {
        version = 1,
        nodes = {
            { id = 3, type = "action.sound", controls = { soundId = 1 } },
            {
                id = 7,
                type = "action.screen_flash",
                controls = {
                    color = { r = 255, g = 0, b = 0, a = 127 },
                    inShape = "instant",
                    outShape = "fade",
                    dismissOn = "mouse",
                    sticky = true,
                },
            },
        },
        connections = {},
    }
end

function TestDropDismissOn:testMouseAddsAPlayerInputWithOnlyMouseMoveOn()
    local graph = mouseGraph()
    local layout = {
        { id = 3, x = 355, y = 328 },
        { id = 7, x = 605, y = 328 },
    }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(#graph.nodes, 3)
    luaunit.assertEquals(graph.nodes[3], {
        id = 8,
        type = "trigger.player_input",
        controls = { mouseMove = true, keyboard = false, mouseClick = false },
    })
    luaunit.assertEquals(graph.connections, {
        { fromNode = 8, fromPin = "out", toNode = 7, toPin = "dismiss" },
    })
    luaunit.assertNil(graph.nodes[2].controls.dismissOn)
    luaunit.assertEquals(graph.nodes[2].controls.sticky, true)
    luaunit.assertEquals(graph.nodes[2].controls.color, { r = 255, g = 0, b = 0, a = 127 })
    luaunit.assertEquals(layout, {
        { id = 3, x = 355, y = 328 },
        { id = 7, x = 605, y = 328 },
        { id = 8, x = 355, y = 328 },
    })
end

function TestDropDismissOn:testKeyboardAddsAPlayerInputWithOnlyKeyboardOn()
    local graph = mouseGraph()
    graph.nodes[2].controls.dismissOn = "keyboard"
    local layout = { { id = 7, x = 100, y = 40 } }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(graph.nodes[3].controls, {
        mouseMove = false,
        keyboard = true,
        mouseClick = false,
    })
    luaunit.assertEquals(graph.connections, {
        { fromNode = 8, fromPin = "out", toNode = 7, toPin = "dismiss" },
    })
    luaunit.assertNil(graph.nodes[2].controls.dismissOn)
    luaunit.assertEquals(layout[2], { id = 8, x = -150, y = 40 })
end

function TestDropDismissOn:testBothAddsMouseMoveAndKeyboardWithMouseClickOff()
    local graph = mouseGraph()
    graph.nodes[2].controls.dismissOn = "both"
    local layout = { { id = 7, x = 605, y = 328 } }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(graph.nodes[3].controls, {
        mouseMove = true,
        keyboard = true,
        mouseClick = false,
    })
    luaunit.assertNil(graph.nodes[2].controls.dismissOn)
    luaunit.assertEquals(#graph.nodes, 3)
end

function TestDropDismissOn:testNoneDropsTheValueAndAddsNoPlayerInput()
    local graph = mouseGraph()
    graph.nodes[2].controls.dismissOn = "none"
    local layout = { { id = 7, x = 605, y = 328 } }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(#graph.nodes, 2)
    luaunit.assertEquals(graph.connections, {})
    luaunit.assertEquals(#layout, 1)
    luaunit.assertNil(graph.nodes[2].controls.dismissOn)
    luaunit.assertEquals(graph.nodes[2].controls.sticky, true)
end

function TestDropDismissOn:testUnrecognizedDismissOnDropsTheValueAndAddsNoPlayerInput()
    local graph = mouseGraph()
    graph.nodes[2].controls.dismissOn = "hover"
    local layout = { { id = 7, x = 605, y = 328 } }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(#graph.nodes, 2)
    luaunit.assertEquals(graph.connections, {})
    luaunit.assertEquals(#layout, 1)
    luaunit.assertNil(graph.nodes[2].controls.dismissOn)
end

function TestDropDismissOn:testGraphWithNoDismissOnGainsNoPlayerInput()
    local graph = mouseGraph()
    graph.nodes[2].controls.dismissOn = nil
    graph.nodes[2].controls.sticky = false
    local layout = { { id = 7, x = 605, y = 328 } }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(#graph.nodes, 2)
    luaunit.assertEquals(graph.connections, {})
    luaunit.assertEquals(#layout, 1)
    luaunit.assertEquals(graph.nodes[2].controls.sticky, false)
end

function TestDropDismissOn:testTwoFlashesEachGetTheirOwnPlayerInput()
    local graph = {
        version = 1,
        nodes = {
            { id = 1, type = "action.screen_flash", controls = { dismissOn = "mouse", sticky = true } },
            { id = 2, type = "action.screen_flash", controls = { dismissOn = "keyboard", sticky = false } },
        },
        connections = {},
    }
    local layout = {
        { id = 1, x = 500, y = 10 },
        { id = 2, x = 500, y = 400 },
    }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(graph.nodes[3].controls, { mouseMove = true, keyboard = false, mouseClick = false })
    luaunit.assertEquals(graph.nodes[4].controls, { mouseMove = false, keyboard = true, mouseClick = false })
    luaunit.assertEquals(graph.connections, {
        { fromNode = 3, fromPin = "out", toNode = 1, toPin = "dismiss" },
        { fromNode = 4, fromPin = "out", toNode = 2, toPin = "dismiss" },
    })
    luaunit.assertEquals(layout[3], { id = 3, x = 250, y = 10 })
    luaunit.assertEquals(layout[4], { id = 4, x = 250, y = 400 })
    luaunit.assertNil(graph.nodes[1].controls.dismissOn)
    luaunit.assertNil(graph.nodes[2].controls.dismissOn)
    luaunit.assertEquals(graph.nodes[2].controls.sticky, false)
end

function TestDropDismissOn:testExistingDismissWireStaysBesideTheNewOne()
    local graph = mouseGraph()
    graph.connections = {
        { fromNode = 3, fromPin = "out", toNode = 7, toPin = "dismiss" },
    }
    local layout = { { id = 7, x = 605, y = 328 } }

    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(graph.connections, {
        { fromNode = 3, fromPin = "out", toNode = 7, toPin = "dismiss" },
        { fromNode = 8, fromPin = "out", toNode = 7, toPin = "dismiss" },
    })
end

function TestDropDismissOn:testSecondPassAddsNoPlayerInput()
    local graph = mouseGraph()
    graph.nodes[2].controls.dismissOn = "both"
    local layout = { { id = 7, x = 605, y = 328 } }

    DropDismissOn.Apply(graph, layout)
    DropDismissOn.Apply(graph, layout)

    luaunit.assertEquals(#graph.nodes, 3)
    luaunit.assertEquals(#graph.connections, 1)
    luaunit.assertEquals(#layout, 2)
    luaunit.assertEquals(graph.nodes[2].controls.sticky, true)
end

-- An old save has Dismiss On and no Sticky, Rise, or Fall. Sticky must be
-- written true. Rise and Fall stay absent so the pin default of 1 applies.
function TestDropDismissOn:testMissingStickyLoadsStickyAndLeavesRiseAndFallMissing()
    local graph = {
        version = 1,
        nodes = {
            {
                id = 1,
                type = "action.screen_flash",
                controls = {
                    color = { r = 9, g = 8, b = 7, a = 6 },
                    inShape = "instant",
                    outShape = "instant",
                    dismissOn = "both",
                },
            },
        },
        connections = {},
    }
    local layout = { { id = 1, x = 400, y = 20 } }

    DropDismissOn.Apply(graph, layout)

    local controls = graph.nodes[1].controls
    luaunit.assertEquals(controls.sticky, true)
    luaunit.assertNil(controls.rise)
    luaunit.assertNil(controls.fall)
    luaunit.assertNil(controls.cycles)
    luaunit.assertNil(controls.dismissOn)
    luaunit.assertEquals(controls.color, { r = 9, g = 8, b = 7, a = 6 })
    luaunit.assertEquals(controls.inShape, "instant")
    luaunit.assertEquals(graph.nodes[2].controls, {
        mouseMove = true,
        keyboard = true,
        mouseClick = false,
    })
end

-- Loaders are not given the matrix. One saved Mouse flash proves each path
-- called Apply on the raw document: Sticky is written, Rise stays missing.
local Json = require("json")
local Store = require("src/store")
local Presets = require("src/presets")
local Export = require("src/export")
local PresetCopy = require("src/preset_copy")

local function fakeDb()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value)
        self.data[key] = value
        return true
    end
    return db
end

local function mouseSavedGraph()
    return {
        version = 1,
        nodes = {
            {
                id = 1,
                type = "action.screen_flash",
                controls = { dismissOn = "mouse", color = { r = 1, g = 2, b = 3, a = 4 } },
            },
        },
        connections = {},
    }
end

local function assertRawMouseRewrite(graph, layout)
    luaunit.assertEquals(graph.nodes[2], {
        id = 2,
        type = "trigger.player_input",
        controls = { mouseMove = true, keyboard = false, mouseClick = false },
    })
    luaunit.assertEquals(graph.connections, {
        { fromNode = 2, fromPin = "out", toNode = 1, toPin = "dismiss" },
    })
    luaunit.assertNil(graph.nodes[1].controls.dismissOn)
    luaunit.assertEquals(graph.nodes[1].controls.sticky, true)
    luaunit.assertNil(graph.nodes[1].controls.rise)
    luaunit.assertNil(graph.nodes[1].controls.fall)
    luaunit.assertEquals(layout, {
        { id = 1, x = 605, y = 328 },
        { id = 2, x = 355, y = 328 },
    })
end

TestDropDismissOnLoad = {}

function TestDropDismissOnLoad:setUp()
    self.savedGraph = LibNodeGraph
    self.savedDb = PersistentDB
    LibNodeGraph = {
        NewGraph = require("graph").new,
        Serialize = require("serialize").Serialize,
        Deserialize = require("serialize").Deserialize,
        Json = Json,
        UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
    }
    PersistentDB = fakeDb()
end

function TestDropDismissOnLoad:tearDown()
    LibNodeGraph = self.savedGraph
    PersistentDB = self.savedDb
end

function TestDropDismissOnLoad:testLoadKeyRewritesDismissOnBeforePinDefaults()
    local doc = {
        version = 2,
        entries = {
            {
                id = 1,
                kind = "group",
                name = "Group",
                enabled = true,
                children = {
                    {
                        id = 2,
                        kind = "alert",
                        name = "Flash",
                        enabled = true,
                        graph = mouseSavedGraph(),
                        layout = { { id = 1, x = 605, y = 328 } },
                    },
                },
            },
        },
    }
    PersistentDB:SetString("player_key", LibNodeGraph.Json.Default.encode(doc))

    local loaded = Store.LoadKey("player_key")
    local alert = loaded.entries[1].children[1]
    assertRawMouseRewrite(alert.graph, alert.layout)
end

function TestDropDismissOnLoad:testLoadRewritesTheGlobalBucket()
    local doc = {
        version = 2,
        entries = {
            {
                id = 1,
                kind = "alert",
                name = "Flash",
                enabled = true,
                graph = mouseSavedGraph(),
                layout = { { id = 1, x = 605, y = 328 } },
            },
        },
    }
    PersistentDB:SetString("global", LibNodeGraph.Json.Default.encode(doc))

    local loaded = Store.Load()
    assertRawMouseRewrite(loaded.entries[1].graph, loaded.entries[1].layout)
end

function TestDropDismissOnLoad:testPresetLoadRewritesDismissOnBeforePinDefaults()
    local doc = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Old flash",
                graph = mouseSavedGraph(),
                layout = { { id = 1, x = 605, y = 328 } },
                variables = {},
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(doc))

    local loaded = Presets.Load()
    assertRawMouseRewrite(loaded.presets[1].graph, loaded.presets[1].layout)
end

function TestDropDismissOnLoad:testImportRewritesDismissOnBeforePinDefaults()
    local text = LibNodeGraph.Json.Default.encode(Export.BuildEnvelope({
        {
            kind = "group",
            name = "Imported",
            enabled = true,
            children = {
                {
                    kind = "alert",
                    name = "Pasted",
                    enabled = true,
                    graph = mouseSavedGraph(),
                    layout = { { id = 1, x = 605, y = 328 } },
                },
            },
        },
    }))
    local doc = Store.Empty()

    local ok = Export.Import(doc, text)
    luaunit.assertTrue(ok)
    local alert = doc.entries[1].children[1]
    assertRawMouseRewrite(alert.graph, alert.layout)
end

-- A pack snapshot is a saved graph that never passed through Presets.Load.
-- Library presets are migrated there, so Instantiate does not migrate again.
function TestDropDismissOnLoad:testSnapshotCopyRewritesDismissOnBeforePinDefaults()
    local registry = require("registry").new()
    local runtime = {
        effects = { Dismiss = function() end, PushStack = function() end },
        mouseActivityTick = 0,
        keyboardActivityTick = 0,
        BindTrigger = function() end,
        BindCursorMove = function() end,
    }
    require("src/nodes/triggers/player_input").Register(registry, runtime)
    require("src/nodes/actions/screen_flash").Register(registry, runtime)

    local snapshot = {
        name = "Old pack flash",
        graph = mouseSavedGraph(),
        layout = { { id = 1, x = 605, y = 328 } },
    }
    local entry, _, _, err = PresetCopy.InstantiateSnapshot(Store.Empty(), snapshot, registry)
    luaunit.assertNil(err)

    local flash, input
    for _, node in ipairs(entry.graph.nodes) do
        if node.type == "action.screen_flash" then flash = node end
        if node.type == "trigger.player_input" then input = node end
    end
    luaunit.assertEquals(input.controls, { mouseMove = true, keyboard = false, mouseClick = false })
    luaunit.assertEquals(flash.controls.sticky, true)
    luaunit.assertNil(flash.controls.dismissOn)
    local wired = false
    for _, conn in ipairs(entry.graph.connections) do
        if conn.fromNode == input.id and conn.fromPin == "out"
            and conn.toNode == flash.id and conn.toPin == "dismiss" then
            wired = true
        end
    end
    luaunit.assertTrue(wired)
    local placed = nil
    for _, pos in ipairs(entry.layout) do
        if pos.id == input.id then placed = pos end
    end
    luaunit.assertEquals(placed, { id = input.id, x = 355, y = 328 })
end
