-- Exercises the Alert Manager's pure tree/scope/expand logic (ui/manager.lua) — the half that
-- turns a Watchdog.Bucket tree into a flat visible-row list, tracks per-scope collapse state, and
-- resolves the active scope against the injected provider. The mount/render half is client-only
-- (ui.*) and not unit-testable here, exactly like the Editor's Canvas mount; but every decision the
-- renderer reads — row order, indent depth, chevron/child-count, active tab, double-click open — is
-- driven from this pure layer, so it is all assertable headless with a fake scope provider.
--
-- Client/UI globals ui/manager builds constants from at load time (via its Theme require) — stubbed
-- minimally so the module loads under a standalone interpreter.
_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local Manager = require("ui/manager")

-- Bucket/Entry builders mirroring store.lua's shapes (the Manager only reads them).
local function alert(id, name, enabled)
    return { id = id, kind = "alert", name = name, enabled = enabled ~= false }
end
local function group(id, name, children, enabled)
    return { id = id, kind = "group", name = name, enabled = enabled ~= false, children = children or {} }
end
local function bucket(entries)
    return { version = 2, entries = entries }
end

TestManager = {}

-- A Manager over a fixed scope list, with the alert-open callback recorded so a test can prove a
-- double-click reports the right (scopeKey, id). Optional `extras` injects the #91 mutation
-- callbacks (onToggleEnabled / onRename / onDelete / onCreateAlert / onCreateGroup).
function TestManager:makeManager(scopes, extras)
    local opened = {}
    local opts = {
        scopes = function() return scopes end,
        onOpenAlert = function(scopeKey, id) opened[#opened + 1] = { scopeKey, id } end,
    }
    if extras ~= nil then
        for k, v in pairs(extras) do opts[k] = v end
    end
    local mgr = Manager.new(opts)
    return mgr, opened
end

--- Scope resolution -----------------------------------------------------------------------

function TestManager:testActiveScopeDefaultsToFirst()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    })
    luaunit.assertEquals(mgr:ActiveScopeKey(), "global")
end

function TestManager:testSetActiveScopeSelectsIt()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    })
    mgr:SetActiveScope("player_alice")
    luaunit.assertEquals(mgr:ActiveScopeKey(), "player_alice")
end

function TestManager:testActiveScopeFallsBackWhenSelectionDeparts()
    -- Selected the character tab, then the character logged out (provider now returns Global only):
    -- the active scope falls back to the first scope rather than pointing at a dead key.
    local scopes = {
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    }
    local mgr = self:makeManager(scopes)
    mgr:SetActiveScope("player_alice")
    scopes[2] = nil -- Alice logs out
    luaunit.assertEquals(mgr:ActiveScopeKey(), "global")
end

function TestManager:testNoScopesYieldsNoRows()
    local mgr = self:makeManager({})
    luaunit.assertNil(mgr:ActiveScope())
    luaunit.assertEquals(mgr:VisibleRows(), {})
end

--- Flattening: order, depth, kinds --------------------------------------------------------

