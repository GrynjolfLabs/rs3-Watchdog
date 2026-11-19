-- Idle trigger: Logic ticks, KeyDown, MiniMenu events and a fake Mouse via the fake event source.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
local Idle = require("src/nodes/triggers/idle")

TestIdle = {}

function TestIdle:setUp()
    self.savedPlayer = _G.Player
    Player = { IsAvailable = function() return self.loggedIn end }
    self.loggedIn = true
    self.mouse = { pos = { x = 0, y = 0 } }
    self.mouse.IsAvailable = function() return true end
    self.mouse.GetPosition = function() return self.mouse.pos end

    local registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source, self.mouse)
    self.graph = Graph.new(registry)
    self.runtime:SetGraph(self.graph)
    Idle.Register(registry, self.runtime)

    self.fired = {}
    local idle = self.graph:AddNode("trigger.idle", { seconds = 2 })
    for _, pin in ipairs({ "Idle", "Active" }) do
        registry:RegisterNodeType("fixture." .. pin, {
            category = "action",
            pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
            run = function() table.insert(self.fired, pin) end,
        })
        self.graph:Connect(idle, pin, self.graph:AddNode("fixture." .. pin), "in")
    end
end

function TestIdle:tearDown()
    Player = self.savedPlayer
end

-- main.lua polls the mouse on Logic, then the dispatcher sees the same tick.
function TestIdle:seconds(s)
    for _ = 1, s * 50 do
        self.runtime:Update()
        self.source:Push("Logic", {})
    end
end

function TestIdle:testFiresIdleOnceThenActiveOnInput()
    self:seconds(1.98)
    luaunit.assertEquals(self.fired, {})
    self:seconds(5)
    luaunit.assertEquals(self.fired, { "Idle" })
    self.source:Push("KeyDown", { isRepeat = false })
    self:seconds(0.02)
    luaunit.assertEquals(self.fired, { "Idle", "Active" })
end

function TestIdle:testClicksAndMouseMovesCountButHeldKeysDoNot()
    local heldKey = setmetatable({}, { __index = { isRepeat = true } }) -- client payloads are userdata
    for _, input in ipairs({
        function() self.source:Push("KeyDown", heldKey) end,
        function() self.source:Push("MiniMenuEntrySelected", {}) end,
        function() self.mouse.pos = { x = self.mouse.pos.x + 1, y = 0 } end,
    }) do
        self:seconds(1.5)
        input()
    end
    self:seconds(1.5)
    -- The held key at 1.5s did not stop Idle at 2s. The click at 3s and the move at 4.5s did reset it.
    luaunit.assertEquals(self.fired, { "Idle", "Active" })
end

function TestIdle:testNeverFiresWhileLoggedOut()
    self.loggedIn = false
    self:seconds(5)
    self.loggedIn = true
    self:seconds(1.5)
    luaunit.assertEquals(self.fired, {})
end
