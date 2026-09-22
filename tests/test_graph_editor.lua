-- Editor:linkPins (ui/graph.lua) - connection-commit shared by Wire drops and Palette auto-connect.
-- The full Editor is Canvas/immediate-mode and not unit-testable here; linkPins only touches
-- self.graph and self:connectionInto, so we drive it via a metatable-backed fake `self`.
--
-- Client/UI globals the module builds colors/fonts from at load time - stubbed so ui/graph loads
-- under a standalone interpreter.
_G.Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }
_G.id = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
_G.config = { Font = setmetatable({}, { __index = function()
    return { GetStringWidth = function(_, t) return #t * 7 end }
end }) }

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Editor = require("ui/graph")
local View = require("ui/view")

TestGraphEditor = {}

function TestGraphEditor:setUp()
    self.registry = Registry.new()

    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    self.registry:RegisterNodeType("fixture.action", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "value", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.number", {
        category = "pure",
        pins = { { name = "out", kind = "data", direction = "out", dataType = "number" } },
        run = function(ctx) ctx:Out("out", 0) end,
    })

    self.graph = Graph.new(self.registry)
    -- Fake Editor: linkPins resolves methods against Editor; the only state it reads is self.graph.
    self.editor = setmetatable({ graph = self.graph }, { __index = Editor })
end

