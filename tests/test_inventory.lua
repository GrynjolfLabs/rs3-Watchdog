config = config or {}
config.Inv = config.Inv or {}
config.Inv.INV = config.Inv.INV or { id = 93, size = 28 }
config.Inv.BANK = config.Inv.BANK or { id = 95, size = 28 }

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local Json = require("json")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
local InventoryTrigger = require("src/nodes/triggers/inventory")

local INV, BANK = config.Inv.INV, config.Inv.BANK

TestInventory = {}

function TestInventory:setUp()
    config.Inv = { INV = INV, BANK = BANK }

    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    InventoryTrigger.Register(self.registry, self.runtime)

    self.fires = 0
    local t = self
    self.registry:RegisterNodeType("fixture.mark", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() t.fires = t.fires + 1 end,
    })

    self.invs = {}
    _G.Inventory = {
        Find = function(invType)
            if invType == nil then
                return nil
            end
            return t.invs[invType.id] or t.invs[invType]
        end,
    }
end

function TestInventory:tearDown()
    _G.Inventory = nil
end

function TestInventory:setInv(invType, opts)
    opts = opts or {}
    local slots = opts.slots or {}
    self.invs[invType.id or invType] = {
        usedSlotCount = opts.usedSlotCount or #slots,
        slotCount = opts.slotCount or 28,
        isValid = true,
        GetSlots = function() return slots end,
    }
end

function TestInventory:addWired(controls)
    controls = controls or { container = INV }
    local id = self.graph:AddNode("trigger.inventory", controls)
    self.graph:Connect(id, "out", self.graph:AddNode("fixture.mark"), "in")
    return id
end

local function sub(needle) return { needle = needle, mode = "substring" } end
local function pat(needle) return { needle = needle, mode = "pattern" } end

-- Item Count is a Pure Node: connect a Trigger Snapshot, Fire the count node, read `count`.
function TestInventory:addItemCount(triggerId, snapshotPin, controls)
    local id = self.graph:AddNode("inventory.item_count", controls)
    local ok, err = self.graph:Connect(triggerId, snapshotPin or "snapshot", id, "snapshot")
    luaunit.assertNotNil(ok, err)
    return id
end

function TestInventory:pullCount(itemCountId)
    self.graph:Fire(itemCountId)
    return self.graph:GetLastValue(itemCountId, "count")
end

function TestInventory:addItemCountChanged(triggerId, controls)
    local id = self.graph:AddNode("inventory.item_count_changed", controls)
    local ok, err = self.graph:Connect(triggerId, "snapshot", id, "snapshot")
    luaunit.assertNotNil(ok, err)
    ok, err = self.graph:Connect(triggerId, "prevSnapshot", id, "prevSnapshot")
    luaunit.assertNotNil(ok, err)
    return id
end

function TestInventory:readChanged(id)
    self.graph:Fire(id)
    return {
        count = self.graph:GetLastValue(id, "count"),
        prevCount = self.graph:GetLastValue(id, "prevCount"),
        delta = self.graph:GetLastValue(id, "delta"),
    }
end

function TestInventory:pushUpdated(invType, size)
    if size ~= nil then
        invType.size = size
    end
    self.source:Push("InventoryUpdated", { inv = invType, slotsUpdated = {} })
end

function TestInventory:pushAdded(invType)
    self.source:Push("InventoryAdded", { inv = invType })
end

function TestInventory:pushRemoved(invType)
    self.source:Push("InventoryRemoved", { inv = invType })
end

local function slot(name, configName, count, objId)
    return { obj = { name = name, configName = configName, id = objId }, count = count }
end

function TestInventory:testNodeHasNoModesAndNoMatcher()
    local nt = self.registry:GetNodeType("trigger.inventory")
    luaunit.assertEquals(nt.displayName, "Inventory")
    luaunit.assertEquals(nt.category, "trigger")
    luaunit.assertNil(nt.modes)
    luaunit.assertNil(nt.pins.nameMatch)
    luaunit.assertNil(nt.pins.contains)
    luaunit.assertNotNil(nt.pins.container)
    luaunit.assertEquals(nt.pins.container.dataType, "invContainer")
    luaunit.assertEquals(nt.pins.snapshot.dataType, "invSnapshot")
    luaunit.assertEquals(nt.pins.prevSnapshot.dataType, "invSnapshot")
    luaunit.assertEquals(nt.pins.isFull.dataType, "bool")
    luaunit.assertEquals(nt.pins.isEmpty.dataType, "bool")
