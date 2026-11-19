local Theme = require("src/ui/theme")

local CaptureBanner = {}

CaptureBanner.SCREEN_TEXT = "Drag to select a region · Esc to cancel"
CaptureBanner.OBJECT_TEXT = "Select Object on scenery · Esc to cancel"
CaptureBanner.BUFF_TEXT = "Click a buff in the window · Esc to cancel"

local BANNER_H = 40
local BANNER_PAD_Y = 8

---@param canvas any
---@param text string
---@param screenW number|nil
function CaptureBanner.Draw(canvas, text, screenW)
    if canvas == nil or text == nil or text == "" then
        return
    end
    local w = screenW or 1920
    pcall(function()
        if (screenW == nil) and canvas.width and canvas.width > 0 then w = canvas.width end
    end)
    local y = BANNER_PAD_Y
    local bgVec = Theme.Vec4(Theme.COL_CAPTURE_BANNER_BG)
    local fgVec = Theme.Vec4(Theme.COL_CAPTURE_BANNER_FG)
    pcall(function()
        canvas:AddRectangle(0, y, w, BANNER_H, bgVec)
    end)
    local font = Theme.Font(14)
    if canvas.AddText ~= nil and font ~= nil then
        pcall(function()
            canvas:AddText(24, y + 12, tostring(text), font, fgVec)
        end)
    end
end

return CaptureBanner
