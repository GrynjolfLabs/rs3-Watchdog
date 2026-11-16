-- Content coordinates start at the content origin; overlay coordinates are screen-relative.

local Dialog = require("src/ui/dialog")
local EditorHelp = require("src/ui/editor_help")
local Theme    = require("src/ui/theme")
local View     = require("src/ui/view")
local Node     = require("src/ui/node")
local Placeholder = require("src/ui/placeholder")
local Wire     = require("src/ui/wire")
local Clip     = require("src/ui/canvas_clip")
local Palette  = require("src/ui/palette")
local ColorPopup = require("src/ui/color_popup")
local IfaceScale = require("src/ui/iface_scale")
local InvViewer = require("src/ui/inv_viewer")
local NumberSpinner = require("src/ui/widgets/number_spinner")
local Util = require("src/util")

local Editor = {}
Editor.__index = Editor

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
        screenScale = nil,         -- pixels per interface unit, including OS scale
        screenScaleIface = nil,    -- InterfaceScale factor the sample was taken under
        captureOriginX = nil,      -- hook-batch origin; hold runs after expandCapture
        captureOriginY = nil,
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
        savePresetButton = nil,
        backButton = nil,
        zoomSlider = nil,
        resetViewButton = nil,
        infoButton = nil,
        zoomTickCanvas = nil,      -- clickthrough 1.0 mark on the slider track
        onBack = nil,              -- host nav-up (Manager)
        onSavePreset = nil,        -- host opens Save as preset
    }, Editor)

    return self
end

---@param id integer
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@param name string|nil
function Editor:BindEntry(id, graph, layout, name)
    self.alertName = name or "New Alert"
    if self.onAlertNameChanged ~= nil then self.onAlertNameChanged(self.alertName) end
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

-- Flush pending edits before dropping the graph.
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

-- A save reads this. Round every live point except the node being dragged.
-- layoutToArray copies a new number, so that drag is not snapped.
---@return Watchdog.Layout
function Editor:GetLayout()
    for id, pos in pairs(self.layout) do
        if id ~= self.dragNodeId then
            pos.x = Util.RoundHalfAway(pos.x)
            pos.y = Util.RoundHalfAway(pos.y)
        end
    end
    return self.layout
end

function Editor:IsVisible()
    return self.visible
end

function Editor:viewportRect()
    local win = self.window
    return 0, 0, win.w, math.max(1, win.h)
end

function Editor:toLocal(sx, sy)
    return sx - self.window.x, sy - self.window.y
end

function Editor:toScreen(lx, ly)
    return lx + self.window.x, ly + self.window.y
end

---@return number gx
---@return number gy
function Editor:viewCenterGraph()
    local w, h = self.window.w, self.window.h
    return self.view:ToGraph(w * 0.5, h * 0.5)
end

-- Nested component positions are parent-relative; read the absolute content bounds.
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

local function dialogOpen(self)
    return Dialog.depth(self.overlayParent) > 0
end

local function frontToolbarTooltip(btn)
    if btn == nil or btn.tooltip == nil or btn.tooltip.root == nil then return end
    if btn.tooltip.root.hidden == true then return end
    btn.tooltip.root:MoveToFront()
end

function Editor:FrontOverlayTooltips()
    frontToolbarTooltip(self.renameButton)
    frontToolbarTooltip(self.savePresetButton)
    frontToolbarTooltip(self.backButton)
    frontToolbarTooltip(self.resetViewButton)
    frontToolbarTooltip(self.infoButton)
    frontToolbarTooltip(self.plusButton)
    InvViewer.FrontTooltips(self)
end

function Editor:FrontOverlayPopups()
    if self.palette.open then
        self:frontOverlayInteractives()
    else
        self:FrontOverlayTooltips()
    end
end

function Editor:frontOverlayInteractives()
    if dialogOpen(self) then return end
    pcall(function() if self.capture ~= nil then self.capture:MoveToFront() end end)
    InvViewer.Front(self)
    pcall(function() if self.paletteCanvas ~= nil then self.paletteCanvas:MoveToFront() end end)
    if self.renameButton ~= nil then self.renameButton.root:MoveToFront() end
    if self.backButton ~= nil then self.backButton.root:MoveToFront() end
    if self.zoomSlider ~= nil then pcall(function() self.zoomSlider:MoveToFront() end) end
    if self.zoomTickCanvas ~= nil then pcall(function() self.zoomTickCanvas:MoveToFront() end) end
    if self.resetViewButton ~= nil then self.resetViewButton.root:MoveToFront() end
    if self.infoButton ~= nil then self.infoButton.root:MoveToFront() end
    if self.plusButton ~= nil then self.plusButton.root:MoveToFront() end
    if self.savePresetButton ~= nil then self.savePresetButton.root:MoveToFront() end
    self:FrontOverlayTooltips()
    if self.editing ~= nil and self.editing.field ~= nil then
        pcall(function() self.editing.field:MoveToFront() end)
    end
    if self.editing ~= nil and self.editing.numberField ~= nil then
        pcall(function() self.editing.numberField:MoveToFront() end)
    end
    if self.editing ~= nil and self.editing.spinners ~= nil then
        -- Arrows sit on the field's right edge and must win the click, or the
        -- capture overlay underneath closes the editor instead of stepping.
        local spinners = self.editing.spinners
        pcall(function() if spinners.up ~= nil then spinners.up:MoveToFront() end end)
        pcall(function() if spinners.down ~= nil then spinners.down:MoveToFront() end end)
    end
    if self.colorHexField ~= nil then
        pcall(function() self.colorHexField:MoveToFront() end)
    end
