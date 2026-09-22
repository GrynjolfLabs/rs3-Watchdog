-- runtime.lua - trigger Event Subscribe/Unsubscribe dispatcher (BindTrigger, injectable sources).
-- Live alerts: Entry `id` is persistence identity (unique within a Bucket); `name` is free-text
-- and not unique. Name-targeted SetEnabled/Toggle act on every match; persistence writes by `id`.
-- Bucket keys: `global` (always armed) and `player_<normalized>` (arm/disarm with login).

local Effects = require("effects")
local InfoBoxArea = require("ui/infobox")
local ScreenMarkerCapture = require("ui/screen_marker_capture")
local ObjectMarkerCapture = require("ui/object_marker_capture")
local IfaceScale = require("ui/iface_scale")
local Util = require("util")

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
---@field filter (fun(payload: any, node: Watchdog.NodeHandle): boolean)|nil  # always-pass if omitted
---@field seedKey (fun(node: Watchdog.NodeHandle): any)|nil  # poll: changing key reseeds edge state (no Enter/Leave)

---@class Watchdog.IdentitySource
---@field Resolve fun(self: Watchdog.IdentitySource): string|nil

---Persistence hook for name-targeted SetEnabled/Toggle (keyed by Entry id).
---@class Watchdog.RuntimePersistence
---@field SetEnabled fun(id: integer, enabled: boolean)

---@class Watchdog.Runtime
---@field alerts Watchdog.RuntimeAlert[]
---@field effects any                                      # EffectRegistry (effects.lua)
---@field infobox any                                      # InfoBox Area (ui/infobox.lua)
---@field screenMarkerCapture any                          # ui/screen_marker_capture.lua
---@field objectMarkerCapture any                          # ui/object_marker_capture.lua
---@field toast any|nil                                    # ToastStack, wired by main.lua
---@field keyboardActivityTick integer
---@field mouseActivityTick integer
---@field new fun(eventSource: any|nil, mouseSource: any|nil, identitySource: Watchdog.IdentitySource|nil): Watchdog.Runtime
---@field SetBucketLoader fun(self: Watchdog.Runtime, loader: fun(normalizedName: string): Watchdog.RestoredAlert[])
---@field GetActiveCharacter fun(self: Watchdog.Runtime): string|nil, string|nil
---@field Update fun(self: Watchdog.Runtime, dt: number)
---@field GetMousePos fun(self: Watchdog.Runtime): number|nil, number|nil
---@field AddAlert fun(self: Watchdog.Runtime, id: integer|nil, name: string|nil, graph: LibNodeGraph.Graph|nil, enabled: boolean|nil, bucketKey: string|nil): Watchdog.RuntimeAlert
---@field RemoveAlert fun(self: Watchdog.Runtime, id: integer): boolean
---@field SetAlertEnabled fun(self: Watchdog.Runtime, id: integer, enabled: boolean): boolean
---@field RenameAlert fun(self: Watchdog.Runtime, id: integer, name: string): boolean
---@field SetRegistry fun(self: Watchdog.Runtime, registry: LibNodeGraph.Registry)
---@field PreloadGraph fun(self: Watchdog.Runtime, graph: LibNodeGraph.Graph|nil)
---@field PreloadNode fun(self: Watchdog.Runtime, graph: LibNodeGraph.Graph, nodeId: integer)
---@field SetGraph fun(self: Watchdog.Runtime, graph: LibNodeGraph.Graph|nil)
---@field SetPersistence fun(self: Watchdog.Runtime, persistence: Watchdog.RuntimePersistence)
---@field SetEnabledResolver fun(self: Watchdog.Runtime, resolver: fun(id: integer): boolean)
---@field SetEnabled fun(self: Watchdog.Runtime, name: string, enabled: boolean): boolean
---@field Toggle fun(self: Watchdog.Runtime, name: string): integer|nil
---@field BindTrigger fun(self: Watchdog.Runtime, typeKey: string, entries: Watchdog.TriggerBinding[])
---@field Stop fun(self: Watchdog.Runtime)
local Runtime = {}
Runtime.__index = Runtime

-- `GameState.GAME` (docs: 30). Fallback literal for the headless harness.
local GAME_STATE = (GameState ~= nil and GameState.GAME) or 30

