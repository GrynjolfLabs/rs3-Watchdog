local Resize = require("ui/window_resize")

---@class Watchdog.MuxSurface
---@field id string                         # stable id for debugging / IsTop
---@field title string|fun():string         # window title while this surface is top
---@field SetVisible fun(self, v: boolean)
---@field OnShellHide fun(self)|nil         # optional: shell tucked (F8/Close); stack kept
---@field FrontOverlayPopups fun(self)|nil

---@class Watchdog.MuxWindow
---@field content any
---@field Show fun(self)
---@field Close fun(self)
---@field SetTitle fun(self, title: string)
---@field Destroy fun(self)
---@field MoveToFront fun(self)|nil
---@field root any|nil
---@field titleDrag any|nil
---@field onClose (fun(self: Watchdog.MuxWindow))|nil
---@field _RegisterOverlay fun(self, component: any, isVisible: (fun(): boolean)|nil, layout: (fun())|nil)|nil
---@field title string|nil
---@field shown boolean|nil
---@field closeCount integer|nil
---@field showCount integer|nil
---@field destroyCount integer|nil
---@field raiseCount integer|nil

---@class Watchdog.MultiplexerOpts
---@field x number|nil
---@field y number|nil
---@field xAnchor number|nil
---@field yAnchor number|nil
---@field width number|nil
---@field height number|nil
---@field minWidth number|nil
---@field minHeight number|nil
---@field scrollable boolean|nil            # default false
---@field onHide (fun())|nil                # ribbon sync etc. after hide
---@field window Watchdog.MuxWindow|nil     # headless: pre-bound window (skips prettyui in Mount)
---@field overlay any|nil                   # headless: overlay parent (default {})
---@field useParentAsRoot boolean|nil       # Mount: treat parent as rootLayer instead of creating one

---@class Watchdog.Multiplexer
---@field onHide (fun())|nil
---@field window Watchdog.MuxWindow|nil
---@field rootLayer any|nil
---@field _overlay any|nil
---@field _stack Watchdog.MuxSurface[]
---@field _visible boolean
---@field _winOpts table
---@field _injected boolean
---@field _ownsRoot boolean
---@field _ownsOverlay boolean
---@field _inCloseCallback boolean
---@field _useParentAsRoot boolean
---@field _hiddenForCapture boolean         # shell tucked for Object Marker select (#14)
local Multiplexer = {}
Multiplexer.__index = Multiplexer

---@param self Watchdog.Multiplexer
---@return fun()
local function bindOnClose(self)
    return function()
        if self._inCloseCallback then return end
        self._inCloseCallback = true
        self:SetVisible(false)
        self._inCloseCallback = false
    end
end

---@param opts Watchdog.MultiplexerOpts|nil
---@return Watchdog.Multiplexer
function Multiplexer.new(opts)
    opts = opts or {}
    local self = setmetatable({
        onHide = opts.onHide,
        window = nil,
        rootLayer = nil,
        _overlay = nil,
        _stack = {},
        _visible = false,
        _winOpts = {
            x = opts.x,
            y = opts.y,
            xAnchor = opts.xAnchor,
            yAnchor = opts.yAnchor,
            width = opts.width,
            height = opts.height,
            minWidth = opts.minWidth,
            minHeight = opts.minHeight,
            scrollable = opts.scrollable == true, -- default false
        },
        _injected = false,
        _ownsRoot = false,
        _ownsOverlay = false,
        _inCloseCallback = false,
        _hiddenForCapture = false,
        _useParentAsRoot = opts.useParentAsRoot == true,
    }, Multiplexer)

    if opts.window ~= nil then
        self.window = opts.window
        self._overlay = opts.overlay or {}
        self._injected = true
        if self.window.onClose == nil then
            self.window.onClose = bindOnClose(self)
        end
    end

    return self
end