end

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
    if self.editing ~= nil and self.editing.numberField ~= nil
        and self.editing.numberLocalX ~= nil then
        local ax, ay = self:toScreen(self.editing.numberLocalX, self.editing.numberLocalY)
        pcall(function()
            self.editing.numberField:SetPos(ax, ay)
            if self.editing.numberSw ~= nil then
                self.editing.numberField:SetSize(self.editing.numberSw, self.editing.numberSh)
            end
        end)
    end
    if self.editing ~= nil and self.editing.spinners ~= nil then
        local spinners = self.editing.spinners
        self:placeSpinnerArrow(spinners.up, spinners.upRect)
        self:placeSpinnerArrow(spinners.down, spinners.downRect)
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

-- Hook x/y are interface units against the snapshotted capture origin, so raw
-- mouse / that position includes OS scale.
function Editor:noteScreenScale(component, x, y)
    if Mouse == nil or Mouse.GetPosition == nil then return end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if not ok or pos == nil then return end
    local originX = self.captureOriginX
    local originY = self.captureOriginY
    if originX == nil or originY == nil then
        originX = component.x or 0
        originY = component.y or 0
    end
    local measured = IfaceScale.Measure(pos.x, pos.y, originX + x, originY + y)
    if measured == nil then return end
    self.screenScale = measured
    self.screenScaleIface = IfaceScale.Factor()
end

function Editor:mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if not ok or pos == nil then return nil end
    local scale = self.screenScale
    if scale ~= nil and self.screenScaleIface == IfaceScale.Factor() then
        return pos.x / scale, pos.y / scale
    end
    return IfaceScale.ToInterface(pos.x, pos.y)
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

local function fieldContent(field)
    local raw = ""
    pcall(function() raw = field.content or "" end)
    local quantity
    pcall(function() quantity = field.contentQuantity end)
    return raw, quantity
end

local function enumv(tbl, name)
    if tbl ~= nil and tbl[name] ~= nil then return tbl[name] end
    return name
end

local SUBMIT_CAUSES = {
    SUBMIT = true, SUBMIT_ON_ESCAPE = true, SUBMIT_ON_FOCUS_LOSS = true,
}

--- The InputField submit name, or nil when this change is not a submit.
--- String names and `ui.InputFieldActionResult` values share this one check.
---@param cause any
---@return string|nil
local function submitKind(cause)
    if cause == nil then return nil end
    if type(cause) == "string" and SUBMIT_CAUSES[cause] then return cause end
    local r = ui and ui.InputFieldActionResult
    if r == nil then return nil end
    if cause == r.SUBMIT then return "SUBMIT" end
    if cause == r.SUBMIT_ON_ESCAPE then return "SUBMIT_ON_ESCAPE" end
    if cause == r.SUBMIT_ON_FOCUS_LOSS then return "SUBMIT_ON_FOCUS_LOSS" end
    return nil
end

---@param cause any
---@return boolean
local function isSubmitCause(cause)
    return submitKind(cause) ~= nil
end

--- Enter stores the spinner's number. Escape dismisses it. Focus loss and the
--- write-back from an arrow click do neither.
---@param self Editor
---@param cause any
local function onSpinnerContent(self, cause)
    local editing = self.editing
    if editing ~= nil and editing.suppressNumberSubmit then return end
    local kind = submitKind(cause)
    if kind == "SUBMIT_ON_ESCAPE" then
        self:closeControlEditor()
        return
    end
    if kind ~= "SUBMIT" then return end
    editing = self.editing
    if editing == nil or editing.numberField == nil or editing.onNumber == nil then return end
    local raw, quantity = fieldContent(editing.numberField)
    editing.onNumber(raw, quantity)
    self:closeControlEditor()
end

local function safeButtonStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.BUTTON_DEFAULT ~= nil then
        return id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

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

local function titleStrip(win)
    local headerH = Theme.WINDOW_HEADER_H
    local border = Theme.WINDOW_BORDER
    return win.x - border, win.y - headerH, win.w + 2 * border, headerH
end

local function titleRightSlot(win, w, h)
    w = w or Theme.TOOLBAR_BTN
    h = h or Theme.TOOLBAR_BTN
    local titleX, titleY, titleW, headerH = titleStrip(win)
    local x = titleX + titleW - Theme.WINDOW_MAX_BTN - 6 - w
    local y = titleY + math.floor((headerH - h) / 2)
    return x, y
end

local function addNodeScreenPos(win, bs)
    bs = bs or Theme.TOOLBAR_BTN
    local titleX, titleY, _, headerH = titleStrip(win)
    local pad = 6
    local btnY = titleY + math.floor((headerH - bs) / 2)
    return titleX + pad + bs + pad + bs + pad, btnY, bs
end

function Editor:unknownTypeKey()
    return LibNodeGraph.UNKNOWN_TYPE
end

function Editor:isPlaceholderNode(nodeId)
    local node = self.graph.nodes[nodeId]
    return node ~= nil and node.typeKey == self:unknownTypeKey()
end

function Editor:unknownTypeOf(nodeId)
    local node = self.graph.nodes[nodeId]
    if node == nil or node.unknown == nil then return nil end
    return node.unknown.type
