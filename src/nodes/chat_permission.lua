-- One chat-permission flag for every node that needs chatAccess.
-- Plugin.HasPermission is read when a node module binds, then OptionalPermissionChanged
-- flips that same flag. The Palette and the Game Message action share it, so a grant
-- or revoke updates every gated row without reloading Watchdog.
--
-- The payload we honor is { permission, enabled }. Any other payload re-reads
-- HasPermission, which covers a client that updates the permission query before it
-- notifies.
--
-- ChatMessage arrives only when chatAccess is granted, so the Game Message and Player
-- Chat triggers have nothing to run until then. Their gate only keeps them off the
-- Palette. A node already on a graph stays registered.

local Gates = require("src/nodes/gates")

local REASON = "needs chat permission"

-- A saved graph stores the node type on `type`. A live graph uses typeKey.
local GATED_TYPES = {
    ["trigger.game_message"] = true,
    ["trigger.player_chat"] = true,
    ["action.game_message"] = true,
}

local ChatPermission = {}
ChatPermission.REASON = REASON

local granted = false
local subscribedChannel = nil

local function readChatPermission()
    if Plugin == nil or Plugin.HasPermission == nil or PluginPermissions == nil then
        return false
    end
    return Plugin.HasPermission(PluginPermissions.chatAccess) == true
end

---@param ev table|userdata|nil
---@return boolean
local function grantFromEvent(ev)
    -- Event payloads are userdata in the client and tables in tests; accept both.
    local kind = type(ev)
    if (kind == "table" or kind == "userdata") and ev.enabled ~= nil then
        local chatName = (PluginPermissions ~= nil and PluginPermissions.chatAccess) or "chatAccess"
        if ev.permission == chatName or ev.permission == "chatAccess" then
            return ev.enabled == true
        end
    end
    return readChatPermission()
end

local function onChanged(ev)
    granted = grantFromEvent(ev)
end

---@return boolean
function ChatPermission.Granted()
    return granted
end

---@param graph table|nil
---@return boolean
function ChatPermission.GraphRequires(graph)
    if type(graph) ~= "table" or type(graph.nodes) ~= "table" then
        return false
    end
    for _, node in pairs(graph.nodes) do
        if type(node) == "table" and GATED_TYPES[node.type] then
            return true
        end
    end
    return false
end

-- Re-read the current grant and subscribe once per event channel. Later binds in the
-- same load share the flag; a test that installs a new Event gets a new subscription.
function ChatPermission.Refresh()
    granted = readChatPermission()
    if Event == nil then
        return
    end
    ---@diagnostic disable-next-line: undefined-field
    local channel = Event.OptionalPermissionChanged
    if channel == nil or channel == subscribedChannel then
        return
    end
    subscribedChannel = channel
    channel.Subscribe("watchdog.chat_permission", onChanged)
end

---@param typeKey string
function ChatPermission.Bind(typeKey)
    ChatPermission.Refresh()
    Gates.Bind(typeKey, function()
        if not granted then return REASON end
    end)
end

return ChatPermission
