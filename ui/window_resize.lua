local CaptureInput = require("ui/capture_input")
local Theme = require("ui/theme")

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
local function gold(hover)
    if hover then
        return Vector4.new(1.0, 0.92, 0.70, 1)
    end
    return Vector4.new(0.86, 0.76, 0.53, 1)
end

---@param canvas ui.Canvas
---@param x number
---@param y number
---@param size number
---@param colour Vector4
local function drawSquare(canvas, x, y, size, colour)
    local x2, y2 = x + size, y + size
    canvas:AddLine(x, y, x2, y, ICON_STROKE, colour)
    canvas:AddLine(x2, y, x2, y2, ICON_STROKE, colour)
    canvas:AddLine(x2, y2, x, y2, ICON_STROKE, colour)
    canvas:AddLine(x, y2, x, y, ICON_STROKE, colour)
end

function Resize.new(window, viewport, chrome)
    chrome = chrome or viewport
    local self = setmetatable({ window = window, parent = viewport }, Resize)
    self.grip = ui.Layer.new(chrome)
    self.grip.clickthrough = false
    self.input = CaptureInput.new(self.grip)
    self.pointer = {}
    self.label = ui.Canvas.new(self.grip)
    self.label:SetSize(GRIP, GRIP)
    self.label.clickthrough = true
    local gripColor = gold()
    for offset = 0, 10, 5 do
        self.label:AddLine(3 + offset, 17, 17, 3 + offset, 1, gripColor)
    end
    self.maxHit = ui.Layer.new(chrome)
    self.maxHit.clickthrough = false
    self.maxIcon = ui.Canvas.new(self.maxHit)
    self.maxIcon:SetSize(MAX, MAX)
    self.maxIcon.clickthrough = true
    self.maxButton = { root = self.maxHit, content = { content = "Maximize" } }
    function self.maxButton:SetTooltip(options)
        self.tooltipOptions = options
    end
    self.maxHover = false
    self.maxHit:Subscribe(ui.Hook.ONMOUSEOVER, function()
        self.maxHover = true
        self:paintMax()
    end)
    self.maxHit:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        self.maxHover = false
        self:paintMax()
    end)
    self.maxHit:Subscribe(ui.Hook.ONCLICK, function()
        self:ToggleMaximize()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONCLICK, function(component, x, y)
        self:Begin(x, y)
        if component.isClicked == false then
            local released = self.input.release
            if released ~= nil then self.pointer.x, self.pointer.y = released.x, released.y end
            self:Finish()
        end
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONHOLD, function(_, x, y)
        if self.start == nil then return true end
        self.pointer.x, self.pointer.y = self.input:Position(x, y)
        self:Drag()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONRELEASE, function(_, x, y)
        self.pointer.x, self.pointer.y = self.input:Release(x, y)
        if self.start ~= nil then self:Finish() end
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
    local c = gold(self.maxHover)
    local pad = (MAX - ICON) * 0.5
    if self.normalBounds ~= nil then
        drawSquare(self.maxIcon, pad - 1, pad + 2, ICON - 2, c)
        drawSquare(self.maxIcon, pad + 2, pad - 1, ICON - 2, c)
    else
        drawSquare(self.maxIcon, pad, pad, ICON, c)
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
    -- HOLD can run many times at an unchanged pointer while Draw catches up.
    -- Avoid invalidating native layout again for the same title bounds.
    if title.x ~= root.x or title.y ~= root.y then
        title:SetPos(root.x, root.y)
    end
    local width = root.width - CLOSE - MAX
    if title.width ~= width or title.height ~= TITLE_H then
        title:SetSize(width, TITLE_H)
    end
end

function Resize:ToggleMaximize()
    if not self.visible then
        return
    end
    self:Finish()
    local root = self.window.root
    if self.normalBounds ~= nil then
        local b = self.normalBounds
        self.normalBounds = nil
        root:SetPos(b.x, b.y)
        self.window:SetSize(b.width, b.height)
        self.maxButton.content.content = "Maximize"
        self.maxButton:SetTooltip({ text = "Fill the game window" })
    else
        local bounds = { x = root.x, y = root.y, width = root.width, height = root.height }
        if not self:FitToParent() then
            return
        end
        self.normalBounds = bounds
        self.maxButton.content.content = "Restore"
        self.maxButton:SetTooltip({ text = "Restore previous size and position" })
    end
    self:paintMax()
    self:layoutTitleDrag()
    self:Sync(self.visible)
end

function Resize:BeginInputBatch()
    self.input:BeginBatch()
end

function Resize:Begin(x, y)
    if not self.visible or self.normalBounds ~= nil then
        return
    end
    local mx, my = self.input:Position(x, y)
    self.pointer.x, self.pointer.y = mx, my
    self.start = {
        x = mx, y = my,
        width = self.window.root.width, height = self.window.root.height,
    }
    self.grip:SetPos(0, 0)
    self.grip:SetSize(0, 0, 1.0, 1.0)
    self.label.hidden = true
    self.grip:MoveToFront()
end

function Resize:Drag()
    if self.start == nil then
        return
    end
    -- Match PrettyUI's pixel rounding and bounds before deciding to relayout.
    local width = math.max(self.window.minWidth,
        math.floor(self.start.width + (self.pointer.x - self.start.x)))
    local height = math.max(self.window.minHeight,
        math.floor(self.start.height + (self.pointer.y - self.start.y)))
    if self.window.maxWidth ~= nil then width = math.min(width, self.window.maxWidth) end
    if self.window.maxHeight ~= nil then height = math.min(height, self.window.maxHeight) end
    if self.window.root.width ~= width or self.window.root.height ~= height then
        self.window:SetSize(width, height)
    end
    self:layoutTitleDrag()
    self.grip:MoveToFront()
end

function Resize:Finish()
    self:Drag()
    self.start = nil
    self.label.hidden = false
    self:Sync(self.visible)
end

function Resize:Sync(visible)
    self.visible = visible
    self.grip.hidden = not visible or self.normalBounds ~= nil
    self.maxHit.hidden = not visible
    if not visible then
        self.start = nil
        self.label.hidden = false
        if self.maxButton.tooltip ~= nil and self.maxButton.tooltip.Hide ~= nil then
            self.maxButton.tooltip:Hide()
        end
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
    self.maxHit:MoveToFront()
    self:layoutTitleDrag()
    if self.start == nil then
        self.grip:SetPos(root.x + root.width - GRIP, root.y + root.height - GRIP)
        self.grip:SetSize(GRIP, GRIP)
    end
    self.grip:MoveToFront()
    if titleDragExpanded(self.window.titleDrag) then
        self.window.titleDrag:MoveToFront()
    end
    local tooltip = self.maxButton.tooltip
    if tooltip ~= nil and tooltip.root ~= nil then
        tooltip.options.x = math.max(6, root.x + root.width - 40 - (tooltip.width or 0))
        tooltip.options.y = root.y + TITLE_H + 3
        if not tooltip.root.hidden then
            tooltip:Show()
        end
    end
end

function Resize:Destroy()
    self.maxHit:Destroy()
    self.grip:Destroy()
end

return Resize
