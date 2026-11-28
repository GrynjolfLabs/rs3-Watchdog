-- The edit toolbar at the canvas top left. Drawn on the editor Canvas and hit-tested by hand
-- like the Palette (ADR-0001). Coordinates are content-local.

local Theme = require("src/ui/theme")

local EditToolbar = {}
EditToolbar.__index = EditToolbar

local X, Y, H, PAD, GAP, GROUP_GAP, PT = 8, 8, 20, 6, 2, 8, 11

-- `group` starts a new group with a wider gap. `hint` is the hover tooltip.
local BUTTONS = {
    { id = "undo", label = "Undo", hint = "Undo (Ctrl+Z)" },
    { id = "redo", label = "Redo", hint = "Redo (Ctrl+Y)" },
    { id = "cut", label = "Cut", hint = "Cut (Ctrl+X)", group = true },
    { id = "copy", label = "Copy", hint = "Copy (Ctrl+C)" },
    { id = "paste", label = "Paste", hint = "Paste (Ctrl+V)" },
    { id = "delete", label = "Delete", hint = "Delete (Del)", group = true },
}

local function textWidth(text)
    return math.ceil(Theme.TextWidth(PT, text) or (#text * 6))
end

local function inside(r, mx, my)
    return mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
end

--- Lowest content-local y the strip covers.
function EditToolbar.Bottom()
    return Y + H + 2
end

function EditToolbar.new()
    local rects, x = {}, X
    for i, b in ipairs(BUTTONS) do
        if i > 1 then x = x + (b.group and GROUP_GAP or GAP) end
        local w = textWidth(b.label) + PAD * 2
        rects[#rects + 1] = { id = b.id, label = b.label, hint = b.hint, x = x, y = Y, w = w, h = H }
        x = x + w
    end
    -- The strip includes the gaps, so a click between buttons does not reach the canvas.
    return setmetatable({ rects = rects, strip = { x = X - 2, y = Y - 2, w = x - X + 4, h = H + 4 } },
        EditToolbar)
end

function EditToolbar:Contains(mx, my)
    return inside(self.strip, mx, my)
end

function EditToolbar:ButtonAt(mx, my)
    for _, r in ipairs(self.rects) do
        if inside(r, mx, my) then return r end
    end
    return nil
end

---@param enabled table<string, boolean>
function EditToolbar:Draw(canvas, enabled, mx, my)
    local font = Theme.Font(PT)
    local s = self.strip
    canvas:AddRectangle(s.x, s.y, s.w, s.h, Theme.Vec4(Theme.COL_PALETTE_BG))
    local function box(x, y, w, text, bg, fg)
        canvas:AddRectangle(x, y, w, H, Theme.Vec4(bg))
        canvas:AddOutline(x, y, w, H, 1, Theme.Vec4(Theme.COL_PALETTE_BORDER))
        if font ~= nil then canvas:AddText(x + PAD, y + 3, text, font, Theme.Vec4(fg)) end
    end
    local hovered = self:ButtonAt(mx, my)
    for _, r in ipairs(self.rects) do
        local on = enabled[r.id] == true
        box(r.x, r.y, r.w, r.label,
            (on and r == hovered) and Theme.COL_PALETTE_HOVER or Theme.COL_PALETTE_HEADER_BG,
            on and Theme.COL_PALETTE_TEXT or Theme.COL_PALETTE_TEXT_DIM)
    end
    if hovered ~= nil then
        box(hovered.x, hovered.y + H + 4, textWidth(hovered.hint) + PAD * 2, hovered.hint,
            Theme.COL_PALETTE_BG, Theme.COL_PALETTE_TEXT)
    end
end

return EditToolbar
