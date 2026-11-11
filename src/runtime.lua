-- runtime.lua - trigger Event Subscribe/Unsubscribe dispatcher (BindTrigger, injectable sources).
-- Live alerts: Entry `id` is persistence identity (unique within a Bucket); `name` is free-text
-- and not unique. Name-targeted SetEnabled/Toggle act on every match; persistence writes by `id`.
-- Bucket keys: `global` (always armed) and `player_<tracking id>` (arm/disarm with login).

local Util = require("src/util")

---A live alert. `id` is Entry identity persistence keys on; `name` is not unique; `bucketKey` owns it.
---@class Watchdog.RuntimeAlert
---@field id integer|nil
---@field name string|nil
---@field graph LibNodeGraph.Graph|nil
---@field enabled boolean
---@field bucketKey string

---@class Watchdog.NodeHandle
---@field id integer
---@field typeKey string
---@field mode string|nil
---@field GetControl fun(pinName: string): any

---@class Watchdog.TriggerBinding
---@field event string
---@field kind "event"|"poll"|nil                          # default "event"
---@field transform (fun(raw: any): any)|nil               # identity if omitted
---@field filter (fun(payload: any, node: Watchdog.NodeHandle, graph: LibNodeGraph.Graph): boolean|table)|nil  # true fires the shared event; a table fires that table; false or nil skips
---@field seedKey (fun(node: Watchdog.NodeHandle): any)|nil  # poll: changing key reseeds edge state (no Enter/Leave)

---@class Watchdog.IdentitySource
---@field Resolve fun(self: Watchdog.IdentitySource): string|nil       # Tracking ID; nil when logged out or empty
---@field DisplayName fun(self: Watchdog.IdentitySource): string|nil  # tab label; never a bucket key

---Persistence hook for Alert Toggle, keyed by Bucket and Entry id.
---@class Watchdog.RuntimePersistence
---@field SaveEnabled (fun(bucketKey: string, id: integer, enabled: boolean): boolean)|nil
---@field SetEnabled (fun(id: integer, enabled: boolean))|nil

---@class Watchdog.Runtime
---@field alerts Watchdog.RuntimeAlert[]
---@field effects any|nil                                  # EffectRegistry (effects.lua)
---@field infobox any|nil                                  # InfoBox Area (ui/infobox.lua)
---@field screenMarkerCapture any|nil                      # ui/screen_marker_capture.lua
---@field objectMarkerCapture any|nil                      # ui/object_marker_capture.lua
---@field toast any|nil                                    # ToastStack, wired by main.lua
---@field keyboardActivityTick integer
---@field mouseActivityTick integer
---@field _cursorMoves { typeKey: string, filter: fun(payload: any, node: Watchdog.NodeHandle): boolean }[]
---@field new fun(eventSource: any|nil, mouseSource: any|nil, identitySource: Watchdog.IdentitySource|nil): Watchdog.Runtime
---@field SetBucketLoader fun(self: Watchdog.Runtime, loader: fun(trackingId: string): Watchdog.RestoredAlert[])
---@field GetActiveCharacter fun(self: Watchdog.Runtime): string|nil, string|nil
---@field Update fun(self: Watchdog.Runtime)
---@field GetMousePos fun(self: Watchdog.Runtime): number|nil, number|nil
---@field AddAlert fun(self: Watchdog.Runtime, id: integer|nil, name: string|nil, graph: LibNodeGraph.Graph|nil, enabled: boolean|nil, bucketKey: string|nil, entry: Watchdog.RuntimeAlert|nil): Watchdog.RuntimeAlert
---@field RemoveAlert fun(self: Watchdog.Runtime, id: integer, bucketKey: string|nil): boolean
---@field SetAlertEnabled fun(self: Watchdog.Runtime, id: integer, enabled: boolean, bucketKey: string|nil): boolean
---@field ReleaseAlertVisuals fun(self: Watchdog.Runtime, id: integer, bucketKey: string|nil): boolean
---@field ReleaseNodeVisuals fun(self: Watchdog.Runtime, graph: LibNodeGraph.Graph|nil, nodeId: integer|nil)
---@field RenameAlert fun(self: Watchdog.Runtime, id: integer, name: string): boolean
---@field SetRegistry fun(self: Watchdog.Runtime, registry: LibNodeGraph.Registry)
---@field PreloadGraph fun(self: Watchdog.Runtime, graph: LibNodeGraph.Graph|nil)
---@field PreloadNode fun(self: Watchdog.Runtime, graph: LibNodeGraph.Graph, nodeId: integer)
---@field SetGraph fun(self: Watchdog.Runtime, graph: LibNodeGraph.Graph|nil)
---@field SetPersistence fun(self: Watchdog.Runtime, persistence: Watchdog.RuntimePersistence)
---@field SetEnabledResolver fun(self: Watchdog.Runtime, resolver: fun(id: integer, bucketKey: string|nil): boolean)
---@field SetEnabled fun(self: Watchdog.Runtime, name: string, enabled: boolean): boolean
---@field Toggle fun(self: Watchdog.Runtime, name: string): integer|nil
---@field BindTrigger fun(self: Watchdog.Runtime, typeKey: string, entries: Watchdog.TriggerBinding[])
---@field BindCursorMove fun(self: Watchdog.Runtime, typeKey: string, filter: fun(payload: any, node: Watchdog.NodeHandle): boolean)
---@field Stop fun(self: Watchdog.Runtime)
local Runtime = {}
Runtime.__index = Runtime

