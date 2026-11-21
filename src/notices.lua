-- Seen ids for one-shot notices. PrettyUI mount is src/ui/notice_dialog.lua.
-- Notices.shared is the client object. Notices.new stays so tests can build
-- another instance and stand in for a plugin reload.
-- A failed write still counts as seen until the plugin unloads, so the dialog
-- does not return on every open. The next load reads the database again.

local ReleaseNotes = require("src/release_notes")

---@class Watchdog.ReleaseNoteImage
---@field image string path under resources/images, without the extension
---@field width integer source width in pixels
---@field height integer source height in pixels

---@class Watchdog.ReleaseNoteTitle
---@field title string

---@class Watchdog.ReleaseNoteBullets
---@field bullets string[]

---@alias Watchdog.ReleaseNoteParagraph string|Watchdog.ReleaseNoteImage|Watchdog.ReleaseNoteTitle|Watchdog.ReleaseNoteBullets

---@class Watchdog.ReleaseNote
---@field version string
---@field paragraphs Watchdog.ReleaseNoteParagraph[]

---@class Watchdog.ReleaseNoteView
---@field version string
---@field paragraphs Watchdog.ReleaseNoteParagraph[]
---@field id string

---@class Watchdog.NoticeOffer
---@field kind "whats-new"|"getting-started"
---@field ids string[]
---@field entries Watchdog.ReleaseNoteView[]|nil

---@class Watchdog.Notices
---@field catalog Watchdog.ReleaseNote[]
---@field seen table<string, boolean>
---@field hold boolean
---@field loaded boolean
---@field canWrite boolean
local Notices = {}
Notices.__index = Notices

Notices.KEY = "watchdog_seen_notices"
Notices.TIPS_ID = "editor-tips"

---@return LibNodeGraph.Codec
local function json()
    return LibNodeGraph.Json.Default
end

---@param message string
local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

---@param version string
---@return string
function Notices.ReleaseId(version)
    return "release:" .. version
end

---@param catalog Watchdog.ReleaseNote[]|nil
---@param seen table<string, boolean>|nil
---@return Watchdog.ReleaseNoteView[]
function Notices.UnseenReleases(catalog, seen)
    local out = {}
    seen = seen or {}
    for i = #catalog, 1, -1 do
        local entry = catalog[i]
        local id = Notices.ReleaseId(entry.version)
        if seen[id] ~= true then
            out[#out + 1] = {
                version = entry.version,
                paragraphs = entry.paragraphs,
                id = id,
            }
        end
    end
    return out
end

---@param decoded any
---@return string[]|nil
local function idList(decoded)
    if type(decoded) ~= "table" then return nil end
    local n = 0
    for k, v in pairs(decoded) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return nil end
        if type(v) ~= "string" or v == "" then return nil end
        n = n + 1
    end
    if n ~= #decoded then return nil end
    return decoded
end

---@param seen table<string, boolean>
---@return string[]
local function sortedIds(seen)
    local ids = {}
    for id, on in pairs(seen) do
        if on then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

-- Missing key is an empty list and may be written. Unreadable text stays as
-- stored: canWrite stays false so a later dismiss cannot replace it.
function Notices:Load()
    if self.loaded then return end
    self.loaded = true
    self.seen = {}
    self.canWrite = false

    if PersistentDB == nil then
        report("seen notices unreadable - no PersistentDB")
        return
    end

    local text
    local got, getErr = pcall(function()
        text = PersistentDB:GetString(Notices.KEY)
    end)
    if not got then
        report("seen notices unreadable - " .. tostring(getErr))
        return
    end
    if text == nil or text == "" then
        self.canWrite = true
        return
    end
    if type(text) ~= "string" then
        report("seen notices unreadable - not a string")
        return
    end

    local decodedOk, decoded = pcall(function()
        return json().decode(text)
    end)
    if not decodedOk then
        report("seen notices unreadable - " .. tostring(decoded))
        return
    end
    local ids = idList(decoded)
    if ids == nil then
        report("seen notices unreadable - expected a JSON array of strings")
        return
    end
    for _, id in ipairs(ids) do
        self.seen[id] = true
    end
    self.canWrite = true
end

---@return boolean ok
---@return any err
function Notices:Save()
    if not self.canWrite then
        return false, "seen notices were not written"
    end
    if PersistentDB == nil then
        return false, "seen notices were not written"
    end
    local encodedOk, text = pcall(function()
        return json().encode(sortedIds(self.seen))
    end)
    if not encodedOk or type(text) ~= "string" then
        return false, text
    end
    -- False, nil, and a throw leave the previous bytes. A true return is the save.
    local setOk, stored = pcall(function()
        return PersistentDB:SetString(Notices.KEY, text)
    end)
    if not setOk or stored ~= true then
        return false, stored
    end
    return true
end

--- Failed writes stay in `seen` for this plugin session. The log line is the
--- signal that the database did not change.
---@param ids string[]
---@return boolean ok
function Notices:MarkSeen(ids)
    self:Load()
    for _, id in ipairs(ids) do
        self.seen[id] = true
    end
    local ok, err = self:Save()
    if not ok then
        report("seen notices could not be saved, kept for this session - " .. tostring(err))
    end
    return ok
end

-- Load first. The hub button can run before any window open, while canWrite
-- is still false and seen is still empty. Save would bail, and the next open
-- would read the old ids back.
function Notices:ResetAllPopups()
    self:Load()
    self.seen = {}
    local ok, err = self:Save()
    if not ok then
        report("seen notices could not be reset, kept for this session - " .. tostring(err))
    end
end

---@param opts { catalog: Watchdog.ReleaseNote[]|nil }|nil
---@return Watchdog.Notices
function Notices.new(opts)
    opts = opts or {}
    return setmetatable({
        catalog = opts.catalog or {},
        seen = {},
        hold = false,
        loaded = false,
        canWrite = false,
    }, Notices)
end

---@param input { editorTop: boolean|nil, dialogOpen: boolean|nil }|nil
---@return Watchdog.NoticeOffer|nil
function Notices:OnWindowOpen(input)
    self:Load()
    input = input or {}
    local editorTop = input.editorTop == true
    if not editorTop then
        self.hold = false
    end
    if input.dialogOpen == true then
        return nil
    end

    local releases = Notices.UnseenReleases(self.catalog, self.seen)
    if #releases > 0 then
        if editorTop then
            self.hold = true
        end
        local ids = {}
        for i, entry in ipairs(releases) do
            ids[i] = entry.id
        end
        return { kind = "whats-new", ids = ids, entries = releases }
    end

    if editorTop and not self.hold and self.seen[Notices.TIPS_ID] ~= true then
        return { kind = "getting-started", ids = { Notices.TIPS_ID } }
    end
    return nil
end

--- A hidden shell is about to show, and that onShow is the window open.
--- An already-visible shell does not change visibility, so this is the editor entry.
---@param shellWasVisible boolean
---@param input { dialogOpen: boolean|nil }|nil
---@return Watchdog.NoticeOffer|nil
function Notices:OnOpenAlert(shellWasVisible, input)
    if shellWasVisible ~= true then return nil end
    self:Load()
    input = input or {}
    if input.dialogOpen == true then return nil end
    if self.seen[Notices.TIPS_ID] == true then return nil end
    return { kind = "getting-started", ids = { Notices.TIPS_ID } }
end

function Notices:OnNavBack()
    self.hold = false
end

---@type Watchdog.Notices
Notices.shared = Notices.new({ catalog = ReleaseNotes })

return Notices
