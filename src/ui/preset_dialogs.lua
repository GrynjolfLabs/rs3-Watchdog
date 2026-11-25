-- Save as preset, the Variable dialog, and New alert. All three use Dialog; this file does not add a dialog harness.
-- Save as preset is parented to the Editor overlay. The Variable dialog stacks on the same
-- parent as New alert so that dialog stays mounted and inert underneath.

local PresetSaveDialog = require("src/ui/preset_save_dialog")
local PresetVariableDialog = require("src/ui/preset_variable_dialog")
local PresetNewAlertDialog = require("src/ui/preset_new_alert_dialog")

local PresetDialogs = {}

---@class PresetDialogs.SaveOpts
---@field graph LibNodeGraph.Graph
---@field initialName string|nil
---@field onSave fun(name: string, marks: Watchdog.PresetVariable[]|nil): Watchdog.Preset|nil, string|nil

---@param parent any
---@param opts PresetDialogs.SaveOpts
function PresetDialogs.mountSave(parent, opts)
    PresetSaveDialog.mountSave(parent, opts)
end

---@class PresetDialogs.VariableOpts
---@field preset Watchdog.Preset
---@field registry LibNodeGraph.Registry
---@field onCreate fun(answers: any[]): integer|nil, string|nil

---@param parent any
---@param opts PresetDialogs.VariableOpts
function PresetDialogs.mountVariables(parent, opts)
    PresetVariableDialog.mountVariables(parent, opts)
end

---@class PresetDialogs.NewAlertOpts
---@field registry LibNodeGraph.Registry|nil
---@field onFromScratch fun(): Watchdog.EditorResult, integer|nil
---@field onFromPreset fun(presetId: integer, answers: any[]|nil): Watchdog.EditorResult, integer|nil, string|nil
---@field onFromAlertPreset fun(snapshot: Watchdog.PackAlertPreset, answers: any[]|nil): Watchdog.EditorResult, integer|nil, string|nil
---@field onCreated fun(result: Watchdog.EditorResult)|nil

-- Calls the Variable dialog for a preset that has variables. It does not
-- decide Sound Effect answers itself. onCreated receives the create result.
-- This dialog does not show the Editor.
---@param parent any
---@param opts PresetDialogs.NewAlertOpts|nil
---@return nil
function PresetDialogs.mountNewAlert(parent, opts)
    PresetNewAlertDialog.mountNewAlert(parent, opts)
end

return PresetDialogs
