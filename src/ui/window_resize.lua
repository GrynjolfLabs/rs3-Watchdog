local IfaceScale = require("src/ui/iface_scale")
local Theme = require("src/ui/theme")
local Dialog = require("src/ui/dialog")

local Resize = {}
Resize.__index = Resize
local GRIP = 20
local MAX = Theme.WINDOW_MAX_BTN
local CLOSE = Theme.WINDOW_CLOSE_RESERVE
local TITLE_H = Theme.WINDOW_HEADER_H
-- PrettyUI window.lua: close is CLOSE_SIZE at SetPos(..., 7).
local TITLE_ICON_Y = 7
local ICON_TOP = 0xD7B980FF
local ICON_BOTTOM = 0x996F42FF

---@return Vector4
local function gold()
    return Vector4.new(0.86, 0.76, 0.53, 1)
end

---@param canvas ui.Canvas
---@param x number
---@param y number
---@param size number
local function drawWindow(canvas, x, y, size)
    canvas:AddGradientV(x, y, 1, size, ICON_TOP, ICON_BOTTOM)
    canvas:AddGradientV(x + size - 1, y, 1, size, ICON_TOP, ICON_BOTTOM)
    canvas:AddRectangle(x + 1, y, size - 2, 1, ICON_TOP)
    canvas:AddRectangle(x + 1, y + size - 1, size - 2, 1, ICON_BOTTOM)
end

function Resize.new(window, viewport, chrome)
    chrome = chrome or viewport
    local self = setmetatable({ window = window, parent = viewport, chrome = chrome }, Resize)
    self.grip = ui.Layer.new(chrome)
    self.grip.clickthrough = false
    self.label = ui.Canvas.new(self.grip)
    self.label:SetSize(GRIP, GRIP)
    self.label.clickthrough = true
    local gripColor = gold()
    for offset = 0, 10, 5 do
        self.label:AddLine(3 + offset, 17, 17, 3 + offset, 1, gripColor)
    end
    self.maxButton = prettyui.SimpleButton.new(chrome, "", function()
        self:ToggleMaximize()
    end, {
        width = MAX,
        height = MAX,
        tooltip = { text = "Maximize window" },
        hoverCursor = config.Cursor.CURSOR_BLANK,
    })
    self.maxHit = self.maxButton.root
    self.maxButton.content.hidden = true
    -- Keep SimpleButton's input/tooltip handling, but paint a square frame.
    for _, part in pairs(self.maxButton.parts) do part.hidden = true end
    -- The artwork extends above/right of the hit area, like Close's shadow.
    self.maxIcon = ui.Canvas.new(chrome)
    self.maxIcon:SetSize(MAX + 1, MAX + 1)
    self.maxIcon.clickthrough = true
    self.grip:Subscribe(ui.Hook.ONCLICK, function()
        self:Begin()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONHOLD, function()
        self:Drag()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONRELEASE, function()
        self:Finish()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONDRAGCOMPLETE, function()
        self:Finish()
        return true
    end)
    self:paintMax()
    self:Sync(false)
    return self
end

function Resize:paintMax()
    local hovered = not self.maxButton.disabled and (self.maxButton.hovered or self.maxButton.pressed) == true
    local restoring = self.normalBounds ~= nil
    if self.maxPaintHovered == hovered and self.maxPaintRestoring == restoring then return end
    self.maxPaintHovered, self.maxPaintRestoring = hovered, restoring
    self.maxIcon:Clear()
    -- Shadow colours sampled from Close; corners are lighter than the edges.
    self.maxIcon:AddRectangle(1, 0, MAX - 1, 1, 0x211C19FF)
    self.maxIcon:AddRectangle(1, MAX, MAX - 1, 1, 0x221D19FF)
    self.maxIcon:AddRectangle(0, 1, 1, MAX - 1, 0x1F1A17FF)
    self.maxIcon:AddRectangle(MAX, 1, 1, MAX - 1, 0x241F1BFF)
    for _, x in ipairs({ 0, MAX }) do
        for _, y in ipairs({ 0, MAX }) do
            self.maxIcon:AddRectangle(x, y, 1, 1, 0x2D2923FF)
        end
    end
    self.maxIcon:AddGradientV(1, 1, MAX - 1, MAX - 1,
        hovered and 0x40382CFF or 0x302B24FF,
        hovered and 0x272017FF or 0x17140FFF)
    -- The inset gold edges include the frame's top-left and bottom-right pixels.
    self.maxIcon:AddRectangle(1, 1, 1, MAX - 1, 0x745D39FF)
    self.maxIcon:AddRectangle(2, MAX - 1, MAX - 2, 1, 0x745D39FF)
    if restoring then
        -- Only the exposed edges of the rear window show behind the front one.
        self.maxIcon:AddRectangle(8, 4, 8, 1, ICON_TOP)
        self.maxIcon:AddGradientV(16, 4, 1, 9, ICON_TOP, ICON_BOTTOM)
        self.maxIcon:AddRectangle(8, 5, 1, 2, ICON_TOP)
        self.maxIcon:AddRectangle(14, 12, 2, 1, ICON_BOTTOM)
        drawWindow(self.maxIcon, 5, 7, 9)
    else
        drawWindow(self.maxIcon, 5, 4, 12)
    end
