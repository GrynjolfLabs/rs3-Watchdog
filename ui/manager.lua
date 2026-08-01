-- manager.lua — the Alert Manager: the second surface beside the Canvas Editor.
--
-- The management surface the F8 keybind and the LibPluginMenu button open (through the nav
-- owner in main.lua): a scope **tab bar** over a tree of Entries. Hybrid PrettyUI + native
-- `ui.Panel` (ADR-0007 + docs/alert-manager-prettyui.md): PrettyUI `Tabs` / toolbar /
-- TextField rename; native horizontal row Panels + native ren/del buttons for the tree strip.
-- NOT the Editor's Canvas — a scrolling list has neither pan nor zoom.
--
-- Window chrome (title bar, frame, drag) lives on the host Multiplexer / PrettyUI window.
-- This module mounts **content only** into an external parent (`mux:Content()`):
-- PrettyUI Tabs sized to the tab strip only + FancyButtons on tabs.root + a sibling native
-- tree Panel below the strip. Tabs must NOT fill the window height — a full-height Tabs
-- paints empty page content over the tree. Mid-session rebuild destroys tree/toolbar via
-- parent Panel; Stop/Unmount only clears Lua refs (mux window Destroy owns native teardown —
-- Destroying Tabs then the window double-frees after Show).
--
-- #90 landed the tree/scope/expand read-only cut; #91 adds the per-row editing ops; PrettyUI
-- chrome migration replaces hand-laid tab buttons and ASCII ren/del. #92 adds native row-panel
-- drag (reorder / nest / cross-scope). Multi-select is #93.
--
-- ## Two halves
--
-- The tree/scope/expand/mutation logic is **pure** (no `ui.*`): it walks a `Watchdog.Bucket`
-- into a flat list of visible rows, tracks per-scope collapse state, resolves the active scope
-- against the injected scope provider, and reports mutations through host callbacks. That half
-- is unit-tested headless (tests/test_manager.lua). The mount / render half is client-only and
-- pcall-guarded, the same split every other surface in this plugin uses.

local Theme = require("ui/theme")
local Store = require("store")

local Manager = {}
Manager.__index = Manager

-- Layout constants (content-parent-local / tab-strip-local).
-- PrettyUI Tabs uses TAB_BASELINE ≈ 42 for the tab header strip (see prettyui/src/tabs.lua).
local TAB_BASELINE = 42
local ROW_H       = 22    -- one tree row
local HANDLE_W    = 16    -- drag-grip column (prototype ⠿; ASCII "::" — RS font lacks braille)
local ENABLE_W    = 22    -- enable toggle width
local ACT_W       = 70    -- ren/del width; must fit "Rename"/"Delete" + stylesheet chrome
local ROW_GAP     = 2     -- gap between controls inside a row
local ROW_SLACK   = 4     -- keep horizontal auto-layout from wrapping the trailing actions
local PAGE_PAD    = 8     -- inset from content edge for the tree
local TOOLBAR_H   = 27    -- PrettyUI FancyButton height
local TOOLBAR_PAD = 8     -- right inset for + Alert / + Group on the tab strip
local TOOLBAR_GAP = 6     -- gap between create buttons
local TREE_TOP    = TAB_BASELINE + 4 -- tree sits below the PrettyUI tab strip

local ROW_DRAG_DELAY_TICKS = 3
local ROW_DRAG_DEAD_ZONE   = 6

local function mouseScreenPos()
    local mx, my = nil, nil
    pcall(function()
        if Mouse == nil then return end
        if Mouse.GetPosition ~= nil then
            local pos = Mouse.GetPosition()
            if pos ~= nil then
                mx, my = pos.x, pos.y
                return
            end
        end
        if Mouse.GetX ~= nil then mx = Mouse.GetX() end
        if Mouse.GetY ~= nil then my = Mouse.GetY() end
    end)
    return mx, my
end

-- Absolute screen origin of a component (Mouse is screen-space). Prefer PrettyUI's tooltip
-- context resolver; fall back to raw .x/.y (parent-local — wrong for drop math if used alone).
---@param comp ui.Component|nil
---@return number, number
local function componentScreenPos(comp)
    local x, y = 0, 0
    if comp == nil then return x, y end
    pcall(function()
        if prettyui ~= nil and prettyui.Tooltip ~= nil and prettyui.Tooltip.getContext ~= nil then
            local ctx = prettyui.Tooltip.getContext(comp)
            if ctx ~= nil and type(ctx.position) == "function" then
                local ax, ay = ctx.position(comp)
                if ax ~= nil then x = ax end
                if ay ~= nil then y = ay end
                return
            end
        end
        x = comp.x or 0
        y = comp.y or 0
    end)
    return x, y
end

