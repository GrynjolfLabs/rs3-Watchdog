-- ui/import_export.lua recipes, via the same fake prettyui host as test_dialog.

local luaunit = require("luaunit")

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }

-- Reuse Dialog's host by requiring test_dialog's globals: install a local copy.
local windows = {}

local function fakeLayer(parent)
    local layer = { parent = parent, clickthrough = false, destroyed = false, raiseCount = 0 }
    function layer:SetPos() end
    function layer:SetSize() end
    function layer:MoveToFront() self.raiseCount = self.raiseCount + 1 end
    function layer:Destroy() self.destroyed = true end
    return layer
end

local function fakeRect(parent)
    local r = { parent = parent, fill = false, clickthrough = false }
    function r:SetPos() end
    function r:SetSize() end
    return r
end

local function installHost()
    windows = {}
    _G.ui = {
        Layer = { new = fakeLayer },
        Rectangle = { new = fakeRect },
        Hook = { ONCLICK = "ONCLICK" },
    }
    _G.prettyui = {
        FancyButton = { getSize = function() return 80, 27 end },
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
                }
                function w:AddText(text) self.texts[#self.texts + 1] = text end
                function w:AddFancyButton(label, action, opts)
                    local btn = { label = label, action = action, opts = opts or {} }
                    self.buttons[#self.buttons + 1] = btn
                    return btn
                end
                function w:AddTextField(opts)
                    opts = opts or {}
                    local field = {
                        opts = opts,
                        text = opts.text or "",
                        root = { text = {}, Subscribe = function() end, SelectAll = function() end },
                    }
                    function field:GetText() return self.text end
                    function field:SetText(t) self.text = t end
                    function field:SetDisabled() end
                    self.fields[#self.fields + 1] = field
                    return field
                end
                function w:Show() self.shown = true end
                function w:MoveToFront() end
                function w:Close()
                    if self.onClose then self.onClose(self) end
                    if self.destroyOnClose then self:Destroy() end
                end
                function w:Destroy() self.destroyed = true end
                windows[#windows + 1] = w
                return w
            end,
        },
    }
end

local luaunit = require("luaunit")
local Dialog = require("src/ui/dialog")
local ImportExport = require("src/ui/import_export")
local Export = require("src/export")
local ChatPermission = require("src/nodes/chat_permission")

local function button(win, label)
    for _, btn in ipairs(win.buttons) do
        if btn.label == label then return btn end
    end
    return nil
end

TestImportExport = {}

local function setChatPermission(granted)
    _G.PluginPermissions = { chatAccess = "chatAccess" }
    _G.Plugin = {
        HasPermission = function(permission)
            return granted == true and permission == "chatAccess"
        end,
    }
    ChatPermission.Refresh()
end

function TestImportExport:setUp()
    self._savedUi = _G.ui
    self._savedPretty = _G.prettyui
    self._savedPlugin = _G.Plugin
    self._savedPermissions = _G.PluginPermissions
    installHost()
    self.parent = { id = "ie" }
    Dialog.dismissAll(self.parent)
end

function TestImportExport:tearDown()
    Dialog.dismissAll(self.parent)
    _G.ui = self._savedUi
    _G.prettyui = self._savedPretty
    _G.Plugin = self._savedPlugin
    _G.PluginPermissions = self._savedPermissions
    ChatPermission.Refresh()
    PersistentDB = nil
end

local function noteDb()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value) self.data[key] = value end
    PersistentDB = db
    return db
end

function TestImportExport:testImportSuccessPopsWithNoNotice()
    local got
    local win = ImportExport.mountImport(self.parent, {
        onImport = function(text)
            got = text
            return true
        end,
    })
    win.fields[1].text = '{"ok":true}'
    button(win, "Import").action()
    luaunit.assertEquals(got, '{"ok":true}')
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
    luaunit.assertEquals(#windows, 1)
end

function TestImportExport:testImportFailureStacksErrorAndKeepsPaste()
    local win = ImportExport.mountImport(self.parent, {
        text = "bad",
        onImport = function()
            return false, "not a Watchdog export envelope"
        end,
    })
    button(win, "Import").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 2)
    luaunit.assertFalse(win.destroyed)
    luaunit.assertEquals(win.fields[1]:GetText(), "bad")
    local err = windows[2]
    luaunit.assertEquals(err.title, "Could not import alerts")
    luaunit.assertEquals(err.texts[1], "not a Watchdog export envelope")
    button(err, "Close").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    luaunit.assertFalse(win.destroyed)
end

function TestImportExport:testSuccessfulImportOfAChatNodeWarnsWhenChatPermissionIsOff()
    setChatPermission(false)
    local win = ImportExport.mountImport(self.parent, {
        onImport = function()
            return true, { hasChatNode = true, message = "Imported 1 entry." }
        end,
    })
    button(win, "Import").action()
    luaunit.assertTrue(win.destroyed)
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    local notice = windows[2]
    luaunit.assertEquals(notice.title, "Chat permission")
    luaunit.assertEquals(notice.texts[1], "This import includes a Game Message or Player Chat node.")
    luaunit.assertEquals(notice.texts[2], "Only those nodes wait on chat permission.")
    luaunit.assertEquals(notice.texts[3], "They do nothing until you grant it, and granting it later is enough.")
    local understand = button(notice, "I understand")
    luaunit.assertEquals(understand.opts.variant, "positive")
    understand.action()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestImportExport:testChatPermissionNoticeClosesFromTheTitleBar()
    setChatPermission(false)
    local win = ImportExport.mountImport(self.parent, {
        onImport = function()
            return true, { hasChatNode = true }
        end,
    })
    button(win, "Import").action()
    local notice = windows[2]
    notice:Close()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end

function TestImportExport:testGrantedChatPermissionSkipsTheNotice()
    setChatPermission(true)
    local win = ImportExport.mountImport(self.parent, {
        onImport = function()
            return true, { hasChatNode = true, message = "Imported 1 entry." }
        end,
    })
    button(win, "Import").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
    luaunit.assertEquals(#windows, 1)
end

function TestImportExport:testImportWithoutAChatNodeSkipsTheNotice()
    setChatPermission(false)
    local win = ImportExport.mountImport(self.parent, {
        onImport = function()
            return true, { hasChatNode = false, message = "Imported 1 entry." }
        end,
    })
    button(win, "Import").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
    luaunit.assertEquals(#windows, 1)
end

function TestImportExport:testFailedImportDoesNotWarnAboutChatPermission()
    setChatPermission(false)
    local win = ImportExport.mountImport(self.parent, {
        onImport = function()
            return false, "not a Watchdog export envelope"
        end,
    })
    button(win, "Import").action()
    luaunit.assertEquals(windows[2].title, "Could not import alerts")
    luaunit.assertEquals(#windows, 2)
end

function TestImportExport:testPasteFieldMaxLengthMatchesExportCap()
    luaunit.assertEquals(ImportExport.DEFAULT_MAX_LENGTH, 9999)
    luaunit.assertEquals(ImportExport.DEFAULT_MAX_LENGTH, Export.MAX_BYTES)
    local win = ImportExport.mountImport(self.parent, {})
    luaunit.assertEquals(win.fields[1].opts.maxLength, 9999)
end

function TestImportExport:testSuccessfulPasteRecordsTheTransfer()
    local db = noteDb()
    local win = ImportExport.mountImport(self.parent, {
        onImport = function()
            return true, { message = "Imported 1 alert." }
        end,
    })
    button(win, "Import").action()
    luaunit.assertEquals(db:GetString("transfer_last"), "import\tok=true\tImported 1 alert.")
end

function TestImportExport:testFailedPasteRecordsTheTransfer()
    local db = noteDb()
    local win = ImportExport.mountImport(self.parent, {
        onImport = function()
            return false, "not a Watchdog export envelope"
        end,
    })
    button(win, "Import").action()
    luaunit.assertEquals(db:GetString("transfer_last"), "import\tok=false\tnot a Watchdog export envelope")
end

function TestImportExport:testExportRecordsBytesAndEntryCount()
    local db = noteDb()
    ImportExport.mountExport(self.parent, {
        text = "abcd",
        entryCount = 2,
    })
    luaunit.assertEquals(db:GetString("transfer_last"), "export\tok=true\t4 bytes / 2 entries")
end

function TestImportExport:testExportHasFrozenFieldAndDisabledSave()
    local win = ImportExport.mountExport(self.parent, {
        text = '{"schemaVersion":1}',
        message = "copy me",
    })
    luaunit.assertEquals(win.title, "Export alerts")
    luaunit.assertEquals(win.texts[1], "copy me")
    luaunit.assertEquals(win.fields[1].text, '{"schemaVersion":1}')
    local save = button(win, "Save to file")
    luaunit.assertTrue(save.opts.disabled)
    save.action()
    luaunit.assertEquals(Dialog.depth(self.parent), 1)
    button(win, "Close").action()
    luaunit.assertEquals(Dialog.depth(self.parent), 0)
end
