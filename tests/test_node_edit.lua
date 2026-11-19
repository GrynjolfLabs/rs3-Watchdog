-- Canvas selection, the node clipboard, and undo/redo (TODO #15).
-- Drives the real (unmounted) Editor headless, as test_graph_editor does.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }
_G.id = _G.id or setmetatable({}, { __index = function()
    return setmetatable({}, { __index = function() return 1 end })
end })
_G.config = _G.config or { Font = setmetatable({}, { __index = function()
    return { GetStringWidth = function(_, t) return #t * 7 end }
end }) }

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local Editor = require("src/ui/graph")
local NodeSnapshot = require("src/ui/node_snapshot")
local EditHistory = require("src/ui/edit_history")
local EditorKeys = require("src/ui/editor_keys")

TestNodeEdit = {}

function TestNodeEdit:setUp()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        displayName = "Trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    self.registry:RegisterNodeType("fixture.action", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "value", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.matcher", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "contains", kind = "data", direction = "in", dataType = "matcher",
              default = { needle = "", mode = "substring" } },
        },
        run = function() end,
    })
    self.graph = Graph.new(self.registry)
    Editor.clipboard = nil
    self.savedLib = rawget(_G, "LibNodeGraph")
    _G.LibNodeGraph = {
        Serialize = Serialize.Serialize,
        Deserialize = Serialize.Deserialize,
        UNKNOWN_TYPE = Registry.UNKNOWN_TYPE,
    }
    self.savedMouse = rawget(_G, "Mouse")
    self.savedKeyboard = rawget(_G, "Keyboard")
    self.savedGameKey = rawget(_G, "GameKey")
end

function TestNodeEdit:tearDown()
    rawset(_G, "Mouse", self.savedMouse)
    rawset(_G, "Keyboard", self.savedKeyboard)
    rawset(_G, "GameKey", self.savedGameKey)
    rawset(_G, "LibNodeGraph", self.savedLib)
    Editor.clipboard = nil
end

-- An editor bound to self.graph with every node laid out and geometry built.
function TestNodeEdit:editor(layout)
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, layout or {})
    editor.view.panY = 0 -- graph space equals content space in these tests
    editor.visible = true
    editor.window.w, editor.window.h = 1000, 800
    editor.expandCapture = function() end
    editor.positionCapture = function() end
    editor:buildGeoms()
    return editor
end

local function mouseAt(editor, lx, ly)
    _G.Mouse = {
        GetPosition = function()
            return { x = editor.window.x + lx, y = editor.window.y + ly }
        end,
    }
end

local function shift(down)
    _G.Keyboard = { IsShiftDown = function() return down end }
end

local function bodyCenter(editor, id)
    local geom = editor.geoms[id]
    -- Below the header, left of the pins: plain body.
    return editor.view:ToScreen(geom.x + geom.w * 0.5, geom.y + geom.h - 4)
end

local function countNodes(graph)
    return #graph:GetNodes()
end

--- Node Snapshot ------------------------------------------------------------------------

