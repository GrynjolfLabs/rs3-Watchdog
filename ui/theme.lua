local Theme = {}

local function col(r, g, b, a)
    return { r / 255, g / 255, b / 255, a or 1 }
end

--- Sizing (Graph-space units at zoom 1.0) -------------------------------------------

Theme.NODE_WIDTH       = 250
Theme.HEADER_HEIGHT    = 26
Theme.PIN_ROW_HEIGHT   = 24
Theme.BODY_PAD_TOP     = 8
Theme.BODY_PAD_BOTTOM  = 10
Theme.PIN_MARGIN_X     = 10
Theme.PIN_GLYPH        = 12
Theme.PIN_LABEL_GAP    = 8
Theme.PIN_HIT_PAD      = 4
Theme.CLOSE_SIZE       = 14
Theme.CLOSE_MARGIN     = 14

Theme.CONTROL_H            = 16
Theme.MODE_STRIP_PAD       = 4
Theme.MODE_STRIP_H         = Theme.MODE_STRIP_PAD + Theme.CONTROL_H + Theme.MODE_STRIP_PAD
Theme.CONTROL_LABEL_CHAR_W = 7     -- approx per-char width when Theme.TextWidth is unavailable
Theme.CONTROL_LABEL_GAP    = 8
Theme.CONTROL_OUT_RESERVE  = 52    -- space for an output pin+label sharing the row
Theme.CONTROL_PAD_X        = 5
Theme.CONTROL_MIN_W        = 12
Theme.CONTROL_MIN_ZOOM     = 0.45  -- below this the box/text is unreadable, so it isn't drawn
-- The transient editor is a real component with a native, fixed-pixel font that does NOT
-- scale with the View, so it's sized in screen pixels independent of zoom (height fixed;
-- width tracks the box but never below the min). Sizing it to view:Scale(box) made the text
-- unreadable at zoom 1 - the box was 16px tall but the native font needs more.
Theme.CONTROL_EDIT_MIN_W   = 60
Theme.CONTROL_EDIT_H       = 24

Theme.COORDGRID_TOP_GAP    = 4
Theme.COORDGRID_FIELD_H    = 16
Theme.COORDGRID_MID_GAP    = 4
Theme.COORDGRID_BUTTON_H   = 16
Theme.COORDGRID_BOTTOM_GAP = 4
Theme.COORDGRID_FIELD_GAP  = 4
Theme.COORDGRID_BAND_H     = Theme.COORDGRID_TOP_GAP + Theme.COORDGRID_FIELD_H
    + Theme.COORDGRID_MID_GAP + Theme.COORDGRID_BUTTON_H + Theme.COORDGRID_BOTTOM_GAP

Theme.MATCHER_TOP_GAP    = 4
Theme.MATCHER_FIELD_H    = 16
Theme.MATCHER_GAP        = 4
Theme.MATCHER_TOGGLE_W   = 64    -- fits "Substring"
Theme.MATCHER_BOTTOM_GAP = 4
Theme.MATCHER_BAND_H     = Theme.MATCHER_TOP_GAP + Theme.MATCHER_FIELD_H + Theme.MATCHER_BOTTOM_GAP

Theme.MODE_TOP_GAP    = 4
Theme.MODE_ROW_H      = 16
Theme.MODE_ROW_GAP    = 3
Theme.MODE_BOTTOM_GAP = 4

function Theme.ModeBandH(count)
    if count <= 0 then return Theme.MODE_TOP_GAP + Theme.MODE_BOTTOM_GAP end
    return Theme.MODE_TOP_GAP + count * Theme.MODE_ROW_H
        + (count - 1) * Theme.MODE_ROW_GAP + Theme.MODE_BOTTOM_GAP
end

Theme.SWATCH_W             = 46
Theme.SWATCH_CHECKER_CELL  = 4

Theme.COLOR_POPUP_W        = 220
Theme.COLOR_POPUP_PAD      = 10
Theme.COLOR_POPUP_HEADER_H = 22
Theme.COLOR_POPUP_SV_H     = 110
Theme.COLOR_POPUP_HUE_H    = 14
Theme.COLOR_POPUP_ROW_H    = 18
Theme.COLOR_POPUP_ROW_GAP  = 6
Theme.COLOR_POPUP_CHECKER_CELL = 6

Theme.TOAST_W            = 240
Theme.TOAST_H            = 48
Theme.TOAST_GAP          = 6
Theme.TOAST_ACCENT_W     = 3
Theme.TOAST_ICON_SIZE    = 28
Theme.TOAST_PAD_X        = 8
Theme.TOAST_TOP_MARGIN   = 24

