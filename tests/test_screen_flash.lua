-- Screen Flash pulse shape, counted lifetime, and pin list.
-- No Canvas. Show, Dismiss, and two-node independence go through the real effect registry.

local luaunit = require("luaunit")
local EffectRegistry = require("src/effects")
local ScreenFlash = require("src/nodes/actions/screen_flash")

TestScreenFlashAlphaAt = {}

-- With Rise 1 and Fall 1, rise is [0, 1) and fall is [1, 2). Fade is the fraction through that half.

function TestScreenFlashAlphaAt:testInstantRiseHoldsPeakForWholeRiseSegment()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 200, "instant", "instant", 1, 1), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0.5, 200, "instant", "instant", 1, 1), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0.999, 200, "instant", "instant", 1, 1), 200)
end

-- A 2s rise is still peak at 1.5s. The old fixed 1s segment would already be in the fall.
function TestScreenFlashAlphaAt:testInstantRiseHoldsPeakForTheWholeRise()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 200, "instant", "instant", 2, 1), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 200, "instant", "instant", 2, 1), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.999, 200, "instant", "instant", 2, 1), 200)
end

-- Fall 3s stays clear past the old 1s mark. t=4 is the next rise.
function TestScreenFlashAlphaAt:testInstantFallHoldsClearForTheWholeFall()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0.5, 200, "instant", "instant", 1, 3), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1, 200, "instant", "instant", 1, 3), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(2.5, 200, "instant", "instant", 1, 3), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(3.999, 200, "instant", "instant", 1, 3), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(4, 200, "instant", "instant", 1, 3), 200)
end

function TestScreenFlashAlphaAt:testInstantFallDropsToZeroForWholeFallSegment()
    luaunit.assertEquals(ScreenFlash.AlphaAt(1, 200, "instant", "instant", 1, 1), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 200, "instant", "instant", 1, 1), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.999, 200, "instant", "instant", 1, 1), 0)
end

function TestScreenFlashAlphaAt:testInstantInstantIsASquareWaveAcrossCycles()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 255, "instant", "instant", 1, 1), 255)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 255, "instant", "instant", 1, 1), 0)
    -- The wave repeats. How many pairs actually play is a separate lifetime question.
    luaunit.assertEquals(ScreenFlash.AlphaAt(2, 255, "instant", "instant", 1, 1), 255)
    luaunit.assertEquals(ScreenFlash.AlphaAt(3.5, 255, "instant", "instant", 1, 1), 0)
end

function TestScreenFlashAlphaAt:testFadeRiseRampsLinearlyAndMeetsTheFallBoundary()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 250, "fade", "instant", 1, 1), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0.5, 250, "fade", "instant", 1, 1), 125)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1, 250, "fade", "instant", 1, 1), 0)
end

function TestScreenFlashAlphaAt:testFadeFallRampsLinearlyFromPeakToTheNextRise()
    luaunit.assertEquals(ScreenFlash.AlphaAt(1, 250, "instant", "fade", 1, 1), 250)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 250, "instant", "fade", 1, 1), 125)
    luaunit.assertEquals(ScreenFlash.AlphaAt(2, 250, "instant", "fade", 1, 1), 250)
end

-- Fade rise over 4s is clear at the start and half peak at 2s. t=4 is the instant fall.
function TestScreenFlashAlphaAt:testFadeRiseRampsAcrossTheRiseDuration()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 200, "fade", "instant", 4, 2), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(2, 200, "fade", "instant", 4, 2), 100)
    luaunit.assertEquals(ScreenFlash.AlphaAt(4, 200, "fade", "instant", 4, 2), 0)
end

-- Fade fall over 4s starts at peak when the rise ends and is clear as the next rise begins.
function TestScreenFlashAlphaAt:testFadeFallRampsAcrossTheFallDuration()
    luaunit.assertEquals(ScreenFlash.AlphaAt(2, 200, "instant", "fade", 2, 4), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(4, 200, "instant", "fade", 2, 4), 100)
    luaunit.assertEquals(ScreenFlash.AlphaAt(6, 200, "instant", "fade", 2, 4), 200)
end

function TestScreenFlashAlphaAt:testNegativeRiseOrFallCountsAsZero()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 200, "instant", "instant", -3, 2), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 200, "instant", "instant", -3, 2), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 200, "instant", "instant", 2, -3), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 200, "instant", "instant", 2, -3), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 200, "instant", "instant", -1, -1), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(5, 200, "fade", "fade", 0, 0), 0)
end

