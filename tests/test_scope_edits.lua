-- Scope edits: Alert Manager mutations and the Editor's Bucket writes.
-- The seam is the saved Bucket and the runtime alert list. No Dialog is mounted.
-- The Alert Manager keeps stubbing these operations in test_manager.lua.

local luaunit = require("luaunit")

local Serialize = require("serialize")
local Json = require("json")
local Store = require("src/store")
local Registry = require("registry")
local Presets = require("src/presets")
local ScopeEdits = require("src/scope_edits")

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

-- Records the alert list the way the runtime does. Visual releases stay separate
-- from enabled so a group disable can drop visuals without flipping child alerts.
local function newRuntime()
    local rt = { alerts = {}, released = {} }
    function rt:AddAlert(id, name, graph, enabled, bucketKey)
        local alert = {
            id = id,
            name = name,
            graph = graph,
            enabled = enabled ~= false,
            bucketKey = bucketKey or "global",
        }
        self.alerts[#self.alerts + 1] = alert
        return alert
    end
    function rt:RemoveAlert(id, bucketKey)
        for i, alert in ipairs(self.alerts) do
            if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
                table.remove(self.alerts, i)
                return true
            end
        end
        return false
    end
    function rt:SetAlertEnabled(id, enabled, bucketKey)
        for _, alert in ipairs(self.alerts) do
            if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
                alert.enabled = enabled and true or false
                return true
            end
        end
        return false
    end
    function rt:ReleaseAlertVisuals(id, bucketKey)
        for _, alert in ipairs(self.alerts) do
            if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
                self.released[#self.released + 1] = id
                return true
            end
        end
        return false
    end
    function rt:RenameAlert(id, name, bucketKey)
        for _, alert in ipairs(self.alerts) do
            if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
                alert.name = name
                return true
            end
        end
        return false
    end
    return rt
end

TestScopeEdits = {}

function TestScopeEdits:setUp()
    self.savedPersistentDB = PersistentDB
    self.savedLibNodeGraph = LibNodeGraph
    LibNodeGraph = {
        NewGraph = require("graph").new,
        NewRegistry = require("registry").new,
        Serialize = Serialize.Serialize,
        Deserialize = Serialize.Deserialize,
        Json = Json,
        UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
    }
    PersistentDB = newFakePersistentDB()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    self.store = Store
    self.doc = Store.Empty()
    self.list = {}
    self.scopes = { global = { doc = self.doc, key = "global", list = self.list } }
    self.runtime = newRuntime()
    self.edits = ScopeEdits.new({
        store = Store,
        runtime = self.runtime,
        registry = self.registry,
        bucket = function(scopeKey)
            local scope = self.scopes[scopeKey]
            if scope == nil then return nil end
            return scope.doc, scope.key, scope.list
        end,
    })
end

function TestScopeEdits:tearDown()
    PersistentDB = self.savedPersistentDB
    LibNodeGraph = self.savedLibNodeGraph
end

function TestScopeEdits:seedAlert(name, enabled)
    local id = Store.MintId(self.doc)
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local layout = {}
    Store.InsertEntry(self.doc, Store.NewAlertEntry(id, name, graph, layout, enabled))
    self.list[#self.list + 1] = {
        id = id, name = name, graph = graph, layout = layout, enabled = enabled ~= false,
    }
    self.runtime:AddAlert(id, name, graph, enabled ~= false, "global")
    return id, graph
end

function TestScopeEdits:testToggleEnabledChangesTheScopeThatOwnsTheSharedId()
    local globalId = self:seedAlert("Global", true)
    local playerDoc = Store.Empty()
    local playerList = {}
    self.scopes["player_tid"] = { doc = playerDoc, key = "player_tid", list = playerList }
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    Store.InsertEntry(playerDoc, Store.NewAlertEntry(globalId, "Character", graph, {}, true))
    playerList[1] = { id = globalId, name = "Character", graph = graph, layout = {}, enabled = true }
    self.runtime:AddAlert(globalId, "Character", graph, true, "player_tid")

    self.edits:ToggleEnabled("player_tid", globalId)

    luaunit.assertEquals(Store.FindById(self.doc, globalId).enabled, true)
    luaunit.assertEquals(Store.FindById(playerDoc, globalId).enabled, false)
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    luaunit.assertEquals(self.runtime.alerts[2].enabled, false)
    luaunit.assertEquals(Store.LoadKey("player_tid").entries[1].enabled, false)
end

function TestScopeEdits:testToggleEnabledKeepsTheFlagWhenTheBucketSaveFails()
    local id = self:seedAlert("Gate", true)
    luaunit.assertTrue(Store.Save(self.doc))
    local lines = {}
    log = function(message) lines[#lines + 1] = message end
    function PersistentDB:SetString() error("rejected") end

    self.edits:ToggleEnabled("global", id)
    log = nil

    luaunit.assertEquals(Store.FindById(self.doc, id).enabled, false)
    luaunit.assertEquals(self.runtime.alerts[1].enabled, false)
    luaunit.assertEquals(self.list[1].enabled, false)
    luaunit.assertTrue(Store.LoadKey("global").entries[1].enabled)
    luaunit.assertEquals(#lines, 1)
    luaunit.assertStrContains(lines[1], "failed to save")
end

function TestScopeEdits:testToggleEnabledSavesTheBucketAndDisablesTheRuntimeAlert()
    local id = self:seedAlert("Gate", true)

    local result = self.edits:ToggleEnabled("global", id)

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(Store.FindById(self.doc, id).enabled, false)
    luaunit.assertEquals(self.list[1].enabled, false)
    luaunit.assertEquals(self.runtime.alerts[1].enabled, false)
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].id, id)
    luaunit.assertEquals(loaded.entries[1].enabled, false)
end

function TestScopeEdits:testGroupDisableKeepsTheNewFlagWhenTheSaveFails()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local child = Store.NewAlertEntry(1, "Inside", graph, {}, true)
    Store.InsertEntry(self.doc, Store.NewGroupEntry(2, "Folder", true, { child }))
    self.list[1] = { id = 1, name = "Inside", graph = graph, layout = {}, enabled = true }
    self.runtime:AddAlert(1, "Inside", graph, true, "global")
    luaunit.assertTrue(Store.Save(self.doc))
    function PersistentDB:SetString() error("rejected") end

    self.edits:ToggleEnabled("global", 2)

    luaunit.assertEquals(Store.FindById(self.doc, 2).enabled, false)
    luaunit.assertEquals(Store.FindById(self.doc, 1).enabled, true)
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    luaunit.assertEquals(self.runtime.released, { 1 })
    local loaded = Store.LoadKey("global")
    luaunit.assertTrue(loaded.entries[1].enabled)
    luaunit.assertTrue(loaded.entries[1].children[1].enabled)
end

function TestScopeEdits:testDisablingAGroupReleasesChildVisualsWithoutDisablingTheChild()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local child = Store.NewAlertEntry(1, "Inside", graph, {}, true)
    Store.InsertEntry(self.doc, Store.NewGroupEntry(2, "Folder", true, { child }))
    self.list[1] = { id = 1, name = "Inside", graph = graph, layout = {}, enabled = true }
    self.runtime:AddAlert(1, "Inside", graph, true, "global")

    local result = self.edits:ToggleEnabled("global", 2)

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(Store.FindById(self.doc, 2).enabled, false)
    luaunit.assertEquals(Store.FindById(self.doc, 1).enabled, true)
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    luaunit.assertEquals(self.list[1].enabled, true)
    luaunit.assertEquals(self.runtime.released, { 1 })
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].enabled, false)
    luaunit.assertEquals(loaded.entries[1].children[1].enabled, true)
