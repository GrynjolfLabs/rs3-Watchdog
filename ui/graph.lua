-- Editor: Canvas viewport onto a live LibNodeGraph Graph (pan/zoom, hit-test, immediate-mode).
-- Mount: Canvas under contentParent; capture/toolbar/palette/transient fields under overlayParent
-- (mux overlay sits above the PrettyUI window, so clickables must be overlay children above capture).
-- Content-local (0,0) is content top-left (no WINDOW_HEADER_H); overlay chrome uses toScreen.

local Dialog = require("ui/dialog")
local PrimaryButton = require("ui/primary_button")
local Theme    = require("ui/theme")
local View     = require("ui/view")
local Node     = require("ui/node")
local Placeholder = require("ui/placeholder")
local Wire     = require("ui/wire")
local Palette  = require("ui/palette")
local ColorPopup = require("ui/color_popup")
local IfaceScale = require("ui/iface_scale")
local InvViewer = require("ui/inv_viewer")

local EDITOR_TOOLBAR_H = 84
local Editor = {}
Editor.__index = Editor

-- Unbound until BindEntry (nil graph is inert). Pan/zoom is not restored. runtime is optional (Capture Arm).
---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime|nil
function Editor.new(registry, runtime)
    local self = setmetatable({
        graph = nil,               -- nil ⇒ inert/unbound
        boundId = nil,             -- host write-back key (not the alert name)
        registry = registry,
        runtime = runtime,
        view = View.new(),
        layout = {},               -- nodeId -> {x, y} Graph-space
        nodeOrder = {},            -- draw/z order, front-most last
        geoms = {},                -- per-frame cache, nodeId -> geom
        mouse = { x = 0, y = 0 },
        pressed = false,
        mode = "idle",             -- idle | pan | dragnode | wire | colordrag | palettescroll
        editing = nil,             -- {nodeId,pinName,spec,widget,field}
        selected = nil,
        visible = false,
        palette = Palette.new(),
        colorPopup = ColorPopup.new(),
        colorHexField = nil,       -- transient InputField over the popup hex row
        inventoryGrids = {},       -- nodeId -> prettyui.ItemGrid
        viewerScroll = {},         -- nodeId -> Snapshot row offset
        viewerBound = {},          -- nodeId -> last Snapshot/offset pushed to ItemGrid
        tick = 0,                  -- Logic ticks; double-click timing
        lastClickTick = -1000,     -- previous press tick
        lastClickX = 0,
        lastClickY = 0,
        window = {                 -- live content screen rect
            x = Theme.WINDOW_X, y = Theme.WINDOW_Y,
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        canvas = nil,
        paletteCanvas = nil,       -- full-screen, screen space, unclipped
        capture = nil,
        contentParent = nil,       -- Canvas only
        overlayParent = nil,       -- capture + palette + toolbar + transient editors
        plusButton = nil,
        backButton = nil,
        zoomSlider = nil,
        resetViewButton = nil,
        zoomTickCanvas = nil,      -- clickthrough 1.0 mark on the slider track
        onBack = nil,              -- host nav-up (Manager)
    }, Editor)

    return self
end

-- Bind live graph + layout; drop previous entry's transient UI. boundId keys host write-back (not name).
---@param id integer
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@param name string|nil
function Editor:BindEntry(id, graph, layout, name)
    self.alertName = name or "New Alert"
    if self.alertNameLabel ~= nil then self.alertNameLabel.content = self.alertName end
    self:closeControlEditor()
    self:closeColorPopup()
    self.palette:Close()

    self.boundId = id
    self.graph = graph
    self.layout = layout or {}
    self.geoms = {}
    self.nodeOrder = {}
    self.selected = nil
    self.editing = nil
    self.pressed = false
    self.mode = "idle"
    self.wire = nil
    self.dragNodeId = nil
    self:resetView()
    InvViewer.DestroyAll(self)
end

-- Drop graph pointer; does not Destroy components (Unmount does). Host must flush first.
function Editor:Unbind()
    self:closeControlEditor()
    self:closeColorPopup()
    self.palette:Close()
    InvViewer.DestroyAll(self)
    self.boundId = nil
    self.graph = nil
    self.layout = {}
    self.geoms = {}
    self.nodeOrder = {}
    self.selected = nil
end

---@return Watchdog.Layout
function Editor:GetLayout()
    return self.layout
end

function Editor:IsVisible()
    return self.visible
end

-- Content-local viewport; origin (0,0) is PrettyUI content top-left (no header inset).
function Editor:viewportRect()
    local win = self.window
    return 0, EDITOR_TOOLBAR_H, win.w, math.max(1, win.h - EDITOR_TOOLBAR_H)
end

-- Screen → content-local. self.window.x/y must be the live content origin (PrettyUI owns drag).
function Editor:toLocal(sx, sy)
    return sx - self.window.x, sy - self.window.y
end

-- Inverse of toLocal (paletteCanvas is screen space, unclipped).
function Editor:toScreen(lx, ly)
    return lx + self.window.x, ly + self.window.y
end

---@return number gx
---@return number gy
function Editor:viewCenterGraph()
    local w, h = self.window.w, self.window.h
    return self.view:ToGraph(w * 0.5, EDITOR_TOOLBAR_H + (h - EDITOR_TOOLBAR_H) * 0.5)
end

-- Re-read contentParent's absolute screen rect; nested .x/.y are parent-relative.
function Editor:syncContentOrigin()
    local p = self.contentParent
    if p == nil then return end
    pcall(function()
        local x, y = p.x or 0, p.y or 0
        if prettyui ~= nil and prettyui.Tooltip ~= nil and prettyui.Tooltip.getContext ~= nil then
            local ctx = prettyui.Tooltip.getContext(p)
            if ctx ~= nil and type(ctx.position) == "function" then
                local ax, ay = ctx.position(p)
                if ax ~= nil and ay ~= nil then x, y = ax, ay end
            end
        end
        local w = self.window.w
        local h = self.window.h
        if p.width and p.width > 0 then w = p.width end
        if p.height and p.height > 0 then h = p.height end
        self.window.x, self.window.y = x, y
        self.window.w, self.window.h = w, h
    end)
    self:layoutToolbar()
    self:layoutTransientEditors()
end

---@return ui.ComponentCollection|nil
function Editor:interactiveParent()
    return self.overlayParent or self.contentParent
end

-- PLUS is fronted last among toolbar buttons; visible tips must follow or Reset view sits under +.
local function frontToolbarTooltip(btn)
    if btn == nil or btn.tooltip == nil or btn.tooltip.root == nil then return end
    if btn.tooltip.root.hidden == true then return end
    btn.tooltip.root:MoveToFront()
end

-- Capture under palette under toolbar under transient editors (overlay above PrettyUI window).
function Editor:frontOverlayInteractives()
    if Dialog.depth(self.overlayParent) > 0 then return end
    pcall(function() if self.capture ~= nil then self.capture:MoveToFront() end end)
    InvViewer.Front(self)
    pcall(function() if self.paletteCanvas ~= nil then self.paletteCanvas:MoveToFront() end end)
    if self.toolbarBackground ~= nil then self.toolbarBackground:MoveToFront() end
    if self.alertNameLabel ~= nil then self.alertNameLabel:MoveToFront() end
    if self.renameButton ~= nil then self.renameButton.root:MoveToFront() end
    if self.backButton ~= nil then self.backButton.root:MoveToFront() end
    if self.zoomSlider ~= nil then pcall(function() self.zoomSlider:MoveToFront() end) end
    if self.zoomTickCanvas ~= nil then pcall(function() self.zoomTickCanvas:MoveToFront() end) end
    if self.resetViewButton ~= nil then self.resetViewButton.root:MoveToFront() end
    if self.plusButton ~= nil then self.plusButton.root:MoveToFront() end
    frontToolbarTooltip(self.renameButton)
    frontToolbarTooltip(self.backButton)
    frontToolbarTooltip(self.resetViewButton)
    frontToolbarTooltip(self.plusButton)
    InvViewer.FrontTooltips(self)
    if self.editing ~= nil and self.editing.field ~= nil then
        pcall(function() self.editing.field:MoveToFront() end)
    end
    if self.colorHexField ~= nil then
        pcall(function() self.colorHexField:MoveToFront() end)
    end
end

-- Keep absolute-positioned overlay editors glued to content while PrettyUI drags the window.
function Editor:layoutTransientEditors()
    if self.editing ~= nil and self.editing.field ~= nil
        and self.editing.localX ~= nil and self.editing.localY ~= nil then
        local ax, ay = self:toScreen(self.editing.localX, self.editing.localY)
        pcall(function()
            self.editing.field:SetPos(ax, ay)
            if self.editing.sw ~= nil then
                self.editing.field:SetSize(self.editing.sw, self.editing.sh)
            end
        end)
    end
    if self.colorHexField ~= nil and self.colorHexLocalX ~= nil then
        local ax, ay = self:toScreen(self.colorHexLocalX, self.colorHexLocalY)
        pcall(function()
            self.colorHexField:SetPos(ax, ay)
            if self.colorHexLocalW ~= nil then
                self.colorHexField:SetSize(self.colorHexLocalW, self.colorHexLocalH)
            end
        end)
    end
end

--- Small helpers

local function mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if ok and pos ~= nil then
        -- Mouse is denser than interface units when InterfaceScale ≠ 100%; native ui.* already scales.
        return IfaceScale.ToInterface(pos.x, pos.y)
    end
    return nil
end

local function modeLabelOf(nt, key)
    if nt == nil or nt.modes == nil then return nil end
    local modeDef = key and nt.modes[key]
    return (modeDef and modeDef.label) or key
end

local function pinExists(graph, nodeId, pinName)
    if pinName == nil then return false end
    for _, p in ipairs(graph:GetPins(nodeId) or {}) do
        if p.name == pinName then return true end
    end
    return false
end

local function dataCompatible(a, b)
    return a == b or a == "any" or b == "any"
end

-- First pin on `def` that can receive `want`. pinSet from live Registry (client cannot require engine modules).
---@param registry LibNodeGraph.Registry
---@param def table
---@param want { kind: string, direction: string, dataType: string|nil }
---@return string|nil pinName
---@return string|nil modeKey
function Editor.FirstCompatiblePin(registry, def, want)
    local wantDir = (want.direction == "out") and "in" or "out"
    local function firstCompatibleInOrder(pins, pinOrder)
        for _, pinName in ipairs(pinOrder or {}) do
            local p = pins[pinName]
            if p ~= nil and p.kind == want.kind and p.direction == wantDir then
                if p.kind ~= "data" or dataCompatible(p.dataType, want.dataType) then
                    return pinName
                end
            end
        end
        return nil
    end
    if def.modes ~= nil then
        for _, m in ipairs(Node.SortedModes(def)) do
            local pins, pinOrder = registry.pinSet(def, m.key)
            local pinName = firstCompatibleInOrder(pins, pinOrder)
            if pinName ~= nil then return pinName, m.key end
        end
        return nil, nil
    end
    local pins, pinOrder = registry.pinSet(def, nil)
    return firstCompatibleInOrder(pins, pinOrder), nil
end

-- field.content / contentQuantity; pcall because the field can be mid-teardown.
local function fieldContent(field)
    local raw = ""
    pcall(function() raw = field.content or "" end)
    local quantity
    pcall(function() quantity = field.contentQuantity end)
    return raw, quantity
end

-- Enum member by name, else the raw string (newer ui.Hook keys exist in-client but not in stubs).
local function enumv(tbl, name)
    if tbl ~= nil and tbl[name] ~= nil then return tbl[name] end
    return name
end

-- True when ONCONTENTCHANGED cause is submit / focus loss / esc (enum value or raw string).
local SUBMIT_CAUSES = {
    SUBMIT = true, SUBMIT_ON_ESCAPE = true, SUBMIT_ON_FOCUS_LOSS = true,
}
local function isSubmitCause(cause)
    if cause == nil then return false end
    if type(cause) == "string" and SUBMIT_CAUSES[cause] then return true end
    local r = ui and ui.InputFieldActionResult
    if r ~= nil then
        if cause == r.SUBMIT or cause == r.SUBMIT_ON_ESCAPE or cause == r.SUBMIT_ON_FOCUS_LOSS then
            return true
        end
    end
    return false
end

local function safeButtonStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.BUTTON_DEFAULT ~= nil then
        return id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

-- Combo stylesheet; DROPDOWN then BUTTON if COMBO_DEFAULT is missing (otherwise ComboField is invisible).
local function safeComboStyle()
    if id ~= nil and id.StyleSheet ~= nil then
        return id.StyleSheet.COMBO_DEFAULT or id.StyleSheet.DROPDOWN_DEFAULT
            or id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

local function safeSliderStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.SLIDER_DEFAULT ~= nil then
        return id.StyleSheet.SLIDER_DEFAULT
    end
    return nil
end

-- PLUS screen origin and size; palette-from-plus hangs off the bottom of this.
local function plusScreenPos(win)
    return win.x + 12, win.y + 46, 28
end

-- Authoritative placeholder type key; no string fallback (would drift).
function Editor:unknownTypeKey()
    return LibNodeGraph.UNKNOWN_TYPE
end

function Editor:isPlaceholderNode(nodeId)
    local node = self.graph.nodes[nodeId]
    return node ~= nil and node.typeKey == self:unknownTypeKey()
end

-- Missing type key from node.unknown (not in GetNodes projection).
function Editor:unknownTypeOf(nodeId)
    local node = self.graph.nodes[nodeId]
    if node == nil or node.unknown == nil then return nil end
    return node.unknown.type
end

function Editor:meta(nodeId, typeKey)
    -- Placeholder title is the missing type, not the reserved key.
    if typeKey == self:unknownTypeKey() then
        return { title = "Unknown: " .. (self:unknownTypeOf(nodeId) or "?"),
            category = nil, placeholder = true }
    end
    local nt = self.registry:GetNodeType(typeKey)
    if nt == nil then return { title = typeKey, category = nil } end
    return { title = nt.displayName or typeKey, category = nt.category }
end

function Editor:posOf(nodeId)
    local p = self.layout[nodeId]
    if p == nil then
        -- Nodes with no assigned position get a cascading default so nothing hides at 0,0.
        local n = 0
        for _ in pairs(self.layout) do n = n + 1 end
        p = { x = 60 + n * 40, y = 60 + n * 40 }
        self.layout[nodeId] = p
    end
    return p
end

function Editor:bringToFront(nodeId)
    for i, id in ipairs(self.nodeOrder) do
        if id == nodeId then
            table.remove(self.nodeOrder, i)
            break
        end
    end
    self.nodeOrder[#self.nodeOrder + 1] = nodeId
end

function Editor:buildGeoms()
    -- Input pins that already have an incoming Connection get a wire, not a Control box.
    local connectedIn = {}
    for _, c in ipairs(self.graph:GetConnections()) do
        connectedIn[c.toNode] = connectedIn[c.toNode] or {}
        connectedIn[c.toNode][c.toPin] = true
    end

    local unknownKey = self:unknownTypeKey()
    local present = {}
    for _, n in ipairs(self.graph:GetNodes()) do
        present[n.id] = n.typeKey
        local pos = self:posOf(n.id)
        local pins, opts
        if n.typeKey == unknownKey then
            -- Placeholder: display-only stubs from touching wires; no interactive geom.
            pins = Placeholder.Stubs(self.graph, n.id)
            opts = { placeholder = true }
        else
            pins = self.graph:GetPins(n.id) or {}
            opts = { connected = connectedIn[n.id] or {} }
            local nt = self.registry:GetNodeType(n.typeKey)
            if nt ~= nil and nt.modes ~= nil then
                opts.modeLabel = modeLabelOf(nt, self.graph:GetMode(n.id))
            end
            if n.typeKey == InvViewer.TYPE_KEY then
                local extra = InvViewer.ExtraBodyOpts(self.view.zoom)
                opts.extraBodyH = extra.extraBodyH
                opts.extraBodyW = extra.extraBodyW
            end
        end
        local geom = Node.BuildGeometry(pins, pos.x, pos.y, Theme.NODE_WIDTH, opts)
        geom.typeKey = n.typeKey
        -- Composite controls share one stored table; field boxes show one axis.
        for _, ctrl in ipairs(geom.controls) do
            ctrl.value = self.graph:GetControl(n.id, ctrl.pinName)
            -- Nil stored Control shows the pin default (value the node would actually run with).
            if ctrl.value == nil then ctrl.value = ctrl.default end
            -- Capture Controls show "Cancel" while this pin's Capture Arm is live.
            if ctrl.kind == "capture" then
                ctrl.captureArmed = self:isCaptureArmed(n.id, ctrl.pinName)
            end
            ctrl.display = ctrl.pinControl.Display(ctrl)
        end
        self.geoms[n.id] = geom
    end
    for id in pairs(self.geoms) do
        if present[id] == nil then self.geoms[id] = nil end
    end
    local seen = {}
    local kept = {}
    for _, id in ipairs(self.nodeOrder) do
        if present[id] and not seen[id] then
            kept[#kept + 1] = id
            seen[id] = true
        end
    end
    for id in pairs(present) do
        if not seen[id] then kept[#kept + 1] = id end
    end
    self.nodeOrder = kept
end

--- Hit-testing

-- Front-to-back; a Body with no hit occludes pins/controls behind it.
local function hitFrontToBack(self, sx, sy, tryHit)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil then
            local hit = tryHit(id, geom)
            if hit ~= nil then return hit end
            if Node.HitBody(geom, self.view, sx, sy) then
                return nil
            end
        end
    end
    return nil
end

-- Placeholder stubs are display-only (never wire endpoints).
function Editor:pinAt(sx, sy)
    return hitFrontToBack(self, sx, sy, function(id, geom)
        if geom.placeholder then return nil end
        local pin = Node.PinAt(geom, self.view, sx, sy)
        if pin ~= nil then return { nodeId = id, entry = pin } end
        return nil
    end)
end

function Editor:nodeAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil and Node.HitBody(geom, self.view, sx, sy) then
            return id
        end
    end
    return nil
end

function Editor:controlAt(sx, sy)
    return hitFrontToBack(self, sx, sy, function(id, geom)
        local ctrl = Node.ControlAt(geom, self.view, sx, sy)
        if ctrl ~= nil then return { nodeId = id, ctrl = ctrl } end
        return nil
    end)
end

function Editor:testButtonAt(sx, sy)
    return hitFrontToBack(self, sx, sy, function(id, geom)
        local tb = Node.TestButtonAt(geom, self.view, sx, sy)
        if tb ~= nil then return { nodeId = id, tb = tb } end
        return nil
    end)
end

function Editor:closeAt(sx, sy)
    return hitFrontToBack(self, sx, sy, function(id, geom)
        if Node.HitClose(geom, self.view, sx, sy) then return id end
        return nil
    end)
end

function Editor:modeStripAt(sx, sy)
    return hitFrontToBack(self, sx, sy, function(id, geom)
        if Node.HitModeStrip(geom, self.view, sx, sy) then return id end
        return nil
    end)
end

function Editor:connectionInto(nodeId, pinName)
    for _, c in ipairs(self.graph:GetConnections()) do
        if c.toNode == nodeId and c.toPin == pinName then return c end
    end
    return nil
end

-- Remove node; clear layout/geom/z-order/selection now so later hit-tests in this press stay consistent.
function Editor:deleteNode(nodeId)
    self.graph:RemoveNode(nodeId)
    self.layout[nodeId] = nil
    self.geoms[nodeId] = nil
    if self.selected == nodeId then self.selected = nil end
    for i, id in ipairs(self.nodeOrder) do
        if id == nodeId then
            table.remove(self.nodeOrder, i)
            break
        end
    end
end

--- Interaction

-- Only from ONCLICK (real mouse-DOWN on this layer). Never ONHOLD: that fires when a press
-- started elsewhere is held over us, and that press's ONRELEASE never routes here - starting
-- a gesture from it strands the drag stuck-to-cursor. pressed-guard still blocks duplicate ONCLICK.
function Editor:beginPress()
    if Dialog.depth(self.overlayParent) > 0 then return end
    if self.pressed or not self.visible then return end
    self:syncContentOrigin()
    local mx, my = mousePos()
    if mx == nil then return end
    local lx, ly = self:toLocal(mx, my)
    self.mouse.x, self.mouse.y = lx, ly

    -- Palette is modal; hit-tests in SCREEN space (paletteCanvas), so pass raw mouse not toLocal.
    if self.palette.open then
        if self.editing ~= nil then self:closeControlEditor() end
        self:handlePaletteClick(mx, my)
        return
    end

    -- Color popup is modal but some parts drag (handleColorPopupClick expands capture).
    if self.colorPopup.open then
        if self.editing ~= nil then self:closeControlEditor() end
        self:handleColorPopupClick(lx, ly)
        return
    end

    -- Click-away commits a pin editor, except Mode strip (ComboField parks the editor until SetMode).
    local onModeStrip = self:modeStripAt(lx, ly)
    if self.editing ~= nil then
        if self.editing.kind == "nodeMode" then
            if not onModeStrip then
                self:closeControlEditor()
                return
            end
        elseif not onModeStrip then
            self:closeControlEditor()
        end
    end

    local dbl = (self.tick - self.lastClickTick) <= Theme.DOUBLECLICK_TICKS
        and math.abs(lx - self.lastClickX) <= Theme.DOUBLECLICK_DIST
        and math.abs(ly - self.lastClickY) <= Theme.DOUBLECLICK_DIST
    self.lastClickTick, self.lastClickX, self.lastClickY = self.tick, lx, ly

    -- Grow capture full-screen for the gesture so release still reaches us outside content.
    self.pressed = true
    self:expandCapture()

    -- Header delete isn't a drag; unwind pressed/capture before return.
    local hitClose = self:closeAt(lx, ly)
    if hitClose ~= nil then
        self.pressed = false
        self:positionCapture()
        self:deleteNode(hitClose)
        return
    end

    -- Mode strip: Graph:SetMode, not a Control. Before pin glyphs so the dropdown isn't a wire start.
    local hitMode = self:modeStripAt(lx, ly)
    if hitMode ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitMode
        self:bringToFront(hitMode)
        self:openNodeModeDropdown(hitMode)
        return
    end

    local hitPin = self:pinAt(lx, ly)
    if hitPin ~= nil then
        self:beginWire(hitPin)
        return
    end

    -- Pin Control.Press; not a drag, unwind gesture. Box is clear of the pin glyph.
    local hitCtrl = self:controlAt(lx, ly)
    if hitCtrl ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitCtrl.nodeId
        self:bringToFront(hitCtrl.nodeId)
        hitCtrl.ctrl.pinControl.Press(self:controlHost(hitCtrl.nodeId, hitCtrl.ctrl), hitCtrl.ctrl)
        return
    end

    local hitTest = self:testButtonAt(lx, ly)
    if hitTest ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitTest.nodeId
        self:bringToFront(hitTest.nodeId)
        self:fireTestPin(hitTest.nodeId, hitTest.tb.pinName)
        return
    end

    local hitNode = self:nodeAt(lx, ly)
    if hitNode ~= nil then
        self.selected = hitNode
        self:bringToFront(hitNode)
        local pos = self:posOf(hitNode)
        local gx, gy = self.view:ToGraph(lx, ly)
        self.mode = "dragnode"
        self.dragNodeId = hitNode
        self.dragDX, self.dragDY = gx - pos.x, gy - pos.y
        return
    end

    if dbl then
        self.pressed = false          -- not a drag after all
        self:positionCapture()
        self.lastClickTick = -1000    -- consume so a 3rd click isn't a fresh double
        self:openPaletteUnfiltered(lx, ly)
        return
    end
    self.selected = nil
    self.mode = "pan"
end

-- Pressing a connected input grabs that Connection (disconnect + re-anchor to original output).
function Editor:beginWire(hit)
    self.mode = "wire"

    if hit.entry.direction == "in" then
        local conn = self:connectionInto(hit.nodeId, hit.entry.name)
        -- Don't grab a wire whose source is a placeholder stub: re-anchoring would fail to reconnect.
        if conn ~= nil and not self:isPlaceholderNode(conn.fromNode) then
            self.graph:Disconnect(conn.id)
            local srcGeom = self.geoms[conn.fromNode]
            local srcEntry = srcGeom and srcGeom.byName[conn.fromPin]
            if srcEntry ~= nil then
                self.wire = { nodeId = conn.fromNode, entry = srcEntry }
                return
            end
        end
    end

    self.wire = { nodeId = hit.nodeId, entry = hit.entry }
end

function Editor:update()
    if Dialog.depth(self.overlayParent) > 0 then
        self.pressed = false
        self.mode = "idle"
        self.wire = nil
        self.dragNodeId = nil
        self.colorDragPart = nil
        self.palette.scrollDragging = false
        return
    end
    self.tick = self.tick + 1   -- advances even without a cursor, for double-click timing
    self:syncContentOrigin()
    -- Resting capture tracks live content rect while PrettyUI drags; skip while expanded.
    if self.visible and not self.pressed and not self.palette.open then
        self:positionCapture()
    end
    local mx, my = mousePos()   -- absolute; converted to local per-branch below
    if mx == nil then return end

    if self.pressed then
        if self.mode == "pan" then
            local lx, ly = self:toLocal(mx, my)
            self.view:PanBy(lx - self.mouse.x, ly - self.mouse.y)
        elseif self.mode == "dragnode" and self.dragNodeId ~= nil then
            local lx, ly = self:toLocal(mx, my)
            local gx, gy = self.view:ToGraph(lx, ly)
            local pos = self:posOf(self.dragNodeId)
            pos.x, pos.y = gx - self.dragDX, gy - self.dragDY
        elseif self.mode == "colordrag" then
            local lx, ly = self:toLocal(mx, my)
            self.colorPopup:ApplyDrag(self.colorDragPart, lx, ly)
            self:commitColorPopupValue()
        elseif self.mode == "palettescroll" then
            -- Palette hit-tests in screen space; scrub with raw mouse (no toLocal).
            self.palette:ScrollToY(my)
        end
    end

    self.mouse.x, self.mouse.y = self:toLocal(mx, my)
end

function Editor:endPress()
    if Dialog.depth(self.overlayParent) > 0 then return end
    if not self.pressed then return end
    self.pressed = false

    if self.mode == "wire" and self.wire ~= nil then
        self:commitWire()
    end

    self.mode = "idle"
    self.wire = nil
    self.dragNodeId = nil
    self.colorDragPart = nil
    self.palette.scrollDragging = false
    -- Shrink capture unless this release opened the Palette; closePalette restores later.
    if not self.palette.open then self:positionCapture() end
end

-- Identical wire toggles off; data input replaces occupant; Connect rejection is logged, not thrown.
function Editor:linkPins(outNode, outPin, inNode, inPin, isData)
    local dup = self.graph:FindConnection(outNode, outPin, inNode, inPin)
    if dup ~= nil then
        self.graph:Disconnect(dup.id)   -- toggle off
        return true
    end
    if isData then
        local existing = self:connectionInto(inNode, inPin)
        if existing ~= nil then self.graph:Disconnect(existing.id) end
    end
    local id, reason = self.graph:Connect(outNode, outPin, inNode, inPin)
    if id == nil and log ~= nil then
        log("Watchdog: connect rejected - " .. tostring(reason))
    end
    return id ~= nil
end

-- Connect if legal. Miss inside Viewport → filtered Palette; miss outside discards (grabbed conn stays removed).
function Editor:commitWire()
    local mx, my = self.mouse.x, self.mouse.y
    local target = self:pinAt(mx, my)
    if target == nil then
        local vx, vy, vw, vh = self:viewportRect()
        if mx >= vx and mx <= vx + vw and my >= vy and my <= vy + vh then
            self:openPaletteFiltered(mx, my, self.wire)
        end
        return
    end

    local a, b = self.wire, target
    local outEnd, inEnd
    if a.entry.direction == "out" and b.entry.direction == "in" then
        outEnd, inEnd = a, b
    elseif a.entry.direction == "in" and b.entry.direction == "out" then
        outEnd, inEnd = b, a
    else
        return -- two outputs or two inputs: illegal
    end

    if outEnd.nodeId == inEnd.nodeId then return end
    if outEnd.entry.kind ~= inEnd.entry.kind then return end
    if outEnd.entry.kind == "data"
        and not dataCompatible(outEnd.entry.dataType, inEnd.entry.dataType) then
        return
    end

    self:linkPins(outEnd.nodeId, outEnd.entry.name, inEnd.nodeId, inEnd.entry.name,
        inEnd.entry.kind == "data")
end

--- Palette

-- Unfiltered palette. `opts.anchorGX/GY` / `centerOnAnchor` override placement; expands capture full-screen.
---@param lx number
---@param ly number
---@param opts { anchorGX: number, anchorGY: number, centerOnAnchor: boolean }|nil
function Editor:openPaletteUnfiltered(lx, ly, opts)
    -- Toolbar + is a real Button (bypasses beginPress's colorPopup-modal check).
    self:closeColorPopup()
    local gx, gy
    if opts ~= nil and opts.anchorGX ~= nil and opts.anchorGY ~= nil then
        gx, gy = opts.anchorGX, opts.anchorGY
    else
        gx, gy = self.view:ToGraph(lx, ly)
    end
    local scx, scy = self:toScreen(lx, ly)
    self.palette:Open(self.registry, nil, {
        screenX = scx, screenY = scy, anchorGX = gx, anchorGY = gy,
        centerOnAnchor = opts ~= nil and opts.centerOnAnchor == true,
        connect = nil,
    })
    self:expandCapture()
    self.mode = "idle"
    self.selected = nil
end

function Editor:openPaletteFromPlus()
    local gx, gy = self:viewCenterGraph()
    -- Place the palette below the Add alert node button.
    local plusX, plusY, bs = plusScreenPos(self.window)
    local lx = plusX - self.window.x
    local ly = plusY + bs - self.window.y
    self:openPaletteUnfiltered(lx, ly, {
        anchorGX = gx, anchorGY = gy, centerOnAnchor = true,
    })
end

-- Palette filtered to types that can receive `source`; first matching pin (any Mode) is auto-connect.
function Editor:openPaletteFiltered(lx, ly, source)
    local gx, gy = self.view:ToGraph(lx, ly)
    local scx, scy = self:toScreen(lx, ly)
    local want = source.entry
    local filter = function(def)
        return Editor.FirstCompatiblePin(self.registry, def, want)
    end
    self.palette:Open(self.registry, filter, {
        screenX = scx, screenY = scy, anchorGX = gx, anchorGY = gy,
        connect = { nodeId = source.nodeId, entry = source.entry },
    })
    self:expandCapture()
end

function Editor:closePalette()
    self.palette:Close()
    if not self.pressed then self:positionCapture() end
end

-- Palette click in SCREEN coords (matches paletteCanvas). beginPress passes raw mouse, not toLocal.
function Editor:handlePaletteClick(mx, my)
    -- Scrollbar gutter is a real drag; checked before RowAt.
    if self.palette:ScrollbarAt(mx, my) then
        self.pressed = true
        self:expandCapture()
        self.mode = "palettescroll"
        self.palette.scrollDragging = true
        self.palette:ScrollToY(my)
        return
    end
    local row = self.palette:RowAt(mx, my)
    if row ~= nil then
        self:placeFromPalette(row)
    elseif not self.palette:Contains(mx, my) then
        self:closePalette()
    end
    -- Header row / inner padding: ignore, keep Palette open.
end

-- Add node at palette anchor; auto-connect if drag-to-create. centerOnAnchor centers the body.
function Editor:placeFromPalette(row)
    local anchorGX, anchorGY = self.palette.anchorGX, self.palette.anchorGY
    local centerOnAnchor = self.palette.centerOnAnchor
    local connect = self.palette.connect
    local targetPin = row.targetPin
    self:closePalette()

    local ok, newId = pcall(function()
        return self.graph:AddNode(row.typeKey, nil, row.targetMode)
    end)
    if not ok or newId == nil then
        if log ~= nil then log("Watchdog: AddNode failed - " .. tostring(newId)) end
        return
    end
    local x, y = anchorGX, anchorGY
    if centerOnAnchor then
        local pins = self.graph:GetPins(newId) or {}
        local opts = { connected = {} }
        local nt = self.registry:GetNodeType(row.typeKey)
        if nt ~= nil and nt.modes ~= nil then
            opts.modeLabel = modeLabelOf(nt, self.graph:GetMode(newId))
        end
        local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH, opts)
        x = anchorGX - geom.w * 0.5
        y = anchorGY - geom.h * 0.5
    end
    self.layout[newId] = { x = x, y = y }
    self:bringToFront(newId)
    self.selected = newId

    if connect ~= nil and targetPin ~= nil then
        local src = connect.entry
        if src.direction == "out" then
            self:linkPins(connect.nodeId, src.name, newId, targetPin, src.kind == "data")
        else
            self:linkPins(newId, targetPin, connect.nodeId, src.name, src.kind == "data")
        end
    end
end

---@param nodeId integer
---@param key string
---@return boolean
function Editor:applyNodeMode(nodeId, key)
    if not self.graph:SetMode(nodeId, key) then return false end
    self:dropVanishedParkedOrEditing(nodeId)
    return true
end

-- Hide the pin editor without Destroy so a cancelled reconstruct can restore it.
function Editor:parkControlEditor()
    local e = self.editing
    if e == nil or e.kind == "nodeMode" then return end
    self._modeEditStash = e
    self.editing = nil
    if e.field ~= nil then pcall(function() e.field.visible = false end) end
end

function Editor:discardParkedEditor()
    local e = self._modeEditStash
    self._modeEditStash = nil
    if e ~= nil and e.field ~= nil then pcall(function() e.field:Destroy() end) end
end

function Editor:unparkControlEditor()
    local e = self._modeEditStash
    if e == nil then return end
    self._modeEditStash = nil
    self.editing = e
    if e.field ~= nil then pcall(function() e.field.visible = true end) end
    self:frontOverlayInteractives()
end

function Editor:dropVanishedParkedOrEditing(nodeId)
    local e = self.editing
    if e ~= nil and e.kind ~= "nodeMode" and e.nodeId == nodeId
        and not pinExists(self.graph, nodeId, e.pinName) then
        self:closeControlEditor()
    end
    local s = self._modeEditStash
    if s ~= nil and s.nodeId == nodeId and not pinExists(self.graph, nodeId, s.pinName) then
        self:discardParkedEditor()
    end
end

-- ComboField over the Mode strip; labels from ModeDropdownChoices (suffix on collision).
function Editor:openNodeModeDropdown(nodeId)
    local geom = self.geoms[nodeId]
    if geom == nil or geom.modeStrip == nil then return end
    local node = self.graph.nodes[nodeId]
    if node == nil then return end
    local nt = self.registry:GetNodeType(node.typeKey)
    local choices = Node.ModeDropdownChoices(nt)
    if #choices == 0 then return end
    self:parkControlEditor()
    local labels = {}
    local byDisplay = {}
    for i, c in ipairs(choices) do
        labels[i] = c.display
        byDisplay[c.display] = c.key
    end
    local current = self.graph:GetMode(nodeId)
    local initial
    for _, c in ipairs(choices) do
        if c.key == current then initial = c.display break end
    end
    local strip = geom.modeStrip
    local ctrl = { x = strip.x, y = strip.y, w = strip.w, h = strip.h, kind = "nodeMode" }
    self:mountControlDropdown(nil, nodeId, ctrl, { labels = labels, initial = initial },
        function(display)
            local key = byDisplay[display]
            if key ~= nil then self:applyNodeMode(nodeId, key) end
        end)
end

function Editor:onScroll(delta)
    if Dialog.depth(self.overlayParent) > 0 then return end
    if delta == nil or delta == 0 then return end
    -- Palette open: wheel scrolls the list instead of zooming.
    if self.palette.open then
        self.palette:Scroll(delta)
        return
    end
    -- Transient editors / color popup are fixed screen rects; close them before zoom.
    self:closeViewTransients()
    local mx, my = mousePos()
    local lx, ly
    if mx ~= nil then lx, ly = self:toLocal(mx, my) else lx, ly = self.mouse.x, self.mouse.y end
    self.view:StepZoomAt(lx, ly, delta)
    self:syncZoomSlider()
end

function Editor:closeViewTransients()
    if self.editing ~= nil then self:closeControlEditor() end
    if self.colorPopup.open then self:closeColorPopup() end
end

-- Wheel leaves the Palette open; slider and # close it first.
function Editor:dismissPaletteThenViewChange()
    if self.palette.open then self:closePalette() end
    self:closeViewTransients()
end

-- Lattice index about the Viewport center (wheel zooms about the cursor).
---@param index integer
function Editor:applyZoomIndex(index)
    self:dismissPaletteThenViewChange()
    local rungs = View.Rungs()
    if index < 1 then index = 1 end
    if index > #rungs then index = #rungs end
    local vx, vy, vw, vh = self:viewportRect()
    local cx, cy = vx + vw * 0.5, vy + vh * 0.5
    self.view:SetZoomAt(cx, cy, rungs[index])
    self:syncZoomSlider()
end

-- SetValue(..., false) so wheel/reset don't re-enter onZoomSliderChanged.
function Editor:syncZoomSlider()
    local slider = self.zoomSlider
    if slider == nil then return end
    local minV = slider.minValue or 0
    slider:SetValue(minV + View.RungIndex(self.view.zoom) - 1, false)
end

function Editor:onZoomSliderChanged()
    local slider = self.zoomSlider
    if slider == nil then return end
    local minV = slider.minValue or 0
    local value = slider.value or minV
    self:applyZoomIndex(value - minV + 1)
end

function Editor:onResetView()
    self:dismissPaletteThenViewChange()
    self:resetView()
end

--- Control commit

function Editor:setControl(nodeId, pinName, value)
    pcall(function() self.graph:SetControl(nodeId, pinName, value) end)
    if self.runtime ~= nil then
        pcall(function() self.runtime:PreloadNode(self.graph, nodeId) end)
    end
end

--- Test button

-- Fire exec-in pin live via Graph:FireInput; pcall so a node error cannot crash the frame.
function Editor:fireTestPin(nodeId, pinName)
    local ok, err = pcall(function() self.graph:FireInput(nodeId, pinName) end)
    if not ok and log ~= nil then
        log("Watchdog: test fire failed - " .. tostring(err))
    end
end

--- Marker Capture Arm

-- Arm `primary`; cancel `other`; same-control re-click cancels.
---@param primary { IsArmed: fun(self): boolean, Cancel: fun(self), Arm: fun(self, any, string, function), nodeId: any, pinName: string|nil }|nil
---@param other { IsArmed: fun(self): boolean, Cancel: fun(self) }|nil
---@param nodeId any
---@param pinName string
---@param onCommit fun(value: any)
local function toggleMarkerCapture(primary, other, nodeId, pinName, onCommit)
    if primary == nil then return end
    local CaptureArm = require("ui/capture_arm")
    if other ~= nil and other:IsArmed() then
        other:Cancel()
    end
    if CaptureArm.Decide(primary.nodeId, primary.pinName, nodeId, pinName) == "cancel"
        and primary:IsArmed() then
        primary:Cancel()
        return
    end
    primary:Arm(nodeId, pinName, onCommit)
end

function Editor:armScreenMarkerCapture(nodeId, pinName)
    if self.runtime == nil then return end
    toggleMarkerCapture(
        self.runtime.screenMarkerCapture,
        self.runtime.objectMarkerCapture,
        nodeId, pinName,
        function(rect) self:setControl(nodeId, pinName, rect) end)
end

function Editor:armObjectMarkerCapture(nodeId, pinName)
    if self.runtime == nil then return end
    toggleMarkerCapture(
        self.runtime.objectMarkerCapture,
        self.runtime.screenMarkerCapture,
        nodeId, pinName,
        function(object) self:setControl(nodeId, pinName, object) end)
end

---@param nodeId integer
---@param pinName string
---@return boolean
function Editor:isCaptureArmed(nodeId, pinName)
    if self.runtime == nil then return false end
    for _, cap in ipairs({ self.runtime.screenMarkerCapture, self.runtime.objectMarkerCapture }) do
        if cap ~= nil and cap:IsArmed() and cap.nodeId == nodeId and cap.pinName == pinName then
            return true
        end
    end
    return false
end


--- Color popup

-- Parts that start a drag (PartAt keys). Hex/close/other are clicks.
local COLOR_DRAG_PARTS = { sv = true, hue = true, r = true, g = true, b = true, a = true }

-- Open below the swatch. `codec` is the swatch hex format/parse table (popup has no Control knowledge).
---@param nodeId integer
---@param ctrl table
---@param codec table
function Editor:openColorPopup(nodeId, ctrl, codec)
    if self.editing ~= nil then self:closeControlEditor() end
    local geom = self.geoms[nodeId]
    if geom == nil then return end
    local cp = self.colorPopup
    local sx, sy = self.view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y + ctrl.h)
    local current = self.graph:GetControl(nodeId, ctrl.pinName)
    if current == nil then current = ctrl.default end
    cp:Open(nodeId, ctrl.pinName, codec, current, sx, sy)
end

function Editor:closeColorPopup()
    self:closeColorHexEditor()
    self.colorPopup:Close()
end

-- Modal popup click: drag parts expand capture; hex mounts InputField; close/outside dismiss.
function Editor:handleColorPopupClick(lx, ly)
    local cp = self.colorPopup
    local part = cp:PartAt(lx, ly)
    if part == "close" then
        self:closeColorPopup()
        return
    end
    if part == "hex" then
        self:openColorHexEditor()
        return
    end
    if COLOR_DRAG_PARTS[part] then
        if self.colorHexField ~= nil then self:closeColorHexEditor() end
        self.pressed = true
        self:expandCapture()
        self.mode = "colordrag"
        self.colorDragPart = part
        cp:ApplyDrag(part, lx, ly)
        self:commitColorPopupValue()
        return
    end
    if not cp:Contains(lx, ly) then
        self:closeColorPopup()
    end
    -- part == "other" or nil (Draw hasn't run yet): stay open.
end

function Editor:commitColorPopupValue()
    local cp = self.colorPopup
    if not cp.open then return end
    self:setControl(cp.nodeId, cp.pinName, cp:Value())
end

-- Transient InputField over hex row; filter NONE (codec strips non-hex on commit).
function Editor:openColorHexEditor()
    self:closeColorHexEditor()
    if self:interactiveParent() == nil or ui == nil then return end
    local cp = self.colorPopup
    local r = cp.rect and cp.rect.hex
    if r == nil then return end

    -- Popup rect is content-local; mountInputField converts to absolute for the overlay.
    local field = self:mountInputField(r.x, r.y, r.w, r.h, "NONE", 8,
        cp:Format(cp:Value()),
        function(_, cause, newContent) self:onColorHexContent(cause, newContent) end)
    if field == nil then return end
    self.colorHexField = field
    self.colorHexLocalX, self.colorHexLocalY = r.x, r.y
    self.colorHexLocalW, self.colorHexLocalH = r.w, r.h
    self:frontOverlayInteractives()
    pcall(function() field:SetFocus() end)
end

-- Live-parse hex via codec (unparsable is no-op); close field on submit, not the whole popup.
function Editor:onColorHexContent(cause, _newContent)
    if self.colorHexField == nil then return end
    local raw = ""
    pcall(function() raw = self.colorHexField.content or "" end)
    local cp = self.colorPopup
    cp:SetValue(cp:Parse(raw, cp:Value()))
    self:commitColorPopupValue()
    if isSubmitCause(cause) then self:closeColorHexEditor() end
end

function Editor:closeColorHexEditor()
    if self.colorHexField == nil then return end
    pcall(function() self.colorHexField:Destroy() end)
    self.colorHexField = nil
    self.colorHexLocalX, self.colorHexLocalY = nil, nil
    self.colorHexLocalW, self.colorHexLocalH = nil, nil
end

-- Esc dismisses the dialog, color popup, marker capture, or editor in that order.
function Editor:onEscape()
    if Dialog.dismissTop(self.overlayParent) then return end
    if self.colorPopup.open then
        self:closeColorPopup()
        return
    end
    if self.runtime ~= nil and self.runtime.screenMarkerCapture ~= nil
        and self.runtime.screenMarkerCapture:IsArmed() then
        self.runtime.screenMarkerCapture:Cancel()
        return
    end
    if self.runtime ~= nil and self.runtime.objectMarkerCapture ~= nil
        and self.runtime.objectMarkerCapture:IsArmed() then
        self.runtime.objectMarkerCapture:Cancel()
        return
    end
    self:goBack()
end

-- Content-local rect for a transient field over `ctrl` (native font is fixed pixels, not View zoom).
---@param geom table
---@param ctrl table
---@return number px, number py, number sw, number sh
function Editor:controlEditRect(geom, ctrl)
    local sx, sy = self.view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
    local boxH = self.view:Scale(ctrl.h)
    local sw = math.max(self.view:Scale(ctrl.w), Theme.CONTROL_EDIT_MIN_W)
    local sh = Theme.CONTROL_EDIT_H
    return sx, sy + (boxH - sh) * 0.5, sw, sh
end

--- Pin Control host seam

---@class ControlHost
---@field GetControl fun(self: ControlHost): any
---@field Commit fun(self: ControlHost, value: any)
---@field MountField fun(self: ControlHost, ctrl: table, opts: table, onChange: fun(raw: string, quantity: number|nil))
---@field MountDropdown fun(self: ControlHost, ctrl: table, opts: table, onSelect: fun(label: string))
---@field OpenColorPopup fun(self: ControlHost, codec: table)
---@field ArmCapture fun(self: ControlHost, kind: string)

-- Pin Control host. ComboField selection is by label, never id.
---@return ControlHost
function Editor:controlHost(nodeId, ctrl)
    local editor = self
    return {
        -- Raw stored value (no default); axis RMW seeds a fresh table from nil.
        GetControl = function(_)
            return editor.graph:GetControl(nodeId, ctrl.pinName)
        end,
        Commit = function(_, value)
            editor:setControl(nodeId, ctrl.pinName, value)
        end,
        MountField = function(_, mctrl, opts, onChange)
            editor:mountControlField(ctrl.pinControl, nodeId, mctrl, opts, onChange)
        end,
        -- Selection is by label, never id (ComboField re-sorts and reassigns ids).
        MountDropdown = function(_, mctrl, opts, onSelect)
            editor:mountControlDropdown(ctrl.pinControl, nodeId, mctrl, opts, onSelect)
        end,
        OpenColorPopup = function(_, codec)
            editor:openColorPopup(nodeId, ctrl, codec)
        end,
        ArmCapture = function(_, kind)
            if kind == "object" then
                editor:armObjectMarkerCapture(nodeId, ctrl.pinName)
            else
                editor:armScreenMarkerCapture(nodeId, ctrl.pinName)
            end
        end,
    }
end

---@param pinControl table
---@param nodeId integer
---@param ctrl table
---@param opts { filter: string|nil, maxLen: integer|nil, initial: string|nil }
---@param onChange fun(raw: string, quantity: number|nil)
function Editor:mountControlField(pinControl, nodeId, ctrl, opts, onChange)
    if self.editing ~= nil then self:closeControlEditor() end
    if self:interactiveParent() == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)
    local field = self:mountInputField(px, py, sw, sh, opts.filter or "NONE", opts.maxLen or 128,
        opts.initial or "",
        function(_, cause, _newContent) self:onControlContent(cause, _newContent) end)
    if field == nil then return end

    self.editing = { nodeId = nodeId, pinName = ctrl.pinName, field = field,
        kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl, onChange = onChange,
        localX = px, localY = py, sw = sw, sh = sh }
    self:frontOverlayInteractives()
    pcall(function() field:SetFocus() end)
end

---@param pinControl table
---@param nodeId integer
---@param ctrl table
---@param opts { labels: string[]|nil, initial: string|nil }
---@param onSelect fun(label: string)
function Editor:mountControlDropdown(pinControl, nodeId, ctrl, opts, onSelect)
    if self.editing ~= nil then
        -- Remounting the Mode ComboField must not unpark the pin editor parked under it.
        self:closeControlEditor({ skipUnpark = ctrl.kind == "nodeMode" })
    end
    local parent = self:interactiveParent()
    if parent == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)
    local ax, ay = self:toScreen(px, py)
    local field
    local ok = pcall(function()
        field = ui.ComboField.new(parent)
        pcall(function() field.stylesheetID = safeComboStyle() end)
        field.clickthrough = false
        field:SetPos(ax, ay)
        field:SetSize(sw, sh)
        -- ComboField re-sorts alphabetically and reassigns ids; match selection by label, not id.
        for i, label in ipairs(opts.labels or {}) do
            field:Add(label, i)
        end
        local sel = 1
        for i, e in ipairs(field.entries) do
            if e.text == opts.initial then sel = i break end
        end
        field:Select(sel, false)
        field:Subscribe(enumv(ui.Hook, "ONSELECTIONCHANGED"), function()
            self:onControlDropdownSelect()
        end)
    end)
    if not ok or field == nil then return end

    self.editing = { nodeId = nodeId, pinName = ctrl.pinName, field = field,
        kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl, onSelect = onSelect,
        localX = px, localY = py, sw = sw, sh = sh }
    self:frontOverlayInteractives()
    pcall(function() field:SetFocus() end)
end

-- Hand selectedLabel (not selectedID) to onSelect; dropdown has no onChange so plain close is a no-op.
function Editor:onControlDropdownSelect()
    local e = self.editing
    if e == nil then return end
    local label
    pcall(function() label = e.field.selectedLabel end)
    if label ~= nil and e.onSelect ~= nil then e.onSelect(label) end
    self:closeControlEditor()
end

--- Inline Control editing

-- Overlay InputField in absolute screen space from content-local (px,py).
function Editor:mountInputField(px, py, sw, sh, filterMode, maxLen, initialContent, onChanged)
    local parent = self:interactiveParent()
    if parent == nil then return nil end
    local ax, ay = self:toScreen(px, py)
    local field
    local ok = pcall(function()
        field = ui.InputField.new(parent)
        pcall(function() field.stylesheetID = safeButtonStyle() end)
        field.clickthrough = false
        field:SetPos(ax, ay)
        field:SetSize(sw, sh)
        field:Setup(enumv(ui.TextContentVisibilityMode, "VISIBLE"),
            enumv(ui.InputFieldFilterMode, filterMode), maxLen)
        field.content = initialContent
        field:Subscribe(enumv(ui.Hook, "ONCONTENTCHANGED"), onChanged)
    end)
    if not ok then return nil end
    return field
end

-- Pin Control onChange(raw, quantity). Dropdown sessions have no onChange (commit on ONSELECTIONCHANGED).
function Editor:commitField()
    local e = self.editing
    if e == nil then return end
    if e.onChange ~= nil then
        local raw, quantity = fieldContent(e.field)
        e.onChange(raw, quantity)
    end
end

-- ONCONTENTCHANGED: live-write every keystroke; close on a submit/focus-loss cause.
function Editor:onControlContent(cause, _newContent)
    if self.editing == nil then return end
    self:commitField()
    if isSubmitCause(cause) then self:closeControlEditor() end
end

---@param opts { skipUnpark: boolean }|nil
function Editor:closeControlEditor(opts)
    local e = self.editing
    if e == nil then return end
    self:commitField()
    self.editing = nil
    if e.field ~= nil then pcall(function() e.field:Destroy() end) end
    if e.kind == "nodeMode" and not (opts and opts.skipUnpark) then
        self:unparkControlEditor()
    end
end

--- Drawing

function Editor:drawBackground()
    local vx, vy, vw, vh = self:viewportRect()
    self.canvas:AddRectangle(vx, vy, vw, vh, Theme.Vec4(Theme.COL_VIEWPORT_BG))

    local step = self.view:Scale(Theme.GRID_SPACING)
    if step < 6 then return end -- too dense to be useful when far out
    local gridCol = Theme.Vec4(Theme.COL_GRID)
    local panX, panY = self.view.panX, self.view.panY

    for k = math.ceil((vx - panX) / step), math.floor((vx + vw - panX) / step) do
        local x = panX + k * step
        self.canvas:AddLine(x, vy, x, vy + vh, 1, gridCol)
    end
    for k = math.ceil((vy - panY) / step), math.floor((vy + vh - panY) / step) do
        local y = panY + k * step
        self.canvas:AddLine(vx, y, vx + vw, y, 1, gridCol)
    end
end

function Editor:geomVisible(geom, vx, vy, vw, vh)
    local x0, y0 = self.view:ToScreen(geom.x, geom.y)
    local x1 = x0 + self.view:Scale(geom.w)
    local y1 = y0 + self.view:Scale(geom.h)
    return not (x1 < vx or x0 > vx + vw or y1 < vy or y0 > vy + vh)
end

function Editor:drawConnections()
    for _, c in ipairs(self.graph:GetConnections()) do
        local fromGeom = self.geoms[c.fromNode]
        local toGeom = self.geoms[c.toNode]
        if fromGeom ~= nil and toGeom ~= nil then
            local ax, ay = Node.PinCenter(fromGeom, c.fromPin)
            local bx, by = Node.PinCenter(toGeom, c.toPin)
            local src = fromGeom.byName[c.fromPin]
            if ax and bx and src then
                local color = Wire.ColorFor(src.kind, src.dataType)
                Wire.DrawCurve(self.canvas, self.view, ax, ay, 1, bx, by, -1, color, self:viewportRect())
            end
        end
    end
end

function Editor:drawPendingWire()
    if self.mode ~= "wire" or self.wire == nil then return end
    local geom = self.geoms[self.wire.nodeId]
    if geom == nil then return end
    local fx, fy = Node.PinCenter(geom, self.wire.entry.name)
    if fx == nil then return end
    local gx, gy = self.view:ToGraph(self.mouse.x, self.mouse.y)
    local color = Wire.ColorFor(self.wire.entry.kind, self.wire.entry.dataType)
    local fixedDir = Wire.DirFor(self.wire.entry.direction)
    Wire.DrawCurve(self.canvas, self.view, fx, fy, fixedDir, gx, gy, -fixedDir, color, self:viewportRect())
end

function Editor:draw()
    if self.canvas == nil or not self.visible then return end
    self:syncContentOrigin()
    pcall(function() self.canvas:MoveToFront() end)
    self:frontOverlayInteractives()
    self.canvas:Clear()

    self:buildGeoms()
    InvViewer.Sync(self)
    local vx, vy, vw, vh = self:viewportRect()

    self:drawBackground()
    self:drawConnections()

    for _, id in ipairs(self.nodeOrder) do
        local geom = self.geoms[id]
        if geom ~= nil and self:geomVisible(geom, vx, vy, vw, vh) then
            local editingHere = self.editing ~= nil and self.editing.nodeId == id
            Node.Draw(self.canvas, self.view, geom, self:meta(id, geom.typeKey),
                { selected = (id == self.selected),
                  mouseX = self.mouse.x, mouseY = self.mouse.y,
                  editingPin = editingHere and self.editing.pinName or nil,
                  editingKind = editingHere and self.editing.kind or nil,
                  editingAxis = editingHere and self.editing.axis or nil })
        end
    end

    self:drawPendingWire()

    -- Color popup last on the content Canvas, clamped to the Viewport.
    if self.colorPopup.open then
        self.colorPopup:Draw(self.canvas, vx, vy, vw, vh, self.mouse.x, self.mouse.y,
            { hexEditing = self.colorHexField ~= nil })
    end

    -- Palette draws on its own full-screen Canvas in screen space (content Canvas clips).
    if self.paletteCanvas ~= nil then
        pcall(function() self.paletteCanvas:Clear() end)
        if self.palette.open then
            pcall(function() self.paletteCanvas:MoveToFront() end)
            local sw, sh = self:screenSize()
            local msx, msy = self:toScreen(self.mouse.x, self.mouse.y)
            self.palette:Draw(self.paletteCanvas, 0, 0, sw, sh, msx, msy)
        end
    end
    self:drawZoomTick()
end

function Editor:drawZoomTick()
    local c = self.zoomTickCanvas
    if c == nil or not self.visible then return end
    c:Clear()
    local w = c.width or 0
    local h = c.height or 0
    if w <= 0 or h <= 0 then return end
    local n = #View.Rungs()
    local t = (View.RungIndex(1.0) - 1) / (n - 1)
    local centerX = math.floor(t * (w - 1) + 0.5) - 4
    -- Use a filled rectangle: native line thickness expands on both sides.
    c:AddRectangle(centerX - 1, 2, 2, h - 4, Theme.Vec4(Theme.COL_ZOOM_TICK))
end

--- Visibility

-- Full-screen size from overlayParent; content Canvas is content-sized.
function Editor:screenSize()
    local w, h = 1920, 1080
    local p = self.overlayParent
    if p ~= nil then
        pcall(function()
            if p.width and p.width > 0 then w = p.width end
            if p.height and p.height > 0 then h = p.height end
        end)
    end
    return w, h
end

-- Resting capture = live content screen rect so title-drag/close stay clickable.
function Editor:positionCapture()
    if self.capture == nil then return end
    local win = self.window
    pcall(function()
        self.capture:SetPos(win.x, win.y)
        self.capture:SetSize(win.w, win.h)
    end)
end

-- Full-screen capture during drag/open palette; front overlay so PrettyUI doesn't bury it.
function Editor:expandCapture()
    if self.capture == nil then return end
    pcall(function()
        if self.overlayParent ~= nil and self.overlayParent.MoveToFront ~= nil then
            self.overlayParent:MoveToFront()
        end
        self.capture:SetPos(0, 0)
        self.capture:SetSize(0, 0, 1.0, 1.0)
    end)
    -- Keep Back/+ (and any open field) above the expanded capture.
    self:frontOverlayInteractives()
end

-- Re-front overlay children after another overlay jumped ahead. No-op while hidden.
function Editor:RaiseToFront()
    if not self.visible then return end
    pcall(function()
        if self.overlayParent ~= nil and self.overlayParent.MoveToFront ~= nil then
            self.overlayParent:MoveToFront()
        end
    end)
    self:frontOverlayInteractives()
end

-- PrettyUI tooltips parent to the overlay, not the SpriteButton. Hiding the button
-- does not fire ONMOUSELEAVE, so a hovered Back tooltip would stick over the manager.
local function hideToolbarButton(btn, hidden)
    if btn == nil then return end
    if btn.root ~= nil then
        btn.root.hidden = hidden
    end
    if hidden then
        if btn.tooltip ~= nil and btn.tooltip.Hide ~= nil then
            btn.tooltip:Hide()
        end
        btn.hovered = false
        btn.pressed = false
        if btn._UpdateState ~= nil then
            btn:_UpdateState()
        end
    end
end

local function dismissToolbarTooltip(btn)
    if btn == nil then return end
    if btn.tooltip ~= nil and btn.tooltip.Hide ~= nil then
        btn.tooltip:Hide()
    end
    btn.hovered = false
    btn.pressed = false
    if btn._UpdateState ~= nil then
        btn:_UpdateState()
    end
end

-- Dismiss popups/gestures without flipping self.visible (F8 must keep pan/zoom).
function Editor:OnShellHide()
    self.pressed = false
    self.mode = "idle"
    self.wire = nil
    self.dragNodeId = nil
    self:closePalette()
    self:closeControlEditor()
    self:closeColorPopup()
    self:positionCapture()
    dismissToolbarTooltip(self.plusButton)
    dismissToolbarTooltip(self.resetViewButton)
    dismissToolbarTooltip(self.renameButton)
    dismissToolbarTooltip(self.backButton)
end

-- Default pan/zoom on Mount and each open (avoids irrecoverable off-screen pan).
function Editor:resetView()
    self.view.panX = 0
    self.view.panY = EDITOR_TOOLBAR_H
    self.view.zoom = 1.0
    self:syncZoomSlider()
end

function Editor:SetVisible(v)
    local becomingVisible = v and not self.visible
    self.visible = v and true or false
    if becomingVisible then self:resetView() end
    if not self.visible then
        self.pressed = false
        self.mode = "idle"
        self.wire = nil
        self.dragNodeId = nil
        self.palette:Close()
        self:closeControlEditor()
        self:closeColorPopup()
    end
    if self.canvas ~= nil then
        pcall(function() self.canvas.hidden = not self.visible end)
    end
    hideToolbarButton(self.plusButton, not self.visible)
    hideToolbarButton(self.resetViewButton, not self.visible)
    hideToolbarButton(self.backButton, not self.visible)
    hideToolbarButton(self.renameButton, not self.visible)
    if self.alertNameLabel ~= nil then self.alertNameLabel.hidden = not self.visible end
    if self.toolbarBackground ~= nil then self.toolbarBackground.hidden = not self.visible end
    if self.zoomSlider ~= nil then
        pcall(function() self.zoomSlider.hidden = not self.visible end)
    end
    if self.zoomTickCanvas ~= nil then
        pcall(function() self.zoomTickCanvas.hidden = not self.visible end)
    end
    if self.paletteCanvas ~= nil then
        pcall(function() self.paletteCanvas.hidden = not self.visible end)
    end
    if self.capture ~= nil then
        pcall(function()
            self.capture.hidden = not self.visible
            self.capture.enabled = self.visible  -- stop intercepting game input while hidden
        end)
        if self.visible then
            self:syncContentOrigin()
            self:positionCapture()
        end
    end
    InvViewer.Sync(self)
end

function Editor:Toggle()
    self:SetVisible(not self.visible)
end

--- Mount / unmount

-- Overlay widgets sit on the PrettyUI title strip (above titleDrag in z-order), not in
-- content. self.window is the content rect: title origin is (-BORDER, -HEADER_H). The
-- Toolbar controls live in the content area below the native title bar.
function Editor:layoutToolbar()
    local win = self.window
    local x, y, gap = win.x + 12, win.y + 8, 8
    local backW = math.max(144, select(1, prettyui.SimpleButton.getSize("Back to alerts")) + 24)
    local resetW = math.max(96, select(1, prettyui.SimpleButton.getSize("Reset view")) + 24)
    local renameW = math.max(80, select(1, prettyui.SimpleButton.getSize("Rename")) + 24)
    local right = win.x + win.w - 12
    if self.toolbarBackground ~= nil then
        self.toolbarBackground:SetPos(win.x, win.y)
        self.toolbarBackground:SetSize(win.w, EDITOR_TOOLBAR_H)
        self.toolbarBackground:Clear()
        self.toolbarBackground:AddRectangle(0, 0, win.w, EDITOR_TOOLBAR_H, Theme.Vec4(Theme.COL_VIEWPORT_BG))
    end
    if self.backButton ~= nil then self.backButton.root:SetPos(x, y); self.backButton.root:SetSize(backW, 28) end
    if self.renameButton ~= nil then self.renameButton.root:SetPos(right - renameW, y); self.renameButton.root:SetSize(renameW, 28) end
    if self.alertNameLabel ~= nil then
        self.alertNameLabel:SetPos(x + backW + 16, y)
        self.alertNameLabel:SetSize(math.max(40, right - renameW - gap - (x + backW + 16)), 28)
    end
    local plusX, plusY = plusScreenPos(win)
    if self.plusButton ~= nil then self.plusButton.root:SetPos(plusX, plusY) end
    local resetX = right - resetW
    if self.resetViewButton ~= nil then self.resetViewButton.root:SetPos(resetX, plusY); self.resetViewButton.root:SetSize(resetW, 28) end
    local sw, sh = Theme.ZOOM_SLIDER_W, Theme.ZOOM_SLIDER_H
    local sliderX, sliderY = resetX - 16 - sw, plusY + 2
    if self.zoomSlider ~= nil then
        self.zoomSlider:SetPos(sliderX, sliderY); self.zoomSlider:SetSize(sw, sh)
    end
    if self.zoomTickCanvas ~= nil then
        self.zoomTickCanvas:SetPos(sliderX, sliderY); self.zoomTickCanvas:SetSize(sw, sh)
    end
end

-- Canvas under contentParent; toolbar/capture/palette under overlayParent.
---@param contentParent ui.ComponentCollection
---@param overlayParent ui.ComponentCollection
function Editor:Mount(contentParent, overlayParent)
    if contentParent == nil or overlayParent == nil then
        if log ~= nil then log("Watchdog: Editor Mount needs contentParent and overlayParent") end
        return
    end
    if ui == nil or ui.Canvas == nil then
        if log ~= nil then log("Watchdog: ui.Canvas unavailable, aborting Editor Mount") end
        return
    end

    self.contentParent = contentParent
    self.overlayParent = overlayParent
    self:syncContentOrigin()

    -- A Canvas can draw outside its own bounds. Its parent Layer supplies the
    -- viewport clip; offset the Canvas back so graph/hit-test coordinates stay
    -- relative to the content origin.
    self.canvasViewport = ui.Layer.new(contentParent)
    self.canvasViewport:SetPos(0, EDITOR_TOOLBAR_H)
    self.canvasViewport:SetSize(0, -EDITOR_TOOLBAR_H, 1.0, 1.0)
    self.canvasViewport.clickthrough = true
    local okCanvas, canvas = pcall(function() return ui.Canvas.new(self.canvasViewport) end)
    if not okCanvas or canvas == nil then
        self.canvasViewport:Destroy()
        self.canvasViewport = nil
        self.contentParent = nil
        self.overlayParent = nil
        if log ~= nil then log("Watchdog: Canvas Mount failed") end
        return
    end
    self.canvas = canvas
    self.canvas:SetPos(0, -EDITOR_TOOLBAR_H)
    self.canvas:SetSize(0, EDITOR_TOOLBAR_H, 1.0, 1.0)
    self.canvas.clickthrough = true

    -- Invisible capture on the overlay (not under content) so it can grow true full-screen.
    local okCap, capture = pcall(function() return ui.Button.new(overlayParent) end)
    if okCap and capture ~= nil then
        self.capture = capture
        self.capture.alpha = 0
        self.capture.clickthrough = false
    end

    -- Palette full-screen Canvas on the overlay so it isn't clipped to content.
    local okPal, paletteCanvas = pcall(function() return ui.Canvas.new(overlayParent) end)
    if okPal and paletteCanvas ~= nil then
        self.paletteCanvas = paletteCanvas
        self.paletteCanvas:SetPos(0, 0)
        self.paletteCanvas:SetSize(0, 0, 1.0, 1.0)
        self.paletteCanvas.clickthrough = true
    end

    -- Toolbar on overlay above capture; contentParent children cannot out-rank the mux overlay.
    self:mountToolbar(overlayParent)

    self:positionCapture()

    -- Gesture ONLY on ONCLICK. Never subscribe ONHOLD: a press that began elsewhere fires
    -- ONHOLD when dragged over us, and that foreign press's ONRELEASE never comes back here.
    if self.capture ~= nil then
        self.capture:Subscribe(ui.Hook.ONCLICK, function() self:beginPress() end)
        self.capture:Subscribe(ui.Hook.ONRELEASE, function() self:endPress() end)
        self.capture:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta) self:onScroll(delta) end)
    end

    self:frontOverlayInteractives()

    self:resetView()
    self:SetVisible(self.visible)
