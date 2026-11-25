-- Exercises store.lua's `global` Bucket + Entry-tree model (#86): the tree helpers (mint id,
-- walk leaves, find/insert/delete by id - all id-keyed, name-agnostic), the id-keyed mutators
-- (SetEnabled, UpdateAlertGraph), RestoreAll over alert leaves, and the persistence round-trip
-- under the un-prefixed `global` key.
--
-- store.lua reaches its dependencies as globals - `LibNodeGraph` (Serialize/Deserialize/Json)
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

local Store = require("src/store")
local Registry = require("registry")
local Node = require("src/ui/node")
local Compress = require("src/compress")

-- A minimal in-memory stand-in for the client PersistentDB (string key/value store).
local function newFakePersistentDB()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value)
        self.data[key] = value
        return true
    end
    function db:Delete(key)
        self.data[key] = nil
        return true
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

local function seedAlert(self, doc, name, enabled, parentId)
    local id = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewAlertEntry(id, name, graphWithOneNode(self.registry), {}, enabled), parentId)
    return id
end

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

    -- The key is plain `global` - no `watchdog_` prefix (PersistentDB is already plugin-scoped).
    luaunit.assertNotNil(PersistentDB.data["global"])
    luaunit.assertNil(PersistentDB.data["watchdog_graphs"])
end

function TestStore:testLoadOnFreshInstallIsEmptyBucket()
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
    luaunit.assertEquals(a, doc.entries[1].id)
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

    luaunit.assertEquals(#Store.FindById(doc, outerId).children, 0)
    local home = Store.FindById(doc, homeId)
    luaunit.assertEquals(home.children[1].id, innerId)
    luaunit.assertEquals(home.children[1].children[1].id, alertId)
end

function TestStore:testMoveSubtreeIntoOwnDescendantIsRefused()
    -- Moving a group under one of its own descendants would sever the tree - must be refused.
    local doc = Store.Empty()
    local outerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(outerId, "outer", true, {}))
    local innerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(innerId, "inner", true, {}), outerId)

    luaunit.assertFalse(Store.MoveSubtree(doc, outerId, innerId))
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
    luaunit.assertEquals(#doc.entries, 1)
end

--- Sibling reorder + Lift (MVP buttons; drag nest/scope stays on #92) ----------------------

function TestStore:testReorderSiblingSwapsAdjacentAtRoot()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    local b = seedAlert(self, doc, "b", true)
    local c = seedAlert(self, doc, "c", true)
    luaunit.assertTrue(Store.ReorderSibling(doc, b, -1))
    luaunit.assertEquals({ doc.entries[1].id, doc.entries[2].id, doc.entries[3].id }, { b, a, c })
    luaunit.assertTrue(Store.ReorderSibling(doc, b, 1))
    luaunit.assertEquals({ doc.entries[1].id, doc.entries[2].id, doc.entries[3].id }, { a, b, c })
end

function TestStore:testReorderSiblingSwapsInsideGroup()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "g", true, {}))
    local a = seedAlert(self, doc, "a", true, groupId)
    local b = seedAlert(self, doc, "b", true, groupId)
    luaunit.assertTrue(Store.ReorderSibling(doc, a, 1))
    local g = Store.FindById(doc, groupId)
    luaunit.assertEquals({ g.children[1].id, g.children[2].id }, { b, a })
end

function TestStore:testReorderSiblingRefusesOutOfBounds()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    local b = seedAlert(self, doc, "b", true)
    luaunit.assertFalse(Store.ReorderSibling(doc, a, -1))
    luaunit.assertFalse(Store.ReorderSibling(doc, b, 1))
    luaunit.assertEquals({ doc.entries[1].id, doc.entries[2].id }, { a, b })
end

function TestStore:testReorderSiblingRefusesUnknownId()
    local doc = Store.Empty()
    seedAlert(self, doc, "a", true)
    luaunit.assertFalse(Store.ReorderSibling(doc, 999, 1))
end

function TestStore:testLiftEntryInsertsBeforeFormerParentAtRoot()
    -- child under G beside sibling S → Lift(child) ⇒ child, G, S
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "g", true, {}))
    local sibling = seedAlert(self, doc, "s", true)
    local child = seedAlert(self, doc, "c", true, groupId)
    luaunit.assertTrue(Store.LiftEntry(doc, child))
    luaunit.assertEquals(
        { doc.entries[1].id, doc.entries[2].id, doc.entries[3].id },
        { child, groupId, sibling }
    )
    local g = Store.FindById(doc, groupId)
    luaunit.assertEquals(#(g.children or {}), 0)
end

function TestStore:testLiftEntryInsertsBeforeFormerParentNested()
    -- outer > inner > leaf; Lift(leaf) ⇒ outer's children become leaf, inner
    local doc = Store.Empty()
    local outerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(outerId, "outer", true, {}))
    local innerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(innerId, "inner", true, {}), outerId)
    local leaf = seedAlert(self, doc, "leaf", true, innerId)
    luaunit.assertTrue(Store.LiftEntry(doc, leaf))
    local outer = Store.FindById(doc, outerId)
    luaunit.assertEquals({ outer.children[1].id, outer.children[2].id }, { leaf, innerId })
    local inner = Store.FindById(doc, innerId)
    luaunit.assertEquals(#(inner.children or {}), 0)
end

function TestStore:testLiftEntryCarriesGroupSubtree()
    local doc = Store.Empty()
    local outerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(outerId, "outer", true, {}))
    local innerId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(innerId, "inner", true, {}), outerId)
    local nested = seedAlert(self, doc, "n", true, innerId)
    luaunit.assertTrue(Store.LiftEntry(doc, innerId))
    luaunit.assertEquals({ doc.entries[1].id, doc.entries[2].id }, { innerId, outerId })
    local inner = Store.FindById(doc, innerId)
    luaunit.assertEquals(inner.children[1].id, nested)
end

function TestStore:testLiftEntryRefusesRoot()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    luaunit.assertFalse(Store.LiftEntry(doc, a))
    luaunit.assertEquals(#doc.entries, 1)
end

function TestStore:testLiftEntryRefusesUnknownId()
    local doc = Store.Empty()
    seedAlert(self, doc, "a", true)
    luaunit.assertFalse(Store.LiftEntry(doc, 999))
end

--- Bulk helpers (#93): NearestCommonAncestor / GroupSelected / MoveEntryToBucket -------------

function TestStore:testNearestCommonAncestorNilForRootSiblings()
    local doc = Store.Empty()
    local a = seedAlert(self, doc, "a", true)
    local b = seedAlert(self, doc, "b", true)
    luaunit.assertNil(Store.NearestCommonAncestor(doc, { a, b }))
end

function TestStore:testNearestCommonAncestorFindsSharedParent()
    local doc = Store.Empty()
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "g", true, {}))
    local a = seedAlert(self, doc, "a", true, groupId)
    local b = seedAlert(self, doc, "b", true, groupId)
    luaunit.assertEquals(Store.NearestCommonAncestor(doc, { a, b }), groupId)
end