end

function TestScopeEdits:testRenameStripsClientTextTagsBeforeSaving()
    local id = self:seedAlert("Gate", true)
    local open = { alertId = id, scopeKey = "global" }

    local result, ok = self.edits:Rename("global", id, "<col=ff0000>Gatehouse</col>", open)

    luaunit.assertEquals(ok, true)
    luaunit.assertEquals(result.kind, "rename")
    luaunit.assertEquals(result.name, "Gatehouse")
    luaunit.assertEquals(Store.FindById(self.doc, id).name, "Gatehouse")
    luaunit.assertEquals(self.list[1].name, "Gatehouse")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Gatehouse")
    luaunit.assertEquals(Store.LoadKey("global").entries[1].name, "Gatehouse")
end

function TestScopeEdits:testRenameOfOnlyATagKeepsTheOldName()
    local id = self:seedAlert("Gate", true)

    local result, ok = self.edits:Rename("global", id, "<col=ff0000>", nil)

    luaunit.assertEquals(ok, false)
    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(Store.FindById(self.doc, id).name, "Gate")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Gate")
end

function TestScopeEdits:testRenameSavesTheBucketAndRenamesTheRuntimeAlert()
    local id = self:seedAlert("Gate", true)

    local result, ok = self.edits:Rename("global", id, "Gatehouse", nil)

    luaunit.assertEquals(ok, true)
    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(Store.FindById(self.doc, id).name, "Gatehouse")
    luaunit.assertEquals(self.list[1].name, "Gatehouse")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Gatehouse")
    luaunit.assertEquals(Store.LoadKey("global").entries[1].name, "Gatehouse")
