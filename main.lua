local Editor = require("ui/graph")
local Manager = require("ui/manager")
local Multiplexer = require("ui/multiplexer")
local Store  = require("store")
local Export = require("export")
---@type Watchdog.Runtime
local Runtime = require("runtime")
local ToastStack = require("toast")
local Theme = require("ui/theme")
local Dialog = require("ui/dialog")

local Events = {
    Logic = "logic",
    Draw = "draw",
    KeyDown = "key",
}

local TOGGLE_KEY = "F8"

if Plugin.HasPermission(PluginPermissions.httpAccess) then
    log("Watchdog: plugin has HTTP access")
else
    log("Watchdog: plugin does NOT have HTTP access")
end

local playerIdentity = {
    Resolve = function()
        if Player == nil or not Player.IsAvailable() then return nil end
        local ok, entity = pcall(function() return Player.GetEntity() end)
        if not ok or entity == nil or not entity.isValid then return nil end
        return entity.displayName
    end,
}

local runtime = Runtime.new(nil, nil, playerIdentity)

local TOAST_ANCHOR_KEY = "watchdog_toast_anchor"
runtime.toast = ToastStack.new(runtime.effects, {
    Load = function()
        if PersistentDB == nil or LibNodeGraph == nil or LibNodeGraph.Json == nil then return nil end
        local text
        pcall(function() text = PersistentDB:GetString(TOAST_ANCHOR_KEY) end)
        if type(text) ~= "string" or text == "" then return nil end
        local ok, pos = pcall(function() return LibNodeGraph.Json.Default.decode(text) end)
        if ok then return pos end
        return nil
    end,
    Save = function(pos)
        if PersistentDB == nil or LibNodeGraph == nil or LibNodeGraph.Json == nil then return end
        local ok, text = pcall(function() return LibNodeGraph.Json.Default.encode(pos) end)
        if ok and text ~= nil then
            pcall(function() PersistentDB:SetString(TOAST_ANCHOR_KEY, text) end)
        end
    end,
})

local registry = LibNodeGraph.NewRegistry()
LibNodeGraphStd.Register(registry)
require("nodes/triggers/game_message").Register(registry, runtime)
require("nodes/triggers/player_chat").Register(registry, runtime)
require("nodes/triggers/logic").Register(registry, runtime)
require("nodes/triggers/location").Register(registry, runtime)
require("nodes/triggers/skill").Register(registry, runtime)
require("nodes/triggers/entity_spawn").Register(registry, runtime)
require("nodes/triggers/inventory").Register(registry, runtime)
require("nodes/actions/log").Register(registry)
require("nodes/actions/sound").Register(registry)
require("nodes/actions/custom_sound").Register(registry)
require("nodes/actions/screen_flash").Register(registry, runtime)
require("nodes/actions/popup").Register(registry, runtime)
require("nodes/actions/infobox").Register(registry, runtime)
require("nodes/actions/screen_marker").Register(registry, runtime)
require("nodes/actions/object_marker").Register(registry, runtime)
require("nodes/actions/toast").Register(registry, runtime)
require("nodes/actions/alert_toggle").Register(registry, runtime)
if shortestpath ~= nil then
    require("nodes/actions/shortest_path").Register(registry, runtime)
end

local function RegisterToPluginMenu()
    LibPluginMenu.Unregister("watchdog")
    LibPluginMenu.Register({
        id = "watchdog",
        name = "Watchdog",
        icon = "W",
        onClick = function()
            pcall(function() Watchdog.Toggle() end)
        end
    })
end
Event.OptionalDependencyChanged.Subscribe('opdepchanged', function(dep)
    if dep.pluginIdentifier == "LibPluginMenu" and LibPluginMenu ~= nil then
        if dep.enabled then
            RegisterToPluginMenu()
        end
    elseif dep.pluginIdentifier == "shortestpath" and shortestpath ~= nil then
        if dep.enabled then
            print("shortestpath is now available, reloading")
            ExecuteConsoleCommand("prl Watchdog")
        end
    end
end)

if LibPluginMenu ~= nil then
    RegisterToPluginMenu()
end

runtime:SetRegistry(registry)

