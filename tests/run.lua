-- Test entry point. Run from anywhere with a standalone Lua interpreter:
--   lua Watchdog/tests/run.lua
-- Exit code is 0 on success, non-zero on any test failure (suitable for CI).

local function scriptDir()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("^@(.*)$") or ""
    return path:match("(.*[/\\])") or "./"
end

local testsDir = scriptDir()
local rootDir = testsDir .. "../"

-- Tests use the real graph libraries. Put LibNodeGraph and LibNodeGraphStd
-- in sibling folders or on LUA_PATH. The main checkout is one level below rs3.
-- A worktree at .worktrees/<branch> is two levels further down, so also search there.
package.path = rootDir .. "?.lua;" .. testsDir .. "?.lua;"
    .. rootDir .. "../LibNodeGraph/?.lua;"
    .. rootDir .. "../../../LibNodeGraph/?.lua;"
    .. package.path
package.path = rootDir .. "../LibNodeGraphStd/?.lua;"
    .. rootDir .. "../../../LibNodeGraphStd/?.lua;"
    .. package.path

-- chat_types.lua names client ChatType enum members. The stub file is valid Lua.
local function existingFile(path)
    local handle = io.open(path, "r")
    if handle == nil then return nil end
    handle:close()
    return path
end
local chatStub = existingFile(rootDir .. "../runescape-api-stubs/generated/game/chat.lua")
    or existingFile(rootDir .. "../../../runescape-api-stubs/generated/game/chat.lua")
if chatStub == nil then
    error("ChatType stub not found next to this plugin")
end
dofile(chatStub)

local luaunit = require("luaunit")

-- Client global. notices.lua logs at file scope, and the hub panel requires it.
if type(log) ~= "function" then
    function log() end
end

require("test_text")
require("test_util")
require("test_iface_scale")
require("test_matcher")
require("test_runtime")
require("test_poll")
require("test_player_scoping")
require("test_store")
require("test_presets")
require("test_preset_labels")
require("test_preset_copy")
require("test_preset_dialogs")
require("test_packs")
require("test_pack_sound")
require("test_sound_effect_value")
require("test_pack_audio")
require("test_pack_alerts")
require("test_starter_alerts")
require("test_export")
require("test_chat_types")
require("test_game_message")
require("test_game_message_action")
require("test_player_chat")
require("test_logic_triggers")
require("test_player_input")
require("test_location")
require("test_skill")
require("test_resource")
require("test_inventory")
require("test_inv_viewer")
require("test_entity_spawn")
require("test_restricted")
require("test_content_layer")
require("test_node")
require("test_placeholder")
require("test_controls")
require("test_widgets")
require("test_number_spinner")
require("test_widget_draw")
require("test_coordgrid_control")
require("test_scalar_control")
require("test_enum_control")
require("test_bool_control")
require("test_compare")
require("test_math_operation")
require("test_matcher_control")
require("test_swatch_control")
require("test_capture_control")
require("test_capture_arm")
require("test_mode_control")
require("test_unavailable")
require("test_palette")
require("test_palette_gates")
require("test_manager")
require("test_scope_edits")
require("test_dialog")
require("test_import_export")
require("test_multiplexer")
require("test_shell")
require("test_notices")
require("test_release_note_body")
require("test_effects")
require("test_screen_flash")
require("test_drop_dismiss_on")
require("test_popup")
require("test_main_timing")
require("test_color")
require("test_color_popup")
require("test_infobox")
require("test_infobox_node")
require("test_screen_marker_capture")
require("test_screen_marker")
require("test_object_marker_capture")
require("test_object_marker")
require("test_toast")
require("test_sound")
require("test_shortest_path")
require("test_custom_sound")
require("test_alert_toggle")
require("test_alert_visuals")
require("test_view")
require("test_wire")
require("test_canvas_clip")
require("test_graph_editor")
require("test_node_edit")
require("test_ui_layout")
require("test_window_chrome")
require("test_theme_font")

os.exit(luaunit.LuaUnit.run())
