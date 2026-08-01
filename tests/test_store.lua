-- Exercises store.lua's `global` Bucket + Entry-tree model (#86): the tree helpers (mint id,
-- walk leaves, find/insert/delete by id — all id-keyed, name-agnostic), the id-keyed mutators
-- (SetEnabled, UpdateAlertGraph), RestoreAll over alert leaves, and the persistence round-trip
-- under the un-prefixed `global` key.
--
-- store.lua reaches its dependencies as globals — `LibNodeGraph` (Serialize/Deserialize/Json)
-- and `PersistentDB`. Neither exists under the bare interpreter, so this suite stands both up:
-- LibNodeGraph from the sibling lib's own modules (already on the path, see run.lua) and a tiny
-- in-memory fake PersistentDB standing in for the client key/value store.

local luaunit = require("luaunit")

-- Build the LibNodeGraph global store.lua expects from the sibling lib's modules (on the path
-- via run.lua). Mirrors what LibNodeGraph/main.lua publishes, minus what store.lua never uses.
local Serialize = require("serialize")
local Json = require("json")
LibNodeGraph = {
    NewGraph = require("graph").new,
    Serialize = Serialize.Serialize,
    Deserialize = Serialize.Deserialize,
    Json = Json,
    UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
}

local Store = require("store")
local Registry = require("registry")

-- A minimal in-memory stand-in for the client PersistentDB (string key/value store).
-- `failWriteKey` / `failDeleteKey` let a test force SetString/Delete to raise for one key,
-- standing in for the client refusing a write (migration-failure paths in #87).
local function newFakePersistentDB()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value)
        if self.failWriteKey == key then error("fake PersistentDB: write refused for " .. key) end
        self.data[key] = value
    end
    function db:Delete(key)
        if self.failDeleteKey == key then error("fake PersistentDB: delete refused for " .. key) end
        self.data[key] = nil
    end
    return db
end

TestStore = {}

function TestStore:setUp()
    self.registry = Registry.new()
    -- A trivial trigger type so a saved graph has a real, deserializable node in it.
    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    PersistentDB = newFakePersistentDB()
end

function TestStore:tearDown()
    PersistentDB = nil
end

local function graphWithOneNode(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    graph:AddNode("fixture.trigger")
    return graph
end

-- Mints an id, builds an alert Entry from a fresh one-node graph, and inserts it at `parentId`
-- (root when nil). Returns the minted id so a test can target the entry afterwards.
local function seedAlert(self, doc, name, enabled, parentId)
    local id = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewAlertEntry(id, name, graphWithOneNode(self.registry), {}, enabled), parentId)
    return id
end

-- Full round-trip helper: save a doc through the fake DB, then Load a fresh copy.
local function saveAndReload(doc)
    luaunit.assertTrue(Store.Save(doc))
    return Store.Load()
end

--- Bucket shape: version 2, un-prefixed `global` key --------------------------------------

function TestStore:testEmptyBucketIsVersion2WithNoEntries()
    local doc = Store.Empty()
    luaunit.assertEquals(doc.version, 2)
    luaunit.assertEquals(doc.entries, {})
    luaunit.assertNil(doc.infoboxAnchor)
end

function TestStore:testSaveWritesUnderUnprefixedGlobalKey()
    local doc = Store.Empty()
    seedAlert(self, doc, "alpha", true)
    Store.Save(doc)

    -- The key is plain `global` — no `watchdog_` prefix (PersistentDB is already plugin-scoped).
    luaunit.assertNotNil(PersistentDB.data["global"])
    luaunit.assertNil(PersistentDB.data["watchdog_graphs"])
end

function TestStore:testLoadOnFreshInstallIsEmptyBucket()
    -- No `global` key written yet: a fresh install loads an empty version-2 bucket.
    local doc = Store.Load()
    luaunit.assertEquals(doc.version, 2)
    luaunit.assertEquals(doc.entries, {})
end

