-- Variable dialog for a Sound Effect mark: the sound id field plus the pack list.

_G.id = _G.id or {}
_G.id.Sound = _G.id.Sound or { TOWN_CRIER_BELL_RING_1 = 2608 }

local luaunit = require("luaunit")

local Serialize = require("serialize")
local Json = require("json")
LibNodeGraph = {
    NewGraph = require("graph").new,
    Serialize = Serialize.Serialize,
    Deserialize = Serialize.Deserialize,
    Json = Json,
    UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
}

local Packs = require("src/packs")
local Presets = require("src/presets")
local PresetLabels = require("src/ui/preset_labels")
local Dialog = require("src/ui/dialog")
local PresetDialogs = require("src/ui/preset_dialogs")
local ChatPermission = require("src/nodes/chat_permission")
local Registry = require("registry")
require("src/nodes/actions/sound")

local function labelsOf(entries)
    local labels = {}
    for i, entry in ipairs(entries) do
        labels[i] = entry.label
    end
    return labels
end

local function click(buttons, label)
    for _, button in ipairs(buttons) do
        if button.label == label then
            button.action()
            return
        end
    end
    error("missing button " .. label)
end

TestPresetVariableSound = {}

function TestPresetVariableSound:setUp()
    self.saved = { ui = _G.ui, prettyui = _G.prettyui, Vector4 = _G.Vector4 }
    self.packs = Packs.new()
    Packs.install(self.packs)
    self.parent = { height = 800 }
    self.texts = {}
    self.fields = {}
    self.combos = {}
    self.checks = {}
    self.buttons = {}
    local texts, fields, combos, checks, buttons = self.texts, self.fields, self.combos, self.checks, self.buttons
    local body = {}
    function body:AddText(text)
        local widget = { content = text }
        texts[#texts + 1] = widget
        return widget
    end
    function body:AddTextField(opts)
        local field = { text = opts.text, opts = opts }
        function field:GetText()
            return self.text
        end
        function field:SetText(value, notify)
            self.text = tostring(value or "")
            if notify == true and opts.onChange ~= nil then
                opts.onChange(self)
            end
        end
        fields[#fields + 1] = field
        return field
    end
    function body:AddComboBox(opts)
        local combo = { opts = opts, selectedID = opts.selectedID }
        function combo:Select(entryID, notify)
            self.selectedID = entryID
            if notify == true and opts.onChange ~= nil then
                local label = nil
                for _, entry in ipairs(opts.entries) do
                    if entry.id == entryID then label = entry.label end
                end
                opts.onChange(self, entryID, label)
            end
        end
        combos[#combos + 1] = combo
        return combo
    end
    function body:AddCheckboxButton(choices, opts)
        local box = { choices = choices, opts = opts }
        checks[#checks + 1] = box
        return box
    end
    local function component()
        return {
            SetPos = function() end,
            SetSize = function() end,
            MoveToFront = function() end,
            Destroy = function() end,
        }
    end
    _G.Vector4 = { new = function() return {} end }
    _G.ui = {
        Layer = { new = component },
        Rectangle = { new = component },
        Hook = {},
    }
    _G.prettyui = {
        FancyButton = { getSize = function() return 80, 27 end },
        Window = {
            new = function(_, options)
                local win = {
                    title = options.title,
                    content = {},
                    onClose = options.onClose,
                }
                function win:SetScrollable() end
                function win:Show() end
                function win:MoveToFront() end
                function win:AddFancyButton(label, action, opts)
                    local button = { label = label, action = action, opts = opts or {} }
                    function button:SetDisabled(disabled)
                        self.disabled = disabled == true
                    end
                    buttons[#buttons + 1] = button
                    return button
                end
                function win:Destroy() end
                return win
            end,
        },
        SimpleView = { new = function() return body end },
    }
    self.registry = Registry.new()
    require("src/nodes/actions/sound").Register(self.registry)
    self.registry:RegisterNodeType("fixture.hold", {
        category = "action",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.flag", {
        category = "action",
        displayName = "Flag",
        pins = {
            { name = "sticky", label = "Sticky", kind = "data", direction = "in", dataType = "bool", default = true },
        },
        run = function() end,
    })
end

function TestPresetVariableSound:tearDown()
    Dialog.dismissAll(self.parent)
    Packs.install(nil)
    _G.ui = self.saved.ui
    _G.prettyui = self.saved.prettyui
    _G.Vector4 = self.saved.Vector4
end

---@param soundId any
---@return Watchdog.Preset
function TestPresetVariableSound:preset(soundId)
    local graph = LibNodeGraph.NewGraph(self.registry)
    local soundNode = graph:AddNode("action.sound", { soundId = soundId })
    local holdNode = graph:AddNode("fixture.hold", { hold = 4 })
    return {
        name = "Callout",
        graph = LibNodeGraph.Serialize(graph),
        variables = {
            { nodeId = soundNode, pinName = "soundId" },
            { nodeId = holdNode, pinName = "hold" },
        },
    }
end

function TestPresetVariableSound:mount(preset, onCreate)
    PresetDialogs.mountVariables(self.parent, {
        preset = preset,
        registry = self.registry,
        onCreate = onCreate or function() return 1 end,
    })
end

---@param stored boolean|nil
---@return Watchdog.Preset
---@return string
function TestPresetVariableSound:flagPreset(stored)
    local graph = LibNodeGraph.NewGraph(self.registry)
    local controls = {}
    if stored ~= nil then controls.sticky = stored end
    local nodeId = graph:AddNode("fixture.flag", controls)
    if stored == nil then
        graph:SetControl(nodeId, "sticky", nil)
    end
    return {
        name = "Flag",
        graph = LibNodeGraph.Serialize(graph),
        variables = { { nodeId = nodeId, pinName = "sticky" } },
    }, PresetLabels.MarkLabel(graph, nodeId, "sticky")
end

function TestPresetVariableSound:testACheckedBoolPinMountsACheckedBox()
    local preset, label = self:flagPreset(true)
    local answers
    self:mount(preset, function(got)
        answers = got
        return 1
    end)
    luaunit.assertEquals(#self.checks, 1)
    luaunit.assertEquals(#self.combos, 0)
    luaunit.assertEquals(#self.fields, 0)
    luaunit.assertEquals(self.checks[1].choices[1].text, label)
    luaunit.assertEquals(self.checks[1].choices[1].selected, true)
    click(self.buttons, "Create")
    luaunit.assertEquals(answers[1], true)
end

function TestPresetVariableSound:testClearingTheBoxSubmitsFalse()
    local answers
    self:mount(self:flagPreset(true), function(got)
        answers = got
        return 1
    end)
    self.checks[1].opts.onChange(self.checks[1], {}, "on", false)
    click(self.buttons, "Create")
    luaunit.assertEquals(answers[1], false)
end

function TestPresetVariableSound:testAClearBoolPinMountsAnEmptyBox()
    self:mount(self:flagPreset(false))
    luaunit.assertEquals(self.checks[1].choices[1].selected, false)
end

function TestPresetVariableSound:testAMissingBoolUsesThePinDefault()
    self:mount(self:flagPreset(nil))
    luaunit.assertEquals(self.checks[1].choices[1].selected, true)
end

function TestPresetVariableSound:testSoundIdOffersEveryPackSoundAndAPlainNumberDoesNot()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "horn", label = "Horn", soundId = 222 },
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    self:mount(self:preset(50))
    luaunit.assertEquals(#self.fields, 2)
    luaunit.assertEquals(self.fields[1].text, "50")
    luaunit.assertEquals(self.fields[2].text, "4")
    luaunit.assertEquals(#self.combos, 1)
    luaunit.assertEquals(labelsOf(self.combos[1].opts.entries), {
        "None",
        "Voice / Bell",
        "Voice / Horn",
    })
    luaunit.assertEquals(self.combos[1].selectedID, 1)
end

function TestPresetVariableSound:testChoosingAPackSoundFillsTheSoundIdAndCreatesThatRecord()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
            { authorId = "horn", label = "Horn", soundId = 222 },
        },
    })
    local answers
    self:mount(self:preset(50), function(got)
        answers = got
        return 1
    end)
    self.combos[1].opts.onChange(self.combos[1], 3, "Voice / Horn")
    luaunit.assertEquals(self.fields[1].text, "222")
    click(self.buttons, "Create")
    luaunit.assertEquals(answers[1], { pack = "Voice", authorId = "horn", soundId = 222 })
    luaunit.assertEquals(answers[2], { raw = "4", quantity = nil })
end

function TestPresetVariableSound:testAnUntouchedPackSoundEffectShowsItsBuiltinSoundId()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    local answers
    self:mount(self:preset(record), function(got)
        answers = got
        return 1
    end)
    luaunit.assertEquals(self.fields[1].text, "12345")
    luaunit.assertEquals(self.combos[1].selectedID, 2)
    click(self.buttons, "Create")
    luaunit.assertEquals(answers[2], { raw = "4", quantity = nil })
end

function TestPresetVariableSound:testChoosingNoneLeavesTheTypedSoundId()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    self:mount(self:preset(record))
    self.combos[1].opts.onChange(self.combos[1], 1, "None")
    luaunit.assertEquals(self.fields[1].text, "12345")
end

function TestPresetVariableSound:testTypingADifferentIdClearsThePackSelection()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    self:mount(self:preset(record))
    self.fields[1].text = "99"
    self.fields[1].opts.onChange(self.fields[1])
    luaunit.assertEquals(self.combos[1].selectedID, 1)
end

function TestPresetVariableSound:testNoPackSoundsLeavesTheMessageInsteadOfADropdown()
    self:mount(self:preset(50))
    local sawMessage = false
    for _, text in ipairs(self.texts) do
        if text.content == "Another plugin can register sounds" then sawMessage = true end
    end
    luaunit.assertTrue(sawMessage)
    luaunit.assertEquals(#self.combos, 0)
    luaunit.assertEquals(#self.fields, 2)
end

local function newFakePersistentDB()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value) self.data[key] = value end
    return db
end

local function live(widgets)
    local out = {}
    for _, widget in ipairs(widgets) do
        if not widget.destroyed then out[#out + 1] = widget end
    end
    return out
end

local function labels(widgets)
    local out = {}
    for i, widget in ipairs(widgets) do
        out[i] = widget.label or widget.content
    end
    return out
end

TestNewAlertDialog = {}

function TestNewAlertDialog:setUp()
    self.saved = {
        ui = _G.ui,
        prettyui = _G.prettyui,
        Vector4 = _G.Vector4,
        PersistentDB = _G.PersistentDB,
        Plugin = _G.Plugin,
        PluginPermissions = _G.PluginPermissions,
    }
    self.packs = Packs.new()
    Packs.install(self.packs)
    PersistentDB = newFakePersistentDB()
    self.parent = { height = 800 }
    self.windows = {}
    self.rows = {}
    self.sprites = {}
    self.rowTexts = {}
    local windows, rows, sprites, rowTexts = self.windows, self.rows, self.sprites, self.rowTexts
    local body = {}
    function body:AddText(text)
        local widget = { content = text }
        function widget:Destroy() self.destroyed = true end
        rowTexts[#rowTexts + 1] = widget
        return widget
    end
    function body:AddTextField(opts)
        local field = { text = opts and opts.text or "" }
        function field:GetText() return self.text end
        function field:SetText(value) self.text = tostring(value or "") end
        function field:Destroy() self.destroyed = true end
        return field
    end
    function body:AddComboBox()
        return { Destroy = function() end }
    end
    function body:AddSimpleButton(label, action, opts)
        local widget = { label = label, action = action, opts = opts }
        function widget:Destroy() self.destroyed = true end
        rows[#rows + 1] = widget
        return widget
    end
    function body:AddSpriteButton(sprite, action, opts)
        local widget = { sprite = sprite, action = action, opts = opts }
        function widget:Destroy() self.destroyed = true end
        sprites[#sprites + 1] = widget
        return widget
    end
    local function component()
        return {
            SetPos = function() end,
            SetSize = function() end,
            MoveToFront = function() end,
            Destroy = function() end,
        }
    end
    _G.Vector4 = { new = function() return {} end }
    _G.ui = {
        Layer = { new = component },
        Rectangle = { new = component },
        Hook = {},
    }
    _G.prettyui = {
        FancyButton = { getSize = function() return 80, 27 end },
        Window = {
            new = function(_, options)
                local win = {
                    title = options.title,
                    content = {},
                    onClose = options.onClose,
                    buttons = {},
                    fields = {},
                    texts = {},
                }
                function win:SetScrollable() end
                function win:Show() end
                function win:MoveToFront() end
                function win:AddText(text)
                    self.texts[#self.texts + 1] = text
                    local widget = { content = text }
                    function widget:Destroy() self.destroyed = true end
                    return widget
                end
                function win:AddTextField(opts)
                    local field = { text = opts and opts.text or "" }
                    function field:GetText() return self.text end
                    function field:SetText(value) self.text = tostring(value or "") end
                    self.fields[#self.fields + 1] = field
                    return field
                end
                function win:AddFancyButton(label, action, opts)
                    local button = { label = label, action = action, opts = opts or {} }
                    function button:SetDisabled(disabled) self.disabled = disabled == true end
                    self.buttons[#self.buttons + 1] = button
                    return button
                end
                function win:Destroy() self.destroyed = true end
                windows[#windows + 1] = win
                return win
            end,
        },
        SimpleView = { new = function() return body end },
    }
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.hold", {
        category = "action",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
end

function TestNewAlertDialog:tearDown()
    Dialog.dismissAll(self.parent)
    Packs.install(nil)
    _G.ui = self.saved.ui
    _G.prettyui = self.saved.prettyui
    _G.Vector4 = self.saved.Vector4
    _G.PersistentDB = self.saved.PersistentDB
    _G.Plugin = self.saved.Plugin
    _G.PluginPermissions = self.saved.PluginPermissions
    ChatPermission.Refresh()
end

local function setChatPermission(granted)
    _G.PluginPermissions = { chatAccess = "chatAccess" }
    _G.Plugin = {
        HasPermission = function(permission)
            return granted == true and permission == "chatAccess"
        end,
    }
    ChatPermission.Refresh()
end

function TestNewAlertDialog:button(win, label)
    for _, button in ipairs(win.buttons) do
        if button.label == label then return button end
    end
    error("missing button " .. label)
end

function TestNewAlertDialog:row(label)
    for _, row in ipairs(live(self.rows)) do
        if row.label == label then return row end
    end
    error("missing row " .. label)
end

function TestNewAlertDialog:testFromScratchReportsOpen()
    local opened
    PresetDialogs.mountNewAlert(self.parent, {
        onFromScratch = function()
            return { kind = "open", scopeKey = "global", alertId = 4 }, 4
        end,
        onCreated = function(result) opened = result end,
    })
    self:button(self.windows[1], "From scratch").action()
    luaunit.assertEquals(opened.kind, "open")
    luaunit.assertEquals(opened.scopeKey, "global")
    luaunit.assertEquals(opened.alertId, 4)
end

function TestNewAlertDialog:testEmptyLibrarySaysThereAreNoPresets()
    PresetDialogs.mountNewAlert(self.parent, {})
    luaunit.assertEquals(labels(live(self.rowTexts)), { "There are no presets.", "" })
end

function TestNewAlertDialog:testPackRowsStayInAlertPresetGroupOrderAndIgnoreALaterRegistration()
    self.packs:RegisterDataPack("Mango", {
        alertPresets = {
            { authorId = "z", name = "Zulu", graph = {} },
            { authorId = "b", name = "Bravo", graph = {} },
        },
    })
    self.packs:RegisterDataPack("Alpha", {
        alertPresets = {
            { authorId = "a", name = "Able", graph = {} },
        },
    })
    PresetDialogs.mountNewAlert(self.parent, {})
    luaunit.assertEquals(labels(live(self.rows)), { "Able", "Bravo", "Zulu" })
    luaunit.assertEquals(labels(live(self.rowTexts)), { "Alpha", "Mango", "" })

    self.packs:RegisterDataPack("Later", {
        alertPresets = {
            { authorId = "n", name = "Newcomer", graph = {} },
        },
    })
    luaunit.assertEquals(labels(live(self.rows)), { "Able", "Bravo", "Zulu" })
    luaunit.assertNil(self:findText("Later"))
    luaunit.assertNil(self:findText("Newcomer"))
end

function TestNewAlertDialog:findText(content)
    for _, widget in ipairs(live(self.rowTexts)) do
        if widget.content == content then return widget end
    end
    return nil
end

function TestNewAlertDialog:testVariablePresetDoesNotCreateUntilAnswersExist()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.hold", { hold = 4 })
    local preset, err = Presets.Add("Callout", graph, {}, {
        { nodeId = nodeId, pinName = "hold" },
    })
    luaunit.assertNotNil(preset, err)
    local calls = 0
    PresetDialogs.mountNewAlert(self.parent, {
        registry = self.registry,
        onFromPreset = function()
            calls = calls + 1
            return { kind = "open", scopeKey = "global", alertId = 1 }, 1, nil
        end,
    })
    self:row("Callout").action()
    luaunit.assertEquals(calls, 0)
    luaunit.assertEquals(self.windows[2].title, "Callout")
end

function TestNewAlertDialog:testPresetWithAGameMessageNodeWarnsWhenChatPermissionIsOff()
    setChatPermission(false)
    self.registry:RegisterNodeType("trigger.game_message", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function() end,
    })
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("trigger.game_message")
    local preset, err = Presets.Add("Drops", graph, {})
    luaunit.assertNotNil(preset, err)
    local created = 0
    PresetDialogs.mountNewAlert(self.parent, {
        registry = self.registry,
        onFromPreset = function()
            created = created + 1
            return { kind = "open", scopeKey = "global", alertId = 9 }, 9, nil
        end,
    })
    self:row("Drops").action()
    luaunit.assertEquals(created, 1)
    local notice = self.windows[#self.windows]
    luaunit.assertEquals(notice.title, "Chat permission")
    luaunit.assertEquals(notice.texts[1], "This alert includes a Game Message or Player Chat node.")
    luaunit.assertEquals(notice.texts[2], "Only those nodes wait on chat permission.")
    luaunit.assertEquals(notice.texts[3], "They do nothing until you grant it, and granting it later is enough.")
    local understand = self:button(notice, "I understand")
    luaunit.assertEquals(understand.opts.variant, "positive")
    understand.action()
    luaunit.assertEquals(notice.destroyed, true)
end

function TestNewAlertDialog:testPresetWithoutAChatNodeDoesNotWarn()
    setChatPermission(false)
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.hold", { hold = 1 })
    local preset, err = Presets.Add("Quiet", graph, {})
    luaunit.assertNotNil(preset, err)
    PresetDialogs.mountNewAlert(self.parent, {
        onFromPreset = function()
            return { kind = "open", scopeKey = "global", alertId = 3 }, 3, nil
        end,
    })
    self:row("Quiet").action()
    luaunit.assertEquals(#self.windows, 1)
end

function TestNewAlertDialog:testGrantedChatPermissionSkipsThePresetNotice()
    setChatPermission(true)
    self.registry:RegisterNodeType("trigger.player_chat", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function() end,
    })
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("trigger.player_chat")
    local preset, err = Presets.Add("Talk", graph, {})
    luaunit.assertNotNil(preset, err)
    PresetDialogs.mountNewAlert(self.parent, {
        onFromPreset = function()
            return { kind = "open", scopeKey = "global", alertId = 3 }, 3, nil
        end,
    })
    self:row("Talk").action()
    luaunit.assertEquals(#self.windows, 1)
end

function TestNewAlertDialog:testFailedPresetCreateDoesNotWarn()
    setChatPermission(false)
    self.registry:RegisterNodeType("action.game_message", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() end,
    })
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("action.game_message")
    local preset, err = Presets.Add("Say", graph, {})
    luaunit.assertNotNil(preset, err)
    PresetDialogs.mountNewAlert(self.parent, {
        onFromPreset = function()
            return { kind = "leave" }, nil, "Could not create the alert."
        end,
    })
    self:row("Say").action()
    luaunit.assertEquals(#self.windows, 1)
end

function TestNewAlertDialog:testAlertPresetWithAChatNodeWarnsWhenChatPermissionIsOff()
    setChatPermission(false)
    self.packs:RegisterDataPack("Starter", {
        alertPresets = {
            {
                authorId = "drops",
                name = "Drop call",
                graph = {
                    version = 1,
                    nodes = { { id = 1, type = "trigger.game_message", controls = {} } },
                    connections = {},
                },
            },
        },
    })
    local created = 0
    PresetDialogs.mountNewAlert(self.parent, {
        onFromAlertPreset = function()
            created = created + 1
            return { kind = "open", scopeKey = "global", alertId = 4 }, 4, nil
        end,
    })
    self:row("Drop call").action()
    luaunit.assertEquals(created, 1)
    luaunit.assertEquals(self.windows[#self.windows].title, "Chat permission")
    luaunit.assertEquals(self.windows[#self.windows].texts[1], "This alert includes a Game Message or Player Chat node.")
end

function TestNewAlertDialog:testVariablePresetWarnsOnlyAfterTheAlertIsCreated()
    setChatPermission(false)
    self.registry:RegisterNodeType("trigger.game_message", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function() end,
    })
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("trigger.game_message")
    local nodeId = graph:AddNode("fixture.hold", { hold = 4 })
    local preset, err = Presets.Add("Marked", graph, {}, {
        { nodeId = nodeId, pinName = "hold" },
    })
    luaunit.assertNotNil(preset, err)
    local created = 0
    PresetDialogs.mountNewAlert(self.parent, {
        registry = self.registry,
        onFromPreset = function()
            created = created + 1
            return { kind = "open", scopeKey = "global", alertId = 8 }, 8, nil
        end,
    })
    self:row("Marked").action()
    luaunit.assertEquals(created, 0)
    luaunit.assertEquals(self.windows[2].title, "Marked")
    self:button(self.windows[2], "Create").action()
    luaunit.assertEquals(created, 1)
    luaunit.assertEquals(self.windows[#self.windows].title, "Chat permission")
end

function TestNewAlertDialog:testRenameAndDeleteRefreshTheLibraryRow()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.hold", { hold = 1 })
    local preset, err = Presets.Add("Siren", graph, {})
    luaunit.assertNotNil(preset, err)
    PresetDialogs.mountNewAlert(self.parent, {})

    live(self.sprites)[1].action()
    local rename = self.windows[2]
    luaunit.assertEquals(rename.title, "Rename preset")
    rename.fields[1].text = "Horn"
    self:button(rename, "Rename").action()
    luaunit.assertEquals(labels(live(self.rows)), { "Horn" })

    local trash
    for _, sprite in ipairs(live(self.sprites)) do
        if sprite.sprite == "TRASH" then trash = sprite end
    end
    trash.action()
    local confirm = self.windows[3]
    luaunit.assertEquals(confirm.title, "CONFIRM DELETE")
    self:button(confirm, "DELETE").action()
    luaunit.assertEquals(labels(live(self.rows)), {})
    luaunit.assertEquals(self:findText("There are no presets.").content, "There are no presets.")
end

-- Save as preset, through the same front door the Editor calls.
TestSavePresetDialog = {}

function TestSavePresetDialog:setUp()
    self.saved = {
        ui = _G.ui,
        prettyui = _G.prettyui,
        Vector4 = _G.Vector4,
    }
    self.packs = Packs.new()
    Packs.install(self.packs)
    self.parent = { height = 800, width = 1200 }
    self.windows = {}
    self.texts = {}
    self.rows = {}
    self.fields = {}
    self.sprites = {}
    self.views = {}
    local windows, texts, rows, fields, sprites, views = self.windows, self.texts, self.rows, self.fields, self.sprites, self.views

    local function component(parent)
        local c = {
            parent = parent,
            children = {},
            x = 0,
            y = 0,
            width = 0,
            height = 0,
        }
        if parent ~= nil then
            parent.children = parent.children or {}
            parent.children[#parent.children + 1] = c
        end
        function c:SetPos(x, y)
            self.x, self.y = x or 0, y or 0
        end
        function c:SetSize(w, h)
            self.width, self.height = w or 0, h or 0
        end
        function c:MoveToFront() end
        function c:Destroy()
            if self.destroyed then return end
            self.destroyed = true
            local kids = self.children
            self.children = {}
            for _, child in ipairs(kids) do
                if child.Destroy ~= nil then child:Destroy() end
            end
        end
        return c
    end

    local function rememberRoot(widget, root)
        local inner = root.Destroy
        function root:Destroy()
            widget.destroyed = true
            inner(self)
        end
        function widget:Destroy()
            self.destroyed = true
            root:Destroy()
        end
    end

    _G.Vector4 = { new = function() return {} end }
    _G.ui = {
        Layer = { new = component },
        Panel = { new = component },
        Rectangle = { new = component },
        Text = {
            new = function(parent)
                local text = component(parent)
                texts[#texts + 1] = text
                return text
            end,
        },
        Hook = {},
        AlignMode = { CENTRE = 1, TOPLEFT = 0 },
    }
    _G.prettyui = {
        FancyButton = { getSize = function() return 80, 27 end },
        Window = {
            new = function(_, options)
                options = options or {}
                local root = component(nil)
                root.x = options.x or 0
                root.y = options.y or 0
                root.xAnchor = options.xAnchor or 0
                root.yAnchor = options.yAnchor or 0
                root.width = options.width or 0
                root.height = options.height or 0
                local content = component(root)
                content.width = (options.width or 460) - 16
                content.height = (options.height or 220) - 40
                local win = {
                    title = options.title,
                    content = content,
                    root = root,
                    titleDrag = component(nil),
                    onClose = options.onClose,
                    buttons = {},
                    parent = self.parent,
                    minWidth = options.minWidth,
                    maxWidth = options.maxWidth,
                    minHeight = options.minHeight,
                    maxHeight = options.maxHeight,
                }
                function win:SetTitle(title)
                    self.title = title or ""
                end
                function win:SetScrollable() end
                function win:Show() end
                function win:MoveToFront() end
                -- A center anchor slides the title bar when the height changes.
                function win:SetSize(w, h)
                    local oldH = self.root.height or h
                    self.root.width = w
                    self.root.height = h
                    local anchor = self.root.yAnchor or 0
                    if anchor ~= 0 then
                        local delta = h - oldH
                        self.root.y = (self.root.y or 0) - math.floor(delta * anchor)
                    end
                    self.titleDrag.x = self.root.x
                    self.titleDrag.y = self.root.y
                    -- Production Window:SetSize snapshots drag bounds after the
                    -- size change, which is the slid top, not the one we restore.
                    if self.dragBounds ~= nil and self.dragBounds.RememberPosition ~= nil then
                        self.dragBounds:RememberPosition()
                    end
                end
                function win:AddFancyButton(label, action)
                    local button = { label = label, action = action }
                    function button:SetDisabled(disabled) self.disabled = disabled == true end
                    self.buttons[#self.buttons + 1] = button
                    return button
                end
                function win:Destroy() self.destroyed = true end
                windows[#windows + 1] = win
                return win
            end,
        },
        TextField = {
            new = function(parent, opts)
                opts = opts or {}
                local root = component(parent)
                root:SetPos(opts.x or 0, opts.y or 0)
                root:SetSize(opts.width or 200, opts.height or 30)
                local field = {
                    parent = parent,
                    root = root,
                    text = opts.text or "",
                    opts = opts,
                    x = opts.x or 0,
                    y = opts.y or 0,
                }
                function field:GetText() return self.text end
                function field:SetText(value)
                    self.text = tostring(value or "")
                    if opts.onChange ~= nil then opts.onChange(self) end
                end
                rememberRoot(field, root)
                fields[#fields + 1] = field
                return field
            end,
        },
        SimpleButton = {
            new = function(parent, label, action, opts)
                opts = opts or {}
                local root = component(parent)
                root:SetPos(opts.x or 0, opts.y or 0)
                root:SetSize(opts.width or 80, opts.height or 32)
                local button = {
                    parent = parent,
                    root = root,
                    label = label,
                    action = action,
                    opts = opts,
                    x = opts.x or 0,
                    y = opts.y or 0,
                }
                rememberRoot(button, root)
                rows[#rows + 1] = button
                return button
            end,
        },
        SpriteButton = {
            new = function(parent, spriteName, action, opts)
                opts = opts or {}
                local root = component(parent)
                root:SetPos(opts.x or 0, opts.y or 0)
                root:SetSize(opts.size or 24, opts.size or 24)
                local button = {
                    parent = parent,
                    root = root,
                    sprite = spriteName,
                    action = action,
                    opts = opts,
                    x = opts.x or 0,
                    y = opts.y or 0,
                }
                rememberRoot(button, root)
                sprites[#sprites + 1] = button
                return button
            end,
        },
        SimpleView = {
            new = function(parent, opts)
                opts = opts or {}
                local root = component(parent)
                root:SetPos(opts.x or 0, opts.y or 0)
                root:SetSize(opts.width or 0, opts.height or 0)
                local content = component(root)
                content.scrollContent = true
                local view = {
                    parent = parent,
                    root = root,
                    content = content,
                    x = opts.x or 0,
                    y = opts.y or 0,
                    width = opts.width or 0,
                    height = opts.height or 0,
                    contentWidth = opts.width or 0,
                    _onScrollWheel = function() return false end,
                }
                function view:SetPos(x, y)
                    self.x, self.y = x or 0, y or 0
                    self.root:SetPos(self.x, self.y)
                end
                function view:SetSize(w, h)
                    self.width, self.height = w or 0, h or 0
                    self.root:SetSize(self.width, self.height)
                end
                function view:SetContentHeight(h)
                    self.contentHeight = h
                    if type(h) == "number" and h > self.height then
                        self.contentWidth = self.width - 18
                        self.scrollbarVisible = true
                    else
                        self.contentWidth = self.width
                        self.scrollbarVisible = false
                    end
                    self.content.width = self.contentWidth
                end
                function view:AddText(text)
                    local widget = component(self.content)
                    widget.content = text
                    texts[#texts + 1] = widget
                    return widget
                end
                function view:AddTextField(fieldOpts)
                    return prettyui.TextField.new(self.content, fieldOpts)
                end
                function view:AddSimpleButton(label, action)
                    return prettyui.SimpleButton.new(self.content, label, action, {})
                end
                rememberRoot(view, root)
                views[#views + 1] = view
                return view
            end,
        },
    }
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.hold", {
        category = "action",
        displayName = "Hold",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
end

function TestSavePresetDialog:tearDown()
    Dialog.dismissAll(self.parent)
    Packs.install(nil)
    _G.ui = self.saved.ui
    _G.prettyui = self.saved.prettyui
    _G.Vector4 = self.saved.Vector4
end

function TestSavePresetDialog:openWindow()
    local open
    for _, win in ipairs(self.windows) do
        if not win.destroyed then open = win end
    end
    if open == nil then error("no open dialog") end
    return open
end

function TestSavePresetDialog:button(win, label)
    for _, button in ipairs(win.buttons) do
        if button.label == label then return button end
    end
    error("missing button " .. label)
end

function TestSavePresetDialog:buried(widget)
    local current = widget
    while current ~= nil do
        if current.hidden == true then return true end
        if current.root ~= nil and current.root.hidden == true then return true end
        current = current.parent
    end
    return false
end

function TestSavePresetDialog:row(label)
    local found = self:findRow(label)
    if found == nil then error("missing row " .. label) end
    return found
end

function TestSavePresetDialog:findRow(label)
    for _, row in ipairs(self.rows) do
        if not row.destroyed and not self:buried(row) and row.label == label then return row end
    end
    return nil
end

function TestSavePresetDialog:sprite(name)
    for _, sprite in ipairs(self.sprites) do
        if not sprite.destroyed and not self:buried(sprite) and sprite.sprite == name then return sprite end
    end
    error("missing sprite " .. name)
end

function TestSavePresetDialog:findText(content)
    for _, widget in ipairs(self.texts) do
        if not widget.destroyed and not self:buried(widget) and widget.content == content then return widget end
    end
    return nil
end

function TestSavePresetDialog:insideScroll(widget)
    local current = widget
    while current ~= nil do
        if current.scrollContent then return true end
        current = current.parent
    end
    return false
end

function TestSavePresetDialog:topY(widget)
    local y = 0
    local current = widget
    while current ~= nil do
        y = y + (current.y or 0)
        current = current.parent
    end
    return y
end

function TestSavePresetDialog:liveButtonLabels()
    local labels = {}
    for _, row in ipairs(self.rows) do
        if not row.destroyed and not self:buried(row) and row.label ~= "Mark Variable" then
            labels[#labels + 1] = row.label
        end
    end
    return labels
end

function TestSavePresetDialog:markLabels()
    local labels = {}
    for _, text in ipairs(self.texts) do
        if not text.destroyed and not self:buried(text) and self:insideScroll(text)
            and type(text.content) == "string" and text.content:find(":", 1, true) then
            labels[#labels + 1] = text.content
        end
    end
    return labels
end

function TestSavePresetDialog:holdGraph()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.hold", { hold = 4 })
    return graph, nodeId
end

function TestSavePresetDialog:testABlankNameDoesNotCallSave()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local calls = 0
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "",
        onSave = function()
            calls = calls + 1
            return { id = 1 }
        end,
    })
    local win = self:openWindow()
    self:button(win, "Save").action()
    luaunit.assertEquals(calls, 0)
    luaunit.assertNil(win.destroyed)
    luaunit.assertEquals(win.title, "Save as preset")
end

function TestSavePresetDialog:testANameAndNoMarksSavesWithNoVariableList()
    local graph = self:holdGraph()
    local savedName, savedMarks
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function(name, marks)
            savedName, savedMarks = name, marks
            return { id = 1 }
        end,
    })
    self:button(self:openWindow(), "Save").action()
    luaunit.assertEquals(savedName, "Siren")
    luaunit.assertNil(savedMarks)
end

function TestSavePresetDialog:testANameAndOneMarkSavesThatMark()
    local graph, nodeId = self:holdGraph()
    local savedName, savedMarks
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function(name, marks)
            savedName, savedMarks = name, marks
            return { id = 1 }
        end,
    })
    self:row("Mark Variable").action()
    self:row("Hold - New Hold").action()
    self:row("hold").action()
    self:button(self:openWindow(), "Save").action()
    luaunit.assertEquals(savedName, "Siren")
    luaunit.assertEquals(savedMarks, { { nodeId = nodeId, pinName = "hold" } })
end

function TestSavePresetDialog:testARefusedSaveLeavesTheDialogOpenAndShowsTheReason()
    local graph = self:holdGraph()
    local calls = 0
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function()
            calls = calls + 1
            return nil, "Could not copy the graph."
        end,
    })
    local win = self:openWindow()
    self:button(win, "Save").action()
    luaunit.assertEquals(calls, 1)
    luaunit.assertNil(win.destroyed)
    luaunit.assertEquals(win.title, "Save as preset")
    luaunit.assertEquals(self:findText("Could not copy the graph.").content, "Could not copy the graph.")
end

function TestSavePresetDialog:testStepsKeepTheDraggedTitleBar()
    local graph = LibNodeGraph.NewGraph(self.registry)
    for i = 1, 12 do
        graph:AddNode("fixture.hold", { hold = i }, { name = "N" .. i })
    end
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function() return { id = 1 } end,
    })
    local win = self:openWindow()
    local openedAt = win.root.y
    win.root.y = 40
    win.dragBounds = {
        RememberPosition = function(bounds)
            bounds.lastY = win.root.y
        end,
    }
    win.dragBounds:RememberPosition()
    local shortH = win.root.height
    self:row("Mark Variable").action()
    luaunit.assertEquals(self:openWindow(), win)
    luaunit.assertEquals(#self.windows, 1)
    luaunit.assertNil(win.destroyed)
    luaunit.assertEquals(win.title, "Save as preset - Choose a node")
    luaunit.assertTrue(win.root.height > shortH)
    local tallH = win.root.height
    local nodeView = self.views[#self.views]
    local nodeButton = self:row("Hold - N1")
    luaunit.assertEquals(nodeView.x, 8)
    luaunit.assertTrue(nodeView.contentHeight > nodeView.height)
    luaunit.assertEquals(nodeView.height, 6 * 32)
    luaunit.assertEquals(nodeButton.opts.x, 0)
    luaunit.assertEquals(nodeButton.opts.width, nodeView.contentWidth)
    luaunit.assertEquals(nodeButton.opts._onScrollWheel, nodeView._onScrollWheel)
    luaunit.assertEquals(win.root.y, 40)
    luaunit.assertEquals(win.dragBounds.lastY, 40)
    luaunit.assertNil(self:findText("Choose a node"))
    luaunit.assertEquals(self:sprite("BACK").opts.tooltip, "Back")
    luaunit.assertEquals(self:sprite("BACK").opts.size, 24)
    self:button(win, "Cancel")
    self:button(win, "Save")

    self:row("Hold - N1").action()
    luaunit.assertEquals(win.title, "Save as preset - Choose a pin")
    luaunit.assertEquals(win.root.y, 40)
    luaunit.assertNil(self:findText("Choose a pin"))
    luaunit.assertEquals(#self.windows, 1)

    self:sprite("BACK").action()
    luaunit.assertEquals(win.title, "Save as preset - Choose a node")
    luaunit.assertEquals(win.root.y, 40)

    self:sprite("BACK").action()
    luaunit.assertEquals(win.title, "Save as preset")
    luaunit.assertTrue(win.root.height < tallH)
    luaunit.assertEquals(win.root.y, 40)
    luaunit.assertEquals(win.dragBounds.lastY, 40)
    luaunit.assertNotEquals(win.root.y, openedAt)
end

function TestSavePresetDialog:testRootPutsTheNameAndMarkButtonAboveAFixedHeader()
    self.parent.height = 320
    local graph = self:holdGraph()
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function() return { id = 1 } end,
    })
    local name = self:findText("Preset name")
    local field = self.fields[1]
    local mark = self:row("Mark Variable")
    luaunit.assertNotNil(name)
    luaunit.assertEquals(field.opts.maxLength, 80)
    luaunit.assertTrue(self:topY(field) > self:topY(name))
    luaunit.assertTrue(self:topY(mark) > self:topY(field))
    luaunit.assertNil(self:findText("Variable"))

    self:row("Mark Variable").action()
    self:row("Hold - New Hold").action()
    luaunit.assertEquals(self:openWindow().title, "Save as preset - Choose a pin")
    self:row("hold").action()

    local header = self:findText("Variable")
    local valueHeader = self:findText("Default value")
    local actions = self:findText("Actions")
    local markText = self:findText("Hold - New Hold: hold")
    local value = self:findText("4")
    luaunit.assertNotNil(header)
    luaunit.assertNotNil(valueHeader)
    luaunit.assertNotNil(actions)
    luaunit.assertNotNil(markText)
    luaunit.assertNotNil(value)
    luaunit.assertTrue(mark.root.hidden == true)
    -- Hiding Mark Variable drops its row. The header takes that place.
    luaunit.assertEquals(self:topY(header), self:topY(mark))
    luaunit.assertFalse(self:insideScroll(header))
    luaunit.assertFalse(self:insideScroll(valueHeader))
    luaunit.assertFalse(self:insideScroll(actions))
    luaunit.assertTrue(self:insideScroll(markText))
    luaunit.assertTrue(self:insideScroll(value))
    luaunit.assertEquals(header.parent.width, markText.parent.width)
    local view = self.views[#self.views]
    luaunit.assertEquals(view.x, 8)
    luaunit.assertEquals(header.parent.x, 8)
    luaunit.assertTrue(view.scrollbarVisible == true)
    luaunit.assertEquals(header.parent.width, view.contentWidth)
    luaunit.assertTrue(header.parent.width < view.width)

    local trash = self:sprite("TRASH")
    luaunit.assertEquals(trash.opts.tooltip, "Remove")
    luaunit.assertEquals(trash.opts.size, 28)
    luaunit.assertEquals(trash.opts._onScrollWheel, view._onScrollWheel)
    trash.action()
    luaunit.assertEquals(#self.windows, 1)
    luaunit.assertNil(self:findText("Hold - New Hold: hold"))
    luaunit.assertNil(self:findText("Variable"))
    luaunit.assertNil(self:openWindow().destroyed)
end

function TestSavePresetDialog:testNothingMarkableSkipsTheTable()
    local graph = LibNodeGraph.NewGraph(self.registry)
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function() return { id = 1 } end,
    })
    luaunit.assertEquals(self:findText("Nothing on this Alert can be marked.").content, "Nothing on this Alert can be marked.")
    luaunit.assertNil(self:findRow("Mark Variable"))
    luaunit.assertNil(self:findText("Variable"))
    luaunit.assertNil(self:findText("Default value"))
    luaunit.assertNil(self:findText("Actions"))
end

function TestSavePresetDialog:testMarkingTheLastPinHidesMarkVariable()
    local graph = self:holdGraph()
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function() return { id = 1 } end,
    })
    local mark = self:row("Mark Variable")
    mark.action()
    self:row("Hold - New Hold").action()
    self:row("hold").action()
    luaunit.assertTrue(mark.root.hidden == true)
    luaunit.assertNil(mark.destroyed)
    luaunit.assertNotNil(self:findText("Hold - New Hold: hold"))
end

function TestSavePresetDialog:testNameSurvivesChooseNode()
    local graph = self:holdGraph()
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "",
        onSave = function() return { id = 1 } end,
    })
    local field = self.fields[1]
    field:SetText("Kept")
    self:row("Mark Variable").action()
    self:sprite("BACK").action()
    luaunit.assertFalse(field.destroyed == true)
    luaunit.assertEquals(field:GetText(), "Kept")
    luaunit.assertEquals(self:openWindow().title, "Save as preset")
end

function TestSavePresetDialog:testAFailedSaveOnChooseNodeStaysOnThatStep()
    local graph = self:holdGraph()
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function()
            return nil, "Could not copy the graph."
        end,
    })
    self:row("Mark Variable").action()
    local win = self:openWindow()
    self:button(win, "Save").action()
    luaunit.assertEquals(win.title, "Save as preset - Choose a node")
    luaunit.assertNil(win.destroyed)
    luaunit.assertEquals(self:findText("Could not copy the graph.").content, "Could not copy the graph.")
    luaunit.assertEquals(#self.windows, 1)
end

function TestSavePresetDialog:testRowsAndNodeChoicesUseNaturalOrder()
    self.registry:RegisterNodeType("fixture.pair", {
        category = "action",
        displayName = "Hold",
        pins = {
            { name = "beta", kind = "data", direction = "in", dataType = "number", default = 1 },
            { name = "alpha", kind = "data", direction = "in", dataType = "number", default = 2 },
        },
        run = function() end,
    })
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.hold", { hold = 1 }, { name = "Node 10" })
    graph:AddNode("fixture.hold", { hold = 2 }, { name = "Node 2" })
    graph:AddNode("fixture.hold", { hold = 3 }, { name = "alpha" })
    graph:AddNode("fixture.hold", { hold = 4 }, { name = "Alpha" })
    graph:AddNode("fixture.pair", { beta = 1, alpha = 2 }, { name = "Same" })
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function() return { id = 1 } end,
    })
    self:row("Mark Variable").action()
    luaunit.assertEquals(self:liveButtonLabels(), {
        "Hold - alpha",
        "Hold - Alpha",
        "Hold - Node 2",
        "Hold - Node 10",
        "Hold - Same",
    })
    self:row("Hold - Same").action()
    luaunit.assertEquals(self:liveButtonLabels(), { "beta", "alpha" })
    self:row("beta").action()
    self:row("Mark Variable").action()
    self:row("Hold - Same").action()
    self:row("alpha").action()

    local function markNode(title, pin)
        self:row("Mark Variable").action()
        self:row(title).action()
        self:row(pin).action()
    end
    markNode("Hold - Node 10", "hold")
    markNode("Hold - Node 2", "hold")
    markNode("Hold - alpha", "hold")
    markNode("Hold - Alpha", "hold")

    luaunit.assertEquals(self:markLabels(), {
        "Hold - alpha: hold",
        "Hold - Alpha: hold",
        "Hold - Node 2: hold",
        "Hold - Node 10: hold",
        "Hold - Same: beta",
        "Hold - Same: alpha",
    })
end
