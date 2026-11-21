-- Preset library: the PersistentDB key `presets` (no watchdog_ prefix), beside the Scope Buckets.
-- Builds real graphs through LibNodeGraph. Does not mount PrettyUI.

local luaunit = require("luaunit")

local Serialize = require("serialize")
local Json = require("json")
LibNodeGraph = {
    NewGraph = require("graph").new,
    Serialize = Serialize.Serialize,
    Deserialize = Serialize.Deserialize,
    Json = Json,
    UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
}

local Store = require("src/store")
local Presets = require("src/presets")
local Registry = require("registry")
local Controls = require("src/ui/controls")
-- Node files register their own tags. Eligibility must follow that registration.
require("src/nodes/triggers/skill")
require("src/nodes/actions/screen_marker")

local function newFakePersistentDB()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value)
        self.data[key] = value
        return true
    end
    function db:Delete(key) self.data[key] = nil end
    return db
end

TestPresets = {}

function TestPresets:setUp()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    self.registry:RegisterNodeType("fixture.note", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "text", kind = "data", direction = "in", default = "" },
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function() end,
    })
    Controls.Register("fixture.mode", {
        widget = "mode",
        modes = { { key = "a", label = "A", enabled = true } },
    })
    Controls.Register("fixture.laterEnum", {
        widget = "enum",
        choices = {
            { value = "one", label = "One" },
            { value = "two", label = "Two" },
        },
    })
    self.registry:RegisterNodeType("fixture.popup", {
        category = "action",
        displayName = "Popup",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "body", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "hold", label = "Hold (seconds)", kind = "data", direction = "in", dataType = "number", default = 4 },
            { name = "theme", label = "Theme", kind = "data", direction = "in", dataType = "bool", default = true },
            { name = "swatch", kind = "data", direction = "in", dataType = "color" },
            { name = "where", kind = "data", direction = "in", dataType = "coordgrid" },
            { name = "shot", kind = "data", direction = "in", dataType = "screen_marker.rect" },
            { name = "op", kind = "data", direction = "in", dataType = "compareOperation", default = "==" },
            { name = "style", kind = "data", direction = "in", dataType = "fixture.mode", default = "a" },
            { name = "later", kind = "data", direction = "in", dataType = "fixture.laterEnum", default = "one" },
            { name = "skillPin", kind = "data", direction = "in", dataType = "skill", default = "any" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "echo", kind = "data", direction = "out", dataType = "string" },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.matcher", {
        category = "trigger",
        displayName = "Game Message",
        pins = {
            { name = "contains", kind = "data", direction = "in", dataType = "matcher",
              label = "Message contains", default = { needle = "boss", mode = "pattern" } },
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.source", {
        category = "value",
        displayName = "Source",
        pins = {
            { name = "text", kind = "data", direction = "out", dataType = "string" },
        },
        run = function() end,
    })
    PersistentDB = newFakePersistentDB()
    Presets.SetSaveFailed(nil)
end

function TestPresets:tearDown()
    Presets.SetSaveFailed(nil)
    PersistentDB = nil
end

function TestPresets:testMissingKeyLoadsAsEmptyVersion1()
    local doc, err = Presets.Load()
    luaunit.assertNil(err)
    luaunit.assertEquals(doc.version, 1)
    luaunit.assertEquals(doc.presets, {})
    luaunit.assertNil(PersistentDB.data["presets"])
    local keys = {}
    for key in pairs(doc) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "presets", "version" })
end

function TestPresets:testBadVersionIsLeftOnDisk()
    local raw = '{"version":2,"presets":[]}'
    PersistentDB:SetString("presets", raw)
    local doc, err = Presets.Load()
    luaunit.assertNil(doc)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
end

function TestPresets:testBadDocumentRefusesAWrite()
    local raw = '{"version":2,"presets":[]}'
    PersistentDB:SetString("presets", raw)
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset, err = Presets.Add("Kept", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)

    PersistentDB:SetString("presets", "{not json")
    local rawBroken = PersistentDB:GetString("presets")
    preset, err = Presets.Add("Kept", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), rawBroken)