end

function TestInventory:testConfigInvTypesCompareEqualByIdentity()
    luaunit.assertTrue(config.Inv.INV == INV)
    luaunit.assertTrue(config.Inv.BANK == BANK)
    luaunit.assertFalse(config.Inv.INV == config.Inv.BANK)
    luaunit.assertFalse(config.Inv.INV == { id = 93, size = 28 })
end

function TestInventory:testNNodesCostExactlyOneUpdatedSubscription()
    self:addWired()
    self:addWired({ container = BANK })
    luaunit.assertEquals(self.source:SubscribeCount("InventoryUpdated"), 1)
end

function TestInventory:testFiresOnInventoryUpdated()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) } })
    self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testAddedAndRemovedDoNotFire()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) } })
    self:addWired()
    self:pushAdded(INV)
    self:pushRemoved(INV)
    luaunit.assertEquals(self.fires, 0)
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testDefaultContainerIsInventory()
    self:setInv(INV, {})
    self:setInv(BANK, { slotCount = 10 })
    self:addWired()
    self:pushUpdated(BANK, 10)
    luaunit.assertEquals(self.fires, 0)
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testBankIgnoresInventoryUpdates()
    self:setInv(INV, {})
    self:setInv(BANK, { slotCount = 10 })
    self:addWired({ container = BANK })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 0)
    self:pushUpdated(BANK, 10)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testColdUpdatedHasEmptyPrevSnapshot()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    local prev = self.graph:GetLastValue(nodeId, "prevSnapshot")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 0)
    luaunit.assertEquals(prev.slots, {})
    luaunit.assertEquals(prev.usedSlotCount, 0)
end

function TestInventory:testPresentContainerSeedFillsPrevForNextUpdated()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    InventoryTrigger.SeedPresentContainers()
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots[1].name, "Shark")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[1].name, "Shark")
end

function TestInventory:testLogicTickSeedsPresentContainerLikeAdded()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local nodeId = self:addWired()
    self.source:Push("Logic", {})
    luaunit.assertEquals(self.fires, 0)
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots[1].name, "Shark")
end

function TestInventory:testRemovedClearsPrevForNextUpdated()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    self:pushRemoved(INV)
    luaunit.assertEquals(self.fires, 1)

    self:setInv(INV, { slots = { slot("Lobster", "LOBSTER", 1) }, usedSlotCount = 1 })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 2)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots, {})
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[1].name, "Lobster")
end

function TestInventory:testSnapshotKeepsSlotsAfterANilHole()
    local slots = {}
    slots[2] = slot("Shark", "SHARK", 1)
    self:setInv(INV, { slots = slots, usedSlotCount = 1, slotCount = 28 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    local snap = self.graph:GetLastValue(nodeId, "snapshot")
    luaunit.assertNil(snap.slots[1])
    luaunit.assertEquals(snap.slots[2].name, "Shark")
end

function TestInventory:testMissingInvUsesEventSizeForOccupancy()
    self.invs[INV] = nil
    local nodeId = self:addWired()
    self:pushUpdated(INV, 28)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isEmpty"), true)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), false)
end

function TestInventory:testOccupancyOutsUseContainerSlotCount()
    self:setInv(BANK, {
        slots = {
            slot("Coins", "COINS", 100),
        },
        usedSlotCount = 10,
        slotCount = 10,
    })
    local nodeId = self:addWired({ container = BANK })
    self:pushUpdated(BANK, 10)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 10)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), true)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isEmpty"), false)
end

function TestInventory:testIsEmptyWhenNoUsedSlots()
    self:setInv(INV, { slots = {}, usedSlotCount = 0, slotCount = 28 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isEmpty"), true)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), false)
end

function TestInventory:testIsFullIsNotHardcodedTwentyEight()
    self:setInv(INV, { usedSlotCount = 10, slotCount = 28, slots = {} })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), false)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 10)
end

