-- Exercises runtime.lua's dispatcher through its one seam: an injected fake event source
-- (fake_event_source.lua) standing in for the client `Event` global. Feeds raw events
-- synchronously and asserts which node fires, with what payload, and in what order the
-- transform -> filter -> run pipeline runs (#24 acceptance criteria).

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")

TestRuntime = {}

function TestRuntime:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)
end

-- A trigger fixture that republishes ctx.payload on a data pin so tests can read what a
-- Fire actually carried via graph:GetLastValue, since downstream nodes never see the payload.
local function registerEchoTrigger(registry, typeKey)
    registry:RegisterNodeType(typeKey, {
        category = "trigger",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
            { name = "payload", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("payload", ctx.payload)
            ctx:Fire("out")
        end,
    })
end

--- BindTrigger / subscription plumbing --------------------------------------------------

function TestRuntime:testBindTriggerSubscribesChannelExactlyOnce()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")

    luaunit.assertEquals(self.source:SubscribeCount("Custom"), 1)
end

function TestRuntime:testMultipleTypeKeysOnSameChannelShareOneSubscription()
    registerEchoTrigger(self.registry, "fixture.echoA")
    registerEchoTrigger(self.registry, "fixture.echoB")
    self.runtime:BindTrigger("fixture.echoA", { { event = "Shared" } })
    self.runtime:BindTrigger("fixture.echoB", { { event = "Shared" } })

    local aId = self.graph:AddNode("fixture.echoA")
    local bId = self.graph:AddNode("fixture.echoB")

    self.source:Push("Shared", "x")

    luaunit.assertEquals(self.source:SubscribeCount("Shared"), 1)
    luaunit.assertEquals(self.graph:GetLastValue(aId, "payload"), "x")
    luaunit.assertEquals(self.graph:GetLastValue(bId, "payload"), "x")
end

function TestRuntime:testOnlyBoundTypeKeyFires()
    registerEchoTrigger(self.registry, "fixture.echoA")
    registerEchoTrigger(self.registry, "fixture.echoB")
    self.runtime:BindTrigger("fixture.echoA", { { event = "OnlyA" } })

    local aId = self.graph:AddNode("fixture.echoA")
    local bId = self.graph:AddNode("fixture.echoB")

    self.source:Push("OnlyA", "hit")

    luaunit.assertEquals(self.graph:GetLastValue(aId, "payload"), "hit")
    luaunit.assertNil(self.graph:GetLastValue(bId, "payload"))
end

--- transform -> filter -> run order and identity default ---------------------------------

function TestRuntime:testIdentityPayloadWhenTransformOmitted()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Raw" } })
    local nodeId = self.graph:AddNode("fixture.echo")

    self.source:Push("Raw", { chatMessage = "hello" })

    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), { chatMessage = "hello" })
end

-- Registers a trigger whose run() records "run" into `order` and republishes ctx.payload on
-- the `value` pin - shared by the two order/gating tests below, which each supply their own
-- `order` table and transform/filter pair to bind against it.
local function registerPipedTrigger(registry, order)
    registry:RegisterNodeType("fixture.piped", {
        category = "trigger",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
            { name = "value", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            table.insert(order, "run")
            ctx:Out("value", ctx.payload)
            ctx:Fire("out")
        end,
    })
end

function TestRuntime:testTransformFilterRunOrderAndShapedPayload()
    local order = {}
    registerPipedTrigger(self.registry, order)

    self.runtime:BindTrigger("fixture.piped", {
        {
            event = "Custom",
            transform = function(raw)
                table.insert(order, "transform")
                return raw.value * 2
            end,
            filter = function(payload)
                table.insert(order, "filter")
                return payload > 0
            end,
        },
    })

    local nodeId = self.graph:AddNode("fixture.piped")
    self.source:Push("Custom", { value = 5 })

    luaunit.assertEquals(order, { "transform", "filter", "run" })
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "value"), 10)
end

function TestRuntime:testFilterFalseBlocksRun()
    local order = {}
    registerPipedTrigger(self.registry, order)

    self.runtime:BindTrigger("fixture.piped", {
        {
            event = "Custom",
            transform = function(raw)
                table.insert(order, "transform")
                return raw.value * 2
            end,
            filter = function(payload)
                table.insert(order, "filter")
                return payload > 0
            end,
        },
    })

    local nodeId = self.graph:AddNode("fixture.piped")
    self.source:Push("Custom", { value = -1 })

    luaunit.assertEquals(order, { "transform", "filter" })
    luaunit.assertNil(self.graph:GetLastValue(nodeId, "value"))