---@param parent any
---@return Watchdog.Multiplexer
function Multiplexer:Mount(parent)
    if self.window ~= nil then
        return self
    end

    local rootLayer
    if self._useParentAsRoot and parent ~= nil then
        rootLayer = parent
        self._ownsRoot = false
    else
        rootLayer = ui.Layer.new(parent)
        rootLayer:SetPos(0, 0)
        rootLayer:SetSize(0, 0, 1.0, 1.0)
        self._ownsRoot = true
    end
    self.rootLayer = rootLayer

    local winOpts = {
        title = "",
        x = self._winOpts.x,
        y = self._winOpts.y,
        xAnchor = self._winOpts.xAnchor,
        yAnchor = self._winOpts.yAnchor,
        width = self._winOpts.width,
        height = self._winOpts.height,
        minWidth = self._winOpts.minWidth,
        minHeight = self._winOpts.minHeight,
        scrollable = self._winOpts.scrollable,
        destroyOnClose = false,
        onClose = bindOnClose(self),
    }
    self.window = prettyui.Window.new(rootLayer, winOpts)

    local overlay = ui.Layer.new(rootLayer)
    overlay:SetPos(0, 0)
    overlay:SetSize(0, 0, 1.0, 1.0)
    overlay.clickthrough = true
    self._overlay = overlay
    self.resizeHandle = Resize.new(self.window, rootLayer, overlay)
    self._ownsOverlay = true

    -- PrettyUI raises the window on show and drag; register the overlay to keep it above the window.
    if self.window._RegisterOverlay ~= nil then
        pcall(function()
            self.window:_RegisterOverlay(overlay, function()
                return self._visible
            end, nil)
        end)
    end

    -- The overlay is a sibling of the window, so closing the window does not hide it.
    self._visible = false
    self.window:Close()
    pcall(function() overlay.hidden = true end)

    return self
end

function Multiplexer:Unmount()
    if self.resizeHandle ~= nil then self.resizeHandle:Destroy(); self.resizeHandle = nil end
    for i = #self._stack, 1, -1 do
        local surface = self._stack[i]
        if surface ~= nil and surface.SetVisible ~= nil then
            pcall(function() surface:SetVisible(false) end)
        end
    end

    if self.window ~= nil and self.window.Destroy ~= nil and not self._injected then
        pcall(function() self.window:Destroy() end)
    end
    self.window = nil

    if self._ownsOverlay and self._overlay ~= nil and self._overlay.Destroy ~= nil then
        pcall(function() self._overlay:Destroy() end)
    end
    self._overlay = nil
    self._ownsOverlay = false

    if self._ownsRoot and self.rootLayer ~= nil and self.rootLayer.Destroy ~= nil then
        pcall(function() self.rootLayer:Destroy() end)
    end
    self.rootLayer = nil
    self._ownsRoot = false
    self._visible = false
end

function Multiplexer:Destroy()
    self:Unmount()
    self._stack = {}
    self._injected = false
end

---@return any
function Multiplexer:Content()
    if self.window == nil then return nil end
    return self.window.content
end

---@return Watchdog.MuxWindow|nil
function Multiplexer:Window()
    return self.window
end

---@return any
function Multiplexer:Overlay()
    return self._overlay
end

---@param surface Watchdog.MuxSurface|nil
---@return string
local function resolveTitle(surface)
    if surface == nil then return "" end
    local title = surface.title
    if type(title) == "function" then
        local ok, result = pcall(title)
        if ok and result ~= nil then return tostring(result) end
        return ""
    end
    if title == nil then return "" end
    return tostring(title)
end

