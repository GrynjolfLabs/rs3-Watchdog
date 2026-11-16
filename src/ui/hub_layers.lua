-- Plugin Hub surfaces.
-- SettingsLayerReady fills a prettyui SimpleView: the manager key, the overlay
-- lock, what a restricted area changes, and whether chat and tracking
-- permission are granted. Rows stack in that flow, so removing one reflows
-- the rest. No per-alert settings.
-- ContentLayerReady registers Toggle, which opens the manager, Reset All
-- Popups, which clears one-shot notices, and Reset Positions, which puts the
-- infobox and toasts back at their defaults. While RestrictedAreas reports
-- Restricted, a line under the buttons reads "In Restricted Area" in red,
-- with a description under it. Otherwise the panel is only the buttons.

local Notices = require("src/notices")

local SETTINGS_EVENT = "watchdog.settings_layer"
local CONTENT_EVENT = "watchdog.content_layer"
local DEPENDENCY_EVENT = "watchdog.restricted_areas"
-- One Watchdog-owned name on RestrictedAreas. Named, so a later Subscribe replaces it.
local RESTRICTED_LISTENER = "watchdog.restricted"

-- ui.Text draws nothing until rgb and rgba are set. Same packing as the
-- Alert Manager header labels (0xRRGGBBAA).
local TEXT_RGBA = 220 * 0x1000000 + 222 * 0x10000 + 230 * 0x100 + 255
local RESTRICTED_LINE = "In Restricted Area"
local RESTRICTED_DETAIL =
"In a restricted area, Watchdog will not trigger Spawn, Game Message, or Location triggers."
-- Settings has no red title, so this block has to say what a restricted area is.
local SETTINGS_RESTRICTED_TITLE = "Restricted areas"
local SETTINGS_RESTRICTED_BODY =
"While you are in a restricted area, Watchdog will not trigger Spawn, Game Message, or Location triggers."
-- Red, packed 0xRRGGBBAA like TEXT_RGBA. Only the restricted title uses it.
local RESTRICTED_RGBA = 255 * 0x1000000 + 48 * 0x10000 + 48 * 0x100 + 255

local STATUS_H = 24
local INSET_X = 12
local BUTTON_H = 30
local RESTRICTED_DETAIL_H = STATUS_H * 4
local SHELL_KEY_DB = "watchdog_shell_key"
local LOCK_DB = "watchdog_position_lock"

local HubLayers = {}

local settingsRoot = nil
local settingsParent = nil
local keybindField = nil
local lockBox = nil
local shellKeys = nil
local positionsLocked = false
local prefsLoaded = false
local contentToggleButton = nil
local contentResetButton = nil
local contentPositionsButton = nil
local resetPositions = nil
local shellOpen = false
-- The click flips isToggled itself. Writing it again from that click lands on
-- the wrong side of the client's flip.
local toggleFromButton = false
local contentLine = nil
local contentDetail = nil
local contentParent = nil
-- fillContent's buttonY is gone by the time the restricted state changes.
local contentButtonY = INSET_X

