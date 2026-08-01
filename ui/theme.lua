-- theme.lua — colors, sizing, and font resolution for the graph Editor.
--
-- Pure data + a couple of defensive lookups. Colors are stored as plain {r,g,b,a}
-- tables (channels 0..1) and converted to the client's Vector4 only at draw time via
-- Theme.Vec4, so this module has no hard dependency on client globals at load. All
-- sizes are in Graph-space interface units at zoom = 1.0; the View scales them.

local Theme = {}

-- Builds a color table from 0..255 RGB and 0..1 alpha.
local function col(r, g, b, a)
    return { r / 255, g / 255, b / 255, a or 1 }
end

--- Sizing (Graph-space units at zoom 1.0) -------------------------------------------

Theme.NODE_WIDTH       = 250   -- default node body width
Theme.HEADER_HEIGHT    = 26    -- category-colored title band
Theme.PIN_ROW_HEIGHT   = 24    -- vertical stride between pin rows
Theme.BODY_PAD_TOP     = 8     -- gap between header and first pin row
Theme.BODY_PAD_BOTTOM  = 10    -- gap below the last pin row
Theme.PIN_MARGIN_X     = 10    -- inset of a pin glyph's center from the node edge
Theme.PIN_GLYPH        = 12    -- pin glyph bounding size (square/triangle extent)
Theme.PIN_LABEL_GAP    = 8     -- gap between a pin glyph and its label
Theme.PIN_HIT_PAD      = 4     -- extra hit-test padding around a pin glyph
Theme.CLOSE_SIZE       = 14    -- delete-button glyph bounding size, in the header
Theme.CLOSE_MARGIN     = 14    -- inset of the close glyph's center from the node's right edge

-- Inline Control value box (ADR-0004): drawn on an unconnected data-input Pin's row, edited
-- via a transient real InputField/ComboField. The box sits in a "value column" to the right
-- of the pin label; on rows that also carry an output pin it stops short to leave room.
Theme.CONTROL_H            = 16    -- value box height within a PIN_ROW_HEIGHT row
Theme.CONTROL_LABEL_CHAR_W = 7     -- approx per-char label width (graph units) for reserving room
Theme.CONTROL_LABEL_GAP    = 8     -- gap kept between the input label and the value box
Theme.CONTROL_OUT_RESERVE  = 52    -- space kept for an output pin+label sharing the row
Theme.CONTROL_PAD_X        = 5     -- inner text inset / right inset when no output shares the row
Theme.CONTROL_MIN_W        = 12    -- never draw a value box narrower than this (graph-space)
Theme.CONTROL_MIN_ZOOM     = 0.45  -- below this the box/text is unreadable, so it isn't drawn
-- The transient editor is a real component with a native, fixed-pixel font that does NOT
-- scale with the View, so it's sized in screen pixels independent of zoom (height fixed;
-- width tracks the box but never below the min). Sizing it to view:Scale(box) made the text
-- unreadable at zoom 1 — the box was 16px tall but the native font needs more.
Theme.CONTROL_EDIT_MIN_W   = 60    -- min screen width for the transient editor component
Theme.CONTROL_EDIT_H       = 24    -- fixed screen height for the transient editor component

