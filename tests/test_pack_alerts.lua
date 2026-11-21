-- Alert Presets offered from the Pack registry, copied into an Alert.
-- Loaded directly, the way the Preset library tests load that library. No PrettyUI.

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

local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local PresetCopy = require("src/preset_copy")
local Store = require("src/store")
local Registry = require("registry")
-- Records string/number widget kinds that bake reads.
require("src/ui/controls")

TestPackAlerts = {}

function TestPackAlerts:setUp()
    self.packs = Packs.new()
end

function TestPackAlerts:tearDown()
    PersistentDB = nil
end

local function row(authorId, name)
    return { authorId = authorId, name = name, graph = {} }
end

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

local function noteRegistry()
    local registry = Registry.new()
    registry:RegisterNodeType("fixture.note", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "text", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function() end,
    })
    return registry
end

local function entryKeys(entry)
    local keys = {}
    for key in pairs(entry) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- Same names the Preset library lists by natural order. Pack ties use the raw
-- name, so "Voice" stays ahead of "voice" even though "voice" was registered first.
-- A Pack with no Alert Preset is not a group.
function TestPackAlerts:testGroupsFollowNaturalPackNameOrder()
    local scrambled = {
        "img2", "B", "Alert 10", "1", "img.2", "alert 2", "a", "img01",
        "Alert2", "01", "img1", "Alert 2", "voice", "Voice",
    }
    for _, name in ipairs(scrambled) do
        self.packs:RegisterDataPack(name, {
            alertPresets = { row("only", "Row") },
        })
    end
    self.packs:RegisterDataPack("Sounds", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 1 } },
    })
    self.packs:RegisterDataPack("NoRows", {
        alertPresets = { { authorId = "x", name = "   ", graph = {} } },
    })

    local got = {}
    for i, group in ipairs(PackRows.AlertPresetGroups(self.packs)) do
        got[i] = group.packName
    end
    luaunit.assertEquals(got, {
        "01", "1", "a", "Alert 2", "Alert2", "alert 2", "Alert 10", "B",
        "img.2", "img01", "img1", "img2", "Voice", "voice",
    })
end

