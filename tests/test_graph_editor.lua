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
local Serialize = require("serialize")
local Editor = require("src/ui/graph")
local View = require("src/ui/view")
local EditToolbar = require("src/ui/edit_toolbar")

TestGraphEditor = {}

function TestGraphEditor:setUp()
    self.registry = Registry.new()

    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        displayName = "Trigger",
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

function TestGraphEditor:tearDown()
    _G.Mouse = nil
    if self._restoreGame then
        rawset(_G, "game", self._savedGame)
        self._restoreGame = nil
    end
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
    luaunit.assertEquals(editor.view.panY, EditToolbar.Bottom() + 8) -- clear of the edit toolbar
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
    luaunit.assertEquals(gy, 150)
end

function TestGraphEditor:testViewCenterGraphAccountsForPanAndZoom()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    editor.view.panX, editor.view.panY, editor.view.zoom = 40, -20, 2.0
    local gx, gy = editor:viewCenterGraph()
    luaunit.assertEquals(gx, 80)
    luaunit.assertEquals(gy, 85)
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
    luaunit.assertEquals(editor.palette.anchorGY, 85)
    luaunit.assertTrue(editor.palette.centerOnAnchor)
    luaunit.assertEquals(editor.palette.screenX, 158)
    luaunit.assertEquals(editor.palette.screenY, 196)
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

function TestGraphEditor:testOnResetViewHomesPanBelowTheToolbarAndDefaultZoom()
    local editor = Editor.new(self.registry, nil)
    editor.view.panX, editor.view.panY, editor.view.zoom = 123, 45, 2.0
    editor:onResetView()
    luaunit.assertEquals(editor.view.panX, 0)
    luaunit.assertEquals(editor.view.panY, EditToolbar.Bottom() + 8)
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