end

function TestPresets:testLoadStripsTagsFromSavedNames()
    local raw = LibNodeGraph.Json.Default.encode({
        version = 1,
        presets = { {
            id = 1,
            name = "<col=ff0000>Alpha",
            graph = { version = 1, nodes = {}, connections = {} },
            layout = {},
            variables = {},
        } },
    })
    PersistentDB:SetString("presets", raw)
    local doc, err = Presets.Load()
    luaunit.assertNil(err)
    luaunit.assertEquals(doc.presets[1].name, "Alpha")
end

function TestPresets:testSaveStripsClientTextTagsFromTheName()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger", {}, { name = "<col=00ff00>Ping" })
    local preset, err = Presets.Add("  <col=ff0000>Alpha</col>  ", graph, {})
    luaunit.assertNil(err)
    luaunit.assertEquals(preset.name, "Alpha")
    luaunit.assertEquals(preset.graph.nodes[1].name, "Ping")
    luaunit.assertEquals(graph.nodes[preset.graph.nodes[1].id].name, "Ping")

    local refused, refuseErr = Presets.Add("<col=ff0000>", graph, {})
    luaunit.assertNil(refused)
    luaunit.assertEquals(refuseErr, "Enter a preset name.")
end

function TestPresets:testSaveTrimsNameAndMintsOneOnAnEmptyLibrary()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.trigger")
    local preset, err = Presets.Add("  Alpha  ", graph, { [nodeId] = { x = 4, y = 8 } })
    luaunit.assertNil(err)
    luaunit.assertEquals(preset.id, 1)
    luaunit.assertEquals(preset.name, "Alpha")
    luaunit.assertEquals(preset.variables, {})

    local again = Presets.Add("Alpha", graph, {})
    luaunit.assertEquals(again.id, 2)
    luaunit.assertEquals(again.name, "Alpha")

    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 2)
    luaunit.assertEquals(doc.presets[1].name, "Alpha")
    luaunit.assertEquals(doc.presets[2].id, 2)
end

function TestPresets:testMintIdIsOnePastTheHighestIdStillPresent()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 2,
                name = "low",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
            {
                id = 4,
                name = "high",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset = Presets.Add("next", graph, {})
    luaunit.assertEquals(preset.id, 5)
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 3)
    local keys = {}
    for key in pairs(doc) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "presets", "version" })
end

function TestPresets:testSaveCopiesGraphLayoutAndEmptyVariables()
    local raw = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.note", controls = { text = "keep" } },
            { id = 3, type = "gone.type", controls = { hold = "stashed" } },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
        },
    }
    local graph = LibNodeGraph.Deserialize(raw, self.registry, { onUnknown = "placeholder" })
    local layout = {
        [1] = { x = 10, y = 20 },
        [2] = { x = 30, y = 40 },
        [3] = { x = 5, y = 6 },
    }
    local preset = Presets.Add("  Enrage callout  ", graph, layout)
    luaunit.assertEquals(preset.name, "Enrage callout")

    local keys = {}
    for key in pairs(preset) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "graph", "id", "layout", "name", "variables" })
    luaunit.assertEquals(preset.variables, {})
    luaunit.assertEquals(preset.layout, {
        { id = 1, x = 10, y = 20 },
        { id = 2, x = 30, y = 40 },
        { id = 3, x = 5, y = 6 },
    })
    luaunit.assertEquals(preset.graph.nodes[1].id, 1)
    luaunit.assertEquals(preset.graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(preset.graph.nodes[2].id, 2)
    luaunit.assertEquals(preset.graph.nodes[2].type, "fixture.note")
    luaunit.assertEquals(preset.graph.nodes[2].controls.text, "keep")
    luaunit.assertEquals(preset.graph.nodes[3].id, 3)
    luaunit.assertEquals(preset.graph.nodes[3].type, "gone.type")
    luaunit.assertEquals(preset.graph.nodes[3].controls.hold, "stashed")
    luaunit.assertEquals(preset.graph.connections[1].fromNode, 1)
    luaunit.assertEquals(preset.graph.connections[1].fromPin, "out")
    luaunit.assertEquals(preset.graph.connections[1].toNode, 2)
    luaunit.assertEquals(preset.graph.connections[1].toPin, "in")

    graph:SetControl(2, "text", "changed")
    graph:AddNode("fixture.trigger")
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets[1].graph.nodes, 3)
    luaunit.assertEquals(doc.presets[1].graph.nodes[2].controls.text, "keep")
    luaunit.assertEquals(doc.presets[1].name, "Enrage callout")
