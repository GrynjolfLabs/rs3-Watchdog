-- export.lua copy-paste envelope (#94 / #79 / #84 / #115): Encode strips Entry ids.
-- JSON that fits in 9,999 bytes is the paste. JSON over that cap is a WD1 token when
-- the token fits, and exports nothing when the token is still over the cap. Import
-- accepts both forms, rejects a forward schemaVersion, mints ids, and appends at the
-- doc root (never merge-by-name). Graph node ids inside an alert are left untouched.

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
local Export = require("src/export")
local Compress = require("src/compress")
local Registry = require("registry")

TestExport = {}

function TestExport:setUp()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
end

local function graphWithOneNode(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    graph:AddNode("fixture.trigger")
    return graph
end

local function seedAlert(doc, registry, name, enabled, parentId)
    local id = Store.MintId(doc)
    local layout = { [1] = { x = 10, y = 20 } }
    Store.InsertEntry(doc, Store.NewAlertEntry(id, name, graphWithOneNode(registry), layout, enabled), parentId)
    return id
end

--- Encode: envelope shape + id omission ---------------------------------------------------

function TestExport:testEncodeOmitsEntryIdsAndBuildsEnvelope()
    local doc = Store.Empty()
    seedAlert(doc, self.registry, "alpha", true)

    local ok, json = Export.Encode(doc.entries)
    luaunit.assertTrue(ok)
    luaunit.assertTrue(type(json) == "string")

    local envelope = LibNodeGraph.Json.Default.decode(json)
    luaunit.assertEquals(envelope.schemaVersion, Export.SCHEMA_VERSION)
    luaunit.assertEquals(envelope.pluginVersion, Export.PLUGIN_VERSION)
    luaunit.assertEquals(#envelope.entries, 1)
    luaunit.assertNil(envelope.entries[1].id)
    luaunit.assertEquals(envelope.entries[1].name, "alpha")
    luaunit.assertEquals(envelope.entries[1].kind, "alert")
    -- Graph node ids (and layout node ids) stay - only TreeEntry.id is stripped.
    luaunit.assertEquals(envelope.entries[1].layout[1].id, 1)
    luaunit.assertNotNil(envelope.entries[1].graph.nodes[1].id)
end

function TestExport:testEncodeGroupIncludesGroupAndChildrenWithoutIds()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "Slayer", true, {}))
    seedAlert(doc, self.registry, "task", true, groupId)

    local ok, json = Export.Encode(doc.entries)
    luaunit.assertTrue(ok)
    local envelope = LibNodeGraph.Json.Default.decode(json)
    luaunit.assertEquals(#envelope.entries, 1)
    local g = envelope.entries[1]
    luaunit.assertNil(g.id)
    luaunit.assertEquals(g.kind, "group")
    luaunit.assertEquals(g.name, "Slayer")
    luaunit.assertEquals(#g.children, 1)
    luaunit.assertNil(g.children[1].id)
    luaunit.assertEquals(g.children[1].name, "task")
end

-- Printable ASCII that is not `"` or `\`, so the JSON encoder copies it one byte
-- per character and deflate has nothing repeated to point at.
local function noise(n)
    local parts = {}
    local x = 123456789
    for i = 1, n do
        x = (1103515245 * x + 12345) % 2147483648
        local c = 33 + (x % 94)
        if c == 34 or c == 92 then c = 65 end
        parts[i] = string.char(c)
    end
    return table.concat(parts)
end

function TestExport:testEncodeCompressesRepeatedPayloadThatExceedsTheCap()
    local entries = {}
    local fat = string.rep("x", 600)
    for i = 1, 20 do
        entries[i] = {
            kind = "alert",
            name = fat .. tostring(i),
            enabled = true,
            graph = { version = 1, nodes = { { id = 1, type = "fixture.trigger", controls = {} } }, connections = {} },
            layout = { { id = 1, x = 0, y = 0 } },
        }
    end
    local json = LibNodeGraph.Json.Default.encode(Export.BuildEnvelope(entries))
    luaunit.assertTrue(#json > Export.MAX_BYTES)

    local ok, token = Export.Encode(entries)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(token:sub(1, 3), Compress.PREFIX)
    luaunit.assertTrue(#token <= Export.MAX_BYTES)

    local doc = Store.Empty()
    local importedOk, report = Export.Import(doc, "\n" .. token .. "\n")
    luaunit.assertTrue(importedOk)
    luaunit.assertEquals(report.entryCount, 20)
    luaunit.assertEquals(doc.entries[1].name, entries[1].name)
    luaunit.assertEquals(doc.entries[20].name, entries[20].name)
end

-- One ASCII name character is one UTF-8 byte, so pad length is target minus the empty envelope.
local function alertNamed(name)
    return {
        kind = "alert",
        name = name,
        enabled = true,
        graph = { version = 1, nodes = {}, connections = {} },
        layout = {},
    }
end

local function envelopeBytes(name)
    return #LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = Export.PLUGIN_VERSION,
        entries = { alertNamed(name) },
    })
end

local function nameForEnvelopeBytes(target)
    local pad = string.rep("a", target - envelopeBytes(""))
    luaunit.assertEquals(envelopeBytes(pad), target)
    return pad
end

function TestExport:testEncodeRefusesWhenCompressedTokenStillExceedsTheCap()
    local entries = { alertNamed(noise(12000)) }
    local json = LibNodeGraph.Json.Default.encode(Export.BuildEnvelope(entries))
    local token = Compress.compress(json)
    luaunit.assertTrue(#json > Export.MAX_BYTES)
    luaunit.assertTrue(#token > Export.MAX_BYTES)

    local ok, err = Export.Encode(entries)
    luaunit.assertFalse(ok)
    luaunit.assertStrContains(err, "Too large to export by copy-paste")
    luaunit.assertStrContains(err, "of 9,999 characters")
    luaunit.assertStrContains(err, "A file-based export is planned.")
    -- N is the shorter candidate. The token can be longer than the JSON.
    local n = tonumber(err:match("%((%d+) of 9,999"))
    luaunit.assertEquals(n, math.min(#json, #token))
end

function TestExport:testEncodeKeepsJsonAtTheCapAndCompressesOneByteOver()
    luaunit.assertEquals(Export.MAX_BYTES, 9999)

    local ok, json = Export.Encode({ alertNamed(nameForEnvelopeBytes(9999)) })
    luaunit.assertTrue(ok)
    luaunit.assertEquals(#json, 9999)
    luaunit.assertEquals(json:sub(1, 1), "{")

    local name = nameForEnvelopeBytes(10000)
    local compressedOk, token = Export.Encode({ alertNamed(name) })
    luaunit.assertTrue(compressedOk)
    luaunit.assertEquals(token:sub(1, 3), Compress.PREFIX)
    luaunit.assertTrue(#token <= Export.MAX_BYTES)

    local doc = Store.Empty()
    local importedOk = Export.Import(doc, token)
    luaunit.assertTrue(importedOk)
    luaunit.assertEquals(doc.entries[1].name, name)
end

function TestExport:testEncodeAcceptsExactlyMaxBytes()
    local pad = nameForEnvelopeBytes(Export.MAX_BYTES)
    local ok, json = Export.Encode({ alertNamed(pad) })
    luaunit.assertTrue(ok)
    luaunit.assertEquals(#json, Export.MAX_BYTES)
end

--- Decode / Import ------------------------------------------------------------------------

function TestExport:testDecodeRejectsNonJson()
    local ok, err = Export.Decode("not json {")
    luaunit.assertFalse(ok)
    luaunit.assertTrue(type(err) == "string" and #err > 0)
end

function TestExport:testDecodeRejectsBrokenCompressedToken()
    local ok, err = Export.Decode("WD1!!!!")
    luaunit.assertFalse(ok)
    luaunit.assertStrContains(err, "compressed export")
end

function TestExport:testImportAcceptsCompressedTokenSplitAcrossLines()
    local payload = LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = Export.PLUGIN_VERSION,
        entries = { alertNamed("alpha") },
    })
    local token = Compress.compress(payload)
    local lines = {}
    for i = 1, #token, 60 do
        lines[#lines + 1] = token:sub(i, i + 59)
    end
    local doc = Store.Empty()
    local ok, report = Export.Import(doc, table.concat(lines, "\n"))
    luaunit.assertTrue(ok)
    luaunit.assertEquals(report.entryCount, 1)
    luaunit.assertEquals(doc.entries[1].name, "alpha")
end

function TestExport:testDecodeRejectsWrongShape()
    local ok, err = Export.Decode('{"version":2,"entries":[]}')
    luaunit.assertFalse(ok)
    luaunit.assertTrue(type(err) == "string" and #err > 0)
end

function TestExport:testImportRejectsForwardSchemaVersionWithoutWriting()
    local doc = Store.Empty()
    seedAlert(doc, self.registry, "keep", true)
    local before = #doc.entries

    local payload = LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION + 1,
        pluginVersion = "9.9.9",
        entries = {
            { kind = "alert", name = "new", enabled = true,
              graph = { version = 1, nodes = {}, connections = {} }, layout = {} },
        },
    })
    local ok, err = Export.Import(doc, payload)
    luaunit.assertFalse(ok)
    luaunit.assertStrContains(err, "newer version")
    luaunit.assertEquals(#doc.entries, before)
end

function TestExport:testImportMintsIdsAppendsAtRootNeverMergesByName()
    local doc = Store.Empty()
    local existing = seedAlert(doc, self.registry, "Slayer", true)
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "Slayer", true, {}))

    local payload = LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = "0.0.0",
        entries = {
            {
                kind = "group",
                name = "Slayer",
                enabled = true,
                children = {
                    {
                        kind = "alert",
                        name = "task",
                        enabled = true,
                        graph = { version = 1, nodes = { { id = 7, type = "fixture.trigger", controls = {} } }, connections = {} },
                        layout = { { id = 7, x = 3, y = 4 } },
                    },
                },
            },
        },
    })
    local ok, report = Export.Import(doc, payload)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(report.entryCount, 1)
    luaunit.assertEquals(#doc.entries, 3)
    luaunit.assertEquals(doc.entries[1].id, existing)
    luaunit.assertEquals(doc.entries[2].id, groupId)
    local imported = doc.entries[3]
    luaunit.assertEquals(imported.kind, "group")
    luaunit.assertEquals(imported.name, "Slayer")
    luaunit.assertNotEquals(imported.id, groupId)
    luaunit.assertEquals(#imported.children, 1)
    local child = imported.children[1]
    luaunit.assertTrue(type(child.id) == "number")
    luaunit.assertNotEquals(child.id, imported.id)
    -- Graph / layout node ids preserved (7), not reminted.
    luaunit.assertEquals(child.graph.nodes[1].id, 7)
    luaunit.assertEquals(child.layout[1].id, 7)
end

function TestExport:testImportStripsTagsFromNamesAndNodeText()
    local doc = Store.Empty()
    local ok, json = Export.Encode({ {
        kind = "group",
        name = "<col=ff0000>Slayer",
        enabled = true,
        children = { {
            kind = "alert",
            name = "<col=00ff00>alpha",
            enabled = true,
            layout = {},
            graph = {
                version = 1,
                nodes = {
                    {
                        id = 1,
                        type = "fixture.trigger",
                        name = "<col=ff0000>Ping",
                        controls = {
                            message = "<col=ff0000>hi",
                            contains = { needle = "<shad=0>boss", mode = "substring" },
                        },
                    },
                },
                connections = {},
            },
        } },
    } })
    luaunit.assertTrue(ok)

    local importedOk = Export.Import(doc, json)
    luaunit.assertTrue(importedOk)
    local group = doc.entries[1]
    luaunit.assertEquals(group.name, "Slayer")
    local alert = group.children[1]
    luaunit.assertEquals(alert.name, "alpha")
    luaunit.assertEquals(alert.graph.nodes[1].name, "Ping")
    luaunit.assertEquals(alert.graph.nodes[1].controls.message, "hi")
    luaunit.assertEquals(alert.graph.nodes[1].controls.contains.needle, "boss")
    luaunit.assertEquals(alert.graph.nodes[1].controls.contains.mode, "substring")
end

function TestExport:testRoundTripExportImportPreservesAlertPayload()
    local doc = Store.Empty()
    local id = seedAlert(doc, self.registry, "alpha", false)
    local original = Store.FindById(doc, id)

    local ok, json = Export.Encode({ original })
    luaunit.assertTrue(ok)

    local dest = Store.Empty()
    -- Seed an unrelated entry so the reminted id is forced off the original's id.
    seedAlert(dest, self.registry, "other", true)
    local ok2, report = Export.Import(dest, json)
    luaunit.assertTrue(ok2)
    luaunit.assertEquals(report.entryCount, 1)
    luaunit.assertEquals(#dest.entries, 2)
    local landed = dest.entries[2]
    luaunit.assertNotEquals(landed.id, id)
    luaunit.assertEquals(landed.name, "alpha")
    luaunit.assertEquals(landed.enabled, false)
    luaunit.assertEquals(landed.graph.nodes[1].type, original.graph.nodes[1].type)
    luaunit.assertEquals(landed.layout[1].x, 10)
    luaunit.assertEquals(landed.layout[1].y, 20)
end

function TestExport:testImportReportsUnknownNodeTypesNonBlocking()
    local payload = LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = "0.1.0",
        entries = {
            {
                kind = "alert",
                name = "future",
                enabled = true,
                graph = {
                    version = 1,
                    nodes = {
                        { id = 1, type = "fixture.trigger", controls = {} },
                        { id = 2, type = "future.WeirdThing", controls = { n = 1 } },
                    },
                    connections = {},
                },
                layout = {},
            },
        },
    })
    local doc = Store.Empty()
    local ok, report = Export.Import(doc, payload, { registry = self.registry })
    luaunit.assertTrue(ok)
    luaunit.assertEquals(report.entryCount, 1)
    luaunit.assertTrue(report.unknownCount >= 1)
    luaunit.assertTrue(type(report.message) == "string")
    luaunit.assertStrContains(report.message, "WeirdThing")
    luaunit.assertEquals(#doc.entries, 1)
    -- Placeholder lands in the live graph the same way bucket load does (#53 / #79).
    local restored = Store.RestoreAll(doc, self.registry)
    luaunit.assertEquals(#restored, 1)
    local unknown = 0
    for _, node in pairs(restored[1].graph.nodes) do
        if node.typeKey == LibNodeGraph.UNKNOWN_TYPE then
            unknown = unknown + 1
            luaunit.assertEquals(node.unknown.type, "future.WeirdThing")
        end
    end
    luaunit.assertEquals(unknown, 1)
end

local function singleNodePaste(typeKey)
    return LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = "0.1.0",
        entries = {
            {
                kind = "alert",
                name = "line",
                enabled = true,
                graph = {
                    version = 1,
                    nodes = { { id = 1, type = typeKey, controls = {} } },
                    connections = {},
                },
                layout = {},
            },
        },
    })
end

function TestExport:testImportReportsAGameMessageTriggerAsAChatNode()
    local doc = Store.Empty()
    local ok, report = Export.Import(doc, singleNodePaste("trigger.game_message"))
    luaunit.assertTrue(ok)
    luaunit.assertEquals(report.hasChatNode, true)
end

function TestExport:testImportReportsPlayerChatAndGameMessageActionAsChatNodes()
    for _, typeKey in ipairs({ "trigger.player_chat", "action.game_message" }) do
        local doc = Store.Empty()
        local ok, report = Export.Import(doc, singleNodePaste(typeKey))
        luaunit.assertTrue(ok)
        luaunit.assertEquals(report.hasChatNode, true)
    end
end

function TestExport:testImportReportsAChatNodeInsideADisabledGroup()
    local payload = LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = "0.1.0",
        entries = {
            {
                kind = "group",
                name = "Quiet",
                enabled = false,
                children = {
                    {
                        kind = "alert",
                        name = "asleep",
                        enabled = false,
                        graph = {
                            version = 1,
                            nodes = { { id = 1, type = "trigger.player_chat", controls = {} } },
                            connections = {},
                        },
                        layout = {},
                    },
                },
            },
        },
    })
    local doc = Store.Empty()
    local ok, report = Export.Import(doc, payload)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(report.hasChatNode, true)
    luaunit.assertEquals(doc.entries[1].enabled, false)
    luaunit.assertEquals(doc.entries[1].children[1].enabled, false)
end

function TestExport:testImportIgnoresChatNodesAlreadyInTheScope()
    local doc = Store.Empty()
    local existing = Store.MintId(doc)
    Store.InsertEntry(doc, {
        id = existing,
        kind = "alert",
        name = "already",
        enabled = true,
        graph = {
            version = 1,
            nodes = { { id = 1, type = "action.game_message", controls = {} } },
            connections = {},
        },
        layout = {},
    }, nil)
    local ok, report = Export.Import(doc, singleNodePaste("fixture.trigger"))
    luaunit.assertTrue(ok)
    luaunit.assertEquals(report.hasChatNode, false)
    luaunit.assertEquals(#doc.entries, 2)
end

function TestExport:testImportRejectsBadEntryBeforeAnyWrite()
    local doc = Store.Empty()
    seedAlert(doc, self.registry, "keep", true)
    local before = #doc.entries
    local payload = LibNodeGraph.Json.Default.encode({
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = "0.1.0",
        entries = {
            { kind = "alert", name = "ok", enabled = true,
              graph = { version = 1, nodes = {}, connections = {} }, layout = {} },
            { kind = "not-a-kind", name = "bad", enabled = true },
        },
    })
    local ok, err = Export.Import(doc, payload)
    luaunit.assertFalse(ok)
    luaunit.assertTrue(type(err) == "string")
    luaunit.assertEquals(#doc.entries, before)
end