end

function TestRuntime:testFilterCanSourceMatchByNodeControl()
    -- Simulates a multi-source node's filter reading its own control to pick which
    -- payloads it cares about (the "no universal discriminator field" case from #23).
    self.registry:RegisterNodeType("fixture.selective", {
        category = "trigger",
        pins = {
            { name = "source", kind = "data", direction = "in", dataType = "string", default = "any" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "value", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("value", ctx.payload.value)
            ctx:Fire("out")
        end,
    })

    self.runtime:BindTrigger("fixture.selective", {
        {
            event = "Multi",
            filter = function(payload, node)
                local wanted = node.GetControl("source")
                return wanted == "any" or wanted == payload.source
            end,
        },
    })

    local anyId = self.graph:AddNode("fixture.selective", { source = "any" })
    local npcId = self.graph:AddNode("fixture.selective", { source = "npc" })
    local objId = self.graph:AddNode("fixture.selective", { source = "obj" })

    self.source:Push("Multi", { source = "npc", value = 42 })

    luaunit.assertEquals(self.graph:GetLastValue(anyId, "value"), 42)
    luaunit.assertEquals(self.graph:GetLastValue(npcId, "value"), 42)
    luaunit.assertNil(self.graph:GetLastValue(objId, "value"))
end

function TestRuntime:testFilterSeesNodeMode()
    self.registry:RegisterNodeType("fixture.modeful", {
        category = "trigger",
        defaultMode = "full",
        modes = {
            {
                key = "full",
                label = "Full",
                pins = {
                    { name = "out", kind = "exec", direction = "out" },
                    { name = "value", kind = "data", direction = "out", dataType = "any" },
                },
            },
            {
                key = "count",
                label = "Count",
                pins = {
                    { name = "out", kind = "exec", direction = "out" },
                    { name = "value", kind = "data", direction = "out", dataType = "any" },
                },
            },
        },
        run = function(ctx)
            ctx:Out("value", ctx.payload)
            ctx:Fire("out")
        end,
    })

    self.runtime:BindTrigger("fixture.modeful", {
        {
            event = "Custom",
            filter = function(_, node)
                return node.mode == "count"
            end,
        },
    })

    local fullId = self.graph:AddNode("fixture.modeful")
    local countId = self.graph:AddNode("fixture.modeful", nil, "count")

    self.source:Push("Custom", "hit")

    luaunit.assertNil(self.graph:GetLastValue(fullId, "value"))
    luaunit.assertEquals(self.graph:GetLastValue(countId, "value"), "hit")
end

function TestRuntime:testTransformComputedOnceRegardlessOfNodeCount()
    local transformCalls = 0
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", {
        {
            event = "Custom",
            transform = function(raw)
                transformCalls = transformCalls + 1
                return raw
            end,
        },
    })

    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")

    self.source:Push("Custom", "x")

    luaunit.assertEquals(transformCalls, 1)
end

--- Injectable event source + Stop ---------------------------------------------------------

function TestRuntime:testEventSourceIsInjectedNotGlobal()
    -- No global `Event` exists under the standalone interpreter; construction and dispatch
    -- via the injected fake must not touch it.
    luaunit.assertNil(_G.Event)
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    local nodeId = self.graph:AddNode("fixture.echo")
    self.source:Push("Custom", "ok")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), "ok")
end

--- Activity ticks (runtime.keyboardActivityTick / runtime.mouseActivityTick, #29) -----------

function TestRuntime:testKeyboardActivityTickStartsAtZero()
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 0)
end

function TestRuntime:testKeyboardActivityTickIncrementsOnKeyDown()
    self.source:Push("KeyDown", { gameKey = "F8", isRepeat = false })
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 1)

    self.source:Push("KeyDown", { gameKey = "A", isRepeat = false })
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 2)
end

function TestRuntime:testKeyboardActivityTickSurvivesStop()
    self.source:Push("KeyDown", { gameKey = "F8", isRepeat = false })
    self.runtime:Stop()
    -- Stop unsubscribes the dispatcher's own channels; the tick value itself must persist
    -- (it's just a counter, not a live subscription).
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 1)
end

-- A fake `Mouse` global stand-in: `pos` is mutated by the test between Update() calls to
-- simulate movement; `available` lets a test simulate Mouse.IsAvailable() == false (mobile).
local function newFakeMouse(x, y)
    local mouse = { available = true, pos = { x = x, y = y } }
    function mouse.IsAvailable() return mouse.available end
    function mouse.GetPosition() return mouse.pos end
    return mouse