---@type { key: string, displayName: string, doc: Watchdog.Bucket, alerts: Watchdog.RestoredAlert[] }|nil
local charScope = nil

runtime:SetBucketLoader(function(normalized)
    local key = Store.PlayerKey(normalized)
    local playerDoc = Store.LoadKey(key)
    local restoredChar = {}
    local ok, r = pcall(function() return Store.RestoreAll(playerDoc, registry) end)
    if ok and r ~= nil then restoredChar = r end
    charScope = { key = key, displayName = normalized, doc = playerDoc, alerts = restoredChar }
    return restoredChar
end)

local function seedDemo()
    local graph = LibNodeGraph.NewGraph(registry)

    local chatNode = graph:AddNode("trigger.game_message",
        { contains = { needle = "Hello", mode = "substring" } })
    local logNode  = graph:AddNode("action.log")
    local addNode  = graph:AddNode("std.add", { a = 2, b = 3 })
    local mulNode  = graph:AddNode("std.multiply", { a = 4, b = 5 })

    local function tryConnect(fromN, fromP, toN, toP)
        local id, reason = graph:Connect(fromN, fromP, toN, toP)
        if id == nil and log ~= nil then
            log("Watchdog: demo connect failed - " .. tostring(reason))
        end
    end

    tryConnect(chatNode, "out", logNode, "in")
    tryConnect(chatNode, "message", logNode, "message")
    tryConnect(addNode, "result", mulNode, "a")

    local layout = {
        [chatNode] = { x = 80,  y = 90 },
        [logNode]  = { x = 460, y = 110 },
        [addNode]  = { x = 80,  y = 360 },
        [mulNode]  = { x = 460, y = 380 },
    }

    return graph, layout
end

local document = Store.Load()

local restored = {}
do
    local ok, all = pcall(function() return Store.RestoreAll(document, registry) end)
    if ok and all ~= nil then
        restored = all
    elseif log ~= nil then
        log("Watchdog: RestoreAll failed, seeding demo - " .. tostring(all))
    end
    if #restored == 0 then
        local graph, layout = seedDemo()
        local id = Store.MintId(document)
        Store.InsertEntry(document, Store.NewAlertEntry(id, "default", graph, layout, true))
        Store.Save(document)
        restored = { { id = id, name = "default", graph = graph, layout = layout, enabled = true } }
    end
end

for _, alert in ipairs(restored) do
    runtime:AddAlert(alert.id, alert.name, alert.graph, alert.enabled)
end

local editor = Editor.new(registry, runtime)

runtime:SetPersistence({
    SetEnabled = function(id, enabled)
        Store.SetEnabled(document, id, enabled)
        Store.Save(document)
    end,
})

runtime:SetEnabledResolver(function(id)
    for _, alert in ipairs(runtime.alerts) do
        if alert.id == id then
            local doc
            if alert.bucketKey == "global" then
                doc = document
            elseif charScope ~= nil and charScope.key == alert.bucketKey then
                doc = charScope.doc
            end
            if doc ~= nil then return Store.AncestorsEnabled(doc, id) end
            return true
        end
    end
    return true
end)

do
    local ax, ay = Store.GetInfoBoxAnchor(document)
    if ax ~= nil and ay ~= nil then
        runtime.infobox:SetAnchor(ax, ay)
    end
end
runtime.infobox:SetPersistence({
    SaveAnchor = function(x, y)
        Store.SetInfoBoxAnchor(document, x, y)
        Store.Save(document)
    end,
})

---@param scopeKey string
---@param id integer
---@return { graph: LibNodeGraph.Graph, layout: Watchdog.Layout, doc: Watchdog.Bucket, key: string }|nil
local function resolveAlert(scopeKey, id)
    local list, doc
    if scopeKey == "global" then
        list, doc = restored, document
    elseif charScope ~= nil and charScope.key == scopeKey then
        list, doc = charScope.alerts, charScope.doc
    else
        return nil
    end
    for _, alert in ipairs(list) do
        if alert.id == id then
            return { graph = alert.graph, layout = alert.layout, doc = doc, key = scopeKey }
        end
    end
    return nil