function TestInventory:testFrozenPrevAcrossTwoUpdates()
    local live = slot("Shark", "SHARK", 1)
    self:setInv(INV, { slots = { live }, usedSlotCount = 1, slotCount = 28 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)

    live.count = 5
    live.obj.name = "mutated"
    self:setInv(INV, { slots = { live }, usedSlotCount = 1, slotCount = 28 })
    self:pushUpdated(INV)

    local prev = self.graph:GetLastValue(nodeId, "prevSnapshot")
    local current = self.graph:GetLastValue(nodeId, "snapshot")
    luaunit.assertEquals(prev.slots[1].name, "Shark")
    luaunit.assertEquals(prev.slots[1].count, 1)
    luaunit.assertEquals(current.slots[1].count, 5)

    live.count = 99
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots[1].count, 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[1].count, 5)
end

-- Client InvType userdata compares equal by id (__eq) but each event is a new proxy.
-- Lua table keys use identity, so CACHE[event.inv] misses every update and prev stays 0/28.
function TestInventory:testPrevSnapshotSurvivesDistinctInvTypeProxies()
    local mt = {
        __eq = function(a, b)
            return a ~= nil and b ~= nil and a.id == b.id
        end,
    }
    local function proxy()
        return setmetatable({ id = INV.id, size = 28 }, mt)
    end

    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1, slotCount = 28 })
    local nodeId = self:addWired({ container = proxy() })
    self:pushUpdated(proxy())
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[1].name, "Shark")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots, {})

    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1), slot("Egg", "EGG", 1) }, usedSlotCount = 2 })
    self:pushUpdated(proxy())
    luaunit.assertEquals(self.fires, 2)
    luaunit.assertEquals(tostring(self.graph:GetLastValue(nodeId, "prevSnapshot")), "1/28: Shark x1")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[2].name, "Egg")
end

function TestInventory:testSnapshotTostringListsItems()
    self:setInv(INV, {
        slots = { slot("Shark", "SHARK", 1), slot("Lobster", "LOBSTER", 5) },
        usedSlotCount = 2,
        slotCount = 28,
    })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(
        tostring(self.graph:GetLastValue(nodeId, "snapshot")),
        "2/28: Shark x1, Lobster x5")
    luaunit.assertEquals(
        tostring(self.graph:GetLastValue(nodeId, "prevSnapshot")),
        "0/28")
end

function TestInventory:testSnapshotHasNoLiveInvHandle()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1, 42) } })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    local snap = self.graph:GetLastValue(nodeId, "snapshot")
    luaunit.assertNil(snap.inv)
    luaunit.assertNil(snap.GetSlots)
    luaunit.assertEquals(snap.slots[1].name, "Shark")
    luaunit.assertEquals(snap.slots[1].configName, "SHARK")
    luaunit.assertEquals(snap.slots[1].count, 1)
    luaunit.assertEquals(snap.slots[1].objId, 42)
end

function TestInventory:testInvContainerCodecPersistsIdNotProxy()
    local nodeId = self:addWired({ container = BANK })
    local data = Serialize.Serialize(self.graph)
    luaunit.assertEquals(data.nodes[1].controls.container, BANK.id)
    luaunit.assertEquals(type(data.nodes[1].controls.container), "number")
    luaunit.assertNotNil(Json.Default.encode(data))

    local rebuilt = Serialize.Deserialize(data, self.registry)
    luaunit.assertTrue(rebuilt:GetControl(nodeId, "container") == BANK)
end

function TestInventory:testInvContainerCodecUnknownIdFallsBackToInventory()
    local nodeId = self:addWired()
    local data = Serialize.Serialize(self.graph)
    data.nodes[1].controls.container = 0
    local rebuilt = Serialize.Deserialize(data, self.registry)
    luaunit.assertTrue(rebuilt:GetControl(nodeId, "container") == INV)
end

function TestInventory:testAddedSeedsPrevForNextUpdated()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local nodeId = self:addWired()
    self:pushAdded(INV)
    luaunit.assertEquals(self.fires, 0)

    self:setInv(INV, {
        slots = { slot("Shark", "SHARK", 1), slot("Lobster", "LOBSTER", 1) },
        usedSlotCount = 2,
    })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 2)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots[1].name, "Shark")