-- coordgrid composite control (#25): a full-width band below the pin's own row, holding 3
-- inline x/z/level fields and a "Set to current position" button. Reuses CONTROL_MIN_ZOOM for
-- its own draw/hit gating; its height is what a pin row's extraH reserves.
Theme.COORDGRID_TOP_GAP    = 4     -- gap between the pin row and the field row
Theme.COORDGRID_FIELD_H    = 16    -- x/z/level field height
Theme.COORDGRID_MID_GAP    = 4     -- gap between the field row and the button row
Theme.COORDGRID_BUTTON_H   = 16    -- "Set to current position" button height
Theme.COORDGRID_BOTTOM_GAP = 4     -- gap kept below the button, before the next pin row
Theme.COORDGRID_FIELD_GAP  = 4     -- horizontal gap between the 3 fields
Theme.COORDGRID_BAND_H     = Theme.COORDGRID_TOP_GAP + Theme.COORDGRID_FIELD_H
    + Theme.COORDGRID_MID_GAP + Theme.COORDGRID_BUTTON_H + Theme.COORDGRID_BOTTOM_GAP

-- matcher composite control (#56): a single-row band below the pin's own row, holding a text
-- field (the needle) and a 2-way Substring/Pattern toggle button after it. Same CONTROL_MIN_ZOOM
-- draw/hit gating as coordgrid; its height is what a matcher pin row's extraH reserves.
Theme.MATCHER_TOP_GAP    = 4     -- gap between the pin row and the field/toggle row
Theme.MATCHER_FIELD_H    = 16    -- needle field / toggle button height
Theme.MATCHER_GAP        = 4     -- horizontal gap between the needle field and the toggle
Theme.MATCHER_TOGGLE_W   = 64    -- toggle button width (fits "Substring")
Theme.MATCHER_BOTTOM_GAP = 4     -- gap kept below the row, before the next pin row
Theme.MATCHER_BAND_H     = Theme.MATCHER_TOP_GAP + Theme.MATCHER_FIELD_H + Theme.MATCHER_BOTTOM_GAP

-- object_marker mode multi-select (#40): a full-width composite band below the pin's own row,
-- holding one checkbox row per mode. Same CONTROL_MIN_ZOOM draw/hit gating as coordgrid. These are
-- per-row sizes only — the number of rows (and thus the band height) is derived from the node's own
-- mode list via Theme.ModeBandH(count), so the row count lives in ONE place (ObjectMarker.MODES).
Theme.MODE_TOP_GAP    = 4      -- gap between the pin row and the first checkbox row
Theme.MODE_ROW_H      = 16     -- one checkbox row height
Theme.MODE_ROW_GAP    = 3      -- vertical gap between checkbox rows
Theme.MODE_BOTTOM_GAP = 4      -- gap kept below the last row, before the next pin row

-- The extraH a mode band of `count` checkbox rows reserves below its pin row.
function Theme.ModeBandH(count)
    if count <= 0 then return Theme.MODE_TOP_GAP + Theme.MODE_BOTTOM_GAP end
    return Theme.MODE_TOP_GAP + count * Theme.MODE_ROW_H
        + (count - 1) * Theme.MODE_ROW_GAP + Theme.MODE_BOTTOM_GAP
end

-- color swatch control (#30): the on-pin chip is a value-column box like a scalar Control
-- (Theme.CONTROL_H tall), but a fixed, narrower width so it reads as a color chip rather
-- than a text field. Checker cell is graph-space (scales with zoom like everything else on
-- the node); the popup's own checker (behind the SV/alpha previews) is screen-space fixed,
-- since the popup itself doesn't scale with the View (see Theme.COLOR_POPUP_* below).
Theme.SWATCH_W             = 46
Theme.SWATCH_CHECKER_CELL  = 4

-- color-picker popup (#30): a Canvas-drawn transient layer opened from the swatch chip,
-- positioned in the same fixed screen-space as the Palette (not scaled by the View — see
-- ui/color_popup.lua). Sized to comfortably fit the SV field, hue strip, prev/cur swatches,
-- hex field, and R/G/B/A rows stacked top-to-bottom.
Theme.COLOR_POPUP_W        = 220   -- popup width
Theme.COLOR_POPUP_PAD      = 10    -- inner padding around the body content
Theme.COLOR_POPUP_HEADER_H = 22    -- title band height
Theme.COLOR_POPUP_SV_H     = 110   -- saturation/value field height
Theme.COLOR_POPUP_HUE_H    = 14    -- hue strip height
Theme.COLOR_POPUP_ROW_H    = 18    -- prev/cur, hex, and each R/G/B/A row share this height
Theme.COLOR_POPUP_ROW_GAP  = 6     -- vertical gap between stacked rows
Theme.COLOR_POPUP_CHECKER_CELL = 6 -- screen-px checker cell behind the alpha preview

-- Toast (#36): a small draggable notification drawn on the always-on effect overlay
-- Canvas (effects.lua), NOT the editor's own Canvas — fixed screen-space, not scaled by the
-- View. Body + a left accent bar (the `color` data pin's dynamic tint) + outline + optional
-- icon sprite + text, stacked vertically below the shared, draggable anchor.
Theme.TOAST_W            = 240   -- toast width
Theme.TOAST_H            = 48    -- toast height
Theme.TOAST_GAP          = 6     -- vertical gap between stacked toasts
Theme.TOAST_ACCENT_W     = 3     -- left accent bar width
Theme.TOAST_ICON_SIZE    = 28    -- optional icon sprite bounding box
Theme.TOAST_PAD_X        = 8     -- inner left/right padding
Theme.TOAST_TOP_MARGIN   = 24    -- default anchor distance below the top of the screen

Theme.COL_TOAST_BG     = col(24, 24, 28, 0.92)
Theme.COL_TOAST_BORDER = col(10, 10, 12, 1.0)
Theme.COL_TOAST_TEXT   = col(230, 230, 236, 1.0)

-- InfoBox strip (#41): a wrapping row of fixed square icon+text tiles drawn on the effect
-- overlay Canvas (like the toast, fixed screen-space), one tile per action.infobox
-- node, laid out left-to-right from a shared draggable anchor and wrapping past a width.
Theme.INFOBOX_BOX_SIZE   = 36    -- side of each fixed square icon+text tile
Theme.INFOBOX_GAP        = 2     -- gap between adjacent tiles (both axes)
Theme.INFOBOX_DEFAULT_X  = 8     -- default anchor: top-left corner, small inset
Theme.INFOBOX_DEFAULT_Y  = 8
Theme.INFOBOX_WRAP_WIDTH = 220   -- row wraps once it would exceed this pixel width
Theme.INFOBOX_TEXT_PT    = 14    -- point size for the value text drawn on a tile
Theme.INFOBOX_TOOLTIP_PT = 12    -- point size for the hover tooltip
Theme.INFOBOX_TOOLTIP_PAD = 4    -- inner padding around the tooltip text

Theme.COL_INFOBOX_BG      = col(30, 30, 34, 0.85)
Theme.COL_INFOBOX_BORDER  = col(12, 12, 15, 1.0)
Theme.COL_INFOBOX_TEXT    = col(255, 255, 255, 1.0)  -- default (unset/nil color) — white
Theme.COL_INFOBOX_TIP_BG  = col(18, 18, 22, 0.96)    -- hover tooltip backing
Theme.COL_INFOBOX_TIP_TX  = col(230, 232, 240, 1.0)

Theme.BORDER_THICKNESS = 2
Theme.WIRE_THICKNESS   = 3
Theme.WIRE_SEGMENTS    = 16    -- straight segments a bezier Wire is tessellated into
Theme.GRID_SPACING     = 32    -- background grid cell size

-- Text can't shrink past the smallest font (font IDs are discrete — ADR-0001), so labels
-- are dropped when zoomed out rather than left to overflow. Degrades in two stages: pin
-- labels go first, node titles persist further out so nodes stay identifiable.
Theme.LABEL_MIN_ZOOM   = 0.45   -- pin labels
Theme.TITLE_MIN_ZOOM   = 0.30   -- node titles

Theme.ZOOM_MIN = 0.25
Theme.ZOOM_MAX = 2.0

--- Window (defaults / host chrome) ------------------------------------------------------

-- Default content size seed before Mount syncs from the live content parent. Screen
-- placement (x/y) is owned by PrettyUI; WINDOW_X/Y are only fallbacks for self.window
-- until syncContentOrigin runs. WINDOW_HEADER_H is retained for any host/docs that still
-- describe PrettyUI title height — the Editor itself no longer insets by it.
Theme.WINDOW_X        = 600
Theme.WINDOW_Y        = 340
Theme.WINDOW_W        = 900
Theme.WINDOW_H        = 560
Theme.WINDOW_HEADER_H = 28
Theme.WINDOW_TITLE    = "Watchdog — Editor"

--- Palette (screen-space popup) + toolbar -----------------------------------------------

Theme.PALETTE_W     = 220   -- popup width (clamped to the Viewport if narrower)
Theme.PALETTE_ROW_H = 20    -- uniform row height (headers and items share it)
Theme.PALETTE_PAD   = 6      -- inner padding above/below the row list
Theme.PALETTE_MAX_H = 400   -- cap the popup height so a big Registry doesn't fill the screen
                            -- (scrolls past this); also bounded to 92% of the draw rect

-- Scrollbar in the reserved right gutter (only drawn when the list overflows). Press-anywhere
-- jumps the thumb under the cursor and scrubs (see Palette:ScrollToY); the wheel still scrolls.
Theme.PALETTE_SCROLLBAR_W         = 8   -- gutter/track width reserved on the panel's right edge
Theme.PALETTE_SCROLLBAR_MIN_THUMB = 24  -- floor on the proportional thumb so it stays grabbable

-- Two clicks pairing into a double-click that opens the Palette on empty space.
Theme.DOUBLECLICK_TICKS = 12  -- Logic ticks (~0.02s each) allowed between the two clicks
Theme.DOUBLECLICK_DIST  = 6   -- max screen-px drift between the two clicks

-- Alert Manager drag drop-target bands (#92): fraction of a row's height. The middle band of a
-- *group* row nests into that group; outside it (and every alert row) is sibling reorder.
Theme.MANAGER_NEST_BAND_LO = 0.25
Theme.MANAGER_NEST_BAND_HI = 0.75
Theme.MANAGER_ROW_H        = 22    -- tree row height (matches ui/manager.lua ROW_H)

--- Colors --------------------------------------------------------------------------

Theme.COL_VIEWPORT_BG = col(26, 26, 30, 1.0)
Theme.COL_GRID        = col(40, 40, 47, 1.0)
Theme.COL_GRID_MAJOR  = col(52, 52, 60, 1.0)

Theme.COL_WINDOW_BORDER = col(12, 12, 15, 1.0)

-- Palette popup + its toolbar launcher.
Theme.COL_PALETTE_BG        = col(32, 32, 38, 0.98)
Theme.COL_PALETTE_BORDER    = col(12, 12, 15, 1.0)
Theme.COL_PALETTE_HEADER_BG = col(48, 48, 58, 1.0)
Theme.COL_PALETTE_HEADER_TX = col(150, 190, 230, 1.0)  -- category label
Theme.COL_PALETTE_HOVER     = col(60, 70, 90, 1.0)      -- row under the cursor
Theme.COL_PALETTE_TEXT      = col(220, 222, 230, 1.0)
Theme.COL_PALETTE_TEXT_DIM  = col(130, 132, 140, 1.0)  -- unavailable-node row + its reason
Theme.COL_PALETTE_TRACK     = col(22, 22, 26, 1.0)      -- recessed scrollbar track backing
Theme.COL_PALETTE_THUMB     = col(80, 88, 104, 1.0)     -- scrollbar thumb
Theme.COL_PALETTE_THUMB_HOT = col(110, 122, 148, 1.0)   -- thumb while being dragged

Theme.COL_NODE_BODY   = col(43, 43, 48, 0.96)
Theme.COL_NODE_BORDER = col(15, 15, 18, 1.0)

-- Unknown-node placeholder (#53): a desaturated, muted box so it reads as inert/degraded —
-- distinct from any real category color, signalling "a node used to be here."
Theme.COL_NODE_UNKNOWN_BODY   = col(38, 36, 40, 0.94)
Theme.COL_NODE_UNKNOWN_HEADER = col(74, 68, 60, 1.0)   -- muted amber-grey (a warning, dimmed)
Theme.COL_NODE_SEL    = col(240, 160, 32, 1.0)  -- selected/hovered node border
Theme.COL_TITLE       = col(240, 240, 244, 1.0)
Theme.COL_PIN_LABEL   = col(198, 200, 208, 1.0)

-- Header delete button: muted by default, reddening when the cursor is over it.
Theme.COL_CLOSE       = col(210, 210, 216, 1.0)
Theme.COL_CLOSE_HOT   = col(255, 120, 120, 1.0)
Theme.COL_CLOSE_BG    = col(150, 40, 40, 0.85)  -- hover backing behind the glyph

-- Inline Control value box.
Theme.COL_CONTROL_BG     = col(28, 28, 33, 1.0)
Theme.COL_CONTROL_BORDER = col(70, 70, 82, 1.0)
Theme.COL_CONTROL_HOT    = col(240, 160, 32, 1.0)   -- border under the cursor
Theme.COL_CONTROL_TEXT   = col(225, 227, 233, 1.0)
Theme.COL_CONTROL_EMPTY  = col(120, 122, 132, 1.0)  -- placeholder when the value is empty
Theme.COL_CONTROL_CARET  = col(170, 172, 182, 1.0)  -- enum dropdown ▾ indicator
Theme.COL_CONTROL_ACTION_BG = col(52, 56, 66, 1.0)  -- composite-control action button (e.g. coordgrid's "set to current position")
Theme.COL_CHECK_BOX_BG   = col(20, 20, 24, 1.0)     -- mode checkbox (#40) inner fill
Theme.COL_CHECK_MARK     = col(245, 205, 70, 1.0)   -- mode checkbox tick — gold, drawn when checked

-- Checkerboard behind a color swatch/preview, so alpha reads visually (#30).
Theme.COL_CHECKER_LIGHT = col(150, 150, 150, 1.0)
Theme.COL_CHECKER_DARK  = col(90, 90, 90, 1.0)

-- Screen Marker's "Draw on screen" full-screen capture overlay (#39): a dim wash over the
-- whole screen while a drag is in progress, and the in-progress selection box drawn on top.
Theme.COL_SCREEN_MARKER_DIM  = col(0, 0, 0, 0.35)
Theme.COL_SCREEN_MARKER_DRAG = col(255, 255, 255, 1.0)

-- Execution pins and wires use one fixed neutral color (they carry no Type Tag).
Theme.COL_EXEC        = col(242, 242, 242, 1.0)

-- Per-exec-in-pin "test" button: a small square between an exec-in pin's glyph and its label
-- that fires that pin (calls the node's run as if the wire had fired) for testing. Drawn/hit
-- on the same CONTROL_MIN_ZOOM gate as inline Control boxes.
Theme.TEST_BTN_W        = 18                        -- square button side (graph units)
Theme.COL_TEST_BTN_BG   = col(46, 78, 52, 1.0)      -- muted green (a "run/play" affordance)
Theme.COL_TEST_BTN_HOT  = col(120, 210, 130, 1.0)   -- border + glyph under the cursor
Theme.COL_TEST_BTN_GLYPH = col(200, 240, 205, 1.0)  -- the ▶ play triangle

-- Category -> header band color. Opaque consumer tags; unknowns fall back.
Theme.CATEGORY_COLORS = {
    trigger = col(155, 47, 47, 1.0),   -- red-ish (events)
    action  = col(47, 95, 155, 1.0),   -- blue (side effects)
    flow    = col(70, 70, 80, 1.0),    -- grey (branch/sequence)
    math    = col(47, 130, 90, 1.0),   -- green
    logic   = col(120, 90, 150, 1.0),  -- purple (boolean/compare)
}
Theme.DEFAULT_CATEGORY_COLOR = col(85, 85, 96, 1.0)

-- Type Tag -> Data pin/wire color (loosely following Blueprint conventions).
Theme.TYPE_COLORS = {
    any    = col(176, 176, 176, 1.0),  -- wildcard: grey
    bool   = col(150, 47, 47, 1.0),    -- red
    number = col(63, 159, 111, 1.0),   -- green
    string = col(192, 63, 159, 1.0),   -- magenta
    coord  = col(208, 160, 32, 1.0),   -- gold
}
Theme.DEFAULT_TYPE_COLOR = col(176, 176, 176, 1.0)

--- Lookups -------------------------------------------------------------------------

function Theme.CategoryColor(category)
    return Theme.CATEGORY_COLORS[category] or Theme.DEFAULT_CATEGORY_COLOR
end

function Theme.TypeColor(tag)
    return Theme.TYPE_COLORS[tag] or Theme.DEFAULT_TYPE_COLOR
end

-- Converts a {r,g,b,a} color to the client's Vector4. Deferred to draw time because
-- Vector4 is a client global that may be absent under a bare Lua runtime.
function Theme.Vec4(c)
    return Vector4.new(c[1], c[2], c[3], c[4])
end

--- Fonts ---------------------------------------------------------------------------

local fontCache = {}

local function fontByName(name)
    if id == nil or id.Font == nil then
        return nil
    end
    local ok, font = pcall(function() return id.Font[name] end)
    -- A missing size can come back as a truthy-but-invalid sentinel (0/-1) rather than
    -- nil; only a positive numeric id is a real font. Rejecting the rest lets Theme.Font's
    -- nearest-size search find a font that actually renders (fixes text vanishing at some
    -- zoom levels).
    if ok and type(font) == "number" and font > 0 then
        return font
    end
    return nil
end

-- Resolves a MUSEO_SANS font ID at (or near) the requested point size, searching
-- outward for the nearest available bucket. Cached per size. Returns nil if fonts
-- are unavailable (caller then skips text).
function Theme.Font(pt)
    pt = math.max(8, math.min(40, math.floor(pt + 0.5)))
    if fontCache[pt] ~= nil then
        return fontCache[pt] or nil
    end

    local function fontAt(sz)
        return fontByName("MUSEO_SANS_" .. sz .. "PT_REGULAR")
            or fontByName("MUSEO_SANS_" .. sz .. "PT")
    end

    local font = fontAt(pt)
    if font == nil then
        for offset = 1, 32 do
            local lo, hi = pt - offset, pt + offset
            if lo >= 8 then font = fontAt(lo) end
            if font == nil and hi <= 40 then font = fontAt(hi) end
            if font ~= nil then break end
        end
    end

    fontCache[pt] = font or false  -- cache the miss too, so we don't re-scan every frame
    return font or nil
end

-- The measurable font OBJECT (a `config.Font` / FontType with :GetStringWidth), as opposed
-- to Theme.Font's integer id used by canvas:AddText. Same nearest-size search + caching.
local fontObjCache = {}

local function fontObjByName(name)
    if config == nil or config.Font == nil then return nil end
    local ok, f = pcall(function() return config.Font[name] end)
    if ok and f ~= nil then return f end
    return nil
end

local function fontObjAt(sz)
    return fontObjByName("MUSEO_SANS_" .. sz .. "PT_REGULAR")
        or fontObjByName("MUSEO_SANS_" .. sz .. "PT")
end

function Theme.FontObject(pt)
    pt = math.max(8, math.min(40, math.floor(pt + 0.5)))
    if fontObjCache[pt] ~= nil then return fontObjCache[pt] or nil end
    local f = fontObjAt(pt)
    if f == nil then
        for offset = 1, 32 do
            local lo, hi = pt - offset, pt + offset
            if lo >= 8 then f = fontObjAt(lo) end
            if f == nil and hi <= 40 then f = fontObjAt(hi) end
            if f ~= nil then break end
        end
    end
    fontObjCache[pt] = f or false
    return f or nil
end

-- Pixel width of `text` drawn at ~`pt`, tags ignored, via the real font metrics — or nil if
-- fonts/metrics are unavailable (a bare Lua runtime), so callers fall back to an estimate.
-- Cached per (pt,text) because node geometry is rebuilt every frame.
local widthCache = {}

function Theme.TextWidth(pt, text)
    if text == nil or text == "" then return 0 end
    pt = math.max(8, math.min(40, math.floor(pt + 0.5)))
    local key = pt .. "\0" .. text
    local cached = widthCache[key]
    if cached ~= nil then return cached or nil end
    local f = Theme.FontObject(pt)
    if f == nil then widthCache[key] = false; return nil end
    local ok, w = pcall(function() return f:GetStringWidth(text, true) end)
    if ok and type(w) == "number" then widthCache[key] = w; return w end
    widthCache[key] = false
    return nil
end

return Theme
