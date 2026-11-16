-- Exercises toast.lua's ToastStack through its pure logic seam: Show/Dismiss/Update
-- against a real EffectRegistry (in-memory, no Canvas needed - mirrors test_effects.lua) plus
-- the anchor drag/persistence math. Canvas drawing (_drawHandle) and the client-only capture
-- mount are intentionally not asserted here, same convention as effects.lua's own Mount/Draw.
-- Update's clickthrough sync is asserted with a stand-in panel.

local luaunit = require("luaunit")
local EffectRegistry = require("src/effects")
local Theme = require("src/ui/theme")
local Toast = require("src/toast")
local ToastNode = require("src/nodes/actions/toast")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")

TestToast = {}

-- A minimal in-memory stand-in for the anchor persistence hook: { Load()->pos|nil, Save(pos) }.
local function newFakePersistence()
    local fake = { saved = nil, saves = 0 }
    fake.Load = function() return fake.saved end
    fake.Save = function(pos)
        fake.saved = { dx = pos.dx, dy = pos.dy }
        fake.saves = fake.saves + 1
    end
    return fake
end

function TestToast:setUp()
    self.effects = EffectRegistry.new()
    self.toast = Toast.new(self.effects)
end

--- Show: creates a live, drawable handle tracked per node --------------------------------

function TestToast:testShowAddsOneLiveHandle()
    self.toast:Show("nodeA", { text = "hi" })
    luaunit.assertEquals(self.toast:LiveCount(), 1)
    luaunit.assertEquals(self.effects:StackCount(Toast.OWNER), 1)
end