-- `GameState.GAME` (docs: 30). Fallback literal for the headless harness.
local GAME_STATE = (GameState ~= nil and GameState.GAME) or 30

-- Always-armed Bucket key. Character buckets: `player_<tracking id>`, character for character.
local GLOBAL_BUCKET = "global"

local function callOrLog(context, fn, ...)
    return Util.CallOrLog("runtime", context, fn, ...)
end

local function makeNodeHandle(graph, node)
    return {
        id = node.id,
        typeKey = node.typeKey,
        -- GetNodes() is an id/typeKey projection; mode lives on the live node (ADR-0011).
        mode = graph:GetMode(node.id),
        GetControl = function(pinName) return graph:GetControl(node.id, pinName) end,
    }
end

-- Same division as IfaceScale.ToInterface. Runtime does not require src/ui.
---@param mx number
---@param my number
---@return number, number
local function toInterface(mx, my)
    local factor = 1
    local ok, setting = pcall(function()
        return game.options.InterfaceScale.setting
    end)
    if ok and type(setting) == "number" and setting > 0 then
        factor = setting / 100
    end
    return mx / factor, my / factor
end

---@param eventSource any|nil
---@param mouseSource any|nil
---@param identitySource Watchdog.IdentitySource|nil
---@return Watchdog.Runtime
function Runtime.new(eventSource, mouseSource, identitySource)
    local self = setmetatable({
        eventSource = eventSource or Event,
        mouseSource = mouseSource or Mouse,
        identitySource = identitySource,
        -- Names aren't unique: `_alertsByName[name]` is a list; SetEnabled/Toggle act on all matches.
        alerts = {},
        _alertsByName = {},
        _persistence = nil,
        -- Bucket key -> { key, armed, resident, displayName }. `global` is always armed.
        -- Fire gates on `alert.enabled AND buckets[alert.bucketKey].armed`. Character buckets
        -- disarm (stay resident) on leave-GAME; discard+reload only when the Tracking ID changes.
        buckets = { [GLOBAL_BUCKET] = { key = GLOBAL_BUCKET, armed = true, resident = true } },
        _characterBucketKey = nil,
        -- GAME, a mid-session reload that can already read the id, or a trackingAccess
        -- grant sets this. Update drains it. The id may not be readable on the same tick.
        _pendingResolve = false,
        _bucketLoader = nil,
        channels = {},
        -- Player Input mouse-move bindings. Fired from the cursor poll, not an event channel.
        _cursorMoves = {},
        -- Poll Enter/Leave edge state, keyed by graph then nodeId (ids unique only within a graph).
        -- Weak keys; missing ⇒ false (already-true-at-load fires Enter); never serialized.
        pollEdgeState = setmetatable({}, { __mode = "k" }),
        -- Parallel to pollEdgeState: last seedKey per graph/node. Weak-keyed so a dropped Graph
        -- does not keep the keys alive.
        pollSeedKey = setmetatable({}, { __mode = "k" }),
        keyboardActivityTick = 0,
        mouseActivityTick = 0,
        _lastMousePos = nil,
    }, Runtime)
    self:_bindActivityTracking()
    self:_bindLifecycle()
    self:_bindPermission()
    -- Reload mid-session gets no GameStateChanged: if a Tracking ID is already readable, drain on first Update.
    if self.identitySource ~= nil and self.identitySource:Resolve() ~= nil then
        self._pendingResolve = true
    end
    return self