TestScreenFlashLifetime = {}

-- Two pairs of 1s rise + 1s fall last 4s. 3.5s is still inside the second pair.
function TestScreenFlashLifetime:testNonStickyEndsWhenElapsedReachesTheCycleCount()
    luaunit.assertTrue(ScreenFlash.IsLive(3.5, 1, 1, 2, false))
    luaunit.assertFalse(ScreenFlash.IsLive(4, 1, 1, 2, false))
end

-- Rise -4 counts as 0, so one pair is the 2s fall. t=1.5 is still in that fall.
function TestScreenFlashLifetime:testNegativeRiseOrFallCountsAsZero()
    luaunit.assertTrue(ScreenFlash.IsLive(1.5, -4, 2, 1, false))
    luaunit.assertFalse(ScreenFlash.IsLive(2, -4, 2, 1, false))
    luaunit.assertTrue(ScreenFlash.IsLive(1.5, 2, -4, 1, false))
    luaunit.assertFalse(ScreenFlash.IsLive(2, 2, -4, 1, false))
end

-- Sticky keeps playing at Cycles 0 and long after a counted flash would have ended.
function TestScreenFlashLifetime:testStickyIgnoresCyclesUntilDismiss()
    luaunit.assertTrue(ScreenFlash.IsLive(0, 1, 1, 0, true))
    luaunit.assertTrue(ScreenFlash.IsLive(100, 1, 1, 3, true))
    luaunit.assertTrue(ScreenFlash.IsLive(0, 0, 0, 0, true))
end

-- One full pair of Rise 2 and Fall 2 is 4s. Half of the next Rise is 1s, so 1.5 ends at 5s.
function TestScreenFlashLifetime:testFractionEndsInsideTheNextPair()
    luaunit.assertTrue(ScreenFlash.IsLive(4.999, 2, 2, 1.5, false))
    luaunit.assertFalse(ScreenFlash.IsLive(5, 2, 2, 1.5, false))
end

-- Two full pairs of Rise 1 and Fall 1 are 4s. Half of the next Rise is 0.5s, so 2.5 ends at 4.5s.
function TestScreenFlashLifetime:testTwoAndAHalfCyclesEndHalfwayThroughTheNextRise()
    luaunit.assertTrue(ScreenFlash.IsLive(4.499, 1, 1, 2.5, false))
    luaunit.assertFalse(ScreenFlash.IsLive(4.5, 1, 1, 2.5, false))
end

function TestScreenFlashLifetime:testZeroCyclesEndsBeforeADraw()
    luaunit.assertFalse(ScreenFlash.IsLive(0, 1, 1, 0, false))
end

function TestScreenFlashLifetime:testNegativeCycleCountEndsBeforeADraw()
    luaunit.assertFalse(ScreenFlash.IsLive(0, 1, 1, -3, false))
    luaunit.assertFalse(ScreenFlash.IsLive(1, 2, 2, -1, false))
end

function TestScreenFlashLifetime:testZeroLengthCycleEndsBeforeADraw()
    luaunit.assertFalse(ScreenFlash.IsLive(0, 0, 0, 3, false))
    luaunit.assertFalse(ScreenFlash.IsLive(0, -2, -5, 4, false))
end

TestScreenFlashClock = {}

local function pulse(inShape, outShape)
    return ScreenFlash.BuildHandle(
        { r = 255, g = 0, b = 0, a = 200 },
        inShape, outShape,
        1, 1, 3, false)
end

function TestScreenFlashClock:testSameWallTimeFromDifferentFrameSplits()
    local fine = pulse("fade", "instant")
    fine.update(0.25)
    fine.update(0.25)
    local coarse = pulse("fade", "instant")
    coarse.update(0.5)
    luaunit.assertEquals(fine.state.elapsed, 0.5)
    luaunit.assertEquals(coarse.state.elapsed, 0.5)
    luaunit.assertEquals(fine.state.alpha, 100)
    luaunit.assertEquals(coarse.state.alpha, 100)
end

function TestScreenFlashClock:testLargeDeltaLandsOnTheSamePhaseAsElapsedTime()
    local handle = pulse("fade", "fade")
    handle.update(2.5)
    luaunit.assertEquals(handle.state.elapsed, 2.5)
    luaunit.assertEquals(handle.state.alpha, 100)