function TestStore:testBucketRoundTripsVersionEntriesAndAnchor()
    local doc = Store.Empty()
    seedAlert(self, doc, "alpha", true)
    Store.SetInfoBoxAnchor(doc, 12, 34)

    local reloaded = saveAndReload(doc)

    luaunit.assertEquals(reloaded.version, 2)
    luaunit.assertEquals(#reloaded.entries, 1)
    luaunit.assertEquals(reloaded.entries[1].name, "alpha")
    local x, y = Store.GetInfoBoxAnchor(reloaded)
    luaunit.assertEquals({ x, y }, { 12, 34 })
end

--- Entry-tree helpers: MintId ------------------------------------------------------------

function TestStore:testMintIdStartsAtOneOnEmptyTree()
    luaunit.assertEquals(Store.MintId(Store.Empty()), 1)
end

function TestStore:testMintIdIsMaxPlusOneAcrossTheWholeTree()
    local doc = Store.Empty()
    -- Nest so the max id lives inside a group, proving mint walks the whole tree, not just root.
    local group = Store.NewGroupEntry(5, "g", true, {})
    Store.InsertEntry(doc, group)
    Store.InsertEntry(doc, Store.NewAlertEntry(9, "deep", graphWithOneNode(self.registry), {}, true), 5)
    Store.InsertEntry(doc, Store.NewAlertEntry(3, "shallow", graphWithOneNode(self.registry), {}, true))

    luaunit.assertEquals(Store.MintId(doc), 10)
end

function TestStore:testMintThenInsertYieldsUniqueIds()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    local b = seedAlert(self, doc, "b", true)
    luaunit.assertNotEquals(a, b)
end

--- Entry-tree helpers: Leaves (alert leaves, tree order) ----------------------------------

function TestStore:testLeavesReturnsOnlyAlertsInTreeOrder()
    local doc = Store.Empty()
    seedAlert(self, doc, "root-alert", true)
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    seedAlert(self, doc, "nested-alert", true, groupId)

    local leaves = Store.Leaves(doc)

    -- Pre-order: root alert, then the group's nested alert. The group itself is not a leaf.
    luaunit.assertEquals(#leaves, 2)
    luaunit.assertEquals(leaves[1].name, "root-alert")
    luaunit.assertEquals(leaves[2].name, "nested-alert")
end

--- Entry-tree helpers: FindById ----------------------------------------------------------

function TestStore:testFindByIdLocatesEntryWithSiblingsAndIndex()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    local b = seedAlert(self, doc, "b", true)

    local entry, siblings, index = Store.FindById(doc, b)
    luaunit.assertEquals(entry.name, "b")
    luaunit.assertEquals(siblings, doc.entries)
    luaunit.assertEquals(index, 2)
    luaunit.assertEquals(a, doc.entries[1].id) -- sanity: a is first
end

function TestStore:testFindByIdReachesNestedEntries()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    local nestedId = seedAlert(self, doc, "nested", true, groupId)

    local entry, siblings, index = Store.FindById(doc, nestedId)
    luaunit.assertEquals(entry.name, "nested")
    luaunit.assertEquals(index, 1)
    luaunit.assertEquals(siblings, doc.entries[1].children)
end

function TestStore:testFindByIdReturnsNilForUnknownId()
    luaunit.assertNil(Store.FindById(Store.Empty(), 999))
end

--- Entry-tree helpers: InsertEntry -------------------------------------------------------

function TestStore:testInsertAtRootAppends()
    local doc = Store.Empty()
    seedAlert(self, doc, "first", true)
    seedAlert(self, doc, "second", true)
    luaunit.assertEquals(doc.entries[1].name, "first")
    luaunit.assertEquals(doc.entries[2].name, "second")
end

function TestStore:testInsertIntoGroupNestsUnderIt()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))

    local childId = Store.MintId(doc)
    luaunit.assertTrue(Store.InsertEntry(doc,
        Store.NewAlertEntry(childId, "child", graphWithOneNode(self.registry), {}, true), groupId))
    luaunit.assertEquals(#doc.entries, 1)
    luaunit.assertEquals(doc.entries[1].children[1].name, "child")
end

function TestStore:testInsertIntoMissingParentFails()
    local doc = Store.Empty()
    local ok = Store.InsertEntry(doc, Store.NewAlertEntry(1, "x", graphWithOneNode(self.registry), {}, true), 999)
    luaunit.assertFalse(ok)
    luaunit.assertEquals(#doc.entries, 0)
end

function TestStore:testInsertIntoAlertFails()
    -- An alert leaf is not a container; inserting into one must be refused, not silently nest.
    local doc = Store.Empty()
    local alertId = seedAlert(self, doc, "leaf", true)
    local ok = Store.InsertEntry(doc, Store.NewAlertEntry(50, "x", graphWithOneNode(self.registry), {}, true), alertId)
    luaunit.assertFalse(ok)
end

--- Entry-tree helpers: DeleteById --------------------------------------------------------

function TestStore:testDeleteByIdRemovesRootEntry()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    seedAlert(self, doc, "b", true)

    local removed = Store.DeleteById(doc, a)
    luaunit.assertEquals(removed.name, "a")
    luaunit.assertEquals(#doc.entries, 1)
    luaunit.assertEquals(doc.entries[1].name, "b")
end

function TestStore:testDeleteByIdRemovesNestedEntry()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    local nestedId = seedAlert(self, doc, "nested", true, groupId)

    luaunit.assertNotNil(Store.DeleteById(doc, nestedId))
    luaunit.assertEquals(#doc.entries[1].children, 0)
end

function TestStore:testDeleteByIdTakesTheWholeSubtree()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    seedAlert(self, doc, "nested", true, groupId)

    -- Deleting the group removes its child alert with it — the leaf count drops to zero.
    Store.DeleteById(doc, groupId)
    luaunit.assertEquals(#doc.entries, 0)
    luaunit.assertEquals(#Store.Leaves(doc), 0)
end

function TestStore:testDeleteByIdReturnsNilForUnknownId()
    luaunit.assertNil(Store.DeleteById(Store.Empty(), 999))
end

--- Entry-tree helpers: MoveSubtree (reparent by id, #88) ----------------------------------

function TestStore:testMoveSubtreeReparentsRootAlertIntoGroup()
    local doc = Store.Empty()
    local alertId = seedAlert(self, doc, "alpha", true)
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))

    luaunit.assertTrue(Store.MoveSubtree(doc, alertId, groupId))

    -- The alert left the root and now lives under the group.
    luaunit.assertEquals(#doc.entries, 1)
    luaunit.assertEquals(doc.entries[1].id, groupId)
    luaunit.assertEquals(#doc.entries[1].children, 1)
    luaunit.assertEquals(doc.entries[1].children[1].id, alertId)
end

function TestStore:testMoveSubtreeReparentsNestedAlertToRoot()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    local alertId = seedAlert(self, doc, "nested", true, groupId)

    luaunit.assertTrue(Store.MoveSubtree(doc, alertId, nil))

    -- The alert is now a root sibling of the (now-empty) group.
    luaunit.assertEquals(#doc.entries[1].children, 0)
    luaunit.assertEquals(doc.entries[2].id, alertId)
end

function TestStore:testMoveSubtreeCarriesAWholeGroupSubtree()
    local doc = Store.Empty()
    -- outer group holds inner group, inner holds an alert; move the inner group under a new home.
    local outerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(outerId, "outer", true, {}))
    local innerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(innerId, "inner", true, {}), outerId)
    local alertId = seedAlert(self, doc, "deep", true, innerId)
    local homeId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(homeId, "home", true, {}))

    luaunit.assertTrue(Store.MoveSubtree(doc, innerId, homeId))

    -- outer is emptied; the inner group (with its alert) hangs under home intact.
    luaunit.assertEquals(#Store.FindById(doc, outerId).children, 0)
    local home = Store.FindById(doc, homeId)
    luaunit.assertEquals(home.children[1].id, innerId)
    luaunit.assertEquals(home.children[1].children[1].id, alertId)
end

function TestStore:testMoveSubtreeIntoOwnDescendantIsRefused()
    -- Moving a group under one of its own descendants would sever the tree — must be refused.
    local doc = Store.Empty()
    local outerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(outerId, "outer", true, {}))
    local innerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(innerId, "inner", true, {}), outerId)

    luaunit.assertFalse(Store.MoveSubtree(doc, outerId, innerId))
    -- Structure untouched: outer still holds inner at root.
    luaunit.assertEquals(doc.entries[1].id, outerId)
    luaunit.assertEquals(doc.entries[1].children[1].id, innerId)
end

function TestStore:testMoveSubtreeIntoItselfIsRefused()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    luaunit.assertFalse(Store.MoveSubtree(doc, groupId, groupId))
end

function TestStore:testMoveSubtreeIntoAlertIsRefused()
    -- An alert leaf is not a container; reparenting into one must fail, leaving the tree intact.
    local doc = Store.Empty()
    local aId = seedAlert(self, doc, "a", true)
    local bId = seedAlert(self, doc, "b", true)
    luaunit.assertFalse(Store.MoveSubtree(doc, aId, bId))
    luaunit.assertEquals(#doc.entries, 2)
end

function TestStore:testMoveSubtreeReturnsFalseForUnknownId()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    luaunit.assertFalse(Store.MoveSubtree(doc, 999, groupId))
end

function TestStore:testMoveSubtreeToMissingParentIsRefused()
    local doc = Store.Empty()
    local alertId = seedAlert(self, doc, "a", true)
    luaunit.assertFalse(Store.MoveSubtree(doc, alertId, 999))
    luaunit.assertEquals(#doc.entries, 1) -- still at root
end

--- Enabled-chain: an alert fires iff its own enabled AND every ancestor group's enabled (#88) --

function TestStore:testAncestorsEnabledTrueForRootEntry()
    -- A root-level entry has no ancestor groups, so nothing upstream can suppress it.
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "root", true)
    luaunit.assertTrue(Store.AncestorsEnabled(doc, id))
end

function TestStore:testAncestorsEnabledTrueWhenEveryAncestorGroupEnabled()
    local doc = Store.Empty()
    local outerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(outerId, "outer", true, {}))
    local innerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(innerId, "inner", true, {}), outerId)
    local alertId = seedAlert(self, doc, "deep", true, innerId)

    luaunit.assertTrue(Store.AncestorsEnabled(doc, alertId))
end

function TestStore:testAncestorsEnabledFalseWhenAnyAncestorGroupDisabled()
    local doc = Store.Empty()
    local outerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(outerId, "outer", false, {})) -- outer disabled
    local innerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(innerId, "inner", true, {}), outerId)
    local alertId = seedAlert(self, doc, "deep", true, innerId)

    -- The alert's own flag is on and inner is on, but the disabled outer breaks the chain.
    luaunit.assertFalse(Store.AncestorsEnabled(doc, alertId))
end

function TestStore:testEnabledChainCombinesOwnFlagWithAncestors()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    local onId = seedAlert(self, doc, "on", true, groupId)
    local offId = seedAlert(self, doc, "off", false, groupId)

    -- Both under an enabled group: the chain follows each alert's own flag.
    luaunit.assertTrue(Store.EnabledChain(doc, onId))
    luaunit.assertFalse(Store.EnabledChain(doc, offId))
end

function TestStore:testEnabledChainFalseWhenGroupDisabledEvenIfAlertEnabled()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", false, {}))
    local alertId = seedAlert(self, doc, "on", true, groupId)

    luaunit.assertFalse(Store.EnabledChain(doc, alertId))
end

function TestStore:testEnabledChainFalseForUnknownId()
    luaunit.assertFalse(Store.EnabledChain(Store.Empty(), 999))
end

function TestStore:testDisablingGroupLeavesDescendantOwnFlagsUntouched()
    -- The master switch suppresses via the chain; it must not overwrite descendants' own enabled,
    -- so re-enabling the group restores exactly the prior per-alert state.
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    local onId = seedAlert(self, doc, "on", true, groupId)
    local offId = seedAlert(self, doc, "off", false, groupId)

    Store.SetEnabled(doc, groupId, false)
    -- Suppressed while the group is off, but each alert keeps its own flag.
    luaunit.assertFalse(Store.EnabledChain(doc, onId))
    luaunit.assertEquals(Store.FindById(doc, onId).enabled, true)
    luaunit.assertEquals(Store.FindById(doc, offId).enabled, false)

    Store.SetEnabled(doc, groupId, true)
    -- Re-enabling restores exactly the prior mix: "on" fires again, "off" stays off.
    luaunit.assertTrue(Store.EnabledChain(doc, onId))
    luaunit.assertFalse(Store.EnabledChain(doc, offId))
end

function TestStore:testEnabledChainReEvaluatesAfterMove()
    -- Moving an alert out of a disabled group must restore it; moving it back in re-suppresses —
    -- the chain is resolved live over the tree, never cached at insert time.
    local doc = Store.Empty()
    local offGroup = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(offGroup, "off-group", false, {}))
    local alertId = seedAlert(self, doc, "a", true, offGroup)

    luaunit.assertFalse(Store.EnabledChain(doc, alertId)) -- suppressed inside the disabled group

    Store.MoveSubtree(doc, alertId, nil) -- out to root
    luaunit.assertTrue(Store.EnabledChain(doc, alertId))  -- restored

    Store.MoveSubtree(doc, alertId, offGroup) -- back into the disabled group
    luaunit.assertFalse(Store.EnabledChain(doc, alertId)) -- re-suppressed