end

--- Item Count (#99) ----------------------------------------------------------------------

function TestInventory:testItemCountIsInventoryCategoryPureNode()
    local nt = self.registry:GetNodeType("inventory.item_count")
    luaunit.assertEquals(nt.displayName, "Item Count")
    luaunit.assertEquals(nt.category, "inventory")
    luaunit.assertNil(nt.modes)
    luaunit.assertEquals(nt.pins.snapshot.dataType, "invSnapshot")
    luaunit.assertEquals(nt.pins.snapshot.direction, "in")
    luaunit.assertEquals(nt.pins.nameMatch.dataType, "matcher")
    luaunit.assertEquals(nt.pins.noteFilter.dataType, "invNoteFilter")
    luaunit.assertEquals(nt.pins.noteFilter.default, "both")
    luaunit.assertEquals(nt.pins.count.dataType, "number")
    luaunit.assertEquals(nt.pins.count.direction, "out")
    for _, pin in pairs(nt.pins) do
        luaunit.assertNotEquals(pin.kind, "exec")
    end
end

function TestInventory:testEmptyMatcherCountsEveryNameAsStackSum()
    self:setInv(INV, {
        slots = {
            slot("Rune arrow", "RUNE_ARROW", 13254),
            slot("Shark", "SHARK", 2),
        },
        usedSlotCount = 2,
    })
    local triggerId = self:addWired()
    local countId = self:addItemCount(triggerId)
    self:pushUpdated(INV)
    luaunit.assertEquals(self:pullCount(countId), 13256)
end

function TestInventory:testCountIsStackQuantitiesNotUsedSlots()
    self:setInv(INV, {
        slots = { slot("Rune arrow", "RUNE_ARROW", 13254) },
        usedSlotCount = 1,
    })
    local triggerId = self:addWired()
    local countId = self:addItemCount(triggerId)
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(triggerId, "usedSlots"), 1)
    luaunit.assertEquals(self:pullCount(countId), 13254)
end

