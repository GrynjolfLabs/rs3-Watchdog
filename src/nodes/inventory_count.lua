local Controls = require("src/ui/controls")
local Matcher = require("src/matcher")

local InventoryCount = {}

Controls.Register("invNoteFilter", {
    widget = "enum",
    choices = {
        { value = "both", label = "Both" },
        { value = "noted", label = "Noted" },
        { value = "unnoted", label = "Unnoted" },
    },
})

---@param slot Watchdog.InvSnapshotSlot|nil
---@return boolean
local function configNameHasCertPrefix(slot)
    local configName = slot and slot.configName
    return type(configName) == "string" and configName:sub(1, 5) == "CERT_"
end

---@param filter string|nil
---@param slot Watchdog.InvSnapshotSlot
---@return boolean
local function noteFilterPasses(filter, slot)
    if filter == "noted" then
        return configNameHasCertPrefix(slot)
    end
    if filter == "unnoted" then
        return not configNameHasCertPrefix(slot)
    end
    return true
end

---@param snap Watchdog.InvSnapshot|nil
---@param matcher Watchdog.MatcherValue|nil
---@param filter string|nil
---@return number
local function matchingSum(snap, matcher, filter)
    local total = 0
    local slots = snap and snap.slots
    local cap = snap and snap.slotCount or 0
    if type(slots) == "table" then
        if cap < 1 then
            cap = #slots
        end
        for i = 1, cap do
            local s = slots[i]
            if s ~= nil and noteFilterPasses(filter, s) and Matcher.Test(matcher, s.name) then
                local n = s.count
                if type(n) == "number" then
                    total = total + n
                end
            end
        end
    end
    return total
end

---@param ctx LibNodeGraph.RunContext
local function runItemCount(ctx)
    ctx:Out("count", matchingSum(ctx:In("snapshot"), ctx:In("nameMatch"), ctx:In("noteFilter")))
end

--- Pure Node. A pull recomputes all three outs from the wired snapshots.
--- `delta ~= 0` is the change check; an exec pin would freeze these numbers until fired.
---@param ctx LibNodeGraph.RunContext
local function runItemCountChanged(ctx)
    local matcher = ctx:In("nameMatch")
    local filter = ctx:In("noteFilter")
    local count = matchingSum(ctx:In("snapshot"), matcher, filter)
    local prevCount = matchingSum(ctx:In("prevSnapshot"), matcher, filter)
    ctx:Out("count", count)
    ctx:Out("prevCount", prevCount)
    ctx:Out("delta", count - prevCount)
end

---@param registry LibNodeGraph.Registry
function InventoryCount.Register(registry)
    registry:RegisterNodeType("inventory.item_count", {
        category = "inventory",
        displayName = "Item Count",
        description = "Filters inventory triggers by item count",
        pins = {
            { name = "snapshot", kind = "data", direction = "in", dataType = "invSnapshot",
              label = "Snapshot" },
            { name = "nameMatch", kind = "data", direction = "in", dataType = "matcher",
              label = "Name", default = { needle = "", mode = "substring" } },
            { name = "noteFilter", kind = "data", direction = "in", dataType = "invNoteFilter",
              label = "Notes", default = "both" },
            { name = "count", kind = "data", direction = "out", dataType = "number" },
        },
        run = runItemCount,
    })

    registry:RegisterNodeType("inventory.item_count_changed", {
        category = "inventory",
        displayName = "Item Count Changed",
        description = "Current and previous matching stack sums, and their difference",
        pins = {
            { name = "prevSnapshot", kind = "data", direction = "in", dataType = "invSnapshot",
              label = "Prev snapshot" },
            { name = "snapshot", kind = "data", direction = "in", dataType = "invSnapshot",
              label = "Snapshot" },
            { name = "nameMatch", kind = "data", direction = "in", dataType = "matcher",
              label = "Name", default = { needle = "", mode = "substring" } },
            { name = "noteFilter", kind = "data", direction = "in", dataType = "invNoteFilter",
              label = "Notes", default = "both" },
            { name = "count", kind = "data", direction = "out", dataType = "number" },
            { name = "prevCount", kind = "data", direction = "out", dataType = "number" },
            { name = "delta", kind = "data", direction = "out", dataType = "number" },
        },
        run = runItemCountChanged,
    })
end

return InventoryCount
