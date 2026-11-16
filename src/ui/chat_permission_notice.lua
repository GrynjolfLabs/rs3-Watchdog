-- Shown after an import or a new alert that contains a chat node.
-- Closing it leaves that import or alert in place.
-- One sentence per AddText. A newline in one string draws as a missing glyph.

local Dialog = require("src/ui/dialog")

local ChatPermissionNotice = {}

local BODY = {
    "Only those nodes wait on chat permission.",
    "They do nothing until you grant it, and granting it later is enough.",
}

---@param parent any
---@param lead string
---@return any|nil
function ChatPermissionNotice.mount(parent, lead)
    return Dialog.mount(parent, {
        title = "Chat permission",
        width = 420,
        height = 220,
        content = function(win)
            win:AddText(lead)
            for _, paragraph in ipairs(BODY) do
                win:AddText(paragraph)
            end
        end,
        actions = {
            { label = "I understand", variant = "positive" },
        },
    })
end

return ChatPermissionNotice