-- Trimmed name, then the raw name when the natural compare ties, then the
-- author id when the names match including case. "bell" stays after "Bell"
-- even though its author id sorts first.
function TestPackAlerts:testPresetsInsideAGroupFollowNameThenAuthorId()
    self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            row("img2", "  img2  "),
            row("z", "Bell"),
            row("a", "bell"),
            row("10", "Alert 10"),
            row("B", "B"),
            row("alert2", "alert 2"),
            row("1", "1"),
            row("img.2", "img.2"),
            row("m", "Bell"),
            row("a-name", "a"),
            row("img01", "img01"),
            row("Alert2", "Alert2"),
            row("01", "01"),
            row("img1", "img1"),
            row("Alert 2", "Alert 2"),
        },
    })

    local groups = PackRows.AlertPresetGroups(self.packs)
    luaunit.assertEquals(#groups, 1)
    luaunit.assertEquals(groups[1].packName, "Voice")
    local got = {}
    for i, preset in ipairs(groups[1].presets) do
        got[i] = preset.name .. "|" .. preset.authorId
    end
    luaunit.assertEquals(got, {
        "01|01",
        "1|1",
        "a|a-name",
        "Alert 2|Alert 2",
        "Alert2|Alert2",
        "alert 2|alert2",
        "Alert 10|10",
        "B|B",
        "Bell|m",
        "Bell|z",
        "bell|a",
        "img.2|img.2",
        "img01|img01",
        "img1|img1",
        "img2|img2",
    })
end

-- The captured row is what create deserializes. An unknown type stays a placeholder.
-- The Alert is enabled, takes the next Entry id and the trimmed name, and keeps
-- neither the author id nor the Pack name. The Preset library is not written.
function TestPackAlerts:testCapturedSnapshotCopiesAnEnabledAlertWithoutAnAuthorId()
    local registry = noteRegistry()
    local raw = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.note", controls = { text = "keep" } },
            { id = 2, type = "gone.type", controls = { hold = "stashed" } },
        },
        connections = {},
    }
    self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            {
                authorId = "greet",
                name = "  Enrage callout  ",
                graph = raw,
                layout = {
                    { id = 1, x = 10, y = 20 },
                    { id = 2, x = 5, y = 6 },
                },
            },
        },
    })
    local snapshot = PackRows.AlertPresetGroups(self.packs)[1].presets[1]
    luaunit.assertEquals(snapshot.name, "Enrage callout")

    PersistentDB = newFakePersistentDB()
    PersistentDB:SetString("presets", "library")
    local bucket = Store.Empty()
    local existing = LibNodeGraph.NewGraph(registry)
    existing:AddNode("fixture.note")
    Store.InsertEntry(bucket, Store.NewAlertEntry(7, "existing", existing, {}, true))

    local entry, live, layout, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry)
    luaunit.assertNil(err)
    luaunit.assertEquals(entry.id, 8)
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.name, "Enrage callout")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })
    luaunit.assertEquals(#bucket.entries, 2)
    luaunit.assertEquals(bucket.entries[2].id, 8)
    luaunit.assertEquals(entry.graph.nodes[1].id, 1)
    luaunit.assertEquals(entry.graph.nodes[1].controls.text, "keep")
    luaunit.assertEquals(entry.graph.nodes[2].id, 2)
    luaunit.assertEquals(entry.graph.nodes[2].type, "gone.type")
    luaunit.assertEquals(entry.graph.nodes[2].controls.hold, "stashed")
    luaunit.assertEquals(live.nodes[2].unknown.type, "gone.type")
    luaunit.assertEquals(live.nodes[2].unknown.controls.hold, "stashed")
    luaunit.assertEquals(entry.layout, {
        { id = 1, x = 10, y = 20 },
        { id = 2, x = 5, y = 6 },
    })
    luaunit.assertEquals(layout[1].x, 10)
    luaunit.assertEquals(layout[2].y, 6)
    luaunit.assertEquals(live:GetControl(1, "text"), "keep")
    luaunit.assertEquals(PersistentDB.data, { presets = "library" })
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").name, "Enrage callout")

    local again = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry)
    luaunit.assertEquals(again.id, 9)
    luaunit.assertEquals(#bucket.entries, 3)
    luaunit.assertEquals(PersistentDB.data, { presets = "library" })
end

-- Answers follow the captured Variable list, not node id order. No answers writes nothing.
function TestPackAlerts:testVariablesBakeInCapturedListOrder()
    local registry = noteRegistry()
    local graph = LibNodeGraph.NewGraph(registry)
    local first = graph:AddNode("fixture.note", { text = "saved-first" })
    local second = graph:AddNode("fixture.note", { text = "saved-second" })
    self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            {
                authorId = "greet",
                name = "Callout",
                graph = LibNodeGraph.Serialize(graph),
                variables = {
                    { nodeId = second, pinName = "text" },
                    { nodeId = first, pinName = "text" },
                },
            },
        },
    })
    local snapshot = PackRows.AlertPresetGroups(self.packs)[1].presets[1]
    luaunit.assertEquals(snapshot.variables, {
        { nodeId = second, pinName = "text" },
        { nodeId = first, pinName = "text" },
    })

    PersistentDB = newFakePersistentDB()
    PersistentDB:SetString("presets", "library")
    local bucket = Store.Empty()
    local refused, _, _, refuseErr = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry)
    luaunit.assertNil(refused)
    luaunit.assertEquals(refuseErr, "variables")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").name, "Callout")
    luaunit.assertEquals(PersistentDB.data, { presets = "library" })

    local entry, live, _, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, {
        "from-second",
        "from-first",
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(entry.name, "Callout")
    luaunit.assertEquals(live:GetControl(second, "text"), "from-second")
    luaunit.assertEquals(live:GetControl(first, "text"), "from-first")
    luaunit.assertEquals(entry.graph.nodes[1].controls.text, "from-first")
    luaunit.assertEquals(entry.graph.nodes[2].controls.text, "from-second")
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").graph.nodes[1].controls.text, "saved-first")
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").graph.nodes[2].controls.text, "saved-second")
    luaunit.assertEquals(PersistentDB.data, { presets = "library" })
end

function TestPackAlerts:testASoundEffectAnswerIsWrittenOntoTheControl()
    _G.id = _G.id or {}
    _G.id.Sound = _G.id.Sound or { TOWN_CRIER_BELL_RING_1 = 2608 }
    local registry = Registry.new()
    require("src/nodes/actions/sound").Register(registry)
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    local graph = LibNodeGraph.NewGraph(registry)
    local nodeId = graph:AddNode("action.sound", { soundId = record })
    self.packs:RegisterDataPack("Voice", {
        alertPresets = { {
            authorId = "greet",
            name = "Callout",
            graph = LibNodeGraph.Serialize(graph),
            variables = { { nodeId = nodeId, pinName = "soundId" } },
        } },
    })
    local snapshot = PackRows.AlertPresetGroups(self.packs)[1].presets[1]
    local bucket = Store.Empty()

    local refused, _, _, refuseErr = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, { "" })
    luaunit.assertNil(refused)
    luaunit.assertEquals(refuseErr, "Enter a number.")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").name, "Callout")

    local entry, live, _, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, {
        record,
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(live:GetControl(nodeId, "soundId"), record)
    luaunit.assertEquals(#bucket.entries, 1)
    luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })

    local replaced, replacedLive = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, {
        99,
    })
    luaunit.assertEquals(replacedLive:GetControl(nodeId, "soundId"), 99)
    luaunit.assertEquals(live:GetControl(nodeId, "soundId"), record)
    luaunit.assertTrue(replaced.id ~= entry.id)