function TestNodeEdit:testCaptureKeepsInnerWiresAndDropsOuterOnes()
    local t = self.graph:AddNode("fixture.trigger")
    local a = self.graph:AddNode("fixture.action")
    local b = self.graph:AddNode("fixture.action")
    self.graph:Connect(t, "out", a, "in")
    self.graph:Connect(t, "out", b, "in")
    local layout = { [t] = { x = 0, y = 0 }, [a] = { x = 300, y = 0 }, [b] = { x = 300, y = 100 } }

    local snap = NodeSnapshot.Capture(self.graph, layout, { [t] = true, [a] = true })

    luaunit.assertEquals(#snap.nodes, 2)
    luaunit.assertEquals(#snap.connections, 1)
    luaunit.assertEquals(snap.connections[1].toNode, a)
    luaunit.assertNil(snap.layout[b])
end

function TestNodeEdit:testPasteAddsNewIdsAndRewiresThem()
    local t = self.graph:AddNode("fixture.trigger", nil, { name = "Start" })
    local a = self.graph:AddNode("fixture.action", { value = 7 })
    self.graph:Connect(t, "out", a, "in")
    local layout = { [t] = { x = 10, y = 20 }, [a] = { x = 310, y = 60 } }
    local snap = NodeSnapshot.Capture(self.graph, layout, { [t] = true, [a] = true })

    local newIds = NodeSnapshot.Paste(self.graph, self.registry, layout, snap, 500, 500)

    luaunit.assertEquals(#newIds, 2)
    luaunit.assertEquals(countNodes(self.graph), 4)
    local nt, na = newIds[1], newIds[2]
    luaunit.assertNotEquals(nt, t)
    luaunit.assertEquals(self.graph.nodes[nt].name, "Start")
    luaunit.assertEquals(self.graph:GetControl(na, "value"), 7)
    luaunit.assertNotNil(self.graph:FindConnection(nt, "out", na, "in"))
    -- The copy keeps its shape with its top-left at the paste point.
    luaunit.assertEquals(layout[nt], { x = 500, y = 500 })
    luaunit.assertEquals(layout[na], { x = 800, y = 540 })
end

function TestNodeEdit:testPastedControlTablesAreNotShared()
    local m = self.graph:AddNode("fixture.matcher", { contains = { needle = "boss", mode = "pattern" } })
    local layout = { [m] = { x = 0, y = 0 } }
    local snap = NodeSnapshot.Capture(self.graph, layout, { [m] = true })

    local copy = NodeSnapshot.Paste(self.graph, self.registry, layout, snap, 0, 200)[1]
    self.graph:GetControl(copy, "contains").needle = "changed"

    luaunit.assertEquals(self.graph:GetControl(m, "contains").needle, "boss")
    luaunit.assertEquals(snap.nodes[1].controls.contains.needle, "boss")
end

function TestNodeEdit:testPasteLeavesOutTypesThatCannotBePlaced()
    local t = self.graph:AddNode("fixture.trigger")
    local a = self.graph:AddNode("fixture.action")
    self.graph:Connect(t, "out", a, "in")
    local layout = { [t] = { x = 0, y = 0 }, [a] = { x = 300, y = 0 } }
    local snap = NodeSnapshot.Capture(self.graph, layout, nil)

    local newIds = NodeSnapshot.Paste(self.graph, self.registry, layout, snap, 0, 300,
        function(typeKey) return typeKey ~= "fixture.action" end)

    luaunit.assertEquals(#newIds, 1)
    luaunit.assertEquals(#self.graph:GetConnections(), 1)
end

function TestNodeEdit:testCaptureCanLeaveOutPlaceholders()
    local graph = Serialize.Deserialize({
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "future.Thing", controls = { n = 1 } },
        },
        connections = {},
    }, self.registry, { onUnknown = "placeholder" })

    local snap, skipped = NodeSnapshot.Capture(graph, {}, { [1] = true, [2] = true }, true)

    luaunit.assertEquals(skipped, 1)
    luaunit.assertEquals(#snap.nodes, 1)
    luaunit.assertEquals(snap.nodes[1].type, "fixture.trigger")
end

function TestNodeEdit:testEncodeIgnoresKeyOrder()
    luaunit.assertEquals(NodeSnapshot.Encode({ a = 1, b = { c = "x", d = true } }),
        NodeSnapshot.Encode({ b = { d = true, c = "x" }, a = 1 }))
    luaunit.assertNotEquals(NodeSnapshot.Encode({ a = 1 }), NodeSnapshot.Encode({ a = 2 }))
end

--- Edit History ---------------------------------------------------------------------------

function TestNodeEdit:testObserveRecordsAStepOnlyWhenSomethingChanged()
    local history = EditHistory.new()
    local layout = {}
    history:Reset(NodeSnapshot.Capture(self.graph, layout))
    luaunit.assertFalse(history:Observe(NodeSnapshot.Capture(self.graph, layout)))
    luaunit.assertFalse(history:CanUndo())

    local id = self.graph:AddNode("fixture.trigger")
    layout[id] = { x = 0, y = 0 }
    luaunit.assertTrue(history:Observe(NodeSnapshot.Capture(self.graph, layout)))
    luaunit.assertTrue(history:CanUndo())
end

function TestNodeEdit:testHistoryDropsTheOldestStepPastTheLimit()
    local history = EditHistory.new(2)
    local layout = {}
    history:Reset(NodeSnapshot.Capture(self.graph, layout))
    for i = 1, 4 do
        local id = self.graph:AddNode("fixture.trigger")
        layout[id] = { x = i, y = 0 }
        history:Observe(NodeSnapshot.Capture(self.graph, layout))
    end
    luaunit.assertEquals(#history.undo, 2)
end

function TestNodeEdit:testUndoBringsBackADeletedNodeWithItsWiresAndPlace()
    local t = self.graph:AddNode("fixture.trigger")
    local a = self.graph:AddNode("fixture.action", { value = 3 }, { name = "Callout" })
    self.graph:Connect(t, "out", a, "in")
    local editor = self:editor({ [t] = { x = 0, y = 0 }, [a] = { x = 300, y = 40 } })

    editor:selectOnly(a)
    luaunit.assertTrue(editor:RunEditAction("delete"))
    luaunit.assertEquals(countNodes(self.graph), 1)

    luaunit.assertTrue(editor:RunEditAction("undo"))
    luaunit.assertEquals(countNodes(self.graph), 2)
    local back
    for _, n in ipairs(self.graph:GetNodes()) do
        if n.typeKey == "fixture.action" then back = n.id end
    end
    luaunit.assertEquals(self.graph:GetControl(back, "value"), 3)
    luaunit.assertEquals(self.graph.nodes[back].name, "Callout")
    luaunit.assertNotNil(self.graph:FindConnection(t, "out", back, "in"))
    luaunit.assertEquals(editor.layout[back], { x = 300, y = 40 })

    luaunit.assertTrue(editor:RunEditAction("redo"))
    luaunit.assertEquals(countNodes(self.graph), 1)
    luaunit.assertNil(self.graph.nodes[back])
end

function TestNodeEdit:testUndoKeepsUntouchedNodesAndTheirState()
    local t = self.graph:AddNode("fixture.action", { value = 1 })
    local editor = self:editor({ [t] = { x = 0, y = 0 } })
    local state = self.graph:GetState(t)

    self.graph:SetControl(t, "value", 9)
    editor:observeHistory()
    luaunit.assertTrue(editor:RunEditAction("undo"))

    luaunit.assertNotNil(self.graph.nodes[t])
    luaunit.assertIs(self.graph:GetState(t), state)
    luaunit.assertEquals(self.graph:GetControl(t, "value"), 1)
end

function TestNodeEdit:testUndoAndRedoFollowANodeThatWasReAdded()
    local editor = self:editor({})
    local id = self.graph:AddNode("fixture.trigger")
    editor.layout[id] = { x = 5, y = 5 }
    editor:observeHistory()               -- step 1: added
    editor:selectOnly(id)
    editor:RunEditAction("delete")        -- step 2: deleted

    editor:RunEditAction("undo")          -- back: a new id stands in for it
    luaunit.assertEquals(countNodes(self.graph), 1)
    editor:RunEditAction("undo")          -- before it was added
    luaunit.assertEquals(countNodes(self.graph), 0)
    editor:RunEditAction("redo")
    luaunit.assertEquals(countNodes(self.graph), 1)
    local again = self.graph:GetNodes()[1].id
    luaunit.assertEquals(editor.layout[again], { x = 5, y = 5 })
    editor:RunEditAction("redo")
    luaunit.assertEquals(countNodes(self.graph), 0)
    luaunit.assertFalse(editor.history:CanRedo())
end

function TestNodeEdit:testANewEditAfterUndoDropsRedo()
    local editor = self:editor({})
    local id = self.graph:AddNode("fixture.trigger")
    editor.layout[id] = { x = 0, y = 0 }
    editor:observeHistory()
    editor:RunEditAction("undo")
    luaunit.assertTrue(editor.history:CanRedo())

    local other = self.graph:AddNode("fixture.action")
    editor.layout[other] = { x = 0, y = 100 }
    editor:observeHistory()
    luaunit.assertFalse(editor.history:CanRedo())
end

function TestNodeEdit:testBindingStartsAFreshHistory()
    local id = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [id] = { x = 0.5, y = 0 } })
    editor:buildGeoms()
    editor:observeHistory()
    luaunit.assertFalse(editor.history:CanUndo())
end

--- Selection -------------------------------------------------------------------------------

function TestNodeEdit:testShiftClickAddsAndRemovesWithoutDragging()
    local a = self.graph:AddNode("fixture.trigger")
    local b = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [a] = { x = 100, y = 100 }, [b] = { x = 100, y = 300 } })

    shift(false)
    mouseAt(editor, bodyCenter(editor, a))
    editor:beginPress()
    editor:endPress()
    shift(true)
    mouseAt(editor, bodyCenter(editor, b))
    editor:beginPress()
    luaunit.assertNotEquals(editor.mode, "dragnode")
    editor:endPress()
    luaunit.assertTrue(editor:isSelected(a))
    luaunit.assertTrue(editor:isSelected(b))

    mouseAt(editor, bodyCenter(editor, a))
    editor:beginPress()
    editor:endPress()
    luaunit.assertFalse(editor:isSelected(a))
    luaunit.assertTrue(editor:isSelected(b))
end

function TestNodeEdit:testDraggingASelectedNodeMovesTheWholeSelection()
    local a = self.graph:AddNode("fixture.trigger")
    local b = self.graph:AddNode("fixture.trigger")
    local c = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({
        [a] = { x = 100, y = 100 }, [b] = { x = 100, y = 300 }, [c] = { x = 500, y = 300 },
    })
    editor.selection = { [a] = true, [b] = true }
    shift(false)

    local sx, sy = bodyCenter(editor, a)
    mouseAt(editor, sx, sy)
    editor:beginPress()
    luaunit.assertEquals(editor.mode, "dragnode")
    mouseAt(editor, sx + 40.5, sy + 10)
    editor:update()
    editor:endPress()

    luaunit.assertEquals(editor.layout[a], { x = 141, y = 110 })
    luaunit.assertEquals(editor.layout[b], { x = 141, y = 310 })
    luaunit.assertEquals(editor.layout[c], { x = 500, y = 300 })
end

function TestNodeEdit:testPlainClickOnEmptyCanvasClearsTheSelection()
    local a = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [a] = { x = 300, y = 300 } })
    editor:selectOnly(a)
    shift(false)
    mouseAt(editor, 900, 700)
    editor:beginPress()
    luaunit.assertEquals(editor.mode, "pan")
    editor:endPress()
    luaunit.assertEquals(#editor:selectedIds(), 0)
end

function TestNodeEdit:testShiftDragBoxAddsOverlappingNodes()
    local a = self.graph:AddNode("fixture.trigger")
    local b = self.graph:AddNode("fixture.trigger")
    local far = self.graph:AddNode("fixture.trigger")
    local kept = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({
        [a] = { x = 100, y = 100 }, [b] = { x = 200, y = 250 },
        [far] = { x = 700, y = 600 }, [kept] = { x = 700, y = 100 },
    })
    editor:selectOnly(kept)

    shift(true)
    mouseAt(editor, 90, 90)
    editor:beginPress()
    luaunit.assertEquals(editor.mode, "marquee")
    mouseAt(editor, 260, 270)
    editor:update()
    editor:endPress()

    luaunit.assertTrue(editor:isSelected(a))
    luaunit.assertTrue(editor:isSelected(b))
    luaunit.assertTrue(editor:isSelected(kept))
    luaunit.assertFalse(editor:isSelected(far))
    luaunit.assertNil(editor.marquee)
end

--- Clipboard and delete --------------------------------------------------------------------

function TestNodeEdit:testCutThenPastePutsTheNodesUnderTheCursor()
    local t = self.graph:AddNode("fixture.trigger")
    local a = self.graph:AddNode("fixture.action")
    self.graph:Connect(t, "out", a, "in")
    local editor = self:editor({ [t] = { x = 0, y = 0 }, [a] = { x = 300, y = 20 } })
    editor.selection = { [t] = true, [a] = true }
    mouseAt(editor, 900, 700)

    luaunit.assertTrue(editor:RunEditAction("cut"))
    luaunit.assertEquals(countNodes(self.graph), 0)
    luaunit.assertNotNil(Editor.clipboard)

    mouseAt(editor, 400, 500)
    luaunit.assertTrue(editor:RunEditAction("paste"))
    luaunit.assertEquals(countNodes(self.graph), 2)
    luaunit.assertEquals(#editor:selectedIds(), 2)
    luaunit.assertEquals(#self.graph:GetConnections(), 1)
    local gx, gy = editor.view:ToGraph(400, 500)
    local minX, minY
    for id in pairs(editor.selection) do
        local p = editor.layout[id]
        if minX == nil or p.x < minX then minX = p.x end
        if minY == nil or p.y < minY then minY = p.y end
    end
    luaunit.assertEquals(minX, gx)
    luaunit.assertEquals(minY, gy)
end

function TestNodeEdit:testRepeatPasteStepsEachCopy()
    local t = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [t] = { x = 0, y = 0 } })
    editor:selectOnly(t)
    editor:RunEditAction("copy")
    mouseAt(editor, 400, 400)

    editor:RunEditAction("paste")
    local first = editor.selected
    editor:RunEditAction("paste")
    local second = editor.selected

    luaunit.assertEquals(editor.layout[second].x - editor.layout[first].x, 20)
    luaunit.assertEquals(editor.layout[second].y - editor.layout[first].y, 20)
end

function TestNodeEdit:testCopyLeavesTheGraphAlone()
    local t = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [t] = { x = 0, y = 0 } })
    editor:selectOnly(t)
    luaunit.assertTrue(editor:RunEditAction("copy"))
    editor:observeHistory()
    luaunit.assertEquals(countNodes(self.graph), 1)
    luaunit.assertFalse(editor.history:CanUndo())
