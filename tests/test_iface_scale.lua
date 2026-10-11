-- InterfaceScale.setting is percent (100 = 1.0x).

local luaunit = require("luaunit")
local IfaceScale = require("ui/iface_scale")

TestIfaceScale = {}

function TestIfaceScale:setUp()
    -- Isolate from any ambient game table left by other suites.
    self._prevGame = rawget(_G, "game")
end

function TestIfaceScale:tearDown()
    rawset(_G, "game", self._prevGame)
end

local function setScale(percent)
    rawset(_G, "game", {
        options = {
            InterfaceScale = { setting = percent },
        },
    })
end

function TestIfaceScale:testFactorAt100()
    setScale(100)
    luaunit.assertEquals(IfaceScale.Factor(), 1)
end

function TestIfaceScale:testFactorAt150()
    setScale(150)
    luaunit.assertAlmostEquals(IfaceScale.Factor(), 1.5, 1e-9)
end

function TestIfaceScale:testFactorAt200()
    setScale(200)
    luaunit.assertEquals(IfaceScale.Factor(), 2)
end

function TestIfaceScale:testToInterfaceHalvesAt200()
    setScale(200)
    local x, y = IfaceScale.ToInterface(400, 300)
    luaunit.assertEquals(x, 200)
    luaunit.assertEquals(y, 150)
end

function TestIfaceScale:testToInterfaceAt150()
    setScale(150)
    local x, y = IfaceScale.ToInterface(300, 150)
    luaunit.assertAlmostEquals(x, 200, 1e-9)
    luaunit.assertAlmostEquals(y, 100, 1e-9)
end

function TestIfaceScale:testMissingGameDefaultsToOne()
    rawset(_G, "game", nil)
    luaunit.assertEquals(IfaceScale.Factor(), 1)
    local x, y = IfaceScale.ToInterface(10, 20)
    luaunit.assertEquals(x, 10)
    luaunit.assertEquals(y, 20)
end

function TestIfaceScale:testInvalidSettingDefaultsToOne()
    setScale(0)
    luaunit.assertEquals(IfaceScale.Factor(), 1)
    setScale(-50)
    luaunit.assertEquals(IfaceScale.Factor(), 1)
end

return TestIfaceScale