end

function Editor:typeLabel(nodeId, typeKey)
    if typeKey == self:unknownTypeKey() then
        return "Unknown: " .. (self:unknownTypeOf(nodeId) or "?")
    end
    local nt = self.registry:GetNodeType(typeKey)
    if nt == nil then return typeKey end
    return nt.displayName or typeKey
end

function Editor:storedNodeName(nodeId)
    if self.graph == nil then return nil end
    local node = self.graph.nodes[nodeId]
    if node == nil then return nil end
    if node.typeKey == self:unknownTypeKey() then
        if node.unknown == nil then return nil end
        return node.unknown.name
    end
    return node.name
end

function Editor:meta(nodeId, typeKey)
    local title = Node.HeaderTitle(self:typeLabel(nodeId, typeKey), self:storedNodeName(nodeId))
    if typeKey == self:unknownTypeKey() then
        return { title = title, category = nil, placeholder = true }
    end
    local nt = self.registry:GetNodeType(typeKey)
    if nt == nil then return { title = title, category = nil } end
    return { title = title, category = nt.category }
end

--- What the Rename node dialog shows. The type is fixed; the field starts as the name
--- already on the header (`New {Type}` or the stored name).
---@param nodeId integer
---@return { typeLabel: string, fieldText: string }|nil
function Editor:nodeRenameDraft(nodeId)
    if self.graph == nil then return nil end
    local node = self.graph.nodes[nodeId]
    if node == nil then return nil end
    local typeLabel = self:typeLabel(nodeId, node.typeKey)
    return {
        typeLabel = typeLabel,
        fieldText = Node.DisplayName(typeLabel, self:storedNodeName(nodeId)),
    }
end

--- Trim and store. Blank or whitespace leaves the node unchanged. Persistence is the
--- same live-graph mutation delete and control edits already use; the host autosave
--- serializes it through Store.UpdateAlertGraph.
---@param nodeId integer
---@param raw string|nil
---@return boolean
function Editor:commitNodeRename(nodeId, raw)
    if self.graph == nil then return false end
    local node = self.graph.nodes[nodeId]
    if node == nil then return false end
    return Node.CommitRename(node, raw)
end

--- True while Rename must stay disabled: blank or whitespace only.
---@param raw string|nil
---@return boolean
function Editor:nodeRenameBlank(raw)
    return Node.TrimName(raw) == nil
end

function Editor:posOf(nodeId)
    local p = self.layout[nodeId]
    if p == nil then
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
            pins = Placeholder.Stubs(self.graph, n.id)
            opts = { placeholder = true }
        else
            pins = self.graph:GetPins(n.id) or {}
            opts = { connected = connectedIn[n.id] or {}, typeKey = n.typeKey }
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
        opts.title = self:meta(n.id, n.typeKey).title
        local geom = Node.BuildGeometry(pins, pos.x, pos.y, Theme.NODE_WIDTH, opts)
        geom.typeKey = n.typeKey
        for _, ctrl in ipairs(geom.controls) do
            ctrl.value = self.graph:GetControl(n.id, ctrl.pinName)
            if ctrl.value == nil then ctrl.value = ctrl.default end
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

-- A node body blocks hits on pins and controls behind it.
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