end

function TestNodeEdit:testActionsNeedASelectionOrAClip()
    local t = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [t] = { x = 0, y = 0 } })
    local enabled = editor:editActionsEnabled()
    luaunit.assertFalse(enabled.copy)
    luaunit.assertFalse(enabled.cut)
    luaunit.assertFalse(enabled.delete)
    luaunit.assertFalse(enabled.paste)
    luaunit.assertFalse(enabled.undo)
    luaunit.assertFalse(editor:RunEditAction("delete"))
    luaunit.assertEquals(countNodes(self.graph), 1)
end

function TestNodeEdit:testDeletingSeveralNodesAsksFirst()
    local a = self.graph:AddNode("fixture.trigger")
    local b = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [a] = { x = 0, y = 0 }, [b] = { x = 0, y = 200 } })
    editor.selection = { [a] = true, [b] = true }
    local Confirm = require("src/ui/confirm")
    local savedMount = Confirm.mount
    local opts
    Confirm.mount = function(_, o) opts = o end
    editor.overlayParent = {}

    editor:RunEditAction("delete")
    Confirm.mount = savedMount
    editor.overlayParent = nil

    luaunit.assertNotNil(opts)
    luaunit.assertEquals(countNodes(self.graph), 2)
    opts.onConfirm()
    luaunit.assertEquals(countNodes(self.graph), 0)
