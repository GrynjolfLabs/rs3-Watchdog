local Controls = require("src/ui/controls")
local BuffBar = require("src/buff_bar")
local BuffCatalog = require("src/buff_catalog")
local BuffSeen = require("src/buff_seen")
local Util = require("src/util")

local Buff = {}

local DEFAULT_CONDITION = "on"
local DEFAULT_OPERATION = "<="

Controls.Register("buff.pick", {
    widget = "capture",
    captureKind = "buff",
    placeholder = "Pick a buff",
    format = function(value)
        local name = BuffCatalog.PickName(value)
        if name == nil then return "" end
        if value.kind == "group" then
            return "Any " .. name:lower()
        end
        return name
    end,
})

Controls.Register("buff.condition", {
    widget = "enum",
    choices = {
        { value = "on", label = "Turns on" },
        { value = "off", label = "Turns off" },
        { value = "number", label = "Number" },
        { value = "time", label = "Time left (seconds)" },
    },
})

local COMPARE = {
    ["=="] = function(a, b) return a == b end,
    ["!="] = function(a, b) return a ~= b end,
    [">"] = function(a, b) return a > b end,
    ["<"] = function(a, b) return a < b end,
    [">="] = function(a, b) return a >= b end,
    ["<="] = function(a, b) return a <= b end,
}

local function conditionOf(node)
    return node.GetControl("condition") or DEFAULT_CONDITION
end

local function compareValue(value, node)
    local threshold = node.GetControl("threshold")
    local compare = COMPARE[node.GetControl("operation") or DEFAULT_OPERATION]
    if type(value) ~= "number" or type(threshold) ~= "number" or compare == nil then
        return false
    end
    return compare(value, threshold)
end

-- The dispatcher fires when this first becomes true, so each crossing alerts once.
local function conditionMet(sample, node)
    local pick = node.GetControl("buff")
    if BuffBar.KeyOf(pick) == nil then
        return false
    end
    local buff = BuffBar.Find(sample, pick)
    local condition = conditionOf(node)
    if condition == "off" then
        return buff == nil
    end
    if buff == nil then
        return false
    end
    if condition == "on" then
        return true
    end
    local count, seconds = BuffBar.ParseValue(buff.text)
    if condition == "number" then
        return compareValue(count, node)
    end
    return compareValue(seconds, node)
end

local function alertMessage(pick, condition, buff)
    local name = BuffCatalog.PickName(pick) or "Buff"
    if condition == "off" then
        return name .. " has ended"
    end
    if condition == "on" or buff == nil or buff.text == "" then
        return name .. " is active"
    end
    if condition == "time" then
        return name .. ": " .. buff.text .. " left"
    end
    return name .. ": " .. buff.text
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Buff.Register(registry, runtime)
    -- Same idea as Location: a change while restricted must not alert afterwards.
    local restrictionGeneration = 0
    local sawRestriction = false

    registry:RegisterNodeType("trigger.buff", {
        category = "trigger",
        displayName = "Buff",
        description = "A buff turns on or off, or reaches a number or time left",
        pins = {
            { name = "buff", kind = "data", direction = "in", dataType = "buff.pick", default = nil },
            { name = "condition", kind = "data", direction = "in", dataType = "buff.condition", default = DEFAULT_CONDITION },
            { name = "operation", kind = "data", direction = "in", dataType = "compareOperation", default = DEFAULT_OPERATION },
            { name = "threshold", kind = "data", direction = "in", dataType = "number", default = 10 },
            { name = "out", kind = "exec", direction = "out" },
            { name = "message", kind = "data", direction = "out", dataType = "string" },
            { name = "text", kind = "data", direction = "out", dataType = "string" },
            { name = "icon", kind = "data", direction = "out", dataType = "toastIcon" },
        },
        run = function(ctx)
            if ctx.payload.edge ~= "Enter" then
                return
            end
            local pick = ctx:In("buff")
            local buff = BuffBar.Find(ctx.payload.sample, pick)
            ctx:Out("message", alertMessage(pick, ctx:In("condition"), buff))
            ctx:Out("text", buff ~= nil and buff.text or "")
            -- Toast icons are sprites, so an item buff shows its toast without one.
            -- A group can match a sprite on the bar (overload does), so use what's there.
            if buff ~= nil and buff.kind == "sprite" then
                ctx:Out("icon", buff.id)
            elseif type(pick) == "table" and pick.kind == "sprite" then
                ctx:Out("icon", pick.id)
            end
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.buff", {
        {
            kind = "poll",
            event = "ServerLogic",
            -- Nil freezes edge state, so logging out or a loading screen can't look like "off".
            transform = function()
                if not Player.IsAvailable() then
                    return nil
                end
                if Util.PlayerIsRestricted() then
                    sawRestriction = true
                    return nil
                end
                if sawRestriction then
                    sawRestriction = false
                    restrictionGeneration = restrictionGeneration + 1
                end
                local sample = BuffBar.Read()
                if sample ~= nil then
                    -- Remembering buffs is a convenience; it must never stop an alert.
                    pcall(BuffSeen.Record, sample.list)
                end
                return sample
            end,
            -- Changing a setting reseeds, so editing a node never fires it.
            seedKey = function(node)
                local key = BuffBar.KeyOf(node.GetControl("buff"))
                if key == nil then
                    return nil
                end
                return table.concat({
                    key, conditionOf(node), tostring(node.GetControl("operation")),
                    tostring(node.GetControl("threshold")), restrictionGeneration,
                }, ":")
            end,
            filter = conditionMet,
        },
    })
end

return Buff
