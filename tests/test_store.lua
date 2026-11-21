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

-- A minimal in-memory stand-in for the client PersistentDB (string key/value store).
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

return TestStore
