-- Pick a buff by clicking its icon. The window shows what's active now, a Common row,
-- and buffs that have been on the bar before, so a buff doesn't need to be active.

local BuffBar = require("src/buff_bar")
local BuffCatalog = require("src/buff_catalog")
local BuffSeen = require("src/buff_seen")
local Util = require("src/util")

local SUBSCRIBE_NAME = "watchdog_buff_capture"
local COLUMNS = 8
local TILE_WIDTH = 40
local ICON_SIZE = 27
local ICON_TOP = 4
local VALUE_HEIGHT = 18
local TILE_HEIGHT = ICON_TOP + ICON_SIZE + VALUE_HEIGHT  -- icon with its number underneath
local COMPACT_HEIGHT = ICON_TOP + ICON_SIZE + 4         -- rows that never show numbers
local PADDING = 12
-- The group box draws a border inside its own size; seen in game as about 18px left.
local FRAME_INSET = 24
local HEADER_HEIGHT = 22
local SECTION_GAP = 6
local INFO_HEIGHT = 26
local MAX_SEEN = 16
local INACTIVE_ALPHA = 0.35
local REFRESH_TICKS = 25  -- about twice a second

local HINT = "Hover for a name, click to choose"

local BuffCapture = {}
BuffCapture.__index = BuffCapture

function BuffCapture.new(eventSource)
    return setmetatable({
        eventSource = eventSource or Event,
        armed = false,
        nodeId = nil,
        pinName = nil,
        onCommit = nil,
        -- Same contract as ObjectMarkerCapture: the shell tucks away while armed.
        onArmedChange = nil,
    }, BuffCapture)
end

function BuffCapture:_setArmed(armed)
    armed = not not armed
    if self.armed == armed then
        return
    end
    self.armed = armed
    if self.onArmedChange ~= nil then
        Util.CallOrLog("buff_capture", "onArmedChange error", self.onArmedChange, armed)
    end
end

---------------------------------------------------------------------------
-- What to show
---------------------------------------------------------------------------

local function sameBuff(a, b)
    return a.kind == b.kind and a.id == b.id
end

