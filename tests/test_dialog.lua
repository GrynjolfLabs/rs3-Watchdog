-- ui/dialog.lua stack + dismiss contract, via a fake prettyui / ui.* host.

local luaunit = require("luaunit")

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }

local windows = {}
local layers = {}

local function fakeLayer(parent)
    local layer = {
        parent = parent,
        clickthrough = false,
        destroyed = false,
        raiseCount = 0,
        hidden = false,
    }
    function layer:SetPos() end
    function layer:SetSize() end
    function layer:MoveToFront()
        self.raiseCount = self.raiseCount + 1
    end
    function layer:Destroy()
        self.destroyed = true
    end
    layers[#layers + 1] = layer
    return layer
end

local function fakeRect(parent)
    local r = { parent = parent, fill = false, clickthrough = false, colour = nil }
    function r:SetPos() end
    function r:SetSize() end
    return r
end

local function installHost()
    windows = {}
    layers = {}
    _G.ui = {
        Layer = { new = fakeLayer },
        Rectangle = { new = fakeRect },
        Hook = { ONCLICK = "ONCLICK" },
    }
    _G.prettyui = {
        FancyButton = {
            getSize = function(_text, _opts) return 80, 27 end,
        },
        Window = {
            new = function(parent, options)
                local w = {
                    parent = parent,
                    options = options,
                    title = options.title,
                    onClose = options.onClose,
                    destroyOnClose = options.destroyOnClose == true,
                    buttons = {},
                    texts = {},
                    fields = {},
                    shown = false,
                    destroyed = false,
                    raiseCount = 0,
                }
                function w:AddText(text)
                    self.texts[#self.texts + 1] = text
                end
                function w:AddFancyButton(label, action, opts)
                    local btn = {
                        label = label,
                        action = action,
                        opts = opts or {},
                        disabled = opts ~= nil and opts.disabled == true,
                    }
                    function btn:SetDisabled(disabled)
                        self.disabled = disabled == true
                        self.opts.disabled = self.disabled
                    end
                    self.buttons[#self.buttons + 1] = btn
                    return btn
                end
                function w:AddTextField(opts)
                    opts = opts or {}
                    local field = {
                        opts = opts,
                        text = opts.text or "",
                        root = {
                            text = {},
                            Subscribe = function() end,
                            SelectAll = function() end,
                        },
                    }
                    function field:GetText() return self.text end
                    function field:SetText(t) self.text = t end
                    function field:SetDisabled() end
                    self.fields[#self.fields + 1] = field
                    return field
                end
                function w:Show()
                    self.shown = true
                    self.raiseCount = self.raiseCount + 1
                end
                function w:MoveToFront()
                    self.raiseCount = self.raiseCount + 1
                end
                function w:Close()
                    if self.onClose then self.onClose(self) end
                    if self.destroyOnClose then self:Destroy() end
                end
                function w:Destroy()
                    self.destroyed = true
                end
                windows[#windows + 1] = w
                return w
            end,
        },
    }
end

local luaunit = require("luaunit")
local Dialog = require("src/ui/dialog")
local Confirm = require("src/ui/confirm")

local function button(win, label)
    for _, btn in ipairs(win.buttons) do
        if btn.label == label then return btn end
    end
    return nil
end

TestDialog = {}

function TestDialog:setUp()
    self._savedUi = _G.ui
    self._savedPretty = _G.prettyui
    installHost()
    self.parent = { id = "p" }
    Dialog.dismissAll(self.parent)
end

function TestDialog:tearDown()
    Dialog.dismissAll(self.parent)
    _G.ui = self._savedUi
    _G.prettyui = self._savedPretty
end

function TestDialog:testResolveDefaults()
    local opts = Dialog.resolve({})
    luaunit.assertEquals(opts.width, Dialog.DEFAULT_WIDTH)
    luaunit.assertEquals(opts.height, Dialog.DEFAULT_HEIGHT)
    luaunit.assertTrue(opts.modal)
    luaunit.assertEquals(#opts.actions, 0)
    luaunit.assertNil(opts.rowBackgroundColours)
    luaunit.assertFalse(Dialog.resolve({ modal = false }).modal)
    local colours = { 1, 2 }
    luaunit.assertEquals(
        Dialog.resolve({ rowBackgroundColours = colours }).rowBackgroundColours,
        colours
    )
end

function TestDialog:testMountNilWithoutPrettyui()
    local saved = _G.prettyui
    _G.prettyui = nil
    luaunit.assertNil(Dialog.mount(self.parent, { title = "X" }))
    _G.prettyui = saved
end

function TestDialog:testOmittedOnClickPops()
    local win = Dialog.mount(self.parent, {
        title = "Msg",
        content = function(w) w:AddText("hello") end,
        actions = { { label = "Close" } },
    })
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    luaunit.assertEquals(win.texts[1], "hello")
    button(win, "Close").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
    luaunit.assertTrue(win.destroyed)
end

function TestDialog:testOnClickFalseStaysTruePops()
    local n = 0
    local win = Dialog.mount(self.parent, {
        actions = {
            {
                label = "Go",
                onClick = function()
                    n = n + 1
                    return n >= 2
                end,
            },
        },
    })
    button(win, "Go").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    button(win, "Go").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestDialog:testMountedActionDisabledUpdatesAfterMount()
    local clicked = 0
    local rename = {
        label = "Rename",
        onClick = function()
            clicked = clicked + 1
            return true
        end,
    }
    local win = Dialog.mount(self.parent, {
        actions = {
            { label = "Cancel" },
            rename,
        },
    })
    Dialog.setActionDisabled(rename, true)
    luaunit.assertTrue(rename.disabled)
    luaunit.assertTrue(button(win, "Rename").opts.disabled)
    button(win, "Rename").action()
    luaunit.assertEquals(clicked, 0)
    luaunit.assertEquals(Dialog.depth(self.parent), 1)

    Dialog.setActionDisabled(rename, false)
    luaunit.assertFalse(rename.disabled)
    luaunit.assertFalse(button(win, "Rename").opts.disabled)
    button(win, "Rename").action()
    luaunit.assertEquals(clicked, 1)
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestDialog:testActionDisabledCanChangeAfterMount()
    local clicked = 0
    local action = {
        label = "Save",
        disabled = true,
        onClick = function()
            clicked = clicked + 1
            return true
        end,
    }
    local win = Dialog.mount(self.parent, {
        actions = { { label = "Cancel" }, action },
    })
    local save = button(win, "Save")
    save.action()
    luaunit.assertEquals(clicked, 0)
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    action.setDisabled(false)
    luaunit.assertEquals(save.disabled, false)
    save.action()
    luaunit.assertEquals(clicked, 1)
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestDialog:testDisabledActionDoesNotPop()
    local win = Dialog.mount(self.parent, {
        actions = {
            { label = "Close" },
            { label = "Save to file", disabled = true },
        },
    })
    button(win, "Save to file").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    button(win, "Close").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestDialog:testPrimaryActionIsRightmost()
    local win = Dialog.mount(self.parent, {
        actions = {
            { label = "Close" },
            { label = "Import", variant = "positive" },
        },
    })
    -- Bound right-to-left: first AddFancyButton is the last action (primary).
    luaunit.assertEquals(win.buttons[1].label, "Import")
    luaunit.assertEquals(win.buttons[2].label, "Close")
    luaunit.assertEquals(win.buttons[1].opts.xAnchor, 1)
    luaunit.assertTrue(win.buttons[1].opts.x > win.buttons[2].opts.x)
end

function TestDialog:testTitlebarXFiresOnDismissNotAction()
    local dismissed = 0
    local clicked = 0
    local win = Dialog.mount(self.parent, {
        onDismiss = function() dismissed = dismissed + 1 end,
        actions = {
            {
                label = "Close",
                onClick = function()
                    clicked = clicked + 1
                    return true
                end,
            },
        },
    })
    win:Close()
    luaunit.assertEquals(dismissed, 1)
    luaunit.assertEquals(clicked, 0)
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestDialog:testFooterCloseDoesNotFireOnDismiss()
    local dismissed = 0
    local win = Dialog.mount(self.parent, {
        onDismiss = function() dismissed = dismissed + 1 end,
        actions = { { label = "Close" } },
    })
    button(win, "Close").action()
    luaunit.assertEquals(dismissed, 0)
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestDialog:testStackPushPopAndDismissAll()
    local a = Dialog.mount(self.parent, { title = "A", actions = { { label = "Close" } } })
    local b = Dialog.mount(self.parent, { title = "B", actions = { { label = "Close" } } })
    luaunit.assertEquals(Dialog.depth(self.parent), 2)
    button(b, "Close").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    luaunit.assertTrue(b.destroyed)
    luaunit.assertFalse(a.destroyed)
    Dialog.dismissAll(self.parent)
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
    luaunit.assertTrue(a.destroyed)
end

function TestDialog:testStackIsPerParent()
    local other = { id = "other" }
    Dialog.mount(self.parent, { title = "A" })
    Dialog.mount(other, { title = "B" })
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    luaunit.assertEquals(Dialog.depth(other), 1)
    Dialog.dismissAll(other)
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    Dialog.dismissAll(self.parent)
end

TestConfirmWrapper = {}

function TestDialog:testFailedSaveMessageDoesNotCallItASizeProblem()
    local win = Dialog.failedSave(self.parent)
    luaunit.assertEquals(win.title, "Could not save")
    luaunit.assertEquals(win.texts, {
        "Watchdog could not save that change.",
        "The last saved copy is still there.",
    })
    luaunit.assertEquals(#win.buttons, 1)
    luaunit.assertEquals(win.buttons[1].label, "Close")
    local body = table.concat(win.texts, " ")
    luaunit.assertNil(body:find("size", 1, true))
    luaunit.assertNil(body:find("too big", 1, true))
end

function TestDialog:testTooBigMessageSaysItIsTooBig()
    local win = Dialog.tooBig(self.parent)
    luaunit.assertEquals(win.title, "Too big to save")
    luaunit.assertEquals(win.texts, {
        "That change is too big to save.",
        "The last saved copy is still there.",
    })
    luaunit.assertEquals(win.buttons[1].label, "Close")
end

function TestDialog:testUnreadAlertMessageNamesTheAlert()
    local win = Dialog.unreadAlerts(self.parent, { "Horn" })
    luaunit.assertEquals(win.title, "Could not load")
    luaunit.assertEquals(win.texts[1], "Could not load Horn.")
    luaunit.assertEquals(win.texts[2], "The saved copy is still there.")
end

function TestDialog:testUnreadableScopeMessageDoesNotCallItASizeProblem()
    local win = Dialog.scopeUnreadable(self.parent)
    luaunit.assertEquals(win.title, "Could not load")
    luaunit.assertEquals(win.texts, {
        "This scope could not be read.",
        "Nothing was written over the saved copy.",
    })
    local body = table.concat(win.texts, " ")
    luaunit.assertNil(body:find("too big", 1, true))
end

function TestConfirmWrapper:setUp()
    self._savedUi = _G.ui
    self._savedPretty = _G.prettyui
    installHost()
    self.parent = { id = "c" }
    Dialog.dismissAll(self.parent)
end

function TestConfirmWrapper:tearDown()
    Dialog.dismissAll(self.parent)
    _G.ui = self._savedUi
    _G.prettyui = self._savedPretty
end

function TestConfirmWrapper:testCancelAndConfirmCallbacks()
    local saw = {}
    local win = Confirm.mount(self.parent, {
        body = "Delete?",
        onConfirm = function()
            saw[#saw + 1] = "ok"
        end,
        onCancel = function()
            saw[#saw + 1] = "no"
        end,
    })
    luaunit.assertEquals(win.texts[1], "Delete?")
    button(win, "CANCEL").action()
    luaunit.assertEquals(saw, { "no" })
    luaunit.assertEquals(Dialog.depth(self.parent), 0)

    saw = {}
    win = Confirm.mount(self.parent, {
        onConfirm = function()
            saw[#saw + 1] = "ok"
        end,
        onCancel = function()
            saw[#saw + 1] = "no"
        end,
    })
    button(win, "CONFIRM").action()
    luaunit.assertEquals(saw, { "ok" })
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestConfirmWrapper:testXIsCancelViaOnDismiss()
    local saw = {}
    local win = Confirm.mount(self.parent, {
        onConfirm = function() saw[#saw + 1] = "ok" end,
        onCancel = function() saw[#saw + 1] = "no" end,
    })
    win:Close()
    luaunit.assertEquals(saw, { "no" })
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestConfirmWrapper:testFalseOnConfirmStays()
    local win = Confirm.mount(self.parent, {
        onConfirm = function() return false end,
    })
    button(win, "CONFIRM").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    luaunit.assertFalse(win.destroyed)
end
