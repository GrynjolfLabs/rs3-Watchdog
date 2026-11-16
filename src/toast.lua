local Util = require("src/util")
local Theme = require("src/ui/theme")
local HubLayers = require("src/ui/hub_layers")

local function callOrLog(context, fn, ...)
    return Util.CallOrLog("toast", context, fn, ...)
end

local Toast = {}
Toast.__index = Toast

-- The single owner key every Toast node's toasts share in the EffectRegistry's Stack, so
-- the cap below applies across the whole graph (all alerts), not per node.
Toast.OWNER = "toast"
Toast.MAX_STACK = 10
Toast.DEFAULT_TTL = 5.0

-- persistence optional: `{ Load() -> {dx,dy}|nil, Save({dx,dy}) }`. Omitted: anchor does not survive reload.
function Toast.new(effects, persistence)
    assert(effects ~= nil, "ToastStack requires an EffectRegistry")
    local self = setmetatable({
        effects = effects,
        persistence = persistence,
        live = {},        -- ordered list of live toast handles, oldest first
        byOwner = {},     -- nodeKey -> { handle, ... }, oldest first
        anchor = { dx = 0, dy = 0 },
        drag = nil,       -- { startMouse = {x,y}, startAnchor = {dx,dy} } while a drag is live
        capture = nil,    -- client-only drag-capture panel, see Mount
        rootParent = nil, -- client root component, kept for screen width (see _screenWidth)
    }, Toast)
    self:_loadAnchor()
    return self
end

--- Anchor persistence -----------------------------------------------------------------

function Toast:_loadAnchor()
    if self.persistence == nil or self.persistence.Load == nil then
        return
    end
    local ok, pos = pcall(self.persistence.Load)
    if ok and type(pos) == "table" and type(pos.dx) == "number" and type(pos.dy) == "number" then
        self.anchor = { dx = pos.dx, dy = pos.dy }
    end
end

function Toast:_saveAnchor()
    if self.persistence == nil or self.persistence.Save == nil then
        return
    end
    callOrLog("anchor Save", self.persistence.Save, { dx = self.anchor.dx, dy = self.anchor.dy })
end

function Toast:GetAnchorOffset()
    return { dx = self.anchor.dx, dy = self.anchor.dy }
end

-- Clear the gesture first so Update and the release cannot save the drag.
function Toast:ResetAnchor()
    self._pressed = false
    self.drag = nil
    self.anchor = { dx = 0, dy = 0 }
    self:_saveAnchor()
    self:Update()
end

--- Drag ---------------------------------------------------------------------------------

function Toast:BeginDrag(mousePos)
    if HubLayers.PositionsLocked() then return end
    self.drag = {
        startMouse = { x = mousePos.x, y = mousePos.y },
        startAnchor = { dx = self.anchor.dx, dy = self.anchor.dy },
    }
end

function Toast:DragTo(mousePos)
    if self.drag == nil then
        return
    end
    local dx = mousePos.x - self.drag.startMouse.x
    local dy = mousePos.y - self.drag.startMouse.y
    self.anchor = { dx = self.drag.startAnchor.dx + dx, dy = self.drag.startAnchor.dy + dy }
end

-- Persist only on gesture end, not every polled frame.
function Toast:EndDrag()
    if self.drag == nil then
        return
    end
    self.drag = nil
    self:_saveAnchor()
end

--- Show / Dismiss --------------------------------------------------------------------------