-- Each tile is { pick, buff }; buff is what's on the bar now, or nil when inactive.
local function buildSections(sample)
    local active = {}
    for _, buff in ipairs(sample.list) do
        active[#active + 1] = { pick = BuffCatalog.PickFor(buff), buff = buff }
    end

    local common = {}
    for _, pick in ipairs(BuffCatalog.Common()) do
        common[#common + 1] = { pick = pick, buff = BuffBar.Find(sample, pick) }
    end

    -- Active buffs are already shown above, and Common already holds its sprites.
    local seen = {}
    for _, entry in ipairs(BuffSeen.List()) do
        local shown = false
        for _, buff in ipairs(sample.list) do
            if sameBuff(entry, buff) then shown = true end
        end
        for _, tile in ipairs(common) do
            if tile.pick.kind ~= "group" and sameBuff(entry, tile.pick) then shown = true end
        end
        if not shown and #seen < MAX_SEEN then
            seen[#seen + 1] = {
                pick = { kind = entry.kind, id = entry.id, name = entry.name or BuffCatalog.Describe(entry) },
            }
        end
    end

    return {
        { title = "Active now", tiles = active, empty = "Nothing is active right now." },
        { title = "Common", tiles = common },
        { title = "Recently seen", tiles = seen, compact = true,
          empty = "Buffs you've had before will appear here." },
    }
end

-- Changes only when icons appear, disappear or change state. Numbers update in place.
local function structureOf(sections)
    local parts = {}
    for _, section in ipairs(sections) do
        parts[#parts + 1] = section.title
        for _, tile in ipairs(section.tiles) do
            parts[#parts + 1] = (BuffBar.KeyOf(tile.pick) or "?") .. (tile.buff and "+" or "-")
        end
    end
    return table.concat(parts, "|")
end

local function describe(tile)
    local name = BuffCatalog.PickName(tile.pick) or "Unknown buff"
    if tile.pick.kind == "group" then
        name = "Any " .. name:lower()
    end
    if tile.buff == nil then
        return name .. "  ·  not active"
    end
    if tile.buff.text ~= "" then
        return name .. "  ·  active, " .. tile.buff.text
    end
    return name .. "  ·  active"
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function newText(parent, content)
    local label = ui.Text.new(parent)
    label.font = id.Font.MUSEO_SANS_15PT_REGULAR
    label.isShadowed = true
    label.content = content
    return label
end

local function addIcon(cell, pick, active)
    local icon = ui.Sprite.new(cell)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPos((TILE_WIDTH - ICON_SIZE) // 2, ICON_TOP)
    local objId = pick.kind == "obj" and pick.id or nil
    if pick.kind == "group" then
        objId = BuffCatalog.GroupIcon(BuffCatalog.Group(pick.group))
    end
    if objId ~= nil then
        icon.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
        icon:SetAssociatedObject(objId)
    elseif pick.kind == "sprite" then
        icon.sprite = pick.id
    end
    if not active then
        icon.alpha = INACTIVE_ALPHA
    end
end

function BuffCapture:_addTile(window, tile, x, y, height)
    local cell = ui.Layer.new(window)
    cell:SetSize(TILE_WIDTH, height)
    cell:SetPos(x, y)
    addIcon(cell, tile.pick, tile.buff ~= nil)

    if height == TILE_HEIGHT then
        local value = newText(cell, tile.buff and tile.buff.text or "")
        value:SetSize(TILE_WIDTH, VALUE_HEIGHT)
        value:SetPos(0, ICON_TOP + ICON_SIZE)
        value:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.TOPLEFT)
        tile.valueText = value
    end

    -- An invisible button on top takes the mouse, as Screen Marker's capture layer does.
    local capture = self
    local button = ui.Button.new(cell)
    button:SetSize(0, 0, 1.0, 1.0)
    button.alpha = 0
    button.clickthrough = false
    button:Subscribe(ui.Hook.ONCLICK, function()
        capture.picked = tile.pick
    end)
    button:Subscribe(ui.Hook.ONMOUSEOVER, function()
        capture:_hover(tile)
    end)
    button:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        if capture.hovered == tile then capture:_hover(nil) end
    end)
end

function BuffCapture:_hover(tile)
    self.hovered = tile
    if self.info ~= nil then
        self.info.content = tile and describe(tile) or HINT
    end
end

function BuffCapture:_destroyWindow()
    if self.window ~= nil then
        pcall(function() self.window:Destroy() end)
    end
    self.window, self.info, self.hovered = nil, nil, nil
    self.sections, self.structure = nil, nil
end

function BuffCapture:_build(sections)
    self:_destroyWindow()
    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if parent == nil then
        return
    end
    local contentWidth = COLUMNS * TILE_WIDTH
    local width = contentWidth + PADDING * 2 + FRAME_INSET * 2
    local window = ui.GroupBox.new(parent)
    window.stylesheetID = id.StyleSheet.DEFAULT
    window:SetHeaderLayout(0, 0, 0, 0, 0)
    window:SetPos(0, 0, 0.4, 0.2)
    self.window = window

    local y = PADDING
    for _, section in ipairs(sections) do
        local header = newText(window, section.title)
        header:SetSize(contentWidth, HEADER_HEIGHT)
        header:SetPos(PADDING, y)
        y = y + HEADER_HEIGHT

        local rowHeight = section.compact and COMPACT_HEIGHT or TILE_HEIGHT
        if #section.tiles == 0 then
            local empty = newText(window, section.empty or "")
            empty:SetSize(contentWidth, COMPACT_HEIGHT)
            empty:SetPos(PADDING, y)
            empty.alpha = 0.6
            y = y + COMPACT_HEIGHT
        else
            for index, tile in ipairs(section.tiles) do
                local column = (index - 1) % COLUMNS
                local row = (index - 1) // COLUMNS
                self:_addTile(window, tile, PADDING + column * TILE_WIDTH, y + row * rowHeight, rowHeight)
            end
            y = y + math.ceil(#section.tiles / COLUMNS) * rowHeight
        end
        y = y + SECTION_GAP
    end

    local info = newText(window, HINT)
    info:SetSize(contentWidth, INFO_HEIGHT)
    info:SetPos(PADDING, y)
    self.info = info
    window:SetSize(width, y + INFO_HEIGHT + PADDING + FRAME_INSET)

    self.sections = sections
    self.structure = structureOf(sections)
end

-- Same icons as last time: only numbers and the hover line change.
function BuffCapture:_updateValues(sections)
    for s, section in ipairs(sections) do
        for t, tile in ipairs(section.tiles) do
            local shown = self.sections[s].tiles[t]
            shown.buff = tile.buff
            local text = tile.buff and tile.buff.text or ""
            if shown.valueText ~= nil and shown.lastText ~= text then
                shown.valueText.content = text
                shown.lastText = text
            end
        end
    end
    if self.hovered ~= nil then
        self.info.content = describe(self.hovered)
    end
end

function BuffCapture:_refresh()
    local sample = BuffBar.Read() or { list = {} }
    pcall(BuffSeen.Record, sample.list)
    local sections = buildSections(sample)
    if self.window ~= nil and structureOf(sections) == self.structure then
        self:_updateValues(sections)
    else
        self:_build(sections)
    end
end

---------------------------------------------------------------------------
-- Arming
---------------------------------------------------------------------------

-- Clicks are only recorded by the button. Handling them here means the window
-- is never destroyed from inside one of its own components' callbacks.
function BuffCapture:_onLogic()
    if not self.armed then
        return
    end
    if self.picked ~= nil then
        local pick = self.picked
        local onCommit = self.onCommit
        self:Cancel()
        if onCommit ~= nil then
            Util.CallOrLog("buff_capture", "onCommit error", onCommit, pick)
        end
        return
    end
    self.ticks = self.ticks + 1
    if self.ticks >= REFRESH_TICKS then
        self.ticks = 0
        Util.CallOrLog("buff_capture", "refresh error", self._refresh, self)
    end
end

function BuffCapture:_unsubscribe()
    if self._subscribed then
        pcall(function() self.eventSource.Logic.Unsubscribe(SUBSCRIBE_NAME) end)
        self._subscribed = false
    end
end

function BuffCapture:Arm(nodeId, pinName, onCommit)
    self.nodeId, self.pinName, self.onCommit = nodeId, pinName, onCommit
    self.picked = nil
    self.ticks = 0
    self:_setArmed(true)
    Util.CallOrLog("buff_capture", "refresh error", self._refresh, self)
    if not self._subscribed then
        local capture = self
        self.eventSource.Logic.Subscribe(SUBSCRIBE_NAME, function() capture:_onLogic() end)
        self._subscribed = true
    end
end

function BuffCapture:IsArmed()
    return self.armed
end

function BuffCapture:Cancel()
    self:_unsubscribe()
    self:_destroyWindow()
    self.nodeId, self.pinName, self.onCommit, self.picked = nil, nil, nil, nil
    self:_setArmed(false)
end

---@param canvas any
function BuffCapture:Draw(canvas)
    if canvas == nil or not self.armed then
        return
    end
    local CaptureBanner = require("src/ui/capture_banner")
    CaptureBanner.Draw(canvas, CaptureBanner.BUFF_TEXT)
end

return BuffCapture