-- Always-armed Bucket key. Character buckets: `player_<normalized>` (Util.NormalizePlayerName).
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
        -- disarm (stay resident) on leave-GAME; discard+reload only on a real name switch.
        buckets = { [GLOBAL_BUCKET] = { key = GLOBAL_BUCKET, armed = true, resident = true } },
        _characterBucketKey = nil,
        -- GAME only sets this; Update drains it (name may not be readable yet; reload has no GameStateChanged).
        _pendingResolve = false,
        _bucketLoader = nil,
        channels = {},
        -- Poll Enter/Leave edge state, keyed by graph then nodeId (ids unique only within a graph).
        -- Weak keys; missing ⇒ false (already-true-at-load fires Enter); never serialized.
        pollEdgeState = setmetatable({}, { __mode = "k" }),
        -- Parallel to pollEdgeState: last seedKey per graph/node. Weak-keyed so a dropped Graph
        -- does not keep the keys alive.
        pollSeedKey = setmetatable({}, { __mode = "k" }),
        effects = Effects.new(),
        infobox = InfoBoxArea.new(),
        screenMarkerCapture = ScreenMarkerCapture.new(),
        objectMarkerCapture = ObjectMarkerCapture.new(),
        keyboardActivityTick = 0,
        mouseActivityTick = 0,
        _lastMousePos = nil,
    }, Runtime)
    self:_bindActivityTracking()
    self:_bindLifecycle()
    -- Reload mid-session gets no GameStateChanged: if already in-world, drain on first Update.
    if self:_resolveDisplayName() ~= nil then
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
    -- LOAD-BEARING print() - do NOT remove (undocumented client-API quirk, measured in-client):
    -- reading an injected event-source channel and calling :Subscribe in the same scope hard-crashes
    -- the client unless a print() executes in that scope first. Looks like a stray debug line; it
    -- isn't. Every event-source Subscribe/Unsubscribe site needs it. See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
    print()
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
    -- LOAD-BEARING print() - do NOT remove. Without it, this GameStateChanged Subscribe hard-crashes
    -- the client on plugin load (this was the #89 crash: the function was copied from
    -- _bindActivityTracking above but dropped its print()). See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
    print()
    source.Subscribe("watchdog_runtime_gamestate", function(payload)
        runtime:_onGameStateChanged(payload)
    end)
    self._lifecycleSource = source
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