function TestStore:testGroupSelectedWrapsUnderCommonAncestor()
    local doc = Store.Empty()
    local parentId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(parentId, "parent", true, {}))
    local a = seedAlert(self, doc, "a", true, parentId)
    local b = seedAlert(self, doc, "b", true, parentId)
    local newId = Store.GroupSelected(doc, { a, b }, "bundled")
    luaunit.assertNotNil(newId)
    local parent = Store.FindById(doc, parentId)
    luaunit.assertEquals(#parent.children, 1)
    luaunit.assertEquals(parent.children[1].id, newId)
    luaunit.assertEquals(parent.children[1].name, "bundled")
    luaunit.assertEquals(#parent.children[1].children, 2)
    luaunit.assertEquals(parent.children[1].children[1].id, a)
    luaunit.assertEquals(parent.children[1].children[2].id, b)
end

function TestStore:testMoveEntryToBucketPreservesFreeIds()
    local src = Store.Empty()
    local dest = Store.Empty()
    local id = seedAlert(self, src, "a", true)
    local moved = Store.MoveEntryToBucket(src, dest, id)
    luaunit.assertEquals(moved.id, id)
    luaunit.assertEquals(#src.entries, 0)
    luaunit.assertEquals(#dest.entries, 1)
    luaunit.assertEquals(dest.entries[1].id, id)
end

function TestStore:testMoveEntryToBucketRemintsCollidingIds()
    local src = Store.Empty()
    local dest = Store.Empty()
    seedAlert(self, dest, "existing", true)
    local id = seedAlert(self, src, "moving", true)
    luaunit.assertEquals(id, 1)
    local moved = Store.MoveEntryToBucket(src, dest, id)
    luaunit.assertNotEquals(moved.id, 1)
    luaunit.assertEquals(#dest.entries, 2)
    luaunit.assertEquals(Store.FindById(dest, 1).name, "existing")
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
    luaunit.assertFalse(Store.EnabledChain(doc, onId))
    luaunit.assertEquals(Store.FindById(doc, onId).enabled, true)
    luaunit.assertEquals(Store.FindById(doc, offId).enabled, false)

    Store.SetEnabled(doc, groupId, true)
    luaunit.assertTrue(Store.EnabledChain(doc, onId))
    luaunit.assertFalse(Store.EnabledChain(doc, offId))
end

function TestStore:testEnabledChainReEvaluatesAfterMove()
    -- Moving an alert out of a disabled group must restore it; moving it back in re-suppresses -
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

function TestStore:testLoadStripsTagsFromSavedNames()
    local doc = Store.Empty()
    doc.entries = { {
        id = 1,
        kind = "group",
        name = "<col=ff0000>Folder",
        enabled = true,
        children = { {
            id = 2,
            kind = "alert",
            name = "<col=00ff00>",
            enabled = true,
            graph = { version = 1, nodes = {}, connections = {} },
            layout = {},
        } },
    } }
    luaunit.assertTrue(Store.Save(doc))
    local loaded = Store.Load()
    luaunit.assertEquals(loaded.entries[1].name, "Folder")
    luaunit.assertEquals(loaded.entries[1].children[1].name, "Alert")
end

function TestStore:testSetNameStripsClientTextTags()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "<col=ff0000>alpha", true)
    luaunit.assertEquals(Store.FindById(doc, id).name, "alpha")
    luaunit.assertTrue(Store.SetName(doc, id, "be<col=00ff00>ta"))
    luaunit.assertEquals(Store.FindById(doc, id).name, "beta")
    luaunit.assertFalse(Store.SetName(doc, id, "<col=ff0000>"))
    luaunit.assertEquals(Store.FindById(doc, id).name, "beta")
    luaunit.assertEquals(Store.NewGroupEntry(9, "<shad=0>Folder", true).name, "Folder")
end

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

    local graph = graphWithOneNode(self.registry)
    graph:AddNode("fixture.trigger")
    luaunit.assertTrue(Store.UpdateAlertGraph(doc, id, graph, {}))

    local reloaded = saveAndReload(doc)
    local restored = Store.RestoreAll(reloaded, self.registry)
    luaunit.assertEquals(#restored[1].graph:GetNodes(), 2)
end

function TestStore:testUpdateAlertGraphPreservesEnabled()
    -- Autosave must not re-arm an alert the user disabled - it only touches graph + layout.
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
    -- would - the unknown node must re-emit its ORIGINAL type + controls verbatim.
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
    luaunit.assertEquals(restored[1].graph:Fire(1), nil)
end

-- Once the missing type is registered again, the same saved bucket loads the REAL node with its
-- original controls + wiring - no placeholder remains.
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

--- Per-character Buckets: keyed I/O (#89) --------------------------------------------------
-- The `global` bucket lives under a fixed key; a character bucket lives under
-- `player_<tracking id>`. Store.PlayerKey prefixes that id as-is (no display-name folding),
-- and Store.LoadKey/SaveTo read/write any bucket key.

function TestStore:testPlayerKeyUsesTrackingIdCharacterForCharacter()
    luaunit.assertEquals(Store.PlayerKey("AbC123"), "player_AbC123")
    -- Case is part of the id. A display-name fold would have collapsed these.
    luaunit.assertNotEquals(Store.PlayerKey("AbC123"), Store.PlayerKey("abc123"))
    -- No `watchdog_` prefix - PersistentDB is already plugin-scoped (#81).
    luaunit.assertStrContains(Store.PlayerKey("A"), "player_")
    luaunit.assertNil(string.find(Store.PlayerKey("A"), "watchdog"))
end

function TestStore:testLoadKeyReturnsEmptyBucketForAbsentKey()
    local doc = Store.LoadKey(Store.PlayerKey("nobody"))
    luaunit.assertEquals(doc.entries, {})
    luaunit.assertEquals(doc.version, 2)
end

function TestStore:testLoadKeyLeavesUnreadableTextOnDisk()
    local key = Store.PlayerKey("nobody")
    local corrupt = "{not-json"
    PersistentDB:SetString(key, corrupt)

    local doc = Store.LoadKey(key)

    luaunit.assertEquals(PersistentDB:GetString(key), corrupt)
    luaunit.assertEquals(doc.entries, {})
end

function TestStore:testSaveToAndLoadKeyRoundTripPlayerBucket()
    local key = Store.PlayerKey("Alice")
    local doc = Store.Empty()
    seedAlert(self, doc, "alice-alert", true)
    luaunit.assertTrue(Store.SaveTo(key, doc))

    luaunit.assertNotNil(PersistentDB.data[key])
    luaunit.assertNil(PersistentDB.data["global"])

    local reloaded = Store.LoadKey(key)
    luaunit.assertEquals(#reloaded.entries, 1)
    luaunit.assertEquals(reloaded.entries[1].name, "alice-alert")
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

--- Node name on the alert graph (#139). UpdateAlertGraph is the editor autosave path. -----

function TestStore:testUnsetNodeNameIsOmittedFromTheSavedGraph()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    local graph = graphWithOneNode(self.registry)
    local nodeId = graph:GetNodes()[1].id
    luaunit.assertNil(graph.nodes[nodeId].name)
    luaunit.assertTrue(Store.UpdateAlertGraph(doc, id, graph, {}))

    local reloaded = saveAndReload(doc)
    luaunit.assertNil(reloaded.entries[1].graph.nodes[1].name)
    local restored = Store.RestoreAll(reloaded, self.registry)
    luaunit.assertNil(restored[1].graph.nodes[nodeId].name)
end

function TestStore:testRestoreStripsTagsFromNodeNamesAndControlText()
    self.registry:RegisterNodeType("fixture.toast", {
        category = "action",
        pins = {
            { name = "text", kind = "data", direction = "in", dataType = "string" },
        },
        run = function() end,
    })
    local restored = Store.RestoreAll({
        version = 2,
        entries = { {
            id = 1,
            kind = "alert",
            name = "alpha",
            enabled = true,
            layout = {},
            graph = {
                version = 1,
                nodes = { {
                    id = 1,
                    type = "fixture.toast",
                    name = "<col=00ff00>Callout",
                    controls = { text = "<col=ff0000>hello" },
                } },
                connections = {},
            },
        } },
    }, self.registry)
    luaunit.assertEquals(restored[1].graph.nodes[1].name, "Callout")
    luaunit.assertEquals(restored[1].graph:GetControl(1, "text"), "hello")
end

function TestStore:testUpdateAlertGraphStripsTagsFromNamesAndControlText()
    self.registry:RegisterNodeType("fixture.toast", {
        category = "action",
        pins = {
            { name = "text", kind = "data", direction = "in", dataType = "string" },
            { name = "contains", kind = "data", direction = "in", dataType = "matcher" },
        },
        run = function() end,
    })
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.toast", {
        text = "<col=ff0000>hello",
        contains = { needle = "<shad=0>boss", mode = "substring" },
    }, { name = "<col=00ff00>Callout" })
    luaunit.assertTrue(Store.UpdateAlertGraph(doc, id, graph, {}))

    luaunit.assertEquals(graph.nodes[nodeId].name, "Callout")
    luaunit.assertEquals(graph:GetControl(nodeId, "text"), "hello")
    luaunit.assertEquals(graph:GetControl(nodeId, "contains").needle, "boss")
    luaunit.assertEquals(graph:GetControl(nodeId, "contains").mode, "substring")

    local reloaded = saveAndReload(doc)
    local saved = reloaded.entries[1].graph.nodes[1]
    luaunit.assertEquals(saved.name, "Callout")
    luaunit.assertEquals(saved.controls.text, "hello")
    luaunit.assertEquals(saved.controls.contains.needle, "boss")
end

function TestStore:testRenamedNodeNameRoundTripsThroughTheAlertGraph()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    local graph = graphWithOneNode(self.registry)
    local nodeId = graph:GetNodes()[1].id
    luaunit.assertTrue(Node.CommitRename(graph.nodes[nodeId], "  Enrage callout  "))
    luaunit.assertTrue(Store.UpdateAlertGraph(doc, id, graph, {}))

    local reloaded = saveAndReload(doc)
    luaunit.assertEquals(reloaded.entries[1].graph.nodes[1].name, "Enrage callout")
    local restored = Store.RestoreAll(reloaded, self.registry)
    luaunit.assertEquals(restored[1].graph.nodes[nodeId].name, "Enrage callout")
end

function TestStore:testPlaceholderRenameKeepsUnknownNameWithOriginalTypeAndControls()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    local first = Store.RestoreAll(bucketWithUnknownNode(), self.registry)[1]
    luaunit.assertTrue(Node.CommitRename(first.graph.nodes[2], "Enrage callout"))
    luaunit.assertTrue(Store.UpdateAlertGraph(doc, id, first.graph, first.layout))

    local reloaded = saveAndReload(doc)
    local saved
    for _, n in ipairs(reloaded.entries[1].graph.nodes) do
        if n.type == "action.overlay" then saved = n end
    end
    luaunit.assertEquals(saved.type, "action.overlay")
    luaunit.assertEquals(saved.controls.text, "hi")
    luaunit.assertEquals(saved.name, "Enrage callout")

    local second = Store.RestoreAll(reloaded, self.registry)[1]
    luaunit.assertEquals(second.graph.nodes[2].unknown.type, "action.overlay")
    luaunit.assertEquals(second.graph.nodes[2].unknown.controls.text, "hi")
    luaunit.assertEquals(second.graph.nodes[2].unknown.name, "Enrage callout")
    luaunit.assertNil(second.graph.nodes[2].name)
end

-- A false return is a refusal. The client leaves the previous bytes, and SaveTo
-- must not report that as saved.
function TestStore:testSetStringFalseLeavesThePreviousBytes()
    local key = "global"
    local previous = "{\"version\":2,\"entries\":[]}"
    PersistentDB.data[key] = previous
    function PersistentDB:SetString()
        return false
    end

    local doc = Store.Empty()
    seedAlert(self, doc, "new", true)
    luaunit.assertFalse(Store.SaveTo(key, doc))
    luaunit.assertEquals(PersistentDB:GetString(key), previous)
end

function TestStore:testSetStringNilLeavesThePreviousBytes()
    local key = "global"
    local previous = "{\"version\":2,\"entries\":[]}"
    PersistentDB.data[key] = previous
    function PersistentDB:SetString()
        return nil
    end

    local doc = Store.Empty()
    seedAlert(self, doc, "new", true)
    luaunit.assertFalse(Store.SaveTo(key, doc))
    luaunit.assertEquals(PersistentDB:GetString(key), previous)
end

function TestStore:testSetStringThrowLeavesThePreviousBytes()
    local key = "global"
    local previous = "{\"version\":2,\"entries\":[]}"
    PersistentDB.data[key] = previous
    function PersistentDB:SetString()
        error("rejected")
    end

    local doc = Store.Empty()
    seedAlert(self, doc, "new", true)
    luaunit.assertFalse(Store.SaveTo(key, doc))
    luaunit.assertEquals(PersistentDB:GetString(key), previous)
end

-- A true return is trusted. A later read that disagrees or throws does not
-- undo the save or turn it into a failure.
function TestStore:testTrueSetStringIsSavedWithoutReadingItBack()
    local key = "global"
    PersistentDB.data[key] = "{\"version\":2,\"entries\":[]}"
    function PersistentDB:SetString(dbKey, value)
        self.data[dbKey] = value
        self.GetString = function() error("read back") end
        return true
    end

    local doc = Store.Empty()
    seedAlert(self, doc, "kept", true)
    luaunit.assertTrue(Store.SaveTo(key, doc))
    luaunit.assertStrContains(PersistentDB.data[key], "kept")
end

--- Split scope: the tree and each alert graph are separate WD1 keys (#184). ---
-- Stored bytes are the contract. The loaded tree is the same shape callers
-- already walk, with the graph filled back in from the alert key.

local function decodeToken(text)
    luaunit.assertEquals(type(text), "string")
    luaunit.assertEquals(text:sub(1, 3), "WD1")
    return LibNodeGraph.Json.Default.decode(Compress.decompress(text))
end

-- Letters, not a repeated byte. A repeated byte deflates under the cap and
-- would not exercise the refusal. 200000 is past the point where this
-- generator's WD1 token exceeds 131070 bytes.
local function incompressible(count)
    local parts = {}
    local x = 123456789
    for i = 1, count do
        x = (1103515245 * x + 12345) % 2147483648
        parts[i] = string.char(48 + (x % 26))
    end
    return table.concat(parts)
end

function TestStore:testSplitScopeRoundTripsTheTreeAndTheAlertGraph()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    Store.SetInfoBoxAnchor(doc, 12, 34)
    local entry = Store.FindById(doc, id)

    luaunit.assertTrue(Store.SaveAlert("global", entry))
    luaunit.assertTrue(Store.SaveScope("global", doc))

    luaunit.assertNil(PersistentDB:GetString("global"))
    local scope = decodeToken(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(scope.version, 3)
    luaunit.assertEquals(scope.entries[1].id, id)
    luaunit.assertEquals(scope.entries[1].kind, "alert")
    luaunit.assertEquals(scope.entries[1].name, "alpha")
    luaunit.assertEquals(scope.entries[1].enabled, true)
    luaunit.assertNil(scope.entries[1].graph)
    luaunit.assertNil(scope.entries[1].layout)
    luaunit.assertEquals(scope.infoboxAnchor.x, 12)
    luaunit.assertEquals(scope.infoboxAnchor.y, 34)

    local alert = decodeToken(PersistentDB:GetString("scope_global_alert_" .. id))
    luaunit.assertEquals(alert.version, 1)
    luaunit.assertEquals(alert.graph.version, 1)
    luaunit.assertEquals(alert.graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(alert.layout, {})

    local loaded = Store.LoadScope("global")
    luaunit.assertEquals(loaded.version, 3)
    luaunit.assertEquals(loaded.entries[1].name, "alpha")
    luaunit.assertEquals(loaded.entries[1].graph.version, 1)
    luaunit.assertEquals(loaded.entries[1].graph.nodes[1].type, "fixture.trigger")
    local x, y = Store.GetInfoBoxAnchor(loaded)
    luaunit.assertEquals({ x, y }, { 12, 34 })
    local restored = Store.RestoreAll(loaded, self.registry)
    luaunit.assertEquals(#restored, 1)
    luaunit.assertEquals(restored[1].name, "alpha")
end

function TestStore:testTheSameAlertIdInTwoScopesIsTwoKeys()
    local globalDoc = Store.Empty()
    local playerDoc = Store.Empty()
    local id = seedAlert(self, globalDoc, "global-horn", true)
    local character = graphWithOneNode(self.registry)
    Store.InsertEntry(playerDoc, Store.NewAlertEntry(id, "character-horn", character, {}, true))
    playerDoc.entries[1].graph.nodes[1].name = "character only"
    Store.SetInfoBoxAnchor(playerDoc, 9, 9)
    local groupId = Store.MintId(globalDoc)
    Store.InsertEntry(globalDoc, Store.NewGroupEntry(groupId, "folder", true, {}))
    local nestedId = seedAlert(self, globalDoc, "nested", false, groupId)

    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(globalDoc, id)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(globalDoc, nestedId)))
    luaunit.assertTrue(Store.SaveScope("global", globalDoc))
    luaunit.assertTrue(Store.SaveAlert("player_42", playerDoc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("player_42", playerDoc))

    local globalAlert = decodeToken(PersistentDB:GetString("scope_global_alert_" .. id))
    local playerAlert = decodeToken(PersistentDB:GetString("scope_player_42_alert_" .. id))
    luaunit.assertNil(globalAlert.graph.nodes[1].name)
    luaunit.assertEquals(playerAlert.graph.nodes[1].name, "character only")

    local scope = decodeToken(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(scope.entries[2].kind, "group")
    luaunit.assertEquals(scope.entries[2].children[1].name, "nested")
    luaunit.assertEquals(scope.entries[2].children[1].enabled, false)
    luaunit.assertNil(scope.entries[2].children[1].graph)
    luaunit.assertNil(decodeToken(PersistentDB:GetString("scope_player_42")).infoboxAnchor)

    local loadedGlobal = Store.LoadScope("global")
    local loadedPlayer = Store.LoadScope("player_42")
    luaunit.assertEquals(loadedGlobal.entries[1].name, "global-horn")
    luaunit.assertNil(loadedGlobal.entries[1].graph.nodes[1].name)
    luaunit.assertEquals(loadedGlobal.entries[2].children[1].name, "nested")
    luaunit.assertEquals(loadedGlobal.entries[2].children[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(loadedPlayer.entries[1].name, "character-horn")
    luaunit.assertEquals(loadedPlayer.entries[1].graph.nodes[1].name, "character only")
    luaunit.assertNil(loadedPlayer.infoboxAnchor)
    local x, y = Store.GetInfoBoxAnchor(loadedGlobal)
    luaunit.assertNil(x)
    luaunit.assertNil(y)
end

function TestStore:testAScopeRenameLeavesTheAlertKey()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local alertBefore = PersistentDB:GetString("scope_global_alert_" .. id)
    doc.entries[1].name = "renamed"
    luaunit.assertTrue(Store.SaveScope("global", doc))
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), alertBefore)
    luaunit.assertEquals(decodeToken(PersistentDB:GetString("scope_global")).entries[1].name, "renamed")
end

function TestStore:testATokenOverTheCapIsRefusedBeforeTheWrite()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local previousAlert = PersistentDB:GetString("scope_global_alert_" .. id)
    local previousScope = PersistentDB:GetString("scope_global")
    local writes = 0
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        writes = writes + 1
        return inner(self, key, value)
    end

    doc.entries[1].graph.nodes[1].controls = { text = incompressible(200000) }
    local alertOk, alertReason = Store.SaveAlert("global", doc.entries[1])
    luaunit.assertFalse(alertOk)
    luaunit.assertEquals(alertReason, "size")
    luaunit.assertEquals(writes, 0)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), previousAlert)
    luaunit.assertEquals(#doc.entries[1].graph.nodes[1].controls.text, 200000)

    doc.entries[1].name = incompressible(200000)
    local scopeOk, scopeReason = Store.SaveScope("global", doc)
    luaunit.assertFalse(scopeOk)
    luaunit.assertEquals(scopeReason, "size")
    luaunit.assertEquals(writes, 0)
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), previousScope)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), previousAlert)
end

function TestStore:testACompressionFailureIsNotASizeRefusal()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local previousAlert = PersistentDB:GetString("scope_global_alert_" .. id)
    local previousScope = PersistentDB:GetString("scope_global")
    local writes = 0
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        writes = writes + 1
        return inner(self, key, value)
    end
    -- The deflate encoder accepts every string JSON can produce below its own
    -- output cap, so the failure this save has to tell from a size refusal is
    -- the compressor throwing.
    local original = Compress.compress
    Compress.compress = function() error("deflate broke") end
    doc.entries[1].name = "edited"
    local alertOk, alertReason = Store.SaveAlert("global", doc.entries[1])
    local scopeOk, scopeReason = Store.SaveScope("global", doc)
    Compress.compress = original

    luaunit.assertFalse(alertOk)
    luaunit.assertEquals(alertReason, "failed")
    luaunit.assertFalse(scopeOk)
    luaunit.assertEquals(scopeReason, "failed")
    luaunit.assertEquals(writes, 0)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), previousAlert)
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), previousScope)
end

function TestStore:testAMissingOrUnreadableAlertLeavesTheRowUnarmed()
    local doc = Store.Empty()
    local kept = seedAlert(self, doc, "kept", true)
    local missing = seedAlert(self, doc, "missing", true)
    local bad = seedAlert(self, doc, "bad", true)
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, kept)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, missing)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, bad)))
    luaunit.assertTrue(Store.SaveScope("global", doc))

    local scopeBefore = PersistentDB:GetString("scope_global")
    local badKey = "scope_global_alert_" .. bad
    local corrupt = "WD1not-a-token"
    PersistentDB.data["scope_global_alert_" .. missing] = nil
    PersistentDB.data[badKey] = corrupt
    local orphan = PersistentDB:GetString("scope_global_alert_" .. kept)
    PersistentDB.data["scope_global_alert_999"] = orphan

    local loaded, unread = Store.LoadScope("global")
    luaunit.assertEquals(#loaded.entries, 3)
    luaunit.assertEquals(loaded.entries[1].name, "kept")
    luaunit.assertEquals(loaded.entries[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertNil(loaded.entries[2].graph)
    luaunit.assertNil(loaded.entries[3].graph)
    luaunit.assertEquals(unread, { "missing", "bad" })
    local restored = Store.RestoreAll(loaded, self.registry)
    luaunit.assertEquals(#restored, 1)
    luaunit.assertEquals(restored[1].id, kept)
    luaunit.assertNil(Store.FindById(loaded, 999))
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), scopeBefore)
    luaunit.assertEquals(PersistentDB:GetString(badKey), corrupt)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_999"), orphan)

    local badEntry = Store.FindById(loaded, bad)
    badEntry.graph = loaded.entries[1].graph
    badEntry.layout = {}
    local ok, reason = Store.SaveAlert("global", badEntry)
    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "failed")
    luaunit.assertEquals(PersistentDB:GetString(badKey), corrupt)
end

function TestStore:testAnUnknownScopeVersionIsLeftOnDisk()
    local future = Compress.compress(LibNodeGraph.Json.Default.encode({
        version = 4,
        entries = { { id = 1, kind = "alert", name = "future", enabled = true } },
    }))
    local bare = Compress.compress(LibNodeGraph.Json.Default.encode({
        entries = { { id = 1, kind = "alert", name = "bare", enabled = true } },
    }))
    PersistentDB:SetString("scope_global", future)
    PersistentDB:SetString("scope_player_42", bare)

    local global = Store.LoadScope("global")
    local player = Store.LoadScope("player_42")
    luaunit.assertEquals(global.entries, {})
    luaunit.assertEquals(player.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), future)
    luaunit.assertEquals(PersistentDB:GetString("scope_player_42"), bare)

    local doc = Store.Empty()
    seedAlert(self, doc, "nope", true)
    luaunit.assertFalse(Store.SaveScope("global", doc))
    luaunit.assertFalse(Store.SaveScope("player_42", doc))
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), future)
    luaunit.assertEquals(PersistentDB:GetString("scope_player_42"), bare)
