-- store.lua - PersistentDB Buckets and the Entry tree (LibNodeGraph never touches persistentdb).
--
-- One Bucket per scope: `{ version, entries, infoboxAnchor }` under an un-prefixed key
-- (`global` or `player_<tracking id>` - PersistentDB is already plugin-scoped).
--
-- `id` is identity: every op keys on `id`, never `name` (display text, not unique). Alerts
-- carry Serialize `graph` + `layout`; groups carry `children`. Layout is an array of
-- `{ id, x, y }` because JSON object keys must be strings; it round-trips to a nodeId-keyed
-- map on load (valid because Deserialize preserves node ids).

local Util = require("src/util")
local Text = require("src/text")
local DropDismissOn = require("src/drop_dismiss_on")

local Store = {}

local DB_KEY = "global"
local DOC_VERSION = 2

-- `player_<tracking id>`, not display-name folded. `player_` distinguishes these from `global`.
---@param trackingId string
---@return string
function Store.PlayerKey(trackingId)
    return "player_" .. trackingId
end

--- Persisted schema -----------------------------------------------------------------------

---@class Watchdog.Entry
---@field id integer                               # minted identity - the key every op uses
---@field kind "alert"|"group"                     # leaf (alert) vs branch (group)
---@field name string                              # display text; NOT unique
---@field enabled boolean                          # whether this entry fires (alert) / its subtree (group)
---@field graph LibNodeGraph.SerializedGraph|nil   # alert only: LibNodeGraph.Serialize output
---@field layout Watchdog.LayoutArray|nil          # alert only: node positions, on-disk array form
---@field children Watchdog.Entry[]|nil            # group only: nested entries, in order

---@class Watchdog.Bucket
---@field version integer                          # schema version (DOC_VERSION), for migrations
---@field entries Watchdog.Entry[]                 # root-level entries, in order
---@field infoboxAnchor Watchdog.Point|nil         # shared InfoBox strip; nil until moved

---@class Watchdog.RestoredAlert
---@field id integer
---@field name string
---@field graph LibNodeGraph.Graph
---@field layout Watchdog.Layout
---@field enabled boolean

-- Lazy: this module must load even if LibNodeGraph is not injected yet.
---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

--- Layout <-> JSON-safe shapes ------------------------------------------------------------

---@class Watchdog.Point
---@field x number
---@field y number

---@alias Watchdog.Layout table<integer, Watchdog.Point>

---On-disk Layout: array of { id, x, y } (JSON object keys must be strings). Sorted by id for diffs.
---@alias Watchdog.LayoutArray { id: integer, x: number, y: number }[]

