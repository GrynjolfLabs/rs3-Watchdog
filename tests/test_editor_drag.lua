-- Exercise the mounted capture hooks, real hit-tests, update and Canvas draw path.
local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Editor = require("ui/graph")

local function component(parent)
    local c = { parent = parent, x = 0, y = 0, width = 0, height = 0, hooks = {}, lines = {}, rects = {} }
    function c:SetPos(x, y) self.x, self.y = x, y end
    function c:SetSize(w, h, wp, hp)
        self.width = w + (wp or 0) * (self.parent and self.parent.width or 0)
        self.height = h + (hp or 0) * (self.parent and self.parent.height or 0)
    end
    function c:Subscribe(hook, callback) self.hooks[hook] = callback end
    function c:MoveToFront() end
    function c:Destroy() end
    function c:Clear() self.lines, self.rects = {}, {} end
    function c:AddLine(...) self.lines[#self.lines + 1] = { ... } end
    function c:AddRectangle(...) self.rects[#self.rects + 1] = { ... } end
    function c:AddOutline() end
    function c:AddTriangle() end
    function c:AddText() end
    return c
end

local function absolutePosition(c)
    local x, y = c.x, c.y
    while c.parent do
        c = c.parent
        x, y = x + c.x, y + c.y
    end
    return x, y
end

TestEditorDrag = {}
function TestEditorDrag:setUp()
    self.saved = { ui = ui, prettyui = prettyui, Mouse = Mouse, game = game, LibNodeGraph = LibNodeGraph, Vector4 = Vector4 }
    Vector4 = { new = function(...) return { ... } end }
    LibNodeGraph = { UNKNOWN_TYPE = "__unknown" }
    ui = {
        Canvas = { new = component }, Button = { new = component }, Layer = { new = component },
        TextDataConfig = { new = function() return {} end },
        Hook = { ONCLICK = "click", ONRELEASE = "release", ONHOLD = "hold",
            ONMOUSEOVER = "over", ONMOUSEREPEAT = "repeat", ONSCROLLWHEEL = "wheel",
            ONMOUSELEAVE = "leave", ONDRAGCOMPLETE = "done" },
    }
    prettyui = {
        Tooltip = { getContext = function() return { position = absolutePosition } end },
        SpriteButton = { new = function(parent) return { root = component(parent), Destroy = function() end } end },
    }
    self.raw = { x = 0, y = 0 }
    Mouse = { GetPosition = function() return self.raw end }
    game = { options = { InterfaceScale = { setting = 100 } } }
    local registry = Registry.new()
    registry:RegisterNodeType("fixture.source", {
        category = "pure", pins = { { name = "out", kind = "data", direction = "out", dataType = "number" } },
        run = function(ctx) ctx:Out("out", 0) end,
    })
    registry:RegisterNodeType("fixture.target", {
        category = "action", pins = { { name = "in", kind = "data", direction = "in", dataType = "number" } },
        run = function() end,
    })
    self.graph = Graph.new(registry)
    self.source = self.graph:AddNode("fixture.source")
    self.target = self.graph:AddNode("fixture.target")
    self.editor = Editor.new(registry)
    self.editor:BindEntry(1, self.graph, { [self.source] = { x = 120, y = 180 }, [self.target] = { x = 480, y = 180 } })
    local overlay = component()
    overlay:SetSize(1920, 1080)
    local container = component(overlay)
    container:SetPos(40, 50)
    self.content = component(container)
    self.content:SetPos(40, 50)
    self.content:SetSize(1000, 700)
    self.editor:Mount(self.content, overlay)
    self.editor:SetVisible(true)
end

function TestEditorDrag:tearDown()
    self.editor:Unmount()
    ui, prettyui, Mouse, game, LibNodeGraph = self.saved.ui, self.saved.prettyui, self.saved.Mouse, self.saved.game, self.saved.LibNodeGraph
    Vector4 = self.saved.Vector4
end

function TestEditorDrag:pointAt(x, y, scale)
    local ox, oy = absolutePosition(self.content)
    self.uiX, self.uiY = ox + x, oy + y
    self.raw.x, self.raw.y = self.uiX * scale, self.uiY * scale
    -- Deliver one native input pass. Raw coordinates may have a different OS
    -- scale, but the client's hook coordinates are already interface units.
    local e = self.editor
    e:update()
    local hook = e.capture.hooks[e.pressed and "hold" or "repeat"]
    if hook then hook(e.capture, self.uiX - e.capture.x, self.uiY - e.capture.y) end
end

function TestEditorDrag:release()
    local e = self.editor
    e:update()
    e.capture.hooks.release(e.capture, self.uiX - e.capture.x, self.uiY - e.capture.y)
end

function TestEditorDrag:prepare(zoom, iface, osScale, kind)
    local e = self.editor
    e:resetView()
    e.view.zoom = zoom
    game.options.InterfaceScale.setting = iface * 100
    e.layout[self.source].x, e.layout[self.source].y = 120, 180
    e:buildGeoms()
    local gx, gy = 160, 192 -- header grab, away from close button and pins
    if kind ~= "node" then
        local geom = e.geoms[self.source]
        local pin = geom.byName.out
        if kind == "reconnect" then
            self.graph:Connect(self.source, "out", self.target, "in")
            geom = e.geoms[self.target]
            pin = geom.byName["in"]
        end
        gx, gy = geom.x + pin.cx, geom.y + pin.cy
    end
    e.view.panX, e.view.panY = 160 - gx * zoom, 200 - gy * zoom
    self:pointAt(160, 200, iface * osScale)
    e.capture.hooks.click(e.capture, 160, 200)
    luaunit.assertEquals(e.mode, kind == "node" and "dragnode" or "wire")
    if kind ~= "node" then
        luaunit.assertEquals(e.wire.nodeId, self.source)
        luaunit.assertEquals(#self.graph:GetConnections(), 0)
    end
    luaunit.assertEquals({ e.capture.x, e.capture.y }, { 0, 0 })
    luaunit.assertEquals({ e.window.x, e.window.y }, { absolutePosition(self.content) })
end

local function assertPoint(x, y, expectedX, expectedY)
    luaunit.assertAlmostEquals(x, expectedX, 1e-7)
    luaunit.assertAlmostEquals(y, expectedY, 1e-7)
end

function TestEditorDrag:assertFrame(kind, dx, dy, zoom)
    local e = self.editor
    e:draw()
    assertPoint(e.mouse.x, e.mouse.y, 160 + dx, 200 + dy)
    if kind == "node" then
        assertPoint(e.layout[self.source].x, e.layout[self.source].y, 120 + dx / zoom, 180 + dy / zoom)
        e:draw()
        -- The grabbed node is brought to the front, so its body draws last.
        local body
        local geom = e.geoms[self.source]
        for _, rect in ipairs(e.canvas.rects) do
            if rect[3] == geom.w * zoom and rect[4] == geom.h * zoom then body = rect end
        end
        luaunit.assertNotNil(body)
        assertPoint(body[1], body[2], 160 - 40 * zoom + dx, 200 - 12 * zoom + dy)
    else
        e.canvas:Clear()
        e:drawPendingWire()
        local endpoint = e.canvas.lines[#e.canvas.lines]
        luaunit.assertNotNil(endpoint)
        assertPoint(endpoint[3], endpoint[4], 160 + dx, 200 + dy)
        assertPoint(e.layout[self.source].x, e.layout[self.source].y, 120, 180)
    end
end

function TestEditorDrag:runMatrix(kind, queuedHook)
    for _, iface in ipairs({ 1, 1.25, 1.5, 2 }) do
        for _, osScale in ipairs({ 1, 1.25, 2 }) do
            for _, zoom in ipairs({ 0.25, 1, 2 }) do
                self:prepare(zoom, iface, osScale, kind)
                -- A queued event still has local coordinates from BEFORE expandCapture().
                local queued = self.editor.capture.hooks[queuedHook]
                if queued then queued(self.editor.capture, 160, 200) end
                self:assertFrame(kind, 0, 0, zoom)
                self:pointAt(184, 218, iface * osScale)
                self:assertFrame(kind, 24, 18, zoom)
                local e = self.editor
                if kind ~= "node" then
                    local geom = e.geoms[self.target]
                    local pin = geom.byName["in"]
                    local x = (geom.x + pin.cx) * zoom + e.view.panX
                    local y = (geom.y + pin.cy) * zoom + e.view.panY
                    self:pointAt(x, y, iface * osScale)
                    e:update()
                end
                self:release()
                if kind ~= "node" then
                    local connections = self.graph:GetConnections()
                    luaunit.assertEquals(#connections, 1)
                    luaunit.assertEquals({ connections[1].fromNode, connections[1].toNode }, { self.source, self.target })
                    self.graph:Disconnect(connections[1].id)
                end
                luaunit.assertFalse(self.editor.pressed)
                luaunit.assertEquals(self.editor.mode, "idle")
                luaunit.assertEquals({ self.editor.capture.x, self.editor.capture.y }, { 80, 100 })
                self.editor.palette:Close()
            end
        end
    end
end

function TestEditorDrag:testNodeFirstFrameWithQueuedHoldAcrossScalingAndZoom()
    self:runMatrix("node", "hold")
end
function TestEditorDrag:testWireFirstFrameWithQueuedHoldAcrossScalingAndZoom()
    self:runMatrix("wire", "hold")
end
function TestEditorDrag:testNodeFirstFrameWithQueuedHoverAcrossScalingAndZoom()
    self:runMatrix("node", "repeat")
end
function TestEditorDrag:testWireFirstFrameWithQueuedHoverAcrossScalingAndZoom()
    self:runMatrix("wire", "over")
end

function TestEditorDrag:testReconnectFirstFrameWithQueuedHoldAcrossScalingAndZoom()
    self:runMatrix("reconnect", "hold")
end
function TestEditorDrag:testReconnectFirstFrameWithQueuedHoverAcrossScalingAndZoom()
    self:runMatrix("reconnect", "repeat")
end

function TestEditorDrag:testNativeCoordinatesSurviveRawScaleChangeBetweenPresses()
    self:prepare(1, 1, 2, "node")
    self:release()
    self:pointAt(160, 200, 1.25)
    self.editor.capture.hooks.click(self.editor.capture, 160, 200)
    self:assertFrame("node", 0, 0, 1)
end

function TestEditorDrag:testDragToCreateKeepsNativePointerUntilPaletteCloses()
    self:prepare(1, 1, 2, "wire")
    self:pointAt(184, 218, 2)
    self.editor:update()
    self:release()
    luaunit.assertTrue(self.editor.palette.open)
    luaunit.assertFalse(self.editor.pressed)
    local hover = self.editor.capture.hooks["repeat"]
    if hover then hover(self.editor.capture, self.uiX, self.uiY) end
    self.editor:update()
    self.editor:draw()
    assertPoint(self.editor.mouse.x, self.editor.mouse.y, 184, 218)
    self.editor:closePalette()
    luaunit.assertEquals({ self.editor.capture.x, self.editor.capture.y }, { 80, 100 })
end

function TestEditorDrag:testNodeRendersEachNativeMovementWithoutDrawAdvancingClock()
    self:prepare(1, 1, 1, "node")
    local e = self.editor
    for frame = 1, 30 do
        self:pointAt(160 + frame * 2, 200 + frame, 1)
        local tick = e.tick
        e:draw()
        luaunit.assertEquals(e.tick, tick, "Draw must not advance the double-click Logic clock")
        assertPoint(e.layout[self.source].x, e.layout[self.source].y, 120 + frame * 2, 180 + frame)
    end
end

function TestEditorDrag:testWireRendersEachNativeMovementWithoutDrawAdvancingClock()
    self:prepare(1, 1, 1, "wire")
    local e = self.editor
    for frame = 1, 30 do
        self:pointAt(160 + frame * 2, 200 + frame, 1)
        e:draw()
        local endpoint = e.canvas.lines[#e.canvas.lines]
        assertPoint(endpoint[3], endpoint[4], 160 + frame * 2, 200 + frame)
    end
end

function TestEditorDrag:testResizeUsesNativeCoordinatesRegardlessOfRawOSScale()
    local Resize = require("ui/window_resize")
    ui.Layer = { new = component }
    ui.Hook.ONMOUSELEAVE, ui.Hook.ONDRAGCOMPLETE = "leave", "done"
    local overlay = self.editor.overlayParent
    local window = { root = component(overlay), titleDrag = component(overlay), minWidth = 720, minHeight = 320 }
    window.root:SetPos(80, 100)
    window.root:SetSize(1000, 700)
    function window:SetSize(w, h) self.root:SetSize(w, h) end
    local resize = Resize.new(window, overlay, overlay)
    resize:Sync(true)
    local gx, gy = resize.grip.x, resize.grip.y
    self.raw.x, self.raw.y = (gx + 10) * 2, (gy + 10) * 2
    resize:BeginInputBatch()
    resize.grip.hooks.click(resize.grip, 10, 10)
    self.raw.x, self.raw.y = (gx + 40) * 2, (gy + 30) * 2
    resize.grip.hooks.hold(resize.grip, 40, 30)
    assertPoint(window.root.width, window.root.height, 1030, 720)
    resize:Destroy()
end

function TestEditorDrag:testDrawSynchronizesCaptureAfterResizeBeforeNextLogicTick()
    local e = self.editor
    self.content.parent:SetPos(100, 120)
    self.content:SetSize(750, 480)
    e:draw()
    luaunit.assertEquals({ e.capture.x, e.capture.y, e.capture.width, e.capture.height }, { 140, 170, 750, 480 })
end

function TestEditorDrag:testReleaseCommitsNativePointerBeforeNextDraw()
    self:prepare(1, 1, 1, "wire")
    local e = self.editor
    local geom = e.geoms[self.target]
    local pin = geom.byName["in"]
    self:pointAt((geom.x + pin.cx) + e.view.panX, (geom.y + pin.cy) + e.view.panY, 1)
    self:release()
    luaunit.assertEquals(#self.graph:GetConnections(), 1)
end

function TestEditorDrag:testResizeThenDragNativeEventMatrix()
    local Resize = require("ui/window_resize")
    local Multiplexer = require("ui/multiplexer")
    local e = self.editor
    local window = { root = self.content.parent, titleDrag = component(e.overlayParent), minWidth = 720, minHeight = 320 }
    function window:SetSize(w, h)
        self.root:SetSize(w, h)
        e.contentParent:SetSize(w - 80, h - 80)
    end
    window:SetSize(1080, 780)
    local resize = Resize.new(window, e.overlayParent, e.overlayParent)
    local mux = Multiplexer.new({ window = window, overlay = e.overlayParent })
    mux._visible, mux.resizeHandle = true, resize
    for _, iface in ipairs({ 1, 1.25, 1.5, 2 }) do
        for _, osScale in ipairs({ 1, 1.25, 2 }) do
            for _, zoom in ipairs({ 0.25, 1, 2 }) do
                for _, kind in ipairs({ "node", "wire", "reconnect" }) do
                    local scale = iface * osScale
                    game.options.InterfaceScale.setting = iface * 100
                    window.root:SetPos(175, 125)
                    window:SetSize(1080, 780)
                    mux:SyncChrome()
                    local gripX, gripY = resize.grip.x + 10, resize.grip.y + 10
                    self.raw.x, self.raw.y = gripX * scale, gripY * scale
                    resize:BeginInputBatch()
                    resize.grip.hooks.click(resize.grip, 10, 10)
                    local tick = e.tick
                    for frame = 1, 6 do
                        self.raw.x, self.raw.y = (gripX + frame * 5) * scale, (gripY + frame * 3) * scale
                        resize:BeginInputBatch()
                        resize.grip.hooks.hold(resize.grip, gripX + frame * 5, gripY + frame * 3)
                        e:draw()
                        mux:SyncChrome()
                        assertPoint(window.root.width, window.root.height, 1080 + frame * 5, 780 + frame * 3)
                        luaunit.assertEquals(e.capture.width, window.root.width - 80)
                    end
                    -- A release after the last rendered frame must retain the final delta.
                    self.raw.x, self.raw.y = (gripX + 35) * scale, (gripY + 21) * scale
                    resize:BeginInputBatch()
                    resize.grip.hooks.release(resize.grip, gripX + 35, gripY + 21)
                    assertPoint(window.root.width, window.root.height, 1115, 801)
                    e:draw()
                    luaunit.assertEquals(e.tick, tick)
                    self:prepare(zoom, iface, osScale, kind)
                    for frame = 0, 6 do
                        self:pointAt(160 + frame * 3, 200 + frame * 2, scale)
                        e:draw()
                        assertPoint(e.mouse.x, e.mouse.y, 160 + frame * 3, 200 + frame * 2)
                        if kind == "node" then
                            assertPoint(e.layout[self.source].x, e.layout[self.source].y,
                                120 + frame * 3 / zoom, 180 + frame * 2 / zoom)
                        else
                            local endpoint = e.canvas.lines[#e.canvas.lines]
                            assertPoint(endpoint[3], endpoint[4], 160 + frame * 3, 200 + frame * 2)
                        end
                    end
                    if kind ~= "node" then
                        local geom = e.geoms[self.target]
                        local pin = geom.byName["in"]
                        self:pointAt((geom.x + pin.cx) * zoom + e.view.panX,
                            (geom.y + pin.cy) * zoom + e.view.panY, scale)
                    end
                    self:release()
                    if kind ~= "node" then
                        local connections = self.graph:GetConnections()
                        luaunit.assertEquals(#connections, 1)
                        self.graph:Disconnect(connections[1].id)
                    end
                end
            end
        end
    end
    resize:Destroy()
end

function TestEditorDrag:testWindowMoveDuringNodeDragKeepsGrabPointUnderPointer()
    self:prepare(1, 1, 2, "node")
    local e = self.editor
    self.content.parent:SetPos(80, 100)
    self.content:SetSize(750, 480)
    e:draw()
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 80, 130)
    assertPoint(e.mouse.x, e.mouse.y, 120, 150)
    -- The graph moved opposite the window movement, preserving the physical grab point.
    assertPoint(e.window.x + e.mouse.x, e.window.y + e.mouse.y, 240, 300)
end

function TestEditorDrag:testReleaseCommitsNativeNodePositionWithoutWaitingForFrame()
    self:prepare(1, 1, 2, "node")
    self:pointAt(190, 220, 2)
    self:release()
    assertPoint(self.editor.layout[self.source].x, self.editor.layout[self.source].y, 150, 200)
end

function TestEditorDrag:testQueuedHoverAfterWindowMoveCannotRecalibratePointer()
    self:prepare(1, 1, 2, "node")
    local e = self.editor
    self:release()
    self.content.parent:SetPos(140, 175)
    e:update() -- Capture still has its prior origin for this queued event batch.
    local hover = e.capture.hooks["repeat"]
    if hover then hover(e.capture, 160, 200) end
    e:draw()
    assertPoint(e.mouse.x, e.mouse.y, 60, 75)
end

-- Native drag completion is distinct from the ordinary release hook.
function TestEditorDrag:testNativeDragCompleteStopsNodeBeforeSubsequentPointerMovement()
    self:prepare(1, 1, 2, "node")
    local e = self.editor
    self:pointAt(190, 220, 2)
    local complete = e.capture.hooks.done
    if complete then complete(e.capture, nil, 190, 220) end
    luaunit.assertFalse(e.pressed, "native drag-complete must end the gesture")
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 150, 200)
    self:pointAt(400, 450, 2)
    for _ = 1, 5 do e:draw(); e:update() end
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 150, 200)
end

function TestEditorDrag:testNativeDragCompleteCommitsWireExactlyOnce()
    self:prepare(1, 1, 2, "wire")
    local e = self.editor
    local geom = e.geoms[self.target]
    local pin = geom.byName["in"]
    self:pointAt(geom.x + pin.cx + e.view.panX, geom.y + pin.cy + e.view.panY, 2)
    local complete = e.capture.hooks.done
    if complete then complete(e.capture, nil, 0, 0) end
    luaunit.assertFalse(e.pressed)
    luaunit.assertEquals(#self.graph:GetConnections(), 1)
    -- Some event batches can contain both notifications.
    self:release()
    luaunit.assertEquals(#self.graph:GetConnections(), 1)
end

function TestEditorDrag:testNativeDragCompleteStopsCanvasPanBeforeResize()
    local e = self.editor
    e:draw()
    self:pointAt(700, 500, 1)
    e.capture.hooks.click(e.capture, 700, 500)
    luaunit.assertEquals(e.mode, "pan")
    self:pointAt(720, 515, 1)
    e:draw()
    local panX, panY = e.view.panX, e.view.panY
    local complete = e.capture.hooks.done
    if complete then complete(e.capture, nil, 720, 515) end
    self.content.parent:SetPos(80, 100)
    self.content:SetSize(750, 480)
    self:pointAt(200, 150, 1)
    e:draw()
    assertPoint(e.view.panX, e.view.panY, panX, panY)
end

-- Native trace 1eb4384, sample 1307: click at (608,451) was delivered
-- after the raw pointer reached (717.2890625,444.19140625). Reproduce the
-- dispatch ordering through mounted hooks, independently of rendered geometry.
function TestEditorDrag:testDelayedClickSelectsOriginalTargetAcrossScaleAndZoom()
    local e = self.editor
    for _, iface in ipairs({ 1, 1.25, 2 }) do
        for _, osScale in ipairs({ 1, 1.25, 2 }) do
            for _, zoom in ipairs({ 0.25, 1, 2 }) do
                for _, kind in ipairs({ "node", "wire", "reconnect" }) do
                    self:prepare(zoom, iface, osScale, kind)
                    -- Close the setup gesture and restore its graph without a drop.
                    e.pressed, e.mode, e.wire = false, "idle", nil
                    e:positionCapture()
                    if kind == "reconnect" then
                        self.graph:Connect(self.source, "out", self.target, "in")
                    end
                    -- Move far beyond the original header/pin before dispatch.
                    self:pointAt(269.2890625, 193.19140625, iface * osScale)
                    local panX, panY = e.view.panX, e.view.panY
                    e.capture.hooks.click(e.capture, 160, 200)
                    luaunit.assertEquals(e.mode, kind == "node" and "dragnode" or "wire")
                    assertPoint(e.mouse.x, e.mouse.y, 160, 200)
                    assertPoint(e.view.panX, e.view.panY, panX, panY)
                    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 120, 180)
                    if kind == "node" then
                        luaunit.assertEquals(e.dragNodeId, self.source)
                    else
                        luaunit.assertEquals(e.wire.nodeId, self.source)
                        luaunit.assertEquals(#self.graph:GetConnections(), 0)
                    end
                    -- The movement event was collected at the pre-expansion origin,
                    -- in the same native pass as this delayed click.
                    e.capture.hooks.hold(e.capture, 269.2890625, 193.19140625)
                    e:draw()
                    assertPoint(e.view.panX, e.view.panY, panX, panY)
                    if kind == "node" then
                        assertPoint(e.layout[self.source].x, e.layout[self.source].y,
                            120 + 109.2890625 / zoom, 180 - 6.80859375 / zoom)
                    else
                        local endpoint = e.canvas.lines[#e.canvas.lines]
                        assertPoint(endpoint[3], endpoint[4], 269.2890625, 193.19140625)
                    end
                    e.pressed, e.mode, e.wire, e.dragNodeId = false, "idle", nil, nil
                    e:positionCapture()
                end
            end
        end
    end
end

function TestEditorDrag:testCatchupTicksDoNotRelayoutUnchangedToolbar()
    self.editor:draw()
    local writes = 0
    for _, button in ipairs({ self.editor.backButton, self.editor.renameButton,
        self.editor.plusButton, self.editor.resetViewButton }) do
        local root = button.root
        local setPos, setSize = root.SetPos, root.SetSize
        function root:SetPos(...) writes = writes + 1; return setPos(self, ...) end
        function root:SetSize(...) writes = writes + 1; return setSize(self, ...) end
    end
    for _ = 1, 24 do self.editor:update() end
    self.editor:draw()
    luaunit.assertEquals(writes, 0, "stationary native layout must not be invalidated on catch-up ticks")
    -- Actual geometry changes must still place controls before the next draw.
    self.content.parent:SetPos(75, 80)
    self.editor:draw()
    luaunit.assertTrue(writes > 0)
end

function TestEditorDrag:testNativeTraceDelayedClickCannotReverseCanvasMovement()
    local e = self.editor
    self.content.parent:SetPos(346, 158)
    e.view.panX, e.view.panY = 616.30522001344, 467.84713085157
    -- Seed the former scale field so this regression also replays against 53ec069.
    e.screenScale, e.screenScaleIface = 1.0015544694984, 1
    self.raw.x, self.raw.y = 643.8671875, 557.16796875
    e:draw()
    local panX, panY = e.view.panX, e.view.panY
    -- Native samples 1353-1357: the button event precedes the newer pointer.
    self.raw.x, self.raw.y = 571.8828125, 457.9921875
    e:update()
    e.capture.hooks.click(e.capture, 257, 349)
    e:update() -- next native input batch sees the expanded capture at (0,0)
    if e.capture.hooks.hold then e.capture.hooks.hold(e.capture, 571, 457) end
    e:draw()
    assertPoint(e.view.panX - panX, e.view.panY - panY, -72, -100)
end

function TestEditorDrag:testRawPointerAheadOfButtonEventsCannotKeepDragging()
    self:prepare(1, 1, 1, "node")
    local e = self.editor
    e:update()
    if e.capture.hooks.hold then e.capture.hooks.hold(e.capture, 264, 318) end
    -- Raw polling has advanced after physical release, but native button delivery
    -- has not caught up. Do not combine that new pointer with the old held state.
    self.raw.x, self.raw.y = 700, 650
    e:draw()
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 144, 198)
    e.capture.hooks.release(e.capture, 264, 318)
    self.raw.x, self.raw.y = 800, 700
    e:draw()
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 144, 198)
    luaunit.assertFalse(e.pressed)
end

function TestEditorDrag:testPressHoldReleaseQueuedBeforeCaptureExpansion()
    local e = self.editor
    self:prepare(1, 1, 2, "node")
    -- Native hooks in this batch were collected at the old (80,100) origin.
    -- Neither the current capture origin nor the later raw poll describes them.
    self.raw.x, self.raw.y = 1200, 900
    if e.capture.hooks.hold then e.capture.hooks.hold(e.capture, 160, 200) end
    e.capture.hooks.release(e.capture, 161, 201)
    e:draw()
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 121, 181)
    luaunit.assertFalse(e.pressed)
end

function TestEditorDrag:testHoverCannotAdvanceAnActiveDragWithoutAHoldEvent()
    self:prepare(1, 1, 1, "node")
    local e = self.editor
    e:update()
    e.capture.hooks.hold(e.capture, 264, 318)
    e:draw()
    -- Hover reports position, but does not establish that the button is held.
    e.capture.hooks["repeat"](e.capture, 700, 650)
    e:draw()
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 144, 198)
    e.capture.hooks.release(e.capture, 264, 318)
    e.capture.hooks["repeat"](e.capture, 900, 700)
    e:draw()
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 144, 198)
end

function TestEditorDrag:testWireReleaseUsesItsEventPositionWhileRawMouseMovesElsewhere()
    self:prepare(1, 1, 2, "wire")
    local e = self.editor
    local geom = e.geoms[self.target]
    local pin = geom.byName["in"]
    local x, y = e:toScreen(geom.x + pin.cx + e.view.panX, geom.y + pin.cy + e.view.panY)
    e:update()
    self.raw.x, self.raw.y = 20, 20
    e.capture.hooks.release(e.capture, x, y)
    e:draw()
    local links = self.graph:GetConnections()
    luaunit.assertEquals(#links, 1)
    luaunit.assertEquals({links[1].fromNode, links[1].toNode}, {self.source, self.target})
    luaunit.assertFalse(e.palette.open)
end

-- Native trace 63d1d34, samples 3944-3947: the client dispatches a completed
-- gesture's RELEASE before CLICK, with isClicked already false in both hooks.
function TestEditorDrag:testNativeReleaseBeforeClickCannotLatchCanvasPan()
    local e = self.editor
    self.content.parent:SetPos(394, 256)
    e.view.panX, e.view.panY = 532.2933068846, 202.89933792802
    e:draw()
    e:update()
    local panX, panY = e.view.panX, e.view.panY
    e.capture.isClicked = false
    e.capture.hooks.release(e.capture, 569, 373)
    e.capture.hooks.click(e.capture, 307, 219)
    e:draw()
    luaunit.assertFalse(e.pressed)
    luaunit.assertEquals(e.mode, "idle")
    assertPoint(e.view.panX - panX, e.view.panY - panY, 262, 154)
    -- An unrelated subsequent press must not resume that completed gesture.
    e:update()
    e.capture.isClicked = true
    e.capture.hooks.click(e.capture, 200, 100)
    e.capture.hooks.hold(e.capture, 200, 100)
    e:draw()
    assertPoint(e.view.panX - panX, e.view.panY - panY, 262, 154)
end

function TestEditorDrag:testQuickNodeGestureUsesReleaseEvenWhenDispatchedFirst()
    self:prepare(1, 1, 1, "node")
    self:release()
    local e = self.editor
    e:update()
    e.capture.isClicked = false
    e.capture.hooks.release(e.capture, 184, 218)
    e.capture.hooks.click(e.capture, 160, 200)
    e:draw()
    luaunit.assertFalse(e.pressed)
    assertPoint(e.layout[self.source].x, e.layout[self.source].y, 144, 198)
end

function TestEditorDrag:testQuickWireGestureUsesReleaseEvenWhenDispatchedFirst()
    self:prepare(1, 1, 1, "wire")
    self:release()
    local e = self.editor
    e:draw()
    local geom = e.geoms[self.target]
    local pin = geom.byName["in"]
    e:update()
    e.capture.isClicked = false
    e.capture.hooks.release(e.capture, geom.x + pin.cx + e.view.panX, geom.y + pin.cy + e.view.panY)
    e.capture.hooks.click(e.capture, 160, 200)
    e:draw()
    luaunit.assertFalse(e.pressed)
    local links = self.graph:GetConnections()
    luaunit.assertEquals(#links, 1)
    luaunit.assertEquals({links[1].fromNode, links[1].toNode}, {self.source, self.target})
    luaunit.assertFalse(e.palette.open)
end