end

function TestStore:testAnUnknownAlertVersionIsLeftOnDisk()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local future = Compress.compress(LibNodeGraph.Json.Default.encode({
        version = 2,
        graph = { version = 9, nodes = {}, connections = {} },
        layout = {},
    }))
    local key = "scope_global_alert_" .. id
    PersistentDB:SetString(key, future)

    local loaded, unread = Store.LoadScope("global")
    luaunit.assertEquals(loaded.entries[1].name, "alpha")
    luaunit.assertNil(loaded.entries[1].graph)
    luaunit.assertEquals(unread, { "alpha" })
    luaunit.assertEquals(#Store.RestoreAll(loaded, self.registry), 0)
    luaunit.assertEquals(PersistentDB:GetString(key), future)

    loaded.entries[1].graph = doc.entries[1].graph
    loaded.entries[1].layout = {}
    luaunit.assertFalse(Store.SaveAlert("global", loaded.entries[1]))
    luaunit.assertEquals(PersistentDB:GetString(key), future)
end

function TestStore:testAVersion3RowUsesTheAlertKeyNotAnInlineGraph()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "alpha", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    local inline = {
        version = 3,
        entries = { {
            id = id,
            kind = "alert",
            name = "alpha",
            enabled = true,
            graph = {
                version = 1,
                nodes = { { id = 7, type = "not.the.alert", controls = {} } },
                connections = {},
            },
            layout = { { id = 7, x = 5, y = 6 } },
        } },
    }
    local stored = Compress.compress(LibNodeGraph.Json.Default.encode(inline))
    PersistentDB:SetString("scope_global", stored)

    local loaded = Store.LoadScope("global")
    luaunit.assertEquals(loaded.entries[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(loaded.entries[1].layout, {})
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), stored)
end

function TestStore:testAnUnreadableScopeKeyIsNotOverwrittenOrReplacedByTheOldDocument()
    local legacy = LibNodeGraph.Json.Default.encode({
        version = 2,
        entries = { {
            id = 1,
            kind = "alert",
            name = "legacy",
            enabled = true,
            graph = { version = 1, nodes = {}, connections = {} },
            layout = {},
        } },
        infoboxAnchor = nil,
    })
    local corrupt = "{not-a-token"
    PersistentDB:SetString("global", legacy)
    PersistentDB:SetString("scope_global", corrupt)

    local loaded, _, problem = Store.LoadScope("global")
    luaunit.assertEquals(problem, "unreadable")
    luaunit.assertEquals(loaded.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), corrupt)
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)

    local doc = Store.Empty()
    local id = seedAlert(self, doc, "new", true)
    luaunit.assertFalse(Store.SaveScope("global", doc))
    luaunit.assertFalse(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), corrupt)
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    luaunit.assertNil(PersistentDB:GetString("scope_global_alert_" .. id))

    local player = Store.Empty()
    Store.InsertEntry(player, Store.NewAlertEntry(1, "other", graphWithOneNode(self.registry), {}, true))
    luaunit.assertTrue(Store.SaveAlert("player_42", player.entries[1]))
    luaunit.assertTrue(Store.SaveScope("player_42", player))
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "other")
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), corrupt)
end