end

function TestNodeEdit:testToolbarClickRunsItsAction()
    local t = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [t] = { x = 300, y = 300 } })
    editor:selectOnly(t)
    local del
    for _, r in ipairs(editor.editToolbar.rects) do
        if r.id == "delete" then del = r end
    end
    mouseAt(editor, del.x + 2, del.y + 2)
    editor:beginPress()
    luaunit.assertEquals(countNodes(self.graph), 0)
    luaunit.assertFalse(editor.pressed)
end

--- Keys ------------------------------------------------------------------------------------

local function keyEvent(code) return { gameKey = code } end

function TestNodeEdit:testShortcutsMapToActions()
    _G.GameKey = { C = 1, V = 2, X = 3, Y = 4, Z = 5, DELETE = 6, A = 7 }
    local ctrl, shiftDown = true, false
    _G.Keyboard = {
        IsControlDown = function() return ctrl end,
        IsShiftDown = function() return shiftDown end,
    }
    luaunit.assertEquals(EditorKeys.ActionFor(keyEvent(1)), "copy")
    luaunit.assertEquals(EditorKeys.ActionFor(keyEvent(2)), "paste")
    luaunit.assertEquals(EditorKeys.ActionFor(keyEvent(3)), "cut")
    luaunit.assertEquals(EditorKeys.ActionFor(keyEvent(4)), "redo")
    luaunit.assertEquals(EditorKeys.ActionFor(keyEvent(5)), "undo")
    shiftDown = true
    luaunit.assertEquals(EditorKeys.ActionFor(keyEvent(5)), "redo")
    luaunit.assertNil(EditorKeys.ActionFor(keyEvent(7)))
    ctrl = false
    luaunit.assertNil(EditorKeys.ActionFor(keyEvent(1)))
    luaunit.assertEquals(EditorKeys.ActionFor(keyEvent(6)), "delete")
