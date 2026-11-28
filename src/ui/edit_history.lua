-- Undo/redo for the open alert. Each step is a whole Node Snapshot. Observe turns any
-- difference from the last snapshot into one step, so a drag or a typing session is one step.

local NodeSnapshot = require("src/ui/node_snapshot")

local EditHistory = {}
EditHistory.__index = EditHistory

EditHistory.LIMIT = 50

function EditHistory.new(limit)
    local self = setmetatable({ limit = limit or EditHistory.LIMIT }, EditHistory)
    self:Reset(nil)
    return self
end

function EditHistory:Reset(snap)
    self.undo, self.redo, self.alias = {}, {}, {}
    self:Settle(snap)
end

-- Takes `snap` as the current state without recording a step.
function EditHistory:Settle(snap)
    self.stable = snap
    self.stableKey = snap and NodeSnapshot.Encode(snap)
end

local function push(list, snap, limit)
    list[#list + 1] = snap
    if #list > limit then table.remove(list, 1) end
end

---@return boolean changed
function EditHistory:Observe(current)
    local key = NodeSnapshot.Encode(current)
    if key == self.stableKey then return false end
    if self.stable ~= nil then
        push(self.undo, self.stable, self.limit)
        self.redo = {}
    end
    self.stable, self.stableKey = current, key
    return true
end

function EditHistory:CanUndo() return #self.undo > 0 end
function EditHistory:CanRedo() return #self.redo > 0 end

-- Pops the snapshot to restore from `from` and parks the current state on `to`. A pending
-- edit is observed first, which also drops the redo steps it made stale.
local function step(self, current, from, to)
    self:Observe(current)
    local target = table.remove(self[from])
    if target ~= nil then push(self[to], self.stable, self.limit) end
    return target
end

function EditHistory:Undo(current) return step(self, current, "undo", "redo") end
function EditHistory:Redo(current) return step(self, current, "redo", "undo") end

return EditHistory