function TestInventory:testMatcherNeedleUsesDisplayName()
    self:setInv(INV, {
        slots = {
            slot("Rune arrow", "RUNE_ARROW", 10),
            slot("Shark", "SHARK", 3),
        },
        usedSlotCount = 2,
    })
    local triggerId = self:addWired()
    local countId = self:addItemCount(triggerId, "snapshot", { nameMatch = sub("rune arrow") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self:pullCount(countId), 10)
end

function TestInventory:testPatternMatcherAnchorsOnDisplayNameOnly()
    self:setInv(INV, {
        slots = {
            slot("Rune arrow", "CERT_RUNE_ARROW", 5),
            slot("Rune arrow (p)", "RUNE_ARROW_P", 2),
        },
        usedSlotCount = 2,
    })
    local triggerId = self:addWired()
    local countId = self:addItemCount(triggerId, "snapshot", { nameMatch = pat("^Rune arrow$") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self:pullCount(countId), 5)
end

function TestInventory:testNoteFilterAndMatcherOnSharedDisplayName()
    self:setInv(INV, {
        slots = {
            slot("Rune arrow", "RUNE_ARROW", 10),
            slot("Rune arrow", "CERT_RUNE_ARROW", 5),
            slot("Shark", "SHARK", 1),
        },
        usedSlotCount = 3,
    })
    local triggerId = self:addWired()
    self:pushUpdated(INV)

    local both = self:addItemCount(triggerId, "snapshot", {
        nameMatch = sub("rune arrow"),
    })
    luaunit.assertEquals(self:pullCount(both), 15)

    local noted = self:addItemCount(triggerId, "snapshot", {
        nameMatch = sub("rune arrow"),
        noteFilter = "noted",
    })
    luaunit.assertEquals(self:pullCount(noted), 5)

    local unnoted = self:addItemCount(triggerId, "snapshot", {
        nameMatch = sub("rune arrow"),
        noteFilter = "unnoted",
    })
    luaunit.assertEquals(self:pullCount(unnoted), 10)
end

function TestInventory:testDefaultNoteFilterIsBoth()
    self:setInv(INV, {
        slots = {
            slot("Rune arrow", "RUNE_ARROW", 10),
            slot("Rune arrow", "CERT_RUNE_ARROW", 5),
        },
        usedSlotCount = 2,
    })
    local triggerId = self:addWired()
    local countId = self:addItemCount(triggerId)
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetControl(countId, "noteFilter"), "both")
    luaunit.assertEquals(self:pullCount(countId), 15)
end

function TestInventory:testPrevSnapshotItemCountIsIndependent()
    self:setInv(INV, { slots = { slot("Rune arrow", "RUNE_ARROW", 10) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    self:pushUpdated(INV)
    self:setInv(INV, { slots = { slot("Rune arrow", "RUNE_ARROW", 13254) }, usedSlotCount = 1 })
    self:pushUpdated(INV)

    local prevCount = self:addItemCount(triggerId, "prevSnapshot")
    local curCount = self:addItemCount(triggerId, "snapshot")
    luaunit.assertEquals(self:pullCount(prevCount), 10)
    luaunit.assertEquals(self:pullCount(curCount), 13254)
end

--- Item Count Changed (#100) --------------------------------------------------------------

function TestInventory:testItemCountChangedIsInventoryCategoryPureNode()
    local nt = self.registry:GetNodeType("inventory.item_count_changed")
    luaunit.assertEquals(nt.displayName, "Item Count Changed")
    luaunit.assertEquals(nt.category, "inventory")
    luaunit.assertNil(nt.modes)
    luaunit.assertNil(nt.pins["in"])
    luaunit.assertNil(nt.pins.changed)
    luaunit.assertNil(nt.pins.unchanged)
    luaunit.assertEquals(nt.pinOrder, {
        "prevSnapshot", "snapshot", "nameMatch", "noteFilter",
        "count", "prevCount", "delta",
    })
    luaunit.assertEquals(nt.pins.snapshot.dataType, "invSnapshot")
    luaunit.assertEquals(nt.pins.snapshot.direction, "in")
    luaunit.assertEquals(nt.pins.prevSnapshot.dataType, "invSnapshot")
    luaunit.assertEquals(nt.pins.prevSnapshot.direction, "in")
    luaunit.assertEquals(nt.pins.nameMatch.dataType, "matcher")
    luaunit.assertEquals(nt.pins.noteFilter.dataType, "invNoteFilter")
    luaunit.assertEquals(nt.pins.noteFilter.default, "both")
    luaunit.assertEquals(nt.pins.count.dataType, "number")
    luaunit.assertEquals(nt.pins.count.direction, "out")
    luaunit.assertEquals(nt.pins.prevCount.dataType, "number")
    luaunit.assertEquals(nt.pins.prevCount.direction, "out")
    luaunit.assertEquals(nt.pins.delta.dataType, "number")
    luaunit.assertEquals(nt.pins.delta.direction, "out")
    luaunit.assertNotNil(nt.description)
    for _, pin in pairs(nt.pins) do
        luaunit.assertNotEquals(pin.kind, "exec")
    end
end

function TestInventory:testDragonMatcherIgnoresEggPickup()
    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 1) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)

    self:setInv(INV, {
        slots = { slot("Dragon", "DRAGON", 1), slot("Egg", "EGG", 1) },
        usedSlotCount = 2,
    })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 2)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 1)
    luaunit.assertEquals(got.prevCount, 1)
    luaunit.assertEquals(got.delta, 0)
end

function TestInventory:testDragonPickupHasPositiveDelta()
    self:setInv(INV, { slots = {}, usedSlotCount = 0 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self:readChanged(id).delta, 0)

    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 1) }, usedSlotCount = 1 })
    self:pushUpdated(INV)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 1)
    luaunit.assertEquals(got.prevCount, 0)
    luaunit.assertEquals(got.delta, 1)
end

function TestInventory:testDroppingLastMatchHasCountZero()
    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 1) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    self:pushUpdated(INV)

    self:setInv(INV, { slots = {}, usedSlotCount = 0 })
    self:pushUpdated(INV)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 0)
    luaunit.assertEquals(got.prevCount, 1)
    luaunit.assertEquals(got.delta, -1)
end

