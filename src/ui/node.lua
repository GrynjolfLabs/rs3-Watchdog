local Theme    = require("src/ui/theme")
local Controls = require("src/ui/controls")
local Box      = require("src/ui/widgets/box")
local Dropdown = require("src/ui/widgets/dropdown")
local Text     = require("src/text")

local Node = {}

--- Name shown in the header and the rename field. Nil means the node was never renamed,
--- so the label is display-only (`New {Type}`) and is not written onto the node.
---@param typeLabel string
---@param storedName string|nil
---@return string
function Node.DisplayName(typeLabel, storedName)
    if storedName == nil then
        return "New " .. typeLabel
    end
    return storedName
end

--- `{Type} - {Name}`. #140 builds Variable labels from this same string.
---@param typeLabel string
---@param storedName string|nil
---@return string
function Node.HeaderTitle(typeLabel, storedName)
    return typeLabel .. " - " .. Node.DisplayName(typeLabel, storedName)
end

--- Trim a rename field and drop text tags. Blank or whitespace is not valid, so Rename stays disabled.
---@param raw string|nil
---@return string|nil
function Node.TrimName(raw)
    if type(raw) ~= "string" then return nil end
    local trimmed = Text.StripTags(raw):match("^%s*(.-)%s*$")
    if trimmed == nil or trimmed == "" then return nil end
    return trimmed
end

--- Store a trimmed name. A placeholder's on-disk name lives on `unknown.name`; writing
--- only `node.name` is dropped the next time Serialize re-emits the original node.
--- Does not look at other nodes, so two nodes may share a name.
---@param node table
---@param raw string|nil
---@return boolean
function Node.CommitRename(node, raw)
    local trimmed = Node.TrimName(raw)
    if trimmed == nil then return false end
    if node.unknown ~= nil then
        node.unknown.name = trimmed
    else
        node.name = trimmed
    end
    return true
end

---@param pin table
---@param connected table<string, boolean>
---@param typeKey string|nil
---@return table|nil
local function pinControlFor(pin, connected, typeKey)
    if pin.kind ~= "data" or connected[pin.name] then return nil end
    return Controls.PinControlForPin(typeKey, pin)
end

