local luaunit = require("luaunit")
local newFakeEventSource = require("fake_event_source")

-- Popup.ICONS reads id.Sprite at load. Same cache ids as tests/test_popup.lua.
id = id or {}
id.Sprite = id.Sprite or {}
id.Sprite.RS3_ICON_CHECK_MARK_24PX_0 = 17127
id.Sprite.ICON_STAR_FILL = 12764
id.Sprite.COINS = 431
id.Sprite.EXCLAMATION_MARK = 937
id.Sprite.RS3_ICON_BOSS_COLLECTION_LOG_0 = 15064
id.Sprite.ICON_RIBBON_QUESTS_INACTIVE = 6953
id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_1_ACTIVE = 35246
id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_2_ACTIVE = 35247
id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_3_ACTIVE = 35248
id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_4_ACTIVE = 35249
id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_5_ACTIVE = 35250

local Popup = require("src/nodes/actions/popup")
local Toast = require("src/toast")

local globals = { "LibNodeGraph", "LibNodeGraphStd", "Event", "Plugin", "PluginPermissions",
    "prettyui", "id", "config", "PersistentDB", "Player", "Mouse", "LibPluginMenu",
    "shortestpath", "Watchdog", "PluginShutdown", "log", "print", "ui", "Vector4" }
local mainPath = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") .. "../main.lua"

TestMainTiming = {}

function TestMainTiming:setUp()
    self.saved = {}
    for _, name in ipairs(globals) do self.saved[name] = _G[name] end
    local serialize = require("serialize")
    LibNodeGraph = {
        NewRegistry = require("registry").new,
        NewGraph = require("graph").new,
        Serialize = serialize.Serialize,
        Deserialize = serialize.Deserialize,
        Json = require("json"),
        UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
    }
    LibNodeGraphStd = { Register = function(registry)
        for _, name in ipairs({ "flow", "boolean", "compare", "mathops", "convert", "stateful" }) do
            require(name).Register(registry)
        end
    end }
    self.events = newFakeEventSource()
    Event = self.events.source
    Plugin = { HasPermission = function() return false end }
    PluginPermissions = { httpAccess = 1, trackingAccess = 2 }
    prettyui = nil
    id = { Sprite = {}, Component = {}, Sound = { TOWN_CRIER_BELL_RING_1 = 2608 } }
    config = { Inv = { INV = { id = 93 }, BANK = { id = 95 } } }
    PersistentDB, Mouse, LibPluginMenu, shortestpath = nil, nil, nil, nil
    Player = { IsAvailable = function() return false end }
    log, print = function() end, function() end
    ui = { Interfaces = { GetComponent = function() return nil end } }
    Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }
    dofile(mainPath)
    self.runtime = Watchdog.editor.runtime
    self.graph = LibNodeGraph.NewGraph(Watchdog.editor.registry)
    self.runtime:AddAlert(999, "Popup timing regression", self.graph, true)
end

function TestMainTiming:tearDown()
    if Watchdog and Watchdog.Stop then Watchdog.Stop() end
    for _, name in ipairs(globals) do _G[name] = self.saved[name] end
end

function TestMainTiming:tick(counter)
    self.events:Push("Logic", { logicTick = counter })
end

function TestMainTiming:draw(seconds)
    self.events:Push("Draw", { timeDeltaSecs = seconds })
end

function TestMainTiming:firePopup()
    local node = self.graph:AddNode("action.popup", { body = "Keep this notification visible", hold = 4 })
    self.graph:FireInput(node, "in")
    return self.runtime.effects.queues[Popup.OWNER].active
end

function TestMainTiming:testLogicTicksDoNotAdvanceVisualEffectsAfterReload()
    local popup = self:firePopup()
    self:tick(1000000)
    self:tick(1000001)
    self:tick(2000000)
    luaunit.assertEquals(popup.state.anim.phase, "in")
    luaunit.assertEquals(popup.state.elapsed, 0)
    luaunit.assertIs(self.runtime.effects.queues[Popup.OWNER].active, popup)
end

function TestMainTiming:testPopupDrawsForConfiguredSecondsBeforeQueueAdvances()
    self:tick(10000)
    local first = self:firePopup()
    self:firePopup()
    local queue = self.runtime.effects.queues[Popup.OWNER]
    local second = queue.pending[1]
    local rectangles = 0
    local canvas = { width = 1920, AddRectangle = function() rectangles = rectangles + 1 end }

    -- Advance the Draw subscriber by four seconds.
    for _ = 1, 200 do self:draw(0.02) end
    luaunit.assertAlmostEquals(first.state.elapsed, 4, 0.000001)
    luaunit.assertEquals(first.state.anim.phase, "hold")
    luaunit.assertIs(queue.active, first)
    self.runtime.effects:Draw(canvas)
    luaunit.assertEquals(rectangles, 1)
    luaunit.assertEquals(second.state.elapsed, 0)

    for _ = 1, 16 do self:draw(0.02) end
    luaunit.assertEquals(first.state.anim.phase, "out")
    luaunit.assertIs(queue.active, first)
    for _ = 1, 20 do self:draw(0.02) end
    luaunit.assertIs(queue.active, second)
    luaunit.assertEquals(second.state.elapsed, 0)
    self:draw(0.02)
    luaunit.assertAlmostEquals(second.state.elapsed, 0.02, 0.000001)