function TestStore:testAScopeKeyThatThrowsOnReadIsNotOverwritten()
    PersistentDB.data.scope_global = "WD1kept"
    PersistentDB.data.global = "{\"version\":2,\"entries\":[{\"name\":\"legacy\"}]}"
    function PersistentDB:GetString(key)
        if key == "scope_global" then error("unreadable") end
        return self.data[key]
    end

    local loaded, _, problem = Store.LoadScope("global")
    luaunit.assertEquals(problem, "unreadable")
    luaunit.assertEquals(loaded.entries, {})
    luaunit.assertEquals(PersistentDB.data.scope_global, "WD1kept")
    luaunit.assertEquals(PersistentDB.data.global, "{\"version\":2,\"entries\":[{\"name\":\"legacy\"}]}")

    local doc = Store.Empty()
    local id = seedAlert(self, doc, "nope", true)
    luaunit.assertFalse(Store.SaveScope("global", doc))
    luaunit.assertFalse(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertEquals(PersistentDB.data.scope_global, "WD1kept")
    luaunit.assertNil(PersistentDB.data["scope_global_alert_" .. id])
    luaunit.assertEquals(PersistentDB.data.global, "{\"version\":2,\"entries\":[{\"name\":\"legacy\"}]}")
end

function TestStore:testALegacyScopeLoadsAndSavesWhileTheNewKeyIsAbsent()
    local doc = Store.Empty()
    seedAlert(self, doc, "alpha", true)
    luaunit.assertTrue(Store.SaveTo("global", doc))
    luaunit.assertNil(PersistentDB:GetString("scope_global"))

    local loaded = Store.LoadScope("global")
    luaunit.assertEquals(loaded.entries[1].name, "alpha")
    luaunit.assertEquals(loaded.entries[1].graph.nodes[1].type, "fixture.trigger")
    loaded.entries[1].name = "renamed"
    luaunit.assertTrue(Store.SaveTo("global", loaded))
    luaunit.assertNil(PersistentDB:GetString("scope_global"))
    luaunit.assertStrContains(PersistentDB:GetString("global"), "renamed")

    luaunit.assertTrue(Store.SaveTo("player_42", doc))
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "alpha")
    luaunit.assertNil(PersistentDB:GetString("scope_player_42"))

    local displayName = PersistentDB:GetString("global")
    PersistentDB:SetString("player_ZeZima", displayName)
    local inner = PersistentDB.GetString
    function PersistentDB:GetString(key)
        if key == "player_ZeZima" then error("read a display-name key") end
        return inner(self, key)
    end
    local skipped = Store.LoadScope("player_ZeZima")
    luaunit.assertEquals(skipped.entries, {})
    luaunit.assertEquals(PersistentDB.data.player_ZeZima, displayName)
