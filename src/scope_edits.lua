-- Alert Manager mutations and the Editor's Bucket writes.
--
-- main.lua passes the Store and the runtime in. This module does not read them
-- back out of main, and it does not show, hide, or rename the Editor. Each
-- operation returns one of four results; main applies that result:
--   { kind = "open", scopeKey = ..., alertId = ... }  open the Editor on this Alert
--   { kind = "close" }                                 close the Editor
--   { kind = "rename", name = ... }                   the open Alert has a new name
--   { kind = "leave" }                                 leave the Editor as it is
--
-- The open Alert (id + Scope key, plus its graph and Layout when a write must
-- land before the Entry moves or disappears) is passed in by the caller. This
-- module never calls navBack.

local Export = require("src/export")
local PresetCopy = require("src/preset_copy")

---@class Watchdog.EditorResult
---@field kind "open"|"close"|"rename"|"leave"
---@field scopeKey string|nil
---@field alertId integer|nil
---@field name string|nil

---@class Watchdog.ScopeEdits
---@field store table
---@field runtime table
---@field registry LibNodeGraph.Registry|nil
---@field lookup (fun(scopeKey: string): Watchdog.Bucket|nil, string|nil, Watchdog.RestoredAlert[]|nil)|nil
---@field onSaveFailed fun()|nil
---@field _savedEncode string|nil
---@field _pendingAlerts table<string, integer[]>
---@field _sizeWarned boolean
local ScopeEdits = {}
ScopeEdits.__index = ScopeEdits

local function leave()
    return { kind = "leave" }
end

---@param entry Watchdog.Entry
---@return Watchdog.Entry
local function cloneEntry(entry)
    local copy = {
        id = entry.id,
        kind = entry.kind,
        name = entry.name,
        enabled = entry.enabled,
        graph = entry.graph,
        layout = entry.layout,
    }
    if entry.children ~= nil then
        copy.children = {}
        for i, child in ipairs(entry.children) do
            copy.children[i] = cloneEntry(child)
        end
    end
    return copy
end

---@param list Watchdog.RestoredAlert[]
---@param ids integer[]
local function purgeAlertList(list, ids)
    local drop = {}
    for _, id in ipairs(ids) do drop[id] = true end
    for i = #list, 1, -1 do
        if drop[list[i].id] then table.remove(list, i) end
    end
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