end

function TestScopeEdits:testRenameOfTheOpenAlertReturnsTheNewName()
    local id = self:seedAlert("Gate", true)
    local open = { alertId = id, scopeKey = "global" }

    local result, ok = self.edits:Rename("global", id, "Gatehouse", open)

    luaunit.assertEquals(ok, true)
    luaunit.assertEquals(result.kind, "rename")
    luaunit.assertEquals(result.name, "Gatehouse")
    luaunit.assertEquals(Store.FindById(self.doc, id).name, "Gatehouse")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Gatehouse")
end

function TestScopeEdits:testRenameKeepsTheOldNameWhenTheSaveFails()
    local id = self:seedAlert("Gate", true)
    PersistentDB.SetString = function() error("disk full") end

    local result, ok = self.edits:Rename("global", id, "Gatehouse", { alertId = id, scopeKey = "global" })

    luaunit.assertEquals(ok, false)
    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(Store.FindById(self.doc, id).name, "Gate")
    luaunit.assertEquals(self.list[1].name, "Gate")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Gate")
end

function TestScopeEdits:testDeleteRemovesTheAlertFromTheBucketAndTheRuntime()
    local kept = self:seedAlert("Kept", true)
    local id = self:seedAlert("Gate", true)

    local result = self.edits:Delete("global", id, { alertId = kept, scopeKey = "global" })

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertNil(Store.FindById(self.doc, id))
    luaunit.assertNotNil(Store.FindById(self.doc, kept))
    luaunit.assertEquals(#self.runtime.alerts, 1)
    luaunit.assertEquals(self.runtime.alerts[1].id, kept)
    luaunit.assertEquals(#self.list, 1)
    luaunit.assertEquals(self.list[1].id, kept)
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(#loaded.entries, 1)
    luaunit.assertEquals(loaded.entries[1].id, kept)
end

function TestScopeEdits:testDeleteClosesTheEditorWhenTheOpenAlertIsInside()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local child = Store.NewAlertEntry(1, "Inside", graph, {}, true)
    Store.InsertEntry(self.doc, Store.NewGroupEntry(2, "Folder", true, { child }))
    self.list[1] = { id = 1, name = "Inside", graph = graph, layout = {}, enabled = true }
    self.runtime:AddAlert(1, "Inside", graph, true, "global")

    local result = self.edits:Delete("global", 2, { alertId = 1, scopeKey = "global" })

    luaunit.assertEquals(result.kind, "close")
    luaunit.assertNil(Store.FindById(self.doc, 1))
    luaunit.assertNil(Store.FindById(self.doc, 2))
    luaunit.assertEquals(self.runtime.alerts, {})
    luaunit.assertEquals(self.runtime.released, { 1 })
    luaunit.assertEquals(self.list, {})
    luaunit.assertEquals(Store.LoadKey("global").entries, {})
end

function TestScopeEdits:testCreateFromScratchSavesANewAlertAndOpensIt()
    local result, id = self.edits:CreateFromScratch("global")

    luaunit.assertEquals(id, 1)
    luaunit.assertEquals(result.kind, "open")
    luaunit.assertEquals(result.scopeKey, "global")
    luaunit.assertEquals(result.alertId, 1)
    local entry = Store.FindById(self.doc, 1)
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.name, "New Alert")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(self.list[1].name, "New Alert")
    luaunit.assertEquals(self.list[1].graph, self.runtime.alerts[1].graph)
    luaunit.assertEquals(self.runtime.alerts[1].name, "New Alert")
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    luaunit.assertEquals(self.runtime.alerts[1].bucketKey, "global")
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].name, "New Alert")
    luaunit.assertEquals(loaded.entries[1].kind, "alert")
    luaunit.assertEquals(loaded.entries[1].enabled, true)
end

