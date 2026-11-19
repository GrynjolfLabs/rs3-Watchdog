-- Edit shortcuts. The client cannot consume a key, so the game sees these keys too.
-- GameKey names and the Ctrl check are not confirmed against the API stubs, so each lookup
-- tries the likely names.

local EditorKeys = {}

local function gameKey(...)
    if GameKey == nil then return nil end
    for _, name in ipairs({ ... }) do
        local ok, v = pcall(function() return GameKey[name] end)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

local function isTrue(fn)
    local ok, v = pcall(fn)
    return ok and v == true
end

function EditorKeys.IsShiftDown()
    return isTrue(function() return Keyboard.IsShiftDown() end)
end

--- Keyboard API first, then a field on the key event, then the held Ctrl key.
function EditorKeys.IsCtrlDown(keyEvent)
    if isTrue(function() return Keyboard.IsControlDown() end)
        or isTrue(function() return Keyboard.IsCtrlDown() end)
        or isTrue(function() return keyEvent.ctrl end)
        or isTrue(function() return keyEvent.control end) then
        return true
    end
    local ctrl = gameKey("CONTROL", "CTRL", "LCONTROL", "LEFT_CONTROL")
    return ctrl ~= nil and isTrue(function() return prettyui.KeybindField.IsDown({ ctrl }) end)
end

local CTRL_ACTIONS = { C = "copy", X = "cut", V = "paste", Y = "redo", Z = "undo" }

---@return string|nil   # "undo" | "redo" | "cut" | "copy" | "paste" | "delete"
function EditorKeys.ActionFor(keyEvent)
    local ok, key = pcall(function() return keyEvent.gameKey end)
    if not ok or key == nil then return nil end
    if key == gameKey("DELETE", "DEL") then return "delete" end
    if not EditorKeys.IsCtrlDown(keyEvent) then return nil end
    for letter, action in pairs(CTRL_ACTIONS) do
        if key == gameKey(letter, "KEY_" .. letter) then
            if action == "undo" and EditorKeys.IsShiftDown() then return "redo" end
            return action
        end
    end
    return nil
end

return EditorKeys
