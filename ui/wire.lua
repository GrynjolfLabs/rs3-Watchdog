-- Canvas has no native curve - tessellate a cubic into AddLine segments.

local Theme = require("ui/theme")

local Wire = {}

local function cubic(p0, p1, p2, p3, t)
    local u = 1 - t
    return u * u * u * p0
        + 3 * u * u * t * p1
        + 3 * u * t * t * p2
        + t * t * t * p3
end

-- Intersect a segment's parameter range with one viewport axis.
local function clipAxis(origin, delta, minimum, maximum, first, last)
    if delta == 0 then
        if origin < minimum or origin > maximum then return nil end
        return first, last
    end
    local a, b = (minimum - origin) / delta, (maximum - origin) / delta
    if a > b then a, b = b, a end
    first, last = math.max(first, a), math.min(last, b)
    if first > last then return nil end
    return first, last
end

function Wire.DrawCurve(canvas, view, x0, y0, dir0, x1, y1, dir1, color, vx, vy, vw, vh)
    local s0x, s0y = view:ToScreen(x0, y0)
    local s1x, s1y = view:ToScreen(x1, y1)

    -- Floor the tangent so short/vertical wires still bow into an S.
    local tang = math.max(math.abs(s1x - s0x) * 0.5, view:Scale(60))
    local c0x, c0y = s0x + dir0 * tang, s0y
    local c1x, c1y = s1x + dir1 * tang, s1y

    local thickness = math.max(1, view:Scale(Theme.WIRE_THICKNESS))
    -- Inset by the stroke extent so caps and integer rounding cannot cross chrome.
    local inset = math.ceil(thickness) + 1
    local left, top = vx + inset, vy + inset
    local right, bottom = vx + vw - inset, vy + vh - inset
    if right < left or bottom < top then return end
    local vcol = Theme.Vec4(color)
    local segments = Theme.WIRE_SEGMENTS

    local px, py = s0x, s0y
    for i = 1, segments do
        local t = i / segments
        local nx = cubic(s0x, c0x, c1x, s1x, t)
        local ny = cubic(s0y, c0y, c1y, s1y, t)
        local dx, dy = nx - px, ny - py
        local first, last = clipAxis(px, dx, left, right, 0, 1)
        if first then first, last = clipAxis(py, dy, top, bottom, first, last) end
        if first then
            canvas:AddLine(px + dx * first, py + dy * first,
                px + dx * last, py + dy * last, thickness, vcol)
        end
        px, py = nx, ny
    end
end

function Wire.ColorFor(kind, dataType)
    if kind == "exec" then
        return Theme.COL_EXEC
    end
    return Theme.TypeColor(dataType)
end

function Wire.DirFor(direction)
    return direction == "out" and 1 or -1
end

return Wire