-- The copy is a new number so a mid-drag save cannot snap the live point.
---@param layout Watchdog.Layout|nil
---@return Watchdog.LayoutArray
local function layoutToArray(layout)
    local arr = {}
    for id, pos in pairs(layout or {}) do
        arr[#arr + 1] = { id = id, x = Util.RoundHalfAway(pos.x), y = Util.RoundHalfAway(pos.y) }
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

-- nil (pre-flag entries / omitted arg) counts as enabled.
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

--- Entry-tree helpers (id-keyed) ----------------------------------------------------------

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

-- max(id)+1. Mint, then insert, before minting again - two mints on the same tree collide.
---@param doc Watchdog.Bucket
---@return integer
function Store.MintId(doc)
    local max = 0
    walk((doc or {}).entries, function(e)
        if type(e.id) == "number" and e.id > max then max = e.id end
    end)
    return max + 1
end

---@param doc Watchdog.Bucket
---@return Watchdog.Entry[]
function Store.Leaves(doc)
    local leaves = {}
    walk((doc or {}).entries, function(e)
        if e.kind == "alert" then leaves[#leaves + 1] = e end
    end)
    return leaves
end

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

---@param doc Watchdog.Bucket
---@param entry Watchdog.Entry
---@param parentId integer|nil                     # nil ⇒ root; else a group entry's id
---@return boolean
function Store.InsertEntry(doc, entry, parentId)
    doc.entries = doc.entries or {}
    if parentId == nil then
        doc.entries[#doc.entries + 1] = entry
        return true
    end
    local parent = Store.FindById(doc, parentId)
    if parent == nil or parent.kind ~= "group" then
        return false
    end
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = entry
    return true
end

---@param doc Watchdog.Bucket
---@param id integer
---@return Watchdog.Entry|nil
function Store.DeleteById(doc, id)
    local entry, siblings, index = Store.FindById(doc, id)
    if entry == nil then return nil end
    table.remove(siblings, index)
    return entry
end

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

---@param doc Watchdog.Bucket
---@param id integer
---@param newParentId integer|nil                  # nil ⇒ root; else a group entry's id
---@return boolean
function Store.MoveSubtree(doc, id, newParentId)
    local entry, siblings, index = Store.FindById(doc, id)
    if entry == nil then return false end
    -- Validate destination before detach so a refused move is a no-op.
    if newParentId ~= nil then
        if subtreeContains(entry, newParentId) then return false end
        local parent = Store.FindById(doc, newParentId)
        if parent == nil or parent.kind ~= "group" then return false end
    end
    table.remove(siblings, index)
    return Store.InsertEntry(doc, entry, newParentId)
end

-- Same-parent sibling swap only (does not reparent; see LiftEntry).
---@param doc Watchdog.Bucket
---@param id integer
---@param delta integer                            # -1 = toward index 1; +1 = toward end
---@return boolean
function Store.ReorderSibling(doc, id, delta)
    if type(delta) ~= "number" or delta == 0 then return false end
    local entry, siblings, index = Store.FindById(doc, id)
    if entry == nil or siblings == nil or index == nil then return false end
    local newIndex = index + delta
    if newIndex < 1 or newIndex > #siblings then return false end
    siblings[index], siblings[newIndex] = siblings[newIndex], siblings[index]
    return true
end

-- Lift one level; insert immediately before the former parent (MoveSubtree appends instead).
---@param doc Watchdog.Bucket
---@param id integer
---@return boolean
function Store.LiftEntry(doc, id)
    local entry, siblings, index = Store.FindById(doc, id)
    if entry == nil or siblings == nil or index == nil then return false end
    local ancestors = Store.AncestorIds(doc, id)
    if #ancestors == 0 then return false end
    local parentId = ancestors[#ancestors]
    local newParentId = (#ancestors >= 2) and ancestors[#ancestors - 1] or nil
    table.remove(siblings, index)
    ---@type Watchdog.Entry[]
    local dest
    if newParentId == nil then
        doc.entries = doc.entries or {}
        dest = doc.entries
    else
        local grand = Store.FindById(doc, newParentId)
        if grand == nil or grand.kind ~= "group" then
            -- Destination vanished mid-op - put the entry back where it was.
            table.insert(siblings, index, entry)
            return false
        end
        grand.children = grand.children or {}
        dest = grand.children
    end
    local insertAt = nil
    for i, e in ipairs(dest) do
        if e.id == parentId then
            insertAt = i
            break
        end
    end
    if insertAt == nil then
        table.insert(siblings, index, entry)
        return false
    end
    table.insert(dest, insertAt, entry)
    return true
end

--- Enabled-chain --------------------------------------------------------------------------
-- Alert fires iff own `enabled` AND every ancestor group's `enabled`. Disabling a group does
-- not touch descendant flags; re-enable restores prior per-alert state. Resolved live (no cache).

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

---@param doc Watchdog.Bucket
---@param id integer
---@return integer[]
function Store.AncestorIds(doc, id)
    local chain = ancestorsOf((doc or {}).entries, id)
    if chain == nil then return {} end
    local ids = {}
    for _, g in ipairs(chain) do ids[#ids + 1] = g.id end
    return ids
end

-- Deepest group containing every id as a descendant; nil when the common parent is the Bucket root.
---@param doc Watchdog.Bucket
---@param ids integer[]
---@return integer|nil
function Store.NearestCommonAncestor(doc, ids)
    if ids == nil or #ids == 0 then return nil end
    local prefix = Store.AncestorIds(doc, ids[1])
    for i = 2, #ids do
        local chain = Store.AncestorIds(doc, ids[i])
        local n = math.min(#prefix, #chain)
        local kept = 0
        for j = 1, n do
            if prefix[j] ~= chain[j] then break end
            kept = j
        end
        for j = #prefix, kept + 1, -1 do prefix[j] = nil end
    end
    if #prefix == 0 then return nil end
    return prefix[#prefix]
end

-- Caller persists.
---@param doc Watchdog.Bucket
---@param ids integer[]
---@param name string|nil
---@return integer|nil
function Store.GroupSelected(doc, ids, name)
    if ids == nil or #ids == 0 then return nil end
    local parentId = Store.NearestCommonAncestor(doc, ids)
    local newId = Store.MintId(doc)
    local group = Store.NewGroupEntry(newId, name or "New Group", true, {})
    if not Store.InsertEntry(doc, group, parentId) then return nil end
    for _, id in ipairs(ids) do
        Store.MoveSubtree(doc, id, newId)
    end
    return newId
end

-- Remint colliding ids in `entry`'s subtree; free ids in dest are preserved.
---@param entry Watchdog.Entry
---@param destDoc Watchdog.Bucket
local function remintCollidingIds(entry, destDoc)
    local used = {}
    walk((destDoc or {}).entries, function(e)
        if type(e.id) == "number" then used[e.id] = true end
    end)
    -- Reserve free ids from the moved subtree so remints don't steal them.
    local function reserve(e)
        if used[e.id] == nil then used[e.id] = "keep" end
        for _, c in ipairs(e.children or {}) do reserve(c) end
    end
    reserve(entry)
    local function nextFree()
        local n = 1
        while used[n] ~= nil do n = n + 1 end
        return n
    end
    local function fix(e)
        if used[e.id] ~= "keep" then
            local newId = nextFree()
            used[newId] = "keep"
            e.id = newId
        end
        for _, c in ipairs(e.children or {}) do fix(c) end
    end
    fix(entry)
end

---@param srcDoc Watchdog.Bucket
---@param destDoc Watchdog.Bucket
---@param id integer
---@return Watchdog.Entry|nil
function Store.MoveEntryToBucket(srcDoc, destDoc, id)
    local entry = Store.DeleteById(srcDoc, id)
    if entry == nil then return nil end
    remintCollidingIds(entry, destDoc)
    Store.InsertEntry(destDoc, entry, nil)
    return entry
end

-- Upstream half of the enabled-chain (excludes own flag). Root / missing id → true.
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

---@param doc Watchdog.Bucket
---@param id integer
---@return boolean
function Store.EnabledChain(doc, id)
    local entry = Store.FindById(doc, id)
    if entry == nil then return false end
    return normalizeEnabled(entry.enabled) and Store.AncestorsEnabled(doc, id)
end

--- Entry construction ---------------------------------------------------------------------

---@param id integer
---@param name string
---@param graph LibNodeGraph.Graph                 # a live graph; serialized into the entry here
---@param layout Watchdog.Layout|nil
---@param enabled boolean|nil
---@return Watchdog.Entry
function Store.NewAlertEntry(id, name, graph, layout, enabled)
    Text.StripGraphText(graph)
    return {
        id = id,
        kind = "alert",
        name = Text.StripTags(name),
        enabled = normalizeEnabled(enabled),
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutToArray(layout),
    }
end

---@param id integer
---@param name string
---@param enabled boolean|nil
---@param children Watchdog.Entry[]|nil
---@return Watchdog.Entry
function Store.NewGroupEntry(id, name, enabled, children)
    return {
        id = id,
        kind = "group",
        name = Text.StripTags(name),
        enabled = normalizeEnabled(enabled),
        children = children or {},
    }
end

--- Mutation by id -------------------------------------------------------------------------

-- Keyed by `id`. Does not persist; caller Save.
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

-- Names are not unique; this only mutates the targeted id. Does not persist; caller Save.
---@param doc Watchdog.Bucket
---@param id integer
---@param name string
---@return boolean
function Store.SetName(doc, id, name)
    local entry = Store.FindById(doc, id)
    if entry == nil then return false end
    name = Text.StripTags(name)
    -- A tag-only rename would store a blank label. Leave the previous name.
    if name == "" then return false end
    entry.name = name
    return true
end

---@param doc Watchdog.Bucket
---@param id integer
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@return boolean
function Store.UpdateAlertGraph(doc, id, graph, layout)
    local entry = Store.FindById(doc, id)
    if entry == nil or entry.kind ~= "alert" then return false end
    Text.StripGraphText(graph)
    entry.graph = LibNodeGraph.Serialize(graph)
    entry.layout = layoutToArray(layout)
    return true
end

--- Restore --------------------------------------------------------------------------------

-- Every alert leaf. Unknown node types load as placeholders; pcall skips a corrupt graph.
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
            Text.StripGraphText(graph)
            restored[#restored + 1] = {
                id = entry.id,
                name = entry.name,
                graph = graph,
                layout = layoutFromArray(entry.layout),
                enabled = normalizeEnabled(entry.enabled),
            }
        elseif log ~= nil then
            log("Watchdog: skipping unrestorable alert '" .. tostring(entry.name) .. "' - " .. tostring(graph))
        end
    end
    return restored
end

--- InfoBox Area anchor --------------------------------------------------------------------
-- Strip position is bucket-level, not per-entry.

---@param doc Watchdog.Bucket
---@param x number
---@param y number
function Store.SetInfoBoxAnchor(doc, x, y)
    doc.infoboxAnchor = { x = x, y = y }
end

---@param doc Watchdog.Bucket
---@return number|nil x
---@return number|nil y
function Store.GetInfoBoxAnchor(doc)
    local a = doc.infoboxAnchor
    if a == nil then return nil, nil end
    return a.x, a.y
end

-- Dismiss On is read here, on the saved document, before RestoreAll deserializes.
-- A missing Sticky is still missing at this point; AddNode would fill it false.
---@param entries Watchdog.Entry[]|nil
local function migrateSavedGraphs(entries)
    DropDismissOn.ApplyEntries(entries)
end

-- A tag-only name would draw a blank row.
---@param entries Watchdog.Entry[]|nil
local function stripEntryNames(entries)
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" then
            if type(entry.name) == "string" then
                local stripped = Text.StripTags(entry.name)
                if stripped == "" then
                    entry.name = entry.kind == "group" and "Group" or "Alert"
                else
                    entry.name = stripped
                end
            end
            stripEntryNames(entry.children)
        end
    end
end

--- persistentdb I/O -----------------------------------------------------------------------

---@param doc Watchdog.Bucket
---@return string|nil  # the JSON text, or nil if no codec is available / encoding failed
function Store.Encode(doc)
    local c = codec()
    if c == nil then return nil end
    local ok, text = pcall(function() return c.encode(doc) end)
    if ok then return text end
    return nil
end

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
        if log ~= nil then log("Watchdog: saved bucket '" .. tostring(key) .. "' unreadable, left on disk - " .. tostring(doc)) end
        return Store.Empty()
    end
    doc.version = doc.version or DOC_VERSION
    doc.entries = doc.entries or {}
    stripEntryNames(doc.entries)
    migrateSavedGraphs(doc.entries)
    return doc
end

---@return Watchdog.Bucket doc  # the same shape Store.Save persists (the round-trip contract)
function Store.Load()
    return Store.LoadKey(DB_KEY)
end

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
    if not ok and log ~= nil then
        log("Watchdog: failed to save bucket '" .. tostring(key) .. "'")
    end
    return ok
end

---@param doc Watchdog.Bucket  # the same shape Store.Load returns (the round-trip contract)
---@return boolean  # true if the document was encoded and written
function Store.Save(doc)
    return Store.SaveTo(DB_KEY, doc)
end

return Store