---@return string|nil
function Runtime:_resolveDisplayName()
    if self.identitySource == nil or self.identitySource.Resolve == nil then
        return nil
    end
    local ok, name = pcall(function() return self.identitySource:Resolve() end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

-- Same normalized name → re-arm in place (preserve pollEdgeState). Different → discard + load.
function Runtime:_drainPendingResolve()
    if not self._pendingResolve then
        return
    end
    local name = self:_resolveDisplayName()
    if name == nil then
        return -- not readable yet (or no source); keep the flag and retry next tick
    end
    self._pendingResolve = false
    local normalized = Util.NormalizePlayerName(name)
    local key = "player_" .. normalized
    if key == self._characterBucketKey then
        local bucket = self.buckets[key]
        if bucket ~= nil then bucket.armed = true end
        return
    end
    if self._characterBucketKey ~= nil then
        self:_discardBucket(self._characterBucketKey)
    end
    self:_loadCharacterBucket(key, normalized, name)
end

function Runtime:_loadCharacterBucket(key, normalized, displayName)
    self.buckets[key] = { key = key, armed = true, resident = true, displayName = displayName }
    self._characterBucketKey = key
    if self._bucketLoader == nil then
        return
    end
    local ok, restored = callOrLog("bucket loader for '" .. tostring(normalized) .. "'",
        self._bucketLoader, normalized)
    if ok and type(restored) == "table" then
        for _, alert in ipairs(restored) do
            self:AddAlert(alert.id, alert.name, alert.graph, alert.enabled, key)
        end
    end
end

-- Character switch (or rename to a new normalized key): drop alerts + pollEdgeState. No disk adoption.
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

---@param loader fun(normalizedName: string): Watchdog.RestoredAlert[]
function Runtime:SetBucketLoader(loader)
    self._bucketLoader = loader
end

-- Resident character (stays loaded while logged out, though disarmed).
---@return string|nil displayName
---@return string|nil bucketKey
function Runtime:GetActiveCharacter()
    local key = self._characterBucketKey
    if key == nil then return nil, nil end
    local bucket = self.buckets[key]
    if bucket == nil then return nil, nil end
    return bucket.displayName, key
end

---@param dt number
function Runtime:Update(dt)
    self:_drainPendingResolve()
    self:_pollMouseActivity()
    self.effects:Update(dt)
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
    local ix, iy = IfaceScale.ToInterface(pos.x, pos.y)
    local last = self._lastMousePos
    -- The first poll only establishes a baseline - there's nothing to compare yet, so it
    -- must not itself count as "activity" (a plugin load/reload isn't a mouse movement).
    if last ~= nil and (ix ~= last.x or iy ~= last.y) then
        self.mouseActivityTick = self.mouseActivityTick + 1
    end
    self._lastMousePos = { x = ix, y = iy }
end

---@param id integer|nil
---@param name string|nil
---@param graph LibNodeGraph.Graph|nil
---@param enabled boolean|nil
---@param bucketKey string|nil  # owning Bucket; defaults to `global`
---@return Watchdog.RuntimeAlert
function Runtime:AddAlert(id, name, graph, enabled, bucketKey)
    local alert = { id = id, name = name, graph = graph, enabled = enabled ~= false,
        bucketKey = bucketKey or GLOBAL_BUCKET }
    self.alerts[#self.alerts + 1] = alert
    self:_indexAlert(alert)
    self:PreloadGraph(graph)
    return alert
end

-- Memory-only; caller persists.
---@param id integer
---@return boolean
function Runtime:RemoveAlert(id)
    local kept, removed = {}, false
    for _, alert in ipairs(self.alerts) do
        if alert.id == id then
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

-- Memory-only; does not re-enter the persistence hook. Groups are not live alerts.
---@param id integer
---@param enabled boolean
---@return boolean
function Runtime:SetAlertEnabled(id, enabled)
    for _, alert in ipairs(self.alerts) do
        if alert.id == id then
            alert.enabled = enabled and true or false
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
---@param resolver fun(id: integer): boolean
function Runtime:SetEnabledResolver(resolver)
    self._enabledResolver = resolver
end

-- Fail-open: no resolver, nil id, or a raising resolver leaves the alert firing.
---@param id integer|nil
---@return boolean
function Runtime:_ancestorsEnabled(id)
    if self._enabledResolver == nil or id == nil then return true end
    local ok, result = callOrLog("enabled resolver for id '" .. tostring(id) .. "'",
        self._enabledResolver, id)
    if not ok then return true end
    return result ~= false
end

-- Persist by Entry id, `global` Bucket only - ids are unique within a Bucket, not across them.
---@param alert { id: integer|nil, bucketKey: string }
---@param enabled boolean
function Runtime:_persistEnabled(alert, enabled)
    if alert.id == nil or alert.bucketKey ~= GLOBAL_BUCKET then return end
    if self._persistence ~= nil and self._persistence.SetEnabled ~= nil then
        callOrLog("persistence SetEnabled for id '" .. tostring(alert.id) .. "'",
            self._persistence.SetEnabled, alert.id, enabled)
    end
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
    end
    return #matches
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
        if alert.enabled and self:_ancestorsEnabled(alert.id) and self:_bucketArmed(alert.bucketKey) then
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
            local passes = true
            if binding.filter ~= nil then
                local nodeHandle = makeNodeHandle(graph, node)
                local ok, result = callOrLog(
                    "filter error on '" .. binding.typeKey .. "'",
                    binding.filter, payload, nodeHandle)
                passes = ok and (result and true or false)
            end
            if passes then
                pcall(function() graph:Fire(nodeId, payload) end)
            end
        end
    end
end

-- Same fire predicate; skipped alerts freeze poll edge state (world-hop re-arm must not replay Enter).
function Runtime:_firePollBinding(binding, payload)
    for _, alert in ipairs(self.alerts) do
        if alert.enabled and self:_ancestorsEnabled(alert.id) and self:_bucketArmed(alert.bucketKey) then
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
    -- Unsubscribe MiniMenuReady so reload does not leak the prior instance.
    pcall(function() self.objectMarkerCapture:Cancel() end)
    self.effects:Clear()
    self.infobox:Clear()
end

return Runtime