end

-- Startup migration (#185). The old key stays as the pre-migration snapshot.
-- The loaded tree is the same shape a split scope already returns.

function TestStore:testStartupMovesALegacyScopeOntoTheNewKeys()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "Horn", true)
    Store.SetInfoBoxAnchor(doc, 3, 4)
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")

    local failures = Store.MigrateListed()

    luaunit.assertEquals(failures, {})
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    local scope = decodeToken(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(scope.version, 3)
    luaunit.assertEquals(scope.entries[1].id, id)
    luaunit.assertEquals(scope.entries[1].name, "Horn")
    luaunit.assertEquals(scope.entries[1].kind, "alert")
    luaunit.assertEquals(scope.entries[1].enabled, true)
    luaunit.assertNil(scope.entries[1].graph)
    luaunit.assertNil(scope.entries[1].layout)
    luaunit.assertEquals(scope.infoboxAnchor, { x = 3, y = 4 })
    local alert = decodeToken(PersistentDB:GetString("scope_global_alert_" .. id))
    luaunit.assertEquals(alert.version, 1)
    luaunit.assertEquals(alert.graph.nodes[1].type, "fixture.trigger")
    local loaded = Store.LoadScope("global")
    luaunit.assertEquals(loaded.entries[1].name, "Horn")
    luaunit.assertEquals(loaded.entries[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(loaded.infoboxAnchor.x, 3)
    luaunit.assertEquals(loaded.infoboxAnchor.y, 4)
end

function TestStore:testAnEmptyLegacyScopeBecomesAnEmptyNewDocument()
    local legacy = LibNodeGraph.Json.Default.encode({
        version = 2,
        entries = {},
        infoboxAnchor = nil,
    })
    PersistentDB:SetString("global", legacy)

    luaunit.assertEquals(Store.MigrateListed(), {})

    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    local scope = decodeToken(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(scope.version, 3)
    luaunit.assertEquals(scope.entries, {})
    luaunit.assertNotEquals(PersistentDB:GetString("scope_global"), "")
    local loaded = Store.LoadScope("global")
    luaunit.assertEquals(loaded.entries, {})
    -- The new key is what a later startup reads. Putting alerts back on the
    -- old key must not bring them into the loaded tree.
    PersistentDB:SetString("global", LibNodeGraph.Json.Default.encode({
        version = 2,
        entries = { {
            id = 1,
            kind = "alert",
            name = "came back",
            enabled = true,
            graph = { version = 1, nodes = {}, connections = {} },
            layout = {},
        } },
    }))
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
    luaunit.assertEquals(Store.MigrateListed(), {})
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
end

function TestStore:testAnUnreadableLegacyScopeDoesNotCreateTheNewKey()
    local legacy = "{not-a-document"
    PersistentDB:SetString("global", legacy)

    luaunit.assertEquals(Store.MigrateListed(), {})

    luaunit.assertNil(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
end

function TestStore:testAScopeMigratesOnlyWhenEveryAlertFits()
    local doc = Store.Empty()
    seedAlert(self, doc, "Horn", true)
    seedAlert(self, doc, "Essay", true)
    doc.entries[2].graph.nodes[1].controls = { text = incompressible(200000) }
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")
    local wroteLegacy = false
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        if key == "global" then wroteLegacy = true end
        return inner(self, key, value)
    end

    local failures = Store.MigrateListed()

    luaunit.assertEquals(#failures, 1)
    luaunit.assertEquals(failures[1].identity, "global")
    luaunit.assertEquals(failures[1].reason, "size")
    luaunit.assertEquals(failures[1].name, "Essay")
    luaunit.assertFalse(wroteLegacy)
    luaunit.assertNil(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    local loaded = Store.LoadScope("global")
    luaunit.assertEquals(loaded.entries[1].name, "Horn")
    luaunit.assertEquals(loaded.entries[2].name, "Essay")
    luaunit.assertEquals(#loaded.entries[2].graph.nodes[1].controls.text, 200000)
end

function TestStore:testAnAlertAddedBesideOneThatCannotBeStoredIsNotPersisted()
    local doc = Store.Empty()
    seedAlert(self, doc, "Horn", true)
    seedAlert(self, doc, "Essay", true)
    doc.entries[2].graph.nodes[1].controls = { text = incompressible(200000) }
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")
    luaunit.assertEquals(#Store.MigrateListed(), 1)

    local loaded = Store.LoadScope("global")
    local extra = seedAlert(self, loaded, "Extra", true)
    local ok, reason, name = Store.PersistScope("global", loaded)

    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "size")
    luaunit.assertEquals(name, "Essay")
    luaunit.assertNil(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    luaunit.assertNil(PersistentDB:GetString("scope_global_alert_" .. extra))
    luaunit.assertEquals(#Store.LoadScope("global").entries, 2)

    loaded.entries[2].graph.nodes[1].controls = { text = "short" }
    luaunit.assertTrue(Store.PersistScope("global", loaded))
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    local again = Store.LoadScope("global")
    luaunit.assertEquals(again.entries[1].name, "Horn")
    luaunit.assertEquals(again.entries[2].name, "Essay")
    luaunit.assertEquals(again.entries[2].graph.nodes[1].controls.text, "short")
    luaunit.assertEquals(again.entries[3].name, "Extra")
    luaunit.assertEquals(again.entries[3].graph.nodes[1].type, "fixture.trigger")
end

function TestStore:testStartupListsKeysBeforeItMigratesCharacters()
    local function legacyDoc(name)
        return LibNodeGraph.Json.Default.encode({
            version = 2,
            entries = { {
                id = 1,
                kind = "alert",
                name = name,
                enabled = true,
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
            } },
        })
    end
    PersistentDB:SetString("global", legacyDoc("Global"))
    PersistentDB:SetString("player_42", legacyDoc("Hero"))
    PersistentDB:SetString("player_7", legacyDoc("Alt"))
    PersistentDB:SetString("player_ZeZima", legacyDoc("Display"))
    PersistentDB:SetString("presets", legacyDoc("Not a scope"))
    local globalLegacy = PersistentDB:GetString("global")
    local heroLegacy = PersistentDB:GetString("player_42")
    local altLegacy = PersistentDB:GetString("player_7")
    local displayLegacy = PersistentDB.data.player_ZeZima
    local presetsLegacy = PersistentDB:GetString("presets")

    local iterating = false
    local wroteDuringList = false
    local listed = false
    function PersistentDB:IterateEntries(callback)
        listed = true
        iterating = true
        local keys = {}
        for key in pairs(self.data) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            if callback(key, self.data[key]) == true then break end
        end
        iterating = false
        return #keys
    end
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        if iterating then wroteDuringList = true end
        return inner(self, key, value)
    end
    local innerGet = PersistentDB.GetString
    function PersistentDB:GetString(key)
        if key == "player_ZeZima" then error("read a display-name key") end
        return innerGet(self, key)
    end

    local failures = Store.MigrateListed()

    luaunit.assertEquals(failures, {})
    luaunit.assertTrue(listed)
    luaunit.assertFalse(wroteDuringList)
    luaunit.assertEquals(PersistentDB:GetString("global"), globalLegacy)
    luaunit.assertEquals(PersistentDB:GetString("player_42"), heroLegacy)
    luaunit.assertEquals(PersistentDB:GetString("player_7"), altLegacy)
    luaunit.assertEquals(PersistentDB.data.player_ZeZima, displayLegacy)
    luaunit.assertEquals(PersistentDB:GetString("presets"), presetsLegacy)
    luaunit.assertNil(PersistentDB:GetString("scope_player_ZeZima"))
    local heroScope = decodeToken(PersistentDB:GetString("scope_player_42"))
    luaunit.assertEquals(heroScope.version, 3)
    luaunit.assertEquals(heroScope.entries[1].name, "Hero")
    luaunit.assertNil(heroScope.entries[1].graph)
    luaunit.assertEquals(decodeToken(PersistentDB:GetString("scope_player_42_alert_1")).graph.version, 1)
    local altScope = decodeToken(PersistentDB:GetString("scope_player_7"))
    luaunit.assertEquals(altScope.version, 3)
    luaunit.assertEquals(altScope.entries[1].name, "Alt")
    luaunit.assertEquals(Store.LoadScope("global").entries[1].name, "Global")
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "Hero")
    luaunit.assertEquals(Store.LoadScope("player_7").entries[1].name, "Alt")
    luaunit.assertEquals(Store.LoadScope("player_ZeZima").entries, {})
end

function TestStore:testAFailedKeyListStillMigratesGlobalAndTheKnownCharacter()
    local function legacyDoc(name)
        return LibNodeGraph.Json.Default.encode({
            version = 2,
            entries = { {
                id = 1,
                kind = "alert",
                name = name,
                enabled = true,
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
            } },
        })
    end
    PersistentDB:SetString("global", legacyDoc("Global"))
    PersistentDB:SetString("player_42", legacyDoc("Hero"))
    local globalLegacy = PersistentDB:GetString("global")
    local heroLegacy = PersistentDB:GetString("player_42")
    function PersistentDB:IterateEntries() error("list failed") end

    luaunit.assertEquals(Store.MigrateListed(), {})

    luaunit.assertEquals(PersistentDB:GetString("global"), globalLegacy)
    luaunit.assertEquals(decodeToken(PersistentDB:GetString("scope_global")).entries[1].name, "Global")
    luaunit.assertNil(PersistentDB:GetString("scope_player_42"))
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "Hero")

    luaunit.assertNil(Store.MigrateScope("player_42"))

    luaunit.assertEquals(PersistentDB:GetString("player_42"), heroLegacy)
    luaunit.assertEquals(decodeToken(PersistentDB:GetString("scope_player_42")).entries[1].name, "Hero")
    luaunit.assertNil(decodeToken(PersistentDB:GetString("scope_player_42")).entries[1].graph)
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "Hero")
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].graph.version, 1)
end

function TestStore:testAFailedCharacterMigrationIsLoggedAndDoesNotStopTheNext()
    local function legacyDoc(name, text)
        return LibNodeGraph.Json.Default.encode({
            version = 2,
            entries = { {
                id = 1,
                kind = "alert",
                name = name,
                enabled = true,
                graph = {
                    version = 1,
                    nodes = { {
                        id = 1,
                        type = "fixture.trigger",
                        controls = { text = text },
                    } },
                    connections = {},
                },
                layout = {},
            } },
        })
    end
    PersistentDB:SetString("player_1", legacyDoc("Essay", incompressible(200000)))
    PersistentDB:SetString("player_2", legacyDoc("Horn", "ok"))
    local essayLegacy = PersistentDB:GetString("player_1")
    local hornLegacy = PersistentDB:GetString("player_2")
    function PersistentDB:IterateEntries(callback)
        callback("player_1")
        callback("player_2")
    end
    local lines = {}
    log = function(message) lines[#lines + 1] = message end

    local failures = Store.MigrateListed()
    log = nil

    luaunit.assertEquals(#failures, 1)
    luaunit.assertEquals(failures[1].identity, "player_1")
    luaunit.assertEquals(failures[1].reason, "size")
    luaunit.assertEquals(failures[1].name, "Essay")
    luaunit.assertNil(PersistentDB:GetString("scope_player_1"))
    luaunit.assertEquals(PersistentDB:GetString("player_1"), essayLegacy)
    luaunit.assertEquals(PersistentDB:GetString("player_2"), hornLegacy)
    luaunit.assertEquals(decodeToken(PersistentDB:GetString("scope_player_2")).entries[1].name, "Horn")
    local joined = table.concat(lines, "\n")
    luaunit.assertStrContains(joined, "could not migrate")
    luaunit.assertStrContains(joined, "player_1")
end

function TestStore:testPersistingAnUnreadEmptyScopeDoesNotInventTheNewKey()
    luaunit.assertTrue(Store.PersistScope("global", Store.Empty()))
    luaunit.assertNil(PersistentDB:GetString("scope_global"))
    luaunit.assertNil(PersistentDB:GetString("global"))

    PersistentDB:SetString("global", "{not-a-document")
    local ok = Store.PersistScope("global", Store.Empty())
    luaunit.assertFalse(ok)
    luaunit.assertNil(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(PersistentDB:GetString("global"), "{not-a-document")
end

function TestStore:testDeletingEveryLegacyAlertLeavesAnEmptyNewDocument()
    local doc = Store.Empty()
    seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")
    local loaded = Store.LoadScope("global")
    loaded.entries = {}

    luaunit.assertTrue(Store.PersistScope("global", loaded))

    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    local scope = decodeToken(PersistentDB:GetString("scope_global"))
    luaunit.assertEquals(scope.version, 3)
    luaunit.assertEquals(scope.entries, {})
    luaunit.assertNotEquals(PersistentDB:GetString("scope_global"), "")
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
    luaunit.assertEquals(Store.MigrateListed(), {})
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
end

function TestStore:testMigrationDoesNotReplaceAnUnreadableNewScopeKey()
    local doc = Store.Empty()
    seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")
    PersistentDB:SetString("scope_global", "{nope")

    luaunit.assertEquals(Store.MigrateListed(), {})

    luaunit.assertEquals(PersistentDB:GetString("scope_global"), "{nope")
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    local loaded, _, problem = Store.LoadScope("global")
    luaunit.assertEquals(problem, "unreadable")
    luaunit.assertEquals(loaded.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), "{nope")
end

function TestStore:testAScopeTreeThatDoesNotFitIsRefusedEveryTime()
    local doc = Store.Empty()
    seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")
    luaunit.assertEquals(Store.MigrateListed(), {})
    local scopeBefore = PersistentDB:GetString("scope_global")
    local alertBefore = PersistentDB:GetString("scope_global_alert_1")
    local loaded = Store.LoadScope("global")
    loaded.entries[1].name = incompressible(200000)

    local ok, reason = Store.PersistScope("global", loaded)
    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "size")
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), scopeBefore)
    luaunit.assertEquals(decodeToken(PersistentDB:GetString("scope_global_alert_1")).graph, decodeToken(alertBefore).graph)
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)

    ok, reason = Store.PersistScope("global", loaded)
    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "size")
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), scopeBefore)
    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    luaunit.assertEquals(#loaded.entries[1].name, 200000)
end

-- An edit removes an alert from the tree before its key goes. A crash between
-- those two writes leaves an orphan, which load ignores. It does not leave a
-- tree row whose graph was already deleted.

function TestStore:testRemovingAnAlertWritesTheTreeBeforeDeletingItsKey()
    local doc = Store.Empty()
    local kept = seedAlert(self, doc, "Kept", true)
    local gone = seedAlert(self, doc, "Gone", true)
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, kept)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, gone)))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local keptBytes = PersistentDB:GetString("scope_global_alert_" .. kept)
    local order = {}
    local innerSet = PersistentDB.SetString
    local innerDelete = PersistentDB.Delete
    function PersistentDB:SetString(key, value)
        order[#order + 1] = "set:" .. key
        return innerSet(self, key, value)
    end
    function PersistentDB:Delete(key)
        order[#order + 1] = "del:" .. key
        local scope = decodeToken(self.data.scope_global)
        luaunit.assertEquals(#scope.entries, 1)
        luaunit.assertEquals(scope.entries[1].id, kept)
        return innerDelete(self, key)
    end

    local loaded = Store.LoadScope("global")
    luaunit.assertNotNil(Store.DeleteById(loaded, gone))
    luaunit.assertTrue(Store.RemoveAlerts("global", loaded, { gone }))

    luaunit.assertEquals(order, {
        "set:scope_global",
        "del:scope_global_alert_" .. gone,
    })
    luaunit.assertNil(PersistentDB:GetString("scope_global_alert_" .. gone))
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. kept), keptBytes)
    luaunit.assertNil(PersistentDB:GetString("global"))
    local again = Store.LoadScope("global")
    luaunit.assertEquals(#again.entries, 1)
    luaunit.assertEquals(again.entries[1].name, "Kept")
    luaunit.assertEquals(again.entries[1].graph.nodes[1].type, "fixture.trigger")
end

function TestStore:testAFailedTreeWriteLeavesTheAlertKey()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local scopeBefore = PersistentDB:GetString("scope_global")
    local alertBefore = PersistentDB:GetString("scope_global_alert_" .. id)
    local deletes = 0
    function PersistentDB:SetString()
        return false
    end
    function PersistentDB:Delete()
        deletes = deletes + 1
        return true
    end

    local loaded = Store.LoadScope("global")
    luaunit.assertNotNil(Store.DeleteById(loaded, id))
    local ok, reason = Store.RemoveAlerts("global", loaded, { id })

    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "failed")
    luaunit.assertEquals(deletes, 0)
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), scopeBefore)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), alertBefore)
    local again = Store.LoadScope("global")
    luaunit.assertEquals(again.entries[1].name, "Horn")
    luaunit.assertEquals(again.entries[1].graph.nodes[1].type, "fixture.trigger")