local function copyKeys(keys)
    local out = {}
    if type(keys) ~= "table" then return out end
    for _, key in ipairs(keys) do
        if type(key) == "number" then
            out[#out + 1] = key
        end
    end
    return out
end

local function defaultShellKeys()
    if GameKey ~= nil and type(GameKey.F8) == "number" then
        return { GameKey.F8 }
    end
    return {}
end

local function readString(key)
    if PersistentDB == nil then return nil end
    local text
    local ok = pcall(function()
        text = PersistentDB:GetString(key)
    end)
    if ok and type(text) == "string" then return text end
    return nil
end

local function writeString(key, value)
    if PersistentDB == nil then return end
    pcall(function()
        PersistentDB:SetString(key, value)
    end)
end

-- Missing shell-key text means F8. A saved empty list means the shell key is off.
function HubLayers.LoadPrefs(force)
    if prefsLoaded and force ~= true then return end
    prefsLoaded = true
    shellKeys = defaultShellKeys()
    positionsLocked = false
    local text = readString(SHELL_KEY_DB)
    if text ~= nil and text ~= "" and LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        local ok, decoded = pcall(function()
            return LibNodeGraph.Json.Default.decode(text)
        end)
        if ok and type(decoded) == "table" then
            shellKeys = copyKeys(decoded)
        end
    end
    positionsLocked = readString(LOCK_DB) == "1"
end

function HubLayers.ShellKeys()
    HubLayers.LoadPrefs()
    return copyKeys(shellKeys)
end

function HubLayers.SetShellKeys(keys)
    HubLayers.LoadPrefs()
    shellKeys = copyKeys(keys)
    if LibNodeGraph == nil or LibNodeGraph.Json == nil then return end
    local ok, text = pcall(function()
        return LibNodeGraph.Json.Default.encode(shellKeys)
    end)
    if ok and type(text) == "string" then
        writeString(SHELL_KEY_DB, text)
    end
end

function HubLayers.PositionsLocked()
    HubLayers.LoadPrefs()
    return positionsLocked == true
end

function HubLayers.SetPositionsLocked(locked)
    HubLayers.LoadPrefs()
    positionsLocked = locked == true
    writeString(LOCK_DB, positionsLocked and "1" or "0")
end

---@param fn fun()|nil
function HubLayers.SetResetPositions(fn)
    resetPositions = fn
end

local function releaseSettingsWidgets()
    if keybindField ~= nil and keybindField.Destroy ~= nil then
        pcall(function() keybindField:Destroy() end)
    end
    keybindField = nil
    if lockBox ~= nil and lockBox.Destroy ~= nil then
        pcall(function() lockBox:Destroy() end)
    end
    lockBox = nil
end

local function granted(permission)
    return Plugin.HasPermission(permission) == true
end

local function permissionLine(name, permission)
    if granted(permission) then
        return name .. " permission: granted"
    end
    return name .. " permission: not granted"
end

local function destroyOwned(node)
    if node == nil then return end
    pcall(function() node:Destroy() end)
end

local function applyShellOpen()
    if contentToggleButton == nil then return end
    contentToggleButton.isToggled = shellOpen
end

---@param open boolean
function HubLayers.SetShellOpen(open)
    shellOpen = not not open
    if toggleFromButton then return end
    applyShellOpen()
end

local function addLine(parent, y, h, text, maxLines)
    local line = ui.Text.new(parent)
    line:SetPos(INSET_X, y)
    line:SetSize(-INSET_X * 2, h, 1)
    line.content = text
    line.font = id.Font.MUSEO_SANS_15PT_REGULAR
    line.maxLines = maxLines
    line.isShadowed = true
    line.clickthrough = true
    line.rgb = TEXT_RGBA
    line.rgba = TEXT_RGBA
    line.alignHorizontal = ui.AlignMode.TOPLEFT
    line.alignVertical = ui.AlignMode.CENTRE
    return line
end

-- The title and description exist only while Restricted. A second true leaves
-- both widgets in place so walking between Restricted areas does not flicker them.
---@param restricted boolean
local function paintRestricted(restricted)
    if contentParent == nil then return end
    if restricted then
        if contentLine ~= nil and contentDetail ~= nil then
            contentLine.content = RESTRICTED_LINE
            contentLine.rgb = RESTRICTED_RGBA
            contentLine.rgba = RESTRICTED_RGBA
            contentDetail.content = RESTRICTED_DETAIL
            return
        end
        if contentLine ~= nil then
            destroyOwned(contentLine)
            contentLine = nil
        end
        if contentDetail ~= nil then
            destroyOwned(contentDetail)
            contentDetail = nil
        end
        local titleY = contentButtonY
        contentLine = addLine(contentParent, titleY, STATUS_H, RESTRICTED_LINE, 1)
        contentLine.rgb = RESTRICTED_RGBA
        contentLine.rgba = RESTRICTED_RGBA
        -- Top-aligned so the paragraph starts under the title instead of centering in its box.
        contentDetail = addLine(contentParent, titleY + STATUS_H + 2, RESTRICTED_DETAIL_H, RESTRICTED_DETAIL, 4)
        contentDetail.alignVertical = ui.AlignMode.TOPLEFT
        return
    end
    if contentLine ~= nil then
        destroyOwned(contentLine)
        contentLine = nil
    end
    if contentDetail ~= nil then
        destroyOwned(contentDetail)
        contentDetail = nil
    end
end

local function unsubscribeRestricted()
    pcall(function()
        RestrictedAreas.Unsubscribe(RESTRICTED_LISTENER)
    end)
end

---@param restricted boolean
local function onRestrictedChanged(restricted)
    paintRestricted(restricted == true)
end

local function syncRestricted()
    paintRestricted(RestrictedAreas.IsRestricted() == true)
    RestrictedAreas.Subscribe(RESTRICTED_LISTENER, onRestrictedChanged)
end

---@param parent ui.ComponentCollection
local function fillSettings(parent)
    releaseSettingsWidgets()
    if settingsRoot ~= nil and settingsParent == parent then
        destroyOwned(settingsRoot)
    end
    settingsRoot = nil
    settingsParent = parent

    -- The client parent is a raw component. SimpleView is the prettyui flow
    -- host for that parent: each Add stacks under the last, and removing one
    -- reflows the rest. A y on an Add pins that row and it will not move.
    if prettyui == nil or prettyui.SimpleView == nil then return end
    local view = prettyui.SimpleView.new(parent, {
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        layout = {
            startY = 12,
            paddingLeft = INSET_X,
            paddingRight = INSET_X,
            rowGap = 8,
        },
    })
    settingsRoot = view

    view:AddText("Manager key")
    local defaultKeys = defaultShellKeys()
    local keyOptions = {
        value = HubLayers.ShellKeys(),
        onChange = function(_, value)
            HubLayers.SetShellKeys(value)
        end,
    }
    if #defaultKeys > 0 then
        keyOptions.defaultValue = defaultKeys
    end
    local ok, field = pcall(function()
        return view:AddKeybindField(keyOptions)
    end)
    if ok then keybindField = field end

    local lockOk, box = pcall(function()
        return view:AddCheckboxButton({
            { text = "Lock infobox and toasts", value = "lock", selected = HubLayers.PositionsLocked() },
        }, {
            onChange = function(_, _, _, selected)
                HubLayers.SetPositionsLocked(selected == true)
            end,
        })
    end)
    if lockOk then lockBox = box end

    view:AddTitle(SETTINGS_RESTRICTED_TITLE)
    view:AddText({
        text = SETTINGS_RESTRICTED_BODY,
        maxLines = 4,
        alignVertical = ui.AlignMode.TOPLEFT,
    })
    view:AddText(permissionLine("Chat", PluginPermissions.chatAccess))
    view:AddText(permissionLine("Tracking", PluginPermissions.trackingAccess))
end

---@param parent ui.ComponentCollection
---@param onToggle fun()
local function fillContent(parent, onToggle)
    if contentToggleButton ~= nil and contentParent == parent then
        destroyOwned(contentToggleButton)
    end
    if contentResetButton ~= nil and contentParent == parent then
        destroyOwned(contentResetButton)
    end
    if contentPositionsButton ~= nil and contentParent == parent then
        destroyOwned(contentPositionsButton)
    end
    if contentLine ~= nil and contentParent == parent then
        destroyOwned(contentLine)
    end
    if contentDetail ~= nil and contentParent == parent then
        destroyOwned(contentDetail)
    end
    contentToggleButton = nil
    contentResetButton = nil
    contentPositionsButton = nil
    contentLine = nil
    contentDetail = nil
    contentParent = parent


    local function onResetPopups()
        Notices.shared:ResetAllPopups()
    end
    local function onResetPositions()
        if resetPositions ~= nil then
            resetPositions()
        end
    end
    local buttonY = INSET_X
    local function addButton(label, onPress, x, y, width, widthAnchor, xAnchor)
        local button = ui.Button.new(parent)
        if xAnchor ~= nil then
            button:SetPos(x, y, xAnchor)
        else
            button:SetPos(x, y)
        end
        button:SetSize(width, BUTTON_H, widthAnchor)
        button.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        button.label = label
        button:Subscribe(ui.Hook.ONBUTTONPRESSED, onPress)
        return button
    end
    local function makeButton(label, onPress)
        local button = addButton(label, onPress, INSET_X, buttonY, -INSET_X * 2, 1)
        buttonY = buttonY + BUTTON_H + 4
        return button
    end
    local button = makeButton("Toggle", onToggle)
    button.canToggle = true
    contentToggleButton = button
    applyShellOpen()

    -- One row. Each button is half the panel, split by the same 4px row gap.
    local rowY = buttonY
    local halfGap = 2
    contentResetButton = addButton(
        "Reset All Popups", onResetPopups, INSET_X, rowY, -INSET_X - halfGap, 0.5)
    contentPositionsButton = addButton(
        "Reset Positions", onResetPositions, halfGap, rowY, -INSET_X - halfGap, 0.5, 0.5)
    buttonY = rowY + BUTTON_H + 4
    contentButtonY = buttonY

    -- IsRestricted() first: Subscribe does not replay the current answer.
    syncRestricted()
end

---@param onToggle fun()
function HubLayers.Bind(onToggle)
    Event.SettingsLayerReady.Subscribe(SETTINGS_EVENT, function(event)
        if event == nil or event.component == nil then return end
        fillSettings(event.component)
    end)
    Event.ContentLayerReady.Subscribe(CONTENT_EVENT, function(event)
        if event == nil or event.component == nil then return end
        fillContent(event.component, function()
            toggleFromButton = true
            onToggle()
            toggleFromButton = false
        end)
    end)
    -- Reload of an optional dependency swaps the global. Only the open panel
    -- follows it; a closed panel must not subscribe and keep that plugin ticking.
    Event.OptionalDependencyChanged.Subscribe(DEPENDENCY_EVENT, function(dep)
        if contentParent == nil then return end
        local kind = type(dep)
        if kind ~= "table" and kind ~= "userdata" then return end
        if dep.pluginIdentifier ~= "RestrictedAreas" then return end
        syncRestricted()
    end)
end

function HubLayers.Unbind()
    Event.SettingsLayerReady.Unsubscribe(SETTINGS_EVENT)
    Event.ContentLayerReady.Unsubscribe(CONTENT_EVENT)
    Event.OptionalDependencyChanged.Unsubscribe(DEPENDENCY_EVENT)
    -- Clear the parent before Unsubscribe so a callback cannot Destroy the
    -- line. PluginShutdown must not Destroy this page; the client does.
    -- Cancel key capture without Destroy. Destroying the settings page here crashes.
    if keybindField ~= nil and keybindField.CancelListening ~= nil then
        pcall(function() keybindField:CancelListening() end)
    end
    keybindField = nil
    lockBox = nil
    contentParent = nil
    unsubscribeRestricted()
    settingsRoot = nil
    settingsParent = nil
    contentToggleButton = nil
    contentResetButton = nil
    contentPositionsButton = nil
    resetPositions = nil
    contentLine = nil
    contentDetail = nil
    shellOpen = false
    toggleFromButton = false
end

-- Live re-exec only. PluginShutdown must not Destroy these; the client tears
-- the page down itself and crashes if they are already gone.
function HubLayers.Stop()
    releaseSettingsWidgets()
    destroyOwned(settingsRoot)
    destroyOwned(contentToggleButton)
    destroyOwned(contentResetButton)
    destroyOwned(contentPositionsButton)
    destroyOwned(contentLine)
    destroyOwned(contentDetail)
    HubLayers.Unbind()
end

return HubLayers