end

---@return Watchdog.ManagerScope[]
local function getScopes()
    local scopes = { { key = "global", label = "All characters", doc = document } }
    local name, key = runtime:GetActiveCharacter()
    if key ~= nil and charScope ~= nil and charScope.key == key then
        scopes[#scopes + 1] = { key = key, label = name or charScope.displayName, doc = charScope.doc }
    end
    return scopes
end

---@type { doc: Watchdog.Bucket, key: string }|nil
local boundScope = nil
local boundLastEncoded = nil
local persistNow -- assigned below

local mux ---@type Watchdog.Multiplexer
local managerSurface ---@type Watchdog.MuxSurface
local editorSurface ---@type Watchdog.MuxSurface
local manager

---@param scopeKey string
---@param entryId integer
local function navOpenAlert(scopeKey, entryId)
    local a = resolveAlert(scopeKey, entryId)
    if a == nil then return end
    local entry = Store.FindById(a.doc, entryId)
    editor:BindEntry(entryId, a.graph, a.layout, entry and entry.name)
    boundScope = { doc = a.doc, key = a.key }
    boundLastEncoded = Store.Encode(a.doc)
    if mux ~= nil and editorSurface ~= nil then
        mux:Push(editorSurface)
        mux:SetVisible(true)
    end
end

local function navBack()
    if persistNow ~= nil then pcall(persistNow) end -- flush before unbinding
    editor:Unbind()
    boundScope = nil
    boundLastEncoded = nil
    if mux ~= nil then mux:Pop() end
end

editor.onBack = navBack

---@param scopeKey string
---@return Watchdog.Bucket|nil doc
---@return string|nil key
---@return Watchdog.RestoredAlert[]|nil list
local function scopeBucket(scopeKey)
    if scopeKey == "global" then
        return document, "global", restored
    elseif charScope ~= nil and charScope.key == scopeKey then
        return charScope.doc, charScope.key, charScope.alerts
    end
    return nil
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

---@param list Watchdog.RestoredAlert[]
---@param ids integer[]
local function purgeAlertList(list, ids)
    local drop = {}
    for _, id in ipairs(ids) do drop[id] = true end
    for i = #list, 1, -1 do
        if drop[list[i].id] then table.remove(list, i) end
    end
end

---@param scopeKey string
---@param id integer
local function onToggleEnabled(scopeKey, id)
    local doc, key = scopeBucket(scopeKey)
    if doc == nil then return end
    local entry = Store.FindById(doc, id)
    if entry == nil then return end
    local nextEnabled = not (entry.enabled ~= false)
    Store.SetEnabled(doc, id, nextEnabled)
    Store.SaveTo(key, doc)
    if entry.kind == "alert" then
        runtime:SetAlertEnabled(id, nextEnabled)
        local _, _, list = scopeBucket(scopeKey)
        if list ~= nil then
            for _, a in ipairs(list) do
                if a.id == id then a.enabled = nextEnabled end
            end
        end
    end
end

---@param scopeKey string
---@param id integer
---@param name string
local function onRename(scopeKey, id, name)
    local doc, key, list = scopeBucket(scopeKey)
    if doc == nil then return end
    local entryBefore = Store.FindById(doc, id)
    local oldName = entryBefore and entryBefore.name
    if not Store.SetName(doc, id, name) then return false end
    if not Store.SaveTo(key, doc) then
        Store.SetName(doc, id, oldName)
        return false
    end
    local entry = Store.FindById(doc, id)
    if entry ~= nil and entry.kind == "alert" then
        runtime:RenameAlert(id, name, key)
        if list ~= nil then
            for _, a in ipairs(list) do
                if a.id == id then a.name = name end
            end
        end
    end
    if editor.boundId == id and boundScope ~= nil and boundScope.key == key then
        editor.alertName = name
        if editor.onAlertNameChanged ~= nil then editor.onAlertNameChanged(name) end
    end
    return true
end
editor.onRename = function()
    if boundScope == nil or editor.boundId == nil then return end
    local scopeKey, entryId = boundScope.key, editor.boundId
    local field, feedback
    Dialog.mount(mux:Overlay(), {
        title = "Rename alert", width = 380, height = 200,
        content = function(win)
            win:AddText("Alert name")
            field = win:AddTextField({ text = editor.alertName, maxLength = 80, height = 30 })
            feedback = win:AddText("")
        end,
        actions = {
            { label = "Cancel" },
            { label = "Save", variant = "positive", onClick = function()
                local name = field:GetText():match("^%s*(.-)%s*$")
                if name == "" then feedback.content = "Enter an alert name."; return false end
                if not onRename(scopeKey, entryId, name) then
                    feedback.content = "Could not save the name. Try again."
                    return false
                end
                return true
            end },
        },
    })
end

---@param scopeKey string
---@param id integer
local function onDelete(scopeKey, id)
    local doc, key, list = scopeBucket(scopeKey)
    if doc == nil then return end
    local entry = Store.FindById(doc, id)
    if entry == nil then return end
    local alertIds = {}
    collectAlertIds(entry, alertIds)
    if editor.boundId ~= nil and boundScope ~= nil and boundScope.key == key then
        local function contains(e, target)
            if e.id == target then return true end
            for _, c in ipairs(e.children or {}) do
                if contains(c, target) then return true end
            end
            return false
        end
        if contains(entry, editor.boundId) then
            navBack()
        end
    end
    Store.DeleteById(doc, id)
    Store.SaveTo(key, doc)
    for _, aid in ipairs(alertIds) do
        runtime:RemoveAlert(aid)
    end
    if list ~= nil then purgeAlertList(list, alertIds) end
end

---@param scopeKey string
---@param id integer
---@param delta integer
local function onReorderSibling(scopeKey, id, delta)
    local doc, key = scopeBucket(scopeKey)
    if doc == nil then return end
    if not Store.ReorderSibling(doc, id, delta) then return end
    Store.SaveTo(key, doc)
end

---@param scopeKey string
---@param id integer
local function onLift(scopeKey, id)
    local doc, key = scopeBucket(scopeKey)
    if doc == nil then return end
    if not Store.LiftEntry(doc, id) then return end
    Store.SaveTo(key, doc)
end

---@param scopeKey string
---@return integer|nil
local function onCreateAlert(scopeKey)
    local doc, key, list = scopeBucket(scopeKey)
    if doc == nil then return nil end
    local graph = LibNodeGraph.NewGraph(registry)
    local layout = {}
    local id = Store.MintId(doc)
    local name = "New Alert"
    Store.InsertEntry(doc, Store.NewAlertEntry(id, name, graph, layout, true))
    Store.SaveTo(key, doc)
    if list ~= nil then
        list[#list + 1] = { id = id, name = name, graph = graph, layout = layout, enabled = true }
    end
    runtime:AddAlert(id, name, graph, true, key)
    navOpenAlert(scopeKey, id)
    return id
end

---@param scopeKey string
---@return integer|nil
local function onCreateGroup(scopeKey)
    local doc, key = scopeBucket(scopeKey)
    if doc == nil then return nil end
    local id = Store.MintId(doc)
    Store.InsertEntry(doc, Store.NewGroupEntry(id, "New Group", true, {}))
    Store.SaveTo(key, doc)
    return id
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

---@param scopeKey string
---@param ids integer[]
local function onBulkDelete(scopeKey, ids)
    local doc, key, list = scopeBucket(scopeKey)
    if doc == nil or ids == nil then return end
    for _, id in ipairs(ids) do
        local entry = Store.FindById(doc, id)
        if entry ~= nil then
            local alertIds = {}
            collectAlertIds(entry, alertIds)
            if editor.boundId ~= nil and boundScope ~= nil and boundScope.key == key then
                local function contains(e, target)
                    if e.id == target then return true end
                    for _, c in ipairs(e.children or {}) do
                        if contains(c, target) then return true end
                    end
                    return false
                end
                if contains(entry, editor.boundId) then
                    navBack()
                end
            end
            Store.DeleteById(doc, id)
            for _, aid in ipairs(alertIds) do
                runtime:RemoveAlert(aid)
            end
            if list ~= nil then purgeAlertList(list, alertIds) end
        end
    end
    Store.SaveTo(key, doc)
end

---@param scopeKey string
---@param ids integer[]
---@return integer|nil
local function onBulkNewGroup(scopeKey, ids)
    local doc, key = scopeBucket(scopeKey)
    if doc == nil or ids == nil or #ids == 0 then return nil end
    local newId = Store.GroupSelected(doc, ids, "New Group")
    if newId == nil then return nil end
    Store.SaveTo(key, doc)
    return newId
end

---@param scopeKey string
---@param destScopeKey string
---@param ids integer[]
local function onBulkMove(scopeKey, destScopeKey, ids)
    local srcDoc, srcKey, srcList = scopeBucket(scopeKey)
    local destDoc, destKey, destList = scopeBucket(destScopeKey)
    if srcDoc == nil or destDoc == nil or ids == nil then return end
    for _, id in ipairs(ids) do
        local before = Store.FindById(srcDoc, id)
        if before ~= nil then
            local alertIds = {}
            collectAlertIds(before, alertIds)
            local snapshots = {}
            if srcList ~= nil then
                for _, aid in ipairs(alertIds) do
                    for _, a in ipairs(srcList) do
                        if a.id == aid then
                            snapshots[#snapshots + 1] = a
                            break
                        end
                    end
                end
            end
            if editor.boundId ~= nil and boundScope ~= nil and boundScope.key == srcKey then
                local function contains(e, target)
                    if e.id == target then return true end
                    for _, c in ipairs(e.children or {}) do
                        if contains(c, target) then return true end
                    end
                    return false
                end
                if contains(before, editor.boundId) then
                    navBack()
                end
            end
            local moved = Store.MoveEntryToBucket(srcDoc, destDoc, id)
            if moved ~= nil then
                if srcList ~= nil then purgeAlertList(srcList, alertIds) end
                local leaves = {}
                local function collectLeaves(e)
                    if e.kind == "alert" then
                        leaves[#leaves + 1] = e
                    else
                        for _, c in ipairs(e.children or {}) do collectLeaves(c) end
                    end
                end
                collectLeaves(moved)
                for i, leaf in ipairs(leaves) do
                    local snap = snapshots[i]
                    if snap ~= nil then
                        runtime:RemoveAlert(snap.id)
                        if destList ~= nil then
                            destList[#destList + 1] = {
                                id = leaf.id,
                                name = snap.name,
                                graph = snap.graph,
                                layout = snap.layout,
                                enabled = snap.enabled,
                            }
                        end
                        runtime:AddAlert(leaf.id, snap.name, snap.graph, snap.enabled ~= false, destKey)
                    end
                end
            end
        end
    end
    Store.SaveTo(srcKey, srcDoc)
    Store.SaveTo(destKey, destDoc)
end

---@param kind string
---@param ok boolean
---@param detail string
local function mirrorTransfer(kind, ok, detail)
    pcall(function()
        if PersistentDB == nil then return end
        PersistentDB:SetString("transfer_last", string.format(
            "%s\tok=%s\t%s", kind, tostring(ok), tostring(detail):sub(1, 500)))
    end)
end

---@param scopeKey string
---@param ids integer[]|nil
---@return boolean ok
---@return string jsonOrErr
local function onExportEntries(scopeKey, ids)
    local doc = select(1, scopeBucket(scopeKey))
    if doc == nil then return false, "no active scope" end
    local entries = {}
    if ids == nil then
        for _, entry in ipairs(doc.entries or {}) do
            entries[#entries + 1] = cloneEntry(entry)
        end
    else
        for _, id in ipairs(ids) do
            local entry = Store.FindById(doc, id)
            if entry ~= nil then entries[#entries + 1] = cloneEntry(entry) end
        end
    end
    local ok, result = Export.Encode(entries)
    if ok then
        mirrorTransfer("export", true, string.format("%d bytes / %d entries", #result, #entries))
    else
        mirrorTransfer("export", false, result)
    end
    return ok, result
end

---@param scopeKey string
---@param text string
---@return boolean ok
---@return Watchdog.ImportReport|string
local function onImportJson(scopeKey, text)
    local doc, key, list = scopeBucket(scopeKey)
    if doc == nil then return false, "no active scope" end
    local before = {}
    for _, leaf in ipairs(Store.Leaves(doc)) do
        before[leaf.id] = true
    end
    local ok, report = Export.Import(doc, text, { registry = registry })
    if not ok then
        mirrorTransfer("import", false, tostring(report))
        return false, report
    end
    Store.SaveTo(key, doc)
    local newLeaves = {}
    for _, leaf in ipairs(Store.Leaves(doc)) do
        if not before[leaf.id] then
            newLeaves[#newLeaves + 1] = leaf
        end
    end
    if #newLeaves > 0 then
        local temp = Store.Empty()
        temp.entries = newLeaves
        local restored = Store.RestoreAll(temp, registry)
        for _, a in ipairs(restored) do
            if list ~= nil then
                list[#list + 1] = a
            end
            runtime:AddAlert(a.id, a.name, a.graph, a.enabled ~= false, key)
        end
    end
    local msg = (type(report) == "table" and report.message) or "ok"
    mirrorTransfer("import", true, msg)
    return true, report
end

local function getRootParent()
    local candidates = { "TOPLEVEL_V2__GAME_AREA" }
    for _, key in ipairs(candidates) do
        local componentID = id.Component[key]
        if componentID ~= nil then
            local component = ui.Interfaces:GetComponent(componentID)
            if component ~= nil then
                return component
            end
        end
    end
    return nil
end

manager = Manager.new({
    scopes = getScopes,
    onOpenAlert = navOpenAlert,
    onToggleEnabled = onToggleEnabled,
    onRename = onRename,
    onDelete = onDelete,
    onReorderSibling = onReorderSibling,
    onLift = onLift,
    onCreateAlert = onCreateAlert,
    onCreateGroup = onCreateGroup,
    onBulkDelete = onBulkDelete,
    onBulkNewGroup = onBulkNewGroup,
    onBulkMove = onBulkMove,
    onExportEntries = onExportEntries,
    onImportJson = onImportJson,
    -- Parent dialogs to the shell so reload destroys them too.
    windowParent = function()
        return mux ~= nil and mux.rootLayer or nil
    end,
})

local function syncRibbon()
    if ribbon ~= nil and mux ~= nil then
        pcall(function() ribbon:SetActive(mux:IsVisible()) end)
    end
end

mux = Multiplexer.new({
    x = -math.floor(Theme.WINDOW_W / 2),
    y = -math.floor(Theme.WINDOW_H / 2),
    xAnchor = 0.5,
    yAnchor = 0.5,
    width = Theme.WINDOW_W,
    height = Theme.WINDOW_H,
    minWidth = 720,
    minHeight = 320,
    scrollable = false,
    onHide = function()
        pcall(function() manager:DismissDialogs() end)
        if ribbon ~= nil then
            pcall(function() ribbon:SetActive(false) end)
        end
    end,
})
editor.onAlertNameChanged = function()
    mux:SyncTitle()
end

runtime.objectMarkerCapture.onArmedChange = function(armed)
    if mux == nil then return end
    if armed then
        mux:HideForCapture()
    else
        mux:RestoreFromCapture()
    end
    syncRibbon()
end

managerSurface = {
    id = "manager",
    title = "Watchdog - Alerts",
    SetVisible = function(_, v) manager:SetVisible(v) end,
    OnShellHide = function() manager:OnShellHide() end,
}
editorSurface = {
    id = "editor",
    title = function()
        local name = editor.alertName
        if name == nil or name == "" then return "Watchdog - Editor" end
        return "Watchdog - " .. name
    end,
    SetVisible = function(_, v) editor:SetVisible(v) end,
    -- Dismiss gestures without resetting pan and zoom on F8.
    OnShellHide = function() editor:OnShellHide() end,
    FrontOverlayPopups = function() editor:FrontOverlayPopups() end,
}

local state = {
    muxMounted = false,
    mounted = false,
    managerMounted = false,
    rootPushed = false,
    effectsMounted = false,
    infoboxMounted = false,
    screenMarkerMounted = false,
    infoboxWasDragging = false,
}

local SAVE_INTERVAL_TICKS = 100
local saveState = { tick = 0, wasOpen = false }

persistNow = function()
    if editor.boundId == nil or boundScope == nil then return end
    Store.UpdateAlertGraph(boundScope.doc, editor.boundId, editor.graph, editor:GetLayout())
    local encoded = Store.Encode(boundScope.doc)
    if encoded ~= nil and encoded ~= boundLastEncoded then
        if Store.SaveTo(boundScope.key, boundScope.doc) then
            boundLastEncoded = encoded
        end
    end
end

local LOGIC_TICK_LAST = 0
local LOGIC_TICK_DELTA = 0
---@param logicEvent Logic
local function onLogic(logicEvent)
    LOGIC_TICK_DELTA = logicEvent.logicTick - LOGIC_TICK_LAST
    pcall(function() runtime:Update(LOGIC_TICK_DELTA) end)
    pcall(function() runtime.toast:Update(LOGIC_TICK_DELTA) end)

    if state.infoboxMounted then
        pcall(function() runtime.infobox:Reposition() end)
        local dragging = runtime.infobox:IsDragging()
        if dragging then
            local mx, my = runtime:GetMousePos()
            if mx ~= nil then
                pcall(function() runtime.infobox:Drag(mx, my) end)
            end
        elseif state.infoboxWasDragging then
            pcall(function() mux:RaiseToFront() end)
        end
        state.infoboxWasDragging = dragging
    end

    if state.screenMarkerMounted and runtime.screenMarkerCapture:IsDragging() then
        local mx, my = runtime:GetMousePos()
        if mx ~= nil then
            pcall(function() runtime.screenMarkerCapture:UpdateDrag(mx, my) end)
        end
    end

    if not state.effectsMounted or not state.infoboxMounted or not state.screenMarkerMounted
        or not state.muxMounted or not state.mounted or not state.managerMounted then
        local parent = getRootParent()
        if parent ~= nil then
            if not state.effectsMounted then
                pcall(function() runtime.effects:Mount(parent) end)
                -- Mount catches errors; a successful call does not guarantee a canvas.
                state.effectsMounted = runtime.effects:IsMounted()
                pcall(function() runtime.toast:Mount(parent) end)
            end
            if not state.infoboxMounted then
                pcall(function() runtime.infobox:Mount(parent) end)
                state.infoboxMounted = runtime.infobox:IsMounted()
            end
            if not state.screenMarkerMounted then
                pcall(function() runtime.screenMarkerCapture:Mount(parent) end)
                state.screenMarkerMounted = runtime.screenMarkerCapture:IsMounted()
            end
            if not state.muxMounted then
                local ok, err = pcall(function() mux:Mount(parent) end)
                if ok and mux:Content() ~= nil then
                    state.muxMounted = true
                elseif log ~= nil and not ok then
                    log("Watchdog: mux mount failed - " .. tostring(err))
                end
            end
            if state.muxMounted then
                if not state.managerMounted then
                    pcall(function() manager:Mount(mux:Content(), mux:Window()) end)
                    state.managerMounted = manager:IsMounted()
                end
                if not state.mounted then
                    local ok, err = pcall(function()
                        editor:Mount(mux:Content(), mux:Overlay())
                    end)
                    if ok and editor.canvas ~= nil then
                        state.mounted = true
                    elseif log ~= nil and not ok then
                        log("Watchdog: mount failed - " .. tostring(err))
                    end
                end
                if state.managerMounted and not state.rootPushed then
                    mux:Push(managerSurface)
                    state.rootPushed = true
                end
            end
        end
    end

    if state.managerMounted then
        pcall(function() manager:Update() end)
    end

    if not state.mounted then
        return
    end
    pcall(function() editor:update() end)

    -- Hiding the shell leaves editor.visible set, so check the shell before autosaving.
    local isOpen = mux:IsVisible() and editor:IsVisible() and editor.boundId ~= nil
    if isOpen then
        saveState.tick = saveState.tick + 1
        if saveState.tick >= SAVE_INTERVAL_TICKS then
            saveState.tick = 0
            pcall(persistNow)
        end
    elseif saveState.wasOpen then
        saveState.tick = 0
        pcall(persistNow)
    end
    saveState.wasOpen = isOpen

    LOGIC_TICK_LAST = logicEvent.logicTick
end

local function onDraw()
    if state.mounted then
        pcall(function() editor:draw() end)
    end
    if state.effectsMounted then
        pcall(function() runtime.effects:BeginFrame() end)
        pcall(function() runtime.effects:Draw() end)
        pcall(function() runtime.toast:Draw(runtime.effects:GetCanvas()) end)
        pcall(function()
            local hx, hy = runtime:GetMousePos()
            runtime.infobox:Draw(runtime.effects.canvas, hx, hy)
        end)
        pcall(function() runtime.screenMarkerCapture:Draw(runtime.effects.canvas) end)
        pcall(function() runtime.objectMarkerCapture:Draw(runtime.effects.canvas) end)
    end
    if mux ~= nil then mux:SyncChrome() end
end

local api = {}

function api.Stop()
    if runtime.objectMarkerCapture ~= nil then
        runtime.objectMarkerCapture.onArmedChange = nil
    end
    pcall(persistNow)
    pcall(function() Event.Logic.Unsubscribe(Events.Logic) end)
    pcall(function() Event.Draw.Unsubscribe(Events.Draw) end)
    pcall(function() Event.KeyDown.Unsubscribe(Events.KeyDown) end)
    pcall(function() runtime:Stop() end)
    pcall(function() runtime.effects:Unmount() end)
    pcall(function() runtime.toast:Unmount() end)
    pcall(function() runtime.infobox:Unmount() end)
    pcall(function() runtime.screenMarkerCapture:Unmount() end)
    pcall(function() editor:Unmount() end)
    pcall(function() manager:Unmount() end)
    pcall(function() mux:Destroy() end)
    state.muxMounted = false
    state.mounted = false
    state.managerMounted = false
    state.rootPushed = false
    state.effectsMounted = false
    state.infoboxMounted = false
    state.screenMarkerMounted = false
end

function api.Toggle()
    if mux == nil then return end
    if runtime.objectMarkerCapture ~= nil and runtime.objectMarkerCapture:IsArmed() then
        runtime.objectMarkerCapture:Cancel()
        return
    end
    mux:Toggle()
    syncRibbon()
end

api.editor = editor
api.manager = manager
api.mux = mux
api.document = document  -- the persisted `global` Bucket, exposed for inspection

Event.Logic.Subscribe(Events.Logic, onLogic)
Event.Draw.Subscribe(Events.Draw, onDraw)

Event.KeyDown.Subscribe(Events.KeyDown, function(keyEvent)
    if keyEvent == nil or keyEvent.isRepeat then return end
    if keyEvent.gameKey == GameKey.ESCAPE then
        if runtime.objectMarkerCapture ~= nil and runtime.objectMarkerCapture:IsArmed() then
            runtime.objectMarkerCapture:Cancel()
            return
        end
        if mux ~= nil and mux:IsVisible() then
            if mux:IsTop("manager") and manager ~= nil and manager:IsVisible() then
                if manager:HasSelection() then
                    manager:ClearSelection()
                    pcall(function() manager:_rebuild() end)
                end
            elseif mux:IsTop("editor") and editor:IsVisible() then
                pcall(function() editor:onEscape() end)
            end
        end
        return
    end
    local target = GameKey[TOGGLE_KEY]
    if target ~= nil and keyEvent.gameKey == target then
        api.Toggle()
    end
end)

ribbon = prettyui.RibbonBar.Register({
    id = "watchdog-ribbon",
    icon = id.Sprite.RS3_ICON_CALENDAR_NEW_CONTENT,
    tooltip = "Open Watchdog",
    onClick = function(handle, active)
        if mux ~= nil then mux:SetVisible(active) end
    end,
})

Watchdog = api
print("Watchdog editor loaded")

-- ADR-0008: Save here, but let the client destroy the UI tree.
function PluginShutdown()
    pcall(persistNow)
    ribbon:Destroy()
end

return Watchdog
