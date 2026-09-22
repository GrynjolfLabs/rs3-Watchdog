local luaunit = require("luaunit")
local Resize = require("ui/window_resize")
local Multiplexer = require("ui/multiplexer")
local Dialog = require("ui/dialog")
local Editor = require("ui/graph")

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
    return c
end

TestWindowChrome = {}
function TestWindowChrome:setUp()
    self.saved = { ui = ui, prettyui = prettyui, Mouse = Mouse, game = game }
    ui = {
        Layer = { new = component },
        Canvas = { new = component },
        Rectangle = { new = component },
        Hook = { ONCLICK = "click", ONHOLD = "hold", ONRELEASE = "release", ONDRAGCOMPLETE = "done" },
    }
    prettyui = { SimpleButton = {}, FancyButton = {
        getSize = function()
            return 80
        end,
    }, Window = {} }
    function prettyui.SimpleButton.new(parent, label, action)
        local b = { root = component(parent), content = { content = label }, action = action }
        function b:SetTooltip(options)
            self.tooltipOptions = options
        end
        function b:Destroy()
            self.root:Destroy()
        end
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
    self.resize = Resize.new(self.window, self.parent)
    self.mux = Multiplexer.new({ window = self.window, overlay = self.overlay })
    self.mux._visible = true
    self.mux.resizeHandle = self.resize
    self.mux:SyncChrome()
end
function TestWindowChrome:tearDown()
    Dialog.dismissAll(self.overlay)
    self.resize:Destroy()
    ui, prettyui, Mouse, game = self.saved.ui, self.saved.prettyui, self.saved.Mouse, self.saved.game
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
function TestWindowChrome:testDraggingKeepsEditorAboveWindowAndCaptureAboveEditor()
    for _ = 1, 3 do
        self.window.root:MoveToFront()
        self.mux:SyncChrome()
        local positions = {}
        for i, c in ipairs(self.parent.children) do
            positions[c] = i
        end
        luaunit.assertTrue(positions[self.window.root] < positions[self.overlay])
        luaunit.assertTrue(positions[self.overlay] < positions[self.window.titleDrag])
    end
    self.window.titleDrag:SetSize(1920, 1080)
    self.mux:SyncChrome()
    luaunit.assertEquals(self.window.titleDrag.width, 1920)
end
function TestWindowChrome:testModalStaysAboveCaptureAndBlocksCanvas()
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
    for _ = 1, 3 do
        capture:MoveToFront()
        self.mux:SyncChrome()
        editor:frontOverlayInteractives()
        local children = self.overlay.children
        luaunit.assertEquals(children[#children], win.titleDrag)
        luaunit.assertEquals(children[#children - 1], win.root)
        luaunit.assertFalse(children[#children - 2].clickthrough)
    end
    luaunit.assertTrue(self.resize.maxButton.root.hidden)
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
    self.mux:SyncChrome()
    luaunit.assertFalse(self.resize.maxButton.root.hidden)
    win = Dialog.mount(self.overlay, {})
    editor:onEscape()
    luaunit.assertEquals(Dialog.depth(self.overlay), 0)
end
function TestWindowChrome:testTooltipStaysBelowMaximizeAndRestore()
    local tip = { root = component(self.parent), options = {}, width = 240 }
    function tip:Show()
        self.root:SetPos(self.options.x, self.options.y)
    end
    function tip:Hide()
        self.root.hidden = true
    end
    self.resize.maxButton.tooltip = tip
    self.resize:Sync(true)
    luaunit.assertEquals({ tip.root.x, tip.root.y }, { 660, 95 })
    self.resize:ToggleMaximize()
    self.resize:Sync(true)
    luaunit.assertEquals({ tip.root.x, tip.root.y }, { 1640, 35 })
    self.resize:Sync(false)
    luaunit.assertTrue(tip.root.hidden)
end

function TestWindowChrome:testGraphCanvasHasSeparateViewportBelowToolbar()
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
    local viewport = editor.canvasViewport
    luaunit.assertEquals(viewport.parent, content)
    luaunit.assertEquals(editor.canvas.parent, viewport)
    luaunit.assertEquals({ viewport.x, viewport.y, viewport.width, viewport.height }, { 0, 84, 900, 466 })
    -- Keep rendering and hit testing in the same content coordinate system.
    luaunit.assertEquals(viewport.y + editor.canvas.y, 0)
    luaunit.assertEquals(editor.canvas.height, content.height)
end