end

function TestStore:testAFailedAlertKeyDeleteLeavesAnOrphanAndDropsTheRow()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local alertBefore = PersistentDB:GetString("scope_global_alert_" .. id)
    local lines = {}
    log = function(message) lines[#lines + 1] = message end
    function PersistentDB:Delete()
        return false
    end

    local loaded = Store.LoadScope("global")
    luaunit.assertNotNil(Store.DeleteById(loaded, id))
    local ok = Store.RemoveAlerts("global", loaded, { id })
    log = nil

    luaunit.assertTrue(ok)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), alertBefore)
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
    luaunit.assertEquals(#lines, 1)
    luaunit.assertStrContains(lines[1], "scope_global_alert_" .. id)
end

function TestStore:testANilOrThrownDeleteLeavesTheAlertKey()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local alertBefore = PersistentDB:GetString("scope_global_alert_" .. id)

    local loaded = Store.LoadScope("global")
    luaunit.assertNotNil(Store.DeleteById(loaded, id))
    function PersistentDB:Delete()
        return nil
    end
    luaunit.assertTrue(Store.RemoveAlerts("global", loaded, { id }))
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), alertBefore)

    function PersistentDB:Delete()
        error("rejected")
    end
    luaunit.assertTrue(Store.RemoveAlerts("global", loaded, { id }))
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), alertBefore)
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
end

