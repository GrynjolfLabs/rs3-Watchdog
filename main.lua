local Editor              = require("src/ui/graph")
local Manager             = require("src/ui/manager")
local Shell               = require("src/ui/shell")
local Store               = require("src/store")
local ScopeEdits          = require("src/scope_edits")
local Presets             = require("src/presets")
local Packs               = require("src/packs")
---@type Watchdog.Runtime
local Runtime             = require("src/runtime")
local Effects             = require("src/effects")
local InfoBoxArea         = require("src/ui/infobox")
local ScreenMarkerCapture = require("src/ui/screen_marker_capture")
local ObjectMarkerCapture = require("src/ui/object_marker_capture")
local ToastStack          = require("src/toast")
local Theme               = require("src/ui/theme")
local Dialog              = require("src/ui/dialog")
local Notices             = require("src/notices")
local NoticeDialog        = require("src/ui/notice_dialog")
local PresetDialogs       = require("src/ui/preset_dialogs")
local HubLayers           = require("src/ui/hub_layers")
local Text                = require("src/text")

local Events              = {
    Logic = "logic",
    Draw = "draw",
    KeyDown = "key",
}

if Plugin.HasPermission(PluginPermissions.trackingAccess) then
    log("Watchdog: plugin has tracking access")
else
    log("Watchdog: plugin does NOT have tracking access")
end

if Plugin.HasPermission(PluginPermissions.chatAccess) then
    log("Watchdog: plugin has chat access")
else
    log("Watchdog: plugin does NOT have chat access")
end

local playerIdentity = {
    Resolve = function()
        if Player == nil or not Player.IsAvailable() then return nil end
        -- Not in the stubs yet.
        ---@diagnostic disable-next-line: undefined-field
        local ok, id = pcall(function() return Player.GetTrackingID() end)
        if not ok or type(id) ~= "number" then return nil end
        return id
    end,
    DisplayName = function()
        if Player == nil or not Player.IsAvailable() then return nil end
        local ok, entity = pcall(function() return Player.GetEntity() end)
        if not ok or entity == nil or not entity.isValid then return nil end
        local name = entity.displayName
        if type(name) ~= "string" or name == "" then return nil end
        return name
    end,
}

local effects = Effects.new()
local infobox = InfoBoxArea.new()
local screenMarkerCapture = ScreenMarkerCapture.new()
local objectMarkerCapture = ObjectMarkerCapture.new()

local TOAST_ANCHOR_KEY = "watchdog_toast_anchor"
local toast = ToastStack.new(effects, {
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
            -- False, nil, and a throw leave the previous bytes. No dialog: this is not a scope save.
            local setOk, stored = pcall(function()
                return PersistentDB:SetString(TOAST_ANCHOR_KEY, text)
            end)
            if (not setOk or stored ~= true) and log ~= nil then
                log("Watchdog: toast anchor could not be saved - " .. tostring(stored))
            end
        end
    end,
})

local runtime = Runtime.new(nil, nil, playerIdentity)
runtime.effects = effects
runtime.infobox = infobox
runtime.screenMarkerCapture = screenMarkerCapture
runtime.objectMarkerCapture = objectMarkerCapture
runtime.toast = toast

local registry = LibNodeGraph.NewRegistry()
LibNodeGraphStd.Register(registry)
require("src/nodes/triggers/game_message").Register(registry, runtime)
require("src/nodes/triggers/player_chat").Register(registry, runtime)
require("src/nodes/triggers/logic").Register(registry, runtime)
require("src/nodes/triggers/player_input").Register(registry, runtime)
require("src/nodes/triggers/location").Register(registry, runtime)
require("src/nodes/triggers/skill").Register(registry, runtime)
require("src/nodes/triggers/resource").Register(registry, runtime)
require("src/nodes/triggers/entity_spawn").Register(registry, runtime)
require("src/nodes/triggers/inventory").Register(registry, runtime)
require("src/nodes/actions/log").Register(registry)
require("src/nodes/actions/sound").Register(registry)
require("src/nodes/actions/custom_sound").Register(registry)
require("src/nodes/actions/screen_flash").Register(registry, runtime)
require("src/nodes/actions/popup").Register(registry, runtime)
require("src/nodes/actions/infobox").Register(registry, runtime)
require("src/nodes/actions/screen_marker").Register(registry, runtime)
require("src/nodes/actions/object_marker").Register(registry, runtime)
require("src/nodes/actions/toast").Register(registry, runtime)
require("src/nodes/actions/alert_toggle").Register(registry, runtime)
require("src/nodes/actions/game_message").Register(registry)
-- require("src/nodes/actions/shortest_path").Register(registry)