function Editor:renameAt(sx, sy)
    return hitFrontToBack(self, sx, sy, function(id, geom)
        if Node.HitPencil(geom, self.view, sx, sy) then return id end
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

function Editor:deleteNode(nodeId)
    -- Capture state before RemoveNode. The strip, toasts, and effect handles are
    -- keyed by that table, and GetState returns nil once the node is gone.
    if self.runtime ~= nil then
        self.runtime:ReleaseNodeVisuals(self.graph, nodeId)
    end
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

-- ONHOLD can come from a press elsewhere whose release never reaches this layer.
function Editor:beginPress()
    if dialogOpen(self) then return end
    if self.pressed or not self.visible then return end
    self:syncContentOrigin()
    local mx, my = self:mousePos()
    if mx == nil then return end
    local lx, ly = self:toLocal(mx, my)
    self.mouse.x, self.mouse.y = lx, ly

    -- The palette uses screen coordinates.
    if self.palette.open then
        if self.editing ~= nil then self:closeControlEditor() end
        self:handlePaletteClick(mx, my)
        return
    end

    if self.colorPopup.open then
        if self.editing ~= nil then self:closeControlEditor() end
        self:handleColorPopupClick(lx, ly)
        return
    end

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

    self.pressed = true
    self:expandCapture()

    -- Pencil before the X, so a point on the boundary renames instead of deleting
    -- or starting a node drag.
    local hitRename = self:renameAt(lx, ly)
    if hitRename ~= nil then
        self.pressed = false
        self:positionCapture()
        if self.onRenameNode ~= nil then self.onRenameNode(hitRename) end
        return
    end

    local hitClose = self:closeAt(lx, ly)
    if hitClose ~= nil then
        self.pressed = false
        self:positionCapture()
        self:deleteNode(hitClose)
        return
    end

    -- Check the mode dropdown before pins so clicking it cannot start a wire.
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

function Editor:beginWire(hit)
    self.mode = "wire"

    if hit.entry.direction == "in" then
        local conn = self:connectionInto(hit.nodeId, hit.entry.name)
        -- Placeholder pins cannot reconnect a grabbed wire.
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
    if dialogOpen(self) then
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
    if self.visible and not self.pressed and not self.palette.open then
        self:positionCapture()
    end
    if self.capture ~= nil then
        self.captureOriginX, self.captureOriginY = self.capture.x, self.capture.y
    end
    local mx, my = self:mousePos() -- absolute; converted to local per-branch below
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
            self.palette:ScrollToY(my)
        end
    end

    self.mouse.x, self.mouse.y = self:toLocal(mx, my)
end

function Editor:endPress()
    if dialogOpen(self) then return end
    if not self.pressed then return end
    self.pressed = false

    if self.mode == "wire" and self.wire ~= nil then
        self:commitWire()
    end

    if self.mode == "dragnode" and self.dragNodeId ~= nil then
        local pos = self.layout[self.dragNodeId]
        if pos ~= nil then
            pos.x = Util.RoundHalfAway(pos.x)
            pos.y = Util.RoundHalfAway(pos.y)
        end
    end

    self.mode = "idle"
    self.wire = nil
    self.dragNodeId = nil
    self.colorDragPart = nil
    self.palette.scrollDragging = false
    if not self.palette.open then self:positionCapture() end
end

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

---@param lx number
---@param ly number
---@param opts { anchorGX: number, anchorGY: number, centerOnAnchor: boolean }|nil
function Editor:openPaletteUnfiltered(lx, ly, opts)
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
    local plusX, plusY, bs = addNodeScreenPos(self.window)
    local lx = plusX - self.window.x
    local ly = plusY + bs - self.window.y
    self:openPaletteUnfiltered(lx, ly, {
        anchorGX = gx, anchorGY = gy, centerOnAnchor = true,
    })
end

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

function Editor:handlePaletteClick(mx, my)
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
end

function Editor:placeFromPalette(row)
    local anchorGX, anchorGY = self.palette.anchorGX, self.palette.anchorGY
    local centerOnAnchor = self.palette.centerOnAnchor
    local connect = self.palette.connect
    local targetPin = row.targetPin
    self:closePalette()

    local ok, newId = pcall(function()
        return self.graph:AddNode(row.typeKey, nil, { mode = row.targetMode })
    end)
    if not ok or newId == nil then
        if log ~= nil then log("Watchdog: AddNode failed - " .. tostring(newId)) end
        return
    end
    local x, y = anchorGX, anchorGY
    if centerOnAnchor then
        local pins = self.graph:GetPins(newId) or {}
        local opts = { connected = {}, typeKey = row.typeKey }
        local nt = self.registry:GetNodeType(row.typeKey)
        if nt ~= nil and nt.modes ~= nil then
            opts.modeLabel = modeLabelOf(nt, self.graph:GetMode(newId))
        end
        opts.title = self:meta(newId, row.typeKey).title
        local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH, opts)
        x = anchorGX - geom.w * 0.5
        y = anchorGY - geom.h * 0.5
    end
    -- Store the integer the player sees. A half goes away from zero.
    self.layout[newId] = { x = Util.RoundHalfAway(x), y = Util.RoundHalfAway(y) }
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

-- Keep the field alive so cancelling a mode change can restore it.
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
    if dialogOpen(self) then return end
    if delta == nil or delta == 0 then return end
    if self.palette.open then
        self.palette:Scroll(delta)
        return
    end
    -- Native fields and the color popup do not scale with the view.
    self:closeViewTransients()
    local mx, my = self:mousePos()
    local lx, ly
    if mx ~= nil then lx, ly = self:toLocal(mx, my) else lx, ly = self.mouse.x, self.mouse.y end
    self.view:StepZoomAt(lx, ly, delta)
    self:syncZoomSlider()
end

function Editor:closeViewTransients()
    if self.editing ~= nil then self:closeControlEditor() end
    if self.colorPopup.open then self:closeColorPopup() end
end

function Editor:dismissPaletteThenViewChange()
    if self.palette.open then self:closePalette() end
    self:closeViewTransients()
end

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

-- Suppress the slider callback to avoid re-entering the zoom handler.
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

function Editor:setControl(nodeId, pinName, value)
    pcall(function() self.graph:SetControl(nodeId, pinName, value) end)
    if self.runtime ~= nil then
        pcall(function() self.runtime:PreloadNode(self.graph, nodeId) end)
    end
end

function Editor:fireTestPin(nodeId, pinName)
    local ok, err = pcall(function() self.graph:FireInput(nodeId, pinName) end)
    if not ok and log ~= nil then
        log("Watchdog: test fire failed - " .. tostring(err))
    end
end

---@param primary { IsArmed: fun(self): boolean, Cancel: fun(self), Arm: fun(self, any, string, function), nodeId: any, pinName: string|nil }|nil
---@param other { IsArmed: fun(self): boolean, Cancel: fun(self) }|nil
---@param nodeId any
---@param pinName string
---@param onCommit fun(value: any)
local function toggleMarkerCapture(primary, other, nodeId, pinName, onCommit)
    if primary == nil then return end
    local CaptureArm = require("src/ui/capture_arm")
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

local COLOR_DRAG_PARTS = { sv = true, hue = true, r = true, g = true, b = true, a = true }

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
end

function Editor:commitColorPopupValue()
    local cp = self.colorPopup
    if not cp.open then return end
    self:setControl(cp.nodeId, cp.pinName, cp:Value())
end