end

function TestRuntime:testMouseActivityTickStartsAtZero()
    local runtime = Runtime.new(self.source.source, newFakeMouse(0, 0))
    luaunit.assertEquals(runtime.mouseActivityTick, 0)
end

function TestRuntime:testMouseActivityTickIncrementsOnPositionChange()
    local mouse = newFakeMouse(10, 10)
    local runtime = Runtime.new(self.source.source, mouse)

    runtime:Update(1) -- first poll just establishes the baseline position
    luaunit.assertEquals(runtime.mouseActivityTick, 0)

    mouse.pos = { x = 11, y = 10 }
    runtime:Update(1)
    luaunit.assertEquals(runtime.mouseActivityTick, 1)

    runtime:Update(1)
    luaunit.assertEquals(runtime.mouseActivityTick, 1)
end

function TestRuntime:testMouseActivityTickIgnoredWhenMouseUnavailable()
    local mouse = newFakeMouse(0, 0)
    mouse.available = false
    local runtime = Runtime.new(self.source.source, mouse)

    runtime:Update(1)
    mouse.pos = { x = 99, y = 99 }
    runtime:Update(1)

    luaunit.assertEquals(runtime.mouseActivityTick, 0)
end

function TestRuntime:testGetMousePosAppliesInterfaceScale()
    -- Screen-marker UpdateDrag (and InfoBox hover) read GetMousePos; raw Mouse must be
    -- converted to interface units or the drag rubber-band drifts down-right of the cursor.
    local prevGame = rawget(_G, "game")
    rawset(_G, "game", { options = { InterfaceScale = { setting = 200 } } })
    local mouse = newFakeMouse(400, 300)
    local runtime = Runtime.new(self.source.source, mouse)
    runtime:Update(1)
    local mx, my = runtime:GetMousePos()
    rawset(_G, "game", prevGame)
    luaunit.assertEquals(mx, 200)
    luaunit.assertEquals(my, 150)
end

--- Alert model: all-graphs-live fan-out + enable/disable (#27, #86) -----------------------

-- A fake persistence hook standing in for the Store wiring: records every SetEnabled call and
-- exposes the last-known flag per Entry *id* (persistence keys on id, not name - #86) so a test
-- can assert the runtime persisted the change.
local function newFakePersistence()
    local fake = { calls = {}, state = {} }
    fake.SetEnabled = function(id, enabled)
        fake.calls[#fake.calls + 1] = { id = id, enabled = enabled }
        fake.state[id] = enabled
    end
    return fake
end

function TestRuntime:testTriggerFiresInAllEnabledAlertsNotJustOne()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    local graphA = Graph.new(self.registry)
    local graphB = Graph.new(self.registry)
    self.runtime:SetGraph(nil) -- clear the setUp single-graph alert
    self.runtime:AddAlert(1, "A", graphA, true)
    self.runtime:AddAlert(2, "B", graphB, true)
    local aId = graphA:AddNode("fixture.echo")
    local bId = graphB:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")

    luaunit.assertEquals(graphA:GetLastValue(aId, "payload"), "ping")
    luaunit.assertEquals(graphB:GetLastValue(bId, "payload"), "ping")
end

function TestRuntime:testDisabledAlertSuppressesFiringButStaysLive()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, false) -- starts disabled
    local aId = graphA:AddNode("fixture.echo")

    self.source:Push("Custom", "while-disabled")
    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))

    self.runtime:SetEnabled("A", true)
    self.source:Push("Custom", "after-enable")
    luaunit.assertEquals(graphA:GetLastValue(aId, "payload"), "after-enable")
end

