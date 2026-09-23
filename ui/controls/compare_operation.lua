local Enum = require("ui/controls/enum")
local Theme = require("ui/theme")

-- <lt> and <gt> display angle brackets without starting a client formatting tag.
-- Each label maps to its stored operator.
local CompareOperation = Enum.new({
    { value = "==", label = "Equals (==)" },
    { value = "!=", label = "Not Equals (!=)" },
    { value = ">",  label = "Greater Than (<gt>)" },
    { value = "<",  label = "Less Than (<lt>)" },
    { value = ">=", label = "Greater or Equal (<gt>=)" },
    { value = "<=", label = "Less or Equal (<lt>=)" },
})

-- Use the node's width so the English labels fit.
CompareOperation.Inline = false
function CompareOperation.ReservedHeight(_pin)
    return Theme.CONTROL_H + Theme.CONTROL_PAD_X
end
function CompareOperation.Layout(band)
    return { { kind = "field", x = band.x, y = band.y, w = band.w, h = Theme.CONTROL_H } }
end

return CompareOperation
