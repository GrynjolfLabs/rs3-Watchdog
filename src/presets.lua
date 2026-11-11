-- Preset library. One plugin-wide document under the PersistentDB key `presets`
-- (no watchdog_ prefix). Not a Scope Bucket: Store.Save / SaveTo never write this key.
-- Does not copy a Preset into a Scope and does not read the Pack registry.

local ControlKinds = require("src/ui/control_kinds")
local Util = require("src/util")
local Text = require("src/text")
local DropDismissOn = require("src/drop_dismiss_on")

local Presets = {}

-- A Variable is one text, number, enum, checkbox, or Matcher needle. Widget kind is
-- the source of truth, looked up from the tag recorded at Controls.Register.
local MARKABLE_WIDGET = {
    text = true,
    number = true,
    enum = true,
    checkbox = true,
    matcher = true,
}

local DB_KEY = "presets"
local DOC_VERSION = 1
-- Blank and longer-than-this names are refused. Pack Alert Presets use this same cap.
Presets.NAME_MAX = 80
local NAME_MAX = Presets.NAME_MAX

---@class Watchdog.PresetVariable
---@field nodeId integer
---@field pinName string

---@class Watchdog.Preset
---@field id integer
---@field name string
---@field graph LibNodeGraph.SerializedGraph
---@field layout Watchdog.LayoutArray
---@field variables Watchdog.PresetVariable[]

---@class Watchdog.PresetDoc
---@field version integer
---@field presets Watchdog.Preset[]

---@return Watchdog.PresetDoc
function Presets.Empty()
    return { version = DOC_VERSION, presets = {} }
end

---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

-- Reported, not overwritten. A bad document stays on disk until a version-1 read succeeds.
---@param message string
local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

-- A missing key is an empty version-1 library. Load does not create the key.
-- Unreadable JSON, or any version other than 1, is reported and left on disk.
---@return Watchdog.PresetDoc|nil doc
---@return string|nil err
function Presets.Load()
    if PersistentDB == nil then return Presets.Empty(), nil end
    local text
    local got, getErr = pcall(function() text = PersistentDB:GetString(DB_KEY) end)
    if not got then
        report("presets document unreadable, left on disk - " .. tostring(getErr))
        return nil, "Presets could not be read."
    end
    if type(text) ~= "string" or text == "" then
        return Presets.Empty(), nil
    end
    local c = codec()
    if c == nil then
        report("presets document unreadable, left on disk - no JSON codec")
        return nil, "Presets could not be read."
    end
    local ok, doc = pcall(function() return c.decode(text) end)
    if not ok or type(doc) ~= "table" then
        report("presets document unreadable, left on disk - " .. tostring(doc))
        return nil, "Presets could not be read."
    end
    if doc.version ~= DOC_VERSION or type(doc.presets) ~= "table" then
        report("presets document version " .. tostring(doc.version) .. " is not supported, left on disk")
        return nil, "Presets could not be read."
    end
    for _, preset in ipairs(doc.presets) do
        if type(preset) == "table" and type(preset.name) == "string" then
            local stripped = Text.StripTags(preset.name)
            preset.name = stripped ~= "" and stripped or "Preset"
        end
        -- Same raw document Bucket load rewrites. Instantiate reads this result,
        -- so it does not migrate a second time.
        if type(preset) == "table" and type(preset.graph) == "table" then
            preset.layout = DropDismissOn.Apply(preset.graph, preset.layout)
        end
    end
    return doc, nil
end

--- Leading and trailing whitespace and client text tags are removed. A non-string is empty.
---@param name string|nil
---@return string
function Presets.trim(name)
    if type(name) ~= "string" then return "" end
    return (Text.StripTags(name):match("^%s*(.-)%s*$"))
end

local trim = Presets.trim