function Editor:openColorHexEditor()
    self:closeColorHexEditor()
    if self:interactiveParent() == nil or ui == nil then return end
    local cp = self.colorPopup
    local r = cp.rect and cp.rect.hex
    if r == nil then return end

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

-- Leave Esc available to the client pause menu while a dialog is open.
function Editor:onEscape()
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

---@param geom table
---@param ctrl table
---@return number px, number py, number sw, number sh
function Editor:controlEditRect(geom, ctrl)
    local sx, sy = self.view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
    local boxH = self.view:Scale(ctrl.h)
    local sw = self.view:Scale(ctrl.w)
    local sh = Theme.CONTROL_EDIT_H
    return sx, sy + (boxH - sh) * 0.5, sw, sh
end

---@class ControlHost
---@field GetControl fun(self: ControlHost): any
---@field Commit fun(self: ControlHost, value: any)
---@field MountField fun(self: ControlHost, ctrl: table, opts: table, onChange: fun(raw: string, quantity: number|nil))
---@field MountDropdown fun(self: ControlHost, ctrl: table, opts: table, onSelect: fun(label: string))
---@field OpenColorPopup fun(self: ControlHost, codec: table)
---@field ArmCapture fun(self: ControlHost, kind: string)

---@return ControlHost
function Editor:controlHost(nodeId, ctrl)
    local editor = self
    return {
        GetControl = function(_)
            return editor.graph:GetControl(nodeId, ctrl.pinName)
        end,
        Commit = function(_, value)
            editor:setControl(nodeId, ctrl.pinName, value)
        end,
        MountField = function(_, mctrl, opts, onChange)
            editor:mountControlField(ctrl.pinControl, nodeId, mctrl, opts, onChange)
        end,
        -- ComboField reorders entries and reassigns IDs; select by label.
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
---@param opts { filter: string|nil, maxLen: integer|nil, initial: string|nil, spinner: boolean|nil }
---@param onChange fun(raw: string, quantity: number|nil)
function Editor:mountControlField(pinControl, nodeId, ctrl, opts, onChange)
    if self.editing ~= nil then self:closeControlEditor() end
    if self:interactiveParent() == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)
    if opts.spinner then
        -- The closed row is shorter than two scrollbar arrows. Grow the editor
        -- to that height and center it on the row.
        local openH = NumberSpinner.OpenHeight()
        py = py + (sh - openH) * 0.5
        sh = openH
        local spinners
        px, py, sw, sh, spinners = self:tryMountSpinner(px, py, sw, sh)
        local numberField = self:mountInputField(px, py, sw, sh, opts.filter or "NUMERIC",
            opts.maxLen or 16, opts.initial or "", function(_, cause) onSpinnerContent(self, cause) end)
        if numberField == nil then
            self:destroySpinners(spinners)
            return
        end
        -- onChange stays off this record. closeControlEditor commits onChange,
        -- and Escape must leave the stored id alone. Arrows and Enter call onNumber.
        self.editing = { nodeId = nodeId, pinName = ctrl.pinName,
            kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl,
            onNumber = onChange, numberField = numberField, spinners = spinners,
            numberLocalX = px, numberLocalY = py, numberSw = sw, numberSh = sh }
        self:frontOverlayInteractives()
        pcall(function() numberField:SetFocus() end)
        return
    end

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
---@param opts { labels: string[]|nil, ids: integer[]|nil, initial: string|nil, number: number|nil, onNumber: (fun(raw: string, quantity: number|nil))|nil, openLayout: (fun(x: number, y: number, w: number, h: number): { x: number, y: number, w: number, h: number }|nil, { x: number, y: number, w: number, h: number })|nil }
---@param onSelect fun(label: string)
function Editor:mountControlDropdown(pinControl, nodeId, ctrl, opts, onSelect)
    if self.editing ~= nil then
        -- Remounting the mode dropdown must leave the pin editor parked.
        self:closeControlEditor({ skipUnpark = ctrl.kind == "nodeMode" })
    end
    local parent = self:interactiveParent()
    if parent == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    -- The pin control places the open number field and the list. The editor
    -- hit-tests the closed control and mounts at the rects it is given.
    local baseX, baseY, baseW, baseH = self:controlEditRect(geom, ctrl)
    local numberRect, listRect
    if opts.openLayout ~= nil then
        numberRect, listRect = opts.openLayout(baseX, baseY, baseW, baseH)
    else
        listRect = { x = baseX, y = baseY, w = baseW, h = baseH }
    end

    local numberField = nil
    local numberX, numberY, numberSw, numberSh = nil, nil, nil, nil
    local spinners = nil
    if numberRect ~= nil then
        numberX, numberY = numberRect.x, numberRect.y
        numberSw, numberSh = numberRect.w, numberRect.h
        -- Arrows only when a number commit exists. A failed sprite mount leaves
        -- the full-width field, which is the previous typing control.
        if opts.onNumber ~= nil then
            numberX, numberY, numberSw, numberSh, spinners = self:tryMountSpinner(
                numberX, numberY, numberSw, numberSh)
        end
        local numberText = ""
        if type(opts.number) == "number" then numberText = tostring(opts.number) end
        numberField = self:mountInputField(numberX, numberY, numberSw, numberSh, "NUMERIC", 16, numberText,
            function(_, cause) onSpinnerContent(self, cause) end)
        if numberField == nil then
            self:destroySpinners(spinners)
            spinners = nil
        end
    end

    local ax, ay = self:toScreen(listRect.x, listRect.y)
    local field
    local ok = pcall(function()
        field = ui.ComboField.new(parent)
        pcall(function() field.stylesheetID = safeComboStyle() end)
        field.clickthrough = false
        field:SetPos(ax, ay)
        field:SetSize(listRect.w, listRect.h)
        -- ComboField reorders entries and may replace the id Add was given.
        -- Callers that pass opts.ids still want that id on the entry (sound ids
        -- are unique). Selection below uses whatever id the combo kept.
        for i, label in ipairs(opts.labels or {}) do
            local entryId = i
            if type(opts.ids) == "table" and opts.ids[i] ~= nil then
                entryId = opts.ids[i]
            end
            field:Add(label, entryId)
        end
        if type(opts.ids) == "table" then
            local selId = nil
            if opts.initial ~= nil then
                for _, entry in ipairs(field.entries) do
                    if entry.text == opts.initial then
                        selId = entry.id
                        break
                    end
                end
            end
            if selId ~= nil then
                field:Select(selId, false)
            else
                pcall(function() field:UnselectAll() end)
            end
        elseif opts.openLayout ~= nil and opts.initial == nil then
            -- A raw number must not land on the first row.
            pcall(function() field:UnselectAll() end)
        else
            local sel = 1
            for i, e in ipairs(field.entries) do
                if e.text == opts.initial then sel = i break end
            end
            field:Select(sel, false)
        end
        field:Subscribe(enumv(ui.Hook, "ONSELECTIONCHANGED"), function()
            self:onControlDropdownSelect()
        end)
    end)
    if not ok then field = nil end
    if field == nil then
        if numberField ~= nil then pcall(function() numberField:Destroy() end) end
        self:destroySpinners(spinners)
        return
    end

    self.editing = { nodeId = nodeId, pinName = ctrl.pinName, field = field,
        kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl, onSelect = onSelect,
        onNumber = opts.onNumber, numberField = numberField, spinners = spinners,
        numberLocalX = numberX, numberLocalY = numberY, numberSw = numberSw, numberSh = numberSh,
        localX = listRect.x, localY = listRect.y, sw = listRect.w, sh = listRect.h }
    self:frontOverlayInteractives()
    if numberField ~= nil then
        pcall(function() numberField:SetFocus() end)
    else
        pcall(function() field:SetFocus() end)
    end