end

function Runtime:_bindActivityTracking()
    local source = self.eventSource.KeyDown
    if source == nil or source.Subscribe == nil then
        return
    end
    local runtime = self
    source.Subscribe("watchdog_runtime_activity_key", function()
        runtime.keyboardActivityTick = runtime.keyboardActivityTick + 1
    end)
    self._activitySource = source
end

--- Player scoping -------------------------------------------------------------------------

function Runtime:_bindLifecycle()
    local source = self.eventSource.GameStateChanged
    if source == nil or source.Subscribe == nil then
        return
    end
    local runtime = self
    source.Subscribe("watchdog_runtime_gamestate", function(payload)
        runtime:_onGameStateChanged(payload)
    end)
    self._lifecycleSource = source
end

-- Already in GAME: no GameStateChanged, and the constructor's Resolve saw no id.
function Runtime:_bindPermission()
    if self.identitySource == nil then
        return
    end
    local source = self.eventSource.OptionalPermissionChanged
    if source == nil or source.Subscribe == nil then
        return
    end
    local runtime = self
    source.Subscribe("watchdog_runtime_permission", function(payload)
        runtime:_onOptionalPermissionChanged(payload)
    end)
    self._permissionSource = source
end

function Runtime:_onOptionalPermissionChanged(payload)
    local kind = type(payload)
    if kind ~= "table" and kind ~= "userdata" then return end
    if payload.permissionName ~= "trackingAccess" then return end
    if payload.enabled == true then
        self._pendingResolve = true
        if log ~= nil then
            log("Watchdog: tracking access granted")
        end
        return
    end
    self._pendingResolve = false
    if self._characterBucketKey ~= nil then
        self:_discardBucket(self._characterBucketKey)
    end
end

-- GAME: defer identity to Update. Else: disarm resident character Bucket (`global` never disarms).
function Runtime:_onGameStateChanged(payload)
    local newState = payload ~= nil and payload.newState or nil
    if newState == GAME_STATE then
        self._pendingResolve = true
    else
        self._pendingResolve = false
        if self._characterBucketKey ~= nil then
            local bucket = self.buckets[self._characterBucketKey]
            if bucket ~= nil then bucket.armed = false end
        end
    end
end

-- Same Tracking ID → re-arm in place (preserve pollEdgeState). Different id → discard + load.
function Runtime:_drainPendingResolve()
    if not self._pendingResolve then
        return
    end
    local trackingId = self.identitySource:Resolve()
    if trackingId == nil then
        return -- not readable yet, logged out, or empty id; keep the flag and retry next tick
    end
    self._pendingResolve = false
    local key = "player_" .. trackingId
    local displayName = self.identitySource:DisplayName()
    if key == self._characterBucketKey then
        local bucket = self.buckets[key]
        if bucket ~= nil then
            bucket.armed = true
            if displayName ~= nil then bucket.displayName = displayName end
        end
        return
    end
    if self._characterBucketKey ~= nil then
        self:_discardBucket(self._characterBucketKey)
    end
    self:_loadCharacterBucket(key, trackingId, displayName)
end

