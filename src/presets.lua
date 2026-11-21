-- Preset library. The index is `scope_presets` (version 2: id, name, variables).
-- Each graph is `scope_presets_<id>` (version 1: version, graph, layout), a WD1 token.
-- The legacy `presets` value stays on disk as the pre-migration snapshot. Nothing
-- writes or deletes it. Not a Scope Bucket, and not the Pack registry.

local ControlKinds = require("src/ui/control_kinds")
local Util = require("src/util")
local Text = require("src/text")
local DropDismissOn = require("src/drop_dismiss_on")
local Compress = require("src/compress")

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
local INDEX_KEY = "scope_presets"
local INDEX_VERSION = 2
local PAYLOAD_VERSION = 1
-- PersistentDB leaves the previous bytes when the stored token is longer than this.
local TOKEN_CAP = 131070
local onSaveFailed
local onLoadFailed
local boundDb
local indexBlocked = false
local reportedUnreadable = false
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

local function bindDb()
    if boundDb ~= PersistentDB then
        boundDb = PersistentDB
        indexBlocked = false
        reportedUnreadable = false
    end
end

---@param key string
---@return boolean got
---@return string|nil text
---@return any err
local function readString(key)
    local text
    local got, err = pcall(function() text = PersistentDB:GetString(key) end)
    return got, text, err
end

---@param id integer
---@return string
local function payloadKey(id)
    return INDEX_KEY .. "_" .. tostring(id)
end

-- The new index is present and this build cannot use it. The session keeps an
-- empty library and does not read the legacy snapshot, so a bad read is not
-- saved back as an empty index.
local function blockIndex(detail)
    indexBlocked = true
    report(detail)
    if not reportedUnreadable and onLoadFailed ~= nil then
        reportedUnreadable = true
        onLoadFailed()
    else
        reportedUnreadable = true
    end
end