function TestInventory:testStackQuantityUpHasDeltaWithUsedSlotsUnchanged()
    self:setInv(INV, { slots = { slot("Rune arrow", "RUNE_ARROW", 13254) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Rune arrow") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(triggerId, "usedSlots"), 1)

    self:setInv(INV, { slots = { slot("Rune arrow", "RUNE_ARROW", 13255) }, usedSlotCount = 1 })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(triggerId, "usedSlots"), 1)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 13255)
    luaunit.assertEquals(got.delta, 1)
end

function TestInventory:testEmptyNeedleSameTotalSwapHasZeroDelta()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId)
    self:pushUpdated(INV)

    self:setInv(INV, { slots = { slot("Lobster", "LOBSTER", 1) }, usedSlotCount = 1 })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 2)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 1)
    luaunit.assertEquals(got.prevCount, 1)
    luaunit.assertEquals(got.delta, 0)
end

function TestInventory:testEmptyNeedlePickupHasPositiveDelta()
    self:setInv(INV, { slots = {}, usedSlotCount = 0 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId)
    self:pushUpdated(INV)
    luaunit.assertEquals(self:readChanged(id).delta, 0)

    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    self:pushUpdated(INV)
    luaunit.assertEquals(self:readChanged(id).delta, 1)
end

function TestInventory:testNoteFilterAndOnSharedNameCertFixture()
    self:setInv(INV, {
        slots = {
            slot("Dragon", "DRAGON", 10),
            slot("Dragon", "CERT_DRAGON", 5),
        },
        usedSlotCount = 2,
    })
    local triggerId = self:addWired()
    local both = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    local noted = self:addItemCountChanged(triggerId, {
        nameMatch = sub("Dragon"),
        noteFilter = "noted",
    })
    local unnoted = self:addItemCountChanged(triggerId, {
        nameMatch = sub("Dragon"),
        noteFilter = "unnoted",
    })
    self:pushUpdated(INV)

    self:setInv(INV, {
        slots = {
            slot("Dragon", "DRAGON", 10),
            slot("Dragon", "CERT_DRAGON", 6),
        },
        usedSlotCount = 2,
    })
    self:pushUpdated(INV)
    local bothGot = self:readChanged(both)
    luaunit.assertEquals(bothGot.count, 16)
    luaunit.assertEquals(bothGot.delta, 1)
    local notedGot = self:readChanged(noted)
    luaunit.assertEquals(notedGot.count, 6)
    luaunit.assertEquals(notedGot.delta, 1)
    local unnotedGot = self:readChanged(unnoted)
    luaunit.assertEquals(unnotedGot.count, 10)
    luaunit.assertEquals(unnotedGot.delta, 0)
end

function TestInventory:testColdStartNonZeroMatchHasPositiveDelta()
    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 2) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    self:pushUpdated(INV)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 2)
    luaunit.assertEquals(got.prevCount, 0)
    luaunit.assertEquals(got.delta, 2)
end

function TestInventory:testSecondPullSeesUnchangedMatchAsZeroDelta()
    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 3) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self:readChanged(id).delta, 3)

    self:setInv(INV, {
        slots = { slot("Dragon", "DRAGON", 3), slot("Egg", "EGG", 1) },
        usedSlotCount = 2,
    })
    self:pushUpdated(INV)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 3)
    luaunit.assertEquals(got.prevCount, 3)
    luaunit.assertEquals(got.delta, 0)
end

function TestInventory:testMissingSnapshotsCountAsZero()
    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 1) }, usedSlotCount = 1 })
    self:addWired()
    local id = self.graph:AddNode("inventory.item_count_changed")
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 0)
    luaunit.assertEquals(got.prevCount, 0)
    luaunit.assertEquals(got.delta, 0)
end

function TestInventory:testChangedUsesTriggerPrevThroughDistinctInvTypeProxies()
    local mt = {
        __eq = function(a, b)
            return a ~= nil and b ~= nil and a.id == b.id
        end,
    }
    local function proxy()
        return setmetatable({ id = INV.id, size = 28 }, mt)
    end

    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 1) }, usedSlotCount = 1 })
    local triggerId = self:addWired({ container = proxy() })
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    self:pushUpdated(proxy())

    self:setInv(INV, {
        slots = { slot("Dragon", "DRAGON", 1), slot("Egg", "EGG", 1) },
        usedSlotCount = 2,
    })
    self:pushUpdated(proxy())
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 1)
    luaunit.assertEquals(got.prevCount, 1)
    luaunit.assertEquals(got.delta, 0)