---@param self Watchdog.Multiplexer
local function applyTitle(self)
    local top = self._stack[#self._stack]
    if self.window == nil or self.window.SetTitle == nil then return end
    self.window:SetTitle(resolveTitle(top))
end

---@param self Watchdog.Multiplexer
---@param showTop boolean
local function applySurfaceVisibility(self, showTop)
    local top = self._stack[#self._stack]
    for i = 1, #self._stack do
        local surface = self._stack[i]
        local want = showTop and surface == top
        if surface ~= nil and surface.SetVisible ~= nil then
            surface:SetVisible(want)
        end
    end
end

---@param surface Watchdog.MuxSurface
function Multiplexer:Push(surface)
    if surface == nil then return end
    local prev = self._stack[#self._stack]
    if prev ~= nil and prev.SetVisible ~= nil then
        prev:SetVisible(false)
    end
    self._stack[#self._stack + 1] = surface
    if surface.SetVisible ~= nil then
        surface:SetVisible(self._visible)
    end
    applyTitle(self)
end

---@return boolean  # false when already at root (depth <= 1); root stays
function Multiplexer:Pop()
    if #self._stack <= 1 then return false end
    local top = table.remove(self._stack)
    if top ~= nil and top.SetVisible ~= nil then
        top:SetVisible(false)
    end
    local prev = self._stack[#self._stack]
    if self._visible and prev ~= nil and prev.SetVisible ~= nil then
        prev:SetVisible(true)
    end
    applyTitle(self)
    return true
end

---@param id string
---@return boolean  # true if `id` is now top
function Multiplexer:PopTo(id)
    while #self._stack > 1 do
        local top = self._stack[#self._stack]
        if top ~= nil and top.id == id then break end
        if not self:Pop() then break end
    end
    return self:IsTop(id)
end

---@return integer
function Multiplexer:Depth()
    return #self._stack
end

---@return Watchdog.MuxSurface|nil
function Multiplexer:Top()
    return self._stack[#self._stack]
end

---@param id string
---@return boolean
function Multiplexer:IsTop(id)
    local top = self._stack[#self._stack]
    return top ~= nil and top.id == id
end

-- Window.Close does not hide tooltips parented to the overlay.
local function hidePrettyUiTooltipTree(ctx)
    if ctx == nil then return end
    for _, tip in ipairs(ctx.tooltips or {}) do
        pcall(function()
            if tip.Hide ~= nil then tip:Hide() end
        end)
    end
    for _, child in ipairs(ctx.children or {}) do
        hidePrettyUiTooltipTree(child)
    end
end

---@param v boolean
function Multiplexer:SetVisible(v)
    v = not not v
    if self._visible == v then return end
    self._visible = v

    if self.resizeHandle ~= nil then self.resizeHandle:Sync(v) end
    if v then
        if self._overlay ~= nil then
            pcall(function() self._overlay.hidden = false end)
        end
        if self.window ~= nil and self.window.Show ~= nil then
            self.window:Show()
        end
        self:RaiseToFront()
        applySurfaceVisibility(self, true)
        applyTitle(self)
    else
        -- Dismiss gestures without resetting the editor state on F8.
        local top = self._stack[#self._stack]
        if top ~= nil and top.OnShellHide ~= nil then
            pcall(function() top:OnShellHide() end)
        end
        hidePrettyUiTooltipTree(self.window and self.window.tooltipContext)
        if prettyui ~= nil and prettyui.Tooltip ~= nil and prettyui.Tooltip.getContext ~= nil then
            local content = self.window and self.window.content
            if content ~= nil then
                hidePrettyUiTooltipTree(prettyui.Tooltip.getContext(content))
            end
        end
        if self._overlay ~= nil then
            pcall(function() self._overlay.hidden = true end)
        end
        -- Skip Close inside its own callback to avoid recursion.
        if self.window ~= nil and self.window.Close ~= nil and not self._inCloseCallback then
            self.window:Close()
        end
        if self.onHide ~= nil then
            self.onHide()
        end
    end
end

-- Restore the shell only if object selection hid it.
function Multiplexer:HideForCapture()
    if self._hiddenForCapture or not self._visible then
        return
    end
    self._hiddenForCapture = true
    self:SetVisible(false)
end

function Multiplexer:RestoreFromCapture()
    if not self._hiddenForCapture then
        return
    end
    self._hiddenForCapture = false
    self:SetVisible(true)
end

---@return boolean
function Multiplexer:IsHiddenForCapture()
    return self._hiddenForCapture == true
end

function Multiplexer:Toggle()
    self:SetVisible(not self._visible)
end

---@return boolean
function Multiplexer:IsVisible()
    return self._visible
end

function Multiplexer:RaiseToFront()
    local w = self.window
    if w == nil then return end
    if w.root ~= nil and w.root.MoveToFront ~= nil then
        w.root:MoveToFront()
        if w.titleDrag ~= nil and w.titleDrag.MoveToFront ~= nil then
            w.titleDrag:MoveToFront()
        end
    elseif w.MoveToFront ~= nil then
        w:MoveToFront()
    end
    self:SyncChrome()
end

-- Raise popups after the resize handle so it cannot cover them or intercept clicks.
function Multiplexer:SyncChrome()
    if self.window == nil or not self._visible then return end
    if self._overlay ~= nil and self._overlay.MoveToFront ~= nil then
        self._overlay:MoveToFront()
    end
    if self.resizeHandle ~= nil then self.resizeHandle:Sync(true) end
    local top = self._stack[#self._stack]
    if top ~= nil and top.FrontOverlayPopups ~= nil then
        top:FrontOverlayPopups()
    end
end

function Multiplexer:SyncTitle()
    applyTitle(self)
end

return Multiplexer