function TestGraphEditor:testToolbarButtonsClosePaletteBeforeTheirAction()
    local savedUi, savedPretty = _G.ui, _G.prettyui
    local buttons = {}
    local function root()
        return {
            SetPos = function() end,
            SetSize = function() end,
            MoveToFront = function() end,
        }
    end
    _G.ui = nil
    _G.prettyui = {
        SpriteButton = {
            new = function(_, _, action, opts)
                local btn = { action = action, tooltip = opts.tooltip, root = root() }
                buttons[#buttons + 1] = btn
                return btn
            end,
        },
    }
    local editor = Editor.new(self.registry, nil)
    editor:mountToolbar({})
    editor.onRename = function()
        luaunit.assertFalse(editor.palette.open)
    end
    editor.onSavePreset = function()
        luaunit.assertFalse(editor.palette.open)
    end
    editor.onBack = function()
        luaunit.assertFalse(editor.palette.open)
    end

    local saw = {}
    for _, btn in ipairs(buttons) do
        editor.palette.open = true
        local closedDuring = false
        editor.closePalette = function(self)
            closedDuring = true
            Editor.closePalette(self)
        end
        btn.action()
        luaunit.assertTrue(closedDuring, btn.tooltip)
        if btn.tooltip == "Add alert node" then
            luaunit.assertTrue(editor.palette.open)
        else
            luaunit.assertFalse(editor.palette.open)
        end
        saw[btn.tooltip] = true
    end

    luaunit.assertTrue(saw["Rename"])
    luaunit.assertTrue(saw["Save as preset"])
    luaunit.assertTrue(saw["Tutorial"])
    luaunit.assertTrue(saw["Add alert node"])
    _G.ui, _G.prettyui = savedUi, savedPretty
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
    -- 400x300 center is 200, 150. The home view starts graph y = 0 below the edit
    -- toolbar, so that center is graph 200, 150 - clearance. A 250x68 body centered
    -- there sits at 75, 116 - clearance.
    luaunit.assertEquals(pos.x, 75)
    luaunit.assertEquals(pos.y, 116 - (EditToolbar.Bottom() + 8))
end

-- Centering runs first. Anchor 126.5, 34.5 puts the body at 1.5, 0.5, which the player sees as 2, 1.
function TestGraphEditor:testPlaceFromPaletteRoundsHalvesAwayFromZero()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end
    editor.positionCapture = function() end
    editor.palette.anchorGX = 126.5
    editor.palette.anchorGY = 34.5
    editor.palette.centerOnAnchor = true

    editor:placeFromPalette({ typeKey = "fixture.trigger" })

    local pos = editor.layout[editor.selected]
    luaunit.assertEquals(pos.x, 2)
    luaunit.assertEquals(pos.y, 1)
end

-- Anchor 123.5, 33.5 centers the body at -1.5, -0.5. Those land on -2, -1.
function TestGraphEditor:testPlaceFromPaletteRoundsNegativeHalvesAwayFromZero()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end
    editor.positionCapture = function() end
    editor.palette.anchorGX = 123.5
    editor.palette.anchorGY = 33.5
    editor.palette.centerOnAnchor = true

    editor:placeFromPalette({ typeKey = "fixture.trigger" })

    local pos = editor.layout[editor.selected]
    luaunit.assertEquals(pos.x, -2)
    luaunit.assertEquals(pos.y, -1)
end

-- Anchor 129, 26 centers the body at 4, -8. An integer stays that integer.
function TestGraphEditor:testPlaceFromPaletteKeepsAnIntegerPosition()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end
    editor.positionCapture = function() end
    editor.palette.anchorGX = 129
    editor.palette.anchorGY = 26
    editor.palette.centerOnAnchor = true

    editor:placeFromPalette({ typeKey = "fixture.trigger" })

    local pos = editor.layout[editor.selected]
    luaunit.assertEquals(pos.x, 4)
    luaunit.assertEquals(pos.y, -8)
end

-- A click places the node on the anchor. -1.5, 0.5 is stored as -2, 1.
function TestGraphEditor:testPlaceFromPaletteRoundsTheClickAnchor()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end
    editor.positionCapture = function() end
    editor.palette.anchorGX = -1.5
    editor.palette.anchorGY = 0.5
    editor.palette.centerOnAnchor = false

    editor:placeFromPalette({ typeKey = "fixture.trigger" })

    local pos = editor.layout[editor.selected]
    luaunit.assertEquals(pos.x, -2)
    luaunit.assertEquals(pos.y, 1)
end

-- No drag writes the integer onto the live point and into the saved array.
-- The node being dragged stays fractional on the live layout. Halves go away from zero.
function TestGraphEditor:testSaveRoundsLivePointsExceptTheDraggedNode()
    local Store = require("src/store")
    local editor = Editor.new(self.registry, nil)
    local kept = self.graph:AddNode("fixture.trigger")
    local dragged = self.graph:AddNode("fixture.trigger")
    local layout = {
        [kept] = { x = 1.5, y = -0.5 },
        [dragged] = { x = -1.5, y = 2.5 },
    }
    editor:BindEntry(1, self.graph, layout)

    editor:GetLayout()
    local quiet = Store.NewAlertEntry(1, "Quiet", self.graph, layout)
    luaunit.assertEquals(layout[kept].x, 2)
    luaunit.assertEquals(layout[kept].y, -1)
    luaunit.assertEquals(layout[dragged].x, -2)
    luaunit.assertEquals(layout[dragged].y, 3)
    luaunit.assertEquals(quiet.layout, {
        { id = kept, x = 2, y = -1 },
        { id = dragged, x = -2, y = 3 },
    })

    layout[kept].x = 1.5
    layout[kept].y = -0.5
    layout[dragged].x = -1.5
    layout[dragged].y = 2.5
    editor.dragNodeId = dragged
    editor:GetLayout()
    local mid = Store.NewAlertEntry(1, "Drag", self.graph, layout)
    luaunit.assertEquals(layout[kept].x, 2)
    luaunit.assertEquals(layout[kept].y, -1)
    luaunit.assertEquals(layout[dragged].x, -1.5)
    luaunit.assertEquals(layout[dragged].y, 2.5)
    luaunit.assertEquals(mid.layout, {
        { id = kept, x = 2, y = -1 },
        { id = dragged, x = -2, y = 3 },
    })
end

-- The body follows the cursor while the button is held. Release stores 1.5, -0.5 as 2, -1.
function TestGraphEditor:testDragFollowsTheCursorUntilReleaseRoundsTheLayout()
    local editor = Editor.new(self.registry, nil)
    local id = self.graph:AddNode("fixture.trigger")
    editor:BindEntry(1, self.graph, { [id] = { x = 10, y = 20 } })
    editor.view.panY = 0 -- graph space equals content space; the home view offset is not under test
    editor.visible = true
    editor:buildGeoms()

    local function mouseAt(lx, ly)
        _G.Mouse = {
            GetPosition = function()
                return { x = editor.window.x + lx, y = editor.window.y + ly }
            end,
        }
    end

    -- Center of the body, below the header and left of the output pin.
    mouseAt(135, 54)
    editor:beginPress()
    luaunit.assertEquals(editor.mode, "dragnode")

    mouseAt(126.5, 33.5)
    editor:update()
    luaunit.assertEquals(editor.layout[id].x, 1.5)
    luaunit.assertEquals(editor.layout[id].y, -0.5)

    editor:endPress()
    luaunit.assertEquals(editor.layout[id].x, 2)
    luaunit.assertEquals(editor.layout[id].y, -1)
end

-- beginPress expands the capture before the queued hold, whose offsets stay in the old space.
-- Window and click are proportional so a live origin still yields a scale Measure accepts.
function TestGraphEditor:testHeldClickDoesNotFlingTheNodeWhenCaptureExpands()
    self._savedGame = rawget(_G, "game")
    self._restoreGame = true
    rawset(_G, "game", { options = { InterfaceScale = { setting = 100 } } })
    local editor = Editor.new(self.registry, nil)
    local id = self.graph:AddNode("fixture.trigger")
    editor:BindEntry(1, self.graph, { [id] = { x = 10, y = 20 } })
    editor.view.panY = 0 -- graph space equals content space; the home view offset is not under test
    editor.visible = true
    editor.window.x, editor.window.y = 270, 108
    editor:buildGeoms()

    local hookX, hookY = 135, 54
    local absoluteX, absoluteY = 405, 162
    local capture = { x = 0, y = 0 }
    function capture:SetPos(x, y)
        self.x, self.y = x, y
    end
    function capture:SetSize() end
    editor.capture = capture
    _G.Mouse = {
        GetPosition = function()
            return { x = absoluteX, y = absoluteY }
        end,
    }

    editor:update()
    editor:noteScreenScale(capture, hookX, hookY)
    editor:beginPress()
    luaunit.assertEquals(editor.mode, "dragnode")
    editor:noteScreenScale(capture, hookX, hookY)
    editor:update()
    local mx, my = editor:mousePos()
    luaunit.assertEquals(mx, absoluteX)
    luaunit.assertEquals(my, absoluteY)
    luaunit.assertEquals(editor.layout[id].x, 10)
    luaunit.assertEquals(editor.layout[id].y, 20)

    -- Next pass, hook offsets are relative to the expanded capture.
    editor:noteScreenScale(capture, absoluteX, absoluteY)
    editor:update()
    mx, my = editor:mousePos()
    luaunit.assertEquals(mx, absoluteX)
    luaunit.assertEquals(my, absoluteY)
    luaunit.assertEquals(editor.layout[id].x, 10)
    luaunit.assertEquals(editor.layout[id].y, 20)
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
    local Theme = require("src/ui/theme")
    local Node = require("src/ui/node")
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

function TestGraphEditor:testLongHeaderTitleWidensTheNode()
    local Theme = require("src/ui/theme")
    self.registry:RegisterNodeType("fixture.gameMessage", {
        category = "trigger",
        displayName = "Game Message",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function() end,
    })
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    local id = self.graph:AddNode("fixture.gameMessage")
    editor.layout[id] = { x = 0, y = 0 }

    editor:buildGeoms()
    luaunit.assertTrue(editor.geoms[id].w > Theme.NODE_WIDTH)
end

function TestGraphEditor:testPlaceFromPaletteCentersTheWidenedBody()
    local Util = require("src/util")
    local Theme = require("src/ui/theme")
    self.registry:RegisterNodeType("fixture.gameMessage", {
        category = "trigger",
        displayName = "Game Message",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function() end,
    })
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end
    editor.positionCapture = function() end
    editor.palette.anchorGX = 200
    editor.palette.anchorGY = 100
    editor.palette.centerOnAnchor = true

    editor:placeFromPalette({ typeKey = "fixture.gameMessage" })
    editor:buildGeoms()

    local geom = editor.geoms[editor.selected]
    local pos = editor.layout[editor.selected]
    luaunit.assertTrue(geom.w > Theme.NODE_WIDTH)
    luaunit.assertEquals(pos.x, Util.RoundHalfAway(200 - geom.w * 0.5))
    luaunit.assertEquals(pos.y, Util.RoundHalfAway(100 - geom.h * 0.5))
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

function TestGraphEditor:testOpenPopupHeaderReadsTypeDashNewType()
    self.registry:RegisterNodeType("action.popup", {
        category = "action",
        displayName = "Popup",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() end,
    })
    local editor = Editor.new(self.registry, nil)
    local id = self.graph:AddNode("action.popup")
    editor:BindEntry(1, self.graph, {})
    luaunit.assertEquals(editor:meta(id, "action.popup").title, "Popup - New Popup")
end

function TestGraphEditor:testOpenPopupHeaderShowsTheStoredName()
    self.registry:RegisterNodeType("action.popup", {
        category = "action",
        displayName = "Popup",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() end,
    })
    local editor = Editor.new(self.registry, nil)
    local id = self.graph:AddNode("action.popup")
    self.graph.nodes[id].name = "Enrage callout"
    editor:BindEntry(1, self.graph, {})
    luaunit.assertEquals(editor:meta(id, "action.popup").title, "Popup - Enrage callout")
end

function TestGraphEditor:testRenameCommitUpdatesTheHeaderImmediately()
    self.registry:RegisterNodeType("action.popup", {
        category = "action",
        displayName = "Popup",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() end,
    })
    local editor = Editor.new(self.registry, nil)
    local id = self.graph:AddNode("action.popup")
    local other = self.graph:AddNode("action.popup")
    editor:BindEntry(1, self.graph, {})

    local draft = editor:nodeRenameDraft(id)
    luaunit.assertEquals(draft.typeLabel, "Popup")
    luaunit.assertEquals(draft.fieldText, "New Popup")
    luaunit.assertEquals(editor:meta(id, "action.popup").title, "Popup - New Popup")

    luaunit.assertTrue(editor:commitNodeRename(id, "  Enrage callout  "))
    luaunit.assertEquals(editor:meta(id, "action.popup").title, "Popup - Enrage callout")
    luaunit.assertEquals(self.graph.nodes[id].name, "Enrage callout")

    luaunit.assertFalse(editor:commitNodeRename(id, "   "))
    luaunit.assertEquals(self.graph.nodes[id].name, "Enrage callout")

    luaunit.assertTrue(editor:commitNodeRename(other, "Enrage callout"))
    luaunit.assertEquals(self.graph.nodes[other].name, "Enrage callout")
    luaunit.assertEquals(editor:meta(other, "action.popup").title, "Popup - Enrage callout")

    luaunit.assertTrue(editor:nodeRenameBlank(""))
    luaunit.assertTrue(editor:nodeRenameBlank("   "))
    luaunit.assertTrue(editor:nodeRenameBlank(" \t "))
    luaunit.assertFalse(editor:nodeRenameBlank("Enrage callout"))
    luaunit.assertFalse(editor:nodeRenameBlank("  Enrage callout  "))
end

function TestGraphEditor:testPencilClickOpensRenameAndDoesNotDeleteOrDrag()
    self.registry:RegisterNodeType("action.popup", {
        category = "action",
        displayName = "Popup",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() end,
    })
    local editor = Editor.new(self.registry, nil)
    local id = self.graph:AddNode("action.popup")
    editor:BindEntry(1, self.graph, { [id] = { x = 40, y = 50 } })
    editor.visible = true
    editor:buildGeoms()
    local geom = editor.geoms[id]
    local pcx, pcy = editor.view:ToScreen(geom.x + geom.pencil.cx, geom.y + geom.pencil.cy)
    local renamed
    editor.onRenameNode = function(nodeId) renamed = nodeId end
    local savedMouse = _G.Mouse
    _G.Mouse = {
        GetPosition = function()
            return { x = editor.window.x + pcx, y = editor.window.y + pcy }
        end,
    }
    editor:beginPress()
    _G.Mouse = savedMouse
    luaunit.assertEquals(renamed, id)
    luaunit.assertNotNil(self.graph.nodes[id])
    luaunit.assertNotEquals(editor.mode, "dragnode")
end

function TestGraphEditor:testPlaceholderHeaderKeepsTheOriginalTypeKey()
    local graph = Serialize.Deserialize({
        version = 1,
        nodes = { { id = 1, type = "action.popup", controls = { body = "hi" } } },
        connections = {},
    }, self.registry, { onUnknown = "placeholder" })
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, graph, {})
    local typeKey = graph.nodes[1].typeKey
    luaunit.assertEquals(editor:meta(1, typeKey).title, "Unknown: action.popup - New Unknown: action.popup")
    luaunit.assertTrue(editor:meta(1, typeKey).placeholder)
    luaunit.assertEquals(editor:nodeRenameDraft(1).fieldText, "New Unknown: action.popup")
    luaunit.assertEquals(editor:nodeRenameDraft(1).typeLabel, "Unknown: action.popup")
    luaunit.assertTrue(editor:commitNodeRename(1, "  Enrage callout  "))
    luaunit.assertEquals(graph.nodes[1].unknown.name, "Enrage callout")
    luaunit.assertNil(graph.nodes[1].name)
    luaunit.assertEquals(editor:meta(1, typeKey).title, "Unknown: action.popup - Enrage callout")
    luaunit.assertEquals(graph.nodes[1].unknown.type, "action.popup")
    luaunit.assertEquals(graph.nodes[1].unknown.controls.body, "hi")
