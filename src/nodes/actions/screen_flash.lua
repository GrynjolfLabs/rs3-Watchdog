local Controls = require("src/ui/controls")

local ScreenFlash = {}

-- A missing or negative length is no time in that segment. The pin default of 1
-- lives on the node, not here, so a caller that omits a duration gets a zero-length segment.
local function nonNegative(value)
    local n = tonumber(value)
    if n == nil or n < 0 then return 0 end
    return n
end

-- `or` would turn a wired 0 into the default. Cycles 0 and Rise 0 are real values.
local function ifNil(value, default)
    if value == nil then return default end
    return value
end

Controls.Register("shape", {
    widget = "enum",
    choices = {
        { value = "instant", label = "Instant" },
        { value = "fade",    label = "Fade" },
    },
})

Controls.Register("dismissOn", {
    widget = "enum",
    choices = {
        { value = "none",     label = "None" },
        { value = "mouse",    label = "Mouse" },
        { value = "keyboard", label = "Keyboard" },
        { value = "both",     label = "Both" },
    },
})

local DEFAULT_COLOR = { r = 255, g = 0, b = 0, a = 127 }

function ScreenFlash.AlphaAt(elapsed, peak, inShape, outShape, rise, fall)
    rise = nonNegative(rise)
    fall = nonNegative(fall)
    local cycleLength = rise + fall
    -- A zero-length cycle has no segment to sample. Modulo by zero is not a phase.
    if cycleLength == 0 then return 0 end
    local cycle = (tonumber(elapsed) or 0) % cycleLength
    if cycle < rise then
        if inShape == "fade" then
            return peak * (cycle / rise)
        end
        return peak
    end
    if outShape == "fade" then
        local fallElapsed = cycle - rise
        return peak * (1 - fallElapsed / fall)
    end
    return 0
end

-- Alive while elapsed is still short of Cycles times (Rise + Fall).
-- Sticky stays live at any elapsed time. Only Dismiss stops it, and Dismiss does not call this.
-- A negative Rise, Fall, or Cycles counts as 0.
function ScreenFlash.IsLive(elapsed, rise, fall, cycles, sticky)
    if sticky then return true end
    rise = nonNegative(rise)
    fall = nonNegative(fall)
    cycles = nonNegative(cycles)
    return (tonumber(elapsed) or 0) < cycles * (rise + fall)
end

function ScreenFlash.ShouldAutoDismiss(dismissOn, baseline, runtimeTicks)
    if dismissOn == "none" or dismissOn == nil then return false end
    local moved = runtimeTicks.mouse ~= baseline.mouse
    local pressed = runtimeTicks.keyboard ~= baseline.keyboard
    if dismissOn == "mouse" then return moved end
    if dismissOn == "keyboard" then return pressed end
    return moved or pressed
end

function ScreenFlash.BuildHandle(color, inShape, outShape, rise, fall, cycles, sticky, dismissOn, baseline, runtime)
    local peak = (color ~= nil and color.a) or 255
    local state = { elapsed = 0, alpha = 0 }
    return {
        kind = "screen_flash",
        state = state,
        update = function(dt)
            if ScreenFlash.ShouldAutoDismiss(dismissOn, baseline,
                { mouse = runtime.mouseActivityTick, keyboard = runtime.keyboardActivityTick }) then
                return false
            end
            state.elapsed = state.elapsed + (tonumber(dt) or 0)
            if not ScreenFlash.IsLive(state.elapsed, rise, fall, cycles, sticky) then
                return false
            end
            state.alpha = ScreenFlash.AlphaAt(state.elapsed, peak, inShape, outShape, rise, fall)
            return true
        end,
        draw = function(canvas)
            if state.alpha <= 0 then return end
            local w, h = 1920, 1080
            pcall(function()
                if canvas.width and canvas.width > 0 then w = canvas.width end
                if canvas.height and canvas.height > 0 then h = canvas.height end
            end)
            local r = ((color ~= nil and color.r) or 0) / 255
            local g = ((color ~= nil and color.g) or 0) / 255
            local b = ((color ~= nil and color.b) or 0) / 255
            canvas:AddRectangle(0, 0, w, h, Vector4.new(r, g, b, state.alpha / 255))
        end,
    }
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function ScreenFlash.Register(registry, runtime)
    registry:RegisterNodeType("action.screen_flash", {
        category = "action",
        displayName = "Screen Flash",
        pins = {
            { name = "show", kind = "exec", direction = "in", label = "Show" },
            { name = "dismiss", kind = "exec", direction = "in", label = "Dismiss" },
            { name = "color", kind = "data", direction = "in", dataType = "color", default = DEFAULT_COLOR },
            { name = "inShape", kind = "data", direction = "in", dataType = "shape",
              default = "instant", label = "In Shape" },
            { name = "rise", kind = "data", direction = "in", dataType = "number",
              default = 1, label = "Rise" },
            { name = "outShape", kind = "data", direction = "in", dataType = "shape",
              default = "instant", label = "Out Shape" },
            { name = "fall", kind = "data", direction = "in", dataType = "number",
              default = 1, label = "Fall" },
            { name = "cycles", kind = "data", direction = "in", dataType = "number",
              default = 3, label = "Cycles" },
            { name = "sticky", kind = "data", direction = "in", dataType = "bool",
              default = false, label = "Sticky" },
            { name = "dismissOn", kind = "data", direction = "in", dataType = "dismissOn",
              default = "both", label = "Dismiss On" },
        },
        run = function(ctx)
            ctx.state = ctx.state or {}
            local state = ctx.state
            local function dismiss()
                if state.handle ~= nil then
                    runtime.effects:Dismiss(state.handle)
                    state.handle = nil
                end
            end

            if ctx.exec == "dismiss" then
                dismiss()
                return
            end

            -- Replace: re-Show restarts, so any of this node's own still-live handle goes
            -- first (Stack capped at 1, keyed by this node's own persistent state table).
            dismiss()

            local color = ctx:In("color") or DEFAULT_COLOR
            local inShape = ctx:In("inShape") or "instant"
            local outShape = ctx:In("outShape") or "instant"
            local rise = ifNil(ctx:In("rise"), 1)
            local fall = ifNil(ctx:In("fall"), 1)
            local cycles = ifNil(ctx:In("cycles"), 3)
            local sticky = ctx:In("sticky") and true or false
            local dismissOn = ctx:In("dismissOn") or "both"
            local baseline = { mouse = runtime.mouseActivityTick, keyboard = runtime.keyboardActivityTick }

            local handle = ScreenFlash.BuildHandle(
                color, inShape, outShape, rise, fall, cycles, sticky, dismissOn, baseline, runtime)
            state.handle = handle
            runtime.effects:PushStack(state, handle, 1)
        end,
    })
end

return ScreenFlash
