local luaunit = require("luaunit")
local Resize = require("src/ui/window_resize")
local Multiplexer = require("src/ui/multiplexer")
local Dialog = require("src/ui/dialog")
local Editor = require("src/ui/graph")

local function component(parent)
    local c = { parent = parent, children = {}, x = 0, y = 0, width = 0, height = 0 }
    if parent then
        table.insert(parent.children, c)
    end
    function c:SetPos(x, y)
        self.x, self.y = x, y
    end
    function c:SetSize(w, h, wp, hp)
        self.width = w + (wp or 0) * (self.parent and self.parent.width or 0)
        self.height = h + (hp or 0) * (self.parent and self.parent.height or 0)
    end
    function c:MoveToFront()
        if not self.parent then
            return
        end
        local siblings = self.parent.children
        for i, item in ipairs(siblings) do
            if item == self then
                table.remove(siblings, i)
                break
            end
        end
        table.insert(siblings, self)
    end
    function c:Destroy()
        self.destroyed = true
        if not self.parent then
            return
        end
        for i, item in ipairs(self.parent.children) do
            if item == self then
                table.remove(self.parent.children, i)
                break
            end
        end
    end
    function c:Subscribe(hook, callback)
        self[hook] = callback
    end
    function c:AddLine() end
    function c:AddSprite() end
    function c:AddRectangle() end
    function c:AddGradientV() end
    function c:Clear() end
    return c
end