end

function TestPresets:testListUsesCaseInsensitiveNaturalOrder()
    local function preset(id, name)
        return {
            id = id,
            name = name,
            graph = { version = 1, nodes = {}, connections = {} },
            layout = {},
            variables = {},
        }
    end
    local seeded = {
        version = 1,
        presets = {
            preset(3, "Alert 10"),
            preset(1, "Alert 2"),
            preset(2, "Alert2"),
            preset(4, "alert 2"),
            preset(10, "B"),
            preset(11, "a"),
            preset(8, "img2"),
            preset(7, "img1"),
            preset(6, "img01"),
            preset(5, "img.2"),
            preset(20, "01"),
            preset(21, "1"),
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local listed, err = Presets.List()
    luaunit.assertNil(err)
    local ids = {}
    for i, presetRow in ipairs(listed) do ids[i] = presetRow.id end
    -- "a" before "B" (case fold). "Alert 2", "Alert2", and "alert 2" compare equal, so lower id first.
    -- "Alert 2" before "Alert 10". "01" before "1" (left-to-right on a zero-padded run).
    -- "img.2" before "img01" before "img1" before "img2" (dots and padding).
    luaunit.assertEquals(ids, { 20, 21, 11, 1, 2, 4, 3, 10, 5, 6, 7, 8 })
    local stored = Presets.Load()
    luaunit.assertEquals(stored.presets[1].id, 3)
    local storedKeys = {}
    for key in pairs(stored.presets[1]) do storedKeys[#storedKeys + 1] = key end
    table.sort(storedKeys)
    luaunit.assertEquals(storedKeys, { "graph", "id", "layout", "name", "variables" })
end

function TestPresets:testScopeSaveLeavesPresetsKeyUnchanged()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    Presets.Add("Alpha", graph, {})
    local before = PersistentDB:GetString("presets")

    local bucket = Store.Empty()
    Store.InsertEntry(bucket, Store.NewAlertEntry(1, "New Alert", graph, {}, true))
    luaunit.assertTrue(Store.SaveTo("global", bucket))
    luaunit.assertTrue(Store.SaveTo(Store.PlayerKey("99"), bucket))
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
    luaunit.assertNotNil(PersistentDB.data["global"])
    luaunit.assertNil(PersistentDB.data["watchdog_presets"])
end

function TestPresets:testNameLongerThan80IsNotSaved()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local tooLong = Presets.Add(string.rep("a", 81), graph, {})
    luaunit.assertNil(tooLong)
    luaunit.assertNil(PersistentDB.data["presets"])
    local capped = Presets.Add(string.rep("b", 80), graph, {})
    luaunit.assertEquals(capped.name, string.rep("b", 80))
end

function TestPresets:testBlankNameIsNotSaved()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset, err = Presets.Add("   ", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertNil(PersistentDB.data["presets"])
    preset = Presets.Add("", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNil(PersistentDB.data["presets"])
end

function TestPresets:testUnreadableJsonIsLeftOnDisk()
    local raw = "{not json"
    PersistentDB:SetString("presets", raw)
    local doc, err = Presets.Load()
    luaunit.assertNil(doc)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
end

-- Text, number, enum, checkbox, and a Matcher needle. Widget kind decides, including a tag
-- registered only by a node file (`skill`) and one registered in this test (`fixture.laterEnum`).
-- Swatch, coordgrid, capture, mode, exec, and data-out pins are absent. The node name is not a mark.
function TestPresets:testUnconnectedTextNumberEnumAndMatcherNeedleCanBeMarked()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local popup = graph:AddNode("fixture.popup")
    local match = graph:AddNode("fixture.matcher")
    graph.nodes[popup].name = "Enrage callout"
    luaunit.assertEquals(Presets.Eligible(graph), {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "theme" },
        { nodeId = popup, pinName = "op" },
        { nodeId = popup, pinName = "later" },
        { nodeId = popup, pinName = "skillPin" },
        { nodeId = match, pinName = "contains" },
    })
end

function TestPresets:testConnectedPinAndPlaceholderCannotBeMarked()
    local raw = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.source", controls = {} },
            { id = 2, type = "fixture.popup", controls = { body = "wired", hold = 4 } },
            { id = 3, type = "gone.type", controls = { hold = "stashed" } },
        },
        connections = {
            { fromNode = 1, fromPin = "text", toNode = 2, toPin = "body" },
        },
    }
    local graph = LibNodeGraph.Deserialize(raw, self.registry, { onUnknown = "placeholder" })
    luaunit.assertEquals(Presets.Eligible(graph), {
        { nodeId = 2, pinName = "hold" },
        { nodeId = 2, pinName = "theme" },
        { nodeId = 2, pinName = "op" },
        { nodeId = 2, pinName = "later" },
        { nodeId = 2, pinName = "skillPin" },
    })
end

function TestPresets:testAddStoresMarksByNodeIdThenPinOrder()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local popup = graph:AddNode("fixture.popup")
    local match = graph:AddNode("fixture.matcher")
    local preset, err = Presets.Add("Callout", graph, {
        [popup] = { x = 1, y = 2 },
        [match] = { x = 3, y = 4 },
    }, {
        { nodeId = match, pinName = "contains", label = "nope" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "body" },
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(preset.variables, {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = match, pinName = "contains" },
    })
    local stored = Presets.Load()
    luaunit.assertEquals(stored.presets[1].variables, {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = match, pinName = "contains" },
    })
    local keys = {}
    for key in pairs(stored.presets[1].variables[1]) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "nodeId", "pinName" })
    luaunit.assertEquals(stored.presets[1].name, "Callout")
