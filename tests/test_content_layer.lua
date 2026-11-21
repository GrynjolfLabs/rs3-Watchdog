-- Content panel text. Drives the panel fill and, later, the RestrictedAreas
-- callback. Asserts the words on the panel, and that the restricted line
-- starts under every button.

local luaunit = require("luaunit")
local HubLayers = require("src/ui/hub_layers")

TestContentLayer = {}

local function live(parent, kind)
    local out = {}
    for _, child in ipairs(parent.children) do
        if child.kind == kind and not child.destroyed then
            out[#out + 1] = child
        end
    end
    return out
end

function TestContentLayer:setUp()
    self.saved = {
        ui = _G.ui,
        id = _G.id,
        Event = _G.Event,
        RestrictedAreas = _G.RestrictedAreas,
        Plugin = _G.Plugin,
        PluginPermissions = _G.PluginPermissions,
        prettyui = _G.prettyui,
        GameKey = _G.GameKey,
        PersistentDB = _G.PersistentDB,
        LibNodeGraph = _G.LibNodeGraph,
    }
    self.toggled = 0
    self.parent = { children = {} }
    self.onContent = nil
    self.onSettings = nil
    self.onDependency = nil

    local test = self
    local function component(kind, parent)
        local node = { kind = kind, parent = parent, hooks = {}, destroyed = false, children = {} }
        function node:SetPos(x, y, xAnchor)
            self.x = x
            self.y = y
            self.xAnchor = xAnchor
        end
        function node:SetSize(w, h, widthAnchor)
            self.w = w
            self.h = h
            self.widthAnchor = widthAnchor
        end
        function node:Subscribe(hook, fn)
            self.hooks[hook] = fn
        end
        function node:Destroy()
            self.destroyed = true
        end
        parent.children = parent.children or {}
        parent.children[#parent.children + 1] = node
        return node
    end

    _G.ui = {
        Button = { new = function(parent) return component("button", parent) end },
        Text = { new = function(parent) return component("text", parent) end },
        Layer = { new = function(parent) return component("layer", parent) end },
        Hook = { ONBUTTONPRESSED = "ONBUTTONPRESSED" },
        AlignMode = { TOPLEFT = "TOPLEFT", CENTRE = "CENTRE" },
    }
    _G.id = {
        StyleSheet = { BUTTON_DEFAULT = 1 },
        Font = { MUSEO_SANS_15PT_REGULAR = 2 },
    }
    _G.Event = {
        SettingsLayerReady = {
            Subscribe = function(_, fn) test.onSettings = fn end,
            Unsubscribe = function() test.onSettings = nil end,
        },
        ContentLayerReady = {
            Subscribe = function(_, fn) test.onContent = fn end,
            Unsubscribe = function() test.onContent = nil end,
        },
        OptionalDependencyChanged = {
            Subscribe = function(_, fn) test.onDependency = fn end,
            Unsubscribe = function() test.onDependency = nil end,
        },
    }
    self:installAreas(false)

    HubLayers.Bind(function()
        test.toggled = test.toggled + 1
    end)
end

function TestContentLayer:tearDown()
    HubLayers.Unbind()
    _G.ui = self.saved.ui
    _G.id = self.saved.id
    _G.Event = self.saved.Event
    _G.RestrictedAreas = self.saved.RestrictedAreas
    _G.Plugin = self.saved.Plugin
    _G.PluginPermissions = self.saved.PluginPermissions
    _G.prettyui = self.saved.prettyui
    _G.GameKey = self.saved.GameKey
    _G.PersistentDB = self.saved.PersistentDB
    _G.LibNodeGraph = self.saved.LibNodeGraph
    HubLayers.LoadPrefs(true)
end

function TestContentLayer:installAreas(answer)
    local areas = {
        answer = answer,
        listeners = {},
        unsubscribed = {},
    }
    function areas.IsRestricted()
        return areas.answer
    end
    function areas.Subscribe(name, callback)
        areas.listeners[name] = callback
    end
    function areas.Unsubscribe(name)
        areas.listeners[name] = nil
        areas.unsubscribed[#areas.unsubscribed + 1] = name
    end
    _G.RestrictedAreas = areas
end

function TestContentLayer:showContent()
    self.onContent({ component = self.parent })
end

function TestContentLayer:button()
    local buttons = live(self.parent, "button")
    for _, button in ipairs(buttons) do
        if button.label == "Toggle" then return button end
    end
    error("Toggle button missing")
end

function TestContentLayer:texts()
    return live(self.parent, "text")
end

-- 0xRRGGBBAA red. Matches the restricted title in hub_layers.lua.
local RESTRICTED_RGBA = 255 * 0x1000000 + 48 * 0x10000 + 48 * 0x100 + 255
local TEXT_RGBA = 220 * 0x1000000 + 222 * 0x10000 + 230 * 0x100 + 255
local RESTRICTED_DETAIL = "In a restricted area, Watchdog will not trigger Spawn, Game Message, or Location triggers."

function TestContentLayer:assertRestrictedLine(line)
    luaunit.assertEquals(line.content, "In Restricted Area")
    luaunit.assertEquals(line.rgb, RESTRICTED_RGBA)
    luaunit.assertEquals(line.rgba, RESTRICTED_RGBA)
end

function TestContentLayer:assertRestrictedDetail(line)
    luaunit.assertEquals(line.content, RESTRICTED_DETAIL)
    luaunit.assertEquals(line.rgb, TEXT_RGBA)
    luaunit.assertEquals(line.rgba, TEXT_RGBA)
end

function TestContentLayer:assertRestrictedCopy(texts)
    luaunit.assertEquals(#texts, 2)
    self:assertRestrictedLine(texts[1])
    self:assertRestrictedDetail(texts[2])
    local floor = 0
    for _, button in ipairs(live(self.parent, "button")) do
        local bottom = button.y + button.h
        if bottom > floor then floor = bottom end
    end
    luaunit.assertTrue(texts[1].y >= floor)
    luaunit.assertTrue(texts[2].y >= texts[1].y + texts[1].h)
    luaunit.assertEquals(texts[2].maxLines, 4)
    luaunit.assertTrue(texts[2].h >= texts[1].h * texts[2].maxLines)
end

function TestContentLayer:testFillWhileRestrictedShowsRestrictedUnderToggle()
    self:installAreas(true)
    self:showContent()
    local buttons = live(self.parent, "button")
    luaunit.assertEquals(#buttons, 3)
    luaunit.assertEquals(buttons[2].label, "Reset All Popups")
    luaunit.assertEquals(buttons[3].label, "Reset Positions")
    local button = self:button()
    luaunit.assertEquals(button.label, "Toggle")
    button.hooks["ONBUTTONPRESSED"]()
    luaunit.assertEquals(self.toggled, 1)
    local texts = self:texts()
    self:assertRestrictedCopy(texts)
end

function TestContentLayer:testShellOpenPressesAndReleasesToggle()
    self:showContent()
    local button = self:button()
    luaunit.assertFalse(button.isToggled)
    HubLayers.SetShellOpen(true)
    luaunit.assertTrue(button.isToggled)
    HubLayers.SetShellOpen(false)
    luaunit.assertFalse(button.isToggled)
end

function TestContentLayer:testPanelShownWhileOpenStartsPressed()
    HubLayers.SetShellOpen(true)
    self:showContent()
    luaunit.assertTrue(self:button().isToggled)
end

function TestContentLayer:testButtonPressDoesNotWriteIsToggled()
    HubLayers.Unbind()
    local presses = 0
    HubLayers.Bind(function()
        presses = presses + 1
        HubLayers.SetShellOpen(true)
    end)
    self:showContent()
    local button = self:button()
    button.isToggled = false
    button.hooks["ONBUTTONPRESSED"]()
    luaunit.assertEquals(presses, 1)
    luaunit.assertFalse(button.isToggled)
    HubLayers.SetShellOpen(false)
    luaunit.assertFalse(button.isToggled)
end

function TestContentLayer:resetButton()
    for _, button in ipairs(live(self.parent, "button")) do
        if button.label == "Reset All Popups" then return button end
    end
    error("Reset All Popups button missing")
end

function TestContentLayer:testRefillReplacesTheResetButton()
    self:showContent()
    local first = self:resetButton()
    local firstPositions = self:positionsButton()
    self:showContent()
    luaunit.assertTrue(first.destroyed)
    luaunit.assertTrue(firstPositions.destroyed)
    luaunit.assertEquals(#live(self.parent, "button"), 3)
    luaunit.assertFalse(self:resetButton().destroyed)
    luaunit.assertFalse(self:positionsButton().destroyed)
end

function TestContentLayer:testStopDestroysTheResetButton()
    self:showContent()
    local reset = self:resetButton()
    local positions = self:positionsButton()
    HubLayers.Stop()
    luaunit.assertTrue(reset.destroyed)
    luaunit.assertTrue(positions.destroyed)
end

function TestContentLayer:positionsButton()
    for _, button in ipairs(live(self.parent, "button")) do
        if button.label == "Reset Positions" then return button end
    end
    error("Reset Positions button missing")
end

function TestContentLayer:testResetPositionsSitsBesidePopupsAndFires()
    local calls = 0
    HubLayers.SetResetPositions(function()
        calls = calls + 1
    end)
    self:showContent()
    local popups = self:resetButton()
    local positions = self:positionsButton()
    luaunit.assertEquals(positions.y, popups.y)
    luaunit.assertEquals(popups.x, 12)
    luaunit.assertNil(popups.xAnchor)
    luaunit.assertEquals(popups.widthAnchor, 0.5)
    luaunit.assertEquals(positions.x, 2)
    luaunit.assertEquals(positions.xAnchor, 0.5)
    luaunit.assertEquals(positions.widthAnchor, 0.5)
    luaunit.assertEquals(positions.w, popups.w)
    positions.hooks["ONBUTTONPRESSED"]()
    luaunit.assertEquals(calls, 1)
end

function TestContentLayer:testFillWhileNotRestrictedShowsNoRestrictedCopy()
    self:installAreas(false)
    self:showContent()
    luaunit.assertEquals(self:button().label, "Toggle")
    luaunit.assertEquals(self:texts(), {})
end

function TestContentLayer:callback()
    local callback = nil
    for _, cb in pairs(_G.RestrictedAreas.listeners) do
        callback = cb
    end
    luaunit.assertNotNil(callback)
    return callback
end

function TestContentLayer:testBecomingRestrictedShowsTheLine()
    self:installAreas(false)
    self:showContent()
    luaunit.assertEquals(self:texts(), {})
    self:callback()(true)
    local texts = self:texts()
    self:assertRestrictedCopy(texts)
    luaunit.assertEquals(self:button().label, "Toggle")
end

function TestContentLayer:testLeavingRestrictedRemovesTheLine()
    self:installAreas(true)
    self:showContent()
    self:assertRestrictedCopy(self:texts())
    self:callback()(false)
    luaunit.assertEquals(self:texts(), {})
    luaunit.assertEquals(self:button().label, "Toggle")
end

function TestContentLayer:listenerName()
    local name = nil
    for subscribed in pairs(_G.RestrictedAreas.listeners) do
        name = subscribed
    end
    luaunit.assertNotNil(name)
    return name
end

function TestContentLayer:testClosingThePanelUnsubscribesAndLeavesThePanel()
    self:installAreas(true)
    self:showContent()
    local name = self:listenerName()
    local button = self:button()
    local line = self:texts()[1]
    local detail = self:texts()[2]
    HubLayers.Unbind()
    luaunit.assertEquals(_G.RestrictedAreas.unsubscribed, { name })
    luaunit.assertNil(_G.RestrictedAreas.listeners[name])
    luaunit.assertFalse(button.destroyed)
    luaunit.assertFalse(line.destroyed)
    luaunit.assertFalse(detail.destroyed)
    luaunit.assertEquals(button.label, "Toggle")
    self:assertRestrictedLine(line)
    self:assertRestrictedDetail(detail)
end

function TestContentLayer:testRestrictedAreasComingBackShowsTheNewAnswer()
    self:installAreas(false)
    self:showContent()
    luaunit.assertEquals(self:texts(), {})
    self:installAreas(true)
    luaunit.assertNotNil(self.onDependency)
    self.onDependency({ pluginIdentifier = "RestrictedAreas", enabled = true })
    local texts = self:texts()
    self:assertRestrictedCopy(texts)
    local name = self:listenerName()
    _G.RestrictedAreas.listeners[name](false)
    luaunit.assertEquals(self:texts(), {})
    luaunit.assertEquals(self:button().label, "Toggle")
end

function TestContentLayer:testAnotherPluginChangingLeavesTheLine()
    self:installAreas(true)
    self:showContent()
    local name = self:listenerName()
    self.onDependency({ pluginIdentifier = "shortestpath", enabled = false })
    self:assertRestrictedCopy(self:texts())
    luaunit.assertEquals(_G.RestrictedAreas.unsubscribed, {})
    luaunit.assertNotNil(_G.RestrictedAreas.listeners[name])
end

function TestContentLayer:testEnabledFlagDoesNotClearWhileTheGlobalRemains()
    self:installAreas(true)
    self:showContent()
    self.onDependency({ pluginIdentifier = "RestrictedAreas", enabled = false })
    self:assertRestrictedCopy(self:texts())
    luaunit.assertEquals(_G.RestrictedAreas.unsubscribed, {})
    luaunit.assertNotNil(_G.RestrictedAreas.listeners[self:listenerName()])
end

function TestContentLayer:testDependencyChangeBeforeThePanelDoesNotSubscribe()
    self:installAreas(true)
    self.onDependency({ pluginIdentifier = "RestrictedAreas", enabled = true })
    luaunit.assertEquals(_G.RestrictedAreas.listeners, {})
    luaunit.assertEquals(#self.parent.children, 0)
end

function TestContentLayer:testSettingsLayerDoesNotShowRestricted()
    _G.PluginPermissions = { chatAccess = "chatAccess", trackingAccess = "trackingAccess" }
    _G.Plugin = {
        HasPermission = function()
            return true
        end,
    }
    _G.GameKey = { F8 = 66 }
    local test = self
    _G.prettyui = {
        SimpleView = {
            new = function(parent)
                local view = { Destroy = function() end }
                function view:AddText(value)
                    local text = type(value) == "table" and value.text or value
                    parent.children[#parent.children + 1] = {
                        kind = "text", content = text, destroyed = false, children = {},
                    }
                end
                function view:AddTitle(value)
                    self:AddText(value)
                end
                function view:AddKeybindField(options)
                    test.keybindOptions = options
                    return { Destroy = function() end, CancelListening = function() end }
                end
                function view:AddCheckboxButton(choices)
                    test.checkboxChoices = choices
                    return { Destroy = function() end }
                end
                return view
            end,
        },
    }
    HubLayers.LoadPrefs(true)
    self:installAreas(true)
    local settingsParent = { children = {} }
    self.onSettings({ component = settingsParent })
    local contents = {}
    local function walk(node)
        if node.kind == "text" and not node.destroyed then
            contents[#contents + 1] = node.content
        end
        for _, child in ipairs(node.children or {}) do
            walk(child)
        end
    end
    for _, child in ipairs(settingsParent.children) do
        walk(child)
    end
    luaunit.assertEquals(contents, {
        "Manager key",
        "Restricted areas",
        "While you are in a restricted area, Watchdog will not trigger Spawn, Game Message, or Location triggers.",
        "Chat permission: granted",
        "Tracking permission: granted",
    })
    luaunit.assertEquals(self.keybindOptions.value, { 66 })
    luaunit.assertEquals(self.keybindOptions.defaultValue, { 66 })
    luaunit.assertEquals(self.checkboxChoices[1].text, "Lock infobox and toasts")
    luaunit.assertFalse(self.checkboxChoices[1].selected)
end

function TestContentLayer:testEmptyShellKeyStaysEmpty()
    local store = {}
    _G.GameKey = { F8 = 66 }
    _G.PersistentDB = {
        GetString = function(_, key) return store[key] end,
        SetString = function(_, key, value)
            store[key] = value
            return true
        end,
    }
    _G.LibNodeGraph = { Json = require("json") }
    HubLayers.LoadPrefs(true)
    luaunit.assertEquals(HubLayers.ShellKeys(), { 66 })
    HubLayers.SetShellKeys({})
    HubLayers.LoadPrefs(true)
    luaunit.assertEquals(HubLayers.ShellKeys(), {})
    HubLayers.SetPositionsLocked(true)
    HubLayers.LoadPrefs(true)
    luaunit.assertTrue(HubLayers.PositionsLocked())
end

function TestContentLayer:testFailedShellKeyWriteLeavesThePreviousBytesAndOnlyLogs()
    local store = { watchdog_shell_key = "[66]" }
    local logged = {}
    local windows = 0
    local savedLog = log
    local savedPretty = prettyui
    log = function(message) logged[#logged + 1] = tostring(message) end
    prettyui = {
        Window = {
            new = function()
                windows = windows + 1
                return {}
            end,
        },
    }
    _G.GameKey = { F8 = 66 }
    _G.PersistentDB = {
        GetString = function(_, key) return store[key] end,
        SetString = function() return false end,
    }
    _G.LibNodeGraph = { Json = require("json") }

    HubLayers.LoadPrefs(true)
    HubLayers.SetShellKeys({})

    log = savedLog
    prettyui = savedPretty
    luaunit.assertEquals(store.watchdog_shell_key, "[66]")
    luaunit.assertEquals(windows, 0)
    luaunit.assertStrContains(table.concat(logged, "\n"), "watchdog_shell_key")
end

function TestContentLayer:testRestrictedAreasIsARequiredDependency()
    local source = debug.getinfo(1, "S").source
    local path = source:match("^@(.*)$") or ""
    local root = path:match("^(.*)tests[/\\]test_content_layer%.lua$") or ""
    local file = assert(io.open(root .. "plugin.json", "rb"))
    local text = file:read("*a")
    file:close()
    local optional = text:match('"optionalDependencies"%s*:%s*%b{}')
    local required = text:match('"requiredDependencies"%s*:%s*%b{}')
    luaunit.assertNotNil(optional)
    luaunit.assertNotNil(required)
    luaunit.assertNotNil(required:find('"RestrictedAreas": "RestrictedAreas"', 1, true))
    luaunit.assertNil(optional:find("RestrictedAreas", 1, true))
end

function TestContentLayer:testStayingRestrictedKeepsTheSameLine()
    self:installAreas(true)
    self:showContent()
    local line = self:texts()[1]
    local detail = self:texts()[2]
    self:callback()(true)
    local texts = self:texts()
    luaunit.assertEquals(#texts, 2)
    luaunit.assertTrue(rawequal(texts[1], line))
    luaunit.assertTrue(rawequal(texts[2], detail))
    luaunit.assertFalse(line.destroyed)
    luaunit.assertFalse(detail.destroyed)
    self:assertRestrictedLine(line)
    self:assertRestrictedDetail(detail)
end

return TestContentLayer