function TestScopeEdits:testAutosaveWritesTheOpenGraphAndLayout()
    local id, graph = self:seedAlert("Gate", true)
    self.edits:NoteSaved("global")
    local nodeId = graph:AddNode("fixture.trigger")
    local layout = { [nodeId] = { x = 12, y = 34 } }

    local result = self.edits:Autosave("global", id, graph, layout)

    luaunit.assertEquals(result.kind, "leave")
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(#loaded.entries[1].layout, 1)
    luaunit.assertEquals(loaded.entries[1].layout[1].id, nodeId)
    luaunit.assertEquals(loaded.entries[1].layout[1].x, 12)
    luaunit.assertEquals(loaded.entries[1].layout[1].y, 34)
    local restored = Store.RestoreAll(loaded, self.registry)
    luaunit.assertEquals(#restored[1].graph:GetNodes(), 2)
end

-- A save while the node is still on 1.5, -0.5 writes 2, -1 and leaves the live point there.
function TestScopeEdits:testAutosaveDuringADragWritesIntegersWithoutMovingTheNode()
    local id, graph = self:seedAlert("Gate", true)
    self.edits:NoteSaved("global")
    local nodeId = graph:AddNode("fixture.trigger")
    local layout = { [nodeId] = { x = 1.5, y = -0.5 } }

    self.edits:Autosave("global", id, graph, layout)

    luaunit.assertEquals(layout[nodeId].x, 1.5)
    luaunit.assertEquals(layout[nodeId].y, -0.5)
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].layout[1].x, 2)
    luaunit.assertEquals(loaded.entries[1].layout[1].y, -1)
    local restored = Store.RestoreAll(loaded, self.registry)
    luaunit.assertEquals(restored[1].layout[nodeId].x, 2)
    luaunit.assertEquals(restored[1].layout[nodeId].y, -1)
end

-- Opening a saved 1.5, -1.5 leaves that point. The next save writes 2, -2 and does not snap it.
function TestScopeEdits:testFractionalAlertLayoutStaysUntilTheAlertIsSavedAgain()
    local id, graph = self:seedAlert("Gate", true)
    local nodeId = graph:GetNodes()[1].id
    local entry = Store.FindById(self.doc, id)
    entry.layout = { { id = nodeId, x = 1.5, y = -1.5 } }
    luaunit.assertTrue(Store.SaveTo("global", self.doc))

    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].layout[1].x, 1.5)
    luaunit.assertEquals(loaded.entries[1].layout[1].y, -1.5)
    local restored = Store.RestoreAll(loaded, self.registry)
    local layout = restored[1].layout
    local live = layout[nodeId]
    luaunit.assertEquals(live.x, 1.5)
    luaunit.assertEquals(live.y, -1.5)
    luaunit.assertEquals(Store.LoadKey("global").entries[1].layout[1].x, 1.5)
    luaunit.assertEquals(Store.LoadKey("global").entries[1].layout[1].y, -1.5)

    self.edits:NoteSaved("global")
    self.edits:Autosave("global", id, restored[1].graph, layout)

    luaunit.assertEquals(live.x, 1.5)
    luaunit.assertEquals(live.y, -1.5)
    local saved = Store.LoadKey("global")
    luaunit.assertEquals(saved.entries[1].layout[1].x, 2)
    luaunit.assertEquals(saved.entries[1].layout[1].y, -2)
end

function TestScopeEdits:testAutosaveLeavesACleanGraphAndLayoutUnsaved()
    local id, graph = self:seedAlert("Gate", true)
    self.edits:NoteSaved("global")
    local writes = 0
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        if key == "global" then writes = writes + 1 end
        return inner(self, key, value)
    end

    local result = self.edits:Autosave("global", id, graph, self.list[1].layout)

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(writes, 0)
    luaunit.assertNil(Store.LoadKey("global").entries[1])
end

function TestScopeEdits:testFailedReorderLeavesThePreviousBytesAndAsksToTellThePlayer()
    local first = self:seedAlert("First", true)
    local second = self:seedAlert("Second", true)
    luaunit.assertTrue(Store.Save(self.doc))
    local previous = PersistentDB:GetString("global")
    local asked = 0
    self.edits.onSaveFailed = function() asked = asked + 1 end
    function PersistentDB:SetString()
        return false
    end

    self.edits:ReorderSibling("global", second, -1)

    luaunit.assertEquals(asked, 1)
    luaunit.assertEquals(PersistentDB:GetString("global"), previous)
    luaunit.assertEquals(self.doc.entries[1].id, second)
    luaunit.assertEquals(self.doc.entries[2].id, first)