Theme.COL_TOAST_BG     = col(24, 24, 28, 0.92)
Theme.COL_TOAST_BORDER = col(10, 10, 12, 1.0)
Theme.COL_TOAST_TEXT   = col(230, 230, 236, 1.0)

Theme.INFOBOX_BOX_SIZE   = 36
Theme.INFOBOX_GAP        = 2
Theme.INFOBOX_DEFAULT_X  = 8
Theme.INFOBOX_DEFAULT_Y  = 8
Theme.INFOBOX_WRAP_WIDTH = 220
Theme.INFOBOX_TEXT_PT    = 14
Theme.INFOBOX_TOOLTIP_PT = 12
Theme.INFOBOX_TOOLTIP_PAD = 4

Theme.COL_INFOBOX_BG      = col(30, 30, 34, 0.85)
Theme.COL_INFOBOX_BORDER  = col(12, 12, 15, 1.0)
Theme.COL_INFOBOX_TEXT    = col(255, 255, 255, 1.0)  -- default (unset/nil color) - white
Theme.COL_INFOBOX_TIP_BG  = col(18, 18, 22, 0.96)    -- hover tooltip backing
Theme.COL_INFOBOX_TIP_TX  = col(230, 232, 240, 1.0)

Theme.BORDER_THICKNESS = 2
Theme.WIRE_THICKNESS   = 3
Theme.WIRE_SEGMENTS    = 16
Theme.GRID_SPACING     = 32

-- Text can't shrink past the smallest font (font IDs are discrete - ADR-0001), so labels
-- are dropped when zoomed out rather than left to overflow. Degrades in two stages: pin
-- labels go first, node titles persist further out so nodes stay identifiable.
Theme.LABEL_MIN_ZOOM   = 0.45   -- pin labels
Theme.TITLE_MIN_ZOOM   = 0.30   -- node titles

Theme.ZOOM_MIN = 0.25
Theme.ZOOM_MAX = 2.0
Theme.ZOOM_STEP = 1.1  -- interior rungs: 1.0 * ZOOM_STEP^k in (ZOOM_MIN, ZOOM_MAX)
Theme.ZOOM_SLIDER_W = 128  -- toolbar track width; buttons stay 18px and center on ZOOM_SLIDER_H
Theme.ZOOM_SLIDER_H = 24   -- taller than the 18px buttons so the native thumb is not clipped
Theme.COL_ZOOM_TICK = col(230, 232, 240, 1.0)  -- single 1.0 mark on the track (not native notches)

--- Window (defaults / host chrome) ------------------------------------------------------

-- Default content size seed before Mount syncs from the live content parent. Screen
-- placement (x/y) is owned by PrettyUI; WINDOW_X/Y are only fallbacks for self.window
-- until syncContentOrigin runs.
-- Title-strip metrics match prettyui/src/window.lua (TITLE_HEIGHT, BORDER, titleDrag
-- width = root.width - CLOSE_SIZE - 14). Overlay toolbar is laid out on that strip;
-- the Editor Canvas still does not inset by WINDOW_HEADER_H.
Theme.WINDOW_X             = 600
Theme.WINDOW_Y             = 340
Theme.WINDOW_W             = 900
Theme.WINDOW_H             = 560
Theme.WINDOW_HEADER_H      = 32   -- PrettyUI TITLE_HEIGHT
Theme.WINDOW_BORDER        = 8    -- PrettyUI BORDER; content is inset this much
Theme.WINDOW_TITLE         = "Watchdog - Editor"

--- Palette (screen-space popup) + toolbar -----------------------------------------------

Theme.PALETTE_W     = 220
Theme.PALETTE_ROW_H = 20
Theme.PALETTE_PAD   = 6
Theme.PALETTE_MAX_H = 400   -- cap the popup height so a big Registry doesn't fill the screen
                            -- (scrolls past this); also bounded to 92% of the draw rect

-- Scrollbar in the reserved right gutter (only drawn when the list overflows). Press-anywhere
-- jumps the thumb under the cursor and scrubs (see Palette:ScrollToY); the wheel still scrolls.
Theme.PALETTE_SCROLLBAR_W         = 8
Theme.PALETTE_SCROLLBAR_MIN_THUMB = 24

-- Two clicks pairing into a double-click that opens the Palette on empty space.
Theme.DOUBLECLICK_TICKS = 24  -- Logic ticks (~0.02s each) allowed between the two clicks
Theme.DOUBLECLICK_DIST  = 6   -- max screen-px drift between the two clicks

