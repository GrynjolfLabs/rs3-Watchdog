-- Dialog: PrettyUI Window chrome — centered, modal dim, footer actions, per-parent stack.
-- Titlebar X is onDismiss only (not a generic onClose and not an action onClick).
-- The editor routes Escape to dismissTop; the dialog does not bind a global key.

local Dialog = {}

Dialog.DEFAULT_WIDTH = 328
Dialog.DEFAULT_HEIGHT = 150
Dialog.ACTION_GAP = 10
Dialog.ACTION_PAD = 10
Dialog.ACTION_Y = -35
Dialog.DIM_ALPHA = 0.4

-- stacks[parent] = { frame, ... }  (bottom → top)
-- chrome[parent] = { dim, blocker }
local stacks = {}
local chrome = {}

---@class Watchdog.DialogAction
---@field label string
---@field variant string|nil
---@field disabled boolean|nil
---@field tooltip string|nil
---@field onClick (fun(): boolean|nil)|nil  # true = pop; false/nil = stay; omitted = pop (unless disabled)

---@class Watchdog.DialogOpts
---@field title string|nil
---@field width integer|nil
---@field height integer|nil
---@field modal boolean|nil  # default true; full-screen dim + click blocker
---@field content (fun(win: any))|nil
---@field actions Watchdog.DialogAction[]|nil
---@field onDismiss (fun())|nil  # titlebar X only; no args; cannot veto

---@class Watchdog.DialogFrame
---@field parent any
---@field win any
---@field opts Watchdog.DialogOpts
---@field closed boolean

---@param opts Watchdog.DialogOpts|nil
---@return Watchdog.DialogOpts
function Dialog.resolve(opts)
    opts = opts or {}
    return {
        title = opts.title or "",
        width = opts.width or Dialog.DEFAULT_WIDTH,
        height = opts.height or Dialog.DEFAULT_HEIGHT,
        modal = opts.modal ~= false,
        content = opts.content,
        actions = opts.actions or {},
        onDismiss = opts.onDismiss,
    }
end

---@param parent any
---@return Watchdog.DialogFrame[]
local function stackOf(parent)
    local s = stacks[parent]
    if s == nil then
        s = {}
        stacks[parent] = s
    end
    return s
end

---@param parent any
---@return integer
function Dialog.depth(parent)
    local s = stacks[parent]
    if s == nil then return 0 end
    return #s
end

---@param layer any|nil
local function destroyLayer(layer)
    if layer == nil then return end
    pcall(function() layer:Destroy() end)
end

---@param parent any
local function destroyChrome(parent)
    local ch = chrome[parent]
    if ch == nil then return end
    chrome[parent] = nil
    destroyLayer(ch.blocker)
    destroyLayer(ch.dim)
end

---@param parent any
---@return any, any  # dim, blocker
local function ensureChrome(parent)
    local ch = chrome[parent]
    if ch ~= nil then return ch.dim, ch.blocker end
    local dim, blocker
    pcall(function()
        dim = ui.Layer.new(parent)
        dim:SetPos(0, 0)
        dim:SetSize(0, 0, 1.0, 1.0)
        dim.clickthrough = false
        local rect = ui.Rectangle.new(dim)
        rect.fill = true
        rect.clickthrough = false
        rect:SetPos(0, 0)
        rect:SetSize(0, 0, 1.0, 1.0)
        rect.colour = Vector4.new(0, 0, 0, Dialog.DIM_ALPHA)
    end)
    pcall(function()
        -- Invisible click catcher: one visual dim (above), this sits under the top Window
        -- so buried Dialogs stay visible but do not receive clicks.
        blocker = ui.Layer.new(parent)
        blocker:SetPos(0, 0)
        blocker:SetSize(0, 0, 1.0, 1.0)
        blocker.clickthrough = false
        local hit = ui.Rectangle.new(blocker)
        hit.fill = true
        hit.clickthrough = false
        hit:SetPos(0, 0)
        hit:SetSize(0, 0, 1.0, 1.0)
        hit.colour = Vector4.new(0, 0, 0, 0)
    end)
    chrome[parent] = { dim = dim, blocker = blocker }
    return dim, blocker
end

---@param component any|nil
local function raise(component)
    if component == nil then return end
    pcall(function()
        if component.MoveToFront ~= nil then
            component:MoveToFront()
        elseif component.Show ~= nil then
            component:Show()
        elseif component.root ~= nil and component.root.MoveToFront ~= nil then
            component.root:MoveToFront()
        end
    end)
end