end

-- Decorative sprites share the labelled button's click target and lifecycle.
local function addToolbarIcon(button, label, spriteID)
    button.root:SetSize(button.root.width + 24, button.root.height)
    label:SetPos(30, 0)
    label:SetSize(-38, 0, 1.0, 1.0)
    local icon = ui.Sprite.new(button.root)
    icon.spriteID = spriteID
    icon:SetSize(18, 18)
    icon:SetPos(8, -9, 0, 0.5)
    icon.clickthrough = true
end

---@param overlayParent ui.ComponentCollection
function Editor:mountToolbar(overlayParent)
    local okSl, slider = pcall(function() return ui.Slider.new(overlayParent) end)
    if okSl and slider ~= nil then
        pcall(function() slider.stylesheetID = safeSliderStyle() end)
        slider.clickthrough = false
        local n = #View.Rungs()
        local i0 = View.RungIndex(self.view.zoom) - 1
        slider:Setup(0, n - 1, i0, 1, 1)
        slider.notchSprite.alpha = 0
        -- labelsText.alpha = 0 paints the numerals black; font 0 skips drawing them.
        slider.labelsText.font = 0
        self.zoomSlider = slider
        slider:Subscribe(ui.Hook.ONSELECTIONCHANGED, function()
            self:onZoomSliderChanged()
            return true
        end)
    end

    local okTick, tick = pcall(function() return ui.Canvas.new(overlayParent) end)
    if okTick and tick ~= nil then
        tick.clickthrough = true
        self.zoomTickCanvas = tick
    end

    self.toolbarBackground = ui.Canvas.new(overlayParent)
    self.toolbarBackground.clickthrough = false
    self.alertNameLabel = ui.Text.new(overlayParent)
    self.alertNameLabel.content = self.alertName or "New Alert"
    self.alertNameLabel.font = id.Font.MUSEO_SANS_15PT_REGULAR
    self.alertNameLabel.rgba = 0xE7D7B0FF
    self.alertNameLabel.alignHorizontal = ui.AlignMode.TOPLEFT
    self.alertNameLabel.alignVertical = ui.AlignMode.CENTRE
    self.alertNameLabel.maxLines = 1
    self.alertNameLabel.clickthrough = true
    self.resetViewButton = prettyui.SimpleButton.new(overlayParent, "Reset view", function()
        self:onResetView()
    end, { height = 28, tooltip = "Reset zoom and position" })
    self.plusButton = prettyui.FancyButton.new(overlayParent, "Add alert node", function()
        self:openPaletteFromPlus()
    end, { variant = "positive", tooltip = "Add a trigger or action to this alert" })
    self.backButton = prettyui.SimpleButton.new(overlayParent, "Back to alerts", function()
        self:goBack()
    end, { height = 28, tooltip = "Return to your alerts" })
    self.renameButton = prettyui.SimpleButton.new(overlayParent, "Rename", function()
        if self.onRename ~= nil then self.onRename() end
    end, { height = 28, tooltip = "Rename this alert" })

    addToolbarIcon(self.backButton, self.backButton.content, id.Sprite.RS3_ICON_BACK_43PX_2)
    PrimaryButton.fit(self.plusButton, "Add alert node", id.Sprite.RS3_ICON_PURCHASE_MORE_0)
    addToolbarIcon(self.renameButton, self.renameButton.content, id.Sprite.RS3_ICON_EDIT_23PX_0)
    addToolbarIcon(self.resetViewButton, self.resetViewButton.content, id.Sprite.RS3_ICON_WARDROBE_VIEW_GRID_24PX_2)
    self:layoutToolbar()
