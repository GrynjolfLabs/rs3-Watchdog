-- InfoBox Area: ordered box set, wrap layout, hit-testing, Bounds, drag-as-unit.
-- Canvas drawing is a client primitive and is not asserted here (#41 AC).
--
-- InfoBox.Draw resolves colors through Vector4 at draw time; stub so the module loads under bare Lua.
_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local InfoBox = require("src/ui/infobox")
local Theme = require("src/ui/theme")

--- Ordered box set -------------------------------------------------------------------------

TestBoxSet = {}

function TestBoxSet:setUp()
    self.area = InfoBox.new()
end

function TestBoxSet:testSetAddsABox()
    self.area:Set("a", { text = "1" })
    luaunit.assertTrue(self.area:Has("a"))
    luaunit.assertEquals(self.area:Count(), 1)
    luaunit.assertEquals(self.area:Get("a").text, "1")
end

function TestBoxSet:testSetStoresAllFields()
    self.area:Set("a", { text = "hp", color = { r = 1, g = 2, b = 3, a = 4 }, icon = 77, title = "Health" })
    local box = self.area:Get("a")
    luaunit.assertEquals(box.text, "hp")
    luaunit.assertEquals(box.color, { r = 1, g = 2, b = 3, a = 4 })
    luaunit.assertEquals(box.icon, 77)
    luaunit.assertEquals(box.title, "Health")
end

function TestBoxSet:testSetSameOwnerRewritesInPlaceKeepingOrder()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    self.area:Set("a", { text = "99" })
    luaunit.assertEquals(self.area:Count(), 2)
    luaunit.assertEquals(self.area:Order(), { "a", "b" })
    luaunit.assertEquals(self.area:Get("a").text, "99")
end

function TestBoxSet:testInsertionOrderPreserved()
    self.area:Set("x", { text = "1" })
    self.area:Set("y", { text = "2" })
    self.area:Set("z", { text = "3" })
    luaunit.assertEquals(self.area:Order(), { "x", "y", "z" })
end

function TestBoxSet:testRemoveDropsBoxAndReflows()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    self.area:Set("c", { text = "3" })
    luaunit.assertTrue(self.area:Remove("b"))
    luaunit.assertFalse(self.area:Has("b"))
    luaunit.assertEquals(self.area:Order(), { "a", "c" })
    luaunit.assertEquals(self.area:Count(), 2)
end

function TestBoxSet:testRemoveMissingIsFalseNoop()
    self.area:Set("a", { text = "1" })
    luaunit.assertFalse(self.area:Remove("nope"))
    luaunit.assertEquals(self.area:Count(), 1)
end

function TestBoxSet:testClearEmptiesEverything()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    self.area:Clear()
    luaunit.assertEquals(self.area:Count(), 0)
    luaunit.assertEquals(self.area:Order(), {})
end

--- Layout: horizontal flow + wrap ----------------------------------------------------------

TestLayout = {}

function TestLayout:setUp()
    self.area = InfoBox.new()
    self.area:SetAnchor(100, 50)
    -- A wrap width that fits exactly 3 fixed-square boxes per row, for deterministic wrap math.
    local size, gap = Theme.INFOBOX_BOX_SIZE, Theme.INFOBOX_GAP
    self.area:SetWrapWidth(size * 3 + gap * 2)
end

function TestLayout:testSingleBoxSitsAtAnchor()
    self.area:Set("a", { text = "1" })
    local rects = self.area:Layout()
    luaunit.assertEquals(#rects, 1)
    luaunit.assertEquals(rects[1].owner, "a")
    luaunit.assertEquals(rects[1].x, 100)
    luaunit.assertEquals(rects[1].y, 50)
    luaunit.assertEquals(rects[1].w, Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(rects[1].h, Theme.INFOBOX_BOX_SIZE)
end

function TestLayout:testHorizontalFlowWithinARow()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    local rects = self.area:Layout()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertEquals(rects[2].x, 100 + step)
    luaunit.assertEquals(rects[2].y, 50)
end

function TestLayout:testWrapsToNextRowPastTheWrapWidth()
    for _, k in ipairs({ "a", "b", "c", "d" }) do
        self.area:Set(k, { text = k })
    end
    local rects = self.area:Layout()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    -- 3 per row, so the 4th wraps back to column 0 on the second row.
    luaunit.assertEquals(rects[4].x, 100)
    luaunit.assertEquals(rects[4].y, 50 + step)
end

function TestLayout:testReflowAfterRemovePullsLaterBoxesUp()
    for _, k in ipairs({ "a", "b", "c", "d" }) do
        self.area:Set(k, { text = k })
    end
    self.area:Remove("a")  -- "d" was on row 2; removing one from row 1 pulls it back up
    local rects = self.area:Layout()
    local d = rects[#rects]
    luaunit.assertEquals(d.owner, "d")
    luaunit.assertEquals(d.y, 50)
end

--- Hit-testing -----------------------------------------------------------------------------

TestHitTest = {}

function TestHitTest:setUp()
    self.area = InfoBox.new()
    self.area:SetAnchor(0, 0)
    self.area:SetWrapWidth(1000)  -- one long row, no wrap
    self.area:Set("a", { text = "1", title = "Alpha" })
    self.area:Set("b", { text = "2" })  -- no title
end

function TestHitTest:testBoxAtInsideFirstBox()
    luaunit.assertEquals(self.area:BoxAt(5, 5), "a")
end

function TestHitTest:testBoxAtInsideSecondBox()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertEquals(self.area:BoxAt(step + 5, 5), "b")
end

function TestHitTest:testBoxAtOutsideIsNil()
    luaunit.assertNil(self.area:BoxAt(-5, -5))
    luaunit.assertNil(self.area:BoxAt(5, Theme.INFOBOX_BOX_SIZE + 100))
end

function TestHitTest:testTooltipReturnsTitleOverTitledBox()
    luaunit.assertEquals(self.area:TooltipAt(5, 5), "Alpha")
end

function TestHitTest:testTooltipNilOverUntitledBox()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertNil(self.area:TooltipAt(step + 5, 5))
end

function TestHitTest:testTooltipNilOutsideAnyBox()
    luaunit.assertNil(self.area:TooltipAt(-5, -5))
end

function TestHitTest:testEmptyTitleIsNoTooltip()
    self.area:Set("a", { text = "1", title = "" })
    luaunit.assertNil(self.area:TooltipAt(5, 5))
end

--- Bounds ----------------------------------------------------------------------------------

TestBounds = {}

function TestBounds:testBoundsNilWhenEmpty()
    local area = InfoBox.new()
    luaunit.assertNil(area:Bounds())
end

function TestBounds:testBoundsSpansAllBoxes()
    local area = InfoBox.new()
    area:SetAnchor(10, 20)
    area:SetWrapWidth(1000)
    area:Set("a", { text = "1" })
    area:Set("b", { text = "2" })
    local b = area:Bounds()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertEquals(b.x, 10)
    luaunit.assertEquals(b.y, 20)
    luaunit.assertEquals(b.w, step + Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(b.h, Theme.INFOBOX_BOX_SIZE)
end

--- Drag-as-unit ----------------------------------------------------------------------------

TestDrag = {}

function TestDrag:setUp()
    self.area = InfoBox.new()
    self.area:SetAnchor(100, 100)
    self.area:SetWrapWidth(1000)
    self.area:Set("a", { text = "1" })
end

function TestDrag:tearDown()
    require("src/ui/hub_layers").SetPositionsLocked(false)
end

function TestDrag:testBeginDragInsideBoundsGrabs()
    luaunit.assertTrue(self.area:BeginDrag(105, 105))
end

function TestDrag:testBeginDragOutsideBoundsDoesNotGrab()
    luaunit.assertFalse(self.area:BeginDrag(500, 500))
end

function TestDrag:testLockedStripDoesNotDrag()
    local HubLayers = require("src/ui/hub_layers")
    HubLayers.SetPositionsLocked(true)
    luaunit.assertFalse(self.area:BeginDrag(105, 105))
    HubLayers.SetPositionsLocked(false)
end

-- Stand-in for the client button Reposition resizes. Mount itself is not under test.
local function fakeCapture()
    local cap = { clickthrough = false }
    function cap:SetPos(x, y)
        self.x, self.y = x, y
    end
    function cap:SetSize(w, h, pw, ph)
        self.w, self.h, self.pw, self.ph = w, h, pw, ph
    end
    function cap:MoveToFront() end
    return cap
end

function TestDrag:testUnlockedStripCapturesClicks()
    self.area._capture = fakeCapture()
    self.area:Reposition()
    luaunit.assertFalse(self.area._capture.clickthrough)
    luaunit.assertEquals(self.area._capture.x, 100)
    luaunit.assertEquals(self.area._capture.y, 100)
    luaunit.assertEquals(self.area._capture.w, Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(self.area._capture.h, Theme.INFOBOX_BOX_SIZE)
end

function TestDrag:testLockedStripLetsClicksThrough()
    local HubLayers = require("src/ui/hub_layers")
    HubLayers.SetPositionsLocked(true)
    self.area._capture = fakeCapture()
    self.area:Reposition()
    luaunit.assertTrue(self.area._capture.clickthrough)
    luaunit.assertEquals(self.area._capture.w, Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(self.area._capture.h, Theme.INFOBOX_BOX_SIZE)
end

function TestDrag:testDragKeepsCaptureExpanded()
    self.area:BeginDrag(105, 105)
    self.area._capture = fakeCapture()
    self.area:_expandCapture()
    self.area:Reposition()
    luaunit.assertTrue(self.area:IsDragging())
    luaunit.assertFalse(self.area._capture.clickthrough)
    luaunit.assertEquals(self.area._capture.w, 0)
    luaunit.assertEquals(self.area._capture.pw, 1.0)
    luaunit.assertEquals(self.area._capture.ph, 1.0)
end

function TestDrag:testLockDuringDragShrinksCaptureAndLetsClicksThrough()
    local HubLayers = require("src/ui/hub_layers")
    local saved = {}
    self.area:SetPersistence({ SaveAnchor = function(x, y) saved.x, saved.y = x, y end })
    self.area:BeginDrag(105, 105)
    self.area:Drag(140, 120)
    self.area._capture = fakeCapture()
    self.area:_expandCapture()
    HubLayers.SetPositionsLocked(true)
    self.area:Reposition()
    luaunit.assertFalse(self.area:IsDragging())
    luaunit.assertTrue(self.area._capture.clickthrough)
    luaunit.assertEquals(saved.x, 135)
    luaunit.assertEquals(saved.y, 115)
    luaunit.assertEquals(self.area._capture.x, 135)
    luaunit.assertEquals(self.area._capture.y, 115)
    luaunit.assertEquals(self.area._capture.w, Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(self.area._capture.h, Theme.INFOBOX_BOX_SIZE)
    luaunit.assertNil(self.area._capture.pw)
end

function TestDrag:testDragMovesAnchorByDelta()
    self.area:BeginDrag(105, 105)
    self.area:Drag(155, 205)
    local ax, ay = self.area:GetAnchor()
    luaunit.assertEquals(ax, 150)
    luaunit.assertEquals(ay, 200)
    local rects = self.area:Layout()
    luaunit.assertEquals(rects[1].x, 150)
    luaunit.assertEquals(rects[1].y, 200)
end

function TestDrag:testDragIgnoredWithoutBeginDrag()
    self.area:Drag(300, 300)
    local ax, ay = self.area:GetAnchor()
    luaunit.assertEquals(ax, 100)
    luaunit.assertEquals(ay, 100)
end

function TestDrag:testResetAnchorDropsTheDragAndPersistsTheDefault()
    local saved = {}
    self.area:SetPersistence({ SaveAnchor = function(x, y) saved.x, saved.y = x, y end })
    self.area:BeginDrag(105, 105)
    self.area:Drag(155, 205)
    self.area._capture = fakeCapture()
    self.area:_expandCapture()
    self.area:ResetAnchor()
    local ax, ay = self.area:GetAnchor()
    luaunit.assertEquals(ax, Theme.INFOBOX_DEFAULT_X)
    luaunit.assertEquals(ay, Theme.INFOBOX_DEFAULT_Y)
    luaunit.assertEquals(saved.x, 8)
    luaunit.assertEquals(saved.y, 8)
    luaunit.assertFalse(self.area:IsDragging())
    luaunit.assertEquals(self.area._capture.x, 8)
    luaunit.assertEquals(self.area._capture.y, 8)
    luaunit.assertEquals(self.area._capture.w, Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(self.area._capture.h, Theme.INFOBOX_BOX_SIZE)
end

function TestDrag:testEndDragPersistsAnchorThroughHook()
    local saved = {}
    self.area:SetPersistence({ SaveAnchor = function(x, y) saved.x, saved.y = x, y end })
    self.area:BeginDrag(105, 105)
    self.area:Drag(155, 205)
    self.area:EndDrag()
    luaunit.assertEquals(saved.x, 150)
    luaunit.assertEquals(saved.y, 200)
end

--- Node-facing helpers ---------------------------------------------------------------------

TestHelpers = {}

function TestHelpers:testResolveTextTostringsAnyValue()
    luaunit.assertEquals(InfoBox.ResolveText(5), "5")
    luaunit.assertEquals(InfoBox.ResolveText("hi"), "hi")
    luaunit.assertEquals(InfoBox.ResolveText(true), "true")
end

function TestHelpers:testResolveTextNilIsEmptyString()
    luaunit.assertEquals(InfoBox.ResolveText(nil), "")
end

function TestHelpers:testIsEmptyForNilZeroAndEmptyString()
    luaunit.assertTrue(InfoBox.IsEmpty(nil))
    luaunit.assertTrue(InfoBox.IsEmpty(0))
    luaunit.assertTrue(InfoBox.IsEmpty(""))
end

function TestHelpers:testIsNotEmptyForRealValues()
    luaunit.assertFalse(InfoBox.IsEmpty("0"))   -- the string "0" is a real value
    luaunit.assertFalse(InfoBox.IsEmpty(1))
    luaunit.assertFalse(InfoBox.IsEmpty("x"))
end