end

--- Alert Entry construction: enabled default + shape -------------------------------------

function TestStore:testNewAlertEntryDefaultsEnabledTrue()
    local entry = Store.NewAlertEntry(1, "a", graphWithOneNode(self.registry), {})
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertNotNil(entry.graph)
end

function TestStore:testNewAlertEntryHonoursExplicitDisabled()
    local entry = Store.NewAlertEntry(1, "a", graphWithOneNode(self.registry), {}, false)
    luaunit.assertEquals(entry.enabled, false)
end

--- SetEnabled by id ----------------------------------------------------------------------

function TestStore:testSetEnabledFlipsById()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)

    luaunit.assertTrue(Store.SetEnabled(doc, id, false))
    luaunit.assertEquals(Store.FindById(doc, id).enabled, false)
end

function TestStore:testSetEnabledIsNameAgnosticAcrossDuplicateNames()
    -- Two alerts share a name; SetEnabled keys on id, so it touches only the targeted one.
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "dup", true)
    local b = seedAlert(self, doc, "dup", true)

    Store.SetEnabled(doc, a, false)
    luaunit.assertEquals(Store.FindById(doc, a).enabled, false)
    luaunit.assertEquals(Store.FindById(doc, b).enabled, true)
end

function TestStore:testSetEnabledReturnsFalseForUnknownId()
    luaunit.assertFalse(Store.SetEnabled(Store.Empty(), 999, true))