end

function TestPackAlerts:testAPlainNumberAnswerIsParsedOntoTheSoundEffect()
    _G.id = _G.id or {}
    _G.id.Sound = _G.id.Sound or { TOWN_CRIER_BELL_RING_1 = 2608 }
    local registry = Registry.new()
    require("src/nodes/actions/sound").Register(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local nodeId = graph:AddNode("action.sound", {
        soundId = { pack = "Voice", authorId = "bell", soundId = 12345 },
    })
    local snapshot = {
        name = "Callout",
        graph = LibNodeGraph.Serialize(graph),
        variables = { { nodeId = nodeId, pinName = "soundId" } },
    }
    local bucket = Store.Empty()
    local _, live, _, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, {
        { raw = "12345" },
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(live:GetControl(nodeId, "soundId"), 12345)
end

function TestPackAlerts:testANumberVariableIgnoresAPackSoundRow()
    local registry = Registry.new()
    registry:RegisterNodeType("fixture.hold", {
        category = "action",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
    local graph = LibNodeGraph.NewGraph(registry)
    local nodeId = graph:AddNode("fixture.hold", { hold = 4 })
    local snapshot = {
        name = "Callout",
        graph = LibNodeGraph.Serialize(graph),
        variables = { { nodeId = nodeId, pinName = "hold" } },
    }
    local bucket = Store.Empty()
    local _, live, _, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, {
        { raw = "8", packRow = { pack = "Voice", authorId = "bell", soundId = 8 } },
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(live:GetControl(nodeId, "hold"), 8)
end

function TestPackAlerts:testACustomSoundVariableBakesThePackAudioRecord()
    local registry = Registry.new()
    require("src/nodes/actions/custom_sound").Register(registry)
    local record = { pack = "Voice", authorId = "bell" }
    local graph = LibNodeGraph.NewGraph(registry)
    local nodeId = graph:AddNode("action.custom_sound", { resource = record })
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
        alertPresets = { {
            authorId = "greet",
            name = "Callout",
            graph = LibNodeGraph.Serialize(graph),
            variables = { { nodeId = nodeId, pinName = "resource" } },
        } },
    })
    local snapshot = PackRows.AlertPresetGroups(self.packs)[1].presets[1]
    local bucket = Store.Empty()
    local _, live, _, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, { record })
    luaunit.assertNil(err)
    luaunit.assertEquals(live:GetControl(nodeId, "resource"), record)
    luaunit.assertNil(live:GetControl(nodeId, "resource").soundId)
    luaunit.assertEquals(#bucket.entries, 1)
end

function TestPackAlerts:testFailedBakeLeavesTheBucketAndTheOffer()
    local registry = noteRegistry()
    registry:RegisterNodeType("fixture.hold", {
        category = "action",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
    local graph = LibNodeGraph.NewGraph(registry)
    local nodeId = graph:AddNode("fixture.hold", { hold = 4 })
    self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            {
                authorId = "greet",
                name = "Callout",
                graph = LibNodeGraph.Serialize(graph),
                variables = { { nodeId = nodeId, pinName = "hold" } },
            },
        },
    })
    local snapshot = PackRows.AlertPresetGroups(self.packs)[1].presets[1]
    local bucket = Store.Empty()
    local existing = LibNodeGraph.NewGraph(registry)
    existing:AddNode("fixture.note")
    Store.InsertEntry(bucket, Store.NewAlertEntry(7, "existing", existing, {}, true))

    local entry, _, _, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, { "" })
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "Enter a number.")
    luaunit.assertEquals(#bucket.entries, 1)
    luaunit.assertEquals(bucket.entries[1].id, 7)
    luaunit.assertEquals(bucket.entries[1].name, "existing")
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").name, "Callout")
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").variables, {
        { nodeId = nodeId, pinName = "hold" },
    })
