local Theme = require("src/ui/theme")
local HubLayers = require("src/ui/hub_layers")

local InfoBox = {}
InfoBox.__index = InfoBox

function InfoBox.new()
    return setmetatable({
        order = {},       -- ordered list of owner keys (insertion order; compacts on Remove)
        boxes = {},       -- owner -> { text, color, icon, title }
        anchor = { x = Theme.INFOBOX_DEFAULT_X, y = Theme.INFOBOX_DEFAULT_Y },
        wrapWidth = Theme.INFOBOX_WRAP_WIDTH,
        _drag = nil,          -- { dx, dy } grab offset while dragging the strip
        _persistence = nil,   -- { SaveAnchor = fn(x, y) }, injected
    }, InfoBox)
end

--- Node-facing pure helpers ----------------------------------------------------------------

function InfoBox.ResolveText(value)
    if value == nil then return "" end
    return tostring(value)
end

-- Whether an `update` value counts as "empty" for the node's dismissWhenEmpty config: nil, the
-- number 0, or the empty string (matching the issue exactly). The string "0" is a real value.
function InfoBox.IsEmpty(value)
    return value == nil or value == 0 or value == ""
end

--- Ordered box set -------------------------------------------------------------------------

-- Rewrite in place when the owner already has a tile so a re-update never reorders.
function InfoBox:Set(owner, fields)
    fields = fields or {}
    if self.boxes[owner] == nil then
        self.order[#self.order + 1] = owner
    end
    self.boxes[owner] = {
        text = fields.text or "",
        color = fields.color,
        icon = fields.icon,
        title = fields.title,
    }
end

function InfoBox:Has(owner)
    return self.boxes[owner] ~= nil
end

function InfoBox:Get(owner)
    return self.boxes[owner]
end

function InfoBox:Count()
    return #self.order
end

-- The owner keys in insertion order (a fresh copy - callers can't mutate the internal list).
function InfoBox:Order()
    local out = {}
    for i, owner in ipairs(self.order) do out[i] = owner end
    return out
end

function InfoBox:Remove(owner)
    if self.boxes[owner] == nil then return false end
    self.boxes[owner] = nil
    for i, o in ipairs(self.order) do
        if o == owner then
            table.remove(self.order, i)
            break
        end
    end
    return true
end

function InfoBox:Clear()
    self.order = {}
    self.boxes = {}
end

--- Anchor / persistence --------------------------------------------------------------------

function InfoBox:GetAnchor()
    return self.anchor.x, self.anchor.y
end

function InfoBox:SetAnchor(x, y)
    self.anchor = { x = x, y = y }
end

-- Clear the gesture first so the logic tick and the release cannot save the drag.
function InfoBox:ResetAnchor()
    self._drag = nil
    self.anchor = { x = Theme.INFOBOX_DEFAULT_X, y = Theme.INFOBOX_DEFAULT_Y }
    if self._persistence ~= nil and self._persistence.SaveAnchor ~= nil then
        pcall(self._persistence.SaveAnchor, self.anchor.x, self.anchor.y)
    end
    self:Reposition()
end

function InfoBox:SetWrapWidth(w)
    self.wrapWidth = w
end

-- Injects the anchor-persistence hook ({ SaveAnchor = fn(x, y) }); EndDrag writes the moved
-- anchor through it so the strip's position survives a reload (main.lua wires it to the Store).
function InfoBox:SetPersistence(persistence)
    self._persistence = persistence
end

--- Layout: horizontal flow + wrap ----------------------------------------------------------

function InfoBox:_columns()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    local cols = math.floor((self.wrapWidth + Theme.INFOBOX_GAP) / step)
    if cols < 1 then cols = 1 end
    return cols
end

function InfoBox:Layout()
    local size = Theme.INFOBOX_BOX_SIZE
    local step = size + Theme.INFOBOX_GAP
    local cols = self:_columns()
    local rects = {}
    for i, owner in ipairs(self.order) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        rects[i] = {
            owner = owner,
            box = self.boxes[owner],
            x = self.anchor.x + col * step,
            y = self.anchor.y + row * step,
            w = size,
            h = size,
        }
    end
    return rects
end

function InfoBox:Bounds()
    local rects = self:Layout()
    if #rects == 0 then return nil end
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, r in ipairs(rects) do
        if r.x < minX then minX = r.x end
        if r.y < minY then minY = r.y end
        if r.x + r.w > maxX then maxX = r.x + r.w end
        if r.y + r.h > maxY then maxY = r.y + r.h end
    end
    return { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
end

--- Hit-testing -----------------------------------------------------------------------------

local function inRect(r, px, py)
    return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

function InfoBox:BoxAt(px, py)
    for _, r in ipairs(self:Layout()) do
        if inRect(r, px, py) then return r.owner end
    end
    return nil
end

function InfoBox:TooltipAt(px, py)
    local owner = self:BoxAt(px, py)
    if owner == nil then return nil end
    local title = self.boxes[owner].title
    if title == nil or title == "" then return nil end
    return title
end

--- Drag-as-unit ----------------------------------------------------------------------------

function InfoBox:BeginDrag(px, py)
    if HubLayers.PositionsLocked() then return false end
    local b = self:Bounds()
    if b == nil or not inRect(b, px, py) then return false end
    self._drag = { dx = px - self.anchor.x, dy = py - self.anchor.y }
    return true
end

function InfoBox:Drag(px, py)
    if self._drag == nil then return end
    self.anchor = { x = px - self._drag.dx, y = py - self._drag.dy }
end

function InfoBox:EndDrag()
    if self._drag == nil then return end
    self._drag = nil
    if self._persistence ~= nil and self._persistence.SaveAnchor ~= nil then
        pcall(self._persistence.SaveAnchor, self.anchor.x, self.anchor.y)
    end
end

function InfoBox:IsDragging()
    return self._drag ~= nil
end

--- Click-capture mount (client-only; untested under the standalone Lua harness) -----------
-- The overlay Canvas effects.lua mounts is `clickthrough = true` (Canvas drawables are inert,
-- CONTEXT.md's Capture Layer note), so dragging the strip needs its own small clickable
-- component - same alpha-0 ui.Button + ONCLICK/ONRELEASE idiom ui/graph.lua's own Capture
-- Layer uses (`mousePos()` there), sized to the strip's current Bounds rather than the whole
-- screen since this capture must never swallow clicks meant for the game or the editor.

local function mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if ok and pos ~= nil then return pos.x, pos.y end
    return nil
end

function InfoBox:Mount(rootParent)
    if self._capture ~= nil then
        return
    end
    local area = self
    local ok, capture = pcall(function()
        local c = ui.Button.new(rootParent)
        c.alpha = 0
        c.clickthrough = HubLayers.PositionsLocked()
        c:Subscribe(ui.Hook.ONCLICK, function()
            local mx, my = mousePos()
            if mx ~= nil and area:BeginDrag(mx, my) then
                area:_expandCapture()
            end
        end)
        c:Subscribe(ui.Hook.ONRELEASE, function()
            area:EndDrag()
            area:Reposition()
        end)
        return c
    end)
    if ok then
        self._capture = capture
        self:Reposition()
    elseif log ~= nil then
        log("Watchdog infobox: Mount failed - " .. tostring(capture))
    end
end

function InfoBox:IsMounted()
    return self._capture ~= nil
end

-- Grows the capture layer to cover the whole screen for the duration of a drag, so the
-- release always routes back to us regardless of how far/fast the cursor moved (same idiom as
-- ui/graph.lua's expandCapture). The 4-arg SetSize is 0 absolute + 1.0 relative = full screen.
-- Also fronts it above every sibling (notably the editor's own Capture Layer, mounted after
-- ours) so crossing into the editor's area during a drag can't steal the hover and drop the
-- grab. main.lua restores the editor's z-order on drag end (Editor:RaiseToFront), so this
-- front-ing is scoped to the drag - the idle strip-sized capture never out-ranks the editor.
function InfoBox:_expandCapture()
    if self._capture == nil then return end
    pcall(function()
        self._capture:SetPos(0, 0)
        self._capture:SetSize(0, 0, 1.0, 1.0)
        self._capture:MoveToFront()
    end)
end

function InfoBox:Unmount()
    if self._capture ~= nil then
        pcall(function() self._capture:Destroy() end)
        self._capture = nil
    end
end

-- Resizes/repositions the capture layer to the strip's current on-screen Bounds - called once
-- per Logic tick (main.lua, alongside runtime:Update) since Bounds shift as tiles are added or
-- removed. An empty area (no live tiles) shrinks the capture to nothing so it can't sit over
-- the game or editor with nothing to actually drag.
function InfoBox:Reposition()
    if self._capture == nil then
        return
    end
    local locked = HubLayers.PositionsLocked()
    if locked and self:IsDragging() then
        self:EndDrag()
    end
    pcall(function()
        self._capture.clickthrough = locked
    end)
    if self:IsDragging() then
        return
    end
    local b = self:Bounds()
    pcall(function()
        if b == nil then
            self._capture:SetSize(0, 0)
        else
            self._capture:SetPos(b.x, b.y)
            self._capture:SetSize(b.w, b.h)
        end
    end)
end

--- Draw (client-only; untested under the bare Lua harness) ---------------------------------

local function textVec4(color)
    if color == nil then
        return Theme.Vec4(Theme.COL_INFOBOX_TEXT)
    end
    local a = (color.a == nil) and 255 or color.a
    return Vector4.new((color.r or 0) / 255, (color.g or 0) / 255, (color.b or 0) / 255, a / 255)
end

function InfoBox:Draw(canvas, hoverX, hoverY)
    if canvas == nil then return end
    local font = Theme.Font(Theme.INFOBOX_TEXT_PT)
    for _, r in ipairs(self:Layout()) do
        local box = r.box
        pcall(function() canvas:AddRectangle(r.x, r.y, r.w, r.h, Theme.Vec4(Theme.COL_INFOBOX_BG)) end)
        pcall(function()
            local t = Theme.BORDER_THICKNESS
            local bv = Theme.Vec4(Theme.COL_INFOBOX_BORDER)
            canvas:AddRectangle(r.x, r.y, r.w, t, bv)
            canvas:AddRectangle(r.x, r.y + r.h - t, r.w, t, bv)
            canvas:AddRectangle(r.x, r.y, t, r.h, bv)
            canvas:AddRectangle(r.x + r.w - t, r.y, t, r.h, bv)
        end)
        if box.icon ~= nil then
            -- AddSprite(x, y, w, h, spriteID, colourRGBA) - stretch the icon to fill the tile
            -- (see docs/research/popup-frame-sprites.md; no built-in 9-slice). Untinted white.
            pcall(function() canvas:AddSprite(r.x, r.y, r.w, r.h, box.icon, 0xFFFFFFFF) end)
        end
        if font ~= nil and box.text ~= nil and box.text ~= "" then
            -- Bottom-left of the tile so the icon (top) and text (bottom) stack like RuneLite.
            pcall(function()
                canvas:AddText(r.x + 2, r.y + r.h - Theme.INFOBOX_TEXT_PT - 2, box.text, font, textVec4(box.color))
            end)
        end
    end
    if hoverX ~= nil and hoverY ~= nil then
        self:_drawTooltip(canvas, hoverX, hoverY)
    end
end

function InfoBox:_drawTooltip(canvas, hoverX, hoverY)
    local title = self:TooltipAt(hoverX, hoverY)
    if title == nil then return end
    local font = Theme.Font(Theme.INFOBOX_TOOLTIP_PT)
    if font == nil then return end
    local pad = Theme.INFOBOX_TOOLTIP_PAD
    local w = (Theme.TextWidth(Theme.INFOBOX_TOOLTIP_PT, title) or (#title * 7)) + pad * 2
    local h = Theme.INFOBOX_TOOLTIP_PT + pad * 2
    local x, y = hoverX + 12, hoverY + 12
    pcall(function() canvas:AddRectangle(x, y, w, h, Theme.Vec4(Theme.COL_INFOBOX_TIP_BG)) end)
    pcall(function() canvas:AddText(x + pad, y + pad, title, font, Theme.Vec4(Theme.COL_INFOBOX_TIP_TX)) end)
end

return InfoBox