end

function TestPresets:testIneligibleMarkRefusesTheAdd()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local popup = graph:AddNode("fixture.popup")
    local source = graph:AddNode("fixture.source")
    graph:Connect(source, "text", popup, "body")
    local before = PersistentDB:GetString("presets")
    local preset, err = Presets.Add("Callout", graph, {}, {
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "body" },
    })
    luaunit.assertNil(preset)
    luaunit.assertEquals(err, "That control cannot be marked.")
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)

    preset, err = Presets.Add("Callout", graph, {}, {
        { nodeId = popup, pinName = "swatch" },
    })
    luaunit.assertNil(preset)
    luaunit.assertEquals(err, "That control cannot be marked.")
    luaunit.assertNil(PersistentDB.data["presets"])
end

-- One remaining pin is the whole choice for that node. A node with nothing left is absent.
function TestPresets:testNodesWithNothingLeftToMarkAreAbsent()
    local eligible = {
        { nodeId = 1, pinName = "body" },
        { nodeId = 2, pinName = "hold" },
        { nodeId = 2, pinName = "title" },
        { nodeId = 4, pinName = "contains" },
    }
    luaunit.assertEquals(Presets.UnmarkedNodes(eligible, {
        { nodeId = 4, pinName = "contains" },
    }), {
        { nodeId = 1, pinNames = { "body" } },
        { nodeId = 2, pinNames = { "hold", "title" } },
    })
end

