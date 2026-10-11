-- The client collects a batch of component hooks on each Logic pass. A click
-- handler can expand its capture before the queued HOLD/RELEASE hooks run.
-- Retain the bounds from the start of that pass for every hook in the batch.
local CaptureInput = {}
CaptureInput.__index = CaptureInput

function CaptureInput.new(component)
    local self = setmetatable({ component = component }, CaptureInput)
    self:BeginBatch()
    return self
end

function CaptureInput:BeginBatch()
    self.x, self.y = self.component.x, self.component.y
    self.release = nil
end

function CaptureInput:Position(x, y)
    return self.x + x, self.y + y
end

-- A completed native click can dispatch RELEASE before CLICK in this pass.
-- Keep its endpoint until the click has selected the original target.
function CaptureInput:Release(x, y)
    local mx, my = self:Position(x, y)
    self.release = { x = mx, y = my }
    return mx, my
end

return CaptureInput