end

function TestInventory:testBankSnapshotsDriveItemCountChanged()
    self:setInv(BANK, { slots = { slot("Dragon", "DRAGON", 1) }, usedSlotCount = 1, slotCount = 10 })
    local triggerId = self:addWired({ container = BANK })
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("Dragon") })
    self:pushUpdated(BANK, 10)
    local got = self:readChanged(id)
    luaunit.assertEquals(got.count, 1)
    luaunit.assertEquals(got.delta, 1)
end

function TestInventory:testPatternMatcherUsesDisplayNameOnly()
    self:setInv(INV, {
        slots = {
            slot("Dragon", "CERT_DRAGON", 1),
            slot("Dragon bones", "DRAGON_BONES", 2),
        },
        usedSlotCount = 2,
    })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = pat("^Dragon$") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self:readChanged(id).count, 1)
end

function TestInventory:testSubstringMatcherIsCaseInsensitive()
    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 4) }, usedSlotCount = 1 })
    local triggerId = self:addWired()
    local id = self:addItemCountChanged(triggerId, { nameMatch = sub("dragon") })
    self:pushUpdated(INV)
    luaunit.assertEquals(self:readChanged(id).count, 4)
end

function TestInventory:testTwoChangedNodesWatchInventoryAndBank()
    self:setInv(INV, { slots = { slot("Dragon", "DRAGON", 1) }, usedSlotCount = 1 })
    self:setInv(BANK, { slots = { slot("Shark", "SHARK", 2) }, usedSlotCount = 1, slotCount = 10 })
    local invTrigger = self:addWired()
    local bankTrigger = self:addWired({ container = BANK })
    local invChanged = self:addItemCountChanged(invTrigger, { nameMatch = sub("Dragon") })
    local bankChanged = self:addItemCountChanged(bankTrigger, { nameMatch = sub("Shark") })
    self:pushUpdated(INV)
    self:pushUpdated(BANK, 10)
    luaunit.assertEquals(self:readChanged(invChanged).count, 1)
    luaunit.assertEquals(self:readChanged(bankChanged).count, 2)
end

function TestInventory:testItemCountSumsASlotAfterAHole()
    local slots = {}
    slots[28] = slot("Shark", "SHARK", 3)
    self:setInv(INV, { slots = slots, usedSlotCount = 1, slotCount = 28 })
    local triggerId = self:addWired()
    local countId = self:addItemCount(triggerId)
    self:pushUpdated(INV)
    luaunit.assertEquals(self:pullCount(countId), 3)
end

function TestInventory:testViewerIsInventoryCategoryAction()
    local nt = self.registry:GetNodeType("inventory.viewer")
    luaunit.assertEquals(nt.displayName, "Inventory Viewer")
    luaunit.assertEquals(nt.category, "inventory")
    luaunit.assertEquals(nt.pins["in"].kind, "exec")
    luaunit.assertEquals(nt.pins["in"].direction, "in")
    luaunit.assertNil(nt.pins.out)
    luaunit.assertEquals(nt.pins.snapshot.dataType, "invSnapshot")
end

function TestInventory:testViewerLatchesSnapshotInNodeState()
    local slots = {}
    slots[2] = slot("Shark", "SHARK", 1, 99)
    self:setInv(INV, { slots = slots, usedSlotCount = 1, slotCount = 28 })
    local triggerId = self:addWired()
    local viewerId = self.graph:AddNode("inventory.viewer")
    luaunit.assertNotNil(self.graph:Connect(triggerId, "out", viewerId, "in"))
    luaunit.assertNotNil(self.graph:Connect(triggerId, "snapshot", viewerId, "snapshot"))
    self:pushUpdated(INV)
    local state = self.graph:GetState(viewerId)
    luaunit.assertEquals(state.snapshot.slots[2].name, "Shark")
    luaunit.assertEquals(state.snapshot.slots[2].objId, 99)
    luaunit.assertNil(state.snapshot.slots[1])
end

return TestInventory