--- Alert Manager (screen-space layout) -----------------------------------------------

-- PrettyUI Tabs uses MANAGER_TAB_BASELINE ≈ 42 for the tab header strip (see prettyui/src/tabs.lua).
Theme.MANAGER_TAB_BASELINE   = 42
Theme.MANAGER_ROW_H          = 32
Theme.MANAGER_HEADER_H       = 26
-- Wider than the checkbox glyph so the "Enabled" header is not ellipsized.
-- The PrettyUI checkbox stays 14px inside a 28px click target.
Theme.MANAGER_ENABLE_W       = 72
Theme.MANAGER_SELECT_W       = 48
Theme.MANAGER_ACT_W          = 28
Theme.MANAGER_ACT_COUNT      = 3    -- pencil + export + trash per row (#94)
Theme.MANAGER_REORDER_W      = 28
Theme.MANAGER_REORDER_COUNT  = 3
Theme.MANAGER_ROW_GAP        = 4
Theme.MANAGER_ROW_INDENT     = 20
Theme.MANAGER_PAGE_PAD       = 12
Theme.MANAGER_TOOLBAR_GAP    = 8
Theme.MANAGER_BULK_BAR_H     = 30
Theme.MANAGER_TREE_TOP       = 92
Theme.MANAGER_IMPORT_EXPORT_W = 440
Theme.MANAGER_IMPORT_EXPORT_H = 420

--- Colors --------------------------------------------------------------------------

Theme.COL_VIEWPORT_BG = col(26, 26, 30, 1.0)
Theme.COL_GRID        = col(40, 40, 47, 1.0)
Theme.COL_GRID_MAJOR  = col(52, 52, 60, 1.0)

Theme.COL_WINDOW_BORDER = col(12, 12, 15, 1.0)

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

-- Unknown-node placeholder (#53): a desaturated, muted box so it reads as inert/degraded -
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

Theme.COL_CONTROL_BG     = col(28, 28, 33, 1.0)
Theme.COL_CONTROL_BORDER = col(70, 70, 82, 1.0)
Theme.COL_CONTROL_HOT    = col(240, 160, 32, 1.0)   -- border under the cursor
Theme.COL_CONTROL_TEXT   = col(225, 227, 233, 1.0)
Theme.COL_CONTROL_EMPTY  = col(120, 122, 132, 1.0)  -- placeholder when the value is empty
Theme.COL_CONTROL_CARET  = col(170, 172, 182, 1.0)  -- enum dropdown ▾ indicator
Theme.COL_CONTROL_ACTION_BG = col(52, 56, 66, 1.0)  -- composite-control action button (e.g. coordgrid's "set to current position")
Theme.COL_CHECK_BOX_BG   = col(20, 20, 24, 1.0)     -- mode checkbox (#40) inner fill
Theme.COL_CHECK_MARK     = col(245, 205, 70, 1.0)   -- mode checkbox tick - gold, drawn when checked

-- Checkerboard behind a color swatch/preview, so alpha reads visually (#30).
Theme.COL_CHECKER_LIGHT = col(150, 150, 150, 1.0)
Theme.COL_CHECKER_DARK  = col(90, 90, 90, 1.0)

-- Screen Marker's "Draw on screen" full-screen capture overlay (#39/#71): dim wash while
-- Capture-Armed (snipping-tool hole while dragging), and the in-progress selection outline.
Theme.COL_SCREEN_MARKER_DIM  = col(0, 0, 0, 0.35)
Theme.COL_SCREEN_MARKER_DRAG = col(255, 255, 255, 1.0)

-- Shared Capture Banner (#71): top instruction strip while a marker Capture Arm is live.
Theme.COL_CAPTURE_BANNER_BG = col(20, 20, 28, 0.92)
Theme.COL_CAPTURE_BANNER_FG = col(240, 240, 245, 1.0)

-- Execution pins and wires use one fixed neutral color (they carry no Type Tag).
Theme.COL_EXEC        = col(242, 242, 242, 1.0)

-- Per-exec-in-pin "test" button: a small square between an exec-in pin's glyph and its label
-- that fires that pin (calls the node's run as if the wire had fired) for testing. Drawn/hit
-- on the same CONTROL_MIN_ZOOM gate as inline Control boxes.
Theme.TEST_BTN_W        = 18
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

-- Pixel width of `text` drawn at ~`pt`, tags ignored, via the real font metrics - or nil if
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