end

function TestScopeEdits:testFailedEnableKeepsTheFlagAndDoesNotAskToTellThePlayer()
    local id = self:seedAlert("Gate", true)
    luaunit.assertTrue(Store.Save(self.doc))
    local lines = {}
    log = function(message) lines[#lines + 1] = message end
    local asked = 0
    self.edits.onSaveFailed = function() asked = asked + 1 end
    function PersistentDB:SetString()
        return false
    end

    self.edits:ToggleEnabled("global", id)
    log = nil

    luaunit.assertEquals(asked, 0)
    luaunit.assertEquals(Store.FindById(self.doc, id).enabled, false)
    luaunit.assertEquals(self.runtime.alerts[1].enabled, false)
    luaunit.assertTrue(Store.LoadKey("global").entries[1].enabled)
    luaunit.assertEquals(#lines, 1)
    luaunit.assertStrContains(lines[1], "failed to save")
    luaunit.assertNil(lines[1]:find("size", 1, true))
    luaunit.assertNil(lines[1]:find("too big", 1, true))
end

function TestScopeEdits:testReorderSiblingSavesTheNewOrder()
    local first = self:seedAlert("First", true)
    local second = self:seedAlert("Second", true)

    local result = self.edits:ReorderSibling("global", second, -1)

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(self.doc.entries[1].id, second)
    luaunit.assertEquals(self.doc.entries[2].id, first)
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].id, second)
    luaunit.assertEquals(loaded.entries[2].id, first)
end

function TestScopeEdits:testLiftSavesTheEntryAboveItsFormerParent()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local child = Store.NewAlertEntry(1, "Inside", graph, {}, true)
    Store.InsertEntry(self.doc, Store.NewGroupEntry(2, "Folder", true, { child }))

    local result = self.edits:Lift("global", 1)

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(self.doc.entries[1].id, 1)
    luaunit.assertEquals(self.doc.entries[1].kind, "alert")
    luaunit.assertEquals(self.doc.entries[2].id, 2)
    luaunit.assertEquals(self.doc.entries[2].children, {})
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].id, 1)
    luaunit.assertEquals(loaded.entries[2].id, 2)
    luaunit.assertEquals(loaded.entries[2].children, {})
end

function TestScopeEdits:testCreateGroupSavesANewGroup()
    local result, id = self.edits:CreateGroup("global")

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(id, 1)
    luaunit.assertEquals(self.doc.entries[1].kind, "group")
    luaunit.assertEquals(self.doc.entries[1].name, "New Group")
    luaunit.assertEquals(self.doc.entries[1].enabled, true)
    luaunit.assertEquals(self.doc.entries[1].children, {})
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].id, 1)
    luaunit.assertEquals(loaded.entries[1].name, "New Group")
    luaunit.assertEquals(loaded.entries[1].kind, "group")
end