-- The copy is a new number so a mid-drag save cannot snap the live point.
-- Same on-disk shape an Alert entry uses: `{ id, x, y }` sorted by node id.
---@param layout Watchdog.Layout|nil
---@return Watchdog.LayoutArray
local function layoutToArray(layout)
    local arr = {}
    for id, pos in pairs(layout or {}) do
        arr[#arr + 1] = { id = id, x = Util.RoundHalfAway(pos.x or 0), y = Util.RoundHalfAway(pos.y or 0) }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

-- One past the highest id still in the list, or 1 when the list is empty. No nextId.
---@param doc Watchdog.PresetDoc
---@return integer
local function mintId(doc)
    local maxId = 0
    for _, preset in ipairs(doc.presets or {}) do
        if type(preset.id) == "number" and preset.id > maxId then
            maxId = preset.id
        end
    end
    return maxId + 1
end

---@param doc Watchdog.PresetDoc
---@return boolean
local function write(doc)
    if PersistentDB == nil then return false end
    local c = codec()
    if c == nil then
        report("failed to encode presets document - no JSON codec")
        return false
    end
    local ok, text = pcall(function() return c.encode(doc) end)
    if not ok or type(text) ~= "string" then
        report("failed to encode presets document - " .. tostring(text))
        return false
    end
    return pcall(function() PersistentDB:SetString(DB_KEY, text) end)
end

---@param nodeId integer
---@param pinName string
---@return string
local function markKey(nodeId, pinName)
    return tostring(nodeId) .. "\0" .. tostring(pinName)
end

-- Nil keeps the 3-arg save: variables = {}. A list is stored as { nodeId, pinName } only,
-- ordered by node id then pin order. Duplicates collapse. An ineligible mark writes nothing.
---@param graph LibNodeGraph.Graph
---@param variables Watchdog.PresetVariable[]|nil
---@return Watchdog.PresetVariable[]|nil marks
---@return string|nil err
local function storedMarks(graph, variables)
    if variables == nil then return {} end
    if type(variables) ~= "table" then
        return nil, "That control cannot be marked."
    end
    local allowed = {}
    for _, mark in ipairs(Presets.Eligible(graph)) do
        allowed[markKey(mark.nodeId, mark.pinName)] = true
    end
    local pinOrder = {}
    for id, node in pairs(graph.nodes or {}) do
        if node ~= nil then
            local order = {}
            for index, pin in ipairs(graph:GetPins(id) or {}) do
                order[pin.name] = index
            end
            pinOrder[id] = order
        end
    end
    local seen = {}
    local out = {}
    for _, mark in ipairs(variables) do
        if type(mark) ~= "table" or type(mark.nodeId) ~= "number" or type(mark.pinName) ~= "string" then
            return nil, "That control cannot be marked."
        end
        local key = markKey(mark.nodeId, mark.pinName)
        if not allowed[key] then
            return nil, "That control cannot be marked."
        end
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = { nodeId = mark.nodeId, pinName = mark.pinName }
        end
    end
    table.sort(out, function(a, b)
        if a.nodeId ~= b.nodeId then return a.nodeId < b.nodeId end
        local aOrder = pinOrder[a.nodeId] and pinOrder[a.nodeId][a.pinName] or 0
        local bOrder = pinOrder[b.nodeId] and pinOrder[b.nodeId][b.pinName] or 0
        return aOrder < bOrder
    end)
    return out
end

-- Always adds. Never replaces. Duplicate names are kept.
-- Refuses to write until a version-1 document can be read, and refuses a blank name.
---@param name string
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@param variables Watchdog.PresetVariable[]|nil
---@return Watchdog.Preset|nil preset
---@return string|nil err
function Presets.Add(name, graph, layout, variables)
    local trimmed = trim(name)
    if trimmed == "" or #trimmed > NAME_MAX then
        return nil, "Enter a preset name."
    end
    if graph == nil or LibNodeGraph == nil or LibNodeGraph.Serialize == nil then
        return nil, "Could not copy the graph."
    end
    local marks, markErr = storedMarks(graph, variables)
    if marks == nil then
        return nil, markErr
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, err
    end
    Text.StripGraphText(graph)
    local ok, serialized = pcall(LibNodeGraph.Serialize, graph)
    if not ok or type(serialized) ~= "table" then
        report("could not copy the alert graph - " .. tostring(serialized))
        return nil, "Could not copy the graph."
    end
    local preset = {
        id = mintId(doc),
        name = trimmed,
        graph = serialized,
        layout = layoutToArray(layout),
        variables = marks,
    }
    doc.presets[#doc.presets + 1] = preset
    if not write(doc) then
        return nil, "Could not save the preset."
    end
    return preset, nil
end

-- Martin Pool's natural order, the case-insensitive form PHP calls strnatcasecmp.
-- Spaces are skipped the way that algorithm skips them. A zero-padded run is
-- compared left to right, so "01" comes before "1". A run with no leading zero
-- uses the longer-run comparison, so "2" comes before "10".

local function isDigit(ch)
    return ch ~= nil and ch >= "0" and ch <= "9"
end

local function isSpace(ch)
    return ch == " " or ch == "\t" or ch == "\n" or ch == "\r" or ch == "\v" or ch == "\f"
end

local function upper(ch)
    local b = string.byte(ch)
    if b >= 97 and b <= 122 then
        return string.char(b - 32)
    end
    return ch
end

--- Case-insensitive natural order. Spaces are skipped. -1 when a < b, 0 when equal, 1 when a > b.
---@param a string
---@param b string
---@return integer
function Presets.natcasecmp(a, b)
    a = type(a) == "string" and a or ""
    b = type(b) == "string" and b or ""
    local aLen, bLen = #a, #b
    if aLen == 0 or bLen == 0 then
        if aLen == bLen then return 0 end
        if aLen > bLen then return 1 end
        return -1
    end

    local ap, bp = 1, 1
    local function charAt(s, len, i)
        if i > len then return nil end
        return s:sub(i, i)
    end
    local ca = charAt(a, aLen, ap)
    local cb = charAt(b, bLen, bp)

    local function compareRight()
        local bias = 0
        while true do
            local aEnd = ap > aLen or not isDigit(charAt(a, aLen, ap))
            local bEnd = bp > bLen or not isDigit(charAt(b, bLen, bp))
            if aEnd and bEnd then return bias end
            if aEnd then return -1 end
            if bEnd then return 1 end
            local da = charAt(a, aLen, ap)
            local db = charAt(b, bLen, bp)
            if da < db then
                if bias == 0 then bias = -1 end
            elseif da > db then
                if bias == 0 then bias = 1 end
            end
            ap = ap + 1
            bp = bp + 1
        end
    end

    local function compareLeft()
        while true do
            local aEnd = ap > aLen or not isDigit(charAt(a, aLen, ap))
            local bEnd = bp > bLen or not isDigit(charAt(b, bLen, bp))
            if aEnd and bEnd then return 0 end
            if aEnd then return -1 end
            if bEnd then return 1 end
            local da = charAt(a, aLen, ap)
            local db = charAt(b, bLen, bp)
            if da < db then return -1 end
            if da > db then return 1 end
            ap = ap + 1
            bp = bp + 1
        end
    end

    while true do
        while ca ~= nil and isSpace(ca) do
            ap = ap + 1
            ca = charAt(a, aLen, ap)
        end
        while cb ~= nil and isSpace(cb) do
            bp = bp + 1
            cb = charAt(b, bLen, bp)
        end

        if isDigit(ca) and isDigit(cb) then
            local result
            if ca == "0" or cb == "0" then
                result = compareLeft()
            else
                result = compareRight()
            end
            if result ~= 0 then return result end
            if ap > aLen and bp > bLen then return 0 end
            if ap > aLen then return -1 end
            if bp > bLen then return 1 end
            ca = charAt(a, aLen, ap)
            cb = charAt(b, bLen, bp)
        end

        if ca == nil and cb == nil then return 0 end
        if ca == nil then return -1 end
        if cb == nil then return 1 end

        local ua, ub = upper(ca), upper(cb)
        if ua < ub then return -1 end
        if ua > ub then return 1 end

        ap = ap + 1
        bp = bp + 1
        if ap > aLen and bp > bLen then return 0 end
        if ap > aLen then return -1 end
        if bp > bLen then return 1 end
        ca = charAt(a, aLen, ap)
        cb = charAt(b, bLen, bp)
    end
end

-- Sorted copy. The stored array keeps insertion order; nothing persists a display order.
---@return Watchdog.Preset[]|nil presets
---@return string|nil err
function Presets.List()
    local doc, err = Presets.Load()
    if doc == nil then return nil, err end
    local copy = {}
    for i, preset in ipairs(doc.presets) do
        copy[i] = preset
    end
    table.sort(copy, function(left, right)
        local cmp = Presets.natcasecmp(left.name, right.name)
        if cmp ~= 0 then return cmp < 0 end
        return (left.id or 0) < (right.id or 0)
    end)
    return copy, nil
end

-- Keeps the id. Only the trimmed name changes; graph, layout, and variables stay as saved.
-- Refuses a blank name and refuses to write until a version-1 document can be read.
---@param id integer
---@param name string
---@return Watchdog.Preset|nil preset
---@return string|nil err
function Presets.Rename(id, name)
    local trimmed = trim(name)
    if trimmed == "" or #trimmed > NAME_MAX then
        return nil, "Enter a preset name."
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, err
    end
    local preset
    for _, candidate in ipairs(doc.presets) do
        if candidate.id == id then
            preset = candidate
            break
        end
    end
    if preset == nil then
        return nil, "Preset not found."
    end
    preset.name = trimmed
    if not write(doc) then
        return nil, "Could not rename the preset."
    end
    return preset, nil
end

-- Removes one id. Another Preset with the same name stays. Does not write Scope buckets.
-- A missing id does not wipe the library. An unreadable document is left on disk.
---@param id integer
---@return boolean|nil ok
---@return string|nil err
function Presets.Delete(id)
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, err
    end
    local index
    for i, candidate in ipairs(doc.presets) do
        if candidate.id == id then
            index = i
            break
        end
    end
    if index == nil then
        return nil, "Preset not found."
    end
    table.remove(doc.presets, index)
    if not write(doc) then
        return nil, "Could not delete the preset."
    end
    return true, nil
end


---@param node table|nil
---@return boolean
local function isPlaceholder(node)
    if node == nil then return false end
    if node.unknown ~= nil then return true end
    local unknown = (LibNodeGraph ~= nil) and LibNodeGraph.UNKNOWN_TYPE or nil
    if unknown ~= nil and node.typeKey == unknown then return true end
    return node.typeKey == "__unknown__"
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return boolean
local function pinConnected(graph, nodeId, pinName)
    for _, conn in pairs(graph.connections or {}) do
        if conn.toNode == nodeId and conn.toPin == pinName then
            return true
        end
    end
    return false
end

-- Pins a player can mark: unconnected data-in text, number, enum, or Matcher needle
-- on a real node. Ordered by node id, then that node's pin order.
---@param graph LibNodeGraph.Graph
---@return Watchdog.PresetVariable[]
function Presets.Eligible(graph)
    if type(graph) ~= "table" or type(graph.nodes) ~= "table" or type(graph.GetPins) ~= "function" then
        return {}
    end
    local ids = {}
    for id in pairs(graph.nodes) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local node = graph.nodes[id]
        if not isPlaceholder(node) then
            for _, pin in ipairs(graph:GetPins(id) or {}) do
                local widget = ControlKinds.Widget(pin.dataType)
                if pin.kind == "data" and pin.direction == "in"
                    and widget ~= nil and MARKABLE_WIDGET[widget] == true
                    and not pinConnected(graph, id, pin.name) then
                    out[#out + 1] = { nodeId = id, pinName = pin.name }
                end
            end
        end
    end
    return out
end

-- Eligible pins still unmarked, grouped by node in eligible order. A node with no pins
-- left is omitted. One pin in the group means choosing that node marks it.
---@param eligible Watchdog.PresetVariable[]|nil
---@param marked Watchdog.PresetVariable[]|nil
---@return { nodeId: integer, pinNames: string[] }[]
function Presets.UnmarkedNodes(eligible, marked)
    local taken = {}
    for _, mark in ipairs(marked or {}) do
        if type(mark) == "table" then
            taken[markKey(mark.nodeId, mark.pinName)] = true
        end
    end
    local groups = {}
    local order = {}
    for _, mark in ipairs(eligible or {}) do
        local key = markKey(mark.nodeId, mark.pinName)
        if not taken[key] then
            local group = groups[mark.nodeId]
            if group == nil then
                group = { nodeId = mark.nodeId, pinNames = {} }
                groups[mark.nodeId] = group
                order[#order + 1] = mark.nodeId
            end
            group.pinNames[#group.pinNames + 1] = mark.pinName
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        out[#out + 1] = groups[id]
    end
    return out
end

return Presets