-- Temporary in-client probe (#92 drag diagnosis). Read via PluginData.db key watchdog_drag_probe.
local DRAG_PROBE_KEY = "watchdog_drag_probe"
local dragProbeLog = {}
local function dragProbe(msg)
    dragProbeLog[#dragProbeLog + 1] = tostring(msg)
    if #dragProbeLog > 40 then
        table.remove(dragProbeLog, 1)
    end
    pcall(function()
        if PersistentDB ~= nil then
            PersistentDB:SetString(DRAG_PROBE_KEY, table.concat(dragProbeLog, "\n"))
        end
    end)
    if log ~= nil then
        log("Watchdog drag: " .. tostring(msg))
    end
end


-- A scope descriptor the injected provider hands back: which Bucket, how to label its tab, and its
-- tree to render. `key` is the Bucket's `PersistentDB` key (`global` / `player_<normalized>`) — the
-- same string main.lua persists and resolves live graphs under, so a row-open can round-trip it.
---@class Watchdog.ManagerScope
---@field key string                 # the Bucket key ("global" | "player_<normalized>")
---@field label string               # tab text ("Global" | the character's display name)
---@field doc Watchdog.Bucket        # the Bucket document whose Entry tree renders under this tab

-- One flattened visible tree row (what the pure walk produces and the view renders one-for-one).
-- A collapsed group's descendants are simply absent from the list, so the renderer needs no
-- collapse logic of its own.
---@class Watchdog.ManagerRow
---@field id integer                  # the Entry id (the key a row-open reports back)
---@field name string                 # display text
---@field kind "alert"|"group"
---@field depth integer               # 0 at root; each nesting level adds one (→ ROW_INDENT px)
---@field childCount integer|nil      # group only: number of DIRECT children
---@field expanded boolean            # group only: whether its children are shown (false for alerts)
---@field enabled boolean             # the Entry's own enabled flag (drives the row enable Check)
---@field parentId integer|nil        # parent group id, or nil at root (#92 drop target)
---@field index integer               # 1-based sibling index under parent/root (#92 reorder)

-- Geometry-enriched row for ResolveDropTarget (#92). Built from VisibleRows + layout Y.
---@class Watchdog.DropRow
---@field id integer
---@field kind "alert"|"group"
---@field parentId integer|nil
---@field index integer
---@field y number
---@field h number|nil

---A resolved drop landing for Manager drag (#92). `reorder` inserts among siblings;
---`nest` appends into a group's children; `scope` moves the subtree to another Bucket root.
---@class Watchdog.DropTarget
---@field kind "reorder"|"nest"|"scope"
---@field parentId integer|nil        # reorder/nest: destination parent (nil ⇒ root)
---@field index integer|nil           # reorder: 1-based sibling insert index
---@field scopeKey string|nil         # scope: destination Bucket key

---@class Watchdog.ResolveDropOpts
---@field dragId integer|nil
---@field dragSubtreeIds table<integer, boolean>|nil  # drag id + descendants (cycle guard)
---@field scopeKey string|nil         # inactive-tab hit → immediate scope drop

--- Construction ---------------------------------------------------------------------------

-- The Manager's whole seam onto its host: the scope provider, the alert-open callback, the
-- #91 mutation callbacks (enable / rename / delete / create), and the #92 drag callbacks
-- (reorder / nest / cross-scope). Persistence + runtime sync live in the host (main.lua);
-- the Manager only reports the op and bumps its rebuild signature.
---@class Watchdog.ManagerOpts
---@field scopes fun(): Watchdog.ManagerScope[]              # ordered scopes (Global first, character second)
---@field onOpenAlert fun(scopeKey: string, id: integer)    # nav callback for a double-clicked alert row
---@field onToggleEnabled fun(scopeKey: string, id: integer)|nil
---@field onRename fun(scopeKey: string, id: integer, name: string)|nil
---@field onDelete fun(scopeKey: string, id: integer)|nil
---@field onCreateAlert fun(scopeKey: string): integer|nil   # returns the minted alert id
---@field onCreateGroup fun(scopeKey: string): integer|nil   # returns the minted group id
---@field onReorder fun(scopeKey: string, id: integer, parentId: integer|nil, index: integer)|nil
---@field onNest fun(scopeKey: string, id: integer, parentId: integer)|nil
---@field onMoveScope fun(fromKey: string, toKey: string, id: integer)|nil

-- `scopes` is the injected scope provider: `fn() -> Watchdog.ManagerScope[]`, ordered (Global
-- first, the current character second when logged in). Called live on every rebuild so a character
-- login/logout re-tabs without the Manager caching identity. `onOpenAlert` is the nav callback
-- `fn(scopeKey, id)` fired when an alert row is double-clicked — main.lua's nav owner binds the
-- Editor to that entry. Mutation callbacks (`onToggleEnabled` / `onRename` / `onDelete` /
-- `onCreateAlert` / `onCreateGroup` / `onReorder` / `onNest` / `onMoveScope`) are the host's
-- Store+Runtime wiring; absent ⇒ the matching Manager method is a silent no-op.
---@param opts Watchdog.ManagerOpts|nil
---@return table
function Manager.new(opts)
    local self = setmetatable({
        scopesProvider = (opts and opts.scopes) or function() return {} end,
        onOpenAlert = (opts and opts.onOpenAlert) or function() end,
        onToggleEnabled = opts and opts.onToggleEnabled,
        onRename = opts and opts.onRename,
        onDelete = opts and opts.onDelete,
        onCreateAlert = opts and opts.onCreateAlert,
        onCreateGroup = opts and opts.onCreateGroup,
        onReorder = opts and opts.onReorder,
        onNest = opts and opts.onNest,
        onMoveScope = opts and opts.onMoveScope,
        activeScope = nil,          -- resolved lazily; nil ⇒ "first scope" (Global)
        expanded = {},              -- expanded[scopeKey][id] = bool; absent ⇒ default (expanded)
        expandVersion = 0,          -- bumped on every toggle, part of the rebuild signature
        mutateVersion = 0,          -- bumped on every row/create mutation (#91) so enable/rename redraw
        dragId = nil,               -- Entry id being dragged (#92), or nil when idle
        dragVisual = nil,           -- row component we reposition in Y while native drag is X-locked
        pendingScopeDrop = nil,     -- inactive-tab scope key hovered during drag (#92)
        visible = false,
        tick = 0,                   -- Logic-tick counter, for row double-click timing
        lastRowId = nil,            -- id of the previously-pressed row (double-click pairing)
        lastRowTick = -1000,
        -- Layout size only (no screen placement — host/mux owns the window chrome).
        window = {
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        -- Client-only component handles (nil until Mount); see the render half below.
        contentParent = nil,        -- external parent (mux Content / rootWindow.content)
        tabs = nil,                 -- prettyui.Tabs instance
        tabsScopeSig = nil,         -- scope key:label signature Tabs was built from
        treePanel = nil,
        toolbarButtons = {},        -- PrettyUI FancyButtons on the active tab page
        rowButtons = {},            -- native row Panels (teardown destroys children)
        rowWidgets = {},            -- PrettyUI row widgets (rename TextField uses renameField)
        lastSignature = nil,        -- last-rendered rebuild signature (skip no-op rebuilds)
        -- Inline rename: PrettyUI TextField + the Entry id it's editing, or nil when idle.
        renameField = nil,
        renameId = nil,
        -- Delete confirm (#91): Entry id awaiting confirm, or nil when idle.
        pendingDeleteId = nil,
        -- After + Group (#78): begin inline rename on this id once the row is rebuilt.
        pendingRenameId = nil,
    }, Manager)
    return self
end

--- Pure logic: scopes ---------------------------------------------------------------------

-- The live scope list from the injected provider (always at least `Global`). Guarded so a throwing
-- provider degrades to an empty list rather than taking the frame down.
---@return Watchdog.ManagerScope[]
function Manager:ScopeList()
    local ok, scopes = pcall(self.scopesProvider)
    if ok and type(scopes) == "table" then return scopes end
    return {}
end

-- The active scope descriptor: the one whose `key` matches `self.activeScope`, or the first scope
-- (Global) when nothing is selected or the selection no longer exists (its character logged out /
-- switched). Returns nil only when the provider yielded no scopes at all.
---@return Watchdog.ManagerScope|nil
function Manager:ActiveScope()
    local scopes = self:ScopeList()
    if #scopes == 0 then return nil end
    if self.activeScope ~= nil then
        for _, scope in ipairs(scopes) do
            if scope.key == self.activeScope then return scope end
        end
    end
    return scopes[1]
end

-- The active scope's Bucket key, or nil when there are no scopes. Resolves through ActiveScope so a
-- stale `self.activeScope` (a since-departed character) reports the fallen-back-to key, not the dead one.
---@return string|nil
function Manager:ActiveScopeKey()
    local scope = self:ActiveScope()
    return scope and scope.key or nil
end

-- Selects the scope tab `key` renders. Clears the double-click pairing so a click that switched
-- tabs can't accidentally pair with a row press in the newly-shown tree.
---@param key string
function Manager:SetActiveScope(key)
    self.activeScope = key
    self.lastRowId = nil
end

--- Pure logic: expand/collapse ------------------------------------------------------------

-- Whether group `id` in scope `scopeKey` is expanded. Groups default to **expanded** (an untouched
-- tree shows all its nesting and child counts on first open); a toggle records the explicit state.
---@param scopeKey string
---@param id integer
---@return boolean
function Manager:IsExpanded(scopeKey, id)
    local perScope = self.expanded[scopeKey]
    if perScope == nil or perScope[id] == nil then return true end
    return perScope[id]
end

-- Flips group `id`'s expand state in scope `scopeKey` and bumps the rebuild signature so the view
-- redraws. Read-only otherwise — no persistence; collapse state is transient session UI.
---@param scopeKey string
---@param id integer
function Manager:ToggleExpand(scopeKey, id)
    local perScope = self.expanded[scopeKey]
    if perScope == nil then
        perScope = {}
        self.expanded[scopeKey] = perScope
    end
    perScope[id] = not self:IsExpanded(scopeKey, id)
    self.expandVersion = self.expandVersion + 1
end

--- Pure logic: tree flattening ------------------------------------------------------------

-- Walks a scope's Entry tree depth-first pre-order into the flat visible-row list, honoring
-- collapse: a collapsed group contributes its own row but none of its subtree. Shared by the
-- renderer and the tests; the one place tree shape becomes screen order. `parentId`/`index` are
-- the sibling coordinates #92's drop resolver needs for reorder.
---@param self table
---@param entries Watchdog.Entry[]|nil
---@param scopeKey string
---@param depth integer
---@param parentId integer|nil
---@param out Watchdog.ManagerRow[]
local function flatten(self, entries, scopeKey, depth, parentId, out)
    for i, e in ipairs(entries or {}) do
        local isGroup = e.kind == "group"
        local expanded = isGroup and self:IsExpanded(scopeKey, e.id) or false
        out[#out + 1] = {
            id = e.id,
            name = e.name or "",
            kind = e.kind,
            depth = depth,
            childCount = isGroup and #(e.children or {}) or nil,
            expanded = expanded,
            enabled = e.enabled ~= false,
            parentId = parentId,
            index = i,
        }
        if isGroup and expanded then
            flatten(self, e.children, scopeKey, depth + 1, e.id, out)
        end
    end
    return out
end

-- The active scope's visible rows, in render order. Empty when there are no scopes or the active
-- tree is empty.
---@return Watchdog.ManagerRow[]
function Manager:VisibleRows()
    local scope = self:ActiveScope()
    if scope == nil then return {} end
    return flatten(self, (scope.doc or {}).entries, scope.key, 0, nil, {})
end

-- Pure drop-target hit-test (#92). Nearest row by vertical center; group middle band nests;
-- otherwise reorder before/after that sibling. `opts.scopeKey` (inactive tab) short-circuits to
-- a cross-scope move. Returns nil when there are no candidate rows.
---@param mouseY number
---@param rows Watchdog.DropRow[]
---@param opts Watchdog.ResolveDropOpts|nil
---@return Watchdog.DropTarget|nil
function Manager.ResolveDropTarget(mouseY, rows, opts)
    opts = opts or {}
    if opts.scopeKey ~= nil then
        return { kind = "scope", scopeKey = opts.scopeKey }
    end
    local dragId = opts.dragId
    local forbidden = opts.dragSubtreeIds or {}
    local best, bestDist = nil, math.huge
    for _, row in ipairs(rows or {}) do
        if dragId == nil or row.id ~= dragId then
            local h = row.h or Theme.MANAGER_ROW_H
            local y = row.y or 0
            local cy = y + h * 0.5
            local d = math.abs(mouseY - cy)
            if d < bestDist then
                bestDist = d
                best = row
            end
        end
    end
    if best == nil then return nil end
    local h = best.h or Theme.MANAGER_ROW_H
    local rel = (mouseY - (best.y or 0)) / h
    local lo = Theme.MANAGER_NEST_BAND_LO
    local hi = Theme.MANAGER_NEST_BAND_HI
    if best.kind == "group" and rel > lo and rel < hi and not forbidden[best.id] then
        return { kind = "nest", parentId = best.id }
    end
    local after = rel >= 0.5
    local index = after and ((best.index or 1) + 1) or (best.index or 1)
    return { kind = "reorder", parentId = best.parentId, index = index }
end

-- Collects `id` plus every descendant id into a set — the cycle guard ResolveDropTarget uses
-- so a group can't be nested under one of its own children.
---@param entry Watchdog.Entry|nil
---@param out table<integer, boolean>|nil
---@return table<integer, boolean>
local function subtreeIdSet(entry, out)
    out = out or {}
    if entry == nil then return out end
    out[entry.id] = true
    for _, child in ipairs(entry.children or {}) do
        subtreeIdSet(child, out)
    end
    return out
end

-- Applies a resolved drop for the dragged Entry `id` via host callbacks. Bumps mutateVersion so
-- the view rebuilds. No-op when there is no active scope or the target is a no-op (same scope).
---@param id integer
---@param target Watchdog.DropTarget|nil
function Manager:ApplyDrop(id, target)
    if target == nil then return end
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil then return end
    if target.kind == "reorder" then
        if self.onReorder == nil then return end
        pcall(self.onReorder, scopeKey, id, target.parentId, target.index)
    elseif target.kind == "nest" then
        if self.onNest == nil or target.parentId == nil then return end
        pcall(self.onNest, scopeKey, id, target.parentId)
        if not self:IsExpanded(scopeKey, target.parentId) then
            self:ToggleExpand(scopeKey, target.parentId)
        end
    elseif target.kind == "scope" then
        if self.onMoveScope == nil or target.scopeKey == nil then return end
        if target.scopeKey == scopeKey then return end
        pcall(self.onMoveScope, scopeKey, target.scopeKey, id)
    else
        return
    end
    self.mutateVersion = self.mutateVersion + 1
end

-- Resolves mouse screen Y + optional inactive-tab hit into a DropTarget for `dragId`, then
-- ApplyDrop. Used from ONDRAGCOMPLETE on the drag grip (client half).
-- `endY` is the ONDRAGCOMPLETE payload when the client provides it; otherwise Mouse.GetY().
---@param dragId integer
---@param endY number|nil  # unused; kept for call-site compat. Native endY is always 0.
function Manager:_completeDrag(dragId, endY)
    self.dragId = nil
    self.dragVisual = nil
    local scopeDrop = self.pendingScopeDrop
    self.pendingScopeDrop = nil
    local scope = self:ActiveScope()
    if scope == nil then
        dragProbe("complete: no scope")
        return
    end
    local mouseX, mouseY = mouseScreenPos()
    local _, treeTop = componentScreenPos(self.treePanel)
    dragProbe(string.format("complete id=%s mouse=%s,%s treeTop=%s scopeDrop=%s",
        tostring(dragId), tostring(mouseX), tostring(mouseY), tostring(treeTop), tostring(scopeDrop)))

    local subtreeIds = {}
    local found = Store.FindById(scope.doc, dragId)
    if found ~= nil then subtreeIdSet(found, subtreeIds) end

    local rows = {}
    local visible = self:VisibleRows()
    local scroll = 0
    pcall(function()
        local tp = self.treePanel
        if tp == nil then return end
        local getter = rawget(tp, "GetScrollPos")
        if type(getter) == "function" then
            scroll = getter(tp) or 0
        else
            local sy = rawget(tp, "scrollY")
            if type(sy) == "number" then scroll = sy end
        end
    end)
    local localY = mouseY or 0
    if mouseY ~= nil and treeTop ~= nil then
        localY = mouseY - treeTop + scroll
    end
    dragProbe(string.format("localY=%.1f scroll=%s", localY, tostring(scroll)))
    for i, row in ipairs(visible) do
        rows[#rows + 1] = {
            id = row.id,
            kind = row.kind,
            parentId = row.parentId,
            index = row.index,
            y = (i - 1) * ROW_H,
            h = ROW_H,
        }
    end
    local scopeKey = scopeDrop
    if scopeKey == nil and mouseY ~= nil and #self:ScopeList() > 1 and self.tabs ~= nil then
        local activeKey = self:ActiveScopeKey()
        for i, s in ipairs(self:ScopeList()) do
            if s.key ~= activeKey then
                local tab
                pcall(function() tab = self.tabs:GetTab(i) end)
                local hit = tab and tab.hit
                if hit ~= nil then
                    local hx, hy = componentScreenPos(hit)
                    local hw, hh = 0, TAB_BASELINE
                    pcall(function()
                        hw = hit.width or 0
                        hh = hit.height or TAB_BASELINE
                    end)
                    if mouseX ~= nil and mouseX >= hx and mouseX <= hx + hw
                        and mouseY >= hy and mouseY <= hy + hh then
                        scopeKey = s.key
                        break
                    end
                end
            end
        end
    end
    local target = Manager.ResolveDropTarget(localY, rows, {
        dragId = dragId,
        dragSubtreeIds = subtreeIds,
        scopeKey = scopeKey,
    })
    dragProbe(string.format("target=%s localY=%.1f",
        target and target.kind or "nil", localY))
    self:ApplyDrop(dragId, target)
    self:_rebuild()
end

-- Reacts to a row press (pure part, so the double-click gating in the view can be tested against
-- it): a group toggles expand; an alert reports up through onOpenAlert. `scopeKey` is captured at
-- press time so a row opened just as a tab switches still targets the tree it was drawn from.
---@param scopeKey string
---@param row Watchdog.ManagerRow
function Manager:_activateRow(scopeKey, row)
    if row.kind == "group" then
        self:ToggleExpand(scopeKey, row.id)
    elseif row.kind == "alert" then
        pcall(self.onOpenAlert, scopeKey, row.id)
    end
end

--- Pure logic: row editing ops (#91) ------------------------------------------------------
-- Each method reports through the matching host callback (main.lua wires Store + Runtime) and
-- bumps `mutateVersion` so the rebuild signature changes even when the root entry count does
-- not (enable / rename). A missing active scope or missing callback is a silent no-op.

local function bumpMutate(self)
    self.mutateVersion = self.mutateVersion + 1
end

-- Flips the Entry's own `enabled` via the host. The host re-evaluates the enabled-chain.
---@param id integer
function Manager:ToggleEnabled(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onToggleEnabled == nil then return end
    pcall(self.onToggleEnabled, scopeKey, id)
    bumpMutate(self)
end

-- Renames the Entry via the host.
---@param id integer
---@param name string
function Manager:Rename(id, name)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onRename == nil then return end
    pcall(self.onRename, scopeKey, id, name)
    bumpMutate(self)
end

-- Deletes the Entry (and its subtree) via the host. Confirm UI is the caller's job — this is the
-- committed delete.
---@param id integer
function Manager:Delete(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onDelete == nil then return end
    pcall(self.onDelete, scopeKey, id)
    bumpMutate(self)
end

-- Asks the host to mint + insert a new alert at the active scope root (and typically open it).
-- Returns the minted id when the host provides one.
---@return integer|nil
function Manager:CreateAlert()
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onCreateAlert == nil then return nil end
    local ok, id = pcall(self.onCreateAlert, scopeKey)
    bumpMutate(self)
    if ok and type(id) == "number" then return id end
    return nil
end

-- Asks the host to mint + insert a new empty group at the active scope root. Returns the minted
-- id when the host provides one (so the view can open an inline rename on the new row, #78).
---@return integer|nil
function Manager:CreateGroup()
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onCreateGroup == nil then return nil end
    local ok, id = pcall(self.onCreateGroup, scopeKey)
    bumpMutate(self)
    if ok and type(id) == "number" then return id end
    return nil
end

--- Rebuild signature ----------------------------------------------------------------------

-- A cheap string capturing everything the rendered tree depends on: the active scope, the expand
-- generation, the mutate generation (#91 — enable/rename don't change root count), and each
-- scope's key+label+entry-count. The view rebuilds only when this changes, so a character login
-- (new tab), a scope switch, an expand toggle, or a row mutation redraws — but an idle frame doesn't.
---@return string
function Manager:_signature()
    local parts = {
        self:ActiveScopeKey() or "-",
        tostring(self.expandVersion),
        tostring(self.mutateVersion),
    }
    for _, scope in ipairs(self:ScopeList()) do
        local entries = (scope.doc or {}).entries or {}
        parts[#parts + 1] = scope.key .. ":" .. (scope.label or "") .. ":" .. tostring(#entries)
    end
    return table.concat(parts, "|")
end

--- Client view: rows glyphs ---------------------------------------------------------------

-- The one-line label a row's name button renders: indent, a chevron for a group (▾ open / ▸
-- collapsed), an icon, the name, and a group's direct-child count. Kept pure so the exact string
-- is assertable in tests without a mounted component. Enable / rename / delete are sibling
-- controls (#91), not baked into this string.
---@param row Watchdog.ManagerRow
---@return string
function Manager:RowLabel(row)
    local indent = string.rep("  ", row.depth)
    if row.kind == "group" then
        local chevron = row.expanded and "▾" or "▸"
        return indent .. chevron .. " ▣ " .. row.name .. " (" .. tostring(row.childCount or 0) .. ")"
    end
    return indent .. "• " .. row.name
end

--- Client view: mount / render (client-only, pcall-guarded) -------------------------------

local function safeButtonStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.BUTTON_DEFAULT ~= nil then
        return id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

local function safeCheckStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.CHECKBOX_DEFAULT ~= nil then
        return id.StyleSheet.CHECKBOX_DEFAULT
    end
    return nil
end

-- Content rect size: prefer the parent's width/height when available, else Theme defaults.
---@param parent ui.ComponentCollection|nil
---@return number, number
local function contentSize(parent)
    local w, h = Theme.WINDOW_W, Theme.WINDOW_H
    if parent ~= nil then
        pcall(function()
            if parent.width and parent.width > 0 then w = parent.width end
            if parent.height and parent.height > 0 then h = parent.height end
        end)
    end
    return w, h
end

-- Apply hidden/enabled to a single content child (tabs root, tree, rename field).
---@param comp ui.Component|nil
---@param visible boolean
local function setChildVisible(comp, visible)
    if comp == nil then return end
    pcall(function()
        comp.hidden = not visible
        comp.enabled = visible
    end)
end

-- PrettyUI component root (wrappers expose `.root`; native components are themselves).
---@param comp any
---@return any
local function componentRoot(comp)
    if comp == nil then return nil end
    if type(comp) == "table" and comp.root ~= nil then return comp.root end
    return comp
end

-- Signature of scope tabs only (key+label). Recreate PrettyUI Tabs when this changes
-- (login/logout); keep Tabs across expand/enable/rename rebuilds.
---@return string
function Manager:_scopeTabsSignature()
    local parts = {}
    for _, scope in ipairs(self:ScopeList()) do
        parts[#parts + 1] = (scope.key or "") .. ":" .. (scope.label or "")
    end
    return table.concat(parts, "|")
end

---@return integer
function Manager:_activeScopeIndex()
    local activeKey = self:ActiveScopeKey()
    for i, scope in ipairs(self:ScopeList()) do
        if scope.key == activeKey then return i end
    end
    return 1
end

-- Destroys create-toolbar FancyButtons parented to tabs.root.
function Manager:_destroyToolbar()
    for _, b in ipairs(self.toolbarButtons) do
        pcall(function() b:Destroy() end)
    end
    self.toolbarButtons = {}
end

-- Destroys the tree Panel (row children die with it).
function Manager:_destroyTree()
    self:_endRename(false)
    self.dragId = nil
    self.dragVisual = nil
    self._treeIsLayer = false
    self.rowWidgets = {}
    self.rowButtons = {}
    if self.treePanel ~= nil then
        pcall(function() self.treePanel:Destroy() end)
        self.treePanel = nil
    end
end

-- Live rebuild helper: tear down toolbar + Tabs when the scope list changes.
-- NOT used from Unmount/Stop — see Unmount (must not Destroy before mux window Destroy).
function Manager:_destroyTabs()
    self:_destroyToolbar()
    self:_destroyTree()
    if self.tabs ~= nil then
        pcall(function() self.tabs:Destroy() end)
        self.tabs = nil
    end
    self.tabsScopeSig = nil
end

-- Ensures PrettyUI Tabs match the live scope list. Recreates on scope key/label change;
-- otherwise syncs the active tab without notifying (avoids rebuild re-entrancy).
---@return boolean
function Manager:_ensureTabs()
    if prettyui == nil or prettyui.Tabs == nil or self.contentParent == nil then
        return false
    end
    local scopes = self:ScopeList()
    if #scopes == 0 then
        self:_destroyTabs()
        return false
    end
    local sig = self:_scopeTabsSignature()
    if self.tabs ~= nil and self.tabsScopeSig == sig then
        local idx = self:_activeScopeIndex()
        pcall(function() self.tabs:SetActive(idx, false) end)
        return true
    end

    self:_destroyTabs()
    local entries = {}
    for _, scope in ipairs(scopes) do
        entries[#entries + 1] = {
            text = scope.label or scope.key,
            value = scope.key,
        }
    end
    local activeIndex = self:_activeScopeIndex()
    local tabs
    local ok, err = pcall(function()
        -- Height = tab strip only. A full-height Tabs root paints an empty page over the
        -- sibling tree Panel and hides every row (MoveToFront is not enough against that).
        tabs = prettyui.Tabs.new(self.contentParent, entries, {
            x = 0,
            y = 0,
            width = 0,
            widthAnchor = 1.0,
            height = TAB_BASELINE + 1,
            scrollable = false,
            activeIndex = activeIndex,
            onChange = function(_, _index, value, _page)
                self.pendingDeleteId = nil
                self:SetActiveScope(value)
                self:_rebuild()
            end,
        })
    end)
    if not ok or tabs == nil then
        if log ~= nil then log("Watchdog: prettyui.Tabs Mount failed") end
        return false
    end
    self.tabs = tabs
    self.tabsScopeSig = sig
    self:_wireScopeTabDrops()
    return true
end

-- Subscribe inactive PrettyUI tab `hit` layers as cross-scope drop targets (#92). While a row
-- drag is live, hovering an inactive tab arms `pendingScopeDrop`; leave clears it. Absent when
-- logged out (only one scope → nothing to wire). Inline ui.Hook.* (no variable-ized channel).
function Manager:_wireScopeTabDrops()
    self.pendingScopeDrop = nil
    if self.tabs == nil or self.tabs.GetTab == nil then return end
    local scopes = self:ScopeList()
    if #scopes < 2 then return end
    for i, scope in ipairs(scopes) do
        local capturedKey = scope.key
        pcall(function()
            local tab = self.tabs:GetTab(i)
            local hit = tab and tab.hit
            if hit == nil or hit.Subscribe == nil then return end
            hit:Subscribe(ui.Hook.ONMOUSEOVER, function()
                if self.dragId ~= nil and capturedKey ~= self:ActiveScopeKey() then
                    self.pendingScopeDrop = capturedKey
                end
                return false
            end)
            hit:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                if self.pendingScopeDrop == capturedKey then
                    self.pendingScopeDrop = nil
                end
                return false
            end)
        end)
    end
end

---@param contentParent ui.ComponentCollection
function Manager:Mount(contentParent)
    if ui == nil or ui.Panel == nil then
        if log ~= nil then log("Watchdog: ui.Panel unavailable, Manager Mount aborted") end
        return
    end
    if prettyui == nil or prettyui.Tabs == nil then
        if log ~= nil then log("Watchdog: prettyui.Tabs unavailable, Manager Mount aborted") end
        return
    end

    self.contentParent = contentParent
    local w, h = contentSize(contentParent)
    self.window.w, self.window.h = w, h

    if not self:_ensureTabs() then
        self.contentParent = nil
        return
    end

    self:SetVisible(self.visible)
    self:_rebuild()
end

---@return boolean
function Manager:IsMounted()
    return self.tabs ~= nil
end

function Manager:_clearChildren()
    self:_destroyToolbar()
    self:_destroyTree()
end

-- Helper: mount a Button under `parent` with text `label`, at (x,y)/(w,h), wired to `onPress`.
---@param parent ui.ComponentCollection
---@param bucket table[]
---@param x number
---@param y number
---@param w number
---@param h number
---@param label string
---@param onPress fun()
---@return ui.Button|nil
local function mountButton(parent, bucket, x, y, w, h, label, onPress)
    local button
    local okb = pcall(function() button = ui.Button.new(parent) end)
    if not okb or button == nil then return nil end
    pcall(function() button.stylesheetID = safeButtonStyle() end)
    button.clickthrough = false
    button:SetPos(x, y)
    -- Set label before size so stylesheet preferred-width from text cannot beat the layout budget.
    pcall(function() button.text.content = label end)
    button:SetSize(w, h)
    if onPress ~= nil then
        button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
            onPress()
            return true
        end)
    end
    pcall(function() button:MoveToFront() end)
    bucket[#bucket + 1] = button
    return button
end

-- Native row drag (#92). In-client, ComponentDragConfig moves on X only (COMPLETE endX
-- changes, endY stays 0) — bank-style horizontal drag. We still use it for gesture
-- begin/end + draggedComponent, and drive the row's Y ourselves in Manager:Update from
-- Mouse.GetPosition() so reorder/nest track the cursor vertically.
---@param comp ui.Component
---@param self Watchdog.Manager
---@param row Watchdog.ManagerRow
---@param visual ui.Component|nil  # defaults to `comp`
---@param note string|nil
local function wireNativeRowDrag(comp, self, row, visual, note)
    if comp == nil then return end
    local captured = row
    local ghost = visual or comp
    local okCfg, errCfg = pcall(function()
        local dc = comp.dragConfig
        if dc == nil then error("nil dragConfig") end
        dc.draggedComponent = ghost
        dc.dragDelayTicks = ROW_DRAG_DELAY_TICKS
        dc.deadZone = ROW_DRAG_DEAD_ZONE
        -- INVISIBLE: hide the native X-only ghost; we reposition `ghost` on Y in Update.
        if ui.DragRenderBehaviour ~= nil then
            dc.renderBehaviour = ui.DragRenderBehaviour.INVISIBLE
        end
    end)
    local ghostOk = false
    pcall(function() ghostOk = (comp.dragConfig.draggedComponent == ghost) end)
    dragProbe(string.format("wire id=%s cfgOk=%s ghostOk=%s err=%s %s",
        tostring(captured.id), tostring(okCfg), tostring(ghostOk), tostring(errCfg), note or ""))

    pcall(function()
        comp:Subscribe(ui.Hook.ONDRAG, function()
            if self.dragId ~= captured.id then
                dragProbe("ONDRAG id=" .. tostring(captured.id))
            end
            self.dragId = captured.id
            self.dragVisual = ghost
            self.pendingScopeDrop = nil
            self.pendingDeleteId = nil
            return true
        end)
        comp:Subscribe(ui.Hook.ONDRAGCOMPLETE, function(...)
            local n = select("#", ...)
            local parts = {}
            for i = 1, n do
                parts[#parts + 1] = tostring(select(i, ...))
            end
            dragProbe(string.format("COMPLETE id=%s n=%d args=[%s]",
                tostring(captured.id), n, table.concat(parts, "|")))
            self:_completeDrag(captured.id)
            return true
        end)
    end)
end

local SUBMIT_CAUSES = {
    SUBMIT = true, SUBMIT_ON_ESCAPE = true, SUBMIT_ON_FOCUS_LOSS = true,
}
local function isSubmitCause(cause)
    if cause == nil then return false end
    if type(cause) == "string" and SUBMIT_CAUSES[cause] then return true end
    local r = ui and ui.InputFieldActionResult
    if r ~= nil then
        if cause == r.SUBMIT or cause == r.SUBMIT_ON_ESCAPE or cause == r.SUBMIT_ON_FOCUS_LOSS then
            return true
        end
    end
    return false
end

-- Commits (or abandons) the inline rename TextField.
---@param commit boolean
function Manager:_endRename(commit)
    local field, id = self.renameField, self.renameId
    self.renameField, self.renameId = nil, nil
    if field == nil then return end
    if commit and id ~= nil then
        local name = ""
        pcall(function()
            if field.GetText ~= nil then
                name = field:GetText() or ""
            elseif field.root ~= nil then
                name = field.root.content or ""
            else
                name = field.content or ""
            end
        end)
        if name ~= "" then self:Rename(id, name) end
    end
    pcall(function() field:Destroy() end)
end

-- Mounts a transient PrettyUI TextField over the name slot for Entry `id`.
---@param id integer
---@param name string
---@param x number
---@param y number
---@param w number
---@param h number
function Manager:_beginRename(id, name, x, y, w, h)
    self:_endRename(false)
    if self.treePanel == nil or prettyui == nil or prettyui.TextField == nil then return end
    local field
    local ok = pcall(function()
        field = prettyui.TextField.new(self.treePanel, {
            text = name or "",
            x = x,
            y = y,
            width = w,
            height = h,
            maxLength = 64,
            onChange = function(_f, reason, _text)
                if isSubmitCause(reason) then
                    self:_endRename(true)
                    self:_rebuild()
                end
            end,
        })
    end)
    if ok and field ~= nil then
        self.renameField = field
        self.renameId = id
        pcall(function()
            if field.root ~= nil then field.root:MoveToFront() end
        end)
    end
end

---@param id integer
function Manager:_onDeletePress(id)
    if self.pendingDeleteId == id then
        self.pendingDeleteId = nil
        self:Delete(id)
        self:_rebuild()
    else
        self.pendingDeleteId = id
        self:_rebuild()
    end
end

---@param id integer
---@return integer
function Manager:_descendantCount(id)
    local scope = self:ActiveScope()
    if scope == nil or scope.doc == nil then return 0 end
    local function find(entries)
        for _, e in ipairs(entries or {}) do
            if e.id == id then return e end
            if e.children ~= nil then
                local found = find(e.children)
                if found ~= nil then return found end
            end
        end
        return nil
    end
    local entry = find((scope.doc or {}).entries)
    if entry == nil or entry.kind ~= "group" then return 0 end
    local n = 0
    local function count(children)
        for _, c in ipairs(children or {}) do
            n = n + 1
            if c.children ~= nil then count(c.children) end
        end
    end
    count(entry.children)
    return n
end

---@param id integer
---@return string
function Manager:_deleteConfirmLabel(id)
    local n = self:_descendantCount(id)
    if n > 0 then return "OK " .. tostring(n) .. "?" end
    return "OK?"
end

-- + Alert / + Group on the PrettyUI tab strip (right-aligned), visually inline with the tabs.
-- PrettyUI Tabs has no trailing-actions API; parenting FancyButtons to tabs.root is the
-- supported workaround.
function Manager:_mountToolbar()
    if self.tabs == nil or self.tabs.root == nil or prettyui == nil then return end
    if prettyui.FancyButton == nil then return end
    local root = self.tabs.root
    local alertW = 75
    local groupW = 75
    pcall(function()
        alertW = select(1, prettyui.FancyButton.getSize("+ Alert", { variant = "positive" }))
        groupW = select(1, prettyui.FancyButton.getSize("+ Group", { variant = "neutral" }))
    end)
    local y = math.max(0, math.floor((TAB_BASELINE - TOOLBAR_H) / 2))
    local group
    local alert
    pcall(function()
        group = prettyui.FancyButton.new(root, "+ Group", function()
            local id = self:CreateGroup()
            if type(id) == "number" then self.pendingRenameId = id end
            self:_rebuild()
        end, {
            x = -TOOLBAR_PAD - groupW,
            y = y,
            xAnchor = 1.0,
            variant = "neutral",
        })
        alert = prettyui.FancyButton.new(root, "+ Alert", function()
            self:CreateAlert()
            self:_rebuild()
        end, {
            x = -TOOLBAR_PAD - groupW - TOOLBAR_GAP - alertW,
            y = y,
            xAnchor = 1.0,
            variant = "positive",
        })
    end)
    if alert ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = alert end
    if group ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = group end
end

-- Rebuilds toolbar + tree rows. Tabs recreate only when the scope-list signature changes.
function Manager:_rebuild()
    if self.contentParent == nil or ui == nil then
        return
    end
    if not self:_ensureTabs() then
        return
    end
    self:_clearChildren()
    self.lastSignature = self:_signature()
    -- Don't wipe the probe on rebuild — COMPLETE→rebuild was erasing ONDRAG evidence.
    dragProbe("rebuild")

    local w, h = contentSize(self.contentParent)
    self.window.w, self.window.h = w, h

    self:_mountToolbar()

    -- Tree: sibling of Tabs under contentParent, below the tab strip.
    -- Use ui.Layer (no auto-layout) so native drag can move a row in Y — a vertical ui.Panel
    -- reflows every tick and pins the dragged row to its slot (looks like X-only movement).
    -- Do NOT assign scrollable — read-only on ComponentCollection; writing it aborts the pcall.
    local rowW = math.max(40, w - 2 * PAGE_PAD)
    local treeH = math.max(40, h - TREE_TOP - PAGE_PAD)
    self._treeIsLayer = false
    local treeOk = pcall(function()
        local tree
        if ui.Layer ~= nil then
            tree = ui.Layer.new(self.contentParent)
            self._treeIsLayer = true
        else
            tree = ui.Panel.new(self.contentParent)
            tree.isVertical = true
            tree.spacing = 0
        end
        tree.clickthrough = false
        tree:SetPos(PAGE_PAD, TREE_TOP)
        tree:SetSize(rowW, treeH)
        tree:MoveToFront()
        self.treePanel = tree
    end)
    if not treeOk or self.treePanel == nil then
        self.treePanel = nil
        self._treeIsLayer = false
        return
    end

    local rows = self:VisibleRows()
    local treeParent = self.treePanel
    -- Native ui.Button ren/del — PrettyUI SpriteButton crashes client teardown after PluginShutdown.
    for i, row in ipairs(rows) do
        local capturedRow = row
        local delLabel = (self.pendingDeleteId == row.id) and self:_deleteConfirmLabel(row.id) or "Delete"
        local delW = math.max(ACT_W, 8 + 7 * #delLabel)
        local rowY = (i - 1) * ROW_H
        -- Each row is a Layer (absolute children), not a horizontal Panel. Dragging a
        -- horizontal Panel (isVertical=false) axis-locks the ghost to X even on a Layer tree.
        local nameW = math.max(40, rowW - HANDLE_W - ENABLE_W - ACT_W - delW - 4 * ROW_GAP - ROW_SLACK)
        local rowPanel = treeParent
        local okRow = pcall(function()
            if self._treeIsLayer and ui.Layer ~= nil then
                rowPanel = ui.Layer.new(treeParent)
            else
                rowPanel = ui.Panel.new(treeParent)
                rowPanel.isVertical = false
                rowPanel.spacing = ROW_GAP
            end
            rowPanel.clickthrough = false
            if self._treeIsLayer then
                rowPanel:SetPos(0, rowY)
            end
            rowPanel:SetSize(rowW, ROW_H)
        end)
        if not okRow or rowPanel == nil then
            rowPanel = treeParent
        end
        if rowPanel ~= treeParent then
            self.rowButtons[#self.rowButtons + 1] = rowPanel
        end

        local x = 0
        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            local handle = mountButton(rowPanel, bucket, x, 0, HANDLE_W, ROW_H, "::", nil)
            local visual = (rowPanel ~= treeParent) and rowPanel or handle
            wireNativeRowDrag(handle, self, capturedRow, visual, "grip=inRowLayer")
        end
        x = x + HANDLE_W + ROW_GAP

        local enableMounted = false
        if ui.Check ~= nil then
            local check
            local okc = pcall(function() check = ui.Check.new(rowPanel) end)
            if okc and check ~= nil then
                pcall(function()
                    check.stylesheetID = safeCheckStyle()
                    check:SetPos(x, 0)
                    check:SetSize(ENABLE_W, ROW_H)
                    check.buttonSize = math.min(ENABLE_W - 2, ROW_H - 2)
                    check.value = row.enabled and true or false
                    check.label = ""
                    check:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                        self.pendingDeleteId = nil
                        self:ToggleEnabled(capturedRow.id)
                        self:_rebuild()
                        return true
                    end)
                end)
                if rowPanel == treeParent then
                    self.rowButtons[#self.rowButtons + 1] = check
                end
                enableMounted = true
            end
        end
        if not enableMounted then
            local mark = row.enabled and "[x]" or "[ ]"
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, x, 0, ENABLE_W, ROW_H, mark, function()
                self.pendingDeleteId = nil
                self:ToggleEnabled(capturedRow.id)
                self:_rebuild()
            end)
        end
        x = x + ENABLE_W + ROW_GAP

        local nameX = x
        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, nameX, 0, nameW, ROW_H, self:RowLabel(row), function()
                self.pendingDeleteId = nil
                self:_onRowPress(capturedRow)
                if capturedRow.kind == "group" then self:_rebuild() end
            end)
        end
        x = nameX + nameW + ROW_GAP

        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, x, 0, ACT_W, ROW_H, "Rename", function()
                self.pendingDeleteId = nil
                local fieldY = 0
                pcall(function() fieldY = rowPanel.y or 0 end)
                self:_beginRename(capturedRow.id, capturedRow.name, nameX, fieldY, nameW, ROW_H)
            end)
        end
        x = x + ACT_W + ROW_GAP

        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, x, 0, delW, ROW_H, delLabel, function()
                self:_onDeletePress(capturedRow.id)
            end)
        end

        if self.pendingRenameId == row.id then
            self.pendingRenameId = nil
            local fieldY = 0
            pcall(function() fieldY = rowPanel.y or 0 end)
            self:_beginRename(row.id, row.name, nameX, fieldY, nameW, ROW_H)
        end
    end

    if self.treePanel ~= nil then
        pcall(function()
            self.treePanel:SetScrollSize(rowW, #rows * ROW_H)
        end)
    end

    if not self.visible then
        setChildVisible(componentRoot(self.tabs), false)
        for _, b in ipairs(self.toolbarButtons) do
            setChildVisible(componentRoot(b), false)
        end
        setChildVisible(self.treePanel, false)
        setChildVisible(componentRoot(self.renameField), false)
    end
end

---@param row Watchdog.ManagerRow
function Manager:_onRowPress(row)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil then return end
    if row.kind == "group" then
        self:_activateRow(scopeKey, row)
        return
    end
    local isDouble = (row.id == self.lastRowId)
        and (self.tick - self.lastRowTick) <= Theme.DOUBLECLICK_TICKS
    self.lastRowId, self.lastRowTick = row.id, self.tick
    if isDouble then
        self.lastRowId = nil
        self:_activateRow(scopeKey, row)
    end
end

function Manager:Update()
    self.tick = self.tick + 1
    if not self.visible or self.tabs == nil then return end
    -- Native drag is X-locked (bank-style). While a gesture is live, pin the row's Y to the
    -- cursor so reorder/nest tracking is vertical.
    if self.dragId ~= nil and self.dragVisual ~= nil and self.treePanel ~= nil then
        local _, my = mouseScreenPos()
        local _, treeTop = componentScreenPos(self.treePanel)
        if my ~= nil and treeTop ~= nil then
            local localY = my - treeTop - (ROW_H * 0.5)
            pcall(function()
                self.dragVisual:SetPos(0, localY)
                self.dragVisual:MoveToFront()
            end)
        end
    end
    if self:_signature() ~= self.lastSignature then
        self:_rebuild()
    end
end

--- Client view: visibility / lifecycle ----------------------------------------------------

---@return boolean
function Manager:IsVisible()
    return self.visible
end

---@param v boolean
function Manager:SetVisible(v)
    local becomingVisible = v and not self.visible
    self.visible = v and true or false
    setChildVisible(componentRoot(self.tabs), self.visible)
    for _, b in ipairs(self.toolbarButtons) do
        setChildVisible(componentRoot(b), self.visible)
    end
    setChildVisible(self.treePanel, self.visible)
    setChildVisible(componentRoot(self.renameField), self.visible)
    if becomingVisible and self.tabs ~= nil then
        self:_rebuild()
    end
end

function Manager:Toggle()
    self:SetVisible(not self.visible)
end

function Manager:RaiseToFront()
end

-- Stop/Unmount must NOT :Destroy() Tabs/tree/toolbar. Those are children of the mux
-- prettyui.Window content; api.Stop then calls mux:Destroy() which Destroy()s the window
-- and its content tree. Destroying Tabs first, then the window, double-frees realized
-- components and freezes/crashes after the window has been shown. Clear Lua refs only —
-- the window Destroy owns native teardown. Mid-session rebuild still uses _destroyTree /
-- _destroyToolbar / _destroyTabs while the window stays alive.
function Manager:Unmount()
    self.pendingDeleteId = nil
    self.dragId = nil
    self:_endRename(false)
    self.toolbarButtons = {}
    self.rowWidgets = {}
    self.rowButtons = {}
    self.treePanel = nil
    self.tabs = nil
    self.tabsScopeSig = nil
    self.contentParent = nil
end

return Manager
