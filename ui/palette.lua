local Theme = require("ui/theme")
local Unavailable = require("nodes/unavailable")

local Palette = {}
Palette.__index = Palette

-- Category display order: Triggers first, then Actions, then everything else
-- alphabetically. Lower rank sorts first; unranked categories share the same high rank
-- and fall back to an alphabetical tie-break.
local CATEGORY_RANK = { trigger = 1, action = 2 }

local function categoryRank(cat)
    return CATEGORY_RANK[cat] or math.huge
end

local function categoryLabel(cat)
    return cat:sub(1, 1):upper() .. cat:sub(2)
end

-- The text actually drawn for a row (a row with a description appends it inline) and its left
-- inset from the panel edge. Shared between width measurement and drawing so they can't
-- drift apart.
local ITEM_INSET = 14
local HEADER_INSET = 6

local function rowLabel(row)
    if row.header then return row.label or row.category end
    if row.description ~= nil and row.description ~= "" then
        return row.displayName .. " - " .. row.description
    end
    return row.displayName
end

local function rowInset(row)
    return row.header and HEADER_INSET or ITEM_INSET
end

function Palette.new()
    return setmetatable({
        open = false,
        rows = {},        -- flat draw list; header rows { header=true, category } or item rows
        scroll = 0,       -- rows scrolled off the top
        maxScroll = 0,    -- recomputed each Draw (needs the visible-row count)
        scrollDragging = false,  -- Editor sets this while dragging the scrollbar (thumb draws hot)
        screenX = 0,      -- where the panel was requested (clamped into the bounds rect at Draw)
        screenY = 0,
        anchorGX = 0,     -- Graph-space placement point (origin, or Body center when centerOnAnchor)
        anchorGY = 0,
        centerOnAnchor = false, -- + path (#96): place Node Body center on the anchor, not origin
        connect = nil,    -- { nodeId, entry } source Pin for drag-to-create; nil when unfiltered
        rect = nil,       -- last drawn panel rect + metrics, for hit-testing
    }, Palette)
end

-- Builds the row list from the Registry. `filterFn(def)` returns the name of the Pin to
-- auto-connect for a compatible Node Type (and optionally a second value, the Mode key to
-- create the Node in), or nil to exclude it; pass nil to include every type (unfiltered).
-- `opts` = { screenX, screenY, anchorGX, anchorGY, centerOnAnchor, connect }.
function Palette:Open(registry, filterFn, opts)
    self.rows = {}
    self.scroll = 0
    self.open = true
    self.screenX = opts.screenX
    self.screenY = opts.screenY
    self.anchorGX = opts.anchorGX
    self.anchorGY = opts.anchorGY
    self.centerOnAnchor = opts.centerOnAnchor == true
    self.connect = opts.connect

    local byCat, cats = {}, {}
    local function ensureCat(cat)
        if byCat[cat] == nil then
            byCat[cat] = {}
            cats[#cats + 1] = cat
        end
    end
    for key, def in pairs(registry.nodeTypes) do
        if def.hidden then goto continue end
        local targetPin, targetMode = true, nil
        if filterFn ~= nil then targetPin, targetMode = filterFn(def) end
        if targetPin then
            local cat = def.category or "other"
            ensureCat(cat)
            byCat[cat][#byCat[cat] + 1] = {
                typeKey = key,
                displayName = def.displayName or key,
                category = cat,
                -- Optional inline blurb (#52), rendered the same dimmed-suffix way as an
                -- unavailable row's "why"; nil for the many types that don't set one.
                description = def.description,
                -- Only carried in filtered mode; unfiltered opens leave them nil.
                targetPin = (filterFn ~= nil) and targetPin or nil,
                targetMode = (filterFn ~= nil) and targetMode or nil,
            }
        end
        ::continue::
    end

    -- Unavailable rows (nodes/unavailable.lua) are display-only and only make sense on an
    -- unfiltered open: a filtered/typed open exists to find a Pin-compatible Node Type,
    -- which nothing here has.
    if filterFn == nil then
        for _, entry in ipairs(Unavailable) do
            local cat = entry.category or "other"
            ensureCat(cat)
            byCat[cat][#byCat[cat] + 1] = {
                displayName = entry.displayName,
                category = cat,
                description = entry.description,
                unavailable = true,
            }
        end
    end

    table.sort(cats, function(a, b)
        local ra, rb = categoryRank(a), categoryRank(b)
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    for _, cat in ipairs(cats) do
        local items = byCat[cat]
        table.sort(items, function(a, b) return a.displayName < b.displayName end)
        self.rows[#self.rows + 1] = { header = true, category = cat, label = categoryLabel(cat) }
        for _, item in ipairs(items) do
            self.rows[#self.rows + 1] = item
        end
    end
end

function Palette:Close()
    self.open = false
    self.rows = {}
    self.rect = nil
    self.connect = nil
    self.centerOnAnchor = false
    self.scrollDragging = false
end

function Palette:Scroll(delta)
    if not self.open then return end
    local dir = delta > 0 and 1 or -1     -- wheel up scrolls toward the top
    self.scroll = self.scroll + dir * 3
    if self.scroll < 0 then self.scroll = 0 end
    if self.scroll > self.maxScroll then self.scroll = self.maxScroll end
end

function Palette:Draw(canvas, vx, vy, vw, vh, mx, my)
    if not self.open then return end
    local rowH = Theme.PALETTE_ROW_H
    local pad = Theme.PALETTE_PAD
    local total = #self.rows
    if total == 0 then return end

    -- Width fits the widest row (falls back to the fixed PALETTE_W when text metrics
    -- aren't available, e.g. a bare Lua runtime under test) so a long row description
    -- never gets clipped by the panel edge. Right margin mirrors the row's own
    -- left inset rather than the (smaller) panel-wide PALETTE_PAD, both for visual
    -- symmetry and so the fit isn't razor-thin against font-metric rounding.
    local maxPanelH = math.min(total * rowH + pad * 2, math.floor(vh * 0.92), Theme.PALETTE_MAX_H)
    local visibleRows = math.floor((maxPanelH - pad * 2) / rowH)
    if visibleRows < 1 then visibleRows = 1 end
    if visibleRows > total then visibleRows = total end
    local panelH = visibleRows * rowH + pad * 2

    -- The list overflows exactly when not every row is visible; only then is a scrollbar (and
    -- the gutter it needs) drawn. `rowW` is the width available to row text/hover/hit (measured
    -- from the panel's left px) - the full panel normally, pulled in by the reserved gutter when
    -- the scrollbar is present.
    local hasScrollbar = total > visibleRows
    local gutter = hasScrollbar and (Theme.PALETTE_SCROLLBAR_W + 2) or 0

    local panelW = Theme.PALETTE_W
    for _, row in ipairs(self.rows) do
        local w = Theme.TextWidth(12, rowLabel(row))
        if w ~= nil then
            local needed = rowInset(row) * 2 + w
            if needed > panelW then panelW = needed end
        end
    end
    -- Widen by the gutter so reserving it doesn't steal room from the text (rows keep their fit).
    panelW = math.min(panelW + gutter, vw)
    local rowW = panelW - gutter

    -- Clamp the panel inside the bounds rect so it stays on screen; the Editor expands its
    -- full-screen Capture Layer while the Palette is open, so every row (even one past the
    -- Window edge) is still over the capture and clickable.
    local px, py = self.screenX, self.screenY
    if px + panelW > vx + vw then px = vx + vw - panelW end
    if py + panelH > vy + vh then py = vy + vh - panelH end
    if px < vx then px = vx end
    if py < vy then py = vy end

    self.maxScroll = math.max(0, total - visibleRows)
    if self.scroll > self.maxScroll then self.scroll = self.maxScroll end
    if self.scroll < 0 then self.scroll = 0 end

    canvas:AddRectangle(px, py, panelW, panelH, Theme.Vec4(Theme.COL_PALETTE_BG))
    canvas:AddOutline(px, py, panelW, panelH, Theme.BORDER_THICKNESS,
        Theme.Vec4(Theme.COL_PALETTE_BORDER))

    local font = Theme.Font(12)
    for i = 1, visibleRows do
        local row = self.rows[self.scroll + i]
        if row ~= nil then
            local ry = py + pad + (i - 1) * rowH
            if row.header then
                canvas:AddRectangle(px + 1, ry, rowW - 2, rowH,
                    Theme.Vec4(Theme.COL_PALETTE_HEADER_BG))
                if font ~= nil then
                    canvas:AddText(px + HEADER_INSET, ry + 3, rowLabel(row), font,
                        Theme.Vec4(Theme.COL_PALETTE_HEADER_TX))
                end
            else
                -- Unavailable rows are inert (RowAt excludes them): no hover highlight, no
                -- click affordance to suggest otherwise. The gutter is not part of a row, so
                -- hovering it (mx past the row width) highlights nothing.
                local hovered = not row.unavailable
                    and mx >= px and mx <= px + rowW and my >= ry and my < ry + rowH
                if hovered then
                    canvas:AddRectangle(px + 1, ry, rowW - 2, rowH,
                        Theme.Vec4(Theme.COL_PALETTE_HOVER))
                end
                if font ~= nil then
                    local tx, ty = px + ITEM_INSET, ry + 3
                    local nameColor = row.unavailable and Theme.COL_PALETTE_TEXT_DIM
                        or Theme.COL_PALETTE_TEXT
                    canvas:AddText(tx, ty, row.displayName, font, Theme.Vec4(nameColor))
                    -- The description suffix is always dimmed, so it reads as a secondary
                    -- blurb whether the row is a live Node Type or an unavailable one. Drawn
                    -- as its own call, offset by the measured name width (falls back to no
                    -- offset when text metrics aren't available, e.g. under the test harness).
                    if row.description ~= nil and row.description ~= "" then
                        local nameW = Theme.TextWidth(12, row.displayName)
                        local sx = nameW ~= nil and (tx + nameW) or tx
                        canvas:AddText(sx, ty, " - " .. row.description, font,
                            Theme.Vec4(Theme.COL_PALETTE_TEXT_DIM))
                    end
                end
            end
        end
    end

    local scrollbar = nil
    if hasScrollbar then
        local trackX = px + panelW - Theme.PALETTE_SCROLLBAR_W - 1
        local trackY = py + pad
        local trackW = Theme.PALETTE_SCROLLBAR_W
        local trackH = visibleRows * rowH
        local thumbH = math.max(Theme.PALETTE_SCROLLBAR_MIN_THUMB,
            math.floor(visibleRows / total * trackH))
        if thumbH > trackH then thumbH = trackH end
        local usable = trackH - thumbH
        local frac = self.maxScroll > 0 and (self.scroll / self.maxScroll) or 0
        local thumbY = trackY + math.floor(usable * frac + 0.5)

        canvas:AddRectangle(trackX, trackY, trackW, trackH, Theme.Vec4(Theme.COL_PALETTE_TRACK))
        local thumbCol = self.scrollDragging and Theme.COL_PALETTE_THUMB_HOT or Theme.COL_PALETTE_THUMB
        canvas:AddRectangle(trackX, thumbY, trackW, thumbH, Theme.Vec4(thumbCol))

        scrollbar = { x = trackX, y = trackY, w = trackW, h = trackH, thumbH = thumbH }
    end

    self.rect = { x = px, y = py, w = panelW, h = panelH, rowW = rowW,
                  pad = pad, rowH = rowH, visibleRows = visibleRows, scrollbar = scrollbar }
end

function Palette:ScrollbarAt(sx, sy)
    local r = self.rect
    if not self.open or r == nil or r.scrollbar == nil then return false end
    local sb = r.scrollbar
    return sx >= sb.x and sx <= sb.x + sb.w and sy >= sb.y and sy <= sb.y + sb.h
end

-- Maps a screen Y to a scroll position: the thumb centers under the cursor (so a press-anywhere
-- jump and a subsequent drag share one mapping), clamped so the ends saturate at 0 / maxScroll.
-- Inert when there's no scrollbar.
function Palette:ScrollToY(sy)
    local r = self.rect
    if not self.open or r == nil or r.scrollbar == nil then return end
    local sb = r.scrollbar
    local usable = sb.h - sb.thumbH
    local frac = 0
    if usable > 0 then frac = (sy - sb.y - sb.thumbH / 2) / usable end
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    self.scroll = math.floor(frac * self.maxScroll + 0.5)
end

-- The item row under a screen point, or nil (header rows, unavailable rows, and empty
-- padding all return nil - an unavailable row has nothing to create).
function Palette:RowAt(sx, sy)
    local r = self.rect
    if not self.open or r == nil then return nil end
    -- Rows only span the row width; the gutter beyond it belongs to the scrollbar, so a press
    -- there is not a row (and must not be, or it'd swallow the scroll-drag the Editor wants).
    if sx < r.x or sx > r.x + r.rowW or sy < r.y or sy > r.y + r.h then return nil end
    local i = math.floor((sy - (r.y + r.pad)) / r.rowH) + 1
    if i < 1 or i > r.visibleRows then return nil end
    local row = self.rows[self.scroll + i]
    if row ~= nil and not row.header and not row.unavailable then return row end
    return nil
end

function Palette:Contains(sx, sy)
    local r = self.rect
    if not self.open or r == nil then return false end
    return sx >= r.x and sx <= r.x + r.w and sy >= r.y and sy <= r.y + r.h
end

return Palette