end

function TestMainTiming:testVariableFrameDurationsUseSecondsWhileUiUnmounted()
    self:tick(50000)
    local popup = self:firePopup()
    self:draw(0.2)
    luaunit.assertAlmostEquals(popup.state.elapsed, 0.2, 0.000001)
    self:tick(50010)
    self:draw(0)
    luaunit.assertAlmostEquals(popup.state.elapsed, 0.2, 0.000001)
    self:draw(0.2)
    luaunit.assertAlmostEquals(popup.state.elapsed, 0.4, 0.000001)
    luaunit.assertEquals(popup.state.anim.phase, "hold")
end

function TestMainTiming:testToastLifetimeUsesTheSameSecondsClock()
    self:tick(70000)
    self.runtime.toast:Show("timed", { text = "Five seconds", ttl = 5 })
    self.runtime.toast:Show("sticky", { text = "Until dismissed", sticky = true })
    for _ = 1, 200 do self:draw(0.02) end
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 2)
    for _ = 1, 51 do self:draw(0.02) end
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
    luaunit.assertEquals(self.runtime.effects:StackCount(Toast.OWNER), 1)
    self.runtime.toast:Dismiss("sticky")
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 0)
end

function TestMainTiming:testRegisterAndClearHitTheLiveRegistry()
    local token, refusals = Watchdog:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 2608 } },
    })
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
    luaunit.assertErrorMsgContentEquals("Pack name is already held.", function()
        Watchdog:RegisterDataPack("Voice", nil)
    end)
    Watchdog:Clear("Voice")
    luaunit.assertErrorMsgContentEquals("Pack name is already held.", function()
        Watchdog:RegisterDataPack("Voice", nil)
    end)
    Watchdog:Clear(token)
    local again, againRefusals = Watchdog:RegisterDataPack("Voice", nil)
    luaunit.assertNotNil(again)
    luaunit.assertEquals(againRefusals, {})
end

function TestMainTiming:reloadWithPlayer(trackingId, db)
    if Watchdog and Watchdog.Stop then Watchdog.Stop() end
    self.events = newFakeEventSource()
    Event = self.events.source
    PersistentDB = db
    Player = {
        IsAvailable = function() return true end,
        GetTrackingID = function() return trackingId end,
        GetEntity = function()
            return { isValid = true, displayName = "Ada" }
        end,
    }
    dofile(mainPath)
    self.events:Push("Logic", { logicTick = 1 })
    self.runtime = Watchdog.editor.runtime
end

function TestMainTiming:testUnreadableCharacterBucketStaysOnDisk()
    local db = { data = { player_42 = "{not-json" } }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value)
        self.data[key] = value
        return true
    end
    local lines = {}
    log = function(message) lines[#lines + 1] = tostring(message) end
    self:reloadWithPlayer(42, db)

    luaunit.assertEquals(db.data.player_42, "{not-json")
    local saw = false
    for _, line in ipairs(lines) do
        if line:find("player_42", 1, true) and line:find("left on disk", 1, true) then
            saw = true
        end
    end
    luaunit.assertTrue(saw)
    local count = 0
    for _, alert in ipairs(self.runtime.alerts) do
        if alert.bucketKey == "player_42" then count = count + 1 end
    end
    luaunit.assertEquals(count, 0)
end

function TestMainTiming:testMissingCharacterBucketIsEmptyAndUnwritten()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value)
        self.data[key] = value
        return true
    end
    self:reloadWithPlayer(7, db)

    luaunit.assertNil(db.data.player_7)
    local count = 0
    for _, alert in ipairs(self.runtime.alerts) do
        if alert.bucketKey == "player_7" then count = count + 1 end
    end
    luaunit.assertEquals(count, 0)
end

function TestMainTiming:testFailedToastAnchorWriteLeavesThePreviousBytesAndOnlyLogs()
    local previous = "{\"dx\":4,\"dy\":5}"
    local data = { watchdog_toast_anchor = previous }
    local logged = {}
    local windows = 0
    log = function(message) logged[#logged + 1] = tostring(message) end
    prettyui = {
        Window = {
            new = function()
                windows = windows + 1
                return {}
            end,
        },
    }
    PersistentDB = {
        data = data,
        GetString = function(self, key) return self.data[key] end,
        SetString = function() return false end,
    }

    self.runtime.toast:ResetAnchor()

    luaunit.assertEquals(data.watchdog_toast_anchor, previous)
    luaunit.assertEquals(windows, 0)
    luaunit.assertStrContains(table.concat(logged, "\n"), "toast")
end

function TestMainTiming:testDurationIsIndependentOfFrameRate()
    for _, fps in ipairs({ 30, 60, 144 }) do
        self.runtime.effects:Clear()
        local popup = self:firePopup()
        for _ = 1, fps * 4 do self:draw(1 / fps) end
        luaunit.assertAlmostEquals(popup.state.elapsed, 4, 0.000001)
        luaunit.assertEquals(popup.state.anim.phase, "hold")
        for _ = 1, math.ceil(fps * 0.72) do self:draw(1 / fps) end
        luaunit.assertNil(self.runtime.effects.queues[Popup.OWNER].active)
    end
end

return TestMainTiming
