-- Import / Export dialog: Dialog wrapper with two recipes. Does not import — the caller
-- applies pasted text. Does not require export.lua (byte cap is passed in).

local Dialog = require("src/ui/dialog")
local Theme = require("src/ui/theme")

local ImportExport = {}

-- The paste dialog writes this key. It is not a Bucket.
---@param kind string
---@param ok boolean
---@param detail string|nil
function ImportExport.noteTransfer(kind, ok, detail)
    pcall(function()
        if PersistentDB == nil then return end
        PersistentDB:SetString("transfer_last", string.format(
            "%s\tok=%s\t%s", kind, tostring(ok), tostring(detail):sub(1, 500)))
    end)
end

-- InputField hard cap (#83); Manager passes Export.MAX_BYTES. Kept here so the wrapper
-- does not require export.lua.
ImportExport.DEFAULT_MAX_LENGTH = 9999

---@class Watchdog.ImportExportOpts
---@field text string|nil
---@field message string|nil
---@field maxLength integer|nil
---@field entryCount integer|nil                         # export success: how many entries the note records
---@field onImport (fun(text: string): boolean, any)|nil  # ok, then err or report. Import recipe only.
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
local function showEveryLine(field)
    if field == nil then return end
    local roots = { field.root }
    if field.dock ~= nil then roots[#roots + 1] = field.dock.root end
    if field.overlay ~= nil then roots[#roots + 1] = field.overlay.root end
    for _, root in ipairs(roots) do
        if root ~= nil and root.text ~= nil then
            root.text.maxLines = -1
        end
    end
end

local function addBody(win, message, fieldOpts)
    if message ~= nil and message ~= "" then
        pcall(function() win:AddText(message) end)
    end
    local field
    pcall(function()
        field = win:AddTextField(fieldOpts)
        showEveryLine(field)
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
                placeholder = "Paste an export here",
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
                    local okCall, ok, report = pcall(opts.onImport, text)
                    if not okCall then
                        ImportExport.noteTransfer("import", false, tostring(ok))
                        stackError(parent, "Could not import alerts", ok)
                        return false
                    end
                    if ok then
                        local detail = (type(report) == "table" and report.message) or "ok"
                        ImportExport.noteTransfer("import", true, detail)
                        return true
                    end
                    ImportExport.noteTransfer("import", false, tostring(report))
                    stackError(parent, "Could not import alerts", report)
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
    if type(opts.entryCount) == "number" then
        ImportExport.noteTransfer("export", true, string.format(
            "%d bytes / %d entries", #frozen, opts.entryCount))
    end
    local maxLength = opts.maxLength or ImportExport.DEFAULT_MAX_LENGTH
    return Dialog.mount(parent, {
        title = "Export alerts",
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