end

function TestStore:testSetEnabledPersistsThroughRoundTrip()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    Store.SetEnabled(doc, id, false)

    local reloaded = saveAndReload(doc)
    luaunit.assertEquals(Store.FindById(reloaded, id).enabled, false)
end

--- SetName by id (#91) -------------------------------------------------------------------

function TestStore:testSetNameRenamesById()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)

    luaunit.assertTrue(Store.SetName(doc, id, "beta"))
    luaunit.assertEquals(Store.FindById(doc, id).name, "beta")
end

function TestStore:testSetNameIsIdKeyedAcrossDuplicateNames()
    -- Two alerts share a name; SetName keys on id, so it touches only the targeted one.
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "dup", true)
    local b = seedAlert(self, doc, "dup", true)

    Store.SetName(doc, a, "renamed")
    luaunit.assertEquals(Store.FindById(doc, a).name, "renamed")
    luaunit.assertEquals(Store.FindById(doc, b).name, "dup")
end

function TestStore:testSetNameReturnsFalseForUnknownId()
    luaunit.assertFalse(Store.SetName(Store.Empty(), 999, "x"))
end

function TestStore:testSetNamePersistsThroughRoundTrip()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    Store.SetName(doc, id, "beta")

    local reloaded = saveAndReload(doc)
    luaunit.assertEquals(Store.FindById(reloaded, id).name, "beta")
end

--- UpdateAlertGraph by id (the editor autosave path) -------------------------------------

