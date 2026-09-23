local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local StandardCompare = require("compare")
local Compare = require("nodes/compare")
local Controls = require("ui/controls")
local FakeHost = require("fake_control_host")
local Palette = require("ui/palette")

TestCompare = {}

function TestCompare:setUp()
    self.registry = Registry.new()
    StandardCompare.Register(self.registry)
    Compare.Register(self.registry)
    self.graph = Graph.new(self.registry)
end

function TestCompare:result(operation, a, b)
    local node = self.graph:AddNode("std.compare", { operation = operation, a = a, b = b })
    self.graph:Fire(node)
    return self.graph:GetLastValue(node, "result")
end

function TestCompare:testAllOperationsTrueAndFalse()
    for _, case in ipairs({
        { "==", 2, 2, true }, { "==", 2, 3, false },
        { "!=", 2, 3, true }, { "!=", 2, 2, false },
        { ">", 3, 2, true }, { ">", 2, 2, false },
        { "<", 2, 3, true }, { "<", 2, 2, false },
        { ">=", 2, 2, true }, { ">=", 2, 3, false },
        { "<=", 2, 2, true }, { "<=", 3, 2, false },
    }) do
        luaunit.assertEquals(self:result(case[1], case[2], case[3]), case[4])
    end
end

function TestCompare:testNativeSemanticsAndDefaultEquality()
    luaunit.assertTrue(self:result(nil, "hello", "hello"))
    luaunit.assertTrue(self:result("==", nil, nil))
    luaunit.assertTrue(self:result("!=", true, false))
    luaunit.assertFalse(self:result("==", "2", 2))
    luaunit.assertTrue(self:result("<", "a", "b"))
    luaunit.assertError(function() self:result(">", "2", 1) end)
    luaunit.assertError(function() self:result("<", nil, 1) end)
end

function TestCompare:testDropdownChangesExecutionAndRoundTrips()
    local id = self.graph:AddNode("std.compare", { a = 3, b = 2 })
    local control = Controls.PinControlFor("compareOperation")
    for _, operation in ipairs({ "==", "!=", ">", "<", ">=", "<=" }) do
        local host = FakeHost.new(self.graph:GetControl(id, "operation"))
        control.Press(host, { value = host.stored, pinName = "operation" })
        host:Pick(operation)
        luaunit.assertEquals(host.commitCount, 1)
        self.graph:SetControl(id, "operation", host.committed)
        self.graph = Serialize.Deserialize(Serialize.Serialize(self.graph), self.registry)
        luaunit.assertEquals(self.graph:GetControl(id, "operation"), operation)
        luaunit.assertEquals(control.Display({ value = host.committed }), operation)
        self.graph:Fire(id)
        luaunit.assertEquals(self.graph:GetLastValue(id, "result"),
            operation == "!=" or operation == ">" or operation == ">=")
    end
end

function TestCompare:testLegacyGraphsRetainDefaultsConnectionsAndBehavior()
    -- Save using the unmodified dependency, then load with the new registration.
    local oldRegistry = Registry.new()
    StandardCompare.Register(oldRegistry)
    local oldGraph = Graph.new(oldRegistry)
    for _, key in ipairs({ "std.equals", "std.notequals", "std.greaterthan",
        "std.lessthan", "std.greaterorequal", "std.lessorequal" }) do
        oldGraph:AddNode(key)
    end
    local source = oldGraph:AddNode("std.greaterthan", { a = 3, b = 2 })
    local target = oldGraph:AddNode("std.equals", { b = true })
    oldGraph:Connect(source, "result", target, "a")
    local saved = Serialize.Serialize(oldGraph)
    local restored = Serialize.Deserialize(saved, self.registry)
    luaunit.assertEquals(Serialize.Serialize(restored), saved)
    for id in pairs(oldGraph.nodes) do
        oldGraph:Fire(id)
        restored:Fire(id)
        luaunit.assertEquals(restored:GetLastValue(id, "result"), oldGraph:GetLastValue(id, "result"))
    end
    luaunit.assertTrue(restored:GetLastValue(target, "result"))
end

function TestCompare:testChangingOperationPreservesWiredInputs()
    local source = self.graph:AddNode("std.greaterthan", { a = 3, b = 2 })
    local target = self.graph:AddNode("std.compare", { b = true })
    self.graph:Connect(source, "result", target, "a")
    local connections = Serialize.Serialize(self.graph).connections
    self.graph:Fire(target)
    luaunit.assertTrue(self.graph:GetLastValue(target, "result"))
    self.graph:SetControl(target, "operation", "!=")
    self.graph = Serialize.Deserialize(Serialize.Serialize(self.graph), self.registry)
    luaunit.assertEquals(Serialize.Serialize(self.graph).connections, connections)
    self.graph:Fire(target)
    luaunit.assertFalse(self.graph:GetLastValue(target, "result"))
end

function TestCompare:testOnlyCompareAppearsInPalette()
    local palette = Palette.new()
    palette:Open(self.registry, nil, { screenX = 0, screenY = 0, anchorGX = 0, anchorGY = 0 })
    local comparisonKeys = {}
    for _, row in ipairs(palette.rows) do
        if not row.header and row.category == "compare" then
            comparisonKeys[#comparisonKeys + 1] = row.typeKey
        end
    end
    luaunit.assertEquals(comparisonKeys, { "std.compare" })
end

return {}
