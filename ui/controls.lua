local ScalarControl  = require("ui/controls/scalar")
local EnumControl    = require("ui/controls/enum")
local SwatchControl  = require("ui/controls/swatch")
local CaptureControl = require("ui/controls/capture")
local ModeControl    = require("ui/controls/mode")
local NumberField    = require("ui/widgets/number_field")
local TextField      = require("ui/widgets/text_field")

local Controls = {}

local pinControls = {}

---@param tag string
---@param module table
---@return table
function Controls.RegisterPinControl(tag, module)
    assert(type(tag) == "string" and tag ~= "", "pin control tag must be a non-empty string")
    assert(type(module) == "table", "pin control must be a module table")
    pinControls[tag] = module
    return module
end

---@param tag string|nil
---@return table|nil
function Controls.PinControlFor(tag)
    if tag == nil then return nil end
    return pinControls[tag]
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
    return descriptor
end

-- ComboField ranks Add() entries alphabetically; match choices by label text, never id.
Controls.Register("number", { widget = "number" })
Controls.Register("string", { widget = "text" })
Controls.RegisterPinControl("compareOperation", require("ui/controls/compare_operation"))
Controls.Register("bool", {
    widget = "enum",
    choices = {
        { value = true,  label = "true"  },
        { value = false, label = "false" },
    },
})

Controls.RegisterPinControl("coordgrid", require("ui/controls/coordgrid"))
Controls.RegisterPinControl("matcher", require("ui/controls/matcher"))

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
    },
})

return Controls