function TestPresets:testRenameTrimsAndKeepsTheId()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 4,
                name = "Zebra",
                graph = {
                    version = 1,
                    nodes = { { id = 1, type = "fixture.note", controls = { text = "keep" } } },
                    connections = {},
                },
                layout = { { id = 1, x = 12, y = 18 } },
                variables = { { nodeId = 1, pinName = "text" } },
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local preset, err = Presets.Rename(4, "  Alpha  ")
    luaunit.assertNil(err)
    luaunit.assertEquals(preset.id, 4)
    luaunit.assertEquals(preset.name, "Alpha")
    local doc = Presets.Load()
    luaunit.assertEquals(doc.presets[1].id, 4)
    luaunit.assertEquals(doc.presets[1].name, "Alpha")
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].id, 1)
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].type, "fixture.note")
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.text, "keep")
    luaunit.assertEquals(doc.presets[1].layout, { { id = 1, x = 12, y = 18 } })
    luaunit.assertEquals(doc.presets[1].variables, { { nodeId = 1, pinName = "text" } })
end

function TestPresets:testRenameRefusesABlankName()
    local raw = LibNodeGraph.Json.Default.encode({
        version = 1,
        presets = {
            {
                id = 4,
                name = "Zebra",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
        },
    })
    PersistentDB:SetString("presets", raw)
    local blank, blankErr = Presets.Rename(4, "   ")
    luaunit.assertNil(blank)
    luaunit.assertNotNil(blankErr)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
    local empty = Presets.Rename(4, "")
    luaunit.assertNil(empty)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
    local doc = Presets.Load()
    luaunit.assertEquals(doc.presets[1].name, "Zebra")
end

function TestPresets:testRenameRefusesANameLongerThan80()
    local raw = LibNodeGraph.Json.Default.encode({
        version = 1,
        presets = {
            {
                id = 4,
                name = "Zebra",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
        },
    })
    PersistentDB:SetString("presets", raw)
    local preset = Presets.Rename(4, string.rep("a", 81))
    luaunit.assertNil(preset)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
    local capped = Presets.Rename(4, "  " .. string.rep("b", 80) .. "  ")
    luaunit.assertEquals(capped.name, string.rep("b", 80))
    luaunit.assertEquals(capped.id, 4)
end

function TestPresets:testRenameDoesNotWriteWhenTheIdIsMissing()
    local raw = LibNodeGraph.Json.Default.encode({
        version = 1,
        presets = {
            {
                id = 4,
                name = "Zebra",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = { { id = 1, x = 2, y = 3 } },
                variables = {},
            },
        },
    })
    PersistentDB:SetString("presets", raw)
    local preset, err = Presets.Rename(9, "Alpha")
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 1)
    luaunit.assertEquals(doc.presets[1].id, 4)
    luaunit.assertEquals(doc.presets[1].name, "Zebra")
end

function TestPresets:testRenameDoesNotWriteAnUnreadableDocument()
    PersistentDB:SetString("presets", "{not json")
    local raw = PersistentDB:GetString("presets")
    local preset, err = Presets.Rename(1, "Alpha")
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)

    local versioned = '{"version":2,"presets":[{"id":1,"name":"Zebra"}]}'
    PersistentDB:SetString("presets", versioned)
    preset = Presets.Rename(1, "Alpha")
    luaunit.assertNil(preset)
    luaunit.assertEquals(PersistentDB:GetString("presets"), versioned)
end

