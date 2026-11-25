-- store.lua - PersistentDB Buckets and the Entry tree (LibNodeGraph never touches persistentdb).
--
-- One Bucket per scope: `{ version, entries, infoboxAnchor }` under an un-prefixed key
-- (`global` or `player_<tracking id>` - PersistentDB is already plugin-scoped).
--
-- A scope that has moved keeps the tree at `scope_global` or `scope_player_<tracking id>`
-- and each alert graph at `..._alert_<id>`. Those values are WD1 tokens. Callers still
-- pass the scope identity. This module maps it to the stored name. While the new key is
-- absent, load still reads the un-prefixed document. Saves write the new keys and leave
-- that document where it is, so a later edit cannot copy a deleted alert back.
--
-- `id` is identity: every op keys on `id`, never `name` (display text, not unique). Alerts
-- carry Serialize `graph` + `layout`; groups carry `children`. Layout is an array of
-- `{ id, x, y }` because JSON object keys must be strings; it round-trips to a nodeId-keyed
-- map on load (valid because Deserialize preserves node ids).

local Util = require("src/util")
local Text = require("src/text")
local DropDismissOn = require("src/drop_dismiss_on")
local Compress = require("src/compress")

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
    -- Reading the key back would treat a stale read as a second answer.
    local ok, stored = pcall(function() return PersistentDB:SetString(key, text) end)
    if not ok or stored ~= true then
        if log ~= nil then
            log("Watchdog: failed to save bucket '" .. tostring(key) .. "'")
        end
        return false
    end
    return true
end

---@param doc Watchdog.Bucket  # the same shape Store.Load returns (the round-trip contract)
---@return boolean  # true if the document was encoded and written
function Store.Save(doc)
    return Store.SaveTo(DB_KEY, doc)
end

--- Split keys -------------------------------------------------------------------------------
-- Document versions sit inside the JSON, after WD1 is removed. The scope tree is
-- version 3. An alert key is version 1 and the graph keeps the version Serialize wrote.

local SCOPE_DOC_VERSION = 3
local ALERT_DOC_VERSION = 1

-- PersistentDB leaves the previous bytes when the value is longer than this.
-- The cap is the stored WD1 token, not the JSON. Refuse before SetString so
-- there is no raw JSON fallback and the caller can say it is too big.
local STORED_TOKEN_CAP = 131070

-- An unreadable key stays blocked for this PersistentDB. A swapped database
-- starts clear, so a test that replaces PersistentDB is not stuck on the old one.
local blockedDb
local blocked = {}

---@return table<string, boolean>
local function blockedSet()
    if blockedDb ~= PersistentDB then
        blockedDb = PersistentDB
        blocked = {}
    end
    return blocked
end

---@param storageKey string
local function blockKey(storageKey)
    blockedSet()[storageKey] = true
end

---@param storageKey string
---@return boolean
local function keyBlocked(storageKey)
    return blockedSet()[storageKey] == true
end

-- Callers pass `global` or `player_<tracking id>`. The stored name is the
-- scope key, not that identity.
---@param identity string
---@return string|nil
local function scopeStorageKey(identity)
    if identity == "global" then return "scope_global" end
    if type(identity) == "string" and identity:match("^player_.+") ~= nil then
        return "scope_" .. identity
    end
    return nil
end

---@param identity string
---@param id integer
---@return string|nil
local function alertStorageKey(identity, id)
    local scopeKey = scopeStorageKey(identity)
    if scopeKey == nil or type(id) ~= "number" then return nil end
    return scopeKey .. "_alert_" .. id
end