end

function Resize:FitToParent()
    local w, h = self.parent.width, self.parent.height
    if w == nil or h == nil or w <= 0 or h <= 0 then
        return false
    end
    self.window.root:SetPos(0, 0)
    if self.window.root.width ~= w or self.window.root.height ~= h then
        self.window:SetSize(w, h)
    end
    return true
end

-- PrettyUI SetSize(0,0,1,1) while the mouse is down. Resting size is TITLE_H.
local function titleDragExpanded(title)
    return title ~= nil and (title.height or 0) > TITLE_H
end

function Resize:layoutTitleDrag()
    local root = self.window.root
    local title = self.window.titleDrag
    if title == nil or titleDragExpanded(title) then return end
    title:SetPos(root.x, root.y)
    title:SetSize(root.width - CLOSE - MAX, TITLE_H)
end

-- Clicks reach these controls even when the dim is painted over them.
function Resize:dialogOpen()
    return Dialog.depth(self.chrome) > 0 or Dialog.depth(self.parent) > 0
end

function Resize:ToggleMaximize()
    if not self.visible or self:dialogOpen() then
        return
    end
    self:Finish()
    local root = self.window.root
    if self.normalBounds ~= nil then
        local b = self.normalBounds
        self.normalBounds = nil
        root:SetPos(b.x, b.y)
        self.window:SetSize(b.width, b.height)
        self.maxButton:SetTooltip("Maximize window")
    else
        local bounds = { x = root.x, y = root.y, width = root.width, height = root.height }
        if not self:FitToParent() then
            return
        end
        self.normalBounds = bounds
        self.maxButton:SetTooltip("Restore previous size")
    end
    self:paintMax()
    self:layoutTitleDrag()
    self:Sync(self.visible, not self:dialogOpen())
end

function Resize:Begin()
    if self:dialogOpen() or not self.visible or self.normalBounds ~= nil then
        return
    end
    local mouse = Mouse.GetPosition()
    if mouse == nil then
        return
    end
    local x, y = IfaceScale.ToInterface(mouse.x, mouse.y)
    self.start = { x = x, y = y, width = self.window.root.width, height = self.window.root.height }
    self.grip:SetPos(0, 0)
    self.grip:SetSize(0, 0, 1.0, 1.0)
    self.label.hidden = true
    self.grip:MoveToFront()
end

function Resize:Drag()
    if self:dialogOpen() then
        self:Finish()
        return
    end
    if self.start == nil then
        return
    end
    local mouse = Mouse.GetPosition()
    if mouse == nil then
        return
    end
    local x, y = IfaceScale.ToInterface(mouse.x, mouse.y)
    self.window:SetSize(self.start.width + x - self.start.x, self.start.height + y - self.start.y)
    self:layoutTitleDrag()
    self.grip:MoveToFront()
end

function Resize:Finish()
    self.start = nil
    self.label.hidden = false
    self:Sync(self.visible, not self:dialogOpen())
end

---@param visible boolean
---@param raise boolean|nil  # default true; false while a dialog is open, matching the toolbar
function Resize:Sync(visible, raise)
    if raise == nil then raise = true end
    self.visible = visible
    self.grip.hidden = not visible or self.normalBounds ~= nil
    self.maxHit.hidden = not visible
    self.maxIcon.hidden = not visible
    -- A covered control still receives the click unless it opts out of hit testing.
    local blocked = not raise
    self.grip.clickthrough = blocked or self.grip.hidden
    local buttonDisabled = blocked or not visible
    if self.maxButton.disabled ~= buttonDisabled then
        self.maxButton:SetDisabled(buttonDisabled)
    end
    self:paintMax()
    if buttonDisabled then self.maxButton.tooltip:Hide() end
    if not visible then
        self.start = nil
        self.label.hidden = false
        return
    end
    if self.normalBounds ~= nil then
        self:FitToParent()
    end
    local root = self.window.root
    if self.window.titleDrag ~= nil then
        self.window.titleDrag.hidden = self.normalBounds ~= nil
    end
    self.maxHit:SetPos(root.x + root.width - CLOSE - MAX, root.y + TITLE_ICON_Y)
    self.maxHit:SetSize(MAX, MAX)
    self.maxIcon:SetPos(self.maxHit.x, self.maxHit.y - 1)
    if raise then
        self.maxHit:MoveToFront()
        self.maxIcon:MoveToFront()
    end
    self:layoutTitleDrag()
    if self.start == nil then
        self.grip:SetPos(root.x + root.width - GRIP, root.y + root.height - GRIP)
        self.grip:SetSize(GRIP, GRIP)
    end
    if raise then self.grip:MoveToFront() end
    if raise and titleDragExpanded(self.window.titleDrag) then
        self.window.titleDrag:MoveToFront()
    end
    local tooltip = self.maxButton.tooltip
    if tooltip ~= nil and tooltip.root ~= nil then
        if not tooltip.root.hidden then
            tooltip:Show()
        end
    end
end

function Resize:Destroy()
    self.maxButton:Destroy()
    self.maxIcon:Destroy()
    self.grip:Destroy()
end

return Resize
