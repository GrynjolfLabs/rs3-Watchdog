-- Buffs that have been on the bar before, so they can be picked when inactive.
-- Saved under one key; a failed read or write only costs the list, never an alert.

local BuffCatalog = require("src/buff_catalog")

local BuffSeen = {}

BuffSeen.KEY = "watchdog_buff_seen"
BuffSeen.MAX = 24

local entries = nil  -- newest first: { kind, id, name }
local keys = nil
local canWrite = false

local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

local function keyOf(entry)
    return entry.kind .. ":" .. tostring(entry.id)
end

local function load()
    if entries ~= nil then return end
    entries, keys, canWrite = {}, {}, false
    if PersistentDB == nil then return end

    local text
    local got = pcall(function() text = PersistentDB:GetString(BuffSeen.KEY) end)
    if not got then
        report("seen buffs unreadable")
        return
    end
    canWrite = true
    if type(text) ~= "string" or text == "" then return end

    local ok, decoded = pcall(function() return LibNodeGraph.Json.Default.decode(text) end)
    if not ok or type(decoded) ~= "table" then
        report("seen buffs unreadable - starting a new list")
        return
    end
    for _, entry in ipairs(decoded) do
        if type(entry) == "table" and (entry.kind == "sprite" or entry.kind == "obj")
            and math.type(entry.id) == "integer" and #entries < BuffSeen.MAX then
            local key = keyOf(entry)
            if not keys[key] then
                keys[key] = true
                entries[#entries + 1] = { kind = entry.kind, id = entry.id, name = entry.name }
            end
        end
    end
end

local function save()
    if not canWrite or PersistentDB == nil then return end
    local ok, err = pcall(function()
        PersistentDB:SetString(BuffSeen.KEY, LibNodeGraph.Json.Default.encode(entries))
    end)
    if not ok then
        report("seen buffs not saved - " .. tostring(err))
    end
end

--- Adds buffs not seen before. Writes only when the list changes.
---@param buffs Watchdog.Buff[]
function BuffSeen.Record(buffs)
    load()
    local changed = false
    for _, buff in ipairs(buffs) do
        local key = keyOf(buff)
        if not keys[key] then
            keys[key] = true
            table.insert(entries, 1, { kind = buff.kind, id = buff.id, name = BuffCatalog.Describe(buff) })
            changed = true
        end
    end
    while #entries > BuffSeen.MAX do
        keys[keyOf(entries[#entries])] = nil
        table.remove(entries)
    end
    if changed then save() end
end

--- Newest first. Callers must not change the entries.
function BuffSeen.List()
    load()
    return entries
end

--- Tests only: forget the loaded list so the next call reads the database again.
function BuffSeen._Reset()
    entries, keys, canWrite = nil, nil, false
end

return BuffSeen