TestWindowChrome = {}
function TestWindowChrome:setUp()
    self.saved = { ui = ui, prettyui = prettyui, Mouse = Mouse, game = game, Vector4 = Vector4, config = config, id = id }
    id = { Sprite = { RS3_BTN_MODAL_WINDOW_1_CLOSE_NML = 1, RS3_BTN_MODAL_WINDOW_1_CLOSE_OVR = 2 } }
    config = { Cursor = { CURSOR_BLANK = { id = 23 } } }
    Vector4 = { new = function(...) return { ... } end }
    ui = {
        Layer = { new = component },
        Canvas = { new = component },
        Rectangle = { new = component },
        Hook = { ONCLICK = "click", ONHOLD = "hold", ONRELEASE = "release", ONDRAGCOMPLETE = "done",
            ONMOUSEOVER = "over", ONMOUSELEAVE = "leave" },
    }
    prettyui = { SimpleButton = {}, FancyButton = {
        getSize = function()
            return 80
        end,
    }, Window = {} }
    self.nativeButtons = {}
    local nativeButtons = self.nativeButtons
    function prettyui.SimpleButton.new(parent, label, action, options)
        local b = { root = component(parent), content = { content = label }, parts = {}, action = action, options = options }
        b.tooltip = { root = component(parent), options = {}, width = 240 }
        b.tooltip.root.hidden = true
        function b.tooltip:Show()
            self.root:SetPos(self.options.x, self.options.y)
            self.root.hidden = false
        end
        function b.tooltip:Hide() self.root.hidden = true end
        function b:SetTooltip(value)
            self.tooltip.options.text = value
        end
        function b:SetDisabled(disabled)
            self.disabled = disabled
            self.root.clickthrough = disabled
        end
        function b:Destroy()
            self.tooltip.root:Destroy()
            self.root:Destroy()
        end
        b:SetTooltip(options.tooltip.text)
        b.root:Subscribe(ui.Hook.ONCLICK, function() if not b.disabled then action() end end)
        nativeButtons[#nativeButtons + 1] = b
        return b
    end
    function prettyui.Window.new(parent, opts)
        local w =
            { root = component(parent), titleDrag = component(parent), onClose = opts.onClose, actions = {} }
        function w:Show()
            self.root:MoveToFront()
            self.titleDrag:MoveToFront()
        end
        function w:Destroy()
            self.root:Destroy()
            self.titleDrag:Destroy()
        end
        function w:Close()
            self.onClose()
            self:Destroy()
        end
        function w:AddFancyButton(label, action)
            self.actions[label] = action
        end
        return w
    end
    game = { options = { InterfaceScale = { setting = 200 } } }
    self.mouse = { x = 100, y = 100 }
    Mouse = {
        GetPosition = function()
            return self.mouse
        end,
    }
    self.parent = component()
    self.parent:SetSize(1920, 1080)
    self.window = { root = component(self.parent), titleDrag = component(self.parent) }
    self.window.root:SetPos(40, 60)
    self.window.root:SetSize(900, 560)
    function self.window:SetSize(w, h)
        self.root:SetSize(math.max(720, w), math.max(320, h))
    end
    self.overlay = component(self.parent)
    self.resize = Resize.new(self.window, self.parent, self.overlay)
    self.mux = Multiplexer.new({ window = self.window, overlay = self.overlay })
    self.mux._visible = true
    self.mux.resizeHandle = self.resize
    self.mux:SyncChrome()
end
local function childIndex(parent)
    local positions = {}
    for i, c in ipairs(parent.children) do
        positions[c] = i
    end
    return positions
end

local function modalDim(parent)
    for _, c in ipairs(parent.children) do
        local rect = c.children and c.children[1]
        local colour = rect and rect.colour
        if colour and colour[4] == Dialog.DIM_ALPHA then
            return c
        end
    end
end

function TestWindowChrome:tearDown()
    Dialog.dismissAll(self.overlay)
    Dialog.dismissAll(self.parent)
    self.resize:Destroy()
    luaunit.assertTrue(self.resize.maxIcon.destroyed)
    ui, prettyui, Mouse, game, Vector4, config, id = self.saved.ui, self.saved.prettyui, self.saved.Mouse, self.saved.game, self.saved.Vector4, self.saved.config, self.saved.id
end
function TestWindowChrome:testMaximizeUsesNativeButtonAndToolbarCursor()
    luaunit.assertEquals(#self.nativeButtons, 1)
    local button = self.nativeButtons[1]
    luaunit.assertIs(self.resize.maxHit, button.root)
    luaunit.assertEquals({ button.options.width, button.options.height }, { 20, 20 })
    luaunit.assertIs(button.options.hoverCursor, config.Cursor.CURSOR_BLANK)
    luaunit.assertEquals(button.tooltip.options.text, "Maximize window")
    luaunit.assertIs(self.resize.maxIcon.parent, self.overlay)
    luaunit.assertTrue(self.resize.maxIcon.clickthrough)
end
function TestWindowChrome:testButtonClickUpdatesTooltipAndRestoresBounds()
    self.resize.maxHit.click()
    luaunit.assertEquals(self.resize.maxButton.tooltip.options.text, "Restore previous size")
    luaunit.assertEquals({ self.window.root.width, self.window.root.height }, { 1920, 1080 })
    self.resize.maxHit.click()
    luaunit.assertEquals(self.resize.maxButton.tooltip.options.text, "Maximize window")
    luaunit.assertEquals(
        { self.window.root.x, self.window.root.y, self.window.root.width, self.window.root.height },
        { 40, 60, 900, 560 }
    )
end
function TestWindowChrome:testModalDisablesButtonAndHidesItsTooltip()
    self.resize.maxButton.tooltip:Show()
    local win = Dialog.mount(self.overlay, { title = "Rename" })
    self.mux:SyncChrome()
    luaunit.assertTrue(self.resize.maxButton.disabled)
    luaunit.assertTrue(self.resize.maxButton.tooltip.root.hidden)
    self.resize.maxHit.click()
    luaunit.assertNil(self.resize.normalBounds)
    win:Close()
    self.mux:SyncChrome()
    luaunit.assertFalse(self.resize.maxButton.disabled)
end
function TestWindowChrome:testResizeUsesInterfaceScaleAndClampsMinimum()
    self.resize:Begin()
    self.mouse.x, self.mouse.y = 300, 200
    self.resize:Drag()
    luaunit.assertEquals({ self.window.root.width, self.window.root.height }, { 1000, 610 })
    self.resize:Finish()
    self.resize:Begin()
    self.mouse.x, self.mouse.y = -5000, -5000
    self.resize:Drag()
    luaunit.assertEquals({ self.window.root.width, self.window.root.height }, { 720, 320 })
    self.resize:Sync(false)
    luaunit.assertNil(self.resize.start)
    luaunit.assertTrue(self.resize.grip.hidden)
    luaunit.assertTrue(self.resize.maxIcon.hidden)
end
function TestWindowChrome:testMaximizeTracksViewportAndRestoresPreviousBounds()
    self.resize:ToggleMaximize()
    luaunit.assertEquals(
        { self.window.root.x, self.window.root.y, self.window.root.width, self.window.root.height },
        { 0, 0, 1920, 1080 }
    )
    luaunit.assertTrue(self.resize.grip.hidden)
    luaunit.assertTrue(self.window.titleDrag.hidden)
    self.parent:SetSize(1600, 900)
    self.resize:Sync(true)
    luaunit.assertEquals(self.window.root.width, 1600)
    self.resize:ToggleMaximize()
    luaunit.assertEquals(
        { self.window.root.x, self.window.root.y, self.window.root.width, self.window.root.height },
        { 40, 60, 900, 560 }
    )
    luaunit.assertFalse(self.window.titleDrag.hidden)
end
function TestWindowChrome:testChromeFollowsWindowDuringTitleDragRestack()
    self.window.root:SetPos(120, 90)
    self.window.root:MoveToFront()
    self.mux:SyncChrome()
    luaunit.assertEquals(
        { self.resize.maxHit.x, self.resize.maxHit.y, self.resize.maxHit.width, self.resize.maxHit.height },
        { 120 + 900 - 34 - 20, 90 + 7, 20, 20 }
    )
    luaunit.assertEquals(
        { self.resize.maxIcon.x, self.resize.maxIcon.y, self.resize.maxIcon.width, self.resize.maxIcon.height },
        { 120 + 900 - 34 - 20, 90 + 6, 21, 21 }
    )
    luaunit.assertFalse(self.resize.maxIcon.hidden)
    luaunit.assertEquals(
        { self.resize.grip.x, self.resize.grip.y },
        { 120 + 900 - 20, 90 + 560 - 20 }
    )
    local positions = {}
    for i, c in ipairs(self.parent.children) do
        positions[c] = i
    end
    luaunit.assertTrue(positions[self.window.root] < positions[self.overlay])
end
function TestWindowChrome:testSyncChromeDoesNotCollapseExpandedTitleDrag()
    self.window.titleDrag:SetPos(0, 0)
    self.window.titleDrag:SetSize(0, 0, 1.0, 1.0)
    self.window.root:MoveToFront()
    self.mux:SyncChrome()
    luaunit.assertEquals(
        { self.window.titleDrag.x, self.window.titleDrag.y, self.window.titleDrag.width, self.window.titleDrag.height },
        { 0, 0, 1920, 1080 }
    )
    local positions = {}
    for i, c in ipairs(self.parent.children) do
        positions[c] = i
    end
    luaunit.assertTrue(positions[self.overlay] < positions[self.window.titleDrag])
end
function TestWindowChrome:testModalBlocksEditorInput()
    local capture = component(self.overlay)
    local valid = false
    local win = Dialog.mount(
        self.overlay,
        { actions = { {
            label = "Save",
            onClick = function()
                return valid
            end,
        } } }
    )
    local editor = setmetatable(
        { overlayParent = self.overlay, capture = capture, pressed = true, wire = {}, palette = {} },
        Editor
    )
    editor:frontOverlayInteractives()
    editor:update()
    editor:beginPress()
    editor:onScroll(1)
    luaunit.assertFalse(editor.pressed)
    luaunit.assertNil(editor.wire)
    win.actions.Save()
    luaunit.assertEquals(Dialog.depth(self.overlay), 1)
    valid = true
    win.actions.Save()
    luaunit.assertEquals(Dialog.depth(self.overlay), 0)
end
function TestWindowChrome:testSyncChromeKeepsDialogListScroll()
    local win = Dialog.mount(self.overlay, { title = "Variables" })
    local dropdown = component(self.overlay)
    local scrollY = 48
    win.overlays = {
        [dropdown] = {
            isVisible = function() return true end,
            layout = function() scrollY = 0 end,
        },
    }
    function win:Show()
        self.root:MoveToFront()
        self.titleDrag:MoveToFront()
        for _, overlay in pairs(self.overlays) do overlay.layout() end
    end
    self.mux:SyncChrome()
    luaunit.assertEquals(scrollY, 48)
    local positions = childIndex(self.overlay)
    luaunit.assertTrue(positions[win.root] < positions[dropdown])
    luaunit.assertTrue(positions[win.titleDrag] < positions[dropdown])
end
function TestWindowChrome:testSyncChromeKeepsOverlayModalAboveMaximizeAndGrip()
    local win = Dialog.mount(self.overlay, { title = "Rename" })
    self.mux:SyncChrome()
    self.mux:SyncChrome()
    local positions = childIndex(self.overlay)
    local dim = modalDim(self.overlay)
    luaunit.assertNotNil(dim)
    luaunit.assertTrue(positions[self.resize.maxHit] < positions[dim])
    luaunit.assertTrue(positions[self.resize.maxIcon] < positions[dim])
    luaunit.assertTrue(positions[self.resize.grip] < positions[dim])
    luaunit.assertTrue(positions[dim] < positions[win.root])
end

function TestWindowChrome:testGripClickDuringModalDoesNotRaiseChrome()
    local win = Dialog.mount(self.overlay, { title = "Rename" })
    self.resize.grip.click()
    self.resize.grip.release()
    local positions = childIndex(self.overlay)
    local dim = modalDim(self.overlay)
    luaunit.assertNil(self.resize.start)
    luaunit.assertEquals(self.resize.grip.width, 20)
    luaunit.assertTrue(self.resize.grip.clickthrough)
    luaunit.assertTrue(self.resize.maxHit.clickthrough)
    luaunit.assertTrue(positions[self.resize.maxHit] < positions[dim])
    luaunit.assertTrue(positions[self.resize.grip] < positions[dim])
    luaunit.assertTrue(positions[dim] < positions[win.root])
end

function TestWindowChrome:testSyncChromeKeepsRootModalAboveOverlay()
    self.mux.rootLayer = self.parent
    local win = Dialog.mount(self.parent, { title = "Delete" })
    self.mux:SyncChrome()
    local positions = childIndex(self.parent)
    local dim = modalDim(self.parent)
    luaunit.assertNotNil(dim)
    luaunit.assertTrue(positions[self.overlay] < positions[dim])
    luaunit.assertTrue(positions[dim] < positions[win.root])
end

function TestWindowChrome:testModalDimSitsUnderTopmostDialog()
    local bottom = Dialog.mount(self.overlay, { title = "Bottom" })
    local top = Dialog.mount(self.overlay, { title = "Top" })
    local positions = childIndex(self.overlay)
    local dim = modalDim(self.overlay)
    luaunit.assertNotNil(dim)
    luaunit.assertTrue(positions[bottom.root] < positions[dim])
    luaunit.assertTrue(positions[dim] < positions[top.root])
    top:Close()
    positions = childIndex(self.overlay)
    dim = modalDim(self.overlay)
    luaunit.assertNotNil(dim)
    luaunit.assertTrue(positions[dim] < positions[bottom.root])
end

function TestWindowChrome:testModalDimStaysUnderHighestModal()
    local under = Dialog.mount(self.overlay, { title = "Under", modal = false })
    local modal = Dialog.mount(self.overlay, { title = "Modal" })
    local over = Dialog.mount(self.overlay, { title = "Over", modal = false })
    local positions = childIndex(self.overlay)
    local dim = modalDim(self.overlay)
    luaunit.assertNotNil(dim)
    luaunit.assertTrue(positions[under.root] < positions[dim])
    luaunit.assertTrue(positions[dim] < positions[modal.root])
    luaunit.assertTrue(positions[modal.root] < positions[over.root])
end

function TestWindowChrome:testSyncChromeRaisesOverlayTooltipAboveMaximize()
    local tipRoot = component(self.overlay)
    tipRoot.hidden = false
    self.mux:Push({
        id = "editor",
        FrontOverlayPopups = function()
            tipRoot:MoveToFront()
        end,
    })
    self.mux:SyncChrome()
    local positions = {}
    for i, c in ipairs(self.overlay.children) do
        positions[c] = i
    end
    luaunit.assertTrue(positions[self.resize.maxHit] < positions[tipRoot])
    luaunit.assertTrue(positions[self.resize.maxIcon] < positions[tipRoot])
end
function TestWindowChrome:testTooltipKeepsNativePlacementAcrossMaximizeAndRestore()
    local tip = self.resize.maxButton.tooltip
    luaunit.assertNil(self.resize.maxButton.options.tooltip.placement)
    tip:Show()
    self.resize:Sync(true)
    luaunit.assertNil(tip.options.x)
    luaunit.assertNil(tip.options.y)
    self.resize:ToggleMaximize()
    self.resize:Sync(true)
    luaunit.assertNil(tip.options.x)
    luaunit.assertNil(tip.options.y)
    self.resize:ToggleMaximize()
    luaunit.assertNil(tip.options.x)
    luaunit.assertNil(tip.options.y)
    self.resize:Sync(false)
    luaunit.assertTrue(tip.root.hidden)
end

function TestWindowChrome:testGraphCanvasFillsContentParent()
    local content = component(nil)
    content:SetSize(900, 550)
    local editor = setmetatable({}, Editor)
    for _, method in ipairs({
        "syncContentOrigin",
        "mountToolbar",
        "positionCapture",
        "frontOverlayInteractives",
        "resetView",
        "SetVisible",
    }) do
        editor[method] = function() end
    end
    editor:Mount(content, self.overlay)
    luaunit.assertEquals(editor.canvas.parent, content)
    luaunit.assertEquals({ editor.canvas.x, editor.canvas.y }, { 0, 0 })
    luaunit.assertNil(editor.canvasViewport)
end

function TestWindowChrome:testPaletteStaysAboveResizeGripUntilClosed()
    local editor = Editor.new({}, nil)
    editor.overlayParent = self.overlay
    editor.capture = component(self.overlay)
    editor.paletteCanvas = component(self.overlay)
    self.mux:Push({
        id = "editor",
        FrontOverlayPopups = function() editor:FrontOverlayPopups() end,
    })
    editor.palette.open = true
    for _ = 1, 2 do
        self.mux:SyncChrome()
        local positions = {}
        for i, c in ipairs(self.overlay.children) do positions[c] = i end
        luaunit.assertTrue(positions[self.resize.grip] < positions[editor.capture])
        luaunit.assertTrue(positions[editor.capture] < positions[editor.paletteCanvas])
    end
    editor:closePalette()
    self.mux:SyncChrome()
    luaunit.assertEquals(self.overlay.children[#self.overlay.children], self.resize.grip)
    self.resize:Begin()
    luaunit.assertNotNil(self.resize.start)
end