---@param parent any
local function syncChrome(parent)
    local s = stacks[parent]
    if s == nil or #s == 0 then
        stacks[parent] = nil
        destroyChrome(parent)
        return
    end
    local anyModal = false
    for _, frame in ipairs(s) do
        if frame.opts.modal then anyModal = true break end
    end
    local top = s[#s]
    local dim, blocker
    if anyModal then
        dim, blocker = ensureChrome(parent)
    else
        destroyChrome(parent)
    end
    raise(dim)
    for i = 1, #s - 1 do
        raise(s[i].win)
    end
    if top.opts.modal then raise(blocker) end
    raise(top.win)
    pcall(function()
        if top.win.Show ~= nil then top.win:Show() end
    end)
end

function Dialog.raiseToFront(parent)
    syncChrome(parent)
end
local pop

---@param frame Watchdog.DialogFrame
---@param skipDestroy boolean|nil
pop = function(frame, skipDestroy)
    if frame.closed then return end
    frame.closed = true
    local parent = frame.parent
    local s = stacks[parent]
    if s ~= nil then
        for i = #s, 1, -1 do
            if s[i] == frame then
                table.remove(s, i)
                break
            end
        end
    end
    if not skipDestroy and frame.win ~= nil then
        pcall(function()
            frame.win.onClose = nil
            frame.win:Destroy()
        end)
    end
    syncChrome(parent)
end
function Dialog.dismissTop(parent)
    local s = stacks[parent]
    if s == nil or #s == 0 then return false end
    s[#s].win:Close()
    return true
end

---@param parent any
function Dialog.dismissAll(parent)
    if parent == nil then return end
    local s = stacks[parent]
    if s == nil then return end
    while #s > 0 do
        pop(s[#s], false)
    end
end

---@param label string
---@param action Watchdog.DialogAction
---@return integer
local function actionWidth(label, action)
    local w = 80
    pcall(function()
        w = select(1, prettyui.FancyButton.getSize(label, {
            variant = action.variant,
            disabled = action.disabled,
        }))
    end)
    return w
end

---@param frame Watchdog.DialogFrame
---@param action Watchdog.DialogAction
---@return fun()
local function bindAction(frame, action)
    return function()
        if frame.closed then return end
        if action.disabled then return end
        if action.onClick == nil then
            pop(frame, false)
            return
        end
        if action.onClick() == true then
            pop(frame, false)
        end
    end
end

---@param win any
---@param frame Watchdog.DialogFrame
---@param actions Watchdog.DialogAction[]
local function mountActions(win, frame, actions)
    local x = -Dialog.ACTION_PAD
    -- Last action is primary (rightmost); walk right-to-left so x is the right edge of each button.
    for i = #actions, 1, -1 do
        local action = actions[i]
        local label = action.label or ""
        local width = actionWidth(label, action)
        x = x - width
        pcall(function()
            win:AddFancyButton(label, bindAction(frame, action), {
                variant = action.variant or "neutral",
                disabled = action.disabled,
                tooltip = action.tooltip,
                xAnchor = 1,
                yAnchor = 1,
                x = x,
                y = Dialog.ACTION_Y,
            })
        end)
        x = x - Dialog.ACTION_GAP
    end
end

---@param parent any
---@param opts Watchdog.DialogOpts|nil
---@return any|nil window
function Dialog.mount(parent, opts)
    if parent == nil or prettyui == nil or prettyui.Window == nil then return nil end
    opts = Dialog.resolve(opts)
    ---@type Watchdog.DialogFrame
    local frame = {
        parent = parent,
        win = nil,
        opts = opts,
        closed = false,
    }
    local win
    local w, h = opts.width, opts.height
    local ok = pcall(function()
        win = prettyui.Window.new(parent, {
            title = opts.title,
            x = -math.floor(w / 2),
            y = -math.floor(h / 2),
            xAnchor = 0.5,
            yAnchor = 0.5,
            width = w,
            height = h,
            minWidth = w,
            minHeight = h,
            maxWidth = w,
            maxHeight = h,
            destroyOnClose = true,
            onClose = function()
                -- PrettyUI X: always pops. onDismiss is notification, not a veto.
                if frame.closed then return end
                if opts.onDismiss ~= nil then opts.onDismiss() end
                pop(frame, true)
            end,
        })
    end)
    if not ok or win == nil then return nil end
    frame.win = win
    local innerDestroy = win.Destroy
    function win:Destroy()
        pop(frame, true)
        innerDestroy(self)
    end
    stackOf(parent)[#stackOf(parent) + 1] = frame
    if opts.content ~= nil then
        pcall(opts.content, win)
    end
    mountActions(win, frame, opts.actions)
    syncChrome(parent)
    return win
end

return Dialog