end

-- One pair of 1s+1s. t=1.5 is the instant fall (clear, still live). t=2 has reached the count.
function TestScreenFlashClock:testNonStickyHandleEndsWhenElapsedReachesTheCycleCount()
    local handle = ScreenFlash.BuildHandle(
        { r = 255, g = 0, b = 0, a = 200 },
        "instant", "instant",
        1, 1, 1, false)
    luaunit.assertTrue(handle.update(1.5))
    luaunit.assertEquals(handle.state.alpha, 0)
    luaunit.assertFalse(handle.update(0.5))
end

function TestScreenFlashClock:testHandleAlphaFollowsTheRiseAndFallDurations()
    local handle = ScreenFlash.BuildHandle(
        { a = 200 }, "fade", "fade",
        4, 4, 1, false)
    luaunit.assertTrue(handle.update(2))
    luaunit.assertEquals(handle.state.alpha, 100)
    luaunit.assertTrue(handle.update(4))
    luaunit.assertEquals(handle.state.alpha, 100)
    luaunit.assertFalse(handle.update(2))
end

function TestScreenFlashClock:testZeroCyclesAndAZeroLengthCycleEndBeforeADraw()
    local zeroCount = ScreenFlash.BuildHandle(
        { a = 200 }, "instant", "instant",
        1, 1, 0, false)
    luaunit.assertFalse(zeroCount.update(0.016))
    luaunit.assertEquals(zeroCount.state.alpha, 0)

    local zeroLength = ScreenFlash.BuildHandle(
        { a = 200 }, "instant", "instant",
        0, 0, 3, false)
    luaunit.assertFalse(zeroLength.update(0.016))

    local negative = ScreenFlash.BuildHandle(
        { a = 200 }, "instant", "instant",
        -2, -2, -1, false)
    luaunit.assertFalse(negative.update(0.016))
end

function TestScreenFlashClock:testStickyHandleKeepsCyclingWhenTheCountIsZero()
    local handle = ScreenFlash.BuildHandle(
        { a = 200 }, "instant", "instant",
        1, 1, 0, true)
    luaunit.assertTrue(handle.update(1.5))
    luaunit.assertEquals(handle.state.alpha, 0)
    luaunit.assertTrue(handle.update(0.5))
    luaunit.assertEquals(handle.state.alpha, 200)
end

TestScreenFlashPins = {}