function TestScopeEdits:testBulkDeleteClosesTheEditorWhenTheOpenAlertIsInside()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local keptGraph = LibNodeGraph.NewGraph(self.registry)
    Store.InsertEntry(self.doc, Store.NewGroupEntry(2, "Folder", true, {
        Store.NewAlertEntry(1, "Inside", graph, {}, true),
    }))
    Store.InsertEntry(self.doc, Store.NewAlertEntry(3, "Kept", keptGraph, {}, true))
    self.list[1] = { id = 1, name = "Inside", graph = graph, layout = {}, enabled = true }
    self.list[2] = { id = 3, name = "Kept", graph = keptGraph, layout = {}, enabled = true }
    self.runtime:AddAlert(1, "Inside", graph, true, "global")
    self.runtime:AddAlert(3, "Kept", keptGraph, true, "global")

    local result = self.edits:BulkDelete("global", { 2 }, { alertId = 1, scopeKey = "global" })

    luaunit.assertEquals(result.kind, "close")
    luaunit.assertNil(Store.FindById(self.doc, 1))
    luaunit.assertNil(Store.FindById(self.doc, 2))
    luaunit.assertEquals(Store.FindById(self.doc, 3).name, "Kept")
    luaunit.assertEquals(self.runtime.alerts[1].id, 3)
    luaunit.assertEquals(#self.runtime.alerts, 1)
    luaunit.assertEquals(self.runtime.released, { 1 })
    luaunit.assertEquals(#self.list, 1)
    luaunit.assertEquals(self.list[1].id, 3)
    luaunit.assertEquals(Store.LoadKey("global").entries[1].id, 3)
end

function TestScopeEdits:testBulkNewGroupWrapsTheSelectedAlerts()
    local first = self:seedAlert("First", true)
    local second = self:seedAlert("Second", true)

    local result, id = self.edits:BulkNewGroup("global", { first, second })

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(id, 3)
    luaunit.assertEquals(#self.doc.entries, 1)
    luaunit.assertEquals(self.doc.entries[1].kind, "group")
    luaunit.assertEquals(self.doc.entries[1].name, "New Group")
    luaunit.assertEquals(self.doc.entries[1].children[1].id, first)
    luaunit.assertEquals(self.doc.entries[1].children[2].id, second)
    local loaded = Store.LoadKey("global")
    luaunit.assertEquals(loaded.entries[1].id, 3)
    luaunit.assertEquals(loaded.entries[1].children[1].id, first)
    luaunit.assertEquals(loaded.entries[1].children[2].id, second)
end

function TestScopeEdits:testBulkMoveSavesTheOpenLayoutOnTheDestinationAndCloses()
    local id, graph = self:seedAlert("Gate", true)
    local nodeId = graph:AddNode("fixture.trigger")
    local editorLayout = { [nodeId] = { x = 12, y = 34 } }
    local destDoc = Store.Empty()
    local destList = {}
    self.scopes.player_9 = { doc = destDoc, key = "player_9", list = destList }

    local result = self.edits:BulkMove("global", "player_9", { id }, {
        alertId = id,
        scopeKey = "global",
        graph = graph,
        layout = editorLayout,
    })

    luaunit.assertEquals(result.kind, "close")
    luaunit.assertEquals(self.list, {})
    luaunit.assertNil(Store.FindById(self.doc, id))
    local moved = Store.FindById(destDoc, id)
    luaunit.assertEquals(moved.name, "Gate")
    luaunit.assertEquals(moved.layout[1].id, nodeId)
    luaunit.assertEquals(moved.layout[1].x, 12)
    luaunit.assertEquals(moved.layout[1].y, 34)
    luaunit.assertEquals(destList[1].id, id)
    luaunit.assertEquals(destList[1].name, "Gate")
    luaunit.assertEquals(destList[1].graph, graph)
    luaunit.assertEquals(self.runtime.alerts[1].bucketKey, "player_9")
    luaunit.assertEquals(self.runtime.alerts[1].graph, graph)
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    local loadedDest = Store.LoadKey("player_9")
    luaunit.assertEquals(loadedDest.entries[1].name, "Gate")
    luaunit.assertEquals(loadedDest.entries[1].layout[1].x, 12)
    luaunit.assertEquals(loadedDest.entries[1].layout[1].y, 34)
    luaunit.assertEquals(Store.LoadKey("global").entries, {})
end

function TestScopeEdits:testImportArmsAnExportedAlert()
    local id = self:seedAlert("Gate", true)
    local exported, ok, text = self.edits:ExportEntries("global", { id })
    luaunit.assertEquals(exported.kind, "leave")
    luaunit.assertEquals(ok, true)

    self.doc.entries = {}
    self.list = {}
    self.scopes.global.list = self.list
    self.runtime.alerts = {}

    local result, imported, report = self.edits:ImportJson("global", text)

    luaunit.assertEquals(result.kind, "leave")
    luaunit.assertEquals(imported, true)
    luaunit.assertEquals(type(report), "table")
    luaunit.assertEquals(self.doc.entries[1].name, "Gate")
    luaunit.assertEquals(self.doc.entries[1].enabled, true)
    luaunit.assertEquals(self.list[1].name, "Gate")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Gate")
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    luaunit.assertEquals(self.runtime.alerts[1].bucketKey, "global")
    luaunit.assertEquals(Store.LoadKey("global").entries[1].name, "Gate")
    luaunit.assertNil(PersistentDB:GetString("transfer_last"))
end

function TestScopeEdits:testCreateFromPresetSavesTheAlertAndOpensIt()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset, addErr = Presets.Add("Siren", graph, {})
    luaunit.assertNotNil(preset, addErr)

    local result, id, err = self.edits:CreateFromPreset("global", preset.id, nil)

    luaunit.assertNil(err)
    luaunit.assertEquals(result.kind, "open")
    luaunit.assertEquals(result.scopeKey, "global")
    luaunit.assertEquals(result.alertId, id)
    luaunit.assertEquals(Store.FindById(self.doc, id).name, "Siren")
    luaunit.assertEquals(Store.FindById(self.doc, id).enabled, true)
    luaunit.assertEquals(self.list[1].name, "Siren")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Siren")
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    luaunit.assertEquals(self.runtime.alerts[1].bucketKey, "global")
    luaunit.assertEquals(Store.LoadKey("global").entries[1].name, "Siren")
end

function TestScopeEdits:testCreateFromAlertPresetSavesACopyAndOpensIt()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local snapshot = {
        name = "Pack Siren",
        graph = LibNodeGraph.Serialize(graph),
        layout = {},
        variables = {},
    }

    local result, id, err = self.edits:CreateFromAlertPreset("global", snapshot, nil)

    luaunit.assertNil(err)
    luaunit.assertEquals(result.kind, "open")
    luaunit.assertEquals(result.scopeKey, "global")
    luaunit.assertEquals(result.alertId, id)
    luaunit.assertEquals(Store.FindById(self.doc, id).name, "Pack Siren")
    luaunit.assertEquals(Store.FindById(self.doc, id).kind, "alert")
    luaunit.assertEquals(self.runtime.alerts[1].name, "Pack Siren")
    luaunit.assertEquals(self.runtime.alerts[1].enabled, true)
    luaunit.assertEquals(self.runtime.alerts[1].bucketKey, "global")
    luaunit.assertNil(self.runtime.alerts[1].authorId)
    luaunit.assertEquals(Store.LoadKey("global").entries[1].name, "Pack Siren")
end

function TestScopeEdits:testCreateOnASplitScopeReloadsTheNewAlert()
    local doc = Store.Empty()
    local id = Store.MintId(doc)
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    Store.InsertEntry(doc, Store.NewAlertEntry(id, "Horn", graph, {}, true))
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local loaded = Store.LoadScope("global")
    self.doc = loaded
    self.scopes.global.doc = loaded
    self.list = {}
    self.scopes.global.list = self.list

    local result, created = self.edits:CreateFromScratch("global")

    luaunit.assertEquals(result.kind, "open")
    luaunit.assertNotNil(created)
    local again = Store.LoadScope("global")
    luaunit.assertEquals(#again.entries, 2)
    luaunit.assertEquals(again.entries[1].name, "Horn")
    luaunit.assertEquals(again.entries[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(again.entries[2].name, "New Alert")
    luaunit.assertEquals(again.entries[2].graph.version, 1)
    luaunit.assertEquals(#again.entries[2].graph.nodes, 0)
end

function TestScopeEdits:testCreateDeleteImportMoveAndEnableAreRefusedWhenTheScopeCannotBeRead()
    PersistentDB:SetString("scope_global", "{nope")
    local loaded, _, problem = Store.LoadScope("global")
    luaunit.assertEquals(problem, "unreadable")
    self.doc = loaded
    self.scopes.global.doc = loaded
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    Store.InsertEntry(self.doc, Store.NewAlertEntry(1, "Horn", graph, {}, true))
    local source = Store.Empty()
    Store.InsertEntry(source, Store.NewAlertEntry(3, "Away", graph, {}, true))
    self.scopes.player_42 = { doc = source, key = "player_42", list = {} }

    self.edits:ToggleEnabled("global", 1)
    luaunit.assertEquals(Store.FindById(self.doc, 1).enabled, true)

    local deleted = self.edits:Delete("global", 1)
    luaunit.assertEquals(deleted.kind, "leave")
    luaunit.assertNotNil(Store.FindById(self.doc, 1))

    local _, exportOk, text = self.edits:ExportEntries("global", { 1 })
    luaunit.assertEquals(exportOk, true)
    local _, imported = self.edits:ImportJson("global", text)
    luaunit.assertFalse(imported)
    luaunit.assertEquals(#self.doc.entries, 1)

    local moved = self.edits:BulkMove("player_42", "global", { 3 })
    luaunit.assertEquals(moved.kind, "leave")
    luaunit.assertEquals(#source.entries, 1)
    luaunit.assertNil(Store.FindById(self.doc, 3))

    local createdResult, created = self.edits:CreateFromScratch("global")
    luaunit.assertEquals(createdResult.kind, "leave")
    luaunit.assertNil(created)
    luaunit.assertEquals(#self.doc.entries, 1)
end

return TestScopeEdits