function TestStore:testUpdateAlertGraphRewritesGraphById()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)

    -- Rebuild with a two-node graph and push it back under the same id.
    local graph = graphWithOneNode(self.registry)
    graph:AddNode("fixture.trigger")
    luaunit.assertTrue(Store.UpdateAlertGraph(doc, id, graph, {}))

    local reloaded = saveAndReload(doc)
    local restored = Store.RestoreAll(reloaded, self.registry)
    luaunit.assertEquals(#restored[1].graph:GetNodes(), 2)
end

function TestStore:testUpdateAlertGraphPreservesEnabled()
    -- Autosave must not re-arm an alert the user disabled — it only touches graph + layout.
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", false)
    Store.UpdateAlertGraph(doc, id, graphWithOneNode(self.registry), {})
    luaunit.assertEquals(Store.FindById(doc, id).enabled, false)
end

function TestStore:testUpdateAlertGraphReturnsFalseForUnknownId()
    luaunit.assertFalse(Store.UpdateAlertGraph(Store.Empty(), 999, graphWithOneNode(self.registry), {}))
end

--- RestoreAll: every alert leaf comes back live, in tree order, with id + flag ------------

function TestStore:testRestoreAllReturnsEveryLeafLiveWithIdAndFlag()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "alpha", true)
    local b = seedAlert(self, doc, "beta", false)

    local reloaded = saveAndReload(doc)
    local restored = Store.RestoreAll(reloaded, self.registry)

    luaunit.assertEquals(#restored, 2)
    luaunit.assertEquals(restored[1].id, a)
    luaunit.assertEquals(restored[1].name, "alpha")
    luaunit.assertEquals(restored[1].enabled, true)
    luaunit.assertEquals(restored[2].id, b)
    luaunit.assertEquals(restored[2].name, "beta")
    luaunit.assertEquals(restored[2].enabled, false)
    -- Each entry carries a live, usable Graph (not the serialized table).
    luaunit.assertEquals(#restored[1].graph:GetNodes(), 1)
    luaunit.assertEquals(#restored[2].graph:GetNodes(), 1)
end

function TestStore:testRestoreAllWalksNestedAlertLeaves()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "group", true, {}))
    seedAlert(self, doc, "nested", true, groupId)

    local restored = Store.RestoreAll(doc, self.registry)
    luaunit.assertEquals(#restored, 1)
    luaunit.assertEquals(restored[1].name, "nested")
end

-- Older/hand-built entries may omit `enabled`; RestoreAll must treat a missing flag as enabled.
function TestStore:testMissingEnabledRestoresAsTrue()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    Store.FindById(doc, id).enabled = nil -- simulate an entry written without the flag

    local restored = Store.RestoreAll(doc, self.registry)
    luaunit.assertEquals(restored[1].enabled, true)
end

--- Unknown-node preservation (#53): an alert with an unregistered type loads as a ---------
--- placeholder rather than being skipped, and round-trips losslessly while the type is absent.

-- A stored bucket whose one alert references a type the reload registry won't have: a known
-- trigger (node 1) wired into an unknown `action.overlay` (node 2). Built as the on-disk shape
-- directly, since the point is that node 2's type is never registered.
local function bucketWithUnknownNode()
    return {
        version = 2,
        entries = { {
            id = 1,
            kind = "alert",
            name = "alpha",
            enabled = true,
            layout = {},
            graph = {
                version = 1,
                nodes = {
                    { id = 1, type = "fixture.trigger", controls = {} },
                    { id = 2, type = "action.overlay", controls = { text = "hi" } },
                },
                connections = {
                    { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
                },
            },
        } },
    }
end

function TestStore:testUnknownNodeLoadsAsPlaceholderNotSkipped()
    local restored = Store.RestoreAll(bucketWithUnknownNode(), self.registry)

    luaunit.assertEquals(#restored, 1)
    luaunit.assertEquals(restored[1].name, "alpha")
    local nodes = restored[1].graph:GetNodes()
    luaunit.assertEquals(#nodes, 2)
    local byId = {}
    for _, n in ipairs(nodes) do byId[n.id] = n.typeKey end
    luaunit.assertEquals(byId[1], "fixture.trigger")
    luaunit.assertEquals(byId[2], LibNodeGraph.UNKNOWN_TYPE)
    luaunit.assertEquals(#restored[1].graph:GetConnections(), 1)
end

function TestStore:testPlaceholderRoundTripsLosslesslyWhileTypeAbsent()
    local first = Store.RestoreAll(bucketWithUnknownNode(), self.registry)[1]

    -- Re-persist the restored (placeholder-bearing) graph exactly as the editor autosave loop
    -- would — the unknown node must re-emit its ORIGINAL type + controls verbatim.
    local doc = Store.Empty()
    Store.InsertEntry(doc, Store.NewAlertEntry(first.id, first.name, first.graph, first.layout, first.enabled))
    local reloaded = saveAndReload(doc)

    local entry = reloaded.entries[1]
    luaunit.assertEquals(entry.graph.nodes[2].type, "action.overlay")
    luaunit.assertEquals(entry.graph.nodes[2].controls.text, "hi")

    local second = Store.RestoreAll(reloaded, self.registry)
    luaunit.assertEquals(#second[1].graph:GetNodes(), 2)
    luaunit.assertEquals(#second[1].graph:GetConnections(), 1)
end

function TestStore:testKnownNodesStillFireAlongsideAPlaceholder()
    local restored = Store.RestoreAll(bucketWithUnknownNode(), self.registry)
    -- Firing the known trigger runs through the graph without the placeholder aborting it.
    luaunit.assertEquals(restored[1].graph:Fire(1), nil)
end

-- Once the missing type is registered again, the same saved bucket loads the REAL node with its
-- original controls + wiring — no placeholder remains.
function TestStore:testPlaceholderRestoresToRealNodeWhenTypeReturns()
    self.registry:RegisterNodeType("action.overlay", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "text", kind = "data", direction = "in", dataType = "string" },
        },
        run = function() end,
    })

    local restored = Store.RestoreAll(bucketWithUnknownNode(), self.registry)

    local nodes = restored[1].graph:GetNodes()
    luaunit.assertEquals(#nodes, 2)
    for _, n in ipairs(nodes) do
        luaunit.assertNotEquals(n.typeKey, LibNodeGraph.UNKNOWN_TYPE)
    end
    luaunit.assertEquals(restored[1].graph:GetControl(2, "text"), "hi")
    luaunit.assertEquals(#restored[1].graph:GetConnections(), 1)
end

--- InfoBox Area anchor (#41) --------------------------------------------------------------

function TestStore:testGetInfoBoxAnchorNilOnFreshBucket()
    local x, y = Store.GetInfoBoxAnchor(Store.Empty())
    luaunit.assertNil(x)
    luaunit.assertNil(y)
end

function TestStore:testSetInfoBoxAnchorRoundTrips()
    local doc = Store.Empty()
    Store.SetInfoBoxAnchor(doc, 12, 34)
    local x, y = Store.GetInfoBoxAnchor(doc)
    luaunit.assertEquals({ x, y }, { 12, 34 })
end

function TestStore:testInfoBoxAnchorSurvivesSaveAndLoad()
    local doc = Store.Empty()
    Store.SetInfoBoxAnchor(doc, 12, 34)

    local reloaded = saveAndReload(doc)
    local x, y = Store.GetInfoBoxAnchor(reloaded)
    luaunit.assertEquals({ x, y }, { 12, 34 })
end

--- One-shot legacy migration (#87) -------------------------------------------------------
-- The pre-Bucket flat document lived under `watchdog_graphs` as
--   { version, current = <name|nil>, graphs = { { name, graph, layout, enabled }, ... }, infoboxAnchor }
-- The migration carries it into the `global` bucket on the first load after upgrade, keyed on
-- the *absence* of `global` (never a version int). These tests drive the seam through the public
-- Store.Load, which returns `doc, migrationFailed`.

local LEGACY_KEY = "watchdog_graphs"

-- A serialized (on-disk) graph, exactly what the legacy document held per entry — the migration
-- carries this verbatim without ever calling Deserialize.
local function serializedGraph(registry)
    return LibNodeGraph.Serialize(graphWithOneNode(registry))
end

-- Writes an encoded legacy flat document straight into the fake DB's watchdog_graphs key.
local function seedLegacyDoc(legacy)
    PersistentDB.data[LEGACY_KEY] = LibNodeGraph.Json.Default.encode(legacy)
end

function TestStore:testLegacyMigratesFlatDocIntoGlobalOrderPreservedIdsMinted()
    seedLegacyDoc({
        version = 1,
        current = "beta", -- dropped by the migration (#80)
        infoboxAnchor = { x = 7, y = 8 },
        graphs = {
            { name = "alpha", graph = serializedGraph(self.registry), layout = {}, enabled = true },
            { name = "beta",  graph = serializedGraph(self.registry), enabled = false }, -- no layout
            { name = "gamma", graph = serializedGraph(self.registry) },                  -- no enabled ⇒ true
        },
    })

    local doc, migrationFailed = Store.Load()

    luaunit.assertNil(migrationFailed)
    luaunit.assertEquals(doc.version, 2)
    -- Order preserved, one root-level alert Entry per legacy entry.
    luaunit.assertEquals(#doc.entries, 3)
    luaunit.assertEquals(doc.entries[1].name, "alpha")
    luaunit.assertEquals(doc.entries[2].name, "beta")
    luaunit.assertEquals(doc.entries[3].name, "gamma")
    for _, e in ipairs(doc.entries) do luaunit.assertEquals(e.kind, "alert") end
    -- Ids minted, unique.
    luaunit.assertNotNil(doc.entries[1].id)
    luaunit.assertNotEquals(doc.entries[1].id, doc.entries[2].id)
    luaunit.assertNotEquals(doc.entries[2].id, doc.entries[3].id)
    -- enabled normalized: explicit true/false carried, missing ⇒ true.
    luaunit.assertEquals(doc.entries[1].enabled, true)
    luaunit.assertEquals(doc.entries[2].enabled, false)
    luaunit.assertEquals(doc.entries[3].enabled, true)
    -- infoboxAnchor carried across.
    local x, y = Store.GetInfoBoxAnchor(doc)
    luaunit.assertEquals({ x, y }, { 7, 8 })
    -- `current` dropped — no such field survives on the bucket or any entry. Cast through `any`:
    -- the whole point is that `current` isn't in the typed Bucket/Entry, so a direct read would
    -- (correctly) trip undefined-field.
    local anyBucket = doc --[[@as table<string, any>]]
    luaunit.assertNil(anyBucket.current)
    local anyEntry = doc.entries[1] --[[@as table<string, any>]]
    luaunit.assertNil(anyEntry.current)
end

function TestStore:testLegacyMigratedAlertsRestoreLive()
    seedLegacyDoc({
        graphs = { { name = "alpha", graph = serializedGraph(self.registry), enabled = true } },
    })

    local doc = Store.Load()
    local restored = Store.RestoreAll(doc, self.registry)

    luaunit.assertEquals(#restored, 1)
    luaunit.assertEquals(restored[1].name, "alpha")
    luaunit.assertEquals(#restored[1].graph:GetNodes(), 1)
end

function TestStore:testLegacyMigrationWritesGlobalAndDeletesLegacyKey()
    seedLegacyDoc({ graphs = { { name = "alpha", graph = serializedGraph(self.registry), enabled = true } } })

    Store.Load()

    -- `global` written, legacy key removed only after that succeeded.
    luaunit.assertNotNil(PersistentDB.data["global"])
    luaunit.assertNil(PersistentDB.data[LEGACY_KEY])
end

function TestStore:testLegacyMigrationPersistsAcrossReload()
    -- After migration the legacy key is gone, so a second Load reads the authoritative `global`.
    seedLegacyDoc({ graphs = {
        { name = "alpha", graph = serializedGraph(self.registry), enabled = true },
        { name = "beta",  graph = serializedGraph(self.registry), enabled = false },
    } })

    Store.Load()
    local reloaded, migrationFailed = Store.Load()

    luaunit.assertNil(migrationFailed)
    luaunit.assertEquals(#reloaded.entries, 2)
    luaunit.assertEquals(reloaded.entries[1].name, "alpha")
    luaunit.assertEquals(reloaded.entries[2].enabled, false)
end

function TestStore:testFreshInstallDoesNotMigrateOrFlag()
    -- No legacy key, no global: a genuine fresh install is untouched and never flags failure.
    local doc, migrationFailed = Store.Load()

    luaunit.assertNil(migrationFailed)
    luaunit.assertEquals(doc.version, 2)
    luaunit.assertEquals(doc.entries, {})
    luaunit.assertNil(PersistentDB.data["global"])
end

function TestStore:testGlobalPresentIsAuthoritativeAndLegacyIgnored()
    -- Trigger is absence of `global`, not version: if `global` exists it wins outright and the
    -- legacy key is neither read nor deleted (rule 2 — migration cannot run twice).
    local existing = Store.Empty()
    seedAlert(self, existing, "kept", true)
    Store.Save(existing)
    seedLegacyDoc({ graphs = { { name = "should-not-appear", graph = serializedGraph(self.registry) } } })

    local doc, migrationFailed = Store.Load()

    luaunit.assertNil(migrationFailed)
    luaunit.assertEquals(#doc.entries, 1)
    luaunit.assertEquals(doc.entries[1].name, "kept")
    -- Legacy key untouched (not deleted), never migrated in.
    luaunit.assertNotNil(PersistentDB.data[LEGACY_KEY])
end

function TestStore:testWriteFailureAbortsKeepsLegacyAndFlags()
    seedLegacyDoc({ graphs = { { name = "alpha", graph = serializedGraph(self.registry), enabled = true } } })
    PersistentDB.failWriteKey = "global" -- client refuses the `global` write

    local doc, migrationFailed = Store.Load()

    -- Aborts: flag set, `global` unwritten, legacy key kept intact for the next retry.
    luaunit.assertTrue(migrationFailed)
    luaunit.assertNil(PersistentDB.data["global"])
    luaunit.assertNotNil(PersistentDB.data[LEGACY_KEY])
    -- Caller still gets a usable (empty) bucket.
    luaunit.assertEquals(doc.entries, {})
end

function TestStore:testUnreadableLegacyJsonAbortsAndFlags()
    -- Corrupt legacy JSON must abort (distinct from a fresh install) so the demo seed is suppressed.
    PersistentDB.data[LEGACY_KEY] = "{ this is not valid json"

    local doc, migrationFailed = Store.Load()

    luaunit.assertTrue(migrationFailed)
    luaunit.assertNil(PersistentDB.data["global"])
    luaunit.assertNotNil(PersistentDB.data[LEGACY_KEY])
    luaunit.assertEquals(doc.entries, {})
end

function TestStore:testFailedLegacyDeleteIsNotMigrationFailure()
    -- `global` is written and authoritative; a failed delete of the stale legacy key is inert.
    seedLegacyDoc({ graphs = { { name = "alpha", graph = serializedGraph(self.registry), enabled = true } } })
    PersistentDB.failDeleteKey = LEGACY_KEY

    local doc, migrationFailed = Store.Load()

    luaunit.assertNil(migrationFailed)
    luaunit.assertNotNil(PersistentDB.data["global"])
    luaunit.assertEquals(#doc.entries, 1)
    luaunit.assertEquals(doc.entries[1].name, "alpha")
    -- The stale key survives (delete refused) but that's harmless — rule 2 keeps `global` winning.
    luaunit.assertNotNil(PersistentDB.data[LEGACY_KEY])
end

--- Per-character Buckets: keyed I/O (#89) --------------------------------------------------
-- The `global` bucket lives under a fixed key; a character bucket lives under
-- `player_<normalized>`. Store.PlayerKey builds that key from a raw display name (normalizing),
-- and Store.LoadKey/SaveTo read/write any bucket key without the global-only legacy migration.

function TestStore:testPlayerKeyNormalizesDisplayName()
    luaunit.assertEquals(Store.PlayerKey("Zezima"), "player_zezima")
    -- Cosmetic case/whitespace variants collapse to the same key so they can't orphan a bucket.
    luaunit.assertEquals(Store.PlayerKey("Ze  ZIMA "), Store.PlayerKey("ze zima"))
    -- No `watchdog_` prefix — PersistentDB is already plugin-scoped (#81).
    luaunit.assertStrContains(Store.PlayerKey("A"), "player_")
    luaunit.assertNil(string.find(Store.PlayerKey("A"), "watchdog"))
end

function TestStore:testLoadKeyReturnsEmptyBucketForAbsentKey()
    local doc = Store.LoadKey(Store.PlayerKey("nobody"))
    luaunit.assertEquals(doc.entries, {})
    luaunit.assertEquals(doc.version, 2)
end

function TestStore:testSaveToAndLoadKeyRoundTripPlayerBucket()
    local key = Store.PlayerKey("Alice")
    local doc = Store.Empty()
    seedAlert(self, doc, "alice-alert", true)
    luaunit.assertTrue(Store.SaveTo(key, doc))

    -- Written under the player key, not the global one.
    luaunit.assertNotNil(PersistentDB.data[key])
    luaunit.assertNil(PersistentDB.data["global"])

    local reloaded = Store.LoadKey(key)
    luaunit.assertEquals(#reloaded.entries, 1)
    luaunit.assertEquals(reloaded.entries[1].name, "alice-alert")
end

function TestStore:testLoadKeyDoesNotRunLegacyMigration()
    -- The one-shot watchdog_graphs hop is bound to the `global` load path only. Loading a player
    -- key when only the legacy key exists must NOT adopt it — it's a fresh (empty) player bucket.
    seedLegacyDoc({ graphs = { { name = "legacy", graph = serializedGraph(self.registry), enabled = true } } })
    local doc = Store.LoadKey(Store.PlayerKey("someone"))
    luaunit.assertEquals(#doc.entries, 0)
    luaunit.assertNotNil(PersistentDB.data[LEGACY_KEY]) -- untouched
end

function TestStore:testDistinctCharactersUseDistinctBuckets()
    local aKey, bKey = Store.PlayerKey("Alice"), Store.PlayerKey("Bob")
    local aDoc, bDoc = Store.Empty(), Store.Empty()
    seedAlert(self, aDoc, "a-only", true)
    seedAlert(self, bDoc, "b-only", true)
    Store.SaveTo(aKey, aDoc)
    Store.SaveTo(bKey, bDoc)

    luaunit.assertEquals(Store.LoadKey(aKey).entries[1].name, "a-only")
    luaunit.assertEquals(Store.LoadKey(bKey).entries[1].name, "b-only")
end

--- Insert-at-index + cross-bucket move (#92) ----------------------------------------------

function TestStore:testInsertEntryAtPlacesAtRootIndex()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    local b = seedAlert(self, doc, "b", true)
    local cId = Store.MintId(doc)
    local c = Store.NewAlertEntry(cId, "c", LibNodeGraph.NewGraph(self.registry), {}, true)
    luaunit.assertTrue(Store.InsertEntryAt(doc, c, nil, 2))
    luaunit.assertEquals(doc.entries[1].id, a)
    luaunit.assertEquals(doc.entries[2].id, cId)
    luaunit.assertEquals(doc.entries[3].id, b)
end

function TestStore:testInsertEntryAtPlacesInsideGroup()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "g", true, {}))
    local a = seedAlert(self, doc, "a", true, groupId)
    local b = seedAlert(self, doc, "b", true, groupId)
    local cId = Store.MintId(doc)
    local c = Store.NewAlertEntry(cId, "c", LibNodeGraph.NewGraph(self.registry), {}, true)
    luaunit.assertTrue(Store.InsertEntryAt(doc, c, groupId, 1))
    local kids = Store.FindById(doc, groupId).children
    luaunit.assertEquals(kids[1].id, cId)
    luaunit.assertEquals(kids[2].id, a)
    luaunit.assertEquals(kids[3].id, b)
end

function TestStore:testInsertEntryAtRefusesNonGroupParent()
    local doc = Store.Empty()
    local alertId = seedAlert(self, doc, "a", true)
    local cId = Store.MintId(doc)
    local c = Store.NewAlertEntry(cId, "c", LibNodeGraph.NewGraph(self.registry), {}, true)
    luaunit.assertFalse(Store.InsertEntryAt(doc, c, alertId, 1))
    luaunit.assertEquals(#doc.entries, 1)
end

function TestStore:testMoveSubtreeToIndexReordersAmongSiblings()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    local b = seedAlert(self, doc, "b", true)
    local c = seedAlert(self, doc, "c", true)
    luaunit.assertTrue(Store.MoveSubtree(doc, c, nil, 1))
    luaunit.assertEquals(doc.entries[1].id, c)
    luaunit.assertEquals(doc.entries[2].id, a)
    luaunit.assertEquals(doc.entries[3].id, b)
end

function TestStore:testMoveSubtreeNilIndexStillAppends()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "g", true, {}))
    local a = seedAlert(self, doc, "a", true)
    seedAlert(self, doc, "inside", true, groupId)
    luaunit.assertTrue(Store.MoveSubtree(doc, a, groupId))
    local kids = Store.FindById(doc, groupId).children
    luaunit.assertEquals(kids[#kids].id, a)
end

function TestStore:testMoveEntryBetweenBucketsPreservesIdAndAppendsRoot()
    local src = Store.Empty()
    local dst = Store.Empty()
    -- Distinct ids across buckets (each Empty() would otherwise both mint 1).
    local alertId = 10
    Store.InsertEntry(src, Store.NewAlertEntry(alertId, "mover", LibNodeGraph.NewGraph(self.registry), {}, true))
    Store.InsertEntry(dst, Store.NewAlertEntry(1, "already", LibNodeGraph.NewGraph(self.registry), {}, true))
    local moved = Store.MoveEntryBetweenBuckets(src, dst, alertId)
    luaunit.assertNotNil(moved)
    luaunit.assertEquals(moved.id, alertId)
    luaunit.assertEquals(moved.name, "mover")
    luaunit.assertEquals(#src.entries, 0)
    luaunit.assertEquals(#dst.entries, 2)
    luaunit.assertEquals(dst.entries[2].id, alertId)
end

function TestStore:testMoveEntryBetweenBucketsCarriesGroupSubtree()
    local src = Store.Empty()
    local dst = Store.Empty()
    local groupId = Store.MintId(src)
    Store.InsertEntry(src, Store.NewGroupEntry(groupId, "g", true, {}))
    local childId = seedAlert(self, src, "nested", true, groupId)
    luaunit.assertNotNil(Store.MoveEntryBetweenBuckets(src, dst, groupId))
    luaunit.assertEquals(#src.entries, 0)
    luaunit.assertEquals(dst.entries[1].id, groupId)
    luaunit.assertEquals(dst.entries[1].children[1].id, childId)
end

function TestStore:testMoveEntryBetweenBucketsRefusesIdCollision()
    local src = Store.Empty()
    local dst = Store.Empty()
    -- Force the same id into both buckets.
    local id = 7
    Store.InsertEntry(src, Store.NewAlertEntry(id, "src", LibNodeGraph.NewGraph(self.registry), {}, true))
    Store.InsertEntry(dst, Store.NewAlertEntry(id, "dst", LibNodeGraph.NewGraph(self.registry), {}, true))
    luaunit.assertNil(Store.MoveEntryBetweenBuckets(src, dst, id))
    luaunit.assertEquals(#src.entries, 1)
    luaunit.assertEquals(dst.entries[1].name, "dst")
end

function TestStore:testMoveEntryBetweenBucketsReturnsNilForUnknownId()
    local src = Store.Empty()
    local dst = Store.Empty()
    luaunit.assertNil(Store.MoveEntryBetweenBuckets(src, dst, 999))
end

return TestStore
