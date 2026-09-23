local Enum = require("ui/controls/enum")
local Theme = require("ui/theme")

-- Client text uses markup: <lt>/<gt> render literal angle brackets. Keep the
-- stored operators unchanged; the enum maps selected labels back to those values.
local CompareOperation = Enum.new({
    { value = "==", label = "Equals (==)" },
    { value = "!=", label = "Not Equals (!=)" },
    { value = ">",  label = "Greater Than (<gt>)" },
    { value = "<",  label = "Less Than (<lt>)" },
    { value = ">=", label = "Greater or Equal (<gt>=)" },
    { value = "<=", label = "Less or Equal (<lt>=)" },
})

-- The full English labels need the node's width, rather than the narrow value
-- column beside the operation pin and result output.
CompareOperation.Inline = false
function CompareOperation.ReservedHeight(_pin)
    return Theme.CONTROL_H + Theme.CONTROL_PAD_X
end
function CompareOperation.Layout(band)
    return { { kind = "field", x = band.x, y = band.y, w = band.w, h = Theme.CONTROL_H } }
end

return CompareOperation
