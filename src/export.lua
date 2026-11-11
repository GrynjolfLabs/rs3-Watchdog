-- export.lua - copy-paste transfer envelope `{ schemaVersion, pluginVersion, entries }`.
-- TreeEntry `id` is omitted on export. Import is append-only (never merge-by-name):
-- decode, reject a forward schemaVersion, mint ids, migrate, append at scope root.
--
-- The paste field holds 9,999 bytes. JSON that fits is the paste: it stays readable,
-- and a noisy payload's WD1 token can be longer than the JSON (base64 expands a
-- block that did not shrink). JSON over the cap is deflated to a WD1 token. Import
-- accepts either form, so older raw-JSON pastes still load.

local Store = require("src/store")
local Compress = require("src/compress")
local Text = require("src/text")
local DropDismissOn = require("src/drop_dismiss_on")

local Export = {}

-- Sole import gate: refuse only if schemaVersion is newer than this build.
Export.SCHEMA_VERSION = 1

-- Written on every export; never read, never branched on.
Export.PLUGIN_VERSION = "1.0.0"

-- ui.InputField hard cap. Guarded as UTF-8 bytes with no margin.
Export.MAX_BYTES = 9999

---@class Watchdog.ExportEntry
---@field kind "alert"|"group"
---@field name string
---@field enabled boolean
---@field graph LibNodeGraph.SerializedGraph|nil
---@field layout Watchdog.LayoutArray|nil
---@field children Watchdog.ExportEntry[]|nil

---@class Watchdog.ExportEnvelope
---@field schemaVersion integer
---@field pluginVersion string
---@field entries Watchdog.ExportEntry[]

---@class Watchdog.ImportReport
---@field entryCount integer
---@field unknownCount integer
---@field unknownTypes string[]
---@field message string|nil

---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

-- Deep-copies an Entry (or ExportEntry) subtree with TreeEntry `id` fields removed. Graph /
-- layout node ids are left untouched - they are graph-local and referenced by layout.
---@param entry Watchdog.Entry|Watchdog.ExportEntry
---@return Watchdog.ExportEntry
function Export.StripIds(entry)
    local copy = {
        kind = entry.kind,
        name = entry.name,
        enabled = entry.enabled ~= false,
        graph = entry.graph,
        layout = entry.layout,
    }
    if entry.children ~= nil then
        copy.children = {}
        for i, child in ipairs(entry.children) do
            copy.children[i] = Export.StripIds(child)
        end
    end
    return copy
end

---@param entries Watchdog.Entry[]|Watchdog.ExportEntry[]|nil
---@return Watchdog.ExportEnvelope
function Export.BuildEnvelope(entries)
    local out = {}
    for i, entry in ipairs(entries or {}) do
        out[i] = Export.StripIds(entry)
    end
    return {
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = Export.PLUGIN_VERSION,
        entries = out,
    }
end

---@param n integer
---@return string
local function oversizeMessage(n)
    return string.format(
        "Too large to export by copy-paste (%d of 9,999 characters). A file-based export is planned.",
        n)
end