end

function Editor:onControlDropdownSelect()
    local e = self.editing
    if e == nil then return end
    local label
    pcall(function() label = e.field.selectedLabel end)
    if label ~= nil and e.onSelect ~= nil then e.onSelect(label) end
    self:closeControlEditor()
end

--- Up/down arrows in a column on the right of a number rect. Returns the
--- field rect to mount, and nil spinners when the sprites are unavailable.
---@param x number
---@param y number
---@param w number
---@param h number
---@return number fieldX
---@return number fieldY
---@return number fieldW
---@return number fieldH
---@return table|nil spinners
function Editor:tryMountSpinner(x, y, w, h)
    local fieldPart, upRect, downRect = NumberSpinner.Split(x, y, w, h)
    local upSprite, downSprite = NumberSpinner.ArrowSprites()
    if upSprite == nil or downSprite == nil then return x, y, w, h, nil end
    local up = self:mountSpinnerArrow(upRect, upSprite, 1)
    local down = self:mountSpinnerArrow(downRect, downSprite, -1)
    if up == nil or down == nil then
        self:destroySpinnerArrow(up)
        self:destroySpinnerArrow(down)
        return x, y, w, h, nil
    end
    return fieldPart.x, fieldPart.y, fieldPart.w, fieldPart.h,
        { up = up, down = down, upRect = upRect, downRect = downRect }
end

function Editor:placeSpinnerArrow(arrow, rect)
    if arrow == nil or rect == nil then return end
    local ax, ay = self:toScreen(rect.x, rect.y)
    pcall(function()
        arrow:SetPos(ax, ay)
        arrow:SetSize(rect.w, rect.h)
    end)
end

function Editor:destroySpinnerArrow(arrow)
    if arrow == nil then return end
    pcall(function() arrow:Destroy() end)
end

function Editor:destroySpinners(spinners)
    if spinners == nil then return end
    self:destroySpinnerArrow(spinners.up)
    self:destroySpinnerArrow(spinners.down)
end

--- Scrollbar up/down sprites beside the sound-id field. A press steps once.
--- Holding repeats about every 500ms. Leaving the field does not commit a
--- typed edit; the arrows commit each accepted step themselves.
---@param rect { x: number, y: number, w: number, h: number }
---@param spriteID number
---@param delta number
---@return ui.Sprite|nil
function Editor:mountSpinnerArrow(rect, spriteID, delta)
    local parent = self:interactiveParent()
    if parent == nil or ui == nil or ui.Sprite == nil or spriteID == nil then return nil end
    local arrow
    local ok = pcall(function()
        arrow = ui.Sprite.new(parent)
        arrow.spriteID = spriteID
        arrow.clickthrough = false
        arrow:Subscribe(enumv(ui.Hook, "ONCLICK"), function()
            self:onSpinnerArrow(delta, "press")
            return false
        end)
        arrow:Subscribe(enumv(ui.Hook, "ONCLICKREPEAT"), function()
            self:onSpinnerArrow(delta, "repeat")
            return false
        end)
        arrow:Subscribe(enumv(ui.Hook, "ONRELEASE"), function()
            self:onSpinnerArrow(delta, "release")
            return false
        end)
    end)
    if not ok or arrow == nil then
        self:destroySpinnerArrow(arrow)
        return nil
    end
    self:placeSpinnerArrow(arrow, rect)
    return arrow
