-- Player Input (#167).
-- Seam: a live graph plus the runtime's event source and cursor. Assert the stored
-- checks and whether the exec output pulsed. Subscription names and widget rects
-- are not part of this contract.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
local PlayerInput = require("src/nodes/triggers/player_input")
local Presets = require("src/presets")
require("src/ui/controls")

TestPlayerInput = {}

local function newFakeMouse(x, y)
    local mouse = { available = true, pos = { x = x, y = y } }
    function mouse.IsAvailable() return mouse.available end
    function mouse.GetPosition() return mouse.pos end
    return mouse
end

function TestPlayerInput:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.mouse = newFakeMouse(0, 0)
    self.runtime = Runtime.new(self.source.source, self.mouse)
    PlayerInput.Register(self.registry, self.runtime)
    self.graph = Graph.new(self.registry)
end

function TestPlayerInput:testNewNodeChecksStartOnAndStayAfterSave()
    local id = self.graph:AddNode("trigger.player_input")
    local nodeType = self.registry:GetNodeType("trigger.player_input")
    luaunit.assertEquals(nodeType.displayName, "Player Input")
    luaunit.assertEquals(nodeType.pinOrder, { "mouseMove", "keyboard", "mouseClick", "out" })
    luaunit.assertEquals(nodeType.pins.mouseMove.label, "Mouse move")
    luaunit.assertEquals(nodeType.pins.keyboard.label, "Keyboard")
    luaunit.assertEquals(nodeType.pins.mouseClick.label, "Mouse click")

    luaunit.assertEquals(self.graph:GetControl(id, "mouseMove"), true)
    luaunit.assertEquals(self.graph:GetControl(id, "keyboard"), true)
    luaunit.assertEquals(self.graph:GetControl(id, "mouseClick"), true)

    self.graph:SetControl(id, "keyboard", false)
    local restored = Serialize.Deserialize(Serialize.Serialize(self.graph), self.registry)
    luaunit.assertEquals(restored:GetControl(id, "mouseMove"), true)
    luaunit.assertEquals(restored:GetControl(id, "keyboard"), false)
    luaunit.assertEquals(restored:GetControl(id, "mouseClick"), true)
end

function TestPlayerInput:testAddNodeKeepsAnExplicitOffCheck()
    local id = self.graph:AddNode("trigger.player_input", {
        mouseMove = false,
        keyboard = true,
        mouseClick = false,
    })
    luaunit.assertEquals(self.graph:GetControl(id, "mouseMove"), false)
    luaunit.assertEquals(self.graph:GetControl(id, "keyboard"), true)
    luaunit.assertEquals(self.graph:GetControl(id, "mouseClick"), false)
end

function TestPlayerInput:testChecksArePinsAndPresetVariables()
    local id = self.graph:AddNode("trigger.player_input")
    local names = {}
    for _, pin in ipairs(self.graph:GetPins(id)) do
        names[#names + 1] = pin.name
    end
    luaunit.assertEquals(names, { "mouseMove", "keyboard", "mouseClick", "out" })

    luaunit.assertEquals(Presets.Eligible(self.graph), {
        { nodeId = id, pinName = "mouseMove" },
        { nodeId = id, pinName = "keyboard" },
        { nodeId = id, pinName = "mouseClick" },
    })

    self.registry:RegisterNodeType("fixture.flag", {
        category = "pure",
        pins = {
            { name = "value", kind = "data", direction = "out", dataType = "bool" },
        },
        run = function() end,
    })
    local source = self.graph:AddNode("fixture.flag")
    local conn, reason = self.graph:Connect(source, "value", id, "keyboard")
    luaunit.assertNotNil(conn)
    luaunit.assertNil(reason)
    luaunit.assertEquals(Presets.Eligible(self.graph), {
        { nodeId = id, pinName = "mouseMove" },
        { nodeId = id, pinName = "mouseClick" },
    })
end

function TestPlayerInput:listen()
    self.seen = {}
    local seen = self.seen
    self.registry:RegisterNodeType("fixture.sink", {
        category = "action",
        pins = { { name = "dismiss", kind = "exec", direction = "in" } },
        run = function(ctx)
            seen[#seen + 1] = { exec = ctx.exec, payload = ctx.payload }
        end,
    })
    self.inputId = self.graph:AddNode("trigger.player_input")
    self.sinkId = self.graph:AddNode("fixture.sink")
    luaunit.assertNotNil(self.graph:Connect(self.inputId, "out", self.sinkId, "dismiss"))
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert(1, "Input", self.graph, true)
end

function TestPlayerInput:testKeyboardPulsesOnEachKeyDownAndNotWhenOff()
    self:listen()
    self.source:Push("KeyDown", { gameKey = "A", isRepeat = false })
    self.source:Push("KeyDown", { gameKey = "B", isRepeat = true })
    luaunit.assertEquals(self.seen, {
        { exec = "dismiss", payload = nil },
        { exec = "dismiss", payload = nil },
    })

    self.graph:SetControl(self.inputId, "keyboard", false)
    self.source:Push("KeyDown", { gameKey = "C" })
    luaunit.assertEquals(#self.seen, 2)
end

function TestPlayerInput:testMouseMovePulsesOnlyAfterTheCursorActuallyMoves()
    self:listen()
    self.runtime:Update()
    luaunit.assertEquals(self.seen, {})

    self.mouse.pos = { x = 3, y = 1 }
    self.runtime:Update()
    luaunit.assertEquals(#self.seen, 1)
    luaunit.assertNil(self.seen[1].payload)

    self.runtime:Update()
    luaunit.assertEquals(#self.seen, 1)

    self.graph:SetControl(self.inputId, "mouseMove", false)
    self.mouse.pos = { x = 9, y = 1 }
    self.runtime:Update()
    luaunit.assertEquals(#self.seen, 1)
end

function TestPlayerInput:testUnavailableCursorDoesNotPulse()
    self:listen()
    self.mouse.available = false
    self.runtime:Update()
    self.mouse.pos = { x = 8, y = 8 }
    self.runtime:Update()
    luaunit.assertEquals(self.seen, {})

    self.mouse.available = true
    self.runtime:Update()
    luaunit.assertEquals(self.seen, {})
    self.mouse.pos = { x = 8, y = 9 }
    self.runtime:Update()
    luaunit.assertEquals(#self.seen, 1)
end

function TestPlayerInput:testMouseClickPulsesOncePerMenuEvent()
    self:listen()
    self.source:Push("MiniMenuOpened", {})
    luaunit.assertEquals(#self.seen, 1)
    self.source:Push("MiniMenuEntrySelected", { entry = "Cancel" })
    luaunit.assertEquals(#self.seen, 2)
    self.source:Push("MiniMenuClosed", {})
    luaunit.assertEquals(#self.seen, 3)
    luaunit.assertNil(self.seen[1].payload)
    luaunit.assertNil(self.seen[2].payload)
    luaunit.assertNil(self.seen[3].payload)

    self.graph:SetControl(self.inputId, "mouseClick", false)
    self.source:Push("MiniMenuOpened", {})
    self.source:Push("MiniMenuEntrySelected", { entry = "Walk here" })
    self.source:Push("MiniMenuClosed", {})
    luaunit.assertEquals(#self.seen, 3)
end

function TestPlayerInput:testAllChecksOffDoesNotPulse()
    self:listen()
    self.graph:SetControl(self.inputId, "mouseMove", false)
    self.graph:SetControl(self.inputId, "keyboard", false)
    self.graph:SetControl(self.inputId, "mouseClick", false)

    self.runtime:Update()
    self.mouse.pos = { x = 2, y = 2 }
    self.runtime:Update()
    self.source:Push("KeyDown", { gameKey = "A" })
    self.source:Push("MiniMenuOpened", {})
    self.source:Push("MiniMenuEntrySelected", { entry = "Cancel" })
    self.source:Push("MiniMenuClosed", {})
    luaunit.assertEquals(self.seen, {})
end

function TestPlayerInput:testEachNodeUsesItsOwnChecks()
    self:listen()
    local other = self.graph:AddNode("trigger.player_input")
    self.graph:SetControl(other, "keyboard", false)
    luaunit.assertNotNil(self.graph:Connect(other, "out", self.sinkId, "dismiss"))
    self.source:Push("KeyDown", { gameKey = "A" })
    luaunit.assertEquals(#self.seen, 1)
end

function TestPlayerInput:testAlertThatCannotFireDoesNotPulse()
    self:listen()
    self.runtime:SetAlertEnabled(1, false)
    self.source:Push("KeyDown", { gameKey = "A" })
    luaunit.assertEquals(self.seen, {})

    self.runtime:SetAlertEnabled(1, true)
    self.runtime:SetEnabledResolver(function() return false end)
    self.source:Push("KeyDown", { gameKey = "A" })
    luaunit.assertEquals(self.seen, {})

    self.runtime:SetEnabledResolver(nil)
    self.runtime:RemoveAlert(1)
    self.runtime:AddAlert(2, "Away", self.graph, true, "player_absent")
    self.source:Push("KeyDown", { gameKey = "A" })
    luaunit.assertEquals(self.seen, {})
end

function TestPlayerInput:testExecOutputWiresToAnExistingDismissPin()
    require("src/nodes/actions/screen_flash").Register(self.registry, self.runtime)
    local input = self.graph:AddNode("trigger.player_input")
    local flash = self.graph:AddNode("action.screen_flash")
    local conn, reason = self.graph:Connect(input, "out", flash, "dismiss")
    luaunit.assertNotNil(conn)
    luaunit.assertNil(reason)

    local dataPins = {}
    for _, pin in ipairs(self.graph:GetPins(input)) do
        if pin.kind == "data" then
            dataPins[#dataPins + 1] = pin.name
        end
    end
    luaunit.assertEquals(dataPins, { "mouseMove", "keyboard", "mouseClick" })
end

function TestPlayerInput:testPaletteOffersPlayerInput()
    local Palette = require("src/ui/palette")
    local palette = Palette.new()
    palette:Open(self.registry, nil, { screenX = 0, screenY = 0, anchorGX = 0, anchorGY = 0 })
    ---@type { displayName: string|nil, typeKey: string|nil, unavailable: boolean|nil }|nil
    local found = nil
    for _, row in ipairs(palette.rows) do
        if row.displayName == "Player Input" then
            found = row
        end
    end
    luaunit.assertNotNil(found)
    luaunit.assertEquals(found.displayName, "Player Input")
    luaunit.assertEquals(found.typeKey, "trigger.player_input")
    luaunit.assertNil(found.unavailable)
end

function TestPlayerInput:testEditorShowsCheckboxesOnThePins()
    local Editor = require("src/ui/graph")
    local id = self.graph:AddNode("trigger.player_input")
    local editor = setmetatable({
        graph = self.graph,
        registry = self.registry,
        layout = {},
        geoms = {},
        nodeOrder = {},
        view = { zoom = 1 },
    }, { __index = Editor })
    editor:buildGeoms()
    local geom = editor.geoms[id]
    luaunit.assertEquals(geom.byName.mouseMove.label, "Mouse move")
    luaunit.assertEquals(geom.byName.keyboard.label, "Keyboard")
    luaunit.assertEquals(geom.byName.mouseClick.label, "Mouse click")
    luaunit.assertEquals(geom.byName.mouseMove.kind, "data")

    local controls = {}
    for _, ctrl in ipairs(geom.controls) do
        controls[#controls + 1] = ctrl.pinName
    end
    luaunit.assertEquals(controls, { "mouseMove", "keyboard", "mouseClick" })
    luaunit.assertEquals(geom.controls[1].value, true)
    luaunit.assertEquals(geom.controls[2].value, true)
    luaunit.assertEquals(geom.controls[3].value, true)
end

function TestPlayerInput:testAWiredBoolDrivesTheCheck()
    self:listen()
    local value = false
    self.registry:RegisterNodeType("fixture.bool", {
        category = "pure",
        pins = {
            { name = "value", kind = "data", direction = "out", dataType = "bool" },
        },
        run = function(ctx) ctx:Out("value", value) end,
    })
    local source = self.graph:AddNode("fixture.bool")
    luaunit.assertNotNil(self.graph:Connect(source, "value", self.inputId, "keyboard"))
    self.graph:SetControl(self.inputId, "keyboard", false)
    self.source:Push("KeyDown", { gameKey = "A" })
    luaunit.assertEquals(self.seen, {})

    value = true
    self.source:Push("KeyDown", { gameKey = "B" })
    luaunit.assertEquals(#self.seen, 1)
end
