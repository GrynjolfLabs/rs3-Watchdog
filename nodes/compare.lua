-- Add Compare and group the standard boolean nodes under Logic.
-- Hide legacy comparisons so saved alerts keep their original behavior.
local Compare = {}

local operations = {
    ["=="] = function(a, b) return a == b end,
    ["!="] = function(a, b) return a ~= b end,
    [">"]  = function(a, b) return a > b end,
    ["<"]  = function(a, b) return a < b end,
    [">="] = function(a, b) return a >= b end,
    ["<="] = function(a, b) return a <= b end,
}

function Compare.Register(registry)
    for _, definition in pairs(registry.nodeTypes) do
        if definition.category == "boolean" then
            definition.category = "logic"
        end
    end

    registry:RegisterNodeType("std.compare", {
        category = "logic",
        displayName = "Compare",
        description = "Compare two values using the selected operation.",
        pins = {
            { name = "operation", kind = "data", direction = "in", dataType = "compareOperation", default = "==" },
            { name = "a", kind = "data", direction = "in", dataType = "any" },
            { name = "b", kind = "data", direction = "in", dataType = "any" },
            { name = "result", kind = "data", direction = "out", dataType = "bool" },
        },
        run = function(ctx)
            -- Native Lua semantics: no coercion or type guards. Incompatible
            -- ordered operands raise an error instead of producing false.
            ctx:Out("result", operations[ctx:In("operation")](ctx:In("a"), ctx:In("b")))
        end,
    })

    for _, key in ipairs({
        "std.equals", "std.notequals", "std.greaterthan",
        "std.lessthan", "std.greaterorequal", "std.lessorequal",
    }) do
        registry:GetNodeType(key).hidden = true
    end
end

return Compare
