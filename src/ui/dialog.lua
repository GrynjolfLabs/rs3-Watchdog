-- Dialog: PrettyUI Window chrome — centered, modal dim, footer actions, per-parent stack.
-- Titlebar X is onDismiss only (not a generic onClose and not an action onClick).
-- Esc is intentionally unbound: the client would also open the pause menu.

local Dialog = {}

Dialog.DEFAULT_WIDTH = 328
Dialog.DEFAULT_HEIGHT = 150
Dialog.ACTION_GAP = 10
Dialog.ACTION_PAD = 10
Dialog.ACTION_Y = -35
Dialog.DIM_ALPHA = 0.4

-- stacks[parent] = { frame, ... }  (bottom → top)
-- chrome[parent] = { dim }
local stacks = {}
local chrome = {}

---@class Watchdog.DialogAction
---@field label string
---@field variant string|nil
---@field disabled boolean|nil
---@field tooltip string|nil
---@field setDisabled fun(disabled: boolean)|nil  # assigned at mount; tracks a field as it changes
---@field onClick (fun(): boolean|nil)|nil  # true = pop; false/nil = stay; omitted = pop (unless disabled)
---@field button any|nil  # mounted footer button; set so disabled can change with the field

---@class Watchdog.DialogOpts
---@field title string|nil
---@field width integer|nil
---@field height integer|nil
---@field modal boolean|nil  # default true; full-screen dim under the topmost modal
---@field content (fun(win: any))|nil
---@field actions Watchdog.DialogAction[]|nil
---@field onDismiss (fun())|nil  # titlebar X only; no args; cannot veto
---@field rowBackgroundColours integer[]|nil  # striped flow rows on the PrettyUI window

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
        rowBackgroundColours = opts.rowBackgroundColours,
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
    destroyLayer(ch.dim)
end

---@param parent any
---@return any dim
local function ensureChrome(parent)
    local ch = chrome[parent]
    if ch ~= nil then return ch.dim end
    local dim
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
    chrome[parent] = { dim = dim }
    return dim
end

--- Bring prettyui window to the front without triggering overlay layout.
---@param win any
---@return boolean
local function frontWindow(win)
    local root = win.root
    if root == nil or root.MoveToFront == nil then return false end
    root.hidden = false
    root:MoveToFront()
    if win.titleDrag ~= nil and win.titleDrag.MoveToFront ~= nil then
        win.titleDrag.hidden = false
        win.titleDrag:MoveToFront()
    end
    if win.overlays == nil then return true end
    for component, overlay in pairs(win.overlays) do
        if component.hidden ~= true and overlay.isVisible() then
            component:MoveToFront()
        end
    end
    return true
end