runtime:SetRegistry(registry)

---@type { key: string, displayName: string, doc: Watchdog.Bucket, alerts: Watchdog.RestoredAlert[] }|nil
local charScope = nil

-- Declared up here so the bucket loader and the shell share one variable.
-- The loader runs before the shell exists, and again after login.
---@type Watchdog.Shell|nil
local mux
local loadNotices = {}

---@param unread string[]|nil
---@param problem "unreadable"|nil
local function queueLoadNotice(unread, problem)
    if problem == "unreadable" then
        loadNotices[#loadNotices + 1] = { kind = "scope" }
    elseif type(unread) == "table" and #unread > 0 then
        loadNotices[#loadNotices + 1] = { kind = "alerts", names = unread }
    end
end

-- One dialog per bad scope, and one dialog naming every alert that did not load.
-- Shown when the shell exists. A load that happens first is queued until then.
local function presentLoadNotices()
    if mux == nil or #loadNotices == 0 then return end
    local parent = mux:Overlay()
    if parent == nil then return end
    local pending = loadNotices
    loadNotices = {}
    for _, item in ipairs(pending) do
        if item.kind == "scope" then
            Dialog.scopeUnreadable(parent)
        elseif item.kind == "save" then
            if item.reason == "size" then
                Dialog.tooBig(parent, item.name)
            else
                Dialog.failedSave(parent)
            end
        elseif item.kind == "presets" then
            Dialog.presetsUnreadable(parent)
        else
            Dialog.unreadAlerts(parent, item.names)
        end
    end
end

---@param fail { reason: "size"|"failed"|nil, name: string|nil }|nil
local function queueSaveFailure(fail)
    if fail == nil then return end
    loadNotices[#loadNotices + 1] = { kind = "save", reason = fail.reason, name = fail.name }
end

runtime:SetBucketLoader(function(trackingId)
    local key = Store.PlayerKey(trackingId)
    -- Disk migration finishes before this scope is armed. A character the
    -- startup list did not see (the list failed, or they were not on disk
    -- yet) moves here. A failure uses the old document and tells the player.
    queueSaveFailure(Store.MigrateScope(key))
    local playerDoc, unread, problem = Store.LoadScope(key)
    queueLoadNotice(unread, problem)
    presentLoadNotices()
    local restoredChar = {}
    local ok, r = pcall(function() return Store.RestoreAll(playerDoc, registry) end)
    if ok and r ~= nil then restoredChar = r end
    for _, alert in ipairs(restoredChar) do
        alert.entry = Store.FindById(playerDoc, alert.id)
    end
    charScope = { key = key, displayName = playerIdentity:DisplayName(), doc = playerDoc, alerts = restoredChar }
    return restoredChar
end)

-- List keys, then move global and every numeric character scope. A character
-- that does not fit is only logged here. The dialog waits until that scope is armed.
local migrationFailures = Store.MigrateListed()
for _, fail in ipairs(migrationFailures) do
    if fail.identity == "global" then
        queueSaveFailure(fail)
    end
end
-- The library does not need the key list. An index that does not fit is
-- queued here and shown when the shell opens. The legacy value is not written.
queueSaveFailure(Presets.Migrate())

local document, globalUnread, globalProblem = Store.LoadScope("global")
queueLoadNotice(globalUnread, globalProblem)

local restored = {}
do
    local ok, all = pcall(function() return Store.RestoreAll(document, registry) end)
    if ok and all ~= nil then
        restored = all
    elseif log ~= nil then
        log("Watchdog: RestoreAll failed - " .. tostring(all))
    end
end

for _, alert in ipairs(restored) do
    local entry = Store.FindById(document, alert.id)
    runtime:AddAlert(alert.id, alert.name, alert.graph, alert.enabled, "global", entry)
end

local editor = Editor.new(registry, runtime)

local reportFailedSave
runtime:SetPersistence({
    SaveEnabled = function(key, id, enabled)
        local doc
        if key == "global" then
            doc = document
        elseif charScope ~= nil and charScope.key == key then
            doc = charScope.doc
        end
        if doc == nil or not Store.SetEnabled(doc, id, enabled) then
            return false
        end
        local ok, reason = Store.PersistScope(key, doc)
        if ok ~= true and reason == "size" and reportFailedSave ~= nil then
            reportFailedSave(reason)
        end
        return ok == true
    end,
})

runtime:SetEnabledResolver(function(id, bucketKey)
    local doc
    if bucketKey == "global" then
        doc = document
    elseif charScope ~= nil and charScope.key == bucketKey then
        doc = charScope.doc
    end
    if doc ~= nil then return Store.AncestorsEnabled(doc, id) end
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
        local ok, reason = Store.PersistScope("global", document)
        if ok ~= true and reportFailedSave ~= nil then
            reportFailedSave(reason)
        end
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
local persistNow -- assigned below
local edits ---@type Watchdog.ScopeEdits

local managerSurface ---@type Watchdog.MuxSurface
local editorSurface ---@type Watchdog.MuxSurface
local manager

local notices = Notices.shared

-- Any dialog already on the shell overlay blocks another until the next trigger.
local function overlayHasDialog()
    if mux == nil then return true end
    local parent = mux:Overlay()
    if parent == nil then return true end
    return Dialog.depth(parent) > 0
end

---@param offer Watchdog.NoticeOffer|nil
local function presentNotice(offer)
    if offer == nil or mux == nil then return end
    local parent = mux:Overlay()
    if parent == nil or Dialog.depth(parent) > 0 then return end
    local function onSeen()
        notices:MarkSeen(offer.ids)
    end
    if offer.kind == "whats-new" then
        NoticeDialog.mountWhatsNew(parent, offer.entries, onSeen)
    elseif offer.kind == "getting-started" then
        NoticeDialog.mountGettingStarted(parent, onSeen)
    end
end

local function onShellShow()
    if mux == nil then return end
    presentLoadNotices()
    presentNotice(notices:OnWindowOpen({
        editorTop = mux:IsTop("editor"),
        dialogOpen = overlayHasDialog(),
    }))
end

---@param scopeKey string
---@param entryId integer
local function navOpenAlert(scopeKey, entryId)
    local a = resolveAlert(scopeKey, entryId)
    if a == nil then return end
    local entry = Store.FindById(a.doc, entryId)
    -- A missing or unreadable alert key is not in the restored list, so this
    -- does not open. A row with no graph must not replace the stored bytes.
    if entry == nil or type(entry.graph) ~= "table" then return end
    editor:BindEntry(entryId, a.graph, a.layout, entry and entry.name)
    boundScope = { doc = a.doc, key = a.key }
    edits:NoteSaved(a.key)
    if mux ~= nil and editorSurface ~= nil then
        -- Hidden: SetVisible is the window open. Already visible: the push is the editor entry.
        local shellWasVisible = mux:IsVisible()
        mux:Push(editorSurface)
        mux:SetVisible(true)
        presentNotice(notices:OnOpenAlert(shellWasVisible, {
            dialogOpen = overlayHasDialog(),
        }))
    end
end

local function navBack()
    if persistNow ~= nil then pcall(persistNow) end -- flush before unbinding
    editor:Unbind()
    boundScope = nil
    if mux ~= nil then mux:Pop() end
    notices:OnNavBack()
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

reportFailedSave = function(reason)
    if mux == nil then return end
    local parent = mux:Overlay()
    if parent == nil then return end
    if reason == "size" then
        Dialog.tooBig(parent)
    else
        Dialog.failedSave(parent)
    end
end
Presets.SetSaveFailed(reportFailedSave)
Presets.SetLoadFailed(function()
    loadNotices[#loadNotices + 1] = { kind = "presets" }
    presentLoadNotices()
end)

edits = ScopeEdits.new({
    store = Store,
    runtime = runtime,
    registry = registry,
    bucket = function(scopeKey)
        return scopeBucket(scopeKey)
    end,
    onSaveFailed = reportFailedSave,
})

-- The Scope module returns one result. This applies it. The module does not
-- show, hide, or rename the Editor, and it does not call navBack.
---@return { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
local function openAlert()
    if editor.boundId == nil or boundScope == nil then return nil end
    return {
        alertId = editor.boundId,
        scopeKey = boundScope.key,
        graph = editor.graph,
        layout = editor:GetLayout(),
    }
end

---@param result Watchdog.EditorResult|nil
local function applyEditor(result)
    if result == nil or result.kind == nil or result.kind == "leave" then return end
    if result.kind == "open" then
        navOpenAlert(result.scopeKey, result.alertId)
    elseif result.kind == "close" then
        navBack()
    elseif result.kind == "rename" then
        editor.alertName = result.name
        if editor.onAlertNameChanged ~= nil then editor.onAlertNameChanged(result.name) end
    end
end

editor.onRename = function()
    if boundScope == nil or editor.boundId == nil then return end
    local scopeKey, entryId = boundScope.key, editor.boundId
    local field, feedback
    Dialog.mount(mux:Overlay(), {
        title = "Rename alert",
        width = 380,
        height = 200,
        content = function(win)
            win:AddText("Alert name")
            field = win:AddTextField({ text = editor.alertName, maxLength = 80, height = 30 })
            feedback = win:AddText("")
        end,
        actions = {
            { label = "Cancel" },
            {
                label = "Save",
                variant = "positive",
                onClick = function()
                    local name = Text.StripTags(field:GetText() or ""):match("^%s*(.-)%s*$")
                    if name == "" then
                        feedback.content = "Enter an alert name."; return false
                    end
                    local result, ok = edits:Rename(scopeKey, entryId, name, openAlert())
                    if not ok then
                        feedback.content = "Could not save the name. Try again."
                        return false
                    end
                    applyEditor(result)
                    return true
                end
            },
        },
    })
end
editor.onRenameNode = function(nodeId)
    local draft = editor:nodeRenameDraft(nodeId)
    if draft == nil then return end
    local field
    local renameAction = {
        label = "Rename",
        variant = "positive",
        disabled = editor:nodeRenameBlank(draft.fieldText),
        onClick = function()
            local text = field:GetText()
            if editor:nodeRenameBlank(text) then return false end
            if not editor:commitNodeRename(nodeId, text) then return false end
            return true
        end,
    }
    Dialog.mount(mux:Overlay(), {
        title = "Rename node",
        width = 380,
        height = 200,
        content = function(win)
            win:AddText(draft.typeLabel)
            field = win:AddTextField({
                text = draft.fieldText,
                maxLength = 80,
                height = 30,
                onChange = function(tf, _, content)
                    local text = content
                    if type(text) ~= "string" and tf ~= nil and tf.GetText ~= nil then
                        text = tf:GetText()
                    end
                    Dialog.setActionDisabled(renameAction, editor:nodeRenameBlank(text))
                end,
            })
        end,
        actions = {
            { label = "Cancel" },
            renameAction,
        },
    })
end

editor.onSavePreset = function()
    if boundScope == nil or editor.boundId == nil or editor.graph == nil then return end
    if mux == nil or mux:Overlay() == nil then return end
    -- Snapshot only. The open Alert is not renamed and gains no Variable marks.
    PresetDialogs.mountSave(mux:Overlay(), {
        graph = editor.graph,
        initialName = editor.alertName or "",
        onSave = function(name, marks)
            if marks == nil or #marks == 0 then
                return Presets.Add(name, editor.graph, editor:GetLayout())
            end
            return Presets.Add(name, editor.graph, editor:GetLayout(), marks)
        end,
    })
end

-- Shell, effects, infobox, and toasts share this parent. Saved anchors are
-- plain offsets, so a different origin moves existing positions.
local function getRootParent()
    local candidates = { "TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP" }
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
    onToggleEnabled = function(scopeKey, id)
        applyEditor(edits:ToggleEnabled(scopeKey, id))
    end,
    onRename = function(scopeKey, id, name)
        local result, ok = edits:Rename(scopeKey, id, name, openAlert())
        applyEditor(result)
        return ok
    end,
    onDelete = function(scopeKey, id)
        applyEditor(edits:Delete(scopeKey, id, openAlert()))
    end,
    onReorderSibling = function(scopeKey, id, delta)
        applyEditor(edits:ReorderSibling(scopeKey, id, delta))
    end,
    onLift = function(scopeKey, id)
        applyEditor(edits:Lift(scopeKey, id))
    end,
    onCreateAlert = function(scopeKey)
        PresetDialogs.mountNewAlert(mux ~= nil and mux.rootLayer or nil, {
            registry = registry,
            onFromScratch = function()
                return edits:CreateFromScratch(scopeKey)
            end,
            onFromPreset = function(presetId, answers)
                return edits:CreateFromPreset(scopeKey, presetId, answers)
            end,
            onFromAlertPreset = function(snapshot, answers)
                return edits:CreateFromAlertPreset(scopeKey, snapshot, answers)
            end,
            onCreated = applyEditor,
        })
        return nil
    end,
    onCreateGroup = function(scopeKey)
        local result, id = edits:CreateGroup(scopeKey)
        applyEditor(result)
        return id
    end,
    onBulkDelete = function(scopeKey, ids)
        applyEditor(edits:BulkDelete(scopeKey, ids, openAlert()))
    end,
    onBulkNewGroup = function(scopeKey, ids)
        local result, id = edits:BulkNewGroup(scopeKey, ids)
        applyEditor(result)
        return id
    end,
    onBulkMove = function(scopeKey, destScopeKey, ids)
        applyEditor(edits:BulkMove(scopeKey, destScopeKey, ids, openAlert()))
    end,
    onExportEntries = function(scopeKey, ids)
        local result, ok, payload, count = edits:ExportEntries(scopeKey, ids)
        applyEditor(result)
        return ok, payload, count
    end,
    onImportJson = function(scopeKey, text)
        local result, ok, report = edits:ImportJson(scopeKey, text)
        applyEditor(result)
        return ok, report
    end,
    -- Parent dialogs to the shell so reload destroys them too.
    windowParent = function()
        return mux ~= nil and mux.rootLayer or nil
    end,
})

mux = Shell.new({
    x = -math.floor(Theme.WINDOW_W / 2),
    y = -math.floor(Theme.WINDOW_H / 2),
    xAnchor = 0.5,
    yAnchor = 0.5,
    width = Theme.WINDOW_W,
    height = Theme.WINDOW_H,
    minWidth = 720,
    minHeight = 320,
    scrollable = false,
    onShow = function()
        onShellShow()
        HubLayers.SetShellOpen(true)
    end,
    onHide = function()
        pcall(function() manager:DismissDialogs() end)
        -- Capture hides the window and restores it. Leave the button pressed.
        if mux ~= nil and mux:IsHiddenForCapture() then return end
        HubLayers.SetShellOpen(false)
    end,
})
presentLoadNotices()
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
    -- Dismiss gestures without resetting pan and zoom on the shell key.
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
    edits:Autosave(boundScope.key, editor.boundId, editor.graph, editor:GetLayout())
end

local function onLogic()
    pcall(function() runtime:Update() end)
    -- A tracking revoke discards the character bucket. Leave the editor if it was bound there.
    if boundScope ~= nil and boundScope.key ~= "global" then
        local _, key = runtime:GetActiveCharacter()
        if key ~= boundScope.key then
            pcall(navBack)
        end
    end
    pcall(function() runtime.toast:Update() end)

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
end

local function onDraw(drawEvent)
    pcall(function() runtime.effects:Update(drawEvent.timeDeltaSecs) end)
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

-- One in-memory Pack registry for this load. It is not written to PersistentDB,
-- and Watchdog does not scan plugins to fill it.
local packs = Packs.new()
Packs.install(packs)

local api = {}

-- Policy lives in the registry. These methods only forward.
---@param name string
---@param contributions table|nil
---@return any token
---@return Watchdog.PackRefusal[] refusals
function api:RegisterDataPack(name, contributions)
    return packs:RegisterDataPack(name, contributions)
end

-- Plugins call this same method. Watchdog's own Pack is registered here, at startup.
require("src/starter_alerts").register(api, registry)

---@param token any
function api:Clear(token)
    return packs:Clear(token)
end

function api.Stop()
    if runtime.objectMarkerCapture ~= nil then
        runtime.objectMarkerCapture.onArmedChange = nil
        -- Unsubscribe MiniMenuReady so reload does not leak the prior instance.
        pcall(function() runtime.objectMarkerCapture:Cancel() end)
    end
    HubLayers.Stop()
    pcall(persistNow)
    pcall(function() Event.Logic.Unsubscribe(Events.Logic) end)
    pcall(function() Event.Draw.Unsubscribe(Events.Draw) end)
    pcall(function() Event.KeyDown.Unsubscribe(Events.KeyDown) end)
    pcall(function() runtime:Stop() end)
    pcall(function() runtime.effects:Clear() end)
    pcall(function() runtime.infobox:Clear() end)
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
end

api.editor = editor
api.manager = manager
api.mux = mux
api.document = document -- the persisted `global` Bucket, exposed for inspection

Event.Logic.Subscribe(Events.Logic, onLogic)
Event.Draw.Subscribe(Events.Draw, onDraw)

Event.KeyDown.Subscribe(Events.KeyDown, function(keyEvent)
    if keyEvent == nil or keyEvent.isRepeat then return end
    if keyEvent.gameKey == GameKey.ESCAPE then
        if runtime.objectMarkerCapture ~= nil and runtime.objectMarkerCapture:IsArmed() then
            runtime.objectMarkerCapture:Cancel()
            return
        end
        -- We can't consume keypresses so these ones make it more confusing
        -- if mux ~= nil and mux:IsVisible() then
        --     if mux:IsTop("manager") and manager ~= nil and manager:IsVisible() then
        --         if manager:HasSelection() then
        --             manager:ClearSelection()
        --             pcall(function() manager:_rebuild() end)
        --         end
        --     elseif mux:IsTop("editor") and editor:IsVisible() then
        --         pcall(function() editor:onEscape() end)
        --     end
        -- end
        return
    end
    local keys = HubLayers.ShellKeys()
    local pressed = keyEvent.gameKey
    local bound = false
    for _, key in ipairs(keys) do
        if key == pressed then
            bound = true
            break
        end
    end
    -- IsDown is false while the settings field is capturing, so choosing a key
    -- does not also toggle. An extra key held with the chord does not match.
    if bound and prettyui ~= nil and prettyui.KeybindField ~= nil
        and prettyui.KeybindField.IsDown(keys) then
        api.Toggle()
    end
end)

-- The shell key and the content-layer Toggle share api.Toggle.
HubLayers.SetResetPositions(function()
    runtime.infobox:ResetAnchor()
    runtime.toast:ResetAnchor()
end)
HubLayers.LoadPrefs()
HubLayers.Bind(function()
    api.Toggle()
end)

Watchdog = api
print("Watchdog editor loaded")

-- ADR-0008: Save here, but let the client destroy the UI tree.
function PluginShutdown()
    pcall(persistNow)
    -- Unsubscribe only. Destroying the settings page here is the shutdown crash.
    HubLayers.Unbind()
end

return Watchdog