end

function Editor:onSpinnerArrow(delta, event)
    if self.spinnerGate == nil then self.spinnerGate = {} end
    local step, nextState = NumberSpinner.Gate(self.spinnerGate[delta], event, self.tick or 0)
    self.spinnerGate[delta] = nextState
    if step then self:stepNumberSpinner(delta) end
end

function Editor:stepNumberSpinner(delta)
    local editing = self.editing
    if editing == nil or editing.numberField == nil or editing.onNumber == nil then return end
    local raw, quantity = fieldContent(editing.numberField)
    local nextValue = NumberSpinner.Apply(raw, quantity, delta)
    if nextValue == nil then return end
    local text = tostring(nextValue)
    local submit = editing.onNumber
    editing.suppressNumberSubmit = true
    pcall(function() editing.numberField.content = text end)
    if self.editing == editing then editing.suppressNumberSubmit = false end
    submit(text, nextValue)
end

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

function Editor:commitField()
    local e = self.editing
    if e == nil then return end
    if e.onChange ~= nil then
        local raw, quantity = fieldContent(e.field)
        e.onChange(raw, quantity)
    end
end

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
    if e.numberField ~= nil then pcall(function() e.numberField:Destroy() end) end
    self:destroySpinners(e.spinners)
    self.spinnerGate = nil
    if e.kind == "nodeMode" and not (opts and opts.skipUnpark) then
        self:unparkControlEditor()
    end
end

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

    -- Canvas does not clip AddLine or AddTriangle.
    local clipped = Clip.Wrap(self.canvas, vx, vy, vw, vh)

    for _, id in ipairs(self.nodeOrder) do
        local geom = self.geoms[id]
        if geom ~= nil and self:geomVisible(geom, vx, vy, vw, vh) then
            local editingHere = self.editing ~= nil and self.editing.nodeId == id
            Node.Draw(clipped, self.view, geom, self:meta(id, geom.typeKey),
                { selected = (id == self.selected),
                  mouseX = self.mouse.x, mouseY = self.mouse.y,
                  editingPin = editingHere and self.editing.pinName or nil,
                  editingKind = editingHere and self.editing.kind or nil,
                  editingAxis = editingHere and self.editing.axis or nil })
        end
    end

    self:drawPendingWire()

    if self.colorPopup.open then
        self.colorPopup:Draw(clipped, vx, vy, vw, vh, self.mouse.x, self.mouse.y,
            { hexEditing = self.colorHexField ~= nil })
    end

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
    -- A native line expands on both sides; use a rectangle for the exact marker width.
    c:AddRectangle(centerX - 1, 2, 2, h - 4, Theme.Vec4(Theme.COL_ZOOM_TICK))
end

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

function Editor:positionCapture()
    if self.capture == nil then return end
    local win = self.window
    pcall(function()
        self.capture:SetPos(win.x, win.y)
        self.capture:SetSize(win.w, win.h)
    end)
end

function Editor:expandCapture()
    if self.capture == nil then return end
    pcall(function()
        if self.overlayParent ~= nil and self.overlayParent.MoveToFront ~= nil then
            self.overlayParent:MoveToFront()
        end
        self.capture:SetPos(0, 0)
        self.capture:SetSize(0, 0, 1.0, 1.0)
    end)
    self:frontOverlayInteractives()
end

function Editor:RaiseToFront()
    if not self.visible then return end
    pcall(function()
        if self.overlayParent ~= nil and self.overlayParent.MoveToFront ~= nil then
            self.overlayParent:MoveToFront()
        end
    end)
    self:frontOverlayInteractives()
end

-- Hiding a button does not fire ONMOUSELEAVE or hide its overlay tooltip.
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
    dismissToolbarTooltip(self.savePresetButton)
    dismissToolbarTooltip(self.resetViewButton)
    dismissToolbarTooltip(self.infoButton)
    dismissToolbarTooltip(self.renameButton)
    dismissToolbarTooltip(self.backButton)
end

function Editor:resetView()
    self.view.panX = 0
    self.view.panY = 0
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
    hideToolbarButton(self.savePresetButton, not self.visible)
    hideToolbarButton(self.resetViewButton, not self.visible)
    hideToolbarButton(self.infoButton, not self.visible)
    hideToolbarButton(self.backButton, not self.visible)
    hideToolbarButton(self.renameButton, not self.visible)
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