end

-- The X removes the node. The InfoBox strip is keyed by that node's state table, which
-- RemoveNode drops from the graph without telling the strip. Alert disable already
-- releases every node; this is the single-node path.
function TestGraphEditor:testDeleteNodeClearsThatNodesInfobox()
    local InfoBox = require("src/ui/infobox")
    local Runtime = require("src/runtime")
    local newFakeEventSource = require("fake_event_source")

    local infobox = InfoBox.new()
    local runtime = Runtime.new(newFakeEventSource().source)
    runtime.infobox = infobox

    local editor = Editor.new(self.registry, runtime)
    editor:BindEntry(1, self.graph, {})

    local removedId = self.graph:AddNode("fixture.action")
    local keptId = self.graph:AddNode("fixture.action")
    local removedState = self.graph:GetState(removedId)
    local keptState = self.graph:GetState(keptId)
    editor.layout[removedId] = { x = 0, y = 0 }
    editor.layout[keptId] = { x = 40, y = 0 }
    editor.nodeOrder = { removedId, keptId }
    editor.selected = removedId
    editor.geoms[removedId] = {}

    infobox:Set(removedState, { text = "9", title = "gone" })
    infobox:Set(keptState, { text = "1", title = "stay" })

    editor:deleteNode(removedId)

    luaunit.assertFalse(infobox:Has(removedState))
    luaunit.assertTrue(infobox:Has(keptState))
    luaunit.assertEquals(infobox:Count(), 1)
    luaunit.assertNil(self.graph:GetState(removedId))
    luaunit.assertNotNil(self.graph:GetState(keptId))
    luaunit.assertNil(editor.layout[removedId])
    luaunit.assertNil(editor.geoms[removedId])
    luaunit.assertNil(editor.selected)
    luaunit.assertEquals(editor.nodeOrder, { keptId })
end