function TestRuntime:testSetEnabledPersistsThroughHook()
    local fake = newFakePersistence()
    self.runtime:SetPersistence(fake)

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(7, "A", graphA, true)

    luaunit.assertTrue(self.runtime:SetEnabled("A", false))
    luaunit.assertEquals(fake.state[7], false)
    luaunit.assertEquals(#fake.calls, 1)
    luaunit.assertEquals(fake.calls[1], { id = 7, enabled = false })
end

function TestRuntime:testToggleFlipsAndPersists()
    local fake = newFakePersistence()
    self.runtime:SetPersistence(fake)

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(7, "A", graphA, true)

    luaunit.assertEquals(self.runtime:Toggle("A"), 1)
    luaunit.assertEquals(fake.state[7], false)
    self.runtime:Toggle("A")
    luaunit.assertEquals(fake.state[7], true)
end

function TestRuntime:testToggleReturnsNilForUnknownAlert()
    self.runtime:SetGraph(nil)
    luaunit.assertNil(self.runtime:Toggle("ghost"))
end

function TestRuntime:testSetEnabledReturnsFalseAndPersistsNothingForUnknownName()
    -- A stale name (post-rename) has no live alert - and thus no Entry id to key persistence on,
    -- so nothing is written. Firing is unaffected (nothing live matches).
    local fake = newFakePersistence()
    self.runtime:SetPersistence(fake)
    self.runtime:SetGraph(nil)

    luaunit.assertFalse(self.runtime:SetEnabled("ghost", false))
    luaunit.assertEquals(#fake.calls, 0)
end

--- Multi-match name targeting (#86: names aren't unique) ----------------------------------

function TestRuntime:testSetEnabledFansOutOverAllAlertsSharingName()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    local fake = newFakePersistence()
    self.runtime:SetPersistence(fake)

    local graphA = Graph.new(self.registry)
    local graphB = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "dup", graphA, true)
    self.runtime:AddAlert(2, "dup", graphB, true)
    local aId = graphA:AddNode("fixture.echo")
    local bId = graphB:AddNode("fixture.echo")

    luaunit.assertTrue(self.runtime:SetEnabled("dup", false))
    luaunit.assertEquals(fake.state[1], false)
    luaunit.assertEquals(fake.state[2], false)

    self.source:Push("Custom", "silenced")
    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))
    luaunit.assertNil(graphB:GetLastValue(bId, "payload"))
end

function TestRuntime:testToggleFlipsEachMatchIndependently()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    local fake = newFakePersistence()
    self.runtime:SetPersistence(fake)

    -- Same name "dup", but a *mixed* starting state: id 1 enabled, id 2 disabled.
    local graphA = Graph.new(self.registry)
    local graphB = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "dup", graphA, true)
    self.runtime:AddAlert(2, "dup", graphB, false)
    local aId = graphA:AddNode("fixture.echo")
    local bId = graphB:AddNode("fixture.echo")

    luaunit.assertEquals(self.runtime:Toggle("dup"), 2)
    luaunit.assertEquals(fake.state[1], false)
    luaunit.assertEquals(fake.state[2], true)

    self.source:Push("Custom", "after-toggle")
    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))
    luaunit.assertEquals(graphB:GetLastValue(bId, "payload"), "after-toggle")
end

function TestRuntime:testTriggerFiresOnNodeAddedMidEdit()
    -- The editor edits the current alert's *same live graph instance*; a node added to it after
    -- registration must fire without re-registering the alert (the "fires mid-edit" criterion).
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)

    local newId = graphA:AddNode("fixture.echo")
    self.source:Push("Custom", "mid-edit")

    luaunit.assertEquals(graphA:GetLastValue(newId, "payload"), "mid-edit")
end

-- A fake Store standing in for store.lua behind the persistence hook: SetEnabled mutates an
-- in-memory Bucket (id-keyed entries) and a save-count records that Save ran, so a test can
-- assert the whole SetEnabled -> Store.SetEnabled -> Save path the AC calls out.
local function newFakeStoreHook()
    local doc = { entries = { { id = 1, name = "A", enabled = true } } }
    local fake = { doc = doc, saves = 0 }
    fake.SetEnabled = function(id, enabled)
        for _, entry in ipairs(doc.entries) do
            if entry.id == id then entry.enabled = enabled end
        end
        fake.saves = fake.saves + 1 -- stands in for Store.Save flushing the doc
    end
    return fake
end

function TestRuntime:testSetEnabledPersistsThroughFakeStoreEndToEnd()
    local store = newFakeStoreHook()
    self.runtime:SetPersistence(store)
    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)

    self.runtime:SetEnabled("A", false)

    luaunit.assertEquals(store.doc.entries[1].enabled, false)
    luaunit.assertEquals(store.saves, 1)
end

function TestRuntime:testAlertMayToggleItself()
    -- The Alert Toggle action (#35) can target its own graph by name; toggling flips this
    -- alert's own enabled flag, silencing its subsequent triggers.
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)
    local aId = graphA:AddNode("fixture.echo")

    self.runtime:Toggle("A") -- self-disable
    self.source:Push("Custom", "should-not-fire")
    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))
end

