-- The Variable dialog stacks on the same
-- parent as New alert so that dialog stays mounted and inert underneath.

local Dialog = require("src/ui/dialog")
local Confirm = require("src/ui/confirm")
local Theme = require("src/ui/theme")
local Presets = require("src/presets")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local PresetVariableDialog = require("src/ui/preset_variable_dialog")
local ChatPermission = require("src/nodes/chat_permission")
local ChatPermissionNotice = require("src/ui/chat_permission_notice")

local PresetNewAlertDialog = {}

---@param preset Watchdog.Preset|Watchdog.PackAlertPreset
---@return boolean
local function presetHasVariables(preset)
    return type(preset.variables) == "table" and #preset.variables > 0
end

-- Calls the Variable dialog for a preset that has variables. It does not
-- decide Sound Effect answers itself. onCreated is how main opens the Editor
-- after a create. This dialog does not show the Editor.
---@param parent any
---@param opts PresetDialogs.NewAlertOpts|nil
---@return nil
function PresetNewAlertDialog.mountNewAlert(parent, opts)
    if parent == nil or opts == nil then return nil end
    local feedback
    local body = {}
    local alertWin
    local fillList, beginRename, beginDelete

    -- Captured at this open. A later registration does not rebuild an open dialog.
    -- Rename and delete call fillList again and still use this list.
    local offered = {}
    local livePacks = Packs.live()
    if livePacks ~= nil then
        offered = PackRows.AlertPresetGroups(livePacks)
    end

    local function deliver(result, id, err, graph)
        if id == nil then return nil, err end
        if opts.onCreated ~= nil then opts.onCreated(result) end
        if ChatPermission.GraphRequires(graph) and not ChatPermission.Granted() then
            ChatPermissionNotice.mount(parent, "This alert includes a Game Message or Player Chat node.")
        end
        return id, err
    end

    -- PrettyUI flow padding (14) and column gap (8). The name fills the row.
    -- The pencil and trash sit inline after it, the same sprites as the Manager.
    local FLOW_PAD = 14
    local FLOW_GAP = 8

    local function forget(host, widget)
        local entries = host._managedFlowEntries
        if type(entries) == "table" then
            for i = #entries, 1, -1 do
                if entries[i].component == widget then
                    table.remove(entries, i)
                end
            end
        end
        pcall(function() widget:Destroy() end)
    end

    local function clearBody(host)
        for i = #body, 1, -1 do
            local widget = body[i]
            body[i] = nil
            forget(host, widget)
        end
        local layout = host._flowLayout
        if layout ~= nil then
            layout.nextY = layout.startY
            layout.row = nil
            layout.hasItems = false
            -- Flow only grows the scroll height. Drop it back so a shorter list,
            -- including the empty library, does not leave the footer below a hole.
            if host.SetContentHeight ~= nil then
                pcall(function() host:SetContentHeight(layout.startY) end)
            end
        end
        feedback = nil
    end

    local function remember(widget)
        if widget ~= nil then body[#body + 1] = widget end
        return widget
    end

    -- `actions` is the pencil and trash. Alert Preset rows have neither, so the name uses the row.
    ---@param host any
    ---@param actions integer
    ---@return integer
    local function rowWidth(host, actions)
        local contentW = host.contentWidth
        if type(contentW) ~= "number" then contentW = 352 end
        local width = contentW - FLOW_PAD * 2 - (Theme.MANAGER_ACT_W + FLOW_GAP) * actions
        if width < 80 then width = 80 end
        return width
    end

    ---@param captured Watchdog.Preset|Watchdog.PackAlertPreset
    ---@param create fun(answers: any[]|nil): integer|nil, string|nil
    local function openPreset(captured, create)
        if presetHasVariables(captured) then
            PresetVariableDialog.mountVariables(parent, {
                preset = captured,
                registry = opts.registry,
                onCreate = function(answers)
                    return create(answers)
                end,
            })
            return
        end
        local id, err = create(nil)
        if id == nil and err ~= "variables" and feedback ~= nil then
            feedback.content = err or "Could not create the alert."
        end
    end

    beginRename = function(preset)
        local field, renameFeedback
        local initial = preset.name or ""
        local renameAction = {
            label = "Rename",
            variant = "positive",
            disabled = Presets.trim(initial) == "",
            onClick = function()
                local name = ""
                pcall(function() name = field:GetText() or "" end)
                if Presets.trim(name) == "" then return false end
                local renamed, err = Presets.Rename(preset.id, name)
                if renamed == nil then
                    if renameFeedback ~= nil then
                        renameFeedback.content = err or "Could not rename the preset."
                    end
                    return false
                end
                if alertWin ~= nil then fillList(alertWin) end
                return true
            end,
        }
        Dialog.mount(parent, {
            title = "Rename preset",
            width = 380,
            height = 200,
            content = function(win)
                win:AddText("Preset name")
                field = win:AddTextField({
                    text = initial,
                    maxLength = 80,
                    height = 30,
                    onChange = function(f)
                        local text = ""
                        pcall(function() text = f:GetText() or "" end)
                        if renameAction.setDisabled ~= nil then
                            renameAction.setDisabled(Presets.trim(text) == "")
                        end
                    end,
                })
                renameFeedback = win:AddText("")
            end,
            actions = {
                { label = "Cancel" },
                renameAction,
            },
        })
    end

    beginDelete = function(preset)
        Confirm.mount(parent, {
            title = "CONFIRM DELETE",
            body = string.format('Delete "%s"? This cannot be undone.', preset.name or ""),
            confirmLabel = "DELETE",
            confirmVariant = "negative",
            onConfirm = function()
                local deleted, err = Presets.Delete(preset.id)
                if deleted ~= true then
                    if feedback ~= nil then
                        feedback.content = err or "Could not delete the preset."
                    end
                    return false
                end
                if alertWin ~= nil then fillList(alertWin) end
                return true
            end,
        })
    end

    fillList = function(host)
        clearBody(host)
        local listed, listErr = Presets.List()
        local hasGroups = #offered > 0
        if listed == nil then
            remember(host:AddText(listErr or "Presets could not be read."))
        elseif #listed == 0 and not hasGroups then
            remember(host:AddText("There are no presets."))
        else
            if listed ~= nil and #listed > 0 then
                local width = rowWidth(host, 2)
                local iconOffset = math.floor((Theme.MANAGER_ROW_H - Theme.MANAGER_ACT_W) / 2)
                for _, preset in ipairs(listed) do
                    local captured = preset
                    remember(host:AddSimpleButton(captured.name, function()
                        openPreset(captured, function(answers)
                            if opts.onFromPreset == nil then
                                return nil, "Could not create the alert."
                            end
                            local result, id, err = opts.onFromPreset(captured.id, answers)
                            return deliver(result, id, err, captured.graph)
                        end)
                    end, {
                        width = width,
                        height = Theme.MANAGER_ROW_H,
                    }))
                    remember(host:AddSpriteButton("PENCIL", function()
                        beginRename(captured)
                    end, {
                        inline = true,
                        size = Theme.MANAGER_ACT_W,
                        offsetY = iconOffset,
                        tooltip = "Rename",
                    }))
                    remember(host:AddSpriteButton("TRASH", function()
                        beginDelete(captured)
                    end, {
                        inline = true,
                        size = Theme.MANAGER_ACT_W,
                        offsetY = iconOffset,
                        tooltip = "Delete",
                    }))
                end
            end
            -- The registry already ordered these groups. Do not sort them again.
            if hasGroups then
                local width = rowWidth(host, 0)
                for _, group in ipairs(offered) do
                    remember(host:AddText(group.packName))
                    for _, preset in ipairs(group.presets) do
                        local captured = preset
                        remember(host:AddSimpleButton(captured.name, function()
                            openPreset(captured, function(answers)
                                if opts.onFromAlertPreset == nil then
                                    return nil, "Could not create the alert."
                                end
                                local result, id, err = opts.onFromAlertPreset(captured, answers)
                                return deliver(result, id, err, captured.graph)
                            end)
                        end, {
                            width = width,
                            height = Theme.MANAGER_ROW_H,
                        }))
                    end
                end
            end
        end
        feedback = remember(host:AddText(""))
    end

    Dialog.mount(parent, {
        title = "New alert",
        width = 400,
        height = 420,
        content = function(win)
            if win.SetScrollable ~= nil then win:SetScrollable(false) end
            if prettyui == nil or prettyui.SimpleView == nil or win.content == nil then
                if log ~= nil then log("Watchdog: prettyui.SimpleView unavailable, New alert list aborted") end
                return
            end
            -- Same chrome as the preset dialogs: title 32 + border 8, footer band 48.
            local width = 400 - 16
            local contentW = win.content.width
            if type(contentW) == "number" and contentW > 0 then width = contentW end
            local view
            local ok, err = pcall(function()
                view = prettyui.SimpleView.new(win.content, {
                    x = 0,
                    y = 0,
                    width = width,
                    height = 420 - 40 - 48,
                })
            end)
            if not ok or view == nil then
                if log ~= nil then log("Watchdog: New alert list failed - " .. tostring(err)) end
                return
            end
            alertWin = view
            fillList(view)
        end,
        actions = {
            { label = "Cancel" },
            {
                label = "From scratch",
                variant = "positive",
                onClick = function()
                    if opts.onFromScratch == nil then return false end
                    local result, id = opts.onFromScratch()
                    if id == nil then
                        if feedback ~= nil then
                            feedback.content = "Could not create the alert."
                        end
                        return false
                    end
                    if opts.onCreated ~= nil then opts.onCreated(result) end
                    return true
                end,
            },
        },
    })
    return nil
end

return PresetNewAlertDialog
