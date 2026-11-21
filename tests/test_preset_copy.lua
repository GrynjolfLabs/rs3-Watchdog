-- Copy a Preset into an enabled Alert in a caller-supplied Bucket.
-- Does not write the Preset library. Sound Effect same-id, None, and untouched
-- answers stay covered by the Alert Preset tests.

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
local PresetCopy = require("src/preset_copy")
local Registry = require("registry")
-- Records string, number, bool, and matcher widget kinds that bake reads.
require("src/ui/controls")

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

TestPresetCopy = {}

function TestPresetCopy:setUp()
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
    self.registry:RegisterNodeType("fixture.popup", {
        category = "action",
        displayName = "Popup",
        pins = {
            { name = "body", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "hold", label = "Hold (seconds)", kind = "data", direction = "in", dataType = "number", default = 4 },
            { name = "theme", label = "Theme", kind = "data", direction = "in", dataType = "bool", default = true },
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
    PersistentDB = newFakePersistentDB()
end

function TestPresetCopy:tearDown()
    PersistentDB = nil
end

function TestPresetCopy:testInstantiateWritesAnEnabledAlertIntoTheCallerBucket()
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
    local preset = Presets.Add("Enrage callout", graph, {
        [1] = { x = 10, y = 20 },
        [2] = { x = 30, y = 40 },
        [3] = { x = 5, y = 6 },
    })
    local before = PersistentDB:GetString("presets")

    local bucket = Store.Empty()
    local existing = LibNodeGraph.NewGraph(self.registry)
    existing:AddNode("fixture.trigger")
    Store.InsertEntry(bucket, Store.NewAlertEntry(7, "existing", existing, {}, true))

    local entry, live, layout, err = PresetCopy.Instantiate(bucket, preset.id, self.registry)
    luaunit.assertNil(err)
    luaunit.assertEquals(entry.id, 8)
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.name, "Enrage callout")
    luaunit.assertEquals(entry.enabled, true)
    local entryKeys = {}
    for key in pairs(entry) do entryKeys[#entryKeys + 1] = key end
    table.sort(entryKeys)
    luaunit.assertEquals(entryKeys, { "enabled", "graph", "id", "kind", "layout", "name" })
    luaunit.assertEquals(#bucket.entries, 2)
    luaunit.assertEquals(bucket.entries[2].id, 8)
    luaunit.assertEquals(entry.graph.nodes[1].id, 1)
    luaunit.assertEquals(entry.graph.nodes[2].id, 2)
    luaunit.assertEquals(entry.graph.nodes[2].controls.text, "keep")
    luaunit.assertEquals(entry.graph.nodes[3].id, 3)
    luaunit.assertEquals(entry.graph.nodes[3].type, "gone.type")
    luaunit.assertEquals(entry.graph.nodes[3].controls.hold, "stashed")
    luaunit.assertEquals(entry.layout, {
        { id = 1, x = 10, y = 20 },
        { id = 2, x = 30, y = 40 },
        { id = 3, x = 5, y = 6 },
    })
    luaunit.assertEquals(layout[1].x, 10)
    luaunit.assertEquals(layout[2].y, 40)
    luaunit.assertEquals(live:GetControl(2, "text"), "keep")
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)

    live:SetControl(2, "text", "edited")
    luaunit.assertEquals(Presets.Load().presets[1].graph.nodes[2].controls.text, "keep")
end

function TestPresetCopy:testInstantiateRefusesAPresetThatHasVariables()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Needs values",
                graph = {
                    version = 1,
                    nodes = { { id = 1, type = "fixture.note", controls = { text = "keep" } } },
                    connections = {},
                },
                layout = { { id = 1, x = 0, y = 0 } },
                variables = { { nodeId = 1, pinName = "text" } },
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry, _, _, err = PresetCopy.Instantiate(bucket, 1, self.registry)
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "variables")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

function TestPresetCopy:testInstantiateRefusesAnUnreadableLibrary()
    PersistentDB:SetString("presets", "{not json")
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry = PresetCopy.Instantiate(bucket, 1, self.registry)
    luaunit.assertNil(entry)
    luaunit.assertEquals(#bucket.entries, 0)
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

local function markedPopup(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local popup = graph:AddNode("fixture.popup", {
        body = "saved",
        hold = 4,
        theme = true,
    })
    local match = graph:AddNode("fixture.matcher", {
        contains = { needle = "boss", mode = "pattern" },
    })
    graph.nodes[popup].name = "Enrage callout"
    local preset, err = Presets.Add("Enrage callout", graph, {
        [popup] = { x = 10, y = 20 },
        [match] = { x = 30, y = 40 },
    }, {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "theme" },
        { nodeId = match, pinName = "contains" },
    })
    return preset, err, popup, match
end

function TestPresetCopy:testInstantiateBakesTextNumberEnumAndMatcherNeedle()
    local preset = markedPopup(self.registry)
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local existing = LibNodeGraph.NewGraph(self.registry)
    existing:AddNode("fixture.trigger")
    Store.InsertEntry(bucket, Store.NewAlertEntry(7, "existing", existing, {}, true))

    local entry, live, layout, err = PresetCopy.Instantiate(bucket, preset.id, self.registry, {
        "  keep  ",
        { raw = "1k", quantity = 1000 },
        false,
        "  boss  ",
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(entry.id, 8)
    luaunit.assertEquals(entry.name, "Enrage callout")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(entry.graph.nodes[1].id, 1)
    luaunit.assertEquals(entry.graph.nodes[2].id, 2)
    luaunit.assertEquals(entry.graph.nodes[1].controls.body, "  keep  ")
    luaunit.assertEquals(entry.graph.nodes[1].controls.hold, 1000)
    luaunit.assertEquals(entry.graph.nodes[1].controls.theme, false)
    luaunit.assertEquals(entry.graph.nodes[2].controls.contains, { needle = "  boss  ", mode = "pattern" })
    luaunit.assertEquals(entry.layout, {
        { id = 1, x = 10, y = 20 },
        { id = 2, x = 30, y = 40 },
    })
    luaunit.assertEquals(layout[1].x, 10)
    luaunit.assertEquals(live:GetControl(1, "body"), "  keep  ")
    luaunit.assertEquals(live:GetControl(1, "hold"), 1000)
    luaunit.assertEquals(live:GetControl(1, "theme"), false)
    luaunit.assertEquals(live:GetControl(2, "contains"), { needle = "  boss  ", mode = "pattern" })
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
    local doc = Presets.Load()
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.body, "saved")
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.hold, 4)
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.theme, true)
    luaunit.assertEquals(doc.presets[1].graph.nodes[2].controls.contains.needle, "boss")
    luaunit.assertEquals(doc.presets[1].graph.nodes[2].controls.contains.mode, "pattern")
end

function TestPresetCopy:testInstantiateBakesEmptyTextAndEmptyNeedle()
    local preset = markedPopup(self.registry)
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry, live = PresetCopy.Instantiate(bucket, preset.id, self.registry, {
        "",
        "4",
        true,
        "",
    })
    luaunit.assertEquals(entry.graph.nodes[1].controls.body, "")
    luaunit.assertEquals(live:GetControl(1, "body"), "")
    luaunit.assertEquals(entry.graph.nodes[2].controls.contains, { needle = "", mode = "pattern" })
    luaunit.assertEquals(live:GetControl(2, "contains").mode, "pattern")
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

function TestPresetCopy:testInstantiateRefusesABlankNumberWithoutWritingAnEntry()
    local preset = markedPopup(self.registry)
    local before = PersistentDB:GetString("presets")
    local blanks = { "", "   ", "nope", { raw = "   ", quantity = 0 }, { raw = "", quantity = 0 } }
    for _, hold in ipairs(blanks) do
        local bucket = Store.Empty()
        local entry, _, _, err = PresetCopy.Instantiate(bucket, preset.id, self.registry, {
            "keep",
            hold,
            true,
            "boss",
        })
        luaunit.assertNil(entry)
        luaunit.assertEquals(err, "Enter a number.")
        luaunit.assertEquals(bucket.entries, {})
        luaunit.assertEquals(PersistentDB:GetString("presets"), before)
    end
    local bucket = Store.Empty()
    local entry, live = PresetCopy.Instantiate(bucket, preset.id, self.registry, {
        "keep",
        "0",
        true,
        "boss",
    })
    luaunit.assertEquals(live:GetControl(1, "hold"), 0)
    luaunit.assertEquals(entry.graph.nodes[1].controls.hold, 0)
end

function TestPresetCopy:testInstantiateRefusesAMarkThatDoesNotResolve()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Needs values",
                graph = {
                    version = 1,
                    nodes = {
                        { id = 1, type = "fixture.popup", controls = { body = "saved", hold = 4 } },
                        { id = 2, type = "gone.type", controls = { hold = "stashed" } },
                    },
                    connections = {},
                },
                layout = { { id = 1, x = 0, y = 0 } },
                variables = { { nodeId = 1, pinName = "missing" } },
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry, _, _, err = PresetCopy.Instantiate(bucket, 1, self.registry, { "x" })
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "A marked control is missing.")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)

    seeded.presets[1].variables = { { nodeId = 2, pinName = "hold" } }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    before = PersistentDB:GetString("presets")
    bucket = Store.Empty()
    entry, _, _, err = PresetCopy.Instantiate(bucket, 1, self.registry, { "x" })
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "A marked control is missing.")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

