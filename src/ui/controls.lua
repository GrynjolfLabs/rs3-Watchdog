local ScalarControl  = require("src/ui/controls/scalar")
local EnumControl    = require("src/ui/controls/enum")
local SwatchControl  = require("src/ui/controls/swatch")
local CaptureControl = require("src/ui/controls/capture")
local ModeControl    = require("src/ui/controls/mode")
local NumberField    = require("src/ui/widgets/number_field")
local TextField      = require("src/ui/widgets/text_field")
local ControlKinds   = require("src/ui/control_kinds")

local Controls = {}

local pinControls = {}
local nodePinControls = {}

---@param tag string
---@param module table
---@return table
function Controls.RegisterPinControl(tag, module)
    assert(type(tag) == "string" and tag ~= "", "pin control tag must be a non-empty string")
    assert(type(module) == "table", "pin control must be a module table")
    pinControls[tag] = module
    return module
end

--- One node pin, not every pin of that data type. A Sound Effect stays a number
--- wire and still gets its own control.
---@param typeKey string
---@param pinName string
---@param module table
---@return table
function Controls.RegisterNodePinControl(typeKey, pinName, module)
    assert(type(typeKey) == "string" and typeKey ~= "", "node type key must be a non-empty string")
    assert(type(pinName) == "string" and pinName ~= "", "pin name must be a non-empty string")
    assert(type(module) == "table", "pin control must be a module table")
    nodePinControls[typeKey .. "\0" .. pinName] = module
    return module
end

---@param tag string|nil
---@return table|nil
function Controls.PinControlFor(tag)
    if tag == nil then return nil end
    return pinControls[tag]
end

--- The node-pin control when one was registered, otherwise the Type Tag control.
---@param typeKey string|nil
---@param pin { name: string, dataType: string|nil }|nil
---@return table|nil
function Controls.PinControlForPin(typeKey, pin)
    if type(pin) ~= "table" then return nil end
    if type(typeKey) == "string" and type(pin.name) == "string" then
        local specific = nodePinControls[typeKey .. "\0" .. pin.name]
        if specific ~= nil then return specific end
    end
    return Controls.PinControlFor(pin.dataType)
end

---@class ControlDescriptor
---@field widget string  -- "number"|"text"|"enum"|"swatch"|"capture"|"mode"
---@field choices table[]|nil  -- enum: { { value, label }, ... }
---@field captureKind string|nil  -- capture: "screen"|"object"
---@field placeholder string|nil  -- capture: empty-state prompt
---@field format (fun(value: any): string)|nil  -- capture: value -> summary text
---@field modes table[]|nil  -- mode: { { key, label, enabled, reason? }, ... }

---@param tag string
---@param descriptor ControlDescriptor
---@return ControlDescriptor
function Controls.Register(tag, descriptor)
    assert(type(tag) == "string" and tag ~= "", "control tag must be a non-empty string")
    assert(type(descriptor) == "table" and descriptor.widget ~= nil, "control descriptor needs a widget")
    if descriptor.widget == "number" then
        Controls.RegisterPinControl(tag, ScalarControl.new({ codec = NumberField, filter = "NUMERIC" }))
    elseif descriptor.widget == "text" then
        Controls.RegisterPinControl(tag, ScalarControl.new({ codec = TextField, filter = "NONE" }))
    elseif descriptor.widget == "enum" then
        Controls.RegisterPinControl(tag, EnumControl.new(descriptor.choices or {}))
    elseif descriptor.widget == "swatch" then
        Controls.RegisterPinControl(tag, SwatchControl.new())
    elseif descriptor.widget == "capture" then
        Controls.RegisterPinControl(tag, CaptureControl.new({
            captureKind = descriptor.captureKind, placeholder = descriptor.placeholder,
            format = descriptor.format,
        }))
    elseif descriptor.widget == "mode" then
        Controls.RegisterPinControl(tag, ModeControl.new(descriptor.modes or {}))
    end
    -- Kind is recorded for every Register call, including node files, so a later enum tag
    -- is markable without editing the preset library.
    ControlKinds.Record(tag, descriptor.widget, descriptor.choices)
    return descriptor
end

Controls.Register("number", { widget = "number" })
Controls.Register("string", { widget = "text" })
local compareOperation = require("src/ui/controls/compare_operation")
Controls.RegisterPinControl("compareOperation", compareOperation)
ControlKinds.Record("compareOperation", "enum", compareOperation.choices)
local mathOperation = require("src/ui/controls/math_operation")
Controls.RegisterPinControl("mathOperation", mathOperation)
ControlKinds.Record("mathOperation", "enum", mathOperation.choices)
local BoolControl = require("src/ui/controls/bool")
Controls.RegisterPinControl("bool", BoolControl)
ControlKinds.Record("bool", "checkbox")

Controls.RegisterPinControl("coordgrid", require("src/ui/controls/coordgrid"))
ControlKinds.Record("coordgrid", "coordgrid")
Controls.RegisterPinControl("matcher", require("src/ui/controls/matcher"))
ControlKinds.Record("matcher", "matcher")

Controls.Register("color", { widget = "swatch" })

Controls.Register("toastIcon", {
    widget = "enum",
    choices = {
        { value = nil,   label = "None" },
        { value = 17127, label = "Tick / checkmark" },
        { value = 21747, label = "Green checkmark" },
        { value = 12764, label = "Star (filled)" },
        { value = 431,   label = "Coins" },
        { value = 937,   label = "Exclamation / alert" },
        { value = 6953,  label = "Quest (ribbon)" },
        { value = 15064, label = "Collection log" },
        { value = 4586,  label = "Skill (Agility)" },
        { value = 4587,  label = "Skill (Archeology)" },
        { value = 4588,  label = "Skill (Attack)" },
        { value = 4589,  label = "Skill (Constitution)" },
        { value = 4590,  label = "Skill (Construction)" },
        { value = 4591,  label = "Skill (Cooking)" },
        { value = 4592,  label = "Skill (Crafting)" },
        { value = 6895,  label = "Skill (Defence)" },
        { value = 6896,  label = "Skill (Divination)" },
        { value = 6899,  label = "Skill (Dungeoneering)" },
        { value = 6901,  label = "Skill (Farming)" },
        { value = 6902,  label = "Skill (Firemaking)" },
        { value = 6903,  label = "Skill (Fishing)" },
        { value = 6904,  label = "Skill (Fletching)" },
        { value = 6905,  label = "Skill (Herblore)" },
        { value = 6906,  label = "Skill (Hunter)" },
        { value = 6907,  label = "Skill (Invention)" },
        { value = 6908,  label = "Skill (Magic)" },
        { value = 6909,  label = "Skill (Mining)" },
        { value = 6910,  label = "Skill (Necromancy)" },
        { value = 6911,  label = "Skill (Prayer)" },
        { value = 6912,  label = "Skill (Ranged)" },
        { value = 6914,  label = "Skill (Runecrafting)" },
        { value = 6915,  label = "Skill (Slayer)" },
        { value = 6916,  label = "Skill (Smithing)" },
        { value = 6917,  label = "Skill (Strength)" },
        { value = 6918,  label = "Skill (Summoning)" },
        { value = 6919,  label = "Skill (Thieving)" },
        { value = 6920,  label = "Skill (Woodcutting)" },
        { value = 24429,  label = "Total level" },
        { value = 10432,  label = "Hourglass" },
    },
})

return Controls
