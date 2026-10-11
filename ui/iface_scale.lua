-- Native ui.* layout is in interface units; Mouse.GetPosition() is unscaled.
-- Divide by InterfaceScale/100 or hit-tests drift down-right as scale rises.

local IfaceScale = {}

---@return number
function IfaceScale.Factor()
    local ok, setting = pcall(function()
        return game.options.InterfaceScale.setting
    end)
    if ok and type(setting) == "number" and setting > 0 then
        return setting / 100
    end
    return 1
end

---@param mx number
---@param my number
---@return number, number
function IfaceScale.ToInterface(mx, my)
    local f = IfaceScale.Factor()
    return mx / f, my / f
end

return IfaceScale
