-- Reads the game's built-in buff and debuff bars. The Client API has no buff functions.

local BuffCatalog = require("src/buff_catalog")

local BuffBar = {}

-- Fallback ids come from "pan Component" and only apply if a name lookup fails.
local BARS = {
    { prefix = "BUFF_BAR__BUFF_", firstSlot = 18612243, required = true },
    { prefix = "DEBUFF_BAR__BUFF_", firstSlot = 19070978, required = false, isDebuff = true },
}
local MAX_SLOTS = 50

---@class Watchdog.Buff
---@field key string              # "sprite:<id>" or "obj:<id>"
---@field kind "sprite"|"obj"
---@field id integer
---@field text string             # the bar's main text with tags removed
---@field isDebuff boolean

---@class Watchdog.BuffPick
---@field kind "sprite"|"obj"|"group"
---@field id integer|nil          # sprite and obj picks
---@field group string|nil        # group picks: a BuffCatalog group key
---@field name string|nil

local function slotIdsFor(bar)
    if bar.slotIds == nil then
        bar.slotIds = {}
        for slot = 1, MAX_SLOTS do
            local componentId = id.Component[bar.prefix .. slot]
            if math.type(componentId) ~= "integer" then
                componentId = bar.firstSlot + slot - 1
            end
            bar.slotIds[slot] = componentId
        end
    end
    return bar.slotIds
end

local function cleanText(text)
    if type(text) ~= "string" then
        return ""
    end
    return (text:gsub("<[^>]*>", ""))
end

-- A slot's children: dyn 0 icon, dyn 1 main text, dyn 2 rectangle, dyn 3 second text.
-- Unused slots can still report as visible, so only a slot with an icon is a buff.
local function readSlot(componentId, isDebuff)
    local slot = ui.Interfaces:GetComponent(componentId)
    if slot == nil or not slot.visibleGlobal then
        return nil
    end
    local children = {}
    slot:IterateDynamicComponents(function(child)
        children[child.dynamicID] = child
        return false
    end)
    local icon = children[0]
    if icon == nil then
        return nil
    end
    local kind, buffId
    if icon.associatedObjectID >= 0 then
        kind, buffId = "obj", icon.associatedObjectID
    elseif icon.spriteID >= 0 then
        kind, buffId = "sprite", icon.spriteID
    else
        return nil
    end
    return {
        key = kind .. ":" .. buffId,
        kind = kind,
        id = buffId,
        text = cleanText(children[1] and children[1].content),
        isDebuff = isDebuff == true,
    }
end

--- Nil means the bars can't be read right now, which is not the same as no buffs.
---@return { list: Watchdog.Buff[], byKey: table<string, Watchdog.Buff> }|nil
function BuffBar.Read()
    if not Player.IsAvailable() then
        return nil
    end
    local list, byKey = {}, {}
    for _, bar in ipairs(BARS) do
        local slotIds = slotIdsFor(bar)
        if ui.Interfaces:GetComponent(slotIds[1]) == nil then
            if bar.required then
                return nil
            end
        else
            -- Slots can be empty in the middle of the bar: Darkness has been seen in
            -- slot 4 with slots 1 to 3 empty. So every slot is read.
            for _, componentId in ipairs(slotIds) do
                local buff = readSlot(componentId, bar.isDebuff)
                if buff ~= nil then
                    list[#list + 1] = buff
                    if byKey[buff.key] == nil then
                        byKey[buff.key] = buff
                    end
                end
            end
        end
    end
    return { list = list, byKey = byKey }
end

--- Identifies a pick for edge-state seeding. Nil means nothing is picked.
---@param pick Watchdog.BuffPick|nil
---@return string|nil
function BuffBar.KeyOf(pick)
    if type(pick) ~= "table" then
        return nil
    end
    if pick.kind == "group" then
        if pick.group == nil then return nil end
        return "group:" .. pick.group
    end
    if pick.kind == nil or pick.id == nil then
        return nil
    end
    return pick.kind .. ":" .. pick.id
end

--- The first buff on the bars that a pick means, or nil.
---@param sample { list: Watchdog.Buff[] }
---@param pick Watchdog.BuffPick|nil
---@return Watchdog.Buff|nil
function BuffBar.Find(sample, pick)
    if BuffBar.KeyOf(pick) == nil then
        return nil
    end
    for _, buff in ipairs(sample.list) do
        if BuffCatalog.Matches(pick, buff) then
            return buff
        end
    end
    return nil
end

--- Turns bar text into comparable values. A bare number could be a count or seconds,
--- so it fills both; "4m" is time only; "16(2)" is 16 seconds with a count of 2.
---@param text string|nil
---@return number|nil count
---@return number|nil seconds
function BuffBar.ParseValue(text)
    if type(text) ~= "string" then
        return nil, nil
    end
    local s = text:gsub(",", ""):gsub("%s+", ""):lower()

    local timer, stacks = s:match("^(%d+)%((%d+)%)$")
    if timer ~= nil then
        return tonumber(stacks), tonumber(timer)
    end
    local minutes, seconds = s:match("^(%d+):(%d%d)$")
    if minutes ~= nil then
        return nil, tonumber(minutes) * 60 + tonumber(seconds)
    end
    local amount = s:match("^(%d+)m[in]*$")
    if amount ~= nil then
        return nil, tonumber(amount) * 60
    end
    amount = s:match("^(%d+)h[rs]*$")
    if amount ~= nil then
        return nil, tonumber(amount) * 3600
    end
    amount = s:match("^(%d+)$")
    if amount ~= nil then
        return tonumber(amount), tonumber(amount)
    end
    return nil, nil
end

return BuffBar