function TestPresets:testTwoPresetsMayShareAName()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Alpha",
                graph = {
                    version = 1,
                    nodes = { { id = 1, type = "fixture.note", controls = { text = "first" } } },
                    connections = {},
                },
                layout = { { id = 1, x = 1, y = 2 } },
                variables = { { nodeId = 1, pinName = "text" } },
            },
            {
                id = 2,
                name = "Beta",
                graph = {
                    version = 1,
                    nodes = { { id = 3, type = "fixture.trigger", controls = {} } },
                    connections = {},
                },
                layout = { { id = 3, x = 8, y = 9 } },
                variables = {},
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local preset, err = Presets.Rename(2, "Alpha")
    luaunit.assertNil(err)
    luaunit.assertEquals(preset.id, 2)
    luaunit.assertEquals(preset.name, "Alpha")
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 2)
    luaunit.assertEquals(doc.presets[1].id, 1)
    luaunit.assertEquals(doc.presets[1].name, "Alpha")
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.text, "first")
    luaunit.assertEquals(doc.presets[1].layout, { { id = 1, x = 1, y = 2 } })
    luaunit.assertEquals(doc.presets[1].variables, { { nodeId = 1, pinName = "text" } })
    luaunit.assertEquals(doc.presets[2].id, 2)
    luaunit.assertEquals(doc.presets[2].name, "Alpha")
    luaunit.assertEquals(doc.presets[2].graph.nodes[1].id, 3)
    luaunit.assertEquals(doc.presets[2].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(doc.presets[2].layout, { { id = 3, x = 8, y = 9 } })
    luaunit.assertEquals(doc.presets[2].variables, {})
end

function TestPresets:testListOrderAfterRenameFollowsNaturalOrder()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Alert 10",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
            {
                id = 2,
                name = "Alert 2",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
            {
                id = 5,
                name = "alert 2",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local before = Presets.List()
    local beforeIds = {}
    for i, row in ipairs(before) do beforeIds[i] = row.id end
    luaunit.assertEquals(beforeIds, { 2, 5, 1 })

    local preset = Presets.Rename(1, "  Alert 1  ")
    luaunit.assertEquals(preset.id, 1)
    luaunit.assertEquals(preset.name, "Alert 1")
    local listed = Presets.List()
    local ids = {}
    local names = {}
    for i, row in ipairs(listed) do
        ids[i] = row.id
        names[i] = row.name
    end
    luaunit.assertEquals(ids, { 1, 2, 5 })
    luaunit.assertEquals(names, { "Alert 1", "Alert 2", "alert 2" })
    local stored = Presets.Load()
    luaunit.assertEquals(stored.presets[1].id, 1)
    luaunit.assertEquals(stored.presets[2].id, 2)
    luaunit.assertEquals(stored.presets[3].id, 5)
end

function TestPresets:testDeleteRemovesOnlyTheAddressedIdWhenNamesMatch()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Alpha",
                graph = {
                    version = 1,
                    nodes = { { id = 1, type = "fixture.note", controls = { text = "first" } } },
                    connections = {},
                },
                layout = { { id = 1, x = 1, y = 2 } },
                variables = { { nodeId = 1, pinName = "text" } },
            },
            {
                id = 2,
                name = "Alpha",
                graph = {
                    version = 1,
                    nodes = { { id = 3, type = "fixture.trigger", controls = {} } },
                    connections = { { fromNode = 3, fromPin = "out", toNode = 3, toPin = "out" } },
                },
                layout = { { id = 3, x = 8, y = 9 } },
                variables = { { nodeId = 3, pinName = "out" } },
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local ok, err = Presets.Delete(1)
    luaunit.assertNil(err)
    luaunit.assertEquals(ok, true)
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 1)
    luaunit.assertEquals(doc.presets[1].id, 2)
    luaunit.assertEquals(doc.presets[1].name, "Alpha")
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].id, 3)
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(doc.presets[1].graph.connections[1].fromPin, "out")
    luaunit.assertEquals(doc.presets[1].layout, { { id = 3, x = 8, y = 9 } })
    luaunit.assertEquals(doc.presets[1].variables, { { nodeId = 3, pinName = "out" } })
    local listed = Presets.List()
    luaunit.assertEquals(#listed, 1)
    luaunit.assertEquals(listed[1].id, 2)
end

function TestPresets:testDeleteOfAMissingIdDoesNotWipeTheLibrary()
    local raw = LibNodeGraph.Json.Default.encode({
        version = 1,
        presets = {
            {
                id = 4,
                name = "Zebra",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = { { id = 1, x = 2, y = 3 } },
                variables = { { nodeId = 1, pinName = "text" } },
            },
        },
    })
    PersistentDB:SetString("presets", raw)
    local ok, err = Presets.Delete(9)
    luaunit.assertNil(ok)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 1)
    luaunit.assertEquals(doc.presets[1].id, 4)
    luaunit.assertEquals(doc.presets[1].name, "Zebra")
    luaunit.assertEquals(doc.presets[1].layout, { { id = 1, x = 2, y = 3 } })
end