---@param text string|nil
---@return table|nil
local function decodeToken(text)
    if type(text) ~= "string" or text == "" then return nil end
    if text:sub(1, #Compress.PREFIX) ~= Compress.PREFIX then return nil end
    local inflated, json = pcall(Compress.decompress, text)
    if not inflated or type(json) ~= "string" then return nil end
    local c = codec()
    if c == nil then return nil end
    local ok, doc = pcall(function() return c.decode(json) end)
    if not ok or type(doc) ~= "table" then return nil end
    return doc
end

-- The tree is id, kind, name, enabled, and children. Graph and layout stay on
-- the alert key even when the in-memory entry still has them.
---@param entry Watchdog.Entry
---@return table
local function treeEntry(entry)
    local copy = {
        id = entry.id,
        kind = entry.kind,
        name = entry.name,
        enabled = entry.enabled ~= false,
    }
    if entry.kind == "group" then
        local children = {}
        for i, child in ipairs(entry.children or {}) do
            children[i] = treeEntry(child)
        end
        copy.children = children
    end
    return copy
end

---@param storageKey string
---@param payload table
---@return boolean
local function writeToken(storageKey, payload)
    if PersistentDB == nil then return false end
    local c = codec()
    if c == nil then
        if log ~= nil then log("Watchdog: failed to encode bucket for save") end
        return false, "failed"
    end
    local encoded, json = pcall(function() return c.encode(payload) end)
    if not encoded or type(json) ~= "string" then
        if log ~= nil then log("Watchdog: failed to encode bucket for save") end
        return false, "failed"
    end
    local compressed, token = pcall(Compress.compress, json)
    if not compressed or type(token) ~= "string" then
        if log ~= nil then log("Watchdog: failed to save bucket '" .. storageKey .. "'") end
        return false, "failed"
    end
    if #token > STORED_TOKEN_CAP then
        if log ~= nil then log("Watchdog: failed to save bucket '" .. storageKey .. "'") end
        return false, "size"
    end
    -- False, nil, and a throw leave the previous bytes. A true return is the save.
    local ok, stored = pcall(function() return PersistentDB:SetString(storageKey, token) end)
    if not ok or stored ~= true then
        if log ~= nil then log("Watchdog: failed to save bucket '" .. storageKey .. "'") end
        return false, "failed"
    end
    return true
end

---@param identity string
---@param entries Watchdog.Entry[]|nil
local function attachAlertGraphs(identity, entries)
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" and entry.kind == "alert" then
            -- A version-3 row that still carries a graph is ignored. The alert key wins.
            entry.graph = nil
            entry.layout = nil
            local key = alertStorageKey(identity, entry.id)
            local text
            local got = true
            if key ~= nil and PersistentDB ~= nil then
                got = pcall(function() text = PersistentDB:GetString(key) end)
            end
            local payload = got and decodeToken(text) or nil
            if payload ~= nil and payload.version == ALERT_DOC_VERSION and type(payload.graph) == "table" then
                entry.graph = payload.graph
                entry.layout = payload.layout
            elseif key ~= nil and (not got or (type(text) == "string" and text ~= "")) then
                -- Missing is not frozen: a later save may create the key.
                -- Bytes that are present but not a version-1 alert stay.
                blockKey(key)
            end
        elseif type(entry) == "table" and entry.children ~= nil then
            attachAlertGraphs(identity, entry.children)
        end
    end
end

-- A new key that is not a version-3 tree must not be replaced. An absent key
-- is not frozen: that is still the legacy document, or a scope not saved yet.
---@param key string
---@return boolean
local function scopeIsFrozen(key)
    if keyBlocked(key) then return true end
    if PersistentDB == nil then return false end
    local text
    local got = pcall(function() text = PersistentDB:GetString(key) end)
    if not got then
        blockKey(key)
        return true
    end
    if type(text) ~= "string" or text == "" then return false end
    local payload = decodeToken(text)
    if payload ~= nil and payload.version == SCOPE_DOC_VERSION and type(payload.entries) == "table" then
        return false
    end
    blockKey(key)
    return true
end

-- True is the only success. False, nil, and a throw leave the key.
---@param identity string
---@param id integer
---@return boolean
local function deleteStoredAlert(identity, id)
    local key = alertStorageKey(identity, id)
    if key == nil or PersistentDB == nil then return false end
    local ok, deleted = pcall(function() return PersistentDB:Delete(key) end)
    if not ok or deleted ~= true then
        if log ~= nil then
            log("Watchdog: failed to delete alert key '" .. key .. "'")
        end
        return false
    end
    blockedSet()[key] = nil
    return true
end

---@param identity string
---@param entry Watchdog.Entry
---@return boolean
---@return "size"|"failed"|nil reason
function Store.SaveAlert(identity, entry)
    if type(entry) ~= "table" or entry.kind ~= "alert" then return false, "failed" end
    local scopeKey = scopeStorageKey(identity)
    if scopeKey ~= nil and scopeIsFrozen(scopeKey) then return false, "failed" end
    local key = alertStorageKey(identity, entry.id)
    if key == nil or keyBlocked(key) then return false, "failed" end
    return writeToken(key, {
        version = ALERT_DOC_VERSION,
        graph = entry.graph,
        layout = entry.layout or {},
    })
end

---@param identity string
---@param doc Watchdog.Bucket
---@return boolean
---@return "size"|"failed"|nil reason
function Store.SaveScope(identity, doc)
    local key = scopeStorageKey(identity)
    if key == nil or type(doc) ~= "table" then return false, "failed" end
    if scopeIsFrozen(key) then return false, "failed" end
    local entries = {}
    for i, entry in ipairs(doc.entries or {}) do
        entries[i] = treeEntry(entry)
    end
    local payload = {
        version = SCOPE_DOC_VERSION,
        entries = entries,
    }
    -- The infobox anchor lives on the global tree only.
    if identity == "global" and type(doc.infoboxAnchor) == "table" then
        payload.infoboxAnchor = { x = doc.infoboxAnchor.x, y = doc.infoboxAnchor.y }
    end
    return writeToken(key, payload)
end

-- One alert changed. A scope that already has its key writes that alert and
-- leaves every other graph alone. While the new key is still absent, every
-- alert has to be stored before the tree, or the next load would list a graph
-- that was never written.
---@param identity string
---@param doc Watchdog.Bucket
---@param entry Watchdog.Entry
---@return boolean
---@return "size"|"failed"|nil reason
---@return string|nil name
function Store.SaveEditedAlert(identity, doc, entry)
    if Store.ScopeStorage(identity) ~= "split" then
        return Store.PersistScope(identity, doc)
    end
    return Store.SaveAlert(identity, entry)
end

-- The tree changed and no graph did. Same split: the scope key alone. A scope
-- still on the legacy document stores every alert first, then the tree.
---@param identity string
---@param doc Watchdog.Bucket
---@return boolean
---@return "size"|"failed"|nil reason
---@return string|nil name
function Store.SaveTree(identity, doc)
    if Store.ScopeStorage(identity) ~= "split" then
        return Store.PersistScope(identity, doc)
    end
    return Store.SaveScope(identity, doc)
end

-- The tree no longer names these alerts. Write that tree first. Only a scope
-- that already had its key has alert keys to delete, and only after the tree
-- write returns true. A failed delete leaves the key. The alert stays out of
-- the tree either way.
---@param identity string
---@param doc Watchdog.Bucket
---@param ids integer[]
---@return boolean
---@return "size"|"failed"|nil reason
---@return string|nil name
function Store.RemoveAlerts(identity, doc, ids)
    if Store.ScopeStorage(identity) ~= "split" then
        return Store.PersistScope(identity, doc)
    end
    local ok, reason = Store.SaveScope(identity, doc)
    if not ok then return false, reason end
    for _, id in ipairs(ids or {}) do
        deleteStoredAlert(identity, id)
    end
    return true
end

-- Destination alert keys first, then the destination tree, then the source
-- tree, then each source key. A failed write stops before the delete, so the
-- source tree still names a graph that is still stored. A failed delete leaves
-- the source key. The same id in two scopes is two keys.
---@param srcIdentity string
---@param srcDoc Watchdog.Bucket
---@param destIdentity string
---@param destDoc Watchdog.Bucket
---@param destEntries Watchdog.Entry[]
---@param srcIds integer[]
---@return boolean
---@return "size"|"failed"|nil reason
---@return string|nil name
function Store.TransferAlerts(srcIdentity, srcDoc, destIdentity, destDoc, destEntries, srcIds)
    if Store.ScopeStorage(destIdentity) == "split" then
        for _, entry in ipairs(destEntries or {}) do
            local ok, reason = Store.SaveAlert(destIdentity, entry)
            if not ok then return false, reason, entry.name end
        end
        local ok, reason = Store.SaveScope(destIdentity, destDoc)
        if not ok then return false, reason end
    else
        local ok, reason, name = Store.PersistScope(destIdentity, destDoc)
        if not ok then return false, reason, name end
    end
    if Store.ScopeStorage(srcIdentity) ~= "split" then
        return Store.PersistScope(srcIdentity, srcDoc)
    end
    local ok, reason = Store.SaveScope(srcIdentity, srcDoc)
    if not ok then return false, reason end
    for _, id in ipairs(srcIds or {}) do
        deleteStoredAlert(srcIdentity, id)
    end
    return true
end

-- Only the old numeric character keys are still documents. A display-name
-- `player_*` key is not a scope.
---@param identity string
---@return boolean
local function legacyIdentity(identity)
    return identity == "global" or (type(identity) == "string" and identity:match("^player_%d+$") ~= nil)
end

-- "split" is a version-3 tree already on disk. "unreadable" must not be written.
-- "legacy" is the old document. "absent" has neither.
---@param identity string
---@return "split"|"legacy"|"unreadable"|"absent"
function Store.ScopeStorage(identity)
    local key = scopeStorageKey(identity)
    if key == nil or PersistentDB == nil then return "absent" end
    if scopeIsFrozen(key) then return "unreadable" end
    local text
    local got = pcall(function() text = PersistentDB:GetString(key) end)
    if not got then return "unreadable" end
    if type(text) == "string" and text ~= "" then return "split" end
    if legacyIdentity(identity) then return "legacy" end
    return "absent"
end

---@param identity string
---@return Watchdog.Bucket doc
---@return string[]|nil unreadNames
---@return "unreadable"|nil problem
function Store.LoadScope(identity)
    if PersistentDB == nil then return Store.Empty() end
    local key = scopeStorageKey(identity)
    if key == nil then return Store.Empty() end
    local text
    local got = pcall(function() text = PersistentDB:GetString(key) end)
    if not got then
        blockKey(key)
        return Store.Empty(), nil, "unreadable"
    end
    if type(text) ~= "string" or text == "" then
        if legacyIdentity(identity) then
            return Store.LoadKey(identity)
        end
        return Store.Empty()
    end
    local payload = decodeToken(text)
    if payload == nil or payload.version ~= SCOPE_DOC_VERSION or type(payload.entries) ~= "table" then
        blockKey(key)
        return Store.Empty(), nil, "unreadable"
    end
    attachAlertGraphs(identity, payload.entries)
    stripEntryNames(payload.entries)
    migrateSavedGraphs(payload.entries)
    local unread = {}
    local function collectUnread(entries)
        for _, entry in ipairs(entries or {}) do
            if type(entry) == "table" and entry.kind == "alert" and type(entry.graph) ~= "table" then
                unread[#unread + 1] = entry.name or "Alert"
            elseif type(entry) == "table" and entry.children ~= nil then
                collectUnread(entry.children)
            end
        end
    end
    collectUnread(payload.entries)
    return payload, unread
end

-- The new key is absent, so this scope still lives on the legacy document.
-- An unreadable new key is not absent: nothing here may replace it.
---@param identity string
---@return boolean
local function newScopeAbsent(identity)
    local key = scopeStorageKey(identity)
    if key == nil or PersistentDB == nil or scopeIsFrozen(key) then return false end
    local text
    local got = pcall(function() text = PersistentDB:GetString(key) end)
    if not got then return false end
    return type(text) ~= "string" or text == ""
end

-- Alert tokens first. The scope key is written only after every one of them
-- is stored, so a later load never lists an alert whose graph was not written.
-- The legacy key is not written or deleted. It stays the pre-migration snapshot.
---@param identity string
---@return { identity: string, reason: "size"|"failed", name: string|nil }|nil
local function migrateIdentity(identity)
    if not legacyIdentity(identity) or not newScopeAbsent(identity) then return nil end
    local text
    local got = pcall(function() text = PersistentDB:GetString(identity) end)
    if not got or type(text) ~= "string" or text == "" then return nil end
    -- Bytes that do not decode are not an empty tree. Creating the new key
    -- would hide them, and the next startup would not try again.
    local c = codec()
    local decodedOk, decoded = false, nil
    if c ~= nil then
        decodedOk, decoded = pcall(function() return c.decode(text) end)
    end
    if not decodedOk or type(decoded) ~= "table" then
        if log ~= nil then
            log("Watchdog: saved bucket '" .. identity .. "' unreadable, left on disk - " .. tostring(decoded))
        end
        return nil
    end
    local doc = Store.LoadKey(identity)
    local ok, reason, name = Store.PersistScope(identity, doc)
    if not ok then
        return { identity = identity, reason = reason or "failed", name = name }
    end
    return nil
end

-- A non-empty legacy value that does not decode must not gain a new key.
-- An empty in-memory tree with no legacy document and no anchor is not a
-- save: writing one would make the next startup skip migration.
---@param identity string
---@param doc Watchdog.Bucket
---@return boolean blocked
---@return boolean inventing
local function emptyWriteGuard(identity, doc)
    if not newScopeAbsent(identity) or not legacyIdentity(identity) then
        return false, false
    end
    local text
    local got = pcall(function() text = PersistentDB:GetString(identity) end)
    if not got then return true, false end
    if type(text) ~= "string" or text == "" then
        local anchor = type(doc.infoboxAnchor) == "table"
        local hasEntries = type(doc.entries) == "table" and #doc.entries > 0
        return false, not anchor and not hasEntries
    end
    local c = codec()
    local decodedOk, decoded = false, nil
    if c ~= nil then
        decodedOk, decoded = pcall(function() return c.decode(text) end)
    end
    if not decodedOk or type(decoded) ~= "table" then
        return true, false
    end
    return false, false
end

-- Writes every alert key, then the scope key. While the scope key is absent
-- this is the migration: one alert that does not fit leaves that key absent
-- and does not touch the legacy document. A later save of a scope that already
-- has its key uses the same writes and still does not touch the legacy key.
---@param identity string
---@param doc Watchdog.Bucket
---@return boolean
---@return "size"|"failed"|nil reason
---@return string|nil name
function Store.PersistScope(identity, doc)
    if type(doc) ~= "table" then return false, "failed" end
    local key = scopeStorageKey(identity)
    if key == nil or scopeIsFrozen(key) then return false, "failed" end
    local blocked, inventing = emptyWriteGuard(identity, doc)
    if blocked then return false, "failed" end
    if inventing then return true end
    for _, entry in ipairs(Store.Leaves(doc)) do
        local ok, reason = Store.SaveAlert(identity, entry)
        if not ok then
            return false, reason or "failed", entry.name
        end
    end
    local ok, reason = Store.SaveScope(identity, doc)
    if not ok then
        return false, reason or "failed"
    end
    return true
end

-- Nil means the list itself failed. Callers still migrate `global`, and the
-- current character once the bucket loader knows the tracking id.
---@return string[]|nil
local function listStorageKeys()
    if PersistentDB == nil or type(PersistentDB.IterateEntries) ~= "function" then
        return nil
    end
    local keys = {}
    local ok = pcall(function()
        PersistentDB:IterateEntries(function(key)
            if type(key) == "string" then
                keys[#keys + 1] = key
            end
        end)
    end)
    if not ok then return nil end
    return keys
end

-- Keys are copied out of IterateEntries before any migration write. A failed
-- list still migrates `global`. Numeric character keys are migrated from that
-- copy. A display-name `player_*` key is not read. Tracking permission is not
-- consulted: the id is already in the key.
---@return { identity: string, reason: "size"|"failed", name: string|nil }[]
function Store.MigrateListed()
    local listed = listStorageKeys()
    local failures = {}
    local function take(identity)
        local fail = migrateIdentity(identity)
        if fail ~= nil then
            failures[#failures + 1] = fail
            -- This character is not armed yet. The load that arms it shows
            -- the dialog. Until then the failure is only a log line, and the
            -- next key in the list still migrates.
            if log ~= nil then
                log("Watchdog: could not migrate scope '" .. tostring(identity) .. "'")
            end
        end
    end
    take("global")
    if listed ~= nil then
        for _, key in ipairs(listed) do
            if key:match("^player_%d+$") ~= nil then
                take(key)
            end
        end
    end
    return failures
end

-- The bucket loader calls this once it knows the tracking id, and it finishes
-- before that scope is armed. A character the startup list never saw still
-- moves here. An identity that already has its new key is left alone.
---@param identity string
---@return { identity: string, reason: "size"|"failed", name: string|nil }|nil
function Store.MigrateScope(identity)
    return migrateIdentity(identity)
end

return Store
