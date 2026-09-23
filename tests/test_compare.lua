local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local StandardCompare = require("compare")
local Controls = require("ui/controls")
local FakeHost = require("fake_control_host")
local Palette = require("ui/palette")

TestCompare = {}

function TestCompare:setUp()
    self.registry = Registry.new()
    StandardCompare.Register(self.registry)
    require("boolean").Register(self.registry)
    self.graph = Graph.new(self.registry)
end

function TestCompare:testDropdownChangesExecutionAndRoundTrips()
    local id = self.graph:AddNode("std.compare", { a = 3, b = 2 })
    local control = Controls.PinControlFor("compareOperation")
    for _, choice in ipairs({
        { "==", "Equals (==)" }, { "!=", "Not Equals (!=)" },
        { ">", "Greater Than (<gt>)" }, { "<", "Less Than (<lt>)" },
        { ">=", "Greater or Equal (<gt>=)" }, { "<=", "Less or Equal (<lt>=)" },
    }) do
        local operation, label = choice[1], choice[2]
        local host = FakeHost.new(self.graph:GetControl(id, "operation"))
        control.Press(host, { value = host.stored, pinName = "operation" })
        luaunit.assertItemsEquals(host.mounted.opts.labels, {
            "Equals (==)", "Not Equals (!=)", "Greater Than (<gt>)",
            "Less Than (<lt>)", "Greater or Equal (<gt>=)", "Less or Equal (<lt>=)",
        })
        host:Pick(label)
        luaunit.assertEquals(host.commitCount, 1)
        self.graph:SetControl(id, "operation", host.committed)
        self.graph = Serialize.Deserialize(Serialize.Serialize(self.graph), self.registry)
        luaunit.assertEquals(self.graph:GetControl(id, "operation"), operation)
        luaunit.assertEquals(control.Display({ value = host.committed }), label)
        self.graph:Fire(id)
        luaunit.assertEquals(self.graph:GetLastValue(id, "result"),
            operation == "!=" or operation == ">" or operation == ">=")
    end
end

function TestCompare:testOperationUsesFullWidthBand()
    local Node = require("ui/node")
    local id = self.graph:AddNode("std.compare")
    local geom = Node.BuildGeometry(self.graph:GetPins(id), 0, 0)
    local operation = geom.controls[1]
    luaunit.assertEquals(operation.pinName, "operation")
    luaunit.assertEquals(operation.w, geom.w - require("ui/theme").PIN_MARGIN_X * 2)
    luaunit.assertTrue(operation.y > geom.byName.operation.cy)
    luaunit.assertTrue(operation.y + operation.h < geom.byName.a.cy)
end

function TestCompare:testComparisonsAndBooleanOperatorsShareLogicGroup()
    for _, key in ipairs({ "std.compare", "std.and", "std.or", "std.not", "std.xor" }) do
        luaunit.assertEquals(self.registry:GetNodeType(key).category, "boolean")
    end
    local palette = Palette.new()
    palette:Open(self.registry, nil, { screenX = 0, screenY = 0, anchorGX = 0, anchorGY = 0 })
    local comparisonKeys = {}
    for _, row in ipairs(palette.rows) do
        luaunit.assertNotEquals(row.category, "compare")
        luaunit.assertNotEquals(row.category, "logic")
        if row.header and row.category == "boolean" then
            luaunit.assertEquals(row.label, "Logic")
        end
        if not row.header and row.category == "boolean" then
            comparisonKeys[#comparisonKeys + 1] = row.typeKey
        end
    end
    luaunit.assertItemsEquals(comparisonKeys, { "std.compare", "std.and", "std.or", "std.not", "std.xor" })
end

return {}