-- #3: re-committing the identical exec wire removes it (toggle off), rather than stacking a
-- duplicate the engine now refuses.
function TestGraphEditor:testDuplicateExecWireTogglesOff()
    local trig = self.graph:AddNode("fixture.trigger")
    local act = self.graph:AddNode("fixture.action")

    self.editor:linkPins(trig, "out", act, "in", false)
    luaunit.assertEquals(#self.graph:GetConnections(), 1)

    self.editor:linkPins(trig, "out", act, "in", false)
    luaunit.assertEquals(#self.graph:GetConnections(), 0)
end

-- #3 applies uniformly: re-committing the identical DATA wire also toggles off (it is not the
-- old invisible replace - the wire disappears).
function TestGraphEditor:testDuplicateDataWireTogglesOff()
    local num = self.graph:AddNode("fixture.number")
    local act = self.graph:AddNode("fixture.action")

    self.editor:linkPins(num, "out", act, "value", true)
    luaunit.assertEquals(#self.graph:GetConnections(), 1)

    self.editor:linkPins(num, "out", act, "value", true)
    luaunit.assertEquals(#self.graph:GetConnections(), 0)
end

-- A DIFFERENT source into an occupied data input still replaces (single data connection),
-- distinct from the toggle above.
function TestGraphEditor:testDifferentSourceReplacesDataInput()
    local num1 = self.graph:AddNode("fixture.number")
    local num2 = self.graph:AddNode("fixture.number")
    local act = self.graph:AddNode("fixture.action")

    self.editor:linkPins(num1, "out", act, "value", true)
    self.editor:linkPins(num2, "out", act, "value", true)

    local conns = self.graph:GetConnections()
    luaunit.assertEquals(#conns, 1)
    luaunit.assertEquals(conns[1].fromNode, num2)
end

-- An exec output may fan out to distinct inputs; only exact duplicates toggle.
function TestGraphEditor:testFanOutIsNotTreatedAsDuplicate()
    local trig = self.graph:AddNode("fixture.trigger")
    local act1 = self.graph:AddNode("fixture.action")
    local act2 = self.graph:AddNode("fixture.action")

    self.editor:linkPins(trig, "out", act1, "in", false)
    self.editor:linkPins(trig, "out", act2, "in", false)
    luaunit.assertEquals(#self.graph:GetConnections(), 2)
end

--- Unbound construction + BindEntry (#80) -------------------------------------------------
-- Editor.new(registry, runtime) constructs the surface with NO graph; the Manager binds one on
-- open. These drive the real (unmounted) Editor - construction touches no ui.* - so BindEntry's
-- reset behavior is assertable headless.

function TestGraphEditor:testConstructedUnbound()
    local editor = Editor.new(self.registry, nil)
    luaunit.assertNil(editor.graph)
    luaunit.assertNil(editor.boundId)
end

function TestGraphEditor:testBindEntryBindsGraphAndResetsView()
    local editor = Editor.new(self.registry, nil)
    -- Dirty the transient view/selection state a previous binding would have left behind.
    editor.view.panX, editor.view.panY, editor.view.zoom = 123, 45, 2.5
    editor.selected = 999
    editor.nodeOrder = { 1, 2, 3 }

    local layout = { [1] = { x = 5, y = 6 } }
    editor:BindEntry(7, self.graph, layout)

    luaunit.assertEquals(editor.boundId, 7) -- keyed on id, never name (#75)
    luaunit.assertIs(editor.graph, self.graph)
    luaunit.assertIs(editor:GetLayout(), layout)
    luaunit.assertEquals(editor.view.panX, 0)
    luaunit.assertEquals(editor.view.panY, 84)
    luaunit.assertEquals(editor.view.zoom, 1.0)
    luaunit.assertNil(editor.selected)
    luaunit.assertEquals(editor.nodeOrder, {})
end

function TestGraphEditor:testBindEntryDefaultsLayoutToEmpty()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(3, self.graph, nil)
    luaunit.assertEquals(editor:GetLayout(), {})
end

function TestGraphEditor:testUnbindClearsBinding()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(7, self.graph, { [1] = { x = 1, y = 2 } })
    editor:Unbind()
    luaunit.assertNil(editor.boundId)
    luaunit.assertNil(editor.graph)
    luaunit.assertEquals(editor:GetLayout(), {})
end

function TestGraphEditor:testGoBackInvokesOnBack()
    local editor = Editor.new(self.registry, nil)
    local calls = 0
    editor.onBack = function() calls = calls + 1 end
    editor:goBack()
    luaunit.assertEquals(calls, 1)
end

-- Hiding the editor must Hide() overlay-parented PrettyUI tooltips; ONMOUSELEAVE never
-- fires when the hovered Back button is hidden under the cursor.
function TestGraphEditor:testSetVisibleFalseHidesToolbarTooltips()
    local editor = Editor.new(self.registry, nil)
    local hideCount = 0
    local updateCount = 0
    editor.backButton = {
        root = { hidden = false },
        tooltip = { Hide = function() hideCount = hideCount + 1 end },
        hovered = true,
        pressed = true,
        _UpdateState = function() updateCount = updateCount + 1 end,
    }
    editor.plusButton = { root = { hidden = false } }
    editor.resetViewButton = { root = { hidden = false } }
    editor.visible = true
    editor:SetVisible(false)
    luaunit.assertTrue(editor.backButton.root.hidden)
    luaunit.assertTrue(editor.plusButton.root.hidden)
    luaunit.assertTrue(editor.resetViewButton.root.hidden)
    luaunit.assertEquals(hideCount, 1)
    luaunit.assertFalse(editor.backButton.hovered)
    luaunit.assertFalse(editor.backButton.pressed)
    luaunit.assertEquals(updateCount, 1)
end

function TestGraphEditor:testOnShellHideHidesToolbarTooltipsWithoutTuckingButtons()
    local editor = Editor.new(self.registry, nil)
    local hideCount = 0
    editor.backButton = {
        root = { hidden = false },
        tooltip = { Hide = function() hideCount = hideCount + 1 end },
        hovered = true,
        pressed = true,
        _UpdateState = function() end,
    }
    editor.visible = true
    editor:OnShellHide()
    luaunit.assertEquals(hideCount, 1)
    luaunit.assertFalse(editor.backButton.root.hidden)
    luaunit.assertFalse(editor.backButton.hovered)
    luaunit.assertTrue(editor.visible)
end

-- Visible Reset-view tooltip must MoveToFront after PLUS.
function TestGraphEditor:testFrontOverlayInteractivesRaisesResetViewTooltipAbovePlus()
    local editor = Editor.new(self.registry, nil)
    local order = {}
    local function tracked(name, hidden)
        return {
            hidden = hidden,
            MoveToFront = function() table.insert(order, name) end,
        }
    end
    editor.plusButton = { root = tracked("plus") }
    editor.resetViewButton = {
        root = tracked("reset"),
        tooltip = { root = tracked("reset-tip", false) },
    }
    editor:frontOverlayInteractives()
    luaunit.assertEquals(order, { "reset", "plus", "reset-tip" })
end

function TestGraphEditor:testFrontOverlayInteractivesSkipsHiddenToolbarTooltip()
    local editor = Editor.new(self.registry, nil)
    local order = {}
    local function tracked(name, hidden)
        return {
            hidden = hidden,
            MoveToFront = function() table.insert(order, name) end,
        }
    end
    editor.plusButton = { root = tracked("plus") }
    editor.resetViewButton = {
        root = tracked("reset"),
        tooltip = { root = tracked("reset-tip", true) },
    }
    editor:frontOverlayInteractives()
    luaunit.assertEquals(order, { "reset", "plus" })
end

-- The Esc cascade's final rung is nav-up: with no popup/capture active, Escape calls goBack.
function TestGraphEditor:testEscapeNavigatesUpWhenNothingElseActive()
    local editor = Editor.new(self.registry, nil)
    local back = 0
    editor.onBack = function() back = back + 1 end
    editor:onEscape()
    luaunit.assertEquals(back, 1)
end

--- #96: + button palette places the new Node at the Viewport center -------------------------
-- viewCenterGraph is the seam: Graph-space point under the Viewport's content-local center.
-- The + path stores that as palette.anchorGX/GY with centerOnAnchor, so placeFromPalette
-- offsets by half the Node Body and the Body's center lands on the Viewport center
-- (double-click / wire-drop keep origin-at-click anchors).

function TestGraphEditor:testViewCenterGraphAtDefaultFraming()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    local gx, gy = editor:viewCenterGraph()
    luaunit.assertEquals(gx, 200)
    luaunit.assertEquals(gy, 192)
end

function TestGraphEditor:testViewCenterGraphAccountsForPanAndZoom()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    editor.view.panX, editor.view.panY, editor.view.zoom = 40, -20, 2.0
    -- The 84px toolbar leaves the viewport center at (200, 192).
    local gx, gy = editor:viewCenterGraph()
    luaunit.assertEquals(gx, 80)
    luaunit.assertEquals(gy, 106)
end

function TestGraphEditor:testOpenPaletteFromPlusAnchorsAtViewCenter()
    local editor = Editor.new(self.registry, nil)
    editor.window.x, editor.window.y = 100, 200
    editor.window.w, editor.window.h = 400, 300
    editor.view.panX, editor.view.panY, editor.view.zoom = 40, -20, 2.0
    -- expandCapture touches capture/ui.*; stub so the open path stays headless.
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end

    editor:openPaletteFromPlus()

    luaunit.assertTrue(editor.palette.open)
    luaunit.assertEquals(editor.palette.anchorGX, 80)
    luaunit.assertEquals(editor.palette.anchorGY, 106)
    luaunit.assertTrue(editor.palette.centerOnAnchor)
    -- Palette opens below Add alert node in the second toolbar row.
    luaunit.assertEquals(editor.palette.screenX, 112)
    luaunit.assertEquals(editor.palette.screenY, 274)
end

--- Wheel lattice vs Palette scroll -------------------------------------------------------

function TestGraphEditor:testOnScrollWithPaletteOpenDoesNotChangeZoom()
    local editor = Editor.new(self.registry, nil)
    editor.view.zoom = 1.0
    editor.palette.open = true
    editor.palette.maxScroll = 20
    editor.palette.scroll = 0

    editor:onScroll(1)

    luaunit.assertEquals(editor.view.zoom, 1.0)
    luaunit.assertEquals(editor.palette.scroll, 3)
end

function TestGraphEditor:testOnScrollWithPaletteClosedStepsLattice()
    local editor = Editor.new(self.registry, nil)
    editor.mouse.x, editor.mouse.y = 100, 80
    editor.view.zoom = 1.0

    editor:onScroll(1)
    luaunit.assertAlmostEquals(editor.view.zoom, 1 / 1.1, 1e-12)

    editor:onScroll(-1)
    luaunit.assertAlmostEquals(editor.view.zoom, 1.0, 1e-12)
end

--- #103: slider index / Reset View (unmounted; no ui.Slider) -----------------------------

function TestGraphEditor:testApplyZoomIndexKeepsViewCenterGraphStable()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    editor.view.panX, editor.view.panY, editor.view.zoom = 40, -20, 1.0
    local gx, gy = editor:viewCenterGraph()
    local iMax = View.RungIndex(2.0)

    editor:applyZoomIndex(iMax)

    luaunit.assertEquals(editor.view.zoom, 2.0)
    local gx2, gy2 = editor:viewCenterGraph()
    luaunit.assertAlmostEquals(gx2, gx, 1e-12)
    luaunit.assertAlmostEquals(gy2, gy, 1e-12)
end

function TestGraphEditor:testOnResetViewZerosPanAndDefaultZoom()
    local editor = Editor.new(self.registry, nil)
    editor.view.panX, editor.view.panY, editor.view.zoom = 123, 45, 2.0
    editor:onResetView()
    luaunit.assertEquals(editor.view.panX, 0)
    luaunit.assertEquals(editor.view.panY, 84)
    luaunit.assertEquals(editor.view.zoom, 1.0)
    luaunit.assertEquals(View.Rungs()[View.RungIndex(editor.view.zoom)], 1.0)
end

function TestGraphEditor:testApplyZoomIndexClosesPaletteThenZooms()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    editor.palette.open = true
    editor.view.zoom = 1.0
    editor:applyZoomIndex(View.RungIndex(2.0))
    luaunit.assertFalse(editor.palette.open)
    luaunit.assertEquals(editor.view.zoom, 2.0)
end

function TestGraphEditor:testOnResetViewClosesPaletteThenResets()
    local editor = Editor.new(self.registry, nil)
    editor.palette.open = true
    editor.view.panX, editor.view.zoom = 50, 2.0
    editor:onResetView()
    luaunit.assertFalse(editor.palette.open)
    luaunit.assertEquals(editor.view.panX, 0)
    luaunit.assertEquals(editor.view.zoom, 1.0)
end

function TestGraphEditor:testApplyZoomIndexClosesControlEditorAndColorPopup()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    local closedEdit, closedColor = false, false
    editor.editing = { nodeId = 1, pinName = "x" }
    editor.closeControlEditor = function(self)
        closedEdit = true
        self.editing = nil
    end
    editor.colorPopup.open = true
    editor.closeColorPopup = function(self)
        closedColor = true
        self.colorPopup.open = false
    end
    editor:applyZoomIndex(View.RungIndex(2.0))
    luaunit.assertTrue(closedEdit)
    luaunit.assertTrue(closedColor)
    luaunit.assertEquals(editor.view.zoom, 2.0)
end

function TestGraphEditor:testOnResetViewClosesControlEditorAndColorPopup()
    local editor = Editor.new(self.registry, nil)
    local closedEdit, closedColor = false, false
    editor.editing = { nodeId = 1, pinName = "x" }
    editor.closeControlEditor = function(self)
        closedEdit = true
        self.editing = nil
    end
    editor.colorPopup.open = true
    editor.closeColorPopup = function(self)
        closedColor = true
        self.colorPopup.open = false
    end
    editor.view.panX, editor.view.zoom = 50, 2.0
    editor:onResetView()
    luaunit.assertTrue(closedEdit)
    luaunit.assertTrue(closedColor)
    luaunit.assertEquals(editor.view.zoom, 1.0)
    luaunit.assertEquals(editor.view.panX, 0)
end

function TestGraphEditor:testOnScrollSyncsSliderWithoutRetrigger()
    local editor = Editor.new(self.registry, nil)
    editor.mouse.x, editor.mouse.y = 100, 80
    editor.view.zoom = 1.0
    local sets = {}
    editor.zoomSlider = {
        SetValue = function(_, value, triggerEvents)
            sets[#sets + 1] = { value = value, triggerEvents = triggerEvents }
        end,
    }

    editor:onScroll(1)

    luaunit.assertAlmostEquals(editor.view.zoom, 1 / 1.1, 1e-12)
    luaunit.assertEquals(#sets, 1)
    luaunit.assertEquals(sets[1].value, View.RungIndex(1 / 1.1) - 1)
    luaunit.assertNotEquals(sets[1].triggerEvents, true)
end

function TestGraphEditor:testOnResetViewSyncsSliderToDefaultRung()
    local editor = Editor.new(self.registry, nil)
    editor.view.zoom = 2.0
    local sets = {}
    editor.zoomSlider = {
        SetValue = function(_, value, triggerEvents)
            sets[#sets + 1] = { value = value, triggerEvents = triggerEvents }
        end,
    }
    editor:onResetView()
    luaunit.assertEquals(#sets, 1)
    luaunit.assertEquals(sets[1].value, View.RungIndex(1.0) - 1)
    luaunit.assertNotEquals(sets[1].triggerEvents, true)
end

function TestGraphEditor:testPlaceFromPlusCentersNodeBodyOnViewCenter()
    local Theme = require("ui/theme")
    local Node = require("ui/node")
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.window.w, editor.window.h = 400, 300
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end
    editor.positionCapture = function() end

    editor:openPaletteFromPlus()
    local row
    for _, r in ipairs(editor.palette.rows) do
        if not r.header and r.typeKey == "fixture.trigger" then
            row = r
            break
        end
    end
    luaunit.assertNotNil(row)

    editor:placeFromPalette(row)

    local id = editor.selected
    luaunit.assertNotNil(id)
    local pos = editor.layout[id]
    local geom = Node.BuildGeometry(self.graph:GetPins(id), 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(pos.x + geom.w * 0.5, 200)
    luaunit.assertEquals(pos.y + geom.h * 0.5, 108)
end

local function registerModeFixture(registry)
    registry:RegisterNodeType("fixture.modes", {
        category = "action",
        defaultMode = "full",
        modes = {
            {
                key = "full",
                label = "Full",
                pins = {
                    { name = "in", kind = "exec", direction = "in", terminates = true },
                    { name = "tag", kind = "data", direction = "in", dataType = "string", default = "" },
                    { name = "item", kind = "data", direction = "in", dataType = "string", default = "" },
                },
            },
            {
                key = "count",
                label = "Count",
                pins = {
                    { name = "in", kind = "exec", direction = "in", terminates = true },
                    { name = "tag", kind = "data", direction = "in", dataType = "string", default = "" },
                    { name = "n", kind = "data", direction = "in", dataType = "number", default = 0 },
                },
            },
        },
        run = function() end,
    })
end

function TestGraphEditor:testFirstCompatiblePinFindsNonDefaultMode()
    registerModeFixture(self.registry)
    local def = self.registry:GetNodeType("fixture.modes")
    local pin, mode = Editor.FirstCompatiblePin(self.registry, def, {
        kind = "data", direction = "out", dataType = "number",
    })
    luaunit.assertEquals(pin, "n")
    luaunit.assertEquals(mode, "count")
end

-- Drag-to-empty filtered palette walks modeless types first (line 308 on the bad
-- require("registry") commit). pinSet must come from the instance, not a module upvalue.
function TestGraphEditor:testFirstCompatiblePinOnModelessType()
    local def = self.registry:GetNodeType("fixture.action")
    local pin, mode = Editor.FirstCompatiblePin(self.registry, def, {
        kind = "exec", direction = "out",
    })
    luaunit.assertEquals(pin, "in")
    luaunit.assertNil(mode)
end

function TestGraphEditor:testFirstCompatiblePinHasNoRegistryModuleUpvalue()
    for i = 1, 20 do
        local name = debug.getupvalue(Editor.FirstCompatiblePin, i)
        if name == nil then break end
        luaunit.assertNotEquals(name, "Registry")
    end
end

function TestGraphEditor:testPlaceFromPaletteCreatesInTargetMode()
    registerModeFixture(self.registry)
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.positionCapture = function() end

    editor:placeFromPalette({ typeKey = "fixture.modes", targetPin = "n", targetMode = "count" })

    local id = editor.selected
    luaunit.assertEquals(self.graph:GetMode(id), "count")
    local names = {}
    for _, p in ipairs(self.graph:GetPins(id)) do names[p.name] = true end
    luaunit.assertTrue(names.n)
    luaunit.assertNil(names.item)
end

function TestGraphEditor:testApplyNodeModeRebuildsPinsAndDropsVanishedEditor()
    registerModeFixture(self.registry)
    local id = self.graph:AddNode("fixture.modes")
    luaunit.assertEquals(self.graph:GetMode(id), "full")

    local closed = false
    local editor = setmetatable({
        graph = self.graph,
        editing = { nodeId = id, pinName = "item", kind = "field" },
        closeControlEditor = function(self)
            closed = true
            self.editing = nil
        end,
    }, { __index = Editor })

    luaunit.assertTrue(editor:applyNodeMode(id, "count"))
    luaunit.assertTrue(closed)
    luaunit.assertEquals(self.graph:GetMode(id), "count")
    local names = {}
    for _, p in ipairs(self.graph:GetPins(id)) do names[p.name] = true end
    luaunit.assertTrue(names.n)
    luaunit.assertNil(names.item)
end

function TestGraphEditor:testFilteredPaletteFindsNonDefaultModeAndAddsInIt()
    registerModeFixture(self.registry)
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.positionCapture = function() end

    local want = { kind = "data", direction = "out", dataType = "number" }
    editor.palette:Open(self.registry, function(def)
        return Editor.FirstCompatiblePin(self.registry, def, want)
    end, { screenX = 0, screenY = 0, anchorGX = 0, anchorGY = 0 })

    local row
    for _, r in ipairs(editor.palette.rows) do
        if r.typeKey == "fixture.modes" then row = r break end
    end
    luaunit.assertNotNil(row)
    luaunit.assertEquals(row.targetPin, "n")
    luaunit.assertEquals(row.targetMode, "count")

    editor:placeFromPalette(row)
    luaunit.assertEquals(self.graph:GetMode(editor.selected), "count")
end

function TestGraphEditor:testApplyNodeModeGeometryMatchesGetPins()
    local Theme = require("ui/theme")
    local Node = require("ui/node")
    registerModeFixture(self.registry)
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    local id = self.graph:AddNode("fixture.modes")
    editor.layout[id] = { x = 0, y = 0 }

    editor:buildGeoms()
    luaunit.assertNotNil(editor.geoms[id].byName.item)
    luaunit.assertNotNil(editor.geoms[id].modeStrip)

    luaunit.assertTrue(editor:applyNodeMode(id, "count"))
    editor:buildGeoms()
    local geom = editor.geoms[id]
    luaunit.assertNotNil(geom.byName.n)
    luaunit.assertNil(geom.byName.item)
    luaunit.assertNotNil(geom.modeStrip)
    luaunit.assertEquals(geom.modeStrip.label, "Count")
    luaunit.assertAlmostEquals(geom.h, Node.BuildGeometry(
        self.graph:GetPins(id), 0, 0, Theme.NODE_WIDTH, { modeLabel = "Count" }).h, 1e-9)
end

function TestGraphEditor:testApplyNodeModeKeepsSurvivingPinEditor()
    registerModeFixture(self.registry)
    local id = self.graph:AddNode("fixture.modes")
    local closed = false
    local editor = setmetatable({
        graph = self.graph,
        editing = { nodeId = id, pinName = "tag", kind = "field" },
        closeControlEditor = function(self)
            closed = true
            self.editing = nil
        end,
    }, { __index = Editor })

    luaunit.assertTrue(editor:applyNodeMode(id, "count"))
    luaunit.assertFalse(closed)
    luaunit.assertEquals(editor.editing.pinName, "tag")
end

function TestGraphEditor:testParkedEditorRestoredWhenPinSurvives()
    registerModeFixture(self.registry)
    local id = self.graph:AddNode("fixture.modes")
    local destroyed = false
    local editor = setmetatable({
        graph = self.graph,
        editing = { kind = "nodeMode", nodeId = id, field = nil },
        _modeEditStash = {
            nodeId = id, pinName = "tag", kind = "field",
            field = { Destroy = function() destroyed = true end },
        },
    }, { __index = Editor })

    luaunit.assertTrue(editor:applyNodeMode(id, "count"))
    luaunit.assertFalse(destroyed)
    luaunit.assertNotNil(editor._modeEditStash)
    editor:closeControlEditor()
    luaunit.assertEquals(editor.editing.pinName, "tag")
    luaunit.assertNil(editor._modeEditStash)
end

function TestGraphEditor:testParkedEditorDroppedWhenPinVanishes()
    registerModeFixture(self.registry)
    local id = self.graph:AddNode("fixture.modes")
    local destroyed = false
    local editor = setmetatable({
        graph = self.graph,
        editing = { kind = "nodeMode", nodeId = id, field = nil },
        _modeEditStash = {
            nodeId = id, pinName = "item", kind = "field",
            field = { Destroy = function() destroyed = true end },
        },
    }, { __index = Editor })

    luaunit.assertTrue(editor:applyNodeMode(id, "count"))
    luaunit.assertTrue(destroyed)
    luaunit.assertNil(editor._modeEditStash)
    editor:closeControlEditor()
    luaunit.assertNil(editor.editing)
end

--- Node Body occludes pins/controls of nodes behind it ----------------------------------
-- pinAt walks front-to-back but used to keep looking after missing a pin on the front
-- node, so a pin sitting under another Node Body still started a wire drag.

local function pinScreen(editor, nodeId, pinName)
    local geom = editor.geoms[nodeId]
    local pin = geom.byName[pinName]
    return editor.view:ToScreen(geom.x + pin.cx, geom.y + pin.cy)
end

local function overlappingPinEditors(self, frontX)
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    local back = self.graph:AddNode("fixture.trigger")
    local front = self.graph:AddNode("fixture.action")
    editor.layout[back] = { x = 0, y = 0 }
    editor.layout[front] = { x = frontX, y = 0 }
    editor:buildGeoms()
    editor.nodeOrder = { back, front }
    return editor, back, front
end

function TestGraphEditor:testPinAtDoesNotSeeThroughFrontNodeBody()
    -- Action at x=200 covers the trigger's right-edge output pin (cx ≈ 240).
    local editor, back, front = overlappingPinEditors(self, 200)
    local sx, sy = pinScreen(editor, back, "out")
    luaunit.assertEquals(editor:nodeAt(sx, sy), front)
    luaunit.assertNil(editor:pinAt(sx, sy))
end

function TestGraphEditor:testPinAtStillHitsUncoveredBackNodePin()
    -- Action parked well to the right: trigger output is in empty space.
    local editor, back = overlappingPinEditors(self, 400)
    local sx, sy = pinScreen(editor, back, "out")
    local hit = editor:pinAt(sx, sy)
    luaunit.assertNotNil(hit)
    luaunit.assertEquals(hit.nodeId, back)
    luaunit.assertEquals(hit.entry.name, "out")
end

function TestGraphEditor:testPinAtStillHitsFrontNodePinWhenOverlapping()
    local editor, _, front = overlappingPinEditors(self, 200)
    local sx, sy = pinScreen(editor, front, "in")
    local hit = editor:pinAt(sx, sy)
    luaunit.assertNotNil(hit)
    luaunit.assertEquals(hit.nodeId, front)
    luaunit.assertEquals(hit.entry.name, "in")
end

function TestGraphEditor:testControlAtDoesNotSeeThroughFrontNodeBody()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    local back = self.graph:AddNode("fixture.action")
    local front = self.graph:AddNode("fixture.trigger")
    editor.layout[back] = { x = 0, y = 0 }
    -- Shift the (shorter) trigger down so its body covers the action's value Control.
    editor.layout[front] = { x = 0, y = 20 }
    editor:buildGeoms()
    editor.nodeOrder = { back, front }
    local geom = editor.geoms[back]
    local ctrl = geom.controls[1]
    local sx, sy = editor.view:ToScreen(geom.x + ctrl.x + ctrl.w * 0.5, geom.y + ctrl.y + ctrl.h * 0.5)
    luaunit.assertEquals(editor:nodeAt(sx, sy), front)
    luaunit.assertNil(editor:controlAt(sx, sy))
end
