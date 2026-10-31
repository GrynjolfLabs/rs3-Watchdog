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
local ICON_STROKE = 1
local ICON = 10

---@return Vector4
local function gold()
    return Vector4.new(0.86, 0.76, 0.53, 1)
end

---@param canvas ui.Canvas
---@param x number
---@param y number
---@param size number
---@param colour Vector4
local function drawWindow(canvas, x, y, size, colour)
    local x2, y2 = x + size, y + size
    canvas:AddLine(x, y, x2, y, 2, colour)
    canvas:AddLine(x2, y, x2, y2, ICON_STROKE, colour)
    canvas:AddLine(x2, y2, x, y2, ICON_STROKE, colour)
    canvas:AddLine(x, y2, x, y, ICON_STROKE, colour)
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
    self.maxIcon = ui.Canvas.new(self.maxHit)
    self.maxIcon:SetSize(MAX, MAX)
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
    self.maxIcon:Clear()
    local c = gold()
    local pad = (MAX - ICON) * 0.5
    if self.normalBounds ~= nil then
        -- Only the exposed edges of the rear window show behind the front one.
        self.maxIcon:AddLine(pad + 2, pad - 1, pad + ICON, pad - 1, 2, c)
        self.maxIcon:AddLine(pad + ICON, pad - 1, pad + ICON, pad + ICON - 3, ICON_STROKE, c)
        self.maxIcon:AddLine(pad + ICON - 2, pad + ICON - 3, pad + ICON, pad + ICON - 3, ICON_STROKE, c)
        self.maxIcon:AddLine(pad + 2, pad - 1, pad + 2, pad + 1, ICON_STROKE, c)
        drawWindow(self.maxIcon, pad - 1, pad + 2, ICON - 2, c)
    else
        drawWindow(self.maxIcon, pad, pad, ICON, c)
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
    -- A covered control still receives the click unless it opts out of hit testing.
    local blocked = not raise
    self.grip.clickthrough = blocked or self.grip.hidden
    local buttonDisabled = blocked or not visible
    if self.maxButton.disabled ~= buttonDisabled then
        self.maxButton:SetDisabled(buttonDisabled)
    end
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
    if raise then self.maxHit:MoveToFront() end
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
    self.grip:Destroy()
end

return Resize