-- Saving writes 1.5, -0.5 as 2, -1. The live point stays where the drag left it.
function TestPresetCopy:testSavingAPresetWritesIntegersWithoutMovingTheLiveLayout()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local id = graph:AddNode("fixture.trigger")
    local layout = { [id] = { x = 1.5, y = -0.5 } }

    local preset, err = Presets.Add("Gate", graph, layout)
    luaunit.assertNil(err)
    luaunit.assertEquals(layout[id].x, 1.5)
    luaunit.assertEquals(layout[id].y, -0.5)
    luaunit.assertEquals(preset.layout[1].x, 2)
    luaunit.assertEquals(preset.layout[1].y, -1)

    local loaded = Presets.Load()
    luaunit.assertEquals(loaded.presets[1].layout[1].x, 2)
    luaunit.assertEquals(loaded.presets[1].layout[1].y, -1)

    local bucket = Store.Empty()
    local entry, _, live = PresetCopy.Instantiate(bucket, preset.id, self.registry)
    luaunit.assertEquals(entry.layout[1].x, 2)
    luaunit.assertEquals(entry.layout[1].y, -1)
    luaunit.assertEquals(live[id].x, 2)
    luaunit.assertEquals(live[id].y, -1)
end

-- A preset saved at 1.5, -1.5 stays there through a copy. Saving that point writes 2, -2.
function TestPresetCopy:testFractionalPresetLayoutStaysUntilThePresetIsSavedAgain()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.trigger")
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Old",
                graph = LibNodeGraph.Serialize(graph),
                layout = { { id = nodeId, x = 1.5, y = -1.5 } },
                variables = {},
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))

    local loaded = Presets.Load()
    luaunit.assertEquals(loaded.presets[1].layout[1].x, 1.5)
    luaunit.assertEquals(loaded.presets[1].layout[1].y, -1.5)

    local bucket = Store.Empty()
    local entry, _, live = PresetCopy.Instantiate(bucket, 1, self.registry)
    luaunit.assertEquals(live[nodeId].x, 1.5)
    luaunit.assertEquals(live[nodeId].y, -1.5)
    luaunit.assertEquals(entry.layout[1].x, 2)
    luaunit.assertEquals(entry.layout[1].y, -2)
    luaunit.assertEquals(Presets.Load().presets[1].layout[1].x, 1.5)
    luaunit.assertEquals(Presets.Load().presets[1].layout[1].y, -1.5)

    local again, err = Presets.Add("Again", graph, live)
    luaunit.assertNil(err)
    luaunit.assertEquals(live[nodeId].x, 1.5)
    luaunit.assertEquals(live[nodeId].y, -1.5)
    luaunit.assertEquals(again.layout[1].x, 2)
    luaunit.assertEquals(again.layout[1].y, -2)
    local doc = Presets.Load()
    luaunit.assertEquals(doc.presets[1].layout[1].x, 1.5)
    luaunit.assertEquals(doc.presets[1].layout[1].y, -1.5)
    luaunit.assertEquals(doc.presets[2].layout[1].x, 2)
    luaunit.assertEquals(doc.presets[2].layout[1].y, -2)
end