function TestStore:testRemovingAGroupDeletesEveryAlertKeyInIt()
    local doc = Store.Empty()
    local outside = seedAlert(self, doc, "Outside", true)
    local groupId = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(groupId, "Folder", true, {}))
    local first = seedAlert(self, doc, "First", true, groupId)
    local second = seedAlert(self, doc, "Second", false, groupId)
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, outside)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, first)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, second)))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local outsideBytes = PersistentDB:GetString("scope_global_alert_" .. outside)

    local loaded = Store.LoadScope("global")
    luaunit.assertNotNil(Store.DeleteById(loaded, groupId))
    luaunit.assertTrue(Store.RemoveAlerts("global", loaded, { first, second }))

    luaunit.assertNil(PersistentDB:GetString("scope_global_alert_" .. first))
    luaunit.assertNil(PersistentDB:GetString("scope_global_alert_" .. second))
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. outside), outsideBytes)
    local again = Store.LoadScope("global")
    luaunit.assertEquals(#again.entries, 1)
    luaunit.assertEquals(again.entries[1].name, "Outside")
    luaunit.assertEquals(again.entries[1].graph.nodes[1].type, "fixture.trigger")
end

-- Destination key, then the tree that names it, then the source tree, then
-- the source key. Stopping early can leave an orphan or a copy in both
-- scopes. It cannot delete a graph the source tree still names.

function TestStore:testAMoveWritesTheDestinationBeforeDeletingTheSource()
    local src = Store.Empty()
    local kept = seedAlert(self, src, "Kept", true)
    local moved = seedAlert(self, src, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(src, kept)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(src, moved)))
    luaunit.assertTrue(Store.SaveScope("global", src))
    local dest = Store.Empty()
    local staying = seedAlert(self, dest, "Stay", true)
    luaunit.assertTrue(Store.SaveAlert("player_42", dest.entries[1]))
    luaunit.assertTrue(Store.SaveScope("player_42", dest))
    local keptBytes = PersistentDB:GetString("scope_global_alert_" .. kept)
    local stayBytes = PersistentDB:GetString("scope_player_42_alert_" .. staying)

    local order = {}
    local innerSet = PersistentDB.SetString
    local innerDelete = PersistentDB.Delete
    function PersistentDB:SetString(key, value)
        order[#order + 1] = "set:" .. key
        return innerSet(self, key, value)
    end
    function PersistentDB:Delete(key)
        order[#order + 1] = "del:" .. key
        local source = decodeToken(self.data.scope_global)
        luaunit.assertEquals(#source.entries, 1)
        luaunit.assertEquals(source.entries[1].id, kept)
        local destination = decodeToken(self.data.scope_player_42)
        luaunit.assertEquals(destination.entries[1].name, "Stay")
        luaunit.assertEquals(destination.entries[2].id, moved)
        luaunit.assertNotNil(self.data["scope_player_42_alert_" .. moved])
        return innerDelete(self, key)
    end

    local loadedSrc = Store.LoadScope("global")
    local loadedDest = Store.LoadScope("player_42")
    local entry = Store.MoveEntryToBucket(loadedSrc, loadedDest, moved)
    luaunit.assertTrue(Store.TransferAlerts(
        "global", loadedSrc, "player_42", loadedDest, { entry }, { moved }))

    luaunit.assertEquals(order, {
        "set:scope_player_42_alert_" .. moved,
        "set:scope_player_42",
        "set:scope_global",
        "del:scope_global_alert_" .. moved,
    })
    luaunit.assertNil(PersistentDB:GetString("scope_global_alert_" .. moved))
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. kept), keptBytes)
    luaunit.assertEquals(PersistentDB:GetString("scope_player_42_alert_" .. staying), stayBytes)
    luaunit.assertNil(PersistentDB:GetString("global"))
    luaunit.assertNil(PersistentDB:GetString("player_42"))
    local source = Store.LoadScope("global")
    luaunit.assertEquals(#source.entries, 1)
    luaunit.assertEquals(source.entries[1].name, "Kept")
    local destination = Store.LoadScope("player_42")
    luaunit.assertEquals(destination.entries[1].name, "Stay")
    luaunit.assertEquals(destination.entries[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(destination.entries[2].name, "Horn")
    luaunit.assertEquals(destination.entries[2].graph.nodes[1].type, "fixture.trigger")
end

function TestStore:testAMoveThatCannotStoreTheGraphLeavesTheSourceUntouched()
    local src = Store.Empty()
    local moved = seedAlert(self, src, "Essay", true)
    luaunit.assertTrue(Store.SaveAlert("global", src.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", src))
    local dest = Store.Empty()
    seedAlert(self, dest, "Stay", true)
    luaunit.assertTrue(Store.SaveAlert("player_42", dest.entries[1]))
    luaunit.assertTrue(Store.SaveScope("player_42", dest))
    local sourceScope = PersistentDB:GetString("scope_global")
    local sourceAlert = PersistentDB:GetString("scope_global_alert_" .. moved)
    local destScope = PersistentDB:GetString("scope_player_42")
    local stayAlert = PersistentDB:GetString("scope_player_42_alert_1")
    local deletes = 0
    function PersistentDB:Delete()
        deletes = deletes + 1
        return true
    end

    local loadedSrc = Store.LoadScope("global")
    local loadedDest = Store.LoadScope("player_42")
    local entry = Store.MoveEntryToBucket(loadedSrc, loadedDest, moved)
    entry.graph.nodes[1].controls = { text = incompressible(200000) }
    local ok, reason, name = Store.TransferAlerts(
        "global", loadedSrc, "player_42", loadedDest, { entry }, { moved })

    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "size")
    luaunit.assertEquals(name, "Essay")
    luaunit.assertEquals(deletes, 0)
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), sourceScope)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. moved), sourceAlert)
    luaunit.assertEquals(PersistentDB:GetString("scope_player_42"), destScope)
    luaunit.assertEquals(PersistentDB:GetString("scope_player_42_alert_1"), stayAlert)
    luaunit.assertNil(PersistentDB:GetString("scope_player_42_alert_" .. entry.id))
    luaunit.assertEquals(#entry.graph.nodes[1].controls.text, 200000)
    luaunit.assertEquals(Store.LoadScope("global").entries[1].name, "Essay")
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "Stay")
end

function TestStore:testAFailedDestinationTreeLeavesTheSourceGraphInPlace()
    local src = Store.Empty()
    local moved = seedAlert(self, src, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", src.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", src))
    local dest = Store.Empty()
    luaunit.assertTrue(Store.SaveScope("player_42", dest))
    local sourceScope = PersistentDB:GetString("scope_global")
    local sourceAlert = PersistentDB:GetString("scope_global_alert_" .. moved)
    local destScope = PersistentDB:GetString("scope_player_42")
    local deletes = 0
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        if key == "scope_player_42" then return false end
        return inner(self, key, value)
    end
    function PersistentDB:Delete()
        deletes = deletes + 1
        return true
    end

    local loadedSrc = Store.LoadScope("global")
    local loadedDest = Store.LoadScope("player_42")
    local entry = Store.MoveEntryToBucket(loadedSrc, loadedDest, moved)
    local ok, reason = Store.TransferAlerts(
        "global", loadedSrc, "player_42", loadedDest, { entry }, { moved })

    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "failed")
    luaunit.assertEquals(deletes, 0)
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), sourceScope)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. moved), sourceAlert)
    luaunit.assertEquals(PersistentDB:GetString("scope_player_42"), destScope)
    luaunit.assertNotNil(PersistentDB:GetString("scope_player_42_alert_" .. moved))
    luaunit.assertEquals(Store.LoadScope("global").entries[1].name, "Horn")
    luaunit.assertEquals(Store.LoadScope("player_42").entries, {})