--- Enabled-chain gate (#88): an ancestor-group resolver suppresses firing per alert -------

function TestRuntime:testEnabledResolverSuppressesFiringForDescendantsOfADisabledGroup()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    -- Alert 1 sits under a disabled group, alert 2 under an enabled one - modelled by a resolver
    -- that reports ancestor-enabled per Entry id (what Store.AncestorsEnabled provides live).
    self.runtime:SetEnabledResolver(function(id) return id ~= 1 end)

    local graphA = Graph.new(self.registry)
    local graphB = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true) -- own flag on, but ancestor group off
    self.runtime:AddAlert(2, "B", graphB, true)
    local aId = graphA:AddNode("fixture.echo")
    local bId = graphB:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")

    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))
    luaunit.assertEquals(graphB:GetLastValue(bId, "payload"), "ping")
end

function TestRuntime:testEnabledResolverReEvaluatedEachFire()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    local ancestorsEnabled = false
    self.runtime:SetEnabledResolver(function() return ancestorsEnabled end)

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)
    local aId = graphA:AddNode("fixture.echo")

    self.source:Push("Custom", "while-group-off")
    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))

    ancestorsEnabled = true
    self.source:Push("Custom", "after-group-on")
    luaunit.assertEquals(graphA:GetLastValue(aId, "payload"), "after-group-on")
end

function TestRuntime:testOwnDisabledStaysSuppressedRegardlessOfResolver()
    -- The runtime's own per-alert flag ANDs with the ancestor gate: a disabled alert never fires
    -- even when every ancestor group is enabled.
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    self.runtime:SetEnabledResolver(function() return true end)

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, false) -- own flag off
    local aId = graphA:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")
    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))
end

function TestRuntime:testNoResolverFiresAsBefore()
    -- With no resolver wired (a runtime with no groups), every enabled alert fires exactly as it
    -- did before the enabled-chain gate existed.
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)
    local aId = graphA:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")
    luaunit.assertEquals(graphA:GetLastValue(aId, "payload"), "ping")
end

function TestRuntime:testResolverErrorFailsOpenSoOneBadGateCannotSilenceEverything()
    -- A resolver that raises must not take down dispatch - fire-time gating is lenient like the
    -- transform/filter fan-out, so the alert still fires.
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    self.runtime:SetEnabledResolver(function() error("boom") end)

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)
    local aId = graphA:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")
    luaunit.assertEquals(graphA:GetLastValue(aId, "payload"), "ping")
end

--- Manager live-set sync by id (#91): RemoveAlert / SetAlertEnabled / RenameAlert ----------
-- Manager mutations own persistence (Store.Save); these APIs only keep the live alert set in
-- sync so a deleted/disabled alert stops firing and a rename retargets name-based SetEnabled.

function TestRuntime:testRemoveAlertStopsFiringAndDropsFromLiveSet()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    local graphA = Graph.new(self.registry)
    local graphB = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)
    self.runtime:AddAlert(2, "B", graphB, true)
    local aId = graphA:AddNode("fixture.echo")
    local bId = graphB:AddNode("fixture.echo")

    luaunit.assertTrue(self.runtime:RemoveAlert(1))
    self.source:Push("Custom", "after-delete")

    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))
    luaunit.assertEquals(graphB:GetLastValue(bId, "payload"), "after-delete")
    luaunit.assertEquals(#self.runtime.alerts, 1)
    luaunit.assertEquals(self.runtime.alerts[1].id, 2)
end

function TestRuntime:testRemoveAlertReturnsFalseForUnknownId()
    self.runtime:SetGraph(nil)
    luaunit.assertFalse(self.runtime:RemoveAlert(999))
end

function TestRuntime:testSetAlertEnabledSuppressesFiringWithoutPersisting()
    -- Manager already wrote Store; this is memory-only so the persistence hook is not re-entered.
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    local fake = newFakePersistence()
    self.runtime:SetPersistence(fake)

    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "A", graphA, true)
    local aId = graphA:AddNode("fixture.echo")

    luaunit.assertTrue(self.runtime:SetAlertEnabled(1, false))
    self.source:Push("Custom", "while-off")
    luaunit.assertNil(graphA:GetLastValue(aId, "payload"))
    luaunit.assertEquals(#fake.calls, 0) -- Manager owns persist; runtime does not double-write

    luaunit.assertTrue(self.runtime:SetAlertEnabled(1, true))
    self.source:Push("Custom", "while-on")
    luaunit.assertEquals(graphA:GetLastValue(aId, "payload"), "while-on")
end

function TestRuntime:testRenameAlertRetargetsNameIndex()
    local fake = newFakePersistence()
    self.runtime:SetPersistence(fake)
    local graphA = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "old", graphA, true)

    luaunit.assertTrue(self.runtime:RenameAlert(1, "new"))
    luaunit.assertFalse(self.runtime:SetEnabled("old", false)) -- stale name: no match
    luaunit.assertTrue(self.runtime:SetEnabled("new", false))
    luaunit.assertEquals(fake.state[1], false)
    luaunit.assertEquals(self.runtime.alerts[1].name, "new")