function Runtime:_loadCharacterBucket(key, trackingId, displayName)
    self.buckets[key] = { key = key, armed = true, resident = true, displayName = displayName }
    self._characterBucketKey = key
    if self._bucketLoader == nil then
        return
    end
    local ok, restored = callOrLog("bucket loader for '" .. tostring(trackingId) .. "'",
        self._bucketLoader, trackingId)
    if ok and type(restored) == "table" then
        for _, alert in ipairs(restored) do
            self:AddAlert(alert.id, alert.name, alert.graph, alert.enabled, key, alert.entry or alert)
        end
    end
end

-- Tracking ID change: drop alerts + pollEdgeState. A rename is not a switch. No disk adoption.
function Runtime:_discardBucket(key)
    local kept = {}
    for _, alert in ipairs(self.alerts) do
        if alert.bucketKey == key then
            self.pollEdgeState[alert.graph] = nil
            self.pollSeedKey[alert.graph] = nil
        else
            kept[#kept + 1] = alert
        end
    end
    self.alerts = kept
    self:_rebuildNameIndex()
    self.buckets[key] = nil
    if self._characterBucketKey == key then
        self._characterBucketKey = nil
    end
end

-- Anonymous (name nil) is untargetable.
function Runtime:_indexAlert(alert)
    if alert.name == nil then return end
    local matches = self._alertsByName[alert.name]
    if matches == nil then
        matches = {}
        self._alertsByName[alert.name] = matches
    end
    matches[#matches + 1] = alert
end

function Runtime:_rebuildNameIndex()
    self._alertsByName = {}
    for _, alert in ipairs(self.alerts) do
        self:_indexAlert(alert)
    end
end

---@param bucketKey string|nil
---@return boolean
function Runtime:_bucketArmed(bucketKey)
    local bucket = self.buckets[bucketKey or GLOBAL_BUCKET]
    return bucket ~= nil and bucket.armed == true
end

---@param loader fun(trackingId: string): Watchdog.RestoredAlert[]
function Runtime:SetBucketLoader(loader)
    self._bucketLoader = loader
end

-- Resident character (stays loaded while logged out, though disarmed).
-- The label is the live display name while one is readable, else the name stored at last resolve.
---@return string|nil displayName
---@return string|nil bucketKey
function Runtime:GetActiveCharacter()
    local key = self._characterBucketKey
    if key == nil then return nil, nil end
    local bucket = self.buckets[key]
    if bucket == nil then return nil, nil end
    local live = self.identitySource:DisplayName()
    if live ~= nil then
        bucket.displayName = live
        return live, key
    end
    return bucket.displayName, key
end

function Runtime:Update()
    self:_drainPendingResolve()
    self:_pollMouseActivity()
end

-- Interface units - use this, not raw Mouse.GetPosition (ui/iface_scale.lua).
---@return number|nil x
---@return number|nil y
function Runtime:GetMousePos()
    local pos = self._lastMousePos
    if pos == nil then return nil, nil end
    return pos.x, pos.y
end

function Runtime:_pollMouseActivity()
    local mouse = self.mouseSource
    if mouse == nil or not mouse.IsAvailable() then
        return
    end
    local ok, pos = pcall(mouse.GetPosition)
    if not ok or pos == nil then
        return
    end
    local ix, iy = toInterface(pos.x, pos.y)
    local last = self._lastMousePos
    -- The first poll only establishes a baseline - there's nothing to compare yet, so it
    -- must not itself count as "activity" (a plugin load/reload isn't a mouse movement).
    if last ~= nil and (ix ~= last.x or iy ~= last.y) then
        self.mouseActivityTick = self.mouseActivityTick + 1
        self:_fireCursorMoves()
    end
    self._lastMousePos = { x = ix, y = iy }
end

local ALERT_ENTRY_FIELDS = { id = true, name = true, enabled = true }

-- id, name, and enabled live on the Scope Entry. The live graph stays on the
-- runtime record so saving the Entry does not replace its serialized graph.
local alertMeta = {
    __index = function(alert, key)
        if ALERT_ENTRY_FIELDS[key] then
            return rawget(alert, "entry")[key]
        end
    end,
    __newindex = function(alert, key, value)
        if ALERT_ENTRY_FIELDS[key] then
            rawget(alert, "entry")[key] = value
            return
        end
        rawset(alert, key, value)
    end,
}

---@param id integer|nil
---@param name string|nil
---@param graph LibNodeGraph.Graph|nil
---@param enabled boolean|nil
---@param bucketKey string|nil  # owning Bucket; defaults to `global`
---@param entry Watchdog.RuntimeAlert|nil  # the Scope's Alert; when omitted, one is created
---@return Watchdog.RuntimeAlert
function Runtime:AddAlert(id, name, graph, enabled, bucketKey, entry)
    if entry == nil then
        entry = { id = id, name = name, enabled = enabled ~= false }
    end
    local alert = setmetatable({
        graph = graph,
        bucketKey = bucketKey or GLOBAL_BUCKET,
        entry = entry,
    }, alertMeta)
    self.alerts[#self.alerts + 1] = alert
    self:_indexAlert(alert)
    self:PreloadGraph(graph)
    return alert
end

-- Memory-only; caller persists.
---@param id integer
---@return boolean
function Runtime:RemoveAlert(id, bucketKey)
    local kept, removed = {}, false
    for _, alert in ipairs(self.alerts) do
        if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
            self.pollEdgeState[alert.graph] = nil
            self.pollSeedKey[alert.graph] = nil
            removed = true
        else
            kept[#kept + 1] = alert
        end
    end
    if not removed then return false end
    self.alerts = kept
    self:_rebuildNameIndex()
    return true
end

-- Drop overlay visuals keyed by these node state tables: infobox tiles, toasts,
-- per-node effect handles (screen marker, object marker, screen flash), and popups stamped
-- with `handle.source == state`. States not in the set are left alone.
---@param states table<any, boolean>
function Runtime:_releaseStateSet(states)
    for state in pairs(states) do
        if self.infobox ~= nil then
            self.infobox:Remove(state)
        end
        if self.toast ~= nil then
            self.toast:Dismiss(state)
        end
        if state.handle ~= nil and self.effects ~= nil then
            self.effects:Dismiss(state.handle)
            state.handle = nil
        end
    end
    if self.effects ~= nil then
        self.effects:DismissIf(function(handle)
            return handle.source ~= nil and states[handle.source] == true
        end)
    end
end

-- Every node on the graph. Used when the whole alert goes quiet.
---@param graph LibNodeGraph.Graph|nil
function Runtime:_releaseGraphVisuals(graph)
    if graph == nil then return end
    local states = {}
    for _, node in ipairs(graph:GetNodes()) do
        local state = graph:GetState(node.id)
        if state ~= nil then
            states[state] = true
        end
    end
    self:_releaseStateSet(states)
end

-- One node, while it still exists. GetState is nil after RemoveNode, and the
-- InfoBox strip keys its tile by that state table.
---@param graph LibNodeGraph.Graph|nil
---@param nodeId integer|nil
function Runtime:ReleaseNodeVisuals(graph, nodeId)
    if graph == nil or nodeId == nil then return end
    local state = graph:GetState(nodeId)
    if state == nil then return end
    self:_releaseStateSet({ [state] = true })
end

-- Public seam for delete and group-disable. Does not change `enabled` or remove the alert.
---@param id integer
---@return boolean
function Runtime:ReleaseAlertVisuals(id, bucketKey)
    for _, alert in ipairs(self.alerts) do
        if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
            self:_releaseGraphVisuals(alert.graph)
            return true
        end
    end
    return false
end

-- Memory-only; does not re-enter the persistence hook. Groups are not live alerts.
-- Turning an alert off drops the visuals it already spawned. Turning it on does not restore them.
---@param id integer
---@param enabled boolean
---@return boolean
function Runtime:SetAlertEnabled(id, enabled, bucketKey)
    for _, alert in ipairs(self.alerts) do
        if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
            alert.enabled = enabled and true or false
            if not alert.enabled then
                self:_releaseGraphVisuals(alert.graph)
            end
            return true
        end
    end
    return false
end

---@param id integer
---@param name string
---@param bucketKey string|nil
---@return boolean
function Runtime:RenameAlert(id, name, bucketKey)
    for _, alert in ipairs(self.alerts) do
        if alert.id == id and (bucketKey == nil or alert.bucketKey == bucketKey) then
            alert.name = name
            self:_rebuildNameIndex()
            return true
        end
    end
    return false
end

---@param registry LibNodeGraph.Registry
function Runtime:SetRegistry(registry)
    self._registry = registry
end

function Runtime:_preloadNode(graph, node)
    local nodeType = self._registry:GetNodeType(node.typeKey)
    if nodeType == nil or nodeType.preload == nil then
        return
    end
    callOrLog("preload error on '" .. tostring(node.typeKey) .. "'",
        nodeType.preload, makeNodeHandle(graph, node))
end

---@param graph LibNodeGraph.Graph|nil
function Runtime:PreloadGraph(graph)
    if graph == nil or self._registry == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        self:_preloadNode(graph, node)
    end
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
function Runtime:PreloadNode(graph, nodeId)
    if graph == nil or self._registry == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        if node.id == nodeId then
            self:_preloadNode(graph, node)
            return
        end
    end
end

---@param graph LibNodeGraph.Graph|nil
function Runtime:SetGraph(graph)
    self.alerts = {}
    self._alertsByName = {}
    if graph ~= nil then
        self:AddAlert(nil, nil, graph, true)
    end
end

---@param persistence Watchdog.RuntimePersistence
function Runtime:SetPersistence(persistence)
    self._persistence = persistence
end

-- Ancestor-group half of the enabled-chain (own flag is `alert.enabled`). Unset ⇒ all ancestors enabled.
---@param resolver fun(id: integer, bucketKey: string|nil): boolean
function Runtime:SetEnabledResolver(resolver)
    self._enabledResolver = resolver
end

-- Fail-open: no resolver, nil id, or a raising resolver leaves the alert firing.
---@param id integer|nil
---@param bucketKey string|nil
---@return boolean
function Runtime:_ancestorsEnabled(id, bucketKey)
    if self._enabledResolver == nil or id == nil then return true end
    local ok, result = callOrLog("enabled resolver for id '" .. tostring(id) .. "'",
        self._enabledResolver, id, bucketKey)
    if not ok then return true end
    return result ~= false
end

-- Persist by Entry id inside the Alert's own Bucket. Ids are unique per Bucket, not across them.
---@param alert { id: integer|nil, bucketKey: string }
---@param enabled boolean
function Runtime:_persistEnabled(alert, enabled)
    if alert.id == nil or self._persistence == nil then return end
    local key = alert.bucketKey or GLOBAL_BUCKET
    if self._persistence.SaveEnabled ~= nil then
        callOrLog("persistence SaveEnabled for id '" .. tostring(alert.id) .. "'",
            self._persistence.SaveEnabled, key, alert.id, enabled)
        return
    end
    if key ~= GLOBAL_BUCKET or self._persistence.SetEnabled == nil then return end
    callOrLog("persistence SetEnabled for id '" .. tostring(alert.id) .. "'",
        self._persistence.SetEnabled, alert.id, enabled)
end

-- Name-targeted; names aren't unique so every match is set. No match → no persist write.
---@param name string
---@param enabled boolean
---@return boolean  # true if at least one live alert of that name existed
function Runtime:SetEnabled(name, enabled)
    enabled = enabled and true or false
    local matches = self._alertsByName[name]
    if matches == nil or #matches == 0 then
        return false
    end
    for _, alert in ipairs(matches) do
        alert.enabled = enabled
        self:_persistEnabled(alert, enabled)
        if not alert.enabled then
            self:_releaseGraphVisuals(alert.graph)
        end
    end
    return true
end

-- Flip each match independently (no shared per-name state).
---@param name string
---@return integer|nil  # count of alerts flipped, or nil if none matched
function Runtime:Toggle(name)
    local matches = self._alertsByName[name]
    if matches == nil or #matches == 0 then
        return nil
    end
    for _, alert in ipairs(matches) do
        alert.enabled = not alert.enabled
        self:_persistEnabled(alert, alert.enabled)
        if not alert.enabled then
            self:_releaseGraphVisuals(alert.graph)
        end
    end
    return #matches
end

-- Mouse move uses the cursor poll, which is not an event channel. The first
-- successful poll only stores a position; a later change fires these bindings.
---@param typeKey string
---@param filter fun(payload: any, node: Watchdog.NodeHandle): boolean
function Runtime:BindCursorMove(typeKey, filter)
    assert(type(typeKey) == "string" and typeKey ~= "", "BindCursorMove requires a typeKey")
    self._cursorMoves[#self._cursorMoves + 1] = { typeKey = typeKey, filter = filter }
end

function Runtime:_fireCursorMoves()
    for _, binding in ipairs(self._cursorMoves) do
        self:_fireBinding(binding, nil)
    end
end

-- Subscribe each `event` once. Poll: nil transform sample freezes edge state for that tick.
-- Optional `seedKey`: first sample / changed key writes edge state with no Enter/Leave.
---@param typeKey string
---@param entries Watchdog.TriggerBinding[]
function Runtime:BindTrigger(typeKey, entries)
    assert(type(typeKey) == "string" and typeKey ~= "", "BindTrigger requires a typeKey")
    assert(type(entries) == "table" and #entries > 0, "BindTrigger requires at least one binding entry")
    for _, entry in ipairs(entries) do
        assert(type(entry.event) == "string" and entry.event ~= "",
            "binding entry for '" .. typeKey .. "' requires an event name")
        local channel = self.channels[entry.event]
        if channel == nil then
            channel = { bindings = {}, subscribed = false }
            self.channels[entry.event] = channel
        end
        channel.bindings[#channel.bindings + 1] = {
            typeKey = typeKey,
            kind = entry.kind or "event",
            transform = entry.transform,
            filter = entry.filter,
            seedKey = entry.seedKey,
        }
        self:_ensureSubscribed(entry.event, channel)
    end
end

function Runtime:_ensureSubscribed(eventName, channel)
    if channel.subscribed then
        return
    end
    local source = self.eventSource[eventName]
    assert(source ~= nil and source.Subscribe ~= nil, "runtime: unknown event channel '" .. eventName .. "'")

    local subscribeName = "watchdog_runtime_" .. eventName
    local runtime = self
    source.Subscribe(subscribeName, function(raw)
        runtime:_dispatch(eventName, raw)
    end)

    channel.subscribed = true
    channel.subscribeName = subscribeName
    channel.source = source
end

function Runtime:_dispatch(eventName, raw)
    local channel = self.channels[eventName]
    if channel == nil then
        return
    end
    for _, binding in ipairs(channel.bindings) do
        local payload = raw
        local transformOk = true
        if binding.transform ~= nil then
            local ok, result = callOrLog(
                "transform error on '" .. eventName .. "' for '" .. binding.typeKey .. "'",
                binding.transform, raw)
            transformOk = ok
            if ok then
                payload = result
            end
        end
        if transformOk then
            if binding.kind == "poll" then
                -- Nil sample (unreadable source): freeze edge state - no spurious Leave/relog-Enter.
                if payload ~= nil then
                    self:_firePollBinding(binding, payload)
                end
            else
                self:_fireBinding(binding, payload)
            end
        end
    end
end

function Runtime:_fireBinding(binding, payload)
    for _, alert in ipairs(self.alerts) do
        if alert.enabled and self:_ancestorsEnabled(alert.id, alert.bucketKey) and self:_bucketArmed(alert.bucketKey) then
            self:_fireBindingInGraph(binding, payload, alert.graph)
        end
    end
end

function Runtime:_fireBindingInGraph(binding, payload, graph)
    if graph == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        if node.typeKey == binding.typeKey then
            local nodeId = node.id
            local firePayload = payload
            local passes = true
            if binding.filter ~= nil then
                local nodeHandle = makeNodeHandle(graph, node)
                -- Graph is the sample key. A table replaces the shared event. false and nil skip.
                local ok, result = callOrLog(
                    "filter error on '" .. binding.typeKey .. "'",
                    binding.filter, payload, nodeHandle, graph)
                if not ok or not result then
                    passes = false
                elseif type(result) == "table" then
                    firePayload = result
                end
            end
            if passes then
                pcall(function() graph:Fire(nodeId, firePayload) end)
            end
        end
    end
end

-- Same fire predicate; skipped alerts freeze poll edge state (world-hop re-arm must not replay Enter).
function Runtime:_firePollBinding(binding, payload)
    for _, alert in ipairs(self.alerts) do
        if alert.enabled and self:_ancestorsEnabled(alert.id, alert.bucketKey) and self:_bucketArmed(alert.bucketKey) then
            self:_firePollBindingInGraph(binding, payload, alert.graph)
        end
    end
end

function Runtime:_pollEdgeStateFor(graph)
    local states = self.pollEdgeState[graph]
    if states == nil then
        states = {}
        self.pollEdgeState[graph] = states
    end
    return states
end

function Runtime:_pollSeedKeyFor(graph)
    local keys = self.pollSeedKey[graph]
    if keys == nil then
        keys = {}
        self.pollSeedKey[graph] = keys
    end
    return keys
end

---@class Watchdog.PollFirePayload
---@field edge "Enter"|"Leave"  # the transition the edge gate detected this tick
---@field sample any            # the value transform() sampled this tick (shared world state)

-- Enter/Leave on predicate transition. Missing edge state ⇒ false. Filter error freezes that node.
-- `seedKey`: first sample, or a changed key (e.g. Location target), writes state with no edge.
function Runtime:_firePollBindingInGraph(binding, payload, graph)
    if graph == nil then
        return
    end
    local edgeStates = self:_pollEdgeStateFor(graph)
    local seedKeys = nil
    if binding.seedKey ~= nil then
        seedKeys = self:_pollSeedKeyFor(graph)
    end
    for _, node in ipairs(graph:GetNodes()) do
        if node.typeKey == binding.typeKey then
            local nodeId = node.id
            local nodeHandle = nil
            if binding.filter ~= nil or seedKeys ~= nil then
                nodeHandle = makeNodeHandle(graph, node)
            end
            -- nil = freeze (filter errored); true/false = predicate.
            local current = true
            if binding.filter ~= nil then
                local ok, result = callOrLog(
                    "poll filter error on '" .. binding.typeKey .. "'",
                    binding.filter, payload, nodeHandle)
                if ok then
                    current = result and true or false
                else
                    current = nil
                end
            end
            local reseed = false
            if current ~= nil and seedKeys ~= nil then
                local ok, key = callOrLog(
                    "poll seedKey error on '" .. binding.typeKey .. "'",
                    binding.seedKey, nodeHandle)
                if not ok then
                    current = nil
                elseif seedKeys[nodeId] ~= key then
                    seedKeys[nodeId] = key
                    reseed = true
                end
            end
            if current ~= nil then
                if not reseed then
                    local prev = edgeStates[nodeId] == true -- lazy: missing ⇒ false
                    if current and not prev then
                        pcall(function() graph:Fire(nodeId, { edge = "Enter", sample = payload }) end)
                    elseif prev and not current then
                        pcall(function() graph:Fire(nodeId, { edge = "Leave", sample = payload }) end)
                    end
                end
                edgeStates[nodeId] = current
            end
        end
    end
end

function Runtime:Stop()
    for _, channel in pairs(self.channels) do
        if channel.subscribed then
            local source, name = channel.source, channel.subscribeName
            pcall(function() source.Unsubscribe(name) end)
            channel.subscribed = false
        end
    end
    if self._activitySource ~= nil then
        pcall(function() self._activitySource.Unsubscribe("watchdog_runtime_activity_key") end)
        self._activitySource = nil
    end
    if self._lifecycleSource ~= nil then
        pcall(function() self._lifecycleSource.Unsubscribe("watchdog_runtime_gamestate") end)
        self._lifecycleSource = nil
    end
    if self._permissionSource ~= nil then
        pcall(function() self._permissionSource.Unsubscribe("watchdog_runtime_permission") end)
        self._permissionSource = nil
    end
end

return Runtime