function Editor:layoutToolbar()
    local win = self.window
    local pad = 6
    local bs = Theme.TOOLBAR_BTN
    local titleX, titleY, titleW, headerH = titleStrip(win)
    local btnY = titleY + math.floor((headerH - bs) / 2)
    local slotX, slotY = titleRightSlot(win, bs, bs)
    local resetX = slotX - pad - bs - pad - bs
    local infoX = slotX - pad - bs
    local sw, sh = Theme.ZOOM_SLIDER_W, Theme.ZOOM_SLIDER_H
    local sliderX = resetX - pad - sw
    local sliderY = titleY + math.floor((headerH - sh) / 2)
    if self.backButton ~= nil then
        self.backButton.root:SetPos(titleX + pad, btnY)
        self.backButton.root:SetSize(bs, bs)
    end
    if self.renameButton ~= nil then
        self.renameButton.root:SetPos(titleX + pad + bs + pad, btnY)
        self.renameButton.root:SetSize(bs, bs)
    end
    if self.plusButton ~= nil then
        self.plusButton.root:SetPos(titleX + pad + bs + pad + bs + pad, btnY)
        self.plusButton.root:SetSize(bs, bs)
    end
    if self.savePresetButton ~= nil then
        self.savePresetButton.root:SetPos(titleX + pad + (bs + pad) * 3, btnY)
        self.savePresetButton.root:SetSize(bs, bs)
    end
    if self.resetViewButton ~= nil then
        self.resetViewButton.root:SetPos(resetX, slotY)
        self.resetViewButton.root:SetSize(bs, bs)
    end
    if self.infoButton ~= nil then
        self.infoButton.root:SetPos(infoX, slotY)
        self.infoButton.root:SetSize(bs, bs)
    end
    if self.zoomSlider ~= nil then
        self.zoomSlider:SetPos(sliderX, sliderY)
        self.zoomSlider:SetSize(sw, sh)
    end
    if self.zoomTickCanvas ~= nil then
        self.zoomTickCanvas:SetPos(sliderX, sliderY)
        self.zoomTickCanvas:SetSize(sw, sh)
    end
end

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

    local okCanvas, canvas = pcall(function() return ui.Canvas.new(contentParent) end)
    if not okCanvas or canvas == nil then
        self.contentParent = nil
        self.overlayParent = nil
        if log ~= nil then log("Watchdog: Canvas Mount failed") end
        return
    end
    self.canvas = canvas
    self.canvas:SetPos(0, 0)
    self.canvas:SetSize(0, 0, 1.0, 1.0)
    self.canvas.clickthrough = true

    -- Mount capture on the overlay so it can expand beyond the content bounds.
    local okCap, capture = pcall(function() return ui.Button.new(overlayParent) end)
    if okCap and capture ~= nil then
        self.capture = capture
        self.capture.alpha = 0
        self.capture.clickthrough = false
    end

    -- Mount the palette on the overlay to avoid content clipping.
    local okPal, paletteCanvas = pcall(function() return ui.Canvas.new(overlayParent) end)
    if okPal and paletteCanvas ~= nil then
        self.paletteCanvas = paletteCanvas
        self.paletteCanvas:SetPos(0, 0)
        self.paletteCanvas:SetSize(0, 0, 1.0, 1.0)
        self.paletteCanvas.clickthrough = true
    end

    self:mountToolbar(overlayParent)

    self:positionCapture()

    if self.capture ~= nil then
        local function noteScale(component, x, y)
            self:noteScreenScale(component, x, y)
        end
        self.capture:Subscribe(ui.Hook.ONMOUSEOVER, noteScale)
        self.capture:Subscribe(ui.Hook.ONMOUSEREPEAT, noteScale)
        self.capture:Subscribe(ui.Hook.ONHOLD, noteScale)
        self.capture:Subscribe(ui.Hook.ONCLICK, function(component, x, y)
            self:noteScreenScale(component, x, y)
            self:beginPress()
        end)
        self.capture:Subscribe(ui.Hook.ONRELEASE, function() self:endPress() end)
        self.capture:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta) self:onScroll(delta) end)
    end

    self:frontOverlayInteractives()

    self:resetView()
    self:SetVisible(self.visible)
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
        -- Zero alpha paints these labels black; font 0 prevents drawing.
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

    local bs = Theme.TOOLBAR_BTN
    -- Buttons sit above the capture, so a click never reaches handlePaletteClick.
    local function button(sprite, tooltip, action)
        return prettyui.SpriteButton.new(overlayParent, sprite, function()
            if self.palette.open then self:closePalette() end
            action()
        end, { size = bs, tooltip = tooltip })
    end

    self.resetViewButton = button("GRID_LAYOUT", "Reset view", function()
        self:onResetView()
    end)
    self.infoButton = button("INFO", "Tutorial", function()
        Dialog.mount(overlayParent, {
            title = "Tutorial", width = 480, height = 420,
            rowBackgroundColours = { 0x24211EFF, 0x2E2825FF },
            content = function(win)
                EditorHelp.fill(win)
            end,
            actions = {
                { label = "Close" },
            },
        })
    end)
    self.plusButton = button("PLUS", "Add alert node", function()
        self:openPaletteFromPlus()
    end)
    self.backButton = button("BACK", "Back to alerts", function()
        self:goBack()
    end)
    self.renameButton = button("PENCIL", "Rename", function()
        if self.onRename ~= nil then self.onRename() end
    end)
    self.savePresetButton = button("STAR", "Save as preset", function()
        if self.onSavePreset ~= nil then self.onSavePreset() end
    end)
    self:layoutToolbar()
end

function Editor:goBack()
    if self.onBack ~= nil then
        pcall(self.onBack)
    else
        self:SetVisible(false)
    end
end

function Editor:Unmount()
    if self.renameButton ~= nil then self.renameButton:Destroy(); self.renameButton = nil end
    if self.savePresetButton ~= nil then self.savePresetButton:Destroy(); self.savePresetButton = nil end
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
    if self.infoButton ~= nil then
        self.infoButton:Destroy()
        self.infoButton = nil
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
    self.contentParent = nil
    self.overlayParent = nil
end

return Editor