end

function TestRuntime:testStopUnsubscribesAllChannels()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    local nodeId = self.graph:AddNode("fixture.echo")

    self.source:Push("Custom", "first")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), "first")

    self.runtime:Stop()
    self.source:Push("Custom", "second")

    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), "first")
end

--- Preload node-type hook (#33: PreloadNode/PreloadGraph, graph-restore + control-commit) --

local function registerPreloadFixture(registry, calls)
    registry:RegisterNodeType("fixture.preload", {
        category = "action",
        -- A real preload node (e.g. action.custom_sound) reads its resource from a declared
        -- data-input pin's Control; the engine only stores controls for declared pins, so the
        -- fixture must declare `resource` too or GetControl("resource") comes back nil.
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "resource", kind = "data", direction = "in", dataType = "string" },
        },
        preload = function(node)
            calls[#calls + 1] = { id = node.id, resource = node.GetControl("resource") }
        end,
        run = function(_ctx) end,
    })
end

function TestRuntime:testPreloadNodeCallsTheNodeTypesPreloadHook()
    local calls = {}
    registerPreloadFixture(self.registry, calls)
    self.runtime:SetRegistry(self.registry)
    local nodeId = self.graph:AddNode("fixture.preload", { resource = "beep" })

    self.runtime:PreloadNode(self.graph, nodeId)

    luaunit.assertEquals(#calls, 1)
    luaunit.assertEquals(calls[1].id, nodeId)
    luaunit.assertEquals(calls[1].resource, "beep")
end

function TestRuntime:testPreloadNodeIsANoopWithoutRegistrySet()
    local calls = {}
    registerPreloadFixture(self.registry, calls)
    local nodeId = self.graph:AddNode("fixture.preload")

    self.runtime:PreloadNode(self.graph, nodeId)

    luaunit.assertEquals(#calls, 0)
end

function TestRuntime:testPreloadNodeIsANoopForATypeWithNoPreloadHook()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:SetRegistry(self.registry)
    local nodeId = self.graph:AddNode("fixture.echo")

    local ok = pcall(function() self.runtime:PreloadNode(self.graph, nodeId) end)
    luaunit.assertTrue(ok)
end

function TestRuntime:testPreloadGraphRunsEveryNodesPreloadHook()
    local calls = {}
    registerPreloadFixture(self.registry, calls)
    self.runtime:SetRegistry(self.registry)
    self.graph:AddNode("fixture.preload", { resource = "a" })
    self.graph:AddNode("fixture.preload", { resource = "b" })

    self.runtime:PreloadGraph(self.graph)

    luaunit.assertEquals(#calls, 2)
end

function TestRuntime:testAddAlertPreloadsTheGraphOnce()
    -- Simulates the graph-restore call site: main.lua adds every restored alert through
    -- AddAlert, which must run the preload pass with no separate step.
    local calls = {}
    registerPreloadFixture(self.registry, calls)
    self.runtime:SetRegistry(self.registry)
    local graphB = Graph.new(self.registry)
    graphB:AddNode("fixture.preload", { resource = "restored" })

    self.runtime:AddAlert(1, "restored-alert", graphB, true)

    luaunit.assertEquals(#calls, 1)
    luaunit.assertEquals(calls[1].resource, "restored")
end


function TestRuntime:testRenameAlertTargetsItsBucketWhenIdsOverlap()
    local global = self.runtime:AddAlert(1, "global alert", nil, true, "global")
    local player = self.runtime:AddAlert(1, "player alert", nil, true, "player_test")
    luaunit.assertTrue(self.runtime:RenameAlert(1, "renamed", "player_test"))
    luaunit.assertEquals(global.name, "global alert")
    luaunit.assertEquals(player.name, "renamed")
    luaunit.assertFalse(self.runtime:RenameAlert(1, "missing", "player_other"))
end

return TestRuntime
