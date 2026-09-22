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

-- runtime.lua and the node files are exercised against a real Graph/Registry, so
-- LibNodeGraph (a sibling deployed folder, see CLAUDE.md) must be on the path too.
package.path = rootDir .. "?.lua;" .. testsDir .. "?.lua;" .. rootDir .. "../LibNodeGraph/?.lua;" .. package.path

local luaunit = require("luaunit")

require("test_text")
require("test_util")
require("test_iface_scale")
require("test_matcher")
require("test_runtime")
require("test_poll")
require("test_player_scoping")
require("test_store")
require("test_export")
require("test_chat_types")
require("test_game_message")
require("test_player_chat")
require("test_logic_triggers")
require("test_location")
require("test_skill")
require("test_inventory")
require("test_inv_viewer")
require("test_entity_spawn")
require("test_node")
require("test_placeholder")
require("test_controls")
require("test_widgets")
require("test_widget_draw")
require("test_coordgrid_control")
require("test_scalar_control")
require("test_enum_control")
require("test_matcher_control")
require("test_swatch_control")
require("test_capture_control")
require("test_capture_arm")
require("test_mode_control")
require("test_unavailable")
require("test_palette")
require("test_manager")
require("test_dialog")
require("test_import_export")
require("test_multiplexer")
require("test_effects")
require("test_screen_flash")
require("test_popup")
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
require("test_custom_sound")
require("test_alert_toggle")
require("test_view")
require("test_wire")
require("test_graph_editor")
require("test_ui_layout")
require("test_window_chrome")

os.exit(luaunit.LuaUnit.run())