---@param component any|nil
local function raise(component)
    if component == nil then return end
    pcall(function()
        if frontWindow(component) then return end
        if component.MoveToFront ~= nil then
            component:MoveToFront()
        elseif component.Show ~= nil then
            component:Show()
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
    local modalAt
    for i = #s, 1, -1 do
        if s[i].opts.modal then
            modalAt = i
            break
        end
    end
    local dim
    if modalAt ~= nil then
        dim = ensureChrome(parent)
    else
        destroyChrome(parent)
    end
    -- Below the topmost modal, then the dim, then the rest. No modal: the last window stays in front.
    local split = modalAt or #s
    for i = 1, split - 1 do
        raise(s[i].win)
    end
    raise(dim)
    for i = split, #s - 1 do
        raise(s[i].win)
    end
    raise(s[#s].win)
end

--- The shell overlay is raised every frame, which covers dialogs parented to the
--- shell root. Re-apply stack order so that dim stays above the overlay.
---@param parent any
function Dialog.front(parent)
    if parent == nil then return end
    local s = stacks[parent]
    if s == nil or #s == 0 then return end
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

--- A mounted action's `disabled` is live: bindAction reads it on click, and the button
--- widget is updated so a field change can disable Rename without remounting.
---@param action Watchdog.DialogAction|nil
---@param disabled boolean
function Dialog.setActionDisabled(action, disabled)
    if action == nil then return end
    action.disabled = disabled == true
    local button = action.button
    if button ~= nil and button.SetDisabled ~= nil then
        pcall(function() button:SetDisabled(action.disabled) end)
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
        local btn
        pcall(function()
            btn = win:AddFancyButton(label, bindAction(frame, action), {
                variant = action.variant or "neutral",
                disabled = action.disabled,
                tooltip = action.tooltip,
                xAnchor = 1,
                yAnchor = 1,
                x = x,
                y = Dialog.ACTION_Y,
            })
        end)
        action.button = btn
        -- The flag is fixed at mount unless the caller updates it as a field changes.
        -- Rename calls Dialog.setActionDisabled; Save as preset calls action.setDisabled.
        action.setDisabled = function(disabled)
            Dialog.setActionDisabled(action, disabled)
        end
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
            rowBackgroundColours = opts.rowBackgroundColours,
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

-- A center anchor keeps the window center fixed, so SetSize slides the title bar.
-- Put the top back, then remember that point. SetSize remembered the slid one.
---@param win any
---@param width number
---@param height number
function Dialog.resizeKeepingTop(win, width, height)
    local root = win.root
    local topX = root.x or 0
    local topY = root.y or 0
    win.minWidth = width
    win.maxWidth = width
    win.minHeight = height
    win.maxHeight = height
    win:SetSize(width, height)
    root:SetPos(topX, topY)
    if win.titleDrag ~= nil then
        win.titleDrag:SetPos(topX, topY)
    end
    if win.dragBounds ~= nil then
        win.dragBounds:RememberPosition()
    end
end

-- A refused alert, preset, or scope save. Not a size refusal: that dialog is separate.
---@param parent any
---@return any|nil window
function Dialog.failedSave(parent)
    return Dialog.mount(parent, {
        title = "Could not save",
        width = 420,
        height = 180,
        content = function(win)
            win:AddText("Watchdog could not save that change.")
            win:AddText("The last saved copy is still there.")
        end,
        actions = { { label = "Close" } },
    })
end

-- A token over the PersistentDB cap. The same dialog covers an alert, a
-- scope tree, and a preset. It is not the generic failed-save dialog.
---@param parent any
---@return any|nil window
function Dialog.tooBig(parent)
    return Dialog.mount(parent, {
        title = "Too big to save",
        width = 420,
        height = 180,
        content = function(win)
            win:AddText("That change is too big to save.")
            win:AddText("The last saved copy is still there.")
        end,
        actions = { { label = "Close" } },
    })
end

-- One dialog for every alert whose key was missing or unreadable. The row
-- stays in the tree. Naming it here is how the player finds that row.
---@param parent any
---@param names string[]
---@return any|nil window
function Dialog.unreadAlerts(parent, names)
    return Dialog.mount(parent, {
        title = "Could not load",
        width = 420,
        height = 180,
        content = function(win)
            if names == nil or #names ~= 1 then
                win:AddText("These alerts did not load. The saved copies are still there.")
                for _, name in ipairs(names or {}) do
                    win:AddText(name)
                end
            else
                win:AddText("Could not load " .. names[1] .. ".")
                win:AddText("The saved copy is still there.")
            end
        end,
        actions = { { label = "Close" } },
    })
end

-- The new scope key is present and this build cannot use it. The legacy
-- document is not a fallback, and nothing may write over the bad key.
---@param parent any
---@return any|nil window
function Dialog.scopeUnreadable(parent)
    return Dialog.mount(parent, {
        title = "Could not load",
        width = 420,
        height = 180,
        content = function(win)
            win:AddText("This scope could not be read.")
            win:AddText("Nothing was written over the saved copy.")
        end,
        actions = { { label = "Close" } },
    })
end

return Dialog