---@param entry Watchdog.Entry
---@param out integer[]
local function collectAlertIds(entry, out)
    if entry.kind == "alert" then
        out[#out + 1] = entry.id
    else
        for _, child in ipairs(entry.children or {}) do
            collectAlertIds(child, out)
        end
    end
end

---@param deps { onSaveFailed: fun()|nil, store: table, runtime: table, registry: LibNodeGraph.Registry|nil, bucket: fun(scopeKey: string): Watchdog.Bucket|nil, string|nil, Watchdog.RestoredAlert[]|nil }
---@return Watchdog.ScopeEdits
function ScopeEdits.new(deps)
    return setmetatable({
        store = deps.store,
        runtime = deps.runtime,
        registry = deps.registry,
        lookup = deps.bucket,
        onSaveFailed = deps.onSaveFailed,
        _savedEncode = nil,
        -- Alert ids whose key was stored, or still needs storing, while the
        -- scope tree does not name them yet. Cleared only after that tree write
        -- succeeds. Not stored. A restart drops the in-memory graph with it.
        _pendingAlerts = {},
        -- The size dialog for the open alert. Not stored. Closing the alert
        -- or a successful save clears it, so the next oversize edit warns again.
        _sizeWarned = false,
    }, ScopeEdits)
end

---@param scopeKey string
---@return Watchdog.Bucket|nil doc
---@return string|nil key
---@return Watchdog.RestoredAlert[]|nil list
function ScopeEdits:_bucket(scopeKey)
    if self.lookup == nil then return nil end
    return self.lookup(scopeKey)
end

-- Enable does not use this. A refused write tells the player; the bytes stay as they were.
-- A scope that already has its key writes the tree only. One still on the legacy
-- document stores every alert first, then the tree.
---@param key string
---@param doc Watchdog.Bucket
---@return boolean
function ScopeEdits:_save(key, doc)
    local ok, reason = self.store.SaveTree(key, doc)
    if ok ~= true and self.onSaveFailed ~= nil then
        self.onSaveFailed(reason)
    end
    return ok == true
end

---@param reason string|nil
function ScopeEdits:_report(reason)
    if self.onSaveFailed ~= nil then
        self.onSaveFailed(reason)
    end
end

-- A scope already on the new keys writes each changed alert, then the tree.
-- A scope still on the legacy document writes every alert, then the tree, and
-- does not write the legacy key. An unreadable scope is the caller's job to
-- refuse before it changes the tree.
--
-- A failed alert or tree write keeps the new ids pending. The alert key is
-- not deleted: the tree has to name it before anything removes it. The next
-- save of an alert on this scope writes those keys again, then the tree.
---@param key string
---@param doc Watchdog.Bucket
---@param entries Watchdog.Entry[]
---@return boolean
function ScopeEdits:_saveCreated(key, doc, entries)
    if self.store.ScopeStorage(key) ~= "split" then
        return self:_save(key, doc)
    end
    local ids = self._pendingAlerts[key] or {}
    local seen = {}
    for _, id in ipairs(ids) do seen[id] = true end
    for _, entry in ipairs(entries) do
        if entry ~= nil and entry.id ~= nil and not seen[entry.id] then
            ids[#ids + 1] = entry.id
            seen[entry.id] = true
        end
    end
    self._pendingAlerts[key] = ids
    local ok, reason = self:_writePending(key, doc, nil)
    if not ok then self:_report(reason) end
    return ok
end

-- Pending alert keys, then the scope tree. `entry` is the alert being saved
-- now, so its graph is the one just edited, not the copy from the failed create.
-- A true tree write clears the pending ids. A false one leaves them, and leaves
-- every alert key that was already stored.
---@param key string
---@param doc Watchdog.Bucket
---@param entry Watchdog.Entry|nil
---@return boolean ok
---@return "size"|"failed"|nil reason
---@return boolean treeFailed
function ScopeEdits:_writePending(key, doc, entry)
    local ids = self._pendingAlerts[key]
    if ids == nil then
        if entry == nil then return true end
        local ok, reason = self.store.SaveEditedAlert(key, doc, entry)
        return ok == true, reason, false
    end
    local wrote = {}
    if entry ~= nil then
        local ok, reason = self.store.SaveAlert(key, entry)
        if not ok then return false, reason, false end
        wrote[entry.id] = true
    end
    for _, id in ipairs(ids) do
        if not wrote[id] then
            local pending = self.store.FindById(doc, id)
            if pending ~= nil and pending.kind == "alert" then
                local ok, reason = self.store.SaveAlert(key, pending)
                if not ok then return false, reason, false end
            end
        end
    end
    local ok, reason = self.store.SaveScope(key, doc)
    if ok then self._pendingAlerts[key] = nil end
    return ok == true, reason, ok ~= true
end

-- Flips one Entry. A disabled Group does not flip child alert.enabled; firing
-- stops through the ancestor check, so this only releases visuals those children
-- already spawned. An Alert's own flag is what the runtime reads.
---@param scopeKey string
---@param id integer
---@return Watchdog.EditorResult
function ScopeEdits:ToggleEnabled(scopeKey, id)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    if self.store.ScopeStorage(key) == "unreadable" then return leave() end
    local entry = self.store.FindById(doc, id)
    if entry == nil then return leave() end
    local nextEnabled = not (entry.enabled ~= false)
    self.store.SetEnabled(doc, id, nextEnabled)
    -- A tree that does not fit uses the size dialog, every time. Any other
    -- failure stays the enable log line, and the new flag stays for the session.
    local ok, reason = self.store.SaveTree(key, doc)
    if ok ~= true and reason == "size" then
        self:_report(reason)
    end
    if entry.kind == "alert" then
        self.runtime:SetAlertEnabled(id, nextEnabled, key)
        local _, _, list = self:_bucket(scopeKey)
        if list ~= nil then
            for _, alert in ipairs(list) do
                if alert.id == id then alert.enabled = nextEnabled end
            end
        end
    elseif not nextEnabled then
        local alertIds = {}
        collectAlertIds(entry, alertIds)
        for _, alertId in ipairs(alertIds) do
            self.runtime:ReleaseAlertVisuals(alertId, key)
        end
    end
    return leave()
end

-- A failed save puts the previous name back so the Bucket and the runtime stay
-- on the last name that actually persisted. The Editor title changes only when
-- the renamed id is the open Alert; that decision is the returned result.
---@param scopeKey string
---@param id integer
---@param name string
---@param open { alertId: integer, scopeKey: string }|nil
---@return Watchdog.EditorResult
---@return boolean ok
function ScopeEdits:Rename(scopeKey, id, name, open)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), false end
    local entryBefore = self.store.FindById(doc, id)
    local oldName = entryBefore and entryBefore.name
    if entryBefore == nil or not self.store.SetName(doc, id, name) then return leave(), false end
    -- SetName drops client text tags. The runtime and the editor title use that stored name.
    local storedName = entryBefore.name
    if not self:_save(key, doc) then
        entryBefore.name = oldName
        return leave(), false
    end
    local entry = self.store.FindById(doc, id)
    if entry ~= nil and entry.kind == "alert" then
        self.runtime:RenameAlert(id, storedName, key)
        if list ~= nil then
            for _, alert in ipairs(list) do
                if alert.id == id then alert.name = storedName end
            end
        end
    end
    if open ~= nil and open.alertId == id and open.scopeKey == key then
        return { kind = "rename", name = storedName }, true
    end
    return leave(), true
end

---@param scopeKey string
---@param id integer
---@param open { alertId: integer, scopeKey: string }|nil
---@return Watchdog.EditorResult
function ScopeEdits:Delete(scopeKey, id, open)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    if self.store.ScopeStorage(key) == "unreadable" then return leave() end
    local entry = self.store.FindById(doc, id)
    if entry == nil then return leave() end
    local alertIds = {}
    collectAlertIds(entry, alertIds)
    local closing = self:_closing(entry, key, open)
    if closing then self:_flushOpen(open) end
    self.store.DeleteById(doc, id)
    -- Tree first. The alert keys are deleted only after that write succeeds.
    local saved, reason = self.store.RemoveAlerts(key, doc, alertIds)
    if not saved then self:_report(reason) end
    for _, alertId in ipairs(alertIds) do
        self.runtime:ReleaseAlertVisuals(alertId, key)
        self.runtime:RemoveAlert(alertId, key)
    end
    if list ~= nil then purgeAlertList(list, alertIds) end
    if closing then return { kind = "close" } end
    return leave()
end

---@param list Watchdog.RestoredAlert[]|nil
---@param id integer
---@param name string
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout
local function rememberAlert(list, id, name, graph, layout)
    if list == nil then return end
    list[#list + 1] = { id = id, name = name, graph = graph, layout = layout, enabled = true }
end

local function openEditor(scopeKey, alertId)
    return { kind = "open", scopeKey = scopeKey, alertId = alertId }
end

-- Empty graph, enabled, named "New Alert". Does not read the Preset library.
---@param scopeKey string
---@return Watchdog.EditorResult
---@return integer|nil id
function ScopeEdits:CreateFromScratch(scopeKey)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil end
    if self.store.ScopeStorage(key) == "unreadable" then return leave(), nil end
    local graph = LibNodeGraph.NewGraph(self.registry)
    local layout = {}
    local id = self.store.MintId(doc)
    local name = "New Alert"
    self.store.InsertEntry(doc, self.store.NewAlertEntry(id, name, graph, layout, true))
    -- FindById also returns the sibling list. A local keeps the entry alone.
    local entry = self.store.FindById(doc, id)
    self:_saveCreated(key, doc, { entry })
    rememberAlert(list, id, name, graph, layout)
    self.runtime:AddAlert(id, name, graph, true, key, self.store.FindById(doc, id))
    return openEditor(scopeKey, id), id
end

-- Records the Bucket's encoded text when the Editor opens, so a later autosave
-- can tell an untouched graph from a real edit. One open Alert at a time.
-- Opening starts the size warning over. Nothing about that warning is stored.
---@param scopeKey string
function ScopeEdits:NoteSaved(scopeKey)
    self._sizeWarned = false
    local doc = self:_bucket(scopeKey)
    if doc == nil then
        self._savedEncode = nil
        return
    end
    self._savedEncode = self.store.Encode(doc)
end

--- Closing the alert drops the size warning. The next open can show it again.
function ScopeEdits:NoteClosed()
    self._sizeWarned = false
end

-- Writes the open Alert's graph and Layout into its Bucket, and saves only when
-- that encoding differs from the last successful save. A create or import whose
-- tree write failed is not a successful save, so an unchanged close still writes
-- the tree. Hiding the shell and shutdown both call this; the caller decides when.
---@param scopeKey string
---@param alertId integer
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@return Watchdog.EditorResult
function ScopeEdits:Autosave(scopeKey, alertId, graph, layout)
    if scopeKey == nil or alertId == nil or graph == nil then return leave() end
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    self.store.UpdateAlertGraph(doc, alertId, graph, layout)
    local encoded = self.store.Encode(doc)
    local treePending = self._pendingAlerts[key] ~= nil
    if (encoded == nil or encoded == self._savedEncode) and not treePending then
        -- Back to the last saved graph. The next oversize edit warns again.
        self._sizeWarned = false
        return leave()
    end
    local entry = self.store.FindById(doc, alertId)
    local ok, reason, treeFailed
    if self._pendingAlerts[key] ~= nil and self.store.ScopeStorage(key) == "split" then
        -- The create or import stored the alert key and then failed the tree.
        -- This save writes that key again, then the tree that names it.
        ok, reason, treeFailed = self:_writePending(key, doc, entry)
    else
        ok, reason = self.store.SaveEditedAlert(key, doc, entry)
        if ok then self._pendingAlerts[key] = nil end
    end
    if ok then
        self._savedEncode = encoded
        self._sizeWarned = false
    elseif reason == "size" and treeFailed then
        -- A tree that does not fit warns on every failed save. The alert's
        -- own size warning stays once per open.
        self:_report(reason)
    elseif reason == "size" then
        if not self._sizeWarned then
            self._sizeWarned = true
            self:_report(reason)
        end
    else
        self:_report(reason)
    end
    return leave()
end

---@param scopeKey string
---@param id integer
---@param delta integer
---@return Watchdog.EditorResult
function ScopeEdits:ReorderSibling(scopeKey, id, delta)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    if not self.store.ReorderSibling(doc, id, delta) then return leave() end
    self:_save(key, doc)
    return leave()
end

---@param scopeKey string
---@param id integer
---@return Watchdog.EditorResult
function ScopeEdits:Lift(scopeKey, id)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    if not self.store.LiftEntry(doc, id) then return leave() end
    self:_save(key, doc)
    return leave()
end

---@param scopeKey string
---@return Watchdog.EditorResult
---@return integer|nil id
function ScopeEdits:CreateGroup(scopeKey)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil end
    -- An unreadable scope key stays as it is. Inserting first would leave
    -- "New Group" in the empty stand-in after the save refuses to overwrite it.
    if self.store.ScopeStorage(key) == "unreadable" then return leave(), nil end
    local id = self.store.MintId(doc)
    self.store.InsertEntry(doc, self.store.NewGroupEntry(id, "New Group", true, {}))
    self:_save(key, doc)
    return leave(), id
end

---@param entry Watchdog.Entry|nil
---@param key string
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
---@return boolean
function ScopeEdits:_closing(entry, key, open)
    if entry == nil or open == nil or open.alertId == nil or open.scopeKey ~= key then
        return false
    end
    return subtreeContains(entry, open.alertId)
end

-- The Editor's unsaved graph has to land on the Entry before that Entry is
-- deleted or moved. main closes the Editor afterwards and must not navBack here.
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
function ScopeEdits:_flushOpen(open)
    if open == nil or open.graph == nil or open.alertId == nil or open.scopeKey == nil then return end
    self:Autosave(open.scopeKey, open.alertId, open.graph, open.layout)
end

---@param scopeKey string
---@param ids integer[]
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
---@return Watchdog.EditorResult
function ScopeEdits:BulkDelete(scopeKey, ids, open)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil or ids == nil then return leave() end
    if self.store.ScopeStorage(key) == "unreadable" then return leave() end
    local closing = false
    local removed = {}
    for _, id in ipairs(ids) do
        local entry = self.store.FindById(doc, id)
        if entry ~= nil then
            local alertIds = {}
            collectAlertIds(entry, alertIds)
            if self:_closing(entry, key, open) then
                if not closing then self:_flushOpen(open) end
                closing = true
            end
            self.store.DeleteById(doc, id)
            for _, alertId in ipairs(alertIds) do
                removed[#removed + 1] = alertId
                self.runtime:ReleaseAlertVisuals(alertId, key)
                self.runtime:RemoveAlert(alertId, key)
            end
            if list ~= nil then purgeAlertList(list, alertIds) end
        end
    end
    local saved, reason = self.store.RemoveAlerts(key, doc, removed)
    if not saved then self:_report(reason) end
    if closing then return { kind = "close" } end
    return leave()
end

---@param scopeKey string
---@param ids integer[]
---@return Watchdog.EditorResult
---@return integer|nil id
function ScopeEdits:BulkNewGroup(scopeKey, ids)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil or ids == nil or #ids == 0 then return leave(), nil end
    local newId = self.store.GroupSelected(doc, ids, "New Group")
    if newId == nil then return leave(), nil end
    self:_save(key, doc)
    return leave(), newId
end

---@param scopeKey string
---@param destScopeKey string
---@param ids integer[]
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
---@return Watchdog.EditorResult
function ScopeEdits:BulkMove(scopeKey, destScopeKey, ids, open)
    local srcDoc, srcKey, srcList = self:_bucket(scopeKey)
    local destDoc, destKey, destList = self:_bucket(destScopeKey)
    if srcDoc == nil or destDoc == nil or srcKey == nil or destKey == nil or ids == nil then
        return leave()
    end
    if self.store.ScopeStorage(srcKey) == "unreadable" or self.store.ScopeStorage(destKey) == "unreadable" then
        return leave()
    end
    local closing = false
    local movedAny = false
    local sourceIds = {}
    local destEntries = {}
    for _, id in ipairs(ids) do
        local before = self.store.FindById(srcDoc, id)
        if before ~= nil then
            local alertIds = {}
            collectAlertIds(before, alertIds)
            local snapshots = {}
            if srcList ~= nil then
                for _, alertId in ipairs(alertIds) do
                    for _, alert in ipairs(srcList) do
                        if alert.id == alertId then
                            snapshots[#snapshots + 1] = alert
                            break
                        end
                    end
                end
            end
            if self:_closing(before, srcKey, open) then
                if not closing then self:_flushOpen(open) end
                closing = true
            end
            local moved = self.store.MoveEntryToBucket(srcDoc, destDoc, id)
            if moved ~= nil then
                movedAny = true
                for _, alertId in ipairs(alertIds) do
                    sourceIds[#sourceIds + 1] = alertId
                end
                if srcList ~= nil then purgeAlertList(srcList, alertIds) end
                local leaves = {}
                local function collectLeaves(entry)
                    if entry.kind == "alert" then
                        leaves[#leaves + 1] = entry
                    else
                        for _, child in ipairs(entry.children or {}) do collectLeaves(child) end
                    end
                end
                collectLeaves(moved)
                for _, leaf in ipairs(leaves) do
                    destEntries[#destEntries + 1] = leaf
                end
                for i, leaf in ipairs(leaves) do
                    local snap = snapshots[i]
                    if snap ~= nil then
                        self.runtime:RemoveAlert(snap.id, srcKey)
                        if destList ~= nil then
                            destList[#destList + 1] = {
                                id = leaf.id,
                                name = snap.name,
                                graph = snap.graph,
                                layout = snap.layout,
                                enabled = snap.enabled,
                            }
                        end
                        self.runtime:AddAlert(leaf.id, snap.name, snap.graph, snap.enabled ~= false, destKey, leaf)
                    end
                end
            end
        end
    end
    -- Destination keys, then the tree that names them, then the source tree,
    -- then the source keys. A failed write does not delete a graph the source
    -- tree still names.
    if movedAny then
        local saved, reason = self.store.TransferAlerts(
            srcKey, srcDoc, destKey, destDoc, destEntries, sourceIds)
        if not saved then self:_report(reason) end
    end
    if closing then return { kind = "close" } end
    return leave()
end

---@param scopeKey string
---@param ids integer[]|nil
---@return Watchdog.EditorResult
---@return boolean ok
---@return string jsonOrErr
---@return integer|nil entryCount  # present when encode succeeded; the paste dialog records it
function ScopeEdits:ExportEntries(scopeKey, ids)
    local doc = self:_bucket(scopeKey)
    if doc == nil then return leave(), false, "no active scope" end
    local entries = {}
    if ids == nil then
        for _, entry in ipairs(doc.entries or {}) do
            entries[#entries + 1] = cloneEntry(entry)
        end
    else
        for _, id in ipairs(ids) do
            local entry = self.store.FindById(doc, id)
            if entry ~= nil then entries[#entries + 1] = cloneEntry(entry) end
        end
    end
    local ok, result = Export.Encode(entries)
    return leave(), ok, result, ok and #entries or nil
end

---@param scopeKey string
---@param text string
---@return Watchdog.EditorResult
---@return boolean ok
---@return Watchdog.ImportReport|string
function ScopeEdits:ImportJson(scopeKey, text)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), false, "no active scope" end
    local before = {}
    for _, leaf in ipairs(self.store.Leaves(doc)) do
        before[leaf.id] = true
    end
    if self.store.ScopeStorage(key) == "unreadable" then
        return leave(), false, "Could not save the import."
    end
    local ok, report = Export.Import(doc, text, { registry = self.registry })
    if not ok then
        return leave(), false, report
    end
    local newLeaves = {}
    for _, leaf in ipairs(self.store.Leaves(doc)) do
        if not before[leaf.id] then
            newLeaves[#newLeaves + 1] = leaf
        end
    end
    local saved = self:_saveCreated(key, doc, newLeaves)
    if #newLeaves > 0 then
        local temp = self.store.Empty()
        temp.entries = newLeaves
        local restored = self.store.RestoreAll(temp, self.registry)
        for _, alert in ipairs(restored) do
            if list ~= nil then
                list[#list + 1] = alert
            end
            self.runtime:AddAlert(alert.id, alert.name, alert.graph, alert.enabled ~= false, key, self.store.FindById(doc, alert.id))
        end
    end
    if not saved then
        return leave(), false, "Could not save the import."
    end
    return leave(), true, report
end

-- Saves and arms the Alert the instantiate call inserted. A failed copy or a
-- failed bake returns the error and leaves the Bucket as that call left it.
---@param doc Watchdog.Bucket
---@param key string
---@param list Watchdog.RestoredAlert[]|nil
---@param entry Watchdog.Entry|nil
---@param graph LibNodeGraph.Graph|nil
---@param layout Watchdog.Layout|nil
---@param err string|nil
---@return Watchdog.EditorResult
---@return integer|nil id
---@return string|nil err
function ScopeEdits:_finishCreate(doc, key, list, entry, graph, layout, err)
    if entry == nil or graph == nil or layout == nil then
        return leave(), nil, err
    end
    if self.store.ScopeStorage(key) == "unreadable" then
        return leave(), nil, "This scope could not be read."
    end
    self:_saveCreated(key, doc, { entry })
    rememberAlert(list, entry.id, entry.name, graph, layout)
    self.runtime:AddAlert(entry.id, entry.name, graph, true, key, entry)
    return leave(), entry.id, nil
end

---@param scopeKey string
---@param presetId integer
---@param answers any[]|nil
---@return Watchdog.EditorResult
---@return integer|nil id
---@return string|nil err
function ScopeEdits:CreateFromPreset(scopeKey, presetId, answers)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil, "No scope to create the alert in." end
    if self.store.ScopeStorage(key) == "unreadable" then
        return leave(), nil, "This scope could not be read."
    end
    return self:_finishCreate(doc, key, list, PresetCopy.Instantiate(doc, presetId, self.registry, answers))
end

-- Same save and arm as a library Preset. The registry does not save the Bucket,
-- and the copy does not keep the author id.
---@param scopeKey string
---@param snapshot Watchdog.PackAlertPreset
---@param answers any[]|nil
---@return Watchdog.EditorResult
---@return integer|nil id
---@return string|nil err
function ScopeEdits:CreateFromAlertPreset(scopeKey, snapshot, answers)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil, "No scope to create the alert in." end
    if self.store.ScopeStorage(key) == "unreadable" then
        return leave(), nil, "This scope could not be read."
    end
    return self:_finishCreate(doc, key, list, PresetCopy.InstantiateSnapshot(doc, snapshot, self.registry, answers))
end

return ScopeEdits