-- #36: same-node re-fire stacks a second handle, never replaces.
function Toast:Show(nodeKey, params)
    params = params or {}
    local sticky = params.sticky and true or false
    local state = {
        nodeKey = nodeKey,
        text = params.text or "",
        color = params.color,
        icon = params.icon,
        sticky = sticky,
        remaining = sticky and nil or (params.ttl or Toast.DEFAULT_TTL),
    }

    local self_ = self
    local handle
    handle = {
        kind = "toast",
        state = state,
        update = function(dt)
            if state.sticky then
                return true
            end
            state.remaining = state.remaining - dt
            return state.remaining > 0
        end,
        draw = function(canvas) self_:_drawHandle(canvas, handle) end,
        onDone = function() self_:_forget(handle) end,
    }

    self.live[#self.live + 1] = handle
    local owned = self.byOwner[nodeKey]
    if owned == nil then
        owned = {}
        self.byOwner[nodeKey] = owned
    end
    owned[#owned + 1] = handle

    self.effects:PushStack(Toast.OWNER, handle, Toast.MAX_STACK)
    return handle
end

function Toast:_forget(handle)
    for i, h in ipairs(self.live) do
        if h == handle then
            table.remove(self.live, i)
            break
        end
    end
    local owned = self.byOwner[handle.state.nodeKey]
    if owned == nil then
        return
    end
    for i, h in ipairs(owned) do
        if h == handle then
            table.remove(owned, i)
            break
        end
    end
    if #owned == 0 then
        self.byOwner[handle.state.nodeKey] = nil
    end
end

-- #36: dismiss clears all of that node's live toasts (including sticky).
-- Snapshot the owned list; each Dismiss onDone mutates byOwner[nodeKey].
function Toast:Dismiss(nodeKey)
    local owned = self.byOwner[nodeKey]
    if owned == nil then
        return
    end
    local toDismiss = {}
    for i, h in ipairs(owned) do
        toDismiss[i] = h
    end
    for _, h in ipairs(toDismiss) do
        self.effects:Dismiss(h)
    end
end

function Toast:LiveCount()
    return #self.live
end

--- Canvas drawing (client-only; untested under the standalone Lua test harness) -----------

-- Canvas cannot be measured; fall back so this never errors outside the client.
function Toast:_screenWidth()
    local w = 1920
    if self.rootParent ~= nil then
        pcall(function()
            if self.rootParent.width and self.rootParent.width > 0 then w = self.rootParent.width end
        end)
    end
    return w
end

function Toast:_anchorPoint()
    return {
        x = self:_screenWidth() * 0.5 + self.anchor.dx,
        y = Theme.TOAST_TOP_MARGIN + self.anchor.dy,
    }
end

-- #36 AC. Canvas primitives only, not ui.GroupBox.
function Toast:_drawHandle(canvas, handle)
    local index
    for i, h in ipairs(self.live) do
        if h == handle then index = i; break end
    end
    if index == nil then
        return
    end

    local anchor = self:_anchorPoint()
    local x = anchor.x - Theme.TOAST_W * 0.5
    local y = anchor.y + (index - 1) * (Theme.TOAST_H + Theme.TOAST_GAP)
    local w, h = Theme.TOAST_W, Theme.TOAST_H
    local state = handle.state

    canvas:AddRectangle(x, y, w, h, Theme.Vec4(Theme.COL_TOAST_BG))
    local accent = state.color
    if accent ~= nil then
        canvas:AddRectangle(x, y, Theme.TOAST_ACCENT_W, h,
            Vector4.new((accent.r or 255) / 255, (accent.g or 255) / 255, (accent.b or 255) / 255,
                (accent.a or 255) / 255))
    end
    canvas:AddOutline(x, y, w, h, Theme.BORDER_THICKNESS, Theme.Vec4(Theme.COL_TOAST_BORDER))

    local textX = x + Theme.TOAST_ACCENT_W + Theme.TOAST_PAD_X
    if state.icon ~= nil then
        local iconY = y + (h - Theme.TOAST_ICON_SIZE) * 0.5
        -- AddSprite's colour arg is a Uint RGBA, not a Vector4 (see
        -- docs/research/popup-frame-sprites.md); untinted white, like InfoBox.
        canvas:AddSprite(textX, iconY, Theme.TOAST_ICON_SIZE, Theme.TOAST_ICON_SIZE, state.icon,
            0xFFFFFFFF)
        textX = textX + Theme.TOAST_ICON_SIZE + Theme.TOAST_PAD_X
    end

    local font = Theme.Font(12)
    if font ~= nil then
        canvas:AddText(textX, y + h * 0.5 - 6, state.text, font, Theme.Vec4(Theme.COL_TOAST_TEXT))
    end
end

function Toast:Draw(canvas)
    if canvas == nil then
        return
    end
    for _, handle in ipairs(self.live) do
        callOrLog("draw error", handle.draw, canvas)
    end
end

--- Drag capture mount (client-only; untested under the standalone Lua test harness) -------

-- Overlay canvas is clickthrough; drag needs a separate capture panel.
-- Update refreshes clickthrough after Mount, because the hub lock can change.
function Toast:Mount(rootParent)
    self.rootParent = rootParent
    if self.capture ~= nil then
        return
    end
    local ok, capture = pcall(function()
        local c = ui.Panel.new(rootParent)
        c.clickthrough = HubLayers.PositionsLocked()
        local self_ = self
        c:Subscribe(ui.Hook.ONCLICK, function()
            local pos = (Mouse ~= nil and Mouse.GetPosition ~= nil) and Mouse.GetPosition() or nil
            if pos ~= nil then
                self_:BeginDrag(pos)
                self_._pressed = true
            end
        end)
        c:Subscribe(ui.Hook.ONRELEASE, function()
            self_._pressed = false
            self_:EndDrag()
        end)
        return c
    end)
    if ok then
        self.capture = capture
    elseif log ~= nil then
        log("Watchdog toast: Mount failed - " .. tostring(capture))
    end
end

function Toast:Unmount()
    if self.capture ~= nil then
        pcall(function() self.capture:Destroy() end)
        self.capture = nil
    end
end

-- Reposition capture over the live stack so it only intercepts toast clicks.
function Toast:Update()
    local locked = HubLayers.PositionsLocked()
    if locked and (self._pressed or self.drag ~= nil) then
        self._pressed = false
        self:EndDrag()
    end
    if self._pressed and Mouse ~= nil and Mouse.GetPosition ~= nil then
        local ok, pos = pcall(Mouse.GetPosition)
        if ok and pos ~= nil then
            self:DragTo(pos)
        end
    end
    if self.capture == nil then
        return
    end
    pcall(function()
        self.capture.clickthrough = locked
    end)
    if #self.live == 0 then
        pcall(function()
            self.capture:SetSize(0, 0)
        end)
        return
    end
    local anchor = self:_anchorPoint()
    local x = anchor.x - Theme.TOAST_W * 0.5
    local h = #self.live * Theme.TOAST_H + math.max(0, #self.live - 1) * Theme.TOAST_GAP
    pcall(function()
        self.capture:SetPos(x, anchor.y)
        self.capture:SetSize(Theme.TOAST_W, h)
    end)
end

return Toast