function TestToast:testSameNodeRefireStacksMultipleHandles()
    self.toast:Show("nodeA", { text = "one" })
    self.toast:Show("nodeA", { text = "two" })
    luaunit.assertEquals(self.toast:LiveCount(), 2)
    luaunit.assertEquals(#self.toast.byOwner["nodeA"], 2)
end

function TestToast:testDifferentNodesTrackedIndependently()
    self.toast:Show("nodeA", { text = "a" })
    self.toast:Show("nodeB", { text = "b" })
    luaunit.assertEquals(#self.toast.byOwner["nodeA"], 1)
    luaunit.assertEquals(#self.toast.byOwner["nodeB"], 1)
end

--- Shared cap: 10 total across every node, oldest evicted -------------------------------

function TestToast:testSharedStackCapsAtTenAcrossAllNodes()
    for i = 1, 12 do
        self.toast:Show("node" .. i, { text = tostring(i) })
    end
    luaunit.assertEquals(self.toast:LiveCount(), 10)
    luaunit.assertEquals(self.effects:StackCount(Toast.OWNER), 10)
end

function TestToast:testEvictionForgetsTheOldestNodesBookkeepingToo()
    for i = 1, 11 do
        self.toast:Show("node" .. i, { text = tostring(i) })
    end
    luaunit.assertNil(self.toast.byOwner["node1"])
    luaunit.assertNotNil(self.toast.byOwner["node11"])
end

--- TTL / sticky lifecycle (advanced via EffectRegistry:Update) ---------------------------

function TestToast:testDefaultTTLExpiresAfterFiveSeconds()
    self.toast:Show("nodeA", { text = "hi" })
    self.effects:Update(4)
    luaunit.assertEquals(self.toast:LiveCount(), 1)
    self.effects:Update(1.01)
    luaunit.assertEquals(self.toast:LiveCount(), 0)
end

function TestToast:testCustomTTLOverridesTheDefault()
    self.toast:Show("nodeA", { text = "hi", ttl = 2 })
    self.effects:Update(1.5)
    luaunit.assertEquals(self.toast:LiveCount(), 1)
    self.effects:Update(0.6)
    luaunit.assertEquals(self.toast:LiveCount(), 0)
end

function TestToast:testStickyIgnoresTTL()
    self.toast:Show("nodeA", { text = "hi", sticky = true, ttl = 1 })
    self.effects:Update(1000)
    luaunit.assertEquals(self.toast:LiveCount(), 1)
end

function TestToast:testStickyNeverExpiresRegardlessOfElapsedTime()
    self.toast:Show("nodeA", { text = "hi", sticky = true })
    self.effects:Update(1000)
    luaunit.assertEquals(self.toast:LiveCount(), 1)
end

--- Dismiss: clears only the named node's live toasts -----------------------------------

function TestToast:testDismissClearsOnlyThatNodesHandles()
    self.toast:Show("nodeA", { text = "a1" })
    self.toast:Show("nodeA", { text = "a2" })
    self.toast:Show("nodeB", { text = "b1" })

    self.toast:Dismiss("nodeA")

    luaunit.assertEquals(self.toast:LiveCount(), 1)
    luaunit.assertNil(self.toast.byOwner["nodeA"])
    luaunit.assertEquals(#self.toast.byOwner["nodeB"], 1)
end

function TestToast:testDismissOfUnknownNodeIsANoOp()
    self.toast:Show("nodeA", { text = "a" })
    self.toast:Dismiss("ghost")
    luaunit.assertEquals(self.toast:LiveCount(), 1)
end

function TestToast:testDismissedStickyOverlayIsGoneEvenThoughItNeverExpires()
    self.toast:Show("nodeA", { text = "a", sticky = true })
    self.toast:Dismiss("nodeA")
    self.effects:Update(1)
    luaunit.assertEquals(self.toast:LiveCount(), 0)
end

--- Anchor: default + persisted round-trip -------------------------------------------------

function TestToast:testDefaultAnchorOffsetIsZero()
    local a = self.toast:GetAnchorOffset()
    luaunit.assertEquals(a, { dx = 0, dy = 0 })
end

function TestToast:testLoadsPersistedAnchorOnConstruction()
    local persistence = newFakePersistence()
    persistence.saved = { dx = 12, dy = -4 }
    local toast = Toast.new(self.effects, persistence)
    luaunit.assertEquals(toast:GetAnchorOffset(), { dx = 12, dy = -4 })
end

--- Drag: begin/drag-to/end, persisting only on release ------------------------------------

function TestToast:testDragMovesAnchorByMouseDelta()
    self.toast:BeginDrag({ x = 100, y = 100 })
    self.toast:DragTo({ x = 130, y = 90 })
    luaunit.assertEquals(self.toast:GetAnchorOffset(), { dx = 30, dy = -10 })
end

function TestToast:testDragToWithoutBeginIsANoOp()
    self.toast:DragTo({ x = 500, y = 500 })
    luaunit.assertEquals(self.toast:GetAnchorOffset(), { dx = 0, dy = 0 })
end

function TestToast:testLockedStackDoesNotDrag()
    local HubLayers = require("src/ui/hub_layers")
    HubLayers.SetPositionsLocked(true)
    self.toast:BeginDrag({ x = 100, y = 100 })
    self.toast:DragTo({ x = 130, y = 90 })
    luaunit.assertEquals(self.toast:GetAnchorOffset(), { dx = 0, dy = 0 })
    HubLayers.SetPositionsLocked(false)
end

-- Stand-in for the client panel Update resizes. Mount itself is not under test.
local function fakeCapture()
    local cap = { clickthrough = false, w = -1, h = -1 }
    function cap:SetPos(x, y)
        self.x, self.y = x, y
    end
    function cap:SetSize(w, h)
        self.w, self.h = w, h
    end
    return cap
end

function TestToast:testLockedStackLetsClicksThrough()
    local HubLayers = require("src/ui/hub_layers")
    HubLayers.SetPositionsLocked(true)
    self.toast:Show("nodeA", { text = "hi" })
    self.toast.capture = fakeCapture()
    self.toast:Update()
    luaunit.assertTrue(self.toast.capture.clickthrough)
    luaunit.assertEquals(self.toast.capture.w, 240)
    luaunit.assertEquals(self.toast.capture.h, 48)
end

function TestToast:testUnlockedStackCapturesClicks()
    self.toast:Show("nodeA", { text = "hi" })
    self.toast.capture = fakeCapture()
    self.toast:Update()
    luaunit.assertFalse(self.toast.capture.clickthrough)
    luaunit.assertEquals(self.toast.capture.w, 240)
    luaunit.assertEquals(self.toast.capture.h, 48)
end

function TestToast:testEmptyStackCollapsesCapture()
    self.toast.capture = fakeCapture()
    self.toast.capture.w = 240
    self.toast.capture.h = 48
    self.toast:Update()
    luaunit.assertEquals(self.toast.capture.w, 0)
    luaunit.assertEquals(self.toast.capture.h, 0)
end

function TestToast:testLockDuringDragEndsTheGesture()
    local persistence = newFakePersistence()
    local toast = Toast.new(self.effects, persistence)
    toast:Show("nodeA", { text = "hi" })
    toast.capture = fakeCapture()
    toast:BeginDrag({ x = 0, y = 0 })
    toast._pressed = true
    self._savedMouse = Mouse
    self._restoreMouse = true
    Mouse = { GetPosition = function() return { x = 40, y = 5 } end }
    require("src/ui/hub_layers").SetPositionsLocked(true)
    toast:Update()
    luaunit.assertEquals(toast:GetAnchorOffset(), { dx = 0, dy = 0 })
    luaunit.assertEquals(persistence.saves, 1)
    luaunit.assertTrue(toast.capture.clickthrough)
end

function TestToast:tearDown()
    require("src/ui/hub_layers").SetPositionsLocked(false)
    if self._restoreMouse then
        Mouse = self._savedMouse
    end
end

function TestToast:testResetAnchorClearsTheOffsetAndIgnoresTheOpenDrag()
    local persistence = newFakePersistence()
    local toast = Toast.new(self.effects, persistence)
    toast:Show("nodeA", { text = "hi" })
    toast.capture = fakeCapture()
    toast:BeginDrag({ x = 0, y = 0 })
    toast:DragTo({ x = 10, y = 20 })
    toast._pressed = true
    self._savedMouse = Mouse
    self._restoreMouse = true
    Mouse = { GetPosition = function() return { x = 80, y = 40 } end }
    toast:ResetAnchor()
    luaunit.assertEquals(toast:GetAnchorOffset(), { dx = 0, dy = 0 })
    luaunit.assertEquals(persistence.saved, { dx = 0, dy = 0 })
    luaunit.assertEquals(persistence.saves, 1)
    luaunit.assertEquals(toast.capture.x, 1920 * 0.5 - Theme.TOAST_W * 0.5)
    luaunit.assertEquals(toast.capture.y, Theme.TOAST_TOP_MARGIN)
    toast:Update()
    luaunit.assertEquals(toast:GetAnchorOffset(), { dx = 0, dy = 0 })
    luaunit.assertEquals(persistence.saves, 1)
end

function TestToast:testEndDragPersistsFinalPosition()
    local persistence = newFakePersistence()
    local toast = Toast.new(self.effects, persistence)
    toast:BeginDrag({ x = 0, y = 0 })
    toast:DragTo({ x = 10, y = 20 })
    toast:EndDrag()
    luaunit.assertEquals(persistence.saved, { dx = 10, dy = 20 })
    luaunit.assertEquals(persistence.saves, 1)
end

function TestToast:testDragUpdatesDoNotPersistUntilEndDrag()
    local persistence = newFakePersistence()
    local toast = Toast.new(self.effects, persistence)
    toast:BeginDrag({ x = 0, y = 0 })
    toast:DragTo({ x = 10, y = 20 })
    luaunit.assertEquals(persistence.saves, 0)
end

function TestToast:testEndDragWithoutPersistenceHookIsSafe()
    self.toast:BeginDrag({ x = 0, y = 0 })
    self.toast:DragTo({ x = 5, y = 5 })
    self.toast:EndDrag()
    luaunit.assertEquals(self.toast:GetAnchorOffset(), { dx = 5, dy = 5 })
end

function TestToast:testSecondDragStartsFromThePreviousAnchor()
    self.toast:BeginDrag({ x = 0, y = 0 })
    self.toast:DragTo({ x = 10, y = 10 })
    self.toast:EndDrag()

    self.toast:BeginDrag({ x = 50, y = 50 })
    self.toast:DragTo({ x = 60, y = 45 })
    luaunit.assertEquals(self.toast:GetAnchorOffset(), { dx = 20, dy = 5 })
end

TestToastNodeRun = {}

function TestToastNodeRun:setUp()
    self.registry = Registry.new()
    self.effects = EffectRegistry.new()
    self.toast = Toast.new(self.effects)
    ToastNode.Register(self.registry, { toast = self.toast })
    self.graph = Graph.new(self.registry)
end

function TestToastNodeRun:testDeserializedCloneDismissDoesNotClearOriginal()
    local id = self.graph:AddNode("action.toast", { text = "original" })
    self.graph:FireInput(id, "show")
    local clone = Serialize.Deserialize(Serialize.Serialize(self.graph), self.registry)
    clone:SetControl(id, "text", "imported")
    clone:FireInput(id, "show")
    luaunit.assertEquals(self.toast:LiveCount(), 2)
    clone:FireInput(id, "dismiss")
    luaunit.assertEquals(self.toast:LiveCount(), 1)
end

return TestToast