function TestScreenFlashPins:testPinOrderDefaultsAndWireableDurations()
    local reg = {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
    ScreenFlash.Register(reg, {
        effects = { Dismiss = function() end, PushStack = function() end },
        mouseActivityTick = 0,
        keyboardActivityTick = 0,
    })
    local pins = reg.types["action.screen_flash"].pins
    local expected = {
        "show", "dismiss", "color", "inShape", "rise", "outShape", "fall", "cycles", "sticky",
    }
    luaunit.assertEquals(#pins, #expected)
    for i, name in ipairs(expected) do
        luaunit.assertEquals(pins[i].name, name)
    end

    local byName = {}
    for _, pin in ipairs(pins) do byName[pin.name] = pin end

    luaunit.assertEquals(byName.rise.kind, "data")
    luaunit.assertEquals(byName.rise.direction, "in")
    luaunit.assertEquals(byName.rise.dataType, "number")
    luaunit.assertEquals(byName.rise.default, 1)
    luaunit.assertEquals(byName.rise.label, "Rise")

    luaunit.assertEquals(byName.fall.dataType, "number")
    luaunit.assertEquals(byName.fall.default, 1)
    luaunit.assertEquals(byName.fall.label, "Fall")

    luaunit.assertEquals(byName.cycles.dataType, "number")
    luaunit.assertEquals(byName.cycles.default, 3)
    luaunit.assertEquals(byName.cycles.label, "Cycles")

    luaunit.assertEquals(byName.sticky.kind, "data")
    luaunit.assertEquals(byName.sticky.direction, "in")
    luaunit.assertEquals(byName.sticky.dataType, "bool")
    luaunit.assertEquals(byName.sticky.default, false)
    luaunit.assertEquals(byName.sticky.label, "Sticky")

    luaunit.assertEquals(byName.inShape.dataType, "shape")
    luaunit.assertEquals(byName.outShape.dataType, "shape")
    luaunit.assertNil(byName.dismissOn)
    luaunit.assertNil(byName.hold)
end

local function registeredRun()
    local effects = EffectRegistry.new()
    local runtime = {
        effects = effects,
        mouseActivityTick = 0,
        keyboardActivityTick = 0,
    }
    local reg = {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
    ScreenFlash.Register(reg, runtime)
    return effects, runtime, reg.types["action.screen_flash"].run
end

local function show(run, values, state)
    state = state or {}
    run({
        state = state,
        exec = "show",
        In = function(_, name) return values[name] end,
    })
    return state
end

TestScreenFlashRun = {}

function TestScreenFlashRun:testWiredRiseDrivesTheLiveFlash()
    local _, _, run = registeredRun()
    local state = show(run, {
        color = { r = 255, g = 0, b = 0, a = 200 },
        inShape = "fade",
        outShape = "instant",
        rise = 4,
        fall = 2,
        cycles = 1,
        sticky = false,
    })
    luaunit.assertTrue(state.handle.update(2))
    luaunit.assertEquals(state.handle.state.alpha, 100)
end

function TestScreenFlashRun:testWiredZeroCyclesEndsBeforeADraw()
    local _, _, run = registeredRun()
    local state = show(run, {
        color = { a = 200 },
        inShape = "instant",
        outShape = "instant",
        rise = 1,
        fall = 1,
        cycles = 0,
        sticky = false,
    })
    luaunit.assertFalse(state.handle.update(0.016))
end

function TestScreenFlashRun:testWiredStickyIgnoresAZeroCycleCount()
    local _, _, run = registeredRun()
    local state = show(run, {
        color = { a = 200 },
        inShape = "instant",
        outShape = "instant",
        rise = 1,
        fall = 1,
        cycles = 0,
        sticky = true,
    })
    luaunit.assertTrue(state.handle.update(2.5))
    luaunit.assertEquals(state.handle.state.alpha, 200)
end

function TestScreenFlashRun:testMissingDurationsPlayThreeOneSecondPairs()
    local _, _, run = registeredRun()
    local state = show(run, {
        color = { a = 200 },
        inShape = "fade",
        outShape = "instant",
    })
    luaunit.assertTrue(state.handle.update(0.5))
    luaunit.assertEquals(state.handle.state.alpha, 100)
    luaunit.assertTrue(state.handle.update(5.4))
    luaunit.assertFalse(state.handle.update(0.2))
end

function TestScreenFlashRun:testDismissClearsThatNodesFlash()
    local effects, _, run = registeredRun()
    local state = show(run, {
        color = { a = 200 },
        rise = 1, fall = 1, cycles = 3, sticky = false,
    })
    luaunit.assertEquals(effects:StackCount(state), 1)
    run({ state = state, exec = "dismiss", In = function() end })
    luaunit.assertEquals(effects:StackCount(state), 0)
    luaunit.assertNil(state.handle)
end

function TestScreenFlashRun:testShowReplacesThatNodesOwnFlash()
    local effects, _, run = registeredRun()
    local values = {
        color = { a = 200 },
        inShape = "instant",
        outShape = "instant",
        rise = 1, fall = 1, cycles = 3, sticky = true,
    }
    local state = show(run, values)
    local first = state.handle
    first.update(1.25)
    show(run, values, state)
    luaunit.assertEquals(effects:StackCount(state), 1)
    luaunit.assertTrue(state.handle ~= first)
    luaunit.assertEquals(state.handle.state.elapsed, 0)
end

function TestScreenFlashRun:testTwoScreenFlashNodesStayIndependent()
    local effects, _, run = registeredRun()
    local values = {
        color = { a = 200 },
        rise = 1, fall = 1, cycles = 3, sticky = true,
    }
    local first = show(run, values)
    local second = show(run, values)
    luaunit.assertEquals(effects:StackCount(first), 1)
    luaunit.assertEquals(effects:StackCount(second), 1)
    run({ state = first, exec = "dismiss", In = function() end })
    luaunit.assertEquals(effects:StackCount(first), 0)
    luaunit.assertEquals(effects:StackCount(second), 1)
    luaunit.assertTrue(second.handle.update(0.5))
    luaunit.assertEquals(second.handle.state.alpha, 200)
end

return TestScreenFlashAlphaAt