end

function TestStore:testAFailedSourceTreeLeavesTheAlertInBothScopes()
    local src = Store.Empty()
    local moved = seedAlert(self, src, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", src.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", src))
    local dest = Store.Empty()
    luaunit.assertTrue(Store.SaveScope("player_42", dest))
    local sourceScope = PersistentDB:GetString("scope_global")
    local sourceAlert = PersistentDB:GetString("scope_global_alert_" .. moved)
    local deletes = 0
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        if key == "scope_global" then return false end
        return inner(self, key, value)
    end
    function PersistentDB:Delete()
        deletes = deletes + 1
        return true
    end

    local loadedSrc = Store.LoadScope("global")
    local loadedDest = Store.LoadScope("player_42")
    local entry = Store.MoveEntryToBucket(loadedSrc, loadedDest, moved)
    local ok, reason = Store.TransferAlerts(
        "global", loadedSrc, "player_42", loadedDest, { entry }, { moved })

    luaunit.assertFalse(ok)
    luaunit.assertEquals(reason, "failed")
    luaunit.assertEquals(deletes, 0)
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), sourceScope)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. moved), sourceAlert)
    luaunit.assertEquals(Store.LoadScope("global").entries[1].name, "Horn")
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "Horn")
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].graph.nodes[1].type, "fixture.trigger")
end

function TestStore:testAFailedSourceDeleteLeavesAnOrphanAndKeepsTheDestination()
    local src = Store.Empty()
    local moved = seedAlert(self, src, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", src.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", src))
    local dest = Store.Empty()
    luaunit.assertTrue(Store.SaveScope("player_42", dest))
    local sourceAlert = PersistentDB:GetString("scope_global_alert_" .. moved)
    function PersistentDB:Delete()
        return false
    end

    local loadedSrc = Store.LoadScope("global")
    local loadedDest = Store.LoadScope("player_42")
    local entry = Store.MoveEntryToBucket(loadedSrc, loadedDest, moved)
    local ok = Store.TransferAlerts(
        "global", loadedSrc, "player_42", loadedDest, { entry }, { moved })

    luaunit.assertTrue(ok)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. moved), sourceAlert)
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].name, "Horn")
    luaunit.assertEquals(Store.LoadScope("player_42").entries[1].graph.nodes[1].type, "fixture.trigger")
end

function TestStore:testAMoveThatRemintsDeletesTheOldIdAndKeepsTheDestinationId()
    local src = Store.Empty()
    seedAlert(self, src, "Horn", true)
    src.entries[1].graph.nodes[1].name = "from global"
    luaunit.assertTrue(Store.SaveAlert("global", src.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", src))
    local dest = Store.Empty()
    seedAlert(self, dest, "Stay", true)
    luaunit.assertTrue(Store.SaveAlert("player_42", dest.entries[1]))
    luaunit.assertTrue(Store.SaveScope("player_42", dest))
    local stayBytes = PersistentDB:GetString("scope_player_42_alert_1")

    local loadedSrc = Store.LoadScope("global")
    local loadedDest = Store.LoadScope("player_42")
    local entry = Store.MoveEntryToBucket(loadedSrc, loadedDest, 1)
    luaunit.assertEquals(entry.id, 2)
    luaunit.assertTrue(Store.TransferAlerts(
        "global", loadedSrc, "player_42", loadedDest, { entry }, { 1 }))

    luaunit.assertNil(PersistentDB:GetString("scope_global_alert_1"))
    luaunit.assertEquals(PersistentDB:GetString("scope_player_42_alert_1"), stayBytes)
    luaunit.assertEquals(decodeToken(PersistentDB:GetString("scope_player_42_alert_2")).graph.nodes[1].name, "from global")
    luaunit.assertEquals(Store.LoadScope("global").entries, {})
    local destination = Store.LoadScope("player_42")
    luaunit.assertEquals(destination.entries[1].name, "Stay")
    luaunit.assertNil(destination.entries[1].graph.nodes[1].name)
    luaunit.assertEquals(destination.entries[2].id, 2)
    luaunit.assertEquals(destination.entries[2].graph.nodes[1].name, "from global")
end

function TestStore:testAnEditedAlertOnASplitScopeWritesOnlyThatKey()
    local doc = Store.Empty()
    local kept = seedAlert(self, doc, "Kept", true)
    local edited = seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, kept)))
    luaunit.assertTrue(Store.SaveAlert("global", Store.FindById(doc, edited)))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local keptBytes = PersistentDB:GetString("scope_global_alert_" .. kept)
    local scopeBytes = PersistentDB:GetString("scope_global")
    doc.entries[2].graph.nodes[1].controls = { text = "edited" }
    local writes = {}
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        writes[key] = (writes[key] or 0) + 1
        return inner(self, key, value)
    end

    luaunit.assertTrue(Store.SaveEditedAlert("global", doc, doc.entries[2]))

    luaunit.assertEquals(writes["scope_global_alert_" .. edited], 1)
    luaunit.assertNil(writes["scope_global_alert_" .. kept])
    luaunit.assertNil(writes.scope_global)
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. kept), keptBytes)
    luaunit.assertEquals(PersistentDB:GetString("scope_global"), scopeBytes)
    local loaded = Store.LoadScope("global")
    luaunit.assertEquals(loaded.entries[1].name, "Kept")
    luaunit.assertEquals(loaded.entries[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(loaded.entries[2].graph.nodes[1].controls.text, "edited")
end

function TestStore:testAnEditWhileTheNewScopeKeyIsAbsentStoresEveryAlert()
    local doc = Store.Empty()
    local kept = seedAlert(self, doc, "Kept", true)
    local edited = seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")
    local loaded = Store.LoadScope("global")
    loaded.entries[2].graph.nodes[1].controls = { text = "edited" }

    luaunit.assertTrue(Store.SaveEditedAlert("global", loaded, loaded.entries[2]))

    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    luaunit.assertNotNil(PersistentDB:GetString("scope_global_alert_" .. kept))
    luaunit.assertNotNil(PersistentDB:GetString("scope_global_alert_" .. edited))
    local again = Store.LoadScope("global")
    luaunit.assertEquals(again.entries[1].name, "Kept")
    luaunit.assertEquals(again.entries[1].graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(again.entries[2].graph.nodes[1].controls.text, "edited")
end

function TestStore:testMovingTheInfoboxWritesOnlyTheGlobalTree()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveAlert("global", doc.entries[1]))
    luaunit.assertTrue(Store.SaveScope("global", doc))
    local alertBefore = PersistentDB:GetString("scope_global_alert_" .. id)
    Store.SetInfoBoxAnchor(doc, 8, 9)
    local writes = {}
    local inner = PersistentDB.SetString
    function PersistentDB:SetString(key, value)
        writes[key] = (writes[key] or 0) + 1
        return inner(self, key, value)
    end

    luaunit.assertTrue(Store.SaveTree("global", doc))

    luaunit.assertEquals(writes.scope_global, 1)
    luaunit.assertNil(writes["scope_global_alert_" .. id])
    luaunit.assertEquals(PersistentDB:GetString("scope_global_alert_" .. id), alertBefore)
    luaunit.assertNil(PersistentDB:GetString("global"))
    local loaded = Store.LoadScope("global")
    local x, y = Store.GetInfoBoxAnchor(loaded)
    luaunit.assertEquals({ x, y }, { 8, 9 })
    luaunit.assertEquals(loaded.entries[1].graph.nodes[1].type, "fixture.trigger")
end

function TestStore:testATreeEditWhileTheNewScopeKeyIsAbsentStoresEveryAlert()
    local doc = Store.Empty()
    local id = seedAlert(self, doc, "Horn", true)
    luaunit.assertTrue(Store.SaveTo("global", doc))
    local legacy = PersistentDB:GetString("global")
    local loaded = Store.LoadScope("global")
    loaded.entries[1].name = "Renamed"

    luaunit.assertTrue(Store.SaveTree("global", loaded))

    luaunit.assertEquals(PersistentDB:GetString("global"), legacy)
    luaunit.assertNotNil(PersistentDB:GetString("scope_global_alert_" .. id))
    local again = Store.LoadScope("global")
    luaunit.assertEquals(again.entries[1].name, "Renamed")
    luaunit.assertEquals(again.entries[1].graph.nodes[1].type, "fixture.trigger")
end

return TestStore