---@param text string|nil
---@return table|nil
local function decodeToken(text)
    if type(text) ~= "string" or text == "" then return nil end
    if text:sub(1, #Compress.PREFIX) ~= Compress.PREFIX then return nil end
    local inflated, json = pcall(Compress.decompress, text)
    if not inflated or type(json) ~= "string" then return nil end
    local c = codec()
    if c == nil then return nil end
    local ok, doc = pcall(function() return c.decode(json) end)
    if not ok or type(doc) ~= "table" then return nil end
    return doc
end

---@param name string|nil
---@return string
local function strippedName(name)
    if type(name) ~= "string" then return "Preset" end
    local stripped = Text.StripTags(name)
    return stripped ~= "" and stripped or "Preset"
end

-- Legacy `presets` is one version-1 document. A missing key is an empty library.
-- Unreadable JSON, or any version other than 1, is reported and left on disk.
---@return Watchdog.PresetDoc|nil doc
---@return string|nil err
local function loadLegacy()
    local got, text, getErr = readString(DB_KEY)
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
            preset.name = strippedName(preset.name)
        end
        -- Same raw document Instantiate reads. It does not migrate a second time.
        if type(preset) == "table" and type(preset.graph) == "table" then
            preset.layout = DropDismissOn.Apply(preset.graph, preset.layout)
        end
    end
    return doc, nil
end

---@param text string
---@return Watchdog.PresetDoc doc
local function loadIndex(text)
    local index = decodeToken(text)
    if index == nil or index.version ~= INDEX_VERSION or type(index.presets) ~= "table" then
        blockIndex("presets document unreadable, left on disk")
        return Presets.Empty()
    end
    local doc = Presets.Empty()
    for _, row in ipairs(index.presets) do
        if type(row) == "table" and type(row.id) == "number" then
            local preset = {
                id = row.id,
                name = strippedName(row.name),
                variables = type(row.variables) == "table" and row.variables or {},
                graph = nil,
                layout = {},
            }
            local got, payloadText = readString(payloadKey(row.id))
            local payload = got and decodeToken(payloadText) or nil
            -- A payload this build does not understand stays on disk. The index
            -- row stays so a later list edit does not drop it.
            if payload ~= nil and payload.version == PAYLOAD_VERSION and type(payload.graph) == "table" then
                preset.graph = payload.graph
                preset.layout = DropDismissOn.Apply(payload.graph, payload.layout)
            end
            doc.presets[#doc.presets + 1] = preset
        end
    end
    return doc
end

-- A missing index with no legacy key is an empty library. Load does not create
-- the index. An index that is present but unreadable is an empty library for
-- this session, and the legacy document is not read.
---@return Watchdog.PresetDoc|nil doc
---@return string|nil err
function Presets.Load()
    bindDb()
    if PersistentDB == nil then return Presets.Empty(), nil end
    local got, text, getErr = readString(INDEX_KEY)
    if not got then
        blockIndex("presets document unreadable, left on disk - " .. tostring(getErr))
        return Presets.Empty(), nil
    end
    if type(text) == "string" and text ~= "" then
        return loadIndex(text), nil
    end
    return loadLegacy()
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

---@param detail string
---@param reason "size"|"failed"|nil
---@return boolean
local function failSave(detail, reason)
    report(detail)
    if onSaveFailed ~= nil then onSaveFailed(reason) end
    return false
end

---@param payload table
---@return string|nil token
---@return "size"|"failed"|nil reason
local function encodeToken(payload)
    local c = codec()
    if c == nil then return nil, "failed" end
    local ok, json = pcall(function() return c.encode(payload) end)
    if not ok or type(json) ~= "string" then return nil, "failed" end
    local compressed, token = pcall(Compress.compress, json)
    if not compressed or type(token) ~= "string" then return nil, "failed" end
    if #token > TOKEN_CAP then return nil, "size" end
    return token
end

-- False, nil, and a throw leave the previous bytes. A true return is the save.
-- The legacy `presets` key is never passed here.
---@param key string
---@param payload table
---@return boolean
---@return "size"|"failed"|nil reason
local function putToken(key, payload)
    if PersistentDB == nil then return false, "failed" end
    local token, reason = encodeToken(payload)
    if token == nil then return false, reason or "failed" end
    local ok, stored = pcall(function() return PersistentDB:SetString(key, token) end)
    if not ok or stored ~= true then return false, "failed" end
    return true
end

---@return boolean
local function indexIsPresent()
    if PersistentDB == nil then return false end
    local got, text = readString(INDEX_KEY)
    return got and type(text) == "string" and text ~= ""
end

---@param preset Watchdog.Preset
---@return boolean
---@return "size"|"failed"|nil reason
local function putPayload(preset)
    return putToken(payloadKey(preset.id), {
        version = PAYLOAD_VERSION,
        graph = preset.graph,
        layout = preset.layout or {},
    })
end

---@param doc Watchdog.PresetDoc
---@return boolean
---@return "size"|"failed"|nil reason
local function putIndex(doc)
    local rows = {}
    for i, preset in ipairs(doc.presets or {}) do
        rows[i] = {
            id = preset.id,
            name = preset.name,
            variables = preset.variables or {},
        }
    end
    return putToken(INDEX_KEY, { version = INDEX_VERSION, presets = rows })
end

-- While the index is absent, every graph has to be stored before the index
-- exists, or the next load would still be the legacy document. Once the index
-- exists, a graph save writes that one key and then the index.
---@param doc Watchdog.PresetDoc
---@param payloadId integer|nil
---@return boolean
local function commitSave(doc, payloadId)
    bindDb()
    if indexBlocked then
        return failSave("failed to save presets document - unreadable index", "failed")
    end
    if indexIsPresent() then
        if payloadId ~= nil then
            for _, preset in ipairs(doc.presets or {}) do
                if preset.id == payloadId then
                    local ok, reason = putPayload(preset)
                    if not ok then
                        return failSave("failed to save presets document - " .. tostring(reason), reason)
                    end
                    break
                end
            end
        end
    else
        for _, preset in ipairs(doc.presets or {}) do
            local ok, reason = putPayload(preset)
            if not ok then
                return failSave("failed to save presets document - " .. tostring(reason), reason)
            end
        end
    end
    local ok, reason = putIndex(doc)
    if not ok then
        return failSave("failed to save presets document - " .. tostring(reason), reason)
    end
    return true
end

-- The index without this preset is written first. The payload key is deleted
-- only after that write returns true. A false, nil, or thrown Delete leaves
-- the payload bytes and still counts the preset as removed from the library.
---@param doc Watchdog.PresetDoc
---@param removedId integer
---@return boolean
local function commitDelete(doc, removedId)
    bindDb()
    if indexBlocked then
        return failSave("failed to save presets document - unreadable index", "failed")
    end
    local hadIndex = indexIsPresent()
    if not hadIndex then
        for _, preset in ipairs(doc.presets or {}) do
            local ok, reason = putPayload(preset)
            if not ok then
                return failSave("failed to save presets document - " .. tostring(reason), reason)
            end
        end
    end
    local ok, reason = putIndex(doc)
    if not ok then
        return failSave("failed to save presets document - " .. tostring(reason), reason)
    end
    if hadIndex and PersistentDB ~= nil then
        local deletedOk, deleted = pcall(function()
            return PersistentDB:Delete(payloadKey(removedId))
        end)
        if not deletedOk or deleted ~= true then
            report("failed to delete preset key '" .. payloadKey(removedId) .. "'")
        end
    end
    return true
end

-- main points this at the save-failed message dialog. Tests replace it.
---@param fn fun(reason: "size"|"failed"|nil)|nil
function Presets.SetSaveFailed(fn)
    onSaveFailed = fn
end

-- One dialog when `scope_presets` is present and this build cannot read it.
---@param fn fun()|nil
function Presets.SetLoadFailed(fn)
    onLoadFailed = fn
end

-- Moves a legacy `presets` document onto the index and payload keys. An index
-- that already exists is left alone, including one this build cannot read.
-- An empty legacy library becomes an empty index so the old list is not copied
-- back. One graph that does not fit leaves the index absent.
---@return { reason: "size"|"failed", name: string|nil }|nil
function Presets.Migrate()
    bindDb()
    if PersistentDB == nil then return nil end
    local got, text = readString(INDEX_KEY)
    if not got or (type(text) == "string" and text ~= "") then
        return nil
    end
    local legacyGot, legacy = readString(DB_KEY)
    if not legacyGot or type(legacy) ~= "string" or legacy == "" then
        return nil
    end
    local doc = loadLegacy()
    if doc == nil then
        report("could not migrate presets")
        return { reason = "failed" }
    end
    for _, preset in ipairs(doc.presets or {}) do
        local ok, reason = putPayload(preset)
        if not ok then
            report("could not migrate presets")
            return { reason = reason or "failed", name = preset.name }
        end
    end
    local ok, reason = putIndex(doc)
    if not ok then
        report("could not migrate presets")
        return { reason = reason or "failed" }
    end
    return nil
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
    if not commitSave(doc, preset.id) then
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
    if not commitSave(doc, nil) then
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
    if not commitDelete(doc, id) then
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