function TestPresets:testDeleteDoesNotWriteAnUnreadableDocument()
    PersistentDB:SetString("presets", "{not json")
    local raw = PersistentDB:GetString("presets")
    local ok, err = Presets.Delete(1)
    luaunit.assertNil(ok)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)

    local versioned = '{"version":2,"presets":[{"id":1,"name":"Zebra"}]}'
    PersistentDB:SetString("presets", versioned)
    ok = Presets.Delete(1)
    luaunit.assertNil(ok)
    luaunit.assertEquals(PersistentDB:GetString("presets"), versioned)
end

function TestPresets:testDeleteLeavesAlertsAlreadyCreatedFromIt()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset = Presets.Add("Enrage callout", graph, { [1] = { x = 4, y = 5 } })
    local bucket = Store.Empty()
    Store.InsertEntry(bucket, Store.NewAlertEntry(8, "Enrage callout", graph, { [1] = { x = 4, y = 5 } }, true))
    luaunit.assertTrue(Store.SaveTo("global", bucket))
    luaunit.assertTrue(Store.SaveTo(Store.PlayerKey("99"), bucket))
    local globalBefore = PersistentDB:GetString("global")
    local playerBefore = PersistentDB:GetString(Store.PlayerKey("99"))

    local ok, err = Presets.Delete(preset.id)
    luaunit.assertNil(err)
    luaunit.assertEquals(ok, true)
    luaunit.assertEquals(PersistentDB:GetString("global"), globalBefore)
    luaunit.assertEquals(PersistentDB:GetString(Store.PlayerKey("99")), playerBefore)
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(#loaded.entries, 1)
    luaunit.assertEquals(loaded.entries[1].id, 8)
    luaunit.assertEquals(loaded.entries[1].name, "Enrage callout")
    luaunit.assertEquals(loaded.entries[1].enabled, true)
    local listed = Presets.List()
    luaunit.assertEquals(listed, {})
end

function TestPresets:testDeleteOfTheLastPresetLeavesAnEmptyLibrary()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset = Presets.Add("Only", graph, {})
    local ok = Presets.Delete(preset.id)
    luaunit.assertEquals(ok, true)
    local doc = Presets.Load()
    luaunit.assertEquals(doc.version, 1)
    luaunit.assertEquals(doc.presets, {})
    local listed, err = Presets.List()
    luaunit.assertNil(err)
    luaunit.assertEquals(listed, {})
end

function TestPresets:testSetStringFalseLeavesThePreviousPresetBytes()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local first = Presets.Add("Kept", graph, {})
    luaunit.assertNotNil(first)
    local previous = PersistentDB:GetString("presets")
    function PersistentDB:SetString()
        return false
    end

    local second, err = Presets.Add("New", graph, {})

    luaunit.assertNil(second)
    luaunit.assertEquals(err, "Could not save the preset.")
    luaunit.assertEquals(PersistentDB:GetString("presets"), previous)
end

function TestPresets:testSetStringNilOrThrowLeavesThePreviousPresetBytes()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    luaunit.assertNotNil(Presets.Add("Kept", graph, {}))
    local previous = PersistentDB:GetString("presets")

    function PersistentDB:SetString()
        return nil
    end
    local added = Presets.Add("Nil", graph, {})
    luaunit.assertNil(added)
    luaunit.assertEquals(PersistentDB:GetString("presets"), previous)

    function PersistentDB:SetString()
        error("rejected")
    end
    added = Presets.Add("Thrown", graph, {})
    luaunit.assertNil(added)
    luaunit.assertEquals(PersistentDB:GetString("presets"), previous)
end

function TestPresets:testFailedPresetSaveAsksToTellThePlayer()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    luaunit.assertNotNil(Presets.Add("Kept", graph, {}))
    local asked = 0
    Presets.SetSaveFailed(function() asked = asked + 1 end)
    function PersistentDB:SetString()
        return false
    end

    luaunit.assertNil(Presets.Add("New", graph, {}))
    luaunit.assertEquals(asked, 1)

    asked = 0
    luaunit.assertNil(Presets.Add("   ", graph, {}))
    luaunit.assertEquals(asked, 0)
end