---@param nodeType table|nil
---@return { key: string, label: string }[]
function Node.SortedModes(nodeType)
    if nodeType == nil or nodeType.modes == nil then return {} end
    local list = {}
    for key, def in pairs(nodeType.modes) do
        list[#list + 1] = { key = key, label = def.label or key }
    end
    table.sort(list, function(a, b)
        if a.label == b.label then return a.key < b.key end
        return a.label < b.label
    end)
    return list
end

-- ComboField matches by label text and re-sorts alphabetically, so duplicate mode labels
-- would collide. Disambiguate with the key when the same label appears twice.
---@param nodeType table|nil
---@return { key: string, label: string, display: string }[]
function Node.ModeDropdownChoices(nodeType)
    local modes = Node.SortedModes(nodeType)
    local counts = {}
    for _, m in ipairs(modes) do
        counts[m.label] = (counts[m.label] or 0) + 1
    end
    local choices = {}
    for _, m in ipairs(modes) do
        local display = m.label
        if counts[m.label] > 1 then
            display = m.label .. " (" .. m.key .. ")"
        end
        choices[#choices + 1] = { key = m.key, label = m.label, display = display }
    end
    return choices
end

function Node.BuildGeometry(pins, x, y, width, opts)
    width = width or Theme.NODE_WIDTH
    local extraBodyH = (opts and opts.extraBodyH) or 0
    local extraBodyW = (opts and opts.extraBodyW) or 0
    if extraBodyW > width then
        width = extraBodyW
    end
    -- Zoom-1 title size, same face Node.Draw uses. Width already includes extraBodyW.
    local title = opts and opts.title
    if title ~= nil and title ~= "" then
        local textW = Theme.TextWidth(Theme.NODE_TITLE_PT, title)
            or (#title * Theme.NODE_TITLE_CHAR_W)
        local pencilLeftInset = Theme.CLOSE_MARGIN
            + Theme.RENAME_ICON_SIZE + Theme.RENAME_ICON_SIZE * 0.5
        local needed = math.ceil(Theme.PIN_MARGIN_X + textW + Theme.HEADER_TITLE_GAP + pencilLeftInset)
        if needed > width then
            width = needed
        end
    end
    local connected = (opts and opts.connected) or {}
    local typeKey = opts and opts.typeKey or nil
    -- A placeholder node (#53) renders its reconstructed stubs as pins, but offers none of the
    -- interactive geometry: no Control boxes (raw controls are opaque without their codecs) and
    -- no per-exec-in test buttons (FireInput would assert on a pin the engine can't resolve).
    local placeholder = (opts and opts.placeholder) or false

    local inputs, outputs = {}, {}
    for _, pin in ipairs(pins) do
        if pin.direction == "in" then
            inputs[#inputs + 1] = pin
        else
            outputs[#outputs + 1] = pin
        end
    end

    -- Config is not a pin. It occupies body rows under the input pins so a checkbox
    -- can be toggled without offering a wire socket.
    local config = {}
    if not placeholder and opts ~= nil and type(opts.config) == "table" then
        config = opts.config
    end

    local rows = math.max(#inputs, #outputs, #inputs + #config)

    -- Mode strip (ADR-0011) sits under the header when this instance's type has modes.
    -- Not a pin: `opts.modeLabel` is the current mode's display label, or nil.
    local modeLabel = (not placeholder) and opts and opts.modeLabel or nil
    local modeStripH = (modeLabel ~= nil) and Theme.MODE_STRIP_H or 0

    -- Row tops, cumulative (#25): row i normally advances by a fixed PIN_ROW_HEIGHT, but a
    -- composite Control on that row's input pin (e.g. coordgrid) reserves extra band height
    -- below it via spec.extraH(pin), pushing every later row down. Scalar/no-control rows
    -- have extraH 0, so this collapses to the old fixed-stride math. Both pin columns (inputs
    -- AND outputs) share this same rowTop table so a row's input and output glyph stay
    -- vertically aligned even when only the input side grew.
    local rowTop = {}
    do
        local cy = Theme.HEADER_HEIGHT + modeStripH + Theme.BODY_PAD_TOP
        for i = 1, rows do
            rowTop[i] = cy
            local extraH = 0
            local pin = inputs[i]
            if pin ~= nil and not placeholder then
                local pc = pinControlFor(pin, connected, typeKey)
                if pc ~= nil then
                    extraH = pc.ReservedHeight(pin) or 0
                end
            end
            cy = cy + Theme.PIN_ROW_HEIGHT + extraH
        end
        rowTop[rows + 1] = cy
    end
    local height = rowTop[rows + 1] + extraBodyH + Theme.BODY_PAD_BOTTOM

    local geom = { x = x, y = y, w = width, h = height,
        pins = {}, byName = {}, controls = {}, configLabels = {}, testButtons = {}, placeholder = placeholder }
    if extraBodyH > 0 then
        geom.viewerGrid = {
            x = Theme.PIN_MARGIN_X,
            y = rowTop[rows + 1],
            w = width - Theme.PIN_MARGIN_X * 2,
            h = extraBodyH,
        }
    end

    -- Delete button center, in the header, Graph-space relative to the node origin. Shared
    -- by Draw and HitClose so the glyph and its hit-target can't disagree.
    geom.close = { cx = width - Theme.CLOSE_MARGIN, cy = Theme.HEADER_HEIGHT * 0.5 }
    -- Pencil sits left of the X. Same title-zoom gate as close, including on a placeholder.
    geom.pencil = { cx = geom.close.cx - Theme.RENAME_ICON_SIZE, cy = geom.close.cy }
    if modeLabel ~= nil then
        geom.modeStrip = {
            x = Theme.PIN_MARGIN_X,
            y = Theme.HEADER_HEIGHT + Theme.MODE_STRIP_PAD,
            w = width - Theme.PIN_MARGIN_X * 2,
            h = Theme.CONTROL_H,
            label = modeLabel,
        }
    end

    local function place(list, cx)
        for i, pin in ipairs(list) do
            local cy = rowTop[i] + Theme.PIN_ROW_HEIGHT * 0.5
            local entry = {
                name = pin.name,
                kind = pin.kind,
                direction = pin.direction,
                dataType = pin.dataType,
                label = pin.label or pin.name,
                cx = cx,   -- glyph center, Graph-space, relative to node origin
                cy = cy,
            }
            geom.pins[#geom.pins + 1] = entry
            geom.byName[pin.name] = entry
        end
    end

    place(inputs, Theme.PIN_MARGIN_X)
    place(outputs, width - Theme.PIN_MARGIN_X)

    for _, pin in ipairs(placeholder and {} or inputs) do
        if pin.kind == "exec" then
            local entry = geom.byName[pin.name]
            if entry ~= nil then
                local bw = Theme.TEST_BTN_W
                local bx = Theme.PIN_MARGIN_X + Theme.PIN_GLYPH * 0.5 + Theme.PIN_LABEL_GAP
                geom.testButtons[#geom.testButtons + 1] = {
                    pinName = pin.name,
                    x = bx, y = entry.cy - Theme.CONTROL_H * 0.5,
                    w = bw, h = Theme.CONTROL_H,
                }
                entry.labelInset = bw + Theme.PIN_LABEL_GAP
            end
        end
    end

    -- Control boxes: one group per unconnected data-input Pin whose Type Tag has a Pin Control
    -- (ADR-0005). The Node reserves the band height the module reports and asks it to lay out its
    -- Widgets' sub-rects, tagging each geom.controls entry with the module so the Editor routes
    -- display/click back to it. Two layout shapes, chosen by the Pin Control: an INLINE control
    -- (scalar, enum, swatch, capture) fills the single value-column box to the right of the label;
    -- a BAND control (coordgrid, matcher, mode) lays its Widgets out in the full-width band reserved
    -- beneath the row (rowTop[i+1] - extraH .. rowTop[i+1]).
    local labelStart = Theme.PIN_MARGIN_X + Theme.PIN_GLYPH * 0.5 + Theme.PIN_LABEL_GAP
    -- Zoom-1 metrics. Draw scales the box. TextWidth is nil outside the client.
    local function labelWidth(text)
        text = text or ""
        return Theme.TextWidth(12, text) or (#text * Theme.CONTROL_LABEL_CHAR_W)
    end

    -- `left` is already past the row's own label. A pin label starts after the glyph.
    -- A config check has no glyph, so that caller passes the margin instead.
    -- The box then stops short of an output label on the same row.
    ---@param pinControl { Layout: fun(band: table): table|nil, Inline: boolean }
    ---@param name string
    ---@param defaultValue any
    ---@param left number
    ---@param cy number
    ---@param outPin { label: string|nil, name: string|nil }|nil
    local function layoutInline(pinControl, name, defaultValue, left, cy, outPin)
        local rightInset = Theme.CONTROL_PAD_X
        if outPin ~= nil then
            local outLabel = outPin.label or outPin.name or ""
            rightInset = Theme.PIN_GLYPH * 0.5 + Theme.PIN_LABEL_GAP
                + labelWidth(outLabel) + Theme.CONTROL_LABEL_GAP
        end
        local right = width - Theme.PIN_MARGIN_X - rightInset
        if outPin == nil and right < left + Theme.CONTROL_MIN_W then
            right = left + Theme.CONTROL_MIN_W
        end
        if right < left then right = left end
        local rects = pinControl.Layout({
            x = left, y = cy - Theme.CONTROL_H * 0.5, w = right - left, h = Theme.CONTROL_H,
        }) or {}
        for _, r in ipairs(rects) do
            geom.controls[#geom.controls + 1] = {
                pinName = name,
                pinControl = pinControl,
                default = defaultValue,
                -- `kind`/`axis` name the sub-rect for the Editor's press + isEditingThis skip.
                -- How it paints is the Pin Control's Draw, not a discriminator the Node reads.
                kind = r.kind, axis = r.axis,
                enabled = r.enabled,          -- a mode checkbox row's toggle-ability
                placeholder = r.placeholder,  -- e.g. the matcher needle's / capture's empty-state hint
                x = r.x, y = r.y, w = r.w, h = r.h,
            }
        end
    end

    for i, pin in ipairs(placeholder and {} or inputs) do
        local pinControl = pinControlFor(pin, connected, typeKey)
        if pinControl ~= nil then
            if pinControl.Inline then
                local label = pin.label or pin.name or ""
                local left = labelStart + labelWidth(label) + Theme.CONTROL_LABEL_GAP
                local cy = rowTop[i] + Theme.PIN_ROW_HEIGHT * 0.5
                layoutInline(pinControl, pin.name, pin.default, left, cy, outputs[i])
            else
                local extraH = pinControl.ReservedHeight(pin) or 0
                local band = {
                    x = Theme.PIN_MARGIN_X, y = rowTop[i + 1] - extraH,
                    w = width - Theme.PIN_MARGIN_X * 2, h = extraH,
                }
                local rects = pinControl.Layout(band) or {}
                for _, r in ipairs(rects) do
                    geom.controls[#geom.controls + 1] = {
                        pinName    = pin.name,
                        pinControl = pinControl,
                        default    = pin.default,
                        -- `kind`/`axis` name the sub-rect for the Editor's press + isEditingThis skip;
                        -- how it PAINTS is the Pin Control's Draw, not a discriminator the Node reads.
                        kind = r.kind, axis = r.axis,
                        enabled = r.enabled,          -- a mode checkbox row's toggle-ability
                        placeholder = r.placeholder,  -- e.g. the matcher needle's / capture's empty-state hint
                        x = r.x, y = r.y, w = r.w, h = r.h,
                    }
                end
            end
        end
    end

    -- Config rows sit after input pins. No glyph: the label is the check's name,
    -- and the checkbox is an ordinary control the editor commits by that name.
    for i, cfg in ipairs(config) do
        local row = #inputs + i
        local label = cfg.label or cfg.name or ""
        local cy = rowTop[row] + Theme.PIN_ROW_HEIGHT * 0.5
        geom.configLabels[#geom.configLabels + 1] = {
            label = label,
            x = Theme.PIN_MARGIN_X,
            cy = cy,
        }
        local pinControl = Controls.PinControlForPin(typeKey, {
            name = cfg.name,
            dataType = cfg.dataType or "bool",
        })
        if pinControl ~= nil and pinControl.Inline then
            local left = Theme.PIN_MARGIN_X + labelWidth(label) + Theme.CONTROL_LABEL_GAP
            layoutInline(pinControl, cfg.name, cfg.default, left, cy, outputs[row])
        end
    end

    return geom
end

function Node.PinCenter(geom, pinName)
    local p = geom.byName[pinName]
    if p == nil then return nil end
    return geom.x + p.cx, geom.y + p.cy
end

local createTextDataConfig = Box.TextData

function Node.Draw(canvas, view, geom, meta, opts)
    opts = opts or {}
    local sx, sy = view:ToScreen(geom.x, geom.y)
    local sw, sh = view:Scale(geom.w), view:Scale(geom.h)
    local headerH = view:Scale(Theme.HEADER_HEIGHT)

    -- Body, header band, border. A placeholder (#53) uses its own muted grey palette instead of
    -- a category color, so it reads as an inert stand-in rather than a real node of some type.
    local bodyCol = geom.placeholder and Theme.COL_NODE_UNKNOWN_BODY or Theme.COL_NODE_BODY
    local headerCol = geom.placeholder and Theme.COL_NODE_UNKNOWN_HEADER
        or Theme.CategoryColor(meta.category)
    canvas:AddRectangle(sx, sy, sw, sh, Theme.Vec4(bodyCol))
    canvas:AddRectangle(sx, sy, sw, headerH, Theme.Vec4(headerCol))
    local borderCol = opts.selected and Theme.COL_NODE_SEL or Theme.COL_NODE_BORDER
    canvas:AddOutline(sx, sy, sw, sh, Theme.BORDER_THICKNESS, Theme.Vec4(borderCol))

    local showTitle  = view.zoom >= Theme.TITLE_MIN_ZOOM
    local showLabels = view.zoom >= Theme.LABEL_MIN_ZOOM

    if showTitle and meta.title then
        local font = Theme.Font(Theme.NODE_TITLE_PT * view.zoom)
        if font ~= nil then
            local tw = Theme.TextWidth(Theme.NODE_TITLE_PT * view.zoom, meta.title)
                or (#meta.title * view:Scale(Theme.NODE_TITLE_CHAR_W))
            local textData = createTextDataConfig(font, Theme.Vec4(Theme.COL_TITLE))
            canvas:AddText(sx + view:Scale(Theme.PIN_MARGIN_X),
                sy + headerH * 0.5 - view:Scale(8),
                tw, 0, meta.title, textData)
        end
    end

    -- Header pencil, left of the delete X. Same zoom gate as HitClose.
    if showTitle and geom.pencil ~= nil then
        local pcx, pcy = view:ToScreen(geom.x + geom.pencil.cx, geom.y + geom.pencil.cy)
        local sz = view:Scale(Theme.RENAME_ICON_SIZE)
        local half = sz * 0.5
        local hot = opts.mouseX ~= nil and Node.HitPencil(geom, view, opts.mouseX, opts.mouseY)
        if id and id.Sprite then
            local spriteId = hot and id.Sprite.RS3_ICON_EDIT_23PX_1 or id.Sprite.RS3_ICON_EDIT_23PX_0
            if spriteId ~= nil then
                canvas:AddSprite(pcx - half, pcy - half, sz, sz, spriteId, 0xFFFFFFFF)
            end
        end
    end

    -- Header delete button (an X). Only shown when the header is legible (title zoom),
    -- matching HitClose so an invisible button is never clickable.
    if showTitle and geom.close ~= nil then
        local ccx, ccy = view:ToScreen(geom.x + geom.close.cx, geom.y + geom.close.cy)
        local half = view:Scale(Theme.CLOSE_SIZE) * 0.5
        local arm  = half * 0.6
        local hot  = opts.mouseX ~= nil and Node.HitClose(geom, view, opts.mouseX, opts.mouseY)
        if hot then
            canvas:AddRectangle(ccx - half, ccy - half, half * 2, half * 2,
                Theme.Vec4(Theme.COL_CLOSE_BG))
        end
        local col = Theme.Vec4(hot and Theme.COL_CLOSE_HOT or Theme.COL_CLOSE)
        local t = math.max(1, view:Scale(2))
        canvas:AddLine(ccx - arm, ccy - arm, ccx + arm, ccy + arm, t, col)
        canvas:AddLine(ccx - arm, ccy + arm, ccx + arm, ccy - arm, t, col)
    end

    -- Mode strip (ADR-0011): ComboField-lookalike under the header. Skipped while the
    -- transient dropdown is mounted over it (`editingKind == "nodeMode"`).
    if view.zoom >= Theme.CONTROL_MIN_ZOOM and geom.modeStrip ~= nil
        and opts.editingKind ~= "nodeMode" then
        local ms = geom.modeStrip
        local bx, by = view:ToScreen(geom.x + ms.x, geom.y + ms.y)
        local bw, bh = view:Scale(ms.w), view:Scale(ms.h)
        local hot = opts.mouseX ~= nil
            and opts.mouseX >= bx and opts.mouseX <= bx + bw
            and opts.mouseY >= by and opts.mouseY <= by + bh
        local font = Theme.Font(11 * view.zoom)
        local scale = function(n) return view:Scale(n) end
        Dropdown:Draw(canvas, { x = bx, y = by, w = bw, h = bh },
            { display = ms.label },
            { hot = hot, font = font, zoom = view.zoom, scale = scale })
    end

    local hs = view:Scale(Theme.PIN_GLYPH) * 0.5
    local labelFont = showLabels and Theme.Font(12 * view.zoom) or nil
    -- Same baseline for a pin label and a config check. Callers pass x, because a pin
    -- sits past its glyph and a check starts at the margin.
    ---@param text string
    ---@return number
    local function labelPixelWidth(text)
        return Theme.TextWidth(12 * view.zoom, text) or (#text * view:Scale(7))
    end
    ---@param x number
    ---@param centerY number
    ---@param text string
    ---@param tw number
    local function drawLabel(x, centerY, text, tw)
        canvas:AddText(x, centerY - view:Scale(7), tw, 0, text,
            createTextDataConfig(labelFont, Theme.Vec4(Theme.COL_PIN_LABEL)))
    end
    for _, pin in ipairs(geom.pins) do
        local pcx, pcy = view:ToScreen(geom.x + pin.cx, geom.y + pin.cy)

        local color
        if pin.kind == "exec" then
            color = Theme.Vec4(Theme.COL_EXEC)
            canvas:AddTriangle(pcx - hs, pcy - hs, pcx - hs, pcy + hs, pcx + hs, pcy, color)
        else
            color = Theme.Vec4(Theme.TypeColor(pin.dataType))
            canvas:AddRectangle(pcx - hs, pcy - hs, hs * 2, hs * 2, color)
        end

        if labelFont ~= nil then
            local tw = labelPixelWidth(pin.label)
            if pin.direction == "in" then
                -- An exec-in pin's label is pushed right to clear its test button (labelInset,
                -- set in BuildGeometry); every other pin has no inset.
                local inset = Theme.PIN_LABEL_GAP + (pin.labelInset or 0)
                drawLabel(pcx + hs + view:Scale(inset), pcy, pin.label, tw)
            else
                -- Right-align output labels against the glyph (measured at the drawn size).
                drawLabel(pcx - hs - view:Scale(Theme.PIN_LABEL_GAP) - tw, pcy, pin.label, tw)
            end
        end
    end

    for _, row in ipairs(geom.configLabels or {}) do
        if labelFont ~= nil then
            local tx, ty = view:ToScreen(geom.x + row.x, geom.y + row.cy)
            drawLabel(tx, ty, row.label, labelPixelWidth(row.label))
        end
    end

    -- Control value boxes. Skipped when zoomed too far out to read, and the box currently
    -- being edited is skipped entirely - the transient InputField/ComboField covers it. A
    -- composite Control (#25) contributes several boxes sharing one pinName, so the "is this
    -- the one being edited" check also matches kind/axis - otherwise opening the editor on
    -- one coordgrid field would blank out its whole band.
    --
    -- Each box's paint is the Widget's own (ADR-0005 #63 render seam): the Node projects the
    -- graph-space rect to screen, computes `hot`, and hands both to the Pin Control's Draw with a
    -- small draw-context (dctx) - there is NO `kind`/`widget` branch here. The Node keeps only what
    -- is genuinely its own: the row/View transform and the isEditingThis skip (the transient editor
    -- overlay is an Editor concern, not the control's). The Widget never sees `view`/ToScreen/Scale.
    if view.zoom >= Theme.CONTROL_MIN_ZOOM then
        local ctrlFont = Theme.Font(11 * view.zoom)
        local scale = function(n) return view:Scale(n) end
        for _, ctrl in ipairs(geom.controls) do
            local isEditingThis = ctrl.pinName == opts.editingPin
                and ctrl.kind == opts.editingKind and ctrl.axis == opts.editingAxis
            if not isEditingThis then
                local bx, by = view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
                local bw, bh = view:Scale(ctrl.w), view:Scale(ctrl.h)
                local hot = opts.mouseX ~= nil
                    and opts.mouseX >= bx and opts.mouseX <= bx + bw
                    and opts.mouseY >= by and opts.mouseY <= by + bh
                ctrl.pinControl.Draw(canvas, { x = bx, y = by, w = bw, h = bh }, ctrl,
                    { hot = hot, font = ctrlFont, zoom = view.zoom, scale = scale })
            end
        end

        -- Test buttons (one per exec-in pin): a green square with a ▶ play triangle, gated on
        -- the same CONTROL_MIN_ZOOM as Control boxes so an undrawn button is never hittable.
        for _, tb in ipairs(geom.testButtons) do
            local bx, by = view:ToScreen(geom.x + tb.x, geom.y + tb.y)
            local bw, bh = view:Scale(tb.w), view:Scale(tb.h)
            local hot = opts.mouseX ~= nil
                and opts.mouseX >= bx and opts.mouseX <= bx + bw
                and opts.mouseY >= by and opts.mouseY <= by + bh
            canvas:AddRectangle(bx, by, bw, bh, Theme.Vec4(Theme.COL_TEST_BTN_BG))
            canvas:AddOutline(bx, by, bw, bh, math.max(1, view:Scale(1)),
                Theme.Vec4(hot and Theme.COL_TEST_BTN_HOT or Theme.COL_NODE_BORDER))
            local cx, cy = bx + bw * 0.5, by + bh * 0.5
            local a = view:Scale(4)
            local glyph = Theme.Vec4(hot and Theme.COL_TEST_BTN_HOT or Theme.COL_TEST_BTN_GLYPH)
            canvas:AddTriangle(cx - a * 0.7, cy - a, cx - a * 0.7, cy + a, cx + a, cy, glyph)
        end
    end
end

function Node.TestButtonAt(geom, view, sx, sy)
    if view.zoom < Theme.CONTROL_MIN_ZOOM then return nil end
    for _, tb in ipairs(geom.testButtons) do
        local bx, by = view:ToScreen(geom.x + tb.x, geom.y + tb.y)
        local bw, bh = view:Scale(tb.w), view:Scale(tb.h)
        if sx >= bx and sx <= bx + bw and sy >= by and sy <= by + bh then
            return tb
        end
    end
    return nil
end

function Node.PinAt(geom, view, sx, sy)
    local half = view:Scale(Theme.PIN_GLYPH) * 0.5 + Theme.PIN_HIT_PAD
    for _, pin in ipairs(geom.pins) do
        local pcx, pcy = view:ToScreen(geom.x + pin.cx, geom.y + pin.cy)
        if sx >= pcx - half and sx <= pcx + half
            and sy >= pcy - half and sy <= pcy + half then
            return pin
        end
    end
    return nil
end

function Node.ControlAt(geom, view, sx, sy)
    if view.zoom < Theme.CONTROL_MIN_ZOOM then return nil end
    for _, ctrl in ipairs(geom.controls) do
        local bx, by = view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
        local bw, bh = view:Scale(ctrl.w), view:Scale(ctrl.h)
        if sx >= bx and sx <= bx + bw and sy >= by and sy <= by + bh then
            return ctrl
        end
    end
    return nil
end

local function headerBoxHit(cx, cy, half, sx, sy)
    return sx >= cx - half and sx <= cx + half
        and sy >= cy - half and sy <= cy + half
end

function Node.HitClose(geom, view, sx, sy)
    if geom.close == nil or view.zoom < Theme.TITLE_MIN_ZOOM then return false end
    local ccx, ccy = view:ToScreen(geom.x + geom.close.cx, geom.y + geom.close.cy)
    local half = view:Scale(Theme.CLOSE_SIZE) * 0.5
    if not headerBoxHit(ccx, ccy, half, sx, sy) then return false end
    return not Node.HitPencil(geom, view, sx, sy)
end

function Node.HitPencil(geom, view, sx, sy)
    if geom.pencil == nil or view.zoom < Theme.TITLE_MIN_ZOOM then return false end
    local pcx, pcy = view:ToScreen(geom.x + geom.pencil.cx, geom.y + geom.pencil.cy)
    local half = view:Scale(Theme.RENAME_ICON_SIZE) * 0.5
    return headerBoxHit(pcx, pcy, half, sx, sy)
end

function Node.HitModeStrip(geom, view, sx, sy)
    if geom.modeStrip == nil or view.zoom < Theme.CONTROL_MIN_ZOOM then return false end
    local ms = geom.modeStrip
    local bx, by = view:ToScreen(geom.x + ms.x, geom.y + ms.y)
    local bw, bh = view:Scale(ms.w), view:Scale(ms.h)
    return sx >= bx and sx <= bx + bw and sy >= by and sy <= by + bh
end

function Node.HitBody(geom, view, sx, sy)
    local x0, y0 = view:ToScreen(geom.x, geom.y)
    local x1, y1 = view:ToScreen(geom.x + geom.w, geom.y + geom.h)
    return sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1
end

return Node