end

function TestPackAlerts:testFailedDeserializeLeavesTheBucketAndTheOffer()
    local registry = noteRegistry()
    self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            { authorId = "greet", name = "Callout", graph = { nodes = { {} } } },
        },
    })
    local snapshot = PackRows.AlertPresetGroups(self.packs)[1].presets[1]
    local bucket = Store.Empty()
    local existing = LibNodeGraph.NewGraph(registry)
    existing:AddNode("fixture.note")
    Store.InsertEntry(bucket, Store.NewAlertEntry(7, "existing", existing, {}, true))

    local entry, _, _, err = PresetCopy.InstantiateSnapshot(bucket, snapshot, registry)
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "Could not copy the preset graph.")
    luaunit.assertEquals(#bucket.entries, 1)
    luaunit.assertEquals(bucket.entries[1].id, 7)
    luaunit.assertEquals(bucket.entries[1].name, "existing")
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").graph, { nodes = { {} } })
end

-- The row captured at open still copies the old snapshot. The next listing sees
-- the replacement, and a preset left out of that registration is gone from the offer only.
function TestPackAlerts:testLaterRegistrationReplacesOnlyTheNextOffer()
    local registry = noteRegistry()
    local function graphWith(text)
        local graph = LibNodeGraph.NewGraph(registry)
        graph:AddNode("fixture.note", { text = text })
        return LibNodeGraph.Serialize(graph)
    end
    local token = self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            { authorId = "greet", name = "Greet", graph = graphWith("first") },
            { authorId = "bell", name = "Bell", graph = graphWith("bell") },
        },
    })
    local captured
    for _, preset in ipairs(PackRows.AlertPresetGroups(self.packs)[1].presets) do
        if preset.authorId == "greet" then captured = preset end
    end

    local bucket = Store.Empty()
    local entry, live = PresetCopy.InstantiateSnapshot(bucket, captured, registry)
    luaunit.assertEquals(entry.name, "Greet")
    luaunit.assertEquals(live:GetControl(1, "text"), "first")
    luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })

    self.packs:Clear(token)
    self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            { authorId = "greet", name = "Greet", graph = graphWith("second") },
        },
    })

    luaunit.assertEquals(entry.graph.nodes[1].controls.text, "first")
    luaunit.assertEquals(live:GetControl(1, "text"), "first")
    luaunit.assertNil(self.packs:GetAlertPreset("Voice", "bell"))

    local nextGroups = PackRows.AlertPresetGroups(self.packs)
    luaunit.assertEquals(#nextGroups, 1)
    luaunit.assertEquals(#nextGroups[1].presets, 1)
    luaunit.assertEquals(nextGroups[1].presets[1].authorId, "greet")
    luaunit.assertEquals(nextGroups[1].presets[1].graph.nodes[1].controls.text, "second")

    local again, againLive = PresetCopy.InstantiateSnapshot(bucket, captured, registry)
    luaunit.assertEquals(again.id, entry.id + 1)
    luaunit.assertEquals(againLive:GetControl(1, "text"), "first")
    luaunit.assertEquals(#bucket.entries, 2)
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").graph.nodes[1].controls.text, "second")
end
