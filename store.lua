-- store.lua — Watchdog's persistence backend: the `global` Bucket and the Entry tree it holds.
--
-- LibNodeGraph deliberately never touches persistentdb (ADR-0007): the library only
-- produces/consumes tables + strings, and the *consumer* owns actual persistence. This
-- module is that consumer half for Watchdog.
--
-- ## The Bucket model (#75, #81)
--
-- Persistence is a per-Scope **Bucket**: one `PersistentDB` key holding one Scope's tree as
-- `{ version, entries, infoboxAnchor }`. This ticket (#86) delivers the `global` Bucket only —
-- per-character `player_<normalized>` buckets are #89. Keys carry **no `watchdog_` prefix**:
-- `PersistentDB` is already plugin-scoped, so the Bucket for the shared scope is plain `global`.
-- An absent `global` key is a fresh install (empty bucket); ordinary schema bumps are version-
-- gated on the document's `version` field, not a separate key hop.
--
-- ## The Entry tree (#75)
--
-- `entries` is a tree of **Entry** records. Every Entry has a minted `id`, a `kind`
-- (`"alert" | "group"`), a `name`, and an `enabled` flag. An **alert** leaf also carries its
-- serialized `graph` + `layout`; a **group** branch carries a `children` array of Entries.
-- This ticket's fresh-install / restore paths produce only root-level alerts (groups are #88),
-- but the schema and every helper here are already tree-shaped so groups drop in additively.
--
-- **`id` is the identity.** Names carry *no* uniqueness constraint, so every Store operation
-- keys on `id`, never name (a name is display text and may repeat across entries). Ordering is
-- array position within a parent's `children` (root order for top-level entries).
--
-- `graph` is exactly what LibNodeGraph.Serialize produces (the same shareable structure a user
-- would export), so there is no separate saved-vs-shared representation. Layout is stored as an
-- array of { id, x, y } rather than an id-keyed map because JSON object keys must be strings; it
-- round-trips back to a nodeId-keyed map on load. That mapping only stays valid because
-- LibNodeGraph.Deserialize preserves node ids.

local Util = require("util")

local Store = {}

-- Bucket keys are un-prefixed — PersistentDB is already plugin-scoped (#81). The `global` scope
-- keys on a fixed string; a per-character scope (#89) keys on `player_<normalized displayName>`.
local DB_KEY = "global"
local DOC_VERSION = 2

-- The `PersistentDB` key for a character's Bucket (#89): `player_` + the normalized display name.
-- Normalizing (see Util.NormalizePlayerName) means a cosmetic case/whitespace difference in what
-- the client returns can't silently orphan a bucket, and the `player_` namespace lets an
-- IterateEntries pass tell character buckets apart from `global` (#77 §4).
---@param displayName string
---@return string
function Store.PlayerKey(displayName)
    return "player_" .. Util.NormalizePlayerName(displayName)
end

--- Persisted schema -----------------------------------------------------------------------
-- These describe exactly what lives under the DB_KEY JSON string. `Watchdog.Bucket` is the
-- single shape that round-trips: it's what `Store.Load` returns and what `Store.Save`/`Encode`
-- consume — so the type *is* the persistence contract.

---One node of a Scope's persisted tree (#75). Identity is `id`; `name` is non-unique display
---text. An **alert** (`kind == "alert"`) carries `graph` + `layout` and is a leaf; a **group**
---(`kind == "group"`) carries `children` and is a branch. The alert-only / group-only fields are
---absent on the other kind.
---@class Watchdog.Entry
---@field id integer                               # minted identity — the key every op uses
---@field kind "alert"|"group"                     # leaf (alert) vs branch (group)
---@field name string                              # display text; NOT unique
---@field enabled boolean                          # whether this entry fires (alert) / its subtree (group)
---@field graph LibNodeGraph.SerializedGraph|nil   # alert only: LibNodeGraph.Serialize output
---@field layout Watchdog.LayoutArray|nil          # alert only: node positions, on-disk array form
---@field children Watchdog.Entry[]|nil            # group only: nested entries, in order

---One Scope's whole persisted document: a `version`, the Entry tree, and (for the `global`
---bucket) the shared InfoBox anchor. The one type that survives a save -> load round-trip intact.
---@class Watchdog.Bucket
---@field version integer                          # schema version (DOC_VERSION), for migrations
---@field entries Watchdog.Entry[]                 # root-level entries, in order
---@field infoboxAnchor Watchdog.Point|nil         # shared InfoBox strip position (#41); nil until moved

---A saved alert rebuilt into live objects (the return shape of RestoreAll). Mirrors an alert
---Entry but with the runtime forms: a live `LibNodeGraph.Graph` and the id-keyed
---`Watchdog.Layout`. Carries the entry `id` so the runtime can persist enable/disable by id.
---@class Watchdog.RestoredAlert
---@field id integer
---@field name string
---@field graph LibNodeGraph.Graph
---@field layout Watchdog.Layout
---@field enabled boolean

-- The JSON codec and the graph (de)serializers live in the LibNodeGraph plugin, injected
-- as a global (same as main.lua reaches LibNodeGraph.NewGraph). Fetched lazily so this
-- module can load even if the lib isn't present yet.
---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

--- Layout <-> JSON-safe shapes ------------------------------------------------------------

---A node's on-canvas position, in Graph-space (the pan/zoom-independent coordinate the View
---transform maps to the screen). Top-left corner of the node box.
---@class Watchdog.Point
---@field x number
---@field y number

---The editor's Layout: where each node sits on the canvas, keyed by its LibNodeGraph node id.
---Purely UI state — the engine has no concept of node position, so Watchdog owns this and
---persists it alongside the serialized graph. A node id with no entry falls back to a default
---placement when first drawn.
---@alias Watchdog.Layout table<integer, Watchdog.Point>

---The on-disk form of a Layout: an array of { id, x, y } records. JSON object keys must be
---strings, so the id can't be a table key here — it rides as a field and round-trips back to a
---nodeId-keyed Watchdog.Layout on load. Sorted by id purely so saved files diff cleanly.
---@alias Watchdog.LayoutArray { id: integer, x: number, y: number }[]

---@param layout Watchdog.Layout|nil
---@return Watchdog.LayoutArray
local function layoutToArray(layout)
    local arr = {}
    for id, pos in pairs(layout or {}) do
        arr[#arr + 1] = { id = id, x = pos.x, y = pos.y }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

---@param arr Watchdog.LayoutArray|nil
---@return Watchdog.Layout
local function layoutFromArray(arr)
    local layout = {}
    for _, e in ipairs(arr or {}) do
        if e.id ~= nil then
            layout[e.id] = { x = e.x or 0, y = e.y or 0 }
        end
    end
    return layout
end

-- Normalizes any stored/passed enabled value to a strict boolean, treating nil (an entry
-- written before the flag existed, or an omitted argument) as enabled.
---@param enabled boolean|nil
---@return boolean
local function normalizeEnabled(enabled)
    return enabled ~= false
end

--- Document construction ------------------------------------------------------------------

---@return Watchdog.Bucket
function Store.Empty()
    return { version = DOC_VERSION, entries = {}, infoboxAnchor = nil }
end

--- Entry-tree helpers (all id-keyed, name-agnostic) ---------------------------------------
-- The tree is walked depth-first, pre-order (a parent before its children), so `Leaves`,
-- `MintId`, and `FindById` all see entries in the same stable order the UI renders them.

---Applies `fn(entry, siblings, index)` to every entry in the tree, depth-first pre-order.
---`siblings` is the array the entry lives in and `index` its position, so a visitor can splice.
---@param entries Watchdog.Entry[]|nil
---@param fn fun(entry: Watchdog.Entry, siblings: Watchdog.Entry[], index: integer)
local function walk(entries, fn)
    for i, entry in ipairs(entries or {}) do
        fn(entry, entries, i)
        if entry.children ~= nil then
            walk(entry.children, fn)
        end
    end
end

-- Mints an id not used by any entry anywhere in the tree (max existing id + 1, starting at 1).
-- Mint one id and insert its entry before minting the next — two mints against the same tree
-- state return the same id.
---@param doc Watchdog.Bucket
---@return integer
function Store.MintId(doc)
    local max = 0
    walk((doc or {}).entries, function(e)
        if type(e.id) == "number" and e.id > max then max = e.id end
    end)
    return max + 1
end

-- Every alert leaf (`kind == "alert"`) in the tree, in depth-first pre-order — what the runtime
-- restores as live alerts. Group branches are walked into but not themselves returned.
---@param doc Watchdog.Bucket
---@return Watchdog.Entry[]
function Store.Leaves(doc)
    local leaves = {}
    walk((doc or {}).entries, function(e)
        if e.kind == "alert" then leaves[#leaves + 1] = e end
    end)
    return leaves
end

-- Finds the entry with `id` anywhere in the tree, returning it plus the array it lives in and
-- its index there (so the caller can reorder/splice without re-searching). Lone nil if absent.
---@param doc Watchdog.Bucket
---@param id integer
---@return Watchdog.Entry|nil entry
---@return Watchdog.Entry[]|nil siblings
---@return integer|nil index
function Store.FindById(doc, id)
    local found, foundSiblings, foundIndex
    walk((doc or {}).entries, function(e, siblings, index)
        if e.id == id then
            found, foundSiblings, foundIndex = e, siblings, index
        end
    end)
    return found, foundSiblings, foundIndex
end

-- Inserts `entry` into `parentId`'s children (a group), or the root when `parentId` is nil.
-- When `index` is nil, appends; otherwise clamps `index` into `[1, #siblings+1]` and inserts
-- there (1-based, Lua array style). Returns true on success; false if `parentId` names an entry
-- that doesn't exist or isn't a group. Mutates `doc` in place.
---@param doc Watchdog.Bucket
---@param entry Watchdog.Entry
---@param parentId integer|nil                     # nil ⇒ root; else a group entry's id
---@param index integer|nil                        # 1-based insert position; nil ⇒ append
---@return boolean
function Store.InsertEntryAt(doc, entry, parentId, index)
    doc.entries = doc.entries or {}
    local siblings
    if parentId == nil then
        siblings = doc.entries
    else
        local parent = Store.FindById(doc, parentId)
        if parent == nil or parent.kind ~= "group" then
            return false
        end
        parent.children = parent.children or {}
        siblings = parent.children
    end
    if index == nil then
        siblings[#siblings + 1] = entry
    else
        local i = math.floor(index)
        if i < 1 then i = 1 end
        if i > #siblings + 1 then i = #siblings + 1 end
        table.insert(siblings, i, entry)
    end
    return true
end

-- Appends `entry` to the end of `parentId`'s children (a group), or to the root when `parentId`
-- is nil. Returns true on success; false if `parentId` names an entry that doesn't exist or isn't
-- a group. Mutates `doc` in place. Equivalent to InsertEntryAt with a nil index.
---@param doc Watchdog.Bucket
---@param entry Watchdog.Entry
---@param parentId integer|nil                     # nil ⇒ root; else a group entry's id
---@return boolean
function Store.InsertEntry(doc, entry, parentId)
    return Store.InsertEntryAt(doc, entry, parentId, nil)
end

-- Removes the entry with `id` from wherever it sits in the tree (its whole subtree goes with it).
-- Returns the removed entry, or nil if no entry had that id.
---@param doc Watchdog.Bucket
---@param id integer
---@return Watchdog.Entry|nil
function Store.DeleteById(doc, id)
    local entry, siblings, index = Store.FindById(doc, id)
    if entry == nil then return nil end
    table.remove(siblings, index)
    return entry
end

-- True if `targetId` names `entry` itself or any entry inside its subtree — the cycle guard
-- MoveSubtree uses so a group can't be reparented under one of its own descendants (which would
-- detach that whole branch from the tree).
---@param entry Watchdog.Entry
---@param targetId integer
---@return boolean
local function subtreeContains(entry, targetId)
    if entry.id == targetId then return true end
    for _, child in ipairs(entry.children or {}) do
        if subtreeContains(child, targetId) then return true end
    end
    return false
end

-- Reparents the entry with `id` (and its whole subtree) under `newParentId` (nil ⇒ root).
-- Optional `atIndex` is the 1-based sibling slot at the destination (nil ⇒ append). Id-keyed
-- like every tree op; the moved subtree stays intact. Returns true on success, false and leaves
-- the tree untouched when: no entry has `id`; `newParentId` names an entry that doesn't exist or
-- isn't a group; or `newParentId` is `id` itself or one of its descendants (a cycle — see
-- subtreeContains). Mutates `doc` in place.
---@param doc Watchdog.Bucket
---@param id integer
---@param newParentId integer|nil                  # nil ⇒ root; else a group entry's id
---@param atIndex integer|nil                      # 1-based insert position; nil ⇒ append
---@return boolean
function Store.MoveSubtree(doc, id, newParentId, atIndex)
    local entry, siblings, index = Store.FindById(doc, id)
    if entry == nil then return false end
    -- Validate the destination *before* detaching, so a refused move is a genuine no-op: reject a
    -- cycle (into self or a descendant), or a parent that doesn't exist / isn't a group. The
    -- group/existence half mirrors InsertEntryAt's, which does the actual insert below.
    if newParentId ~= nil then
        if subtreeContains(entry, newParentId) then return false end
        local parent = Store.FindById(doc, newParentId)
        if parent == nil or parent.kind ~= "group" then return false end
    end
    -- When reordering within the same sibling list, removing the entry shifts indices after it —
    -- bump the destination down so the caller's "before this sibling" intent still holds.
    local destIndex = atIndex
    if destIndex ~= nil and siblings ~= nil then
        local sameList = false
        if newParentId == nil then
            sameList = (siblings == (doc.entries or {}))
        else
            local parent = Store.FindById(doc, newParentId)
            sameList = parent ~= nil and parent.children == siblings
        end
        if sameList and index < destIndex then
            destIndex = destIndex - 1
        end
    end
    table.remove(siblings, index)
    return Store.InsertEntryAt(doc, entry, newParentId, destIndex)
end

-- Moves the entry with `id` (and its whole subtree) from `srcDoc` to the root of `dstDoc`,
-- preserving the entry's id and structure — not a JSON round-trip. Appends at destination root.
-- Returns the moved entry, or nil (and leaves both docs untouched) when: no entry has `id` in
-- `srcDoc`; or `dstDoc` already has an entry with that id (collision). Mutates both docs in place.
---@param srcDoc Watchdog.Bucket
---@param dstDoc Watchdog.Bucket
---@param id integer
---@return Watchdog.Entry|nil
function Store.MoveEntryBetweenBuckets(srcDoc, dstDoc, id)
    if Store.FindById(dstDoc, id) ~= nil then return nil end
    local entry = Store.DeleteById(srcDoc, id)
    if entry == nil then return nil end
    Store.InsertEntry(dstDoc, entry, nil)
    return entry
end

--- Enabled-chain (#88) --------------------------------------------------------------------
-- `enabled` is an inheritable master switch: an alert fires iff its own `enabled` AND every
-- ancestor group's `enabled` are true — the enabled-chain. A group's flag is stored on the group
-- Entry alone (SetEnabled by id, above, flips it); disabling a group never touches a descendant's
-- own `enabled`, so re-enabling it restores exactly the prior per-alert state. The resolution is
-- always live over the current tree, so a move (Store.MoveSubtree) re-parents an entry into a new
-- chain with no cached state to invalidate.

-- Returns the ancestor groups of the entry with `id`, outermost-first (root → the entry's parent),
-- or nil if no entry has that id. Purely the chain *above* the entry — the entry itself is excluded.
---@param entries Watchdog.Entry[]|nil
---@param id integer
---@return Watchdog.Entry[]|nil
local function ancestorsOf(entries, id)
    local function rec(list, acc)
        for _, entry in ipairs(list or {}) do
            if entry.id == id then
                return acc
            end
            if entry.children ~= nil then
                acc[#acc + 1] = entry
                local found = rec(entry.children, acc)
                if found ~= nil then return found end
                acc[#acc] = nil
            end
        end
        return nil
    end
    return rec(entries, {})
end

-- True unless some ancestor group of the entry with `id` is disabled — the upstream half of the
-- enabled-chain, excluding the entry's own flag. A root-level entry (no ancestors) and an absent
-- `id` both return true: nothing upstream suppresses them. This is the gate the runtime ANDs with
-- an alert's own `enabled` at fire time (main.lua wires it via Runtime:SetEnabledResolver).
---@param doc Watchdog.Bucket
---@param id integer
---@return boolean
function Store.AncestorsEnabled(doc, id)
    local ancestors = ancestorsOf((doc or {}).entries, id)
    if ancestors == nil then return true end
    for _, group in ipairs(ancestors) do
        if not normalizeEnabled(group.enabled) then return false end
    end
    return true
end

-- The full enabled-chain for the entry with `id`: its own `enabled` AND every ancestor group's
-- `enabled`. False for an unknown `id` (an absent entry is not enabled). The Manager's per-row
-- "does this fire?" query; the runtime instead composes AncestorsEnabled with its own live flag.
---@param doc Watchdog.Bucket
---@param id integer
---@return boolean
function Store.EnabledChain(doc, id)
    local entry = Store.FindById(doc, id)
    if entry == nil then return false end
    return normalizeEnabled(entry.enabled) and Store.AncestorsEnabled(doc, id)
end

--- Entry construction ---------------------------------------------------------------------

-- Builds an alert Entry from a *live* graph (serialized here) + its Layout. `enabled` defaults
-- to true. The caller mints `id` (Store.MintId) and inserts the result (Store.InsertEntry).
---@param id integer
---@param name string
---@param graph LibNodeGraph.Graph                 # a live graph; serialized into the entry here
---@param layout Watchdog.Layout|nil
---@param enabled boolean|nil
---@return Watchdog.Entry
function Store.NewAlertEntry(id, name, graph, layout, enabled)
    return {
        id = id,
        kind = "alert",
        name = name,
        enabled = normalizeEnabled(enabled),
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutToArray(layout),
    }
end

-- Builds a group Entry. Groups aren't produced by this ticket's fresh-install / restore paths
-- (that's #88) — this exists so the tree helpers have a group to nest into and so the schema
-- demonstrably doesn't preclude them.
---@param id integer
---@param name string
---@param enabled boolean|nil
---@param children Watchdog.Entry[]|nil
---@return Watchdog.Entry
function Store.NewGroupEntry(id, name, enabled, children)
    return {
        id = id,
        kind = "group",
        name = name,
        enabled = normalizeEnabled(enabled),
        children = children or {},
    }
end

--- Mutation by id -------------------------------------------------------------------------

-- Flips an entry's enabled flag in place, keyed by `id` (the runtime's persistence hook for
-- SetEnabled/Toggle). Returns true if an entry with that id existed, false otherwise. Does not
-- persist; the caller runs Store.Save.
---@param doc Watchdog.Bucket
---@param id integer
---@param enabled boolean
---@return boolean
function Store.SetEnabled(doc, id, enabled)
    local entry = Store.FindById(doc, id)
    if entry == nil then return false end
    entry.enabled = normalizeEnabled(enabled)
    return true
end

-- Renames an entry in place, keyed by `id` (Manager row rename, #91). Returns true if an entry
-- with that id existed, false otherwise. Names carry no uniqueness constraint — this only mutates
-- the targeted entry. Does not persist; the caller runs Store.Save.
---@param doc Watchdog.Bucket
---@param id integer
---@param name string
---@return boolean
function Store.SetName(doc, id, name)
    local entry = Store.FindById(doc, id)
    if entry == nil then return false end
    entry.name = name
    return true
end

-- Re-serializes a *live* graph + Layout back into the alert Entry with `id` (the editor autosave
-- path). Returns true if an alert with that id existed and was updated, false otherwise. Does not
-- persist; the caller runs Store.Save.
---@param doc Watchdog.Bucket
---@param id integer
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@return boolean
function Store.UpdateAlertGraph(doc, id, graph, layout)
    local entry = Store.FindById(doc, id)
    if entry == nil or entry.kind ~= "alert" then return false end
    entry.graph = LibNodeGraph.Serialize(graph)
    entry.layout = layoutToArray(layout)
    return true
end

--- Restore --------------------------------------------------------------------------------

-- Rebuilds *every* alert leaf into a live instance (#27: all saved alerts instantiate live at
-- startup, not just the one the editor is viewing, so triggers in every enabled alert fire).
-- Returns an array of { id, name, graph, layout, enabled } in tree order. Deserialize is lenient
-- (#53): an unregistered node type loads as an inert placeholder rather than dropping the alert.
-- The pcall stays as a backstop for a genuinely corrupt entry (e.g. `graph`/`nodes` not a table),
-- so one malformed alert can't take the others down.
---@param doc Watchdog.Bucket
---@param registry LibNodeGraph.Registry
---@return Watchdog.RestoredAlert[]  # one live alert per restorable leaf, in tree order
function Store.RestoreAll(doc, registry)
    local restored = {}
    for _, entry in ipairs(Store.Leaves(doc)) do
        local ok, graph = pcall(function()
            return LibNodeGraph.Deserialize(entry.graph, registry, { onUnknown = "placeholder" })
        end)
        if ok and graph ~= nil then
            restored[#restored + 1] = {
                id = entry.id,
                name = entry.name,
                graph = graph,
                layout = layoutFromArray(entry.layout),
                enabled = normalizeEnabled(entry.enabled),
            }
        elseif log ~= nil then
            log("Watchdog: skipping unrestorable alert '" .. tostring(entry.name) .. "' — " .. tostring(graph))
        end
    end
    return restored
end

--- InfoBox Area anchor (#41) --------------------------------------------------------------
-- The shared InfoBox strip's draggable anchor lives at the bucket's top level (it's not
-- per-entry state, unlike an alert's `enabled` flag) — one strip position for the whole plugin.
-- The InfoBox Area's own EndDrag calls SetInfoBoxAnchor directly (main.lua wires it), same seam
-- shape as runtime.lua's SetEnabled persistence hook.

---@param doc Watchdog.Bucket
---@param x number
---@param y number
function Store.SetInfoBoxAnchor(doc, x, y)
    doc.infoboxAnchor = { x = x, y = y }
end

-- Returns x, y, or nil, nil if no anchor was ever saved (a fresh install; the caller keeps
-- ui/infobox.lua's own default top-left anchor).
---@param doc Watchdog.Bucket
---@return number|nil x
---@return number|nil y
function Store.GetInfoBoxAnchor(doc)
    local a = doc.infoboxAnchor
    if a == nil then return nil, nil end
    return a.x, a.y
end

--- persistentdb I/O -----------------------------------------------------------------------

-- Encodes the whole bucket to its JSON string. Exposed so a caller can cheaply diff the current
-- document against the last-saved string before deciding to persist.
---@param doc Watchdog.Bucket
---@return string|nil  # the JSON text, or nil if no codec is available / encoding failed
function Store.Encode(doc)
    local c = codec()
    if c == nil then return nil end
    local ok, text = pcall(function() return c.encode(doc) end)
    if ok then return text end
    return nil
end

-- Reads and decodes the raw JSON at `key` into a Bucket, or an empty one when the key is absent,
-- unreadable, or not valid JSON. Never returns nil. Used for every character Bucket (#89) and by
-- Store.Load for `global`.
---@param key string
---@return Watchdog.Bucket doc  # the same shape Store.SaveTo persists (the round-trip contract)
function Store.LoadKey(key)
    if PersistentDB == nil then return Store.Empty() end
    local text
    pcall(function() text = PersistentDB:GetString(key) end)
    if type(text) ~= "string" or text == "" then
        return Store.Empty()
    end
    local c = codec()
    if c == nil then return Store.Empty() end
    local ok, doc = pcall(function() return c.decode(text) end)
    if not ok or type(doc) ~= "table" then
        if log ~= nil then log("Watchdog: saved bucket '" .. tostring(key) .. "' unreadable, starting fresh — " .. tostring(doc)) end
        return Store.Empty()
    end
    doc.version = doc.version or DOC_VERSION
    doc.entries = doc.entries or {}
    return doc
end

-- Reads the saved `global` bucket, or an empty one when there's nothing saved / it can't be
-- parsed. Never returns nil, so callers always get a document to work on.
---@return Watchdog.Bucket doc  # the same shape Store.Save persists (the round-trip contract)
function Store.Load()
    return Store.LoadKey(DB_KEY)
end

-- Persists `doc` as one JSON string under `key`. Returns true on success. The keyed sibling of
-- Store.Save: used for character Buckets (#89) and reused by Store.Save for the `global` key.
---@param key string
---@param doc Watchdog.Bucket  # the same shape Store.LoadKey returns (the round-trip contract)
---@return boolean  # true if the document was encoded and written
function Store.SaveTo(key, doc)
    if PersistentDB == nil then return false end
    local text = Store.Encode(doc)
    if text == nil then
        if log ~= nil then log("Watchdog: failed to encode bucket for save") end
        return false
    end
    local ok = pcall(function() PersistentDB:SetString(key, text) end)
    return ok
end

-- Persists the bucket as one JSON string under the `global` key. Returns true on success.
---@param doc Watchdog.Bucket  # the same shape Store.Load returns (the round-trip contract)
---@return boolean  # true if the document was encoded and written
function Store.Save(doc)
    return Store.SaveTo(DB_KEY, doc)
end

return Store
