-- runtime.lua — the single dispatcher that owns every client `Event.*.Subscribe`/
-- `.Unsubscribe` for Watchdog's trigger nodes. Each trigger node file declares its own
-- event binding via `Runtime:BindTrigger(typeKey, entries)` instead of `main.lua`
-- hardcoding one Subscribe block per trigger type (the old `Event.ChatMessage` block this
-- replaces). The engine's node-type descriptor stays client-agnostic; bindings live here.
--
-- Per bound entry, on every raw event: `transform(raw) -> payload` runs once (identity if
-- omitted), then for each live node of that entry's typeKey, `filter(payload, node) -> bool`
-- gates it (always passes if omitted), and a pass calls `graph:Fire(nodeId, payload)` so the
-- node's own `run(ctx)` only shapes outputs and fires exec.
--
-- Every saved graph is a live "alert" (#27): the dispatcher fans out over *all* enabled alerts
-- (`Runtime:AddAlert`), not just the one the editor is viewing, so triggers fire in every alert
-- and while the editor is open mid-edit. A per-alert `enabled` flag is checked at fire time —
-- `Runtime:SetEnabled`/`Toggle` flip it in O(1) without tearing down the graph, and persist it
-- through the injected persistence hook (`Runtime:SetPersistence`, wired to the Store).
--
-- Each alert carries an Entry `id` (its persistence identity, #86) and a `name` (free-text, and
-- *not* unique). The Alert Toggle node targets by name, so `SetEnabled`/`Toggle` map a name to
-- *every* matching alert and act on all of them: SetEnabled sets each match to the given state;
-- Toggle flips each match independently (a mixed set stays mixed-but-inverted — there is no shared
-- per-name state). Persistence is keyed by the entry `id`, one write per affected alert.
--
-- The event source is injectable (`Runtime.new(eventSource)`, defaults to the client `Event`
-- global) so tests can feed synthetic events through a fake source instead.
--
-- Runtime also owns the EffectRegistry (`runtime.effects`, see effects.lua), the shared InfoBox
-- Area (`runtime.infobox`, see ui/infobox.lua, #41), and two activity tick counters
-- (`runtime.keyboardActivityTick` / `runtime.mouseActivityTick`), consumed later by effect
-- nodes like Screen Flash's dismiss-on (#29). Keyboard activity is tracked the same
-- way as any trigger binding, through the injectable event source; mouse activity has no
-- client event to bind (see Mouse docs — position is poll-only) so it's advanced from
-- `Runtime:Update(dt)`, called once per Logic tick alongside the effect registry. Like the
-- event source, the `Mouse` global is injectable (`Runtime.new(eventSource, mouseSource)`) so
-- this is exercised under the standalone test harness too.

local Effects = require("effects")
local InfoBoxArea = require("ui/infobox")
local ScreenMarkerCapture = require("ui/screen_marker_capture")
local ObjectMarkerCapture = require("ui/object_marker_capture")
local Util = require("util")

local Runtime = {}
Runtime.__index = Runtime

-- The `GameState.GAME` enum value — the reliable "logged in and in a game world" signal on
-- `Event.GameStateChanged` (research #74; docs core/events.html lists GAME = 30). Resolved from
-- the client enum when present, falling back to the documented literal under the headless test
-- harness (no `GameState` global), so tests drive lifecycle by pushing `{ newState = 30 }`.
local GAME_STATE = (GameState ~= nil and GameState.GAME) or 30

-- The always-armed, never-disarmed `global` Bucket key (#89). Character Buckets key on
-- `player_<normalized displayName>` (see Util.NormalizePlayerName) and arm/disarm with login.
local GLOBAL_BUCKET = "global"

-- Wraps a node-authored (or persistence-hook) callback so one bad function can't break dispatch
-- for every other binding — used by the transform/filter fan-out and the enable-persistence hook.
-- See util.lua. Declared up here so every method below (SetEnabled included) can see it.
local function callOrLog(context, fn, ...)
    return Util.CallOrLog("runtime", context, fn, ...)
end

-- The read-only `nodeHandle` handed to every node-authored hook — a filter's second arg
-- (`_fireBindingInGraph`) and the preload hook's arg (`_preloadNode`). One builder keeps the
-- `{ id, typeKey, GetControl(pinName) }` shape identical across both call sites.
local function makeNodeHandle(graph, node)
    return {
        id = node.id,
        typeKey = node.typeKey,
        GetControl = function(pinName) return graph:GetControl(node.id, pinName) end,
    }
end

-- `mouseSource` is the injectable stand-in for the client `Mouse` global (defaults to it),
-- mirroring `eventSource`'s seam: tests pass a fake exposing `IsAvailable()`/`GetPosition()`
-- instead of relying on the real (test-environment-absent) client global.
-- `identitySource` is the injectable stand-in for the client `Player` global's identity read
-- (#89), mirroring `eventSource`/`mouseSource`. It exposes a single `Resolve() -> displayName|nil`
-- that returns the current character's display name only when actually logged in and in-world
-- (`Player.IsAvailable()` ∧ `entity.isValid`, see main.lua's wrapper), or nil otherwise. Defaults
-- to nil: with no identity source the runtime never opens a character Bucket — only `global` is
-- ever armed — so every existing single-source test keeps its behavior unchanged.
function Runtime.new(eventSource, mouseSource, identitySource)
    local self = setmetatable({
        eventSource = eventSource or Event,
        mouseSource = mouseSource or Mouse,
        identitySource = identitySource,
        -- Every saved graph instantiates live as an "alert" (#27); the dispatcher fans out over
        -- *all* of them, not just the one the editor is viewing. `alerts` is the ordered list of
        -- { id, name, graph, enabled }. `_alertsByName` indexes it for name-targeted
        -- SetEnabled/Toggle — but names aren't unique (#86), so each value is a *list* of every
        -- alert sharing that name, and both APIs act on the whole list.
        alerts = {},
        _alertsByName = {},
        _persistence = nil,
        -- Player scoping (#89). `buckets` maps a Bucket key -> { key, armed, resident, displayName }.
        -- `global` is created armed and never disarmed. Every alert carries a `bucketKey`; the fire
        -- predicate gates on `alert.enabled AND buckets[alert.bucketKey].armed` — nothing else. A
        -- character Bucket arms on the GAME transition (unchanged name), disarms but stays resident
        -- on leaving GAME, and is discarded+reloaded only on a genuine character switch.
        buckets = { [GLOBAL_BUCKET] = { key = GLOBAL_BUCKET, armed = true, resident = true } },
        -- The one resident character Bucket's key (only one character is ever loaded at a time), or
        -- nil while logged out / before first login. Compared to the resolved name to tell a
        -- world-hop/reconnect (same name -> re-arm in place) from a switch (different -> discard+load).
        _characterBucketKey = nil,
        -- Identity is resolved *deferred*, not inline in the GameStateChanged callback: a GAME
        -- transition raises this flag and each Logic tick (Update) drains it, retrying until the
        -- name is readable. This also covers a plugin reload mid-session, which gets no
        -- GameStateChanged at all — the constructor's cold-start poll raises the same flag (#77 §8).
        _pendingResolve = false,
        -- Injected by SetBucketLoader: fn(normalizedName) -> Watchdog.RestoredAlert[] for a
        -- character's Bucket (main.lua wires it to Store.LoadKey + Store.RestoreAll; tests fake it).
        _bucketLoader = nil,
        -- eventName -> { bindings = { { typeKey, transform, filter }, ... },
        --                subscribed, subscribeName, source }
        channels = {},
        -- Poll edge state (#28), keyed by graph then by nodeId — a poll node's predicate
        -- history so the gate can fire `Enter`/`Leave` only on a transition. Node ids are only
        -- unique *within* a graph (two alerts can hold the same id), so it's a per-graph subtable
        -- rather than one flat `nodeId -> bool` map. Weak graph keys let a dropped alert's state
        -- be collected. Lazy (missing ⇒ false, so already-true-at-load fires Enter) and never
        -- serialized — a reload re-detects edges from scratch.
        pollEdgeState = setmetatable({}, { __mode = "k" }),
        effects = Effects.new(),
        -- The shared InfoBox Area (#41): a registry-level layout component living on the same
        -- overlay Canvas as `effects`, but not a free EffectRegistry handle (it needs per-box
        -- bounds effects deliberately disclaims — see ui/infobox.lua). Reached by action.infobox
        -- the same way nodes reach `runtime.effects`.
        infobox = InfoBoxArea.new(),
        -- The shared "Draw on screen" capture overlay (#39) behind action.screen_marker's
        -- `rect` Control — armed from the Editor (ui/graph.lua), mounted/drawn/driven from
        -- main.lua the same way runtime.infobox's own click-capture layer is.
        screenMarkerCapture = ScreenMarkerCapture.new(),
        -- The shared "Select object" MiniMenu select mode (#40) behind action.object_marker's
        -- `object` Control — armed from the Editor (ui/graph.lua). Unlike screenMarkerCapture it
        -- has no mounted layer to drive: it self-manages an Event.MiniMenuEntrySelected
        -- subscription while armed (see ui/object_marker_capture.lua), so main.lua only cancels
        -- it on teardown.
        objectMarkerCapture = ObjectMarkerCapture.new(),
        keyboardActivityTick = 0,
        mouseActivityTick = 0,
        _lastMousePos = nil,
    }, Runtime)
    self:_bindActivityTracking()
    self:_bindLifecycle()
    -- Cold-start (#77 §8): a plugin reload mid-session receives no GameStateChanged, so poll once
    -- now — if already in-world, raise the pending-resolve flag the first Update tick will drain
    -- (by which point main.lua has wired the Bucket loader). Logged out ⇒ no-op; a later GAME
    -- transition raises the flag instead.
    if self:_resolveDisplayName() ~= nil then
        self._pendingResolve = true
    end
    return self
end

-- Subscribes to KeyDown on the injectable event source to count keyboard activity (any key,
-- including repeats — "activity" just means the player touched the keyboard). Kept separate
-- from the BindTrigger/channels fan-out below since it isn't tied to a node typeKey; torn
-- down explicitly in Stop.
function Runtime:_bindActivityTracking()
    local source = self.eventSource.KeyDown
    if source == nil or source.Subscribe == nil then
        return
    end
    local runtime = self
    -- LOAD-BEARING print() — do NOT remove (undocumented client-API quirk, measured in-client):
    -- reading an injected event-source channel and calling :Subscribe in the same scope hard-crashes
    -- the client unless a print() executes in that scope first. Looks like a stray debug line; it
    -- isn't. Every event-source Subscribe/Unsubscribe site needs it. See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
    print()
    source.Subscribe("watchdog_runtime_activity_key", function()
        runtime.keyboardActivityTick = runtime.keyboardActivityTick + 1
    end)
    self._activitySource = source
end

--- Player scoping: identity + armed/resident lifecycle (#89) -------------------------------

-- Subscribes to the injectable event source's `GameStateChanged` channel — the *only* login
-- lifecycle signal the client exposes (research #74). Kept separate from the BindTrigger/channels
-- fan-out (it drives Bucket arming, not a node typeKey) and torn down in Stop. A GAME transition
-- only raises the pending-resolve flag; the actual identity read + arm/load happens deferred on
-- the next Update (see `_drainPendingResolve`).
function Runtime:_bindLifecycle()
    local source = self.eventSource.GameStateChanged
    if source == nil or source.Subscribe == nil then
        return
    end
    local runtime = self
    -- LOAD-BEARING print() — do NOT remove. Without it, this GameStateChanged Subscribe hard-crashes
    -- the client on plugin load (this was the #89 crash: the function was copied from
    -- _bindActivityTracking above but dropped its print()). See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
    print()
    source.Subscribe("watchdog_runtime_gamestate", function(payload)
        runtime:_onGameStateChanged(payload)
    end)
    self._lifecycleSource = source
end

-- Handles one `GameStateChanged`. Entering GAME raises the pending-resolve flag (identity is read
-- deferred, on the next Update — it isn't established the name is readable the instant this fires,
-- and deferring is correct either way, #77 §8). Any other newState is "left GAME": the resident
-- character Bucket disarms (stays resident — its graphs, pollEdgeState and timers persist, they
-- just stop firing) and any pending arm is cancelled. `global` is untouched — it's never disarmed.
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

-- Reads the current character display name through the injected identity source, or nil when
-- there's no source / not logged in / the read failed. The source owns the IsAvailable ∧ isValid
-- gate; this only guards against a missing source and a non-string result.
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

-- Drains the pending-resolve flag, called once per Logic tick from Update. Retries the identity
-- read until it succeeds (so a GAME transition whose name isn't readable yet resolves on a later
-- tick). On success, compares the resolved character to the resident one:
--   * same normalized name  -> re-arm in place (world-hop / reconnect): no reload, no state reset,
--     so `pollEdgeState` is preserved and no `Enter` edge is replayed (#77 §7).
--   * different name / none  -> discard the resident character Bucket and load the new one.
-- `global` is never touched here.
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

-- Creates the resident, armed character Bucket for `key` and loads its saved alerts through the
-- injected loader (a no-op set when no loader is wired). Each loaded alert is added under this
-- Bucket key so the fire predicate gates it on this Bucket's armed state.
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

-- Discards a resident Bucket: drops every alert that belongs to it (from the flat list, the
-- name index, and its per-graph pollEdgeState) and removes the Bucket itself. Used on a genuine
-- character switch — the only expensive lifecycle path. A rename resolves to a different
-- normalized key and so lands here too, orphaning the old Bucket on disk (no adoption, #77 §3).
function Runtime:_discardBucket(key)
    local kept = {}
    for _, alert in ipairs(self.alerts) do
        if alert.bucketKey == key then
            self.pollEdgeState[alert.graph] = nil
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

-- Appends `alert` to its name's match list in `_alertsByName` (creating the list on first use).
-- A no-op for an anonymous alert (name nil — untargetable). Shared by AddAlert (incremental) and
-- _rebuildNameIndex (full rebuild) so the two paths can't produce a differently-shaped index.
function Runtime:_indexAlert(alert)
    if alert.name == nil then return end
    local matches = self._alertsByName[alert.name]
    if matches == nil then
        matches = {}
        self._alertsByName[alert.name] = matches
    end
    matches[#matches + 1] = alert
end

-- Rebuilds the name -> {alerts} index from the current flat `alerts` list. Called after a discard
-- prunes the list; keeping the index a pure function of `alerts` avoids drift between the two.
function Runtime:_rebuildNameIndex()
    self._alertsByName = {}
    for _, alert in ipairs(self.alerts) do
        self:_indexAlert(alert)
    end
end

-- True iff the alert's Bucket exists and is armed (`global` always is; a character Bucket only
-- between its GAME-arm and the next leave-GAME). The armed half of the fire predicate.
---@param bucketKey string|nil
---@return boolean
function Runtime:_bucketArmed(bucketKey)
    local bucket = self.buckets[bucketKey or GLOBAL_BUCKET]
    return bucket ~= nil and bucket.armed == true
end

-- Injects the character-Bucket loader (see `_bucketLoader`). Kept as its own seam like
-- SetPersistence/SetRegistry rather than a Runtime.new param, since main.lua builds it (over the
-- Store + registry) after constructing the runtime.
function Runtime:SetBucketLoader(loader)
    self._bucketLoader = loader
end

-- The resident character Bucket's display name and key, or nil when no character is loaded (a
-- fresh boot at the login screen, before any GAME transition). Returns the *resident* character —
-- it stays resident (though disarmed) while logged out, so the Manager can keep showing that
-- character's scope tab and editing continues off-world (#77). The Alert Manager (#90) reads this
-- to decide whether to offer a second scope tab beside `Global`, and how to label it.
---@return string|nil displayName
---@return string|nil bucketKey
function Runtime:GetActiveCharacter()
    local key = self._characterBucketKey
    if key == nil then return nil, nil end
    local bucket = self.buckets[key]
    if bucket == nil then return nil, nil end
    return bucket.displayName, key
end

-- Advances the effect registry and polls mouse-activity by position change. Called once per
-- Logic tick (see main.lua); `dt` is forwarded verbatim to every live effect handle's update.
function Runtime:Update(dt)
    self:_drainPendingResolve()
    self:_pollMouseActivity()
    self.effects:Update(dt)
end

-- The last polled mouse position (x, y), or nil, nil before the first Update tick / when no
-- mouseSource is injected. Lets a Draw-pass caller (main.lua, for the InfoBox Area's hover
-- tooltip) reuse the same poll _pollMouseActivity already does each Logic tick, instead of a
-- second GetPosition call of its own.
function Runtime:GetMousePos()
    local pos = self._lastMousePos
    if pos == nil then return nil, nil end
    return pos.x, pos.y
end

-- Mouse position is poll-only (no move/click event on the client — see core/mouse.lua docs),
-- hence advancing this from Update rather than a binding. `mouseSource` defaults to nil (no
-- client global set up) outside the client, so this is a no-op unless injected.
function Runtime:_pollMouseActivity()
    local mouse = self.mouseSource
    if mouse == nil or not mouse.IsAvailable() then
        return
    end
    local ok, pos = pcall(mouse.GetPosition)
    if not ok or pos == nil then
        return
    end
    local last = self._lastMousePos
    -- The first poll only establishes a baseline — there's nothing to compare yet, so it
    -- must not itself count as "activity" (a plugin load/reload isn't a mouse movement).
    if last ~= nil and (pos.x ~= last.x or pos.y ~= last.y) then
        self.mouseActivityTick = self.mouseActivityTick + 1
    end
    self._lastMousePos = { x = pos.x, y = pos.y }
end

-- Registers a live graph as an alert the dispatcher fans out over. `enabled` defaults to true;
-- a disabled alert stays live (its nodes are never torn down) but has its triggers suppressed at
-- fire time, so toggling it back on is O(1) and lossless. `id` is the Entry identity persistence
-- keys on (#86); `name` is free-text display used only for name-targeted SetEnabled/Toggle and
-- may be nil (anonymous — untargetable) or shared with other alerts (names aren't unique, so a
-- duplicate name *appends* to that name's match list rather than replacing).
--
-- Also runs the generalized `preload(node)` node-type hook (#33) over every node already in the
-- graph — this is the "graph-restore" call site: main.lua adds every restored alert exactly
-- once at startup, through this same method, so no separate restore-time pass is needed.
---@param id integer|nil
---@param name string|nil
---@param graph LibNodeGraph.Graph|nil
---@param enabled boolean|nil
---@param bucketKey string|nil  # which Bucket owns this alert; defaults to `global` (#89)
---@return { id: integer|nil, name: string|nil, graph: LibNodeGraph.Graph|nil, enabled: boolean, bucketKey: string }
function Runtime:AddAlert(id, name, graph, enabled, bucketKey)
    local alert = { id = id, name = name, graph = graph, enabled = enabled ~= false,
        bucketKey = bucketKey or GLOBAL_BUCKET }
    self.alerts[#self.alerts + 1] = alert
    self:_indexAlert(alert)
    self:PreloadGraph(graph)
    return alert
end

-- Drops the live alert with Entry `id` from the fan-out set (Manager delete, #91). Clears its
-- poll-edge state and rebuilds the name index. Persistence is the caller's job (Store.DeleteById
-- + Save) — this only keeps firing in sync. Returns true if an alert with that id was removed.
---@param id integer
---@return boolean
function Runtime:RemoveAlert(id)
    local kept, removed = {}, false
    for _, alert in ipairs(self.alerts) do
        if alert.id == id then
            self.pollEdgeState[alert.graph] = nil
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

-- Flips one live alert's `enabled` flag by Entry `id` (Manager enable toggle, #91). Memory-only —
-- the Manager already wrote Store; this does not re-enter the persistence hook. Returns true if
-- an alert with that id existed. A group toggle never reaches here (groups aren't live alerts);
-- the enabled-chain resolver reads the Store doc directly.
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

-- Renames one live alert by Entry `id` and rebuilds the name index (Manager rename, #91).
-- Memory-only — persistence is the caller's job. Returns true if an alert with that id existed.
-- A group rename never reaches here (groups aren't live alerts).
---@param id integer
---@param name string
---@return boolean
function Runtime:RenameAlert(id, name)
    for _, alert in ipairs(self.alerts) do
        if alert.id == id then
            alert.name = name
            self:_rebuildNameIndex()
            return true
        end
    end
    return false
end

-- Retargets a live alert's Bucket key without Remove/Add (#92 cross-scope move). Preserves the
-- alert object (and its poll-edge state) so no `Enter` edge is replayed — both Buckets are armed
-- by construction while the Manager can offer a cross-scope drop. Returns true if an alert with
-- that id existed.
---@param id integer
---@param bucketKey string
---@return boolean
function Runtime:SetAlertBucketKey(id, bucketKey)
    for _, alert in ipairs(self.alerts) do
        if alert.id == id then
            alert.bucketKey = bucketKey or GLOBAL_BUCKET
            return true
        end
    end
    return false
end

-- Injects the node-type registry (#33) so PreloadNode/PreloadGraph can look up a node's
-- descriptor by typeKey. Kept as its own seam (like SetPersistence) rather than a Runtime.new
-- param, since main.lua constructs the registry after the runtime.
function Runtime:SetRegistry(registry)
    self._registry = registry
end

-- Runs one already-resolved node's `preload(node)` hook, if its registered type declares one.
-- Shared by PreloadGraph (which holds each node from its own scan) and PreloadNode (which
-- resolves by id first), so the type lookup and hook call live in one place.
function Runtime:_preloadNode(graph, node)
    local nodeType = self._registry:GetNodeType(node.typeKey)
    if nodeType == nil or nodeType.preload == nil then
        return
    end
    callOrLog("preload error on '" .. tostring(node.typeKey) .. "'",
        nodeType.preload, makeNodeHandle(graph, node))
end

-- Runs every node's `preload(node)` node-type hook (if it has one) for one graph. A no-op
-- until SetRegistry has been called (e.g. AddAlert during early startup, before the registry
-- exists) or when `graph` is nil.
function Runtime:PreloadGraph(graph)
    if graph == nil or self._registry == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        self:_preloadNode(graph, node)
    end
end

-- Runs one node's `preload(node)` node-type hook, if its registered type has one. This is the
-- "control-commit" call site (#33): the Editor calls this right after Graph:SetControl so a
-- resource-backed node (e.g. action.custom_sound) preloads the instant its dropdown Control is
-- picked, not just at graph-restore. `node` (the hook's argument) exposes the same
-- `{ id, typeKey, GetControl(pinName) }` shape as the dispatcher's own filter nodeHandle.
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

-- Back-compat convenience (and the single-graph test path): replace the whole alert set with one
-- anonymous, always-enabled alert. main.lua uses AddAlert for the real multi-alert startup.
function Runtime:SetGraph(graph)
    self.alerts = {}
    self._alertsByName = {}
    if graph ~= nil then
        self:AddAlert(nil, nil, graph, true)
    end
end

-- Injects the persistence hook the alert-enable API writes through: an object exposing
-- `SetEnabled(id, enabled)` (main.lua wires it to Store.SetEnabled + Store.Save; tests pass a
-- fake that records calls). Keyed by the Entry `id` (#86), since names aren't unique. Kept as a
-- seam so the runtime's dispatch logic never touches the client PersistentDB directly.
function Runtime:SetPersistence(persistence)
    self._persistence = persistence
end

-- Injects the enabled-chain gate (#88): `resolver(id) -> bool` reports whether every ancestor
-- GROUP of the alert's Entry `id` is enabled — the enabled-chain minus the alert's own flag, which
-- the runtime already checks via `alert.enabled`. main.lua wires it to Store.AncestorsEnabled over
-- the live document, so a group toggle or a subtree move re-resolves on the very next fire (nothing
-- is cached). Left unset (a runtime with no groups) every alert is treated as having all ancestors
-- enabled, so firing behaves exactly as it did before the gate existed.
---@param resolver fun(id: integer): boolean
function Runtime:SetEnabledResolver(resolver)
    self._enabledResolver = resolver
end

-- True unless the injected resolver reports a disabled ancestor group for `id`. Fail-open: no
-- resolver wired, a nil id (an anonymous alert has no Entry to key on), or a resolver that raises
-- all leave the alert firing — mirroring the lenient transform/filter handling, so one broken gate
-- can never silence every alert.
---@param id integer|nil
---@return boolean
function Runtime:_ancestorsEnabled(id)
    if self._enabledResolver == nil or id == nil then return true end
    local ok, result = callOrLog("enabled resolver for id '" .. tostring(id) .. "'",
        self._enabledResolver, id)
    if not ok then return true end
    return result ~= false
end

-- Persists one alert's enabled flag through the injected hook, keyed by its Entry id. A no-op for
-- an anonymous alert (id nil) or when no persistence is wired. Called once per affected alert, so
-- a multi-match SetEnabled/Toggle writes each matching alert's flag exactly like a single one does.
--
-- Scoped to `global` alerts (#89): the injected hook owns the `global` Bucket document, and Entry
-- ids are only unique *within* a Bucket — persisting a character alert's id through it would
-- collide with the same id in `global`. A character alert still flips in memory (so it stops
-- firing immediately); persisting per-character enable state is deferred to the Manager (#90).
---@param alert { id: integer|nil, bucketKey: string }
---@param enabled boolean
function Runtime:_persistEnabled(alert, enabled)
    if alert.id == nil or alert.bucketKey ~= GLOBAL_BUCKET then return end
    if self._persistence ~= nil and self._persistence.SetEnabled ~= nil then
        callOrLog("persistence SetEnabled for id '" .. tostring(alert.id) .. "'",
            self._persistence.SetEnabled, alert.id, enabled)
    end
end

-- Enables or disables *every* alert sharing `name` and persists each. Targets by free-text name
-- (any graph may toggle any alert, including itself; a stale name after a rename matches nothing —
-- an accepted no-op, #27). Because names aren't unique (#86), a name may name several alerts and
-- all are set to `enabled`. Returns true if at least one live alert matched. With no match there's
-- no Entry id to key persistence on, so nothing is written.
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

-- Flips the enabled flag of *every* alert sharing `name`, each independently (so a mix of on/off
-- alerts stays mixed-but-inverted — there is no shared per-name state), and persists each. Returns
-- the number of alerts flipped, or nil if no live alert of that name exists (nothing to flip).
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

-- Registers a trigger node type's event binding(s). `entries` is a list of
-- `{ kind = "event"|"poll", event = "ChannelName", transform = fn(raw) -> payload,
--    filter = fn(payload, node) -> bool }`.
-- Multi-source nodes (e.g. a future Entity Spawn node) list several entries. Each distinct
-- `event` is subscribed exactly once, no matter how many typeKeys bind to it.
--
-- `kind` defaults to "event": the payload fans out to every filter-passing node on every event
-- (the Chat/Tick path). A "poll" entry rides the *same* transform -> filter pipeline but adds an
-- edge gate (#28): `transform` samples shared world state once per tick, `filter(payload, node)`
-- is the per-node predicate, and the node's own `Enter`/`Leave` exec pin fires only on the
-- transition of that predicate — see `_firePollBindingInGraph`. A poll entry is expected to bind
-- a per-tick channel (e.g. "Logic") and declare a `transform` that returns nil when the source is
-- unreadable (logged out), which freezes edge state for that tick.
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
                -- A nil sample means the source was unreadable this tick (e.g. logged out): skip
                -- the whole binding and leave every node's edge state untouched (frozen), so there's
                -- no spurious Leave now and no relog-Enter next tick unless a real transition occurs.
                if payload ~= nil then
                    self:_firePollBinding(binding, payload)
                end
            else
                self:_fireBinding(binding, payload)
            end
        end
    end
end

-- Fans a shaped payload out to every matching node in every *firing* alert's graph. The full fire
-- predicate is three independent O(1) gates, all checked here at fire time rather than by tearing
-- down the alert: its own `enabled` flag, its enabled-chain (every ancestor group enabled, #88),
-- and its Bucket being *armed* (a logged-in character, or `global`, #89). A disabled alert, one
-- suppressed by a disabled ancestor group, or one in a disarmed character Bucket (logged out /
-- other character) is skipped without tearing anything down, so toggling, grouping, and arming are
-- all lossless — the alert stays live but silent. The editor's current graph is just one alert
-- among these, so its triggers fire mid-edit like any other's.
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

-- Poll fan-out (#28). Same shape as `_fireBinding` — over every *firing* alert, gated by the same
-- three-part predicate (own flag, enabled-chain #88, armed Bucket #89) — but each graph is handled
-- by `_firePollBindingInGraph`, which applies the edge gate instead of firing on every filter pass.
-- A non-firing alert (own flag off, suppressed by a disabled ancestor group, or in a disarmed
-- Bucket) is skipped and its edge state left frozen until it fires again. That freezing is exactly
-- what makes a world-hop's disarm→re-arm invisible: the preserved predicate state means no spurious
-- `Enter` is replayed on re-arm (#89).
function Runtime:_firePollBinding(binding, payload)
    for _, alert in ipairs(self.alerts) do
        if alert.enabled and self:_ancestorsEnabled(alert.id) and self:_bucketArmed(alert.bucketKey) then
            self:_firePollBindingInGraph(binding, payload, alert.graph)
        end
    end
end

-- Returns this graph's lazy `nodeId -> bool` edge-state subtable, creating it on first use. Kept
-- per-graph (not one flat map) because node ids are only unique within a graph — see
-- `pollEdgeState` in Runtime.new.
function Runtime:_pollEdgeStateFor(graph)
    local states = self.pollEdgeState[graph]
    if states == nil then
        states = {}
        self.pollEdgeState[graph] = states
    end
    return states
end

-- What the dispatcher hands a poll node's `run(ctx)` as `ctx.payload` — the resolved edge plus
-- the value `transform` sampled this tick. A poll node's run is expected to do only
-- `ctx:Fire(ctx.payload.edge)` (and optionally surface `sample` on data outputs); the dispatcher
-- owns which edge occurred, so the node never re-derives it.
---@class Watchdog.PollFirePayload
---@field edge "Enter"|"Leave"  # the transition the edge gate detected this tick
---@field sample any            # the value transform() sampled this tick (shared world state)

-- The edge gate: for every poll node of this binding's typeKey, evaluate the per-node predicate
-- `filter(payload, node)` and compare it to the node's remembered state. A false->true transition
-- fires the node's `Enter` exec pin; true->false fires `Leave`. The node's own `run(ctx)` receives
-- `{ edge = "Enter"|"Leave", sample = payload }` and is expected only to `ctx:Fire(ctx.payload.edge)`
-- (and optionally surface `sample` on data outputs) — the dispatcher owns which edge occurred.
-- `Leave` firing when unwired is a harmless no-op (the engine finds no target connections), so
-- the "optional Leave" contract needs no wiring check here.
--
-- Edge state starts false (a node absent from `edgeStates`), so a predicate already true at load
-- fires `Enter` on the first tick. A filter error freezes that one node's edge (treated like a
-- nil sample) so a broken predicate can't manufacture a spurious transition.
function Runtime:_firePollBindingInGraph(binding, payload, graph)
    if graph == nil then
        return
    end
    local edgeStates = self:_pollEdgeStateFor(graph)
    for _, node in ipairs(graph:GetNodes()) do
        if node.typeKey == binding.typeKey then
            local nodeId = node.id
            -- nil marks "freeze this node" (filter errored); true/false is the predicate result.
            local current = true
            if binding.filter ~= nil then
                local nodeHandle = makeNodeHandle(graph, node)
                local ok, result = callOrLog(
                    "poll filter error on '" .. binding.typeKey .. "'",
                    binding.filter, payload, nodeHandle)
                if ok then
                    current = result and true or false
                else
                    current = nil
                end
            end
            if current ~= nil then
                local prev = edgeStates[nodeId] == true -- lazy: missing ⇒ false
                if current and not prev then
                    pcall(function() graph:Fire(nodeId, { edge = "Enter", sample = payload }) end)
                elseif prev and not current then
                    pcall(function() graph:Fire(nodeId, { edge = "Leave", sample = payload }) end)
                end
                edgeStates[nodeId] = current
            end
        end
    end
end

-- Unsubscribes every channel this runtime subscribed (trigger bindings + the activity
-- tracker) and empties the effect registry. Mirrors the per-event Unsubscribe calls
-- main.lua used to make by hand for each hardcoded trigger.
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
    -- Cancel any armed Object Marker select mode (#40) so its Event.MiniMenuEntrySelected
    -- subscription is unsubscribed on teardown/reload rather than leaking across instances.
    pcall(function() self.objectMarkerCapture:Cancel() end)
    self.effects:Clear()
    self.infobox:Clear()
end

return Runtime