---@param entries Watchdog.Entry[]|Watchdog.ExportEntry[]|nil
---@return boolean ok
---@return string jsonOrErr
function Export.Encode(entries)
    local c = codec()
    if c == nil then
        return false, "Watchdog could not read or create export JSON. Check that LibNodeGraph is enabled."
    end
    local envelope = Export.BuildEnvelope(entries)
    local ok, text = pcall(function() return c.encode(envelope) end)
    if not ok or type(text) ~= "string" then
        return false, "failed to encode export envelope"
    end
    if #text <= Export.MAX_BYTES then
        return true, text
    end
    local compressedOk, token = pcall(Compress.compress, text)
    if not compressedOk or type(token) ~= "string" then
        return false, "failed to compress export: " .. tostring(token)
    end
    if #token <= Export.MAX_BYTES then
        return true, token
    end
    return false, oversizeMessage(math.min(#text, #token))
end

---@param value any
---@return boolean
local function isEnvelope(value)
    if type(value) ~= "table" then return false end
    if type(value.schemaVersion) ~= "number" then return false end
    if type(value.pluginVersion) ~= "string" then return false end
    if type(value.entries) ~= "table" then return false end
    return true
end

-- schemaVersion is gated in Import, not here.
---@param text string
---@return boolean ok
---@return Watchdog.ExportEnvelope|string envelopeOrErr
function Export.Decode(text)
    if type(text) ~= "string" or text:match("%S") == nil then
        return false, "Paste an export first."
    end
    local c = codec()
    if c == nil then
        return false, "Watchdog could not read or create export JSON. Check that LibNodeGraph is enabled."
    end
    local payload = text
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed:sub(1, #Compress.PREFIX) == Compress.PREFIX then
        local inflatedOk, json = pcall(Compress.decompress, text)
        if not inflatedOk or type(json) ~= "string" then
            return false, "This compressed export is not valid (" .. tostring(json)
                .. "). Copy the full export from Watchdog and try again."
        end
        payload = json
    end
    local ok, value = pcall(function() return c.decode(payload) end)
    if not ok or not isEnvelope(value) then
        return false, "This export is not valid. Copy the full export from Watchdog and try again."
    end
    ---@cast value Watchdog.ExportEnvelope
    return true, value
end

---@param raw any
---@param fallback string
---@return string
local function plainName(raw, fallback)
    if type(raw) ~= "string" then return fallback end
    local name = Text.StripTags(raw)
    if name == "" then return fallback end
    return name
end

-- Mint ids without inserting. `used` claims ids so nested mints stay unique before append.
---@param doc Watchdog.Bucket
---@param used table<integer, boolean>
---@param exportEntry Watchdog.ExportEntry
---@return Watchdog.Entry
local function materializeEntry(doc, used, exportEntry)
    local function nextId()
        local id = Store.MintId(doc)
        while used[id] do id = id + 1 end
        used[id] = true
        return id
    end
    local id = nextId()
    if exportEntry.kind == "group" then
        local children = {}
        for i, child in ipairs(exportEntry.children or {}) do
            children[i] = materializeEntry(doc, used, child)
        end
        return {
            id = id,
            kind = "group",
            name = plainName(exportEntry.name, "Group"),
            enabled = exportEntry.enabled ~= false,
            children = children,
        }
    end
    Text.StripGraphText(exportEntry.graph)
    return {
        id = id,
        kind = "alert",
        name = plainName(exportEntry.name, "Alert"),
        enabled = exportEntry.enabled ~= false,
        graph = exportEntry.graph,
        layout = exportEntry.layout,
    }
end

---@param version integer|nil
---@param entries Watchdog.Entry[]
---@return Watchdog.Entry[]
local function migrateEntries(version, entries)
    -- Envelope schemaVersion already gated; keep this hook so Import stays mint-then-migrate.
    local _ = version
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" then
            if entry.kind == "alert" and type(entry.graph) == "table" then
                entry.layout = DropDismissOn.Apply(entry.graph, entry.layout)
            end
            if entry.children ~= nil then
                migrateEntries(version, entry.children)
            end
        end
    end
    return entries
end

---@param entry Watchdog.Entry
---@param registry LibNodeGraph.Registry
---@param types table<string, boolean>
---@param counts integer[]  # counts[1] = total unknown nodes
local function collectUnknown(entry, registry, types, counts)
    if entry.kind == "alert" and entry.graph ~= nil and LibNodeGraph ~= nil then
        local ok, graph = pcall(function()
            return LibNodeGraph.Deserialize(entry.graph, registry, { onUnknown = "placeholder" })
        end)
        if ok and graph ~= nil then
            for _, node in pairs(graph.nodes or {}) do
                if node.typeKey == LibNodeGraph.UNKNOWN_TYPE and node.unknown ~= nil then
                    counts[1] = counts[1] + 1
                    local t = node.unknown.type
                    if type(t) == "string" then types[t] = true end
                end
            end
        end
    end
    for _, child in ipairs(entry.children or {}) do
        collectUnknown(child, registry, types, counts)
    end
end

---@param entryCount integer
---@param unknownCount integer
---@param unknownTypes string[]
---@return string|nil
local function formatReportMessage(entryCount, unknownCount, unknownTypes)
    if unknownCount <= 0 then
        return string.format("Imported %d entr%s.", entryCount, entryCount == 1 and "y" or "ies")
    end
    local listed = table.concat(unknownTypes, ", ")
    return string.format(
        "Imported %d entr%s. %d unrecognized node type%s (%s) will not run those steps.",
        entryCount,
        entryCount == 1 and "y" or "ies",
        unknownCount,
        unknownCount == 1 and "" or "s",
        listed)
end

---@param doc Watchdog.Bucket
---@param text string
---@param opts { registry: LibNodeGraph.Registry|nil }|nil
---@return boolean ok
---@return Watchdog.ImportReport|string reportOrErr
function Export.Import(doc, text, opts)
    local ok, envelopeOrErr = Export.Decode(text)
    if not ok then
        return false, tostring(envelopeOrErr)
    end
    ---@cast envelopeOrErr Watchdog.ExportEnvelope
    local envelope = envelopeOrErr

    if envelope.schemaVersion > Export.SCHEMA_VERSION then
        return false, "This export needs a newer version of Watchdog. Update the plugin, then try again."
    end

    local used = {}
    local function claim(entries)
        for _, e in ipairs(entries or {}) do
            if type(e.id) == "number" then used[e.id] = true end
            if e.children ~= nil then claim(e.children) end
        end
    end
    claim(doc.entries)

    local minted = {}
    for i, exportEntry in ipairs(envelope.entries or {}) do
        if type(exportEntry) ~= "table" or (exportEntry.kind ~= "alert" and exportEntry.kind ~= "group") then
            return false, "Alert or group " .. tostring(i) .. " could not be read. Copy the export JSON again and retry."
        end
        minted[i] = materializeEntry(doc, used, exportEntry)
    end

    minted = migrateEntries(envelope.schemaVersion, minted)

    -- Append only after materialize+migrate succeed - import is atomic.
    for _, entry in ipairs(minted) do
        Store.InsertEntry(doc, entry, nil)
    end

    local unknownTypesSet = {}
    local counts = { 0 }
    local registry = opts and opts.registry
    if registry ~= nil then
        for _, entry in ipairs(minted) do
            collectUnknown(entry, registry, unknownTypesSet, counts)
        end
    end
    local unknownTypes = {}
    for t in pairs(unknownTypesSet) do
        unknownTypes[#unknownTypes + 1] = t
    end
    table.sort(unknownTypes)

    local report = {
        entryCount = #minted,
        unknownCount = counts[1],
        unknownTypes = unknownTypes,
        message = formatReportMessage(#minted, counts[1], unknownTypes),
    }
    return true, report
end

return Export