end

function TestNodeEdit:testCtrlCanComeFromTheKeyEvent()
    _G.GameKey = { C = 1 }
    _G.Keyboard = nil
    luaunit.assertEquals(EditorKeys.ActionFor({ gameKey = 1, ctrl = true }), "copy")
    luaunit.assertNil(EditorKeys.ActionFor({ gameKey = 1 }))
end

function TestNodeEdit:testKeysOnlyActWithTheCursorOverTheEditor()
    _G.GameKey = { DELETE = 6 }
    _G.Keyboard = { IsShiftDown = function() return false end }
    local t = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [t] = { x = 0, y = 0 } })
    editor:selectOnly(t)

    mouseAt(editor, 2000, 2000)
    luaunit.assertFalse(editor:HandleKey(keyEvent(6)))
    luaunit.assertEquals(countNodes(self.graph), 1)

    mouseAt(editor, 500, 500)
    luaunit.assertTrue(editor:HandleKey(keyEvent(6)))
    luaunit.assertEquals(countNodes(self.graph), 0)
end

function TestNodeEdit:testKeysWaitWhileAFieldIsOpen()
    _G.GameKey = { DELETE = 6 }
    local t = self.graph:AddNode("fixture.trigger")
    local editor = self:editor({ [t] = { x = 0, y = 0 } })
    editor:selectOnly(t)
    mouseAt(editor, 500, 500)
    editor.editing = { nodeId = t, pinName = "x" }
    luaunit.assertFalse(editor:HandleKey(keyEvent(6)))
    editor.editing = nil
    luaunit.assertEquals(countNodes(self.graph), 1)
end
