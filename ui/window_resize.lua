local IfaceScale = require("ui/iface_scale")
local Resize = {}
Resize.__index = Resize
local SIZE = 20
function Resize.new(window, parent)
    local self = setmetatable({ window = window, parent = parent }, Resize)
    self.grip = ui.Layer.new(parent)
    self.grip.clickthrough = false
    self.label = ui.Canvas.new(self.grip)
    self.label:SetSize(SIZE, SIZE)
    self.label.clickthrough = true
    local color = Vector4.new(0.86, 0.76, 0.53, 1)
    for offset = 0, 10, 5 do
        self.label:AddLine(3 + offset, 17, 17, 3 + offset, 1, color)
    end
    self.maxButton = prettyui.SimpleButton.new(parent, "Maximize", function()
        self:ToggleMaximize()
    end, { width = 90, height = 24, tooltip = { text = "Fill the game window", placement = "below" } })
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
    self:Sync(false)
    return self
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
        self.maxButton:SetTooltip({ text = "Fill the game window", placement = "below" })
    else
        local bounds = { x = root.x, y = root.y, width = root.width, height = root.height }
        if not self:FitToParent() then
            return
        end
        self.normalBounds = bounds
        self.maxButton.content.content = "Restore"
        self.maxButton:SetTooltip({ text = "Restore previous size and position", placement = "below" })
    end
    if self.window.titleDrag ~= nil then
        self.window.titleDrag:SetPos(root.x, root.y)
        self.window.titleDrag:SetSize(root.width - 34, 32)
    end
    self:Sync(self.visible)
end
function Resize:Begin()
    if not self.visible or self.normalBounds ~= nil then
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
    if self.start == nil then
        return
    end
    local mouse = Mouse.GetPosition()
    if mouse == nil then
        return
    end
    local x, y = IfaceScale.ToInterface(mouse.x, mouse.y)
    self.window:SetSize(self.start.width + x - self.start.x, self.start.height + y - self.start.y)
    local title = self.window.titleDrag
    if title ~= nil then
        title:SetPos(self.window.root.x, self.window.root.y)
        title:SetSize(self.window.root.width - 34, 32)
    end
    self.grip:MoveToFront()
end
function Resize:Finish()
    self.start = nil
    self.label.hidden = false
    self:Sync(self.visible)
end
function Resize:Sync(visible)
    self.visible = visible
    self.grip.hidden = not visible or self.normalBounds ~= nil
    self.maxButton.root.hidden = not visible
    if not visible then
        self.start = nil
        self.label.hidden = false
        if self.maxButton.tooltip ~= nil then
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
    self.maxButton.root:SetPos(root.x + root.width - 130, root.y + 5)
    self.maxButton.root:MoveToFront()
    if self.start == nil then
        self.grip:SetPos(root.x + root.width - SIZE, root.y + root.height - SIZE)
        self.grip:SetSize(SIZE, SIZE)
    end
    self.grip:MoveToFront()
    local tooltip = self.maxButton.tooltip
    if tooltip ~= nil and tooltip.root ~= nil then
        -- Explicit coordinates avoid inherited tooltip-context offsets and
        -- automatic edge placement moving the tooltip over the title button.
        tooltip.options.x = math.max(6, root.x + root.width - 40 - tooltip.width)
        tooltip.options.y = root.y + 35
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