function TestManager:testFlatRootAlertsInOrder()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({ alert(1, "one"), alert(2, "two") }) },
    })
    local rows = mgr:VisibleRows()
    luaunit.assertEquals(#rows, 2)
    luaunit.assertEquals(rows[1].id, 1)
    luaunit.assertEquals(rows[1].kind, "alert")
    luaunit.assertEquals(rows[1].depth, 0)
    luaunit.assertEquals(rows[2].id, 2)
end

function TestManager:testGroupChildrenNestWithDepthAndCount()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), alert(3, "b") }),
        alert(4, "root-alert"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local rows = mgr:VisibleRows()
    -- Pre-order: group, its two children (depth 1), then the root-level alert.
    luaunit.assertEquals(#rows, 4)
    luaunit.assertEquals(rows[1].kind, "group")
    luaunit.assertEquals(rows[1].depth, 0)
    luaunit.assertEquals(rows[1].childCount, 2)
    luaunit.assertEquals(rows[1].expanded, true)     -- groups default expanded
    luaunit.assertEquals(rows[2].id, 2)
    luaunit.assertEquals(rows[2].depth, 1)
    luaunit.assertEquals(rows[3].id, 3)
    luaunit.assertEquals(rows[3].depth, 1)
    luaunit.assertEquals(rows[4].id, 4)
    luaunit.assertEquals(rows[4].depth, 0)
end

function TestManager:testNestedGroupsDeepenDepth()
    local doc = bucket({
        group(1, "outer", { group(2, "inner", { alert(3, "leaf") }) }),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local rows = mgr:VisibleRows()
    luaunit.assertEquals(#rows, 3)
    luaunit.assertEquals(rows[1].depth, 0)
    luaunit.assertEquals(rows[2].depth, 1)
    luaunit.assertEquals(rows[3].depth, 2)
    luaunit.assertEquals(rows[3].id, 3)
end

--- Expand / collapse ----------------------------------------------------------------------

function TestManager:testCollapseHidesSubtree()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), group(3, "h", { alert(4, "b") }) }),
        alert(5, "tail"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    luaunit.assertEquals(#mgr:VisibleRows(), 5) -- all expanded by default

    mgr:ToggleExpand("global", 1) -- collapse the outer group
    local rows = mgr:VisibleRows()
    -- Only the collapsed group row and the tail alert remain; the whole subtree is gone.
    luaunit.assertEquals(#rows, 2)
    luaunit.assertEquals(rows[1].id, 1)
    luaunit.assertEquals(rows[1].expanded, false)
    luaunit.assertEquals(rows[2].id, 5)
end

function TestManager:testToggleIsPerScope()
    -- Collapsing group id 1 in Global must not collapse a same-id group in the character scope.
    local g = bucket({ group(1, "g", { alert(2, "a") }) })
    local p = bucket({ group(1, "p", { alert(2, "b") }) })
    local scopes = {
        { key = "global", label = "Global", doc = g },
        { key = "player_alice", label = "Alice", doc = p },
    }
    local mgr = self:makeManager(scopes)
    mgr:ToggleExpand("global", 1)
    luaunit.assertEquals(mgr:IsExpanded("global", 1), false)
    luaunit.assertEquals(mgr:IsExpanded("player_alice", 1), true)
end

function TestManager:testToggleBumpsSignature()
    local doc = bucket({ group(1, "g", { alert(2, "a") }) })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local before = mgr:_signature()
    mgr:ToggleExpand("global", 1)
    luaunit.assertNotEquals(mgr:_signature(), before)
end

--- Row activation (double-click open / group toggle) --------------------------------------

function TestManager:testActivateAlertRowReportsOpen()
    local doc = bucket({ alert(7, "a") })
    local mgr, opened = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local row = mgr:VisibleRows()[1]
    mgr:_activateRow("global", row)
    luaunit.assertEquals(opened, { { "global", 7 } })
end

function TestManager:testActivateGroupRowTogglesInsteadOfOpening()
    local doc = bucket({ group(9, "g", { alert(1, "a") }) })
    local mgr, opened = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local row = mgr:VisibleRows()[1]
    mgr:_activateRow("global", row)
    luaunit.assertEquals(opened, {})                 -- a group never opens the editor
    luaunit.assertEquals(mgr:IsExpanded("global", 9), false)
end

function TestManager:testActivateReportsCharacterScopeKey()
    local doc = bucket({ alert(3, "a") })
    local mgr, opened = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = doc },
    })
    mgr:SetActiveScope("player_alice")
    local row = mgr:VisibleRows()[1]
    mgr:_activateRow("player_alice", row)
    luaunit.assertEquals(opened, { { "player_alice", 3 } })
end

--- Row label rendering --------------------------------------------------------------------

function TestManager:testRowLabelAlert()
    local mgr = self:makeManager({})
    local label = mgr:RowLabel({ id = 1, name = "Boss timer", kind = "alert", depth = 0 })
    luaunit.assertStrContains(label, "Boss timer")
    luaunit.assertStrContains(label, "•")
end

function TestManager:testRowLabelGroupShowsChevronAndCount()
    local mgr = self:makeManager({})
    local open = mgr:RowLabel({ id = 1, name = "PvM", kind = "group", depth = 0, childCount = 3, expanded = true })
    luaunit.assertStrContains(open, "▾")
    luaunit.assertStrContains(open, "PvM")
    luaunit.assertStrContains(open, "(3)")
    local closed = mgr:RowLabel({ id = 1, name = "PvM", kind = "group", depth = 0, childCount = 3, expanded = false })
    luaunit.assertStrContains(closed, "▸")
end

function TestManager:testRowLabelIndentsByDepth()
    local mgr = self:makeManager({})
    local shallow = mgr:RowLabel({ id = 1, name = "x", kind = "alert", depth = 0 })
    local deep = mgr:RowLabel({ id = 1, name = "x", kind = "alert", depth = 2 })
    luaunit.assertTrue(#deep > #shallow) -- deeper rows carry more leading indent
end

--- Row editing ops (#91): host callbacks + signature bump ---------------------------------
-- Manager mutations go through injected host callbacks (main.lua wires Store + Runtime). The
-- pure half only reports the op + bumps mutateVersion so the view rebuilds; the host mutates
-- the shared Bucket doc the scopes provider already returns.

function TestManager:testToggleEnabledReportsActiveScopeAndId()
    local calls = {}
    local doc = bucket({ alert(7, "a", true) })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onToggleEnabled = function(scopeKey, id) calls[#calls + 1] = { scopeKey, id } end }
    )
    local before = mgr:_signature()
    mgr:ToggleEnabled(7)
    luaunit.assertEquals(calls, { { "global", 7 } })
    luaunit.assertNotEquals(mgr:_signature(), before)
end

function TestManager:testRenameReportsActiveScopeIdAndName()
    local calls = {}
    local doc = bucket({ alert(3, "old") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onRename = function(scopeKey, id, name) calls[#calls + 1] = { scopeKey, id, name } end }
    )
    mgr:Rename(3, "new")
    luaunit.assertEquals(calls, { { "global", 3, "new" } })
end

function TestManager:testDeleteReportsActiveScopeAndId()
    local calls = {}
    local doc = bucket({ alert(5, "a") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onDelete = function(scopeKey, id) calls[#calls + 1] = { scopeKey, id } end }
    )
    mgr:Delete(5)
    luaunit.assertEquals(calls, { { "global", 5 } })
end

function TestManager:testCreateAlertReportsActiveScope()
    local calls = {}
    local mgr = self:makeManager(
        {
            { key = "global", label = "Global", doc = bucket({}) },
            { key = "player_alice", label = "Alice", doc = bucket({}) },
        },
        { onCreateAlert = function(scopeKey) calls[#calls + 1] = scopeKey end }
    )
    mgr:SetActiveScope("player_alice")
    mgr:CreateAlert()
    luaunit.assertEquals(calls, { "player_alice" })
end

function TestManager:testCreateGroupReportsActiveScope()
    local calls = {}
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({}) } },
        { onCreateGroup = function(scopeKey) calls[#calls + 1] = scopeKey end }
    )
    mgr:CreateGroup()
    luaunit.assertEquals(calls, { "global" })
end

function TestManager:testMutationNoOpsWithoutActiveScope()
    local calls = {}
    local mgr = self:makeManager({}, {
        onToggleEnabled = function() calls[#calls + 1] = "toggle" end,
        onRename = function() calls[#calls + 1] = "rename" end,
        onDelete = function() calls[#calls + 1] = "delete" end,
        onCreateAlert = function() calls[#calls + 1] = "alert" end,
        onCreateGroup = function() calls[#calls + 1] = "group" end,
    })
    mgr:ToggleEnabled(1)
    mgr:Rename(1, "x")
    mgr:Delete(1)
    mgr:CreateAlert()
    mgr:CreateGroup()
    luaunit.assertEquals(calls, {})
end

function TestManager:testHostMutationReflectedInVisibleRows()
    -- Shared-doc seam: host mutates the Bucket the provider already returns; after the Manager
    -- bumps its signature the next VisibleRows read sees the change (no Manager-owned copy).
    local doc = bucket({ alert(1, "alpha", true) })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        {
            onToggleEnabled = function(_, id)
                doc.entries[1].enabled = not doc.entries[1].enabled
            end,
            onRename = function(_, id, name)
                doc.entries[1].name = name
            end,
            onDelete = function(_, id)
                doc.entries = {}
            end,
        }
    )
    mgr:ToggleEnabled(1)
    luaunit.assertEquals(mgr:VisibleRows()[1].enabled, false)
    mgr:Rename(1, "beta")
    luaunit.assertEquals(mgr:VisibleRows()[1].name, "beta")
    mgr:Delete(1)
    luaunit.assertEquals(mgr:VisibleRows(), {})
end

function TestManager:testCreateGroupReturnsMintedIdFromHost()
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({}) } },
        { onCreateGroup = function() return 42 end }
    )
    luaunit.assertEquals(mgr:CreateGroup(), 42)
end

function TestManager:testDeleteConfirmLabelDisclosesDescendantCount()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), group(3, "inner", { alert(4, "b") }) }),
        alert(5, "leaf"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    luaunit.assertEquals(mgr:_descendantCount(1), 3) -- a + inner + b
    luaunit.assertEquals(mgr:_deleteConfirmLabel(1), "OK 3?")
    luaunit.assertEquals(mgr:_deleteConfirmLabel(5), "OK?") -- leaf: no ride-alongs
end

--- PrettyUI chrome helpers (pure; mount/render still client-only) -------------------------

function TestManager:testScopeTabsSignatureTracksKeysAndLabels()
    local scopes = {
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    }
    local mgr = self:makeManager(scopes)
    luaunit.assertEquals(mgr:_scopeTabsSignature(), "global:Global|player_alice:Alice")
    scopes[2].label = "Alicia"
    luaunit.assertEquals(mgr:_scopeTabsSignature(), "global:Global|player_alice:Alicia")
    scopes[2] = nil
    luaunit.assertEquals(mgr:_scopeTabsSignature(), "global:Global")
end

function TestManager:testActiveScopeIndexFollowsSelection()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    })
    luaunit.assertEquals(mgr:_activeScopeIndex(), 1)
    mgr:SetActiveScope("player_alice")
    luaunit.assertEquals(mgr:_activeScopeIndex(), 2)
end

--- Drop-target resolution (#92) -----------------------------------------------------------
-- Pure hit-test against flattened rows (y/h + parentId/index). Scope drops are injected by the
-- render half when the pointer is over an inactive tab (absent when logged out).

local function dropRow(id, kind, parentId, index, y, h)
    return { id = id, kind = kind, parentId = parentId, index = index, y = y, h = h or 22 }
end

function TestManager:testResolveDropTargetNestsOnGroupMiddleBand()
    local rows = {
        dropRow(1, "group", nil, 1, 0, 22),
        dropRow(2, "alert", 1, 1, 22, 22),
    }
    local t = Manager.ResolveDropTarget(11, rows, { dragId = 2 })
    luaunit.assertEquals(t.kind, "nest")
    luaunit.assertEquals(t.parentId, 1)
end

function TestManager:testResolveDropTargetReordersBeforeSibling()
    local rows = {
        dropRow(1, "alert", nil, 1, 0, 22),
        dropRow(2, "alert", nil, 2, 22, 22),
        dropRow(3, "alert", nil, 3, 44, 22),
    }
    -- Pointer in the top half of row 2 → insert before it (index 2).
    local t = Manager.ResolveDropTarget(22 + 4, rows, { dragId = 3 })
    luaunit.assertEquals(t.kind, "reorder")
    luaunit.assertNil(t.parentId)
    luaunit.assertEquals(t.index, 2)
end

function TestManager:testResolveDropTargetReordersAfterSibling()
    local rows = {
        dropRow(1, "alert", nil, 1, 0, 22),
        dropRow(2, "alert", nil, 2, 22, 22),
    }
    local t = Manager.ResolveDropTarget(22 + 18, rows, { dragId = 1 })
    luaunit.assertEquals(t.kind, "reorder")
    luaunit.assertNil(t.parentId)
    luaunit.assertEquals(t.index, 3) -- after index 2
end

function TestManager:testResolveDropTargetGroupEdgeIsReorderNotNest()
    -- Top/bottom quarters of a group row are sibling reorder, not nest.
    local rows = {
        dropRow(1, "group", nil, 1, 0, 22),
        dropRow(2, "alert", nil, 2, 22, 22),
    }
    local t = Manager.ResolveDropTarget(2, rows, { dragId = 2 }) -- top of group
    luaunit.assertEquals(t.kind, "reorder")
    luaunit.assertNil(t.parentId)
    luaunit.assertEquals(t.index, 1)
end

function TestManager:testResolveDropTargetRefusesNestIntoOwnDescendant()
    local rows = {
        dropRow(1, "group", nil, 1, 0, 22),
        dropRow(2, "group", 1, 1, 22, 22),
    }
    -- Dragging outer group onto inner's middle band would cycle — fall through to reorder.
    local t = Manager.ResolveDropTarget(22 + 11, rows, {
        dragId = 1,
        dragSubtreeIds = { [1] = true, [2] = true },
    })
    luaunit.assertEquals(t.kind, "reorder")
    luaunit.assertEquals(t.parentId, 1)
end

function TestManager:testResolveDropTargetScopeWhenInactiveTabHit()
    local rows = { dropRow(1, "alert", nil, 1, 0, 22) }
    local t = Manager.ResolveDropTarget(0, rows, { dragId = 1, scopeKey = "player_alice" })
    luaunit.assertEquals(t.kind, "scope")
    luaunit.assertEquals(t.scopeKey, "player_alice")
end

function TestManager:testResolveDropTargetNilWhenNoRows()
    luaunit.assertNil(Manager.ResolveDropTarget(10, {}, { dragId = 1 }))
end

function TestManager:testVisibleRowsCarryParentIdAndIndex()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), alert(3, "b") }),
        alert(4, "root"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local rows = mgr:VisibleRows()
    luaunit.assertEquals(rows[1].parentId, nil)
    luaunit.assertEquals(rows[1].index, 1)
    luaunit.assertEquals(rows[2].parentId, 1)
    luaunit.assertEquals(rows[2].index, 1)
    luaunit.assertEquals(rows[3].parentId, 1)
    luaunit.assertEquals(rows[3].index, 2)
    luaunit.assertEquals(rows[4].parentId, nil)
    luaunit.assertEquals(rows[4].index, 2)
end

function TestManager:testApplyDropReportsReorderToHost()
    local calls = {}
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({ alert(1, "a"), alert(2, "b") }) } },
        {
            onReorder = function(scopeKey, id, parentId, index)
                calls[#calls + 1] = { scopeKey, id, parentId, index }
            end,
        }
    )
    mgr:ApplyDrop(2, { kind = "reorder", parentId = nil, index = 1 })
    luaunit.assertEquals(calls, { { "global", 2, nil, 1 } })
end

function TestManager:testApplyDropReportsNestToHost()
    local calls = {}
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({ group(1, "g", {}), alert(2, "a") }) } },
        {
            onNest = function(scopeKey, id, parentId)
                calls[#calls + 1] = { scopeKey, id, parentId }
            end,
        }
    )
    mgr:ApplyDrop(2, { kind = "nest", parentId = 1 })
    luaunit.assertEquals(calls, { { "global", 2, 1 } })
end

function TestManager:testApplyDropReportsScopeMoveToHost()
    local calls = {}
    local mgr = self:makeManager(
        {
            { key = "global", label = "Global", doc = bucket({ alert(1, "a") }) },
            { key = "player_alice", label = "Alice", doc = bucket({}) },
        },
        {
            onMoveScope = function(fromKey, toKey, id)
                calls[#calls + 1] = { fromKey, toKey, id }
            end,
        }
    )
    mgr:ApplyDrop(1, { kind = "scope", scopeKey = "player_alice" })
    luaunit.assertEquals(calls, { { "global", "player_alice", 1 } })
end

function TestManager:testApplyDropScopeNoOpsWhenSameScope()
    local calls = {}
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({ alert(1, "a") }) } },
        { onMoveScope = function(...) calls[#calls + 1] = { ... } end }
    )
    mgr:ApplyDrop(1, { kind = "scope", scopeKey = "global" })
    luaunit.assertEquals(calls, {})
end
