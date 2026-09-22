-- Import / Export dialog: Dialog wrapper with two recipes. Does not import — the caller
-- applies pasted text. Does not require export.lua (byte cap is passed in).

local Dialog = require("ui/dialog")
local Theme = require("ui/theme")

local ImportExport = {}

-- InputField hard cap (#83); Manager passes Export.MAX_BYTES. Kept here so the wrapper
-- does not require export.lua.
ImportExport.DEFAULT_MAX_LENGTH = 2500

---@class Watchdog.ImportExportOpts
---@field text string|nil
---@field message string|nil
---@field maxLength integer|nil
---@field onImport (fun(text: string): boolean, any)|nil  # ok, err — Import recipe only
---@field onDismiss (fun())|nil

---@param field any
---@param text string
local function freezeExportField(field, text)
    pcall(function()
        if field.SetDisabled ~= nil then field:SetDisabled(false) end
        field.onChange = function(f)
            if f:GetText() ~= text then f:SetText(text) end
        end
        if field.root ~= nil and ui ~= nil and ui.Hook ~= nil then
            field.root:Subscribe(ui.Hook.ONCLICK, function()
                if field.root.SelectAll ~= nil then field.root:SelectAll() end
                return true
            end)
        end
    end)
end

---@param win any
---@param message string|nil
---@param fieldOpts table
---@return any|nil
local function addBody(win, message, fieldOpts)
    if message ~= nil and message ~= "" then
        pcall(function() win:AddText(message) end)
    end
    local field
    pcall(function()
        field = win:AddTextField(fieldOpts)
        if field ~= nil and field.root ~= nil and field.root.text ~= nil then
            field.root.text.maxLines = 100
        end
    end)
    return field
end

---@param parent any
---@param title string
---@param err any
local function stackError(parent, title, err)
    Dialog.mount(parent, {
        title = title,
        content = function(win)
            win:AddText(tostring(err or "Failed."))
        end,
        actions = { { label = "Close" } },
    })
end

---@param parent any
---@param opts Watchdog.ImportExportOpts|nil
---@return any|nil
function ImportExport.mountImport(parent, opts)
    opts = opts or {}
    local field
    local maxLength = opts.maxLength or ImportExport.DEFAULT_MAX_LENGTH
    return Dialog.mount(parent, {
        title = "Import alerts",
        width = Theme.MANAGER_IMPORT_EXPORT_W,
        height = Theme.MANAGER_IMPORT_EXPORT_H,
        onDismiss = opts.onDismiss,
        content = function(win)
            field = addBody(win, opts.message, {
                text = opts.text or "",
                placeholder = "Paste alert code here",
                maxLength = maxLength,
                height = 280,
            })
        end,
        actions = {
            { label = "Cancel" },
            {
                label = "Import",
                variant = "positive",
                onClick = function()
                    local text = opts.text or ""
                    pcall(function()
                        if field ~= nil and field.GetText ~= nil then
                            text = field:GetText() or text
                        end
                    end)
                    if opts.onImport == nil then return true end
                    local okCall, ok, err = pcall(opts.onImport, text)
                    if not okCall then
                        stackError(parent, "Could not import alerts", ok)
                        return false
                    end
                    if ok then return true end
                    stackError(parent, "Could not import alerts", err)
                    return false
                end,
            },
        },
    })
end

---@param parent any
---@param opts Watchdog.ImportExportOpts|nil
---@return any|nil
function ImportExport.mountExport(parent, opts)
    opts = opts or {}
    local frozen = opts.text or ""
    local maxLength = opts.maxLength or ImportExport.DEFAULT_MAX_LENGTH
    return Dialog.mount(parent, {
        title = "Export",
        width = Theme.MANAGER_IMPORT_EXPORT_W,
        height = Theme.MANAGER_IMPORT_EXPORT_H,
        onDismiss = opts.onDismiss,
        content = function(win)
            local field = addBody(win, opts.message, {
                text = frozen,
                maxLength = maxLength,
                height = 280,
                disabled = true,
            })
            if field ~= nil then freezeExportField(field, frozen) end
        end,
        actions = {
            { label = "Close" },
            {
                label = "Save to file",
                disabled = true,
                tooltip = "File export needs a client filesystem API",
            },
        },
    })
end

return ImportExport