end

-- Host onBack if wired; else hide. Nav owner flushes/unbinds.
function Editor:goBack()
    if self.onBack ~= nil then
        pcall(self.onBack)
    else
        self:SetVisible(false)
    end
end

function Editor:Unmount()
    if self.renameButton ~= nil then self.renameButton:Destroy(); self.renameButton = nil end
    if self.alertNameLabel ~= nil then self.alertNameLabel:Destroy(); self.alertNameLabel = nil end
    if self.toolbarBackground ~= nil then self.toolbarBackground:Destroy(); self.toolbarBackground = nil end
    self:closeControlEditor()
    self:closeColorPopup()
    InvViewer.DestroyAll(self)
    if self.paletteCanvas ~= nil then
        pcall(function() self.paletteCanvas:Destroy() end)
        self.paletteCanvas = nil
    end
    if self.capture ~= nil then
        pcall(function() self.capture:Destroy() end)
        self.capture = nil
    end
    if self.zoomTickCanvas ~= nil then
        pcall(function() self.zoomTickCanvas:Destroy() end)
        self.zoomTickCanvas = nil
    end
    if self.zoomSlider ~= nil then
        pcall(function() self.zoomSlider:Destroy() end)
        self.zoomSlider = nil
    end
    if self.resetViewButton ~= nil then
        self.resetViewButton:Destroy()
        self.resetViewButton = nil
    end
    if self.plusButton ~= nil then
        self.plusButton:Destroy()
        self.plusButton = nil
    end
    if self.backButton ~= nil then
        self.backButton:Destroy()
        self.backButton = nil
    end
    if self.canvas ~= nil then
        pcall(function() self.canvas:Destroy() end)
        self.canvas = nil
    end
    if self.canvasViewport ~= nil then
        self.canvasViewport:Destroy()
        self.canvasViewport = nil
    end
    self.contentParent = nil
    self.overlayParent = nil
end

return Editor
