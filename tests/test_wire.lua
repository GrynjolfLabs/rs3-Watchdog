local luaunit = require("luaunit")
local Wire = require("ui/wire")
local View = require("ui/view")
local Theme = require("ui/theme")

TestWire = {}
function TestWire:testStrokeStaysInsideViewportAfterResizeAndZoom()
    local saved = Vector4
    Vector4 = { new = function(...) return { ... } end }
    local canvas = { lines = {} }
    function canvas:AddLine(...) self.lines[#self.lines + 1] = { ... } end
    local view = View.new()
    for _, zoom in ipairs({ 0.25, 1, 2 }) do
        view.zoom = zoom
        for _, height in ipairs({ 500, 120, 300 }) do
            canvas.lines = {}
            -- A wire crossing both the toolbar and bottom edge.
            Wire.DrawCurve(canvas, view, 50, -100, 1, 150, 1000, -1,
                Theme.COL_EXEC, 0, 84, 400, height)
            luaunit.assertTrue(#canvas.lines > 0)
            for _, line in ipairs(canvas.lines) do
                local thickness = line[5]
                for i = 1, 3, 2 do
                    luaunit.assertTrue(line[i] - thickness >= 0)
                    luaunit.assertTrue(line[i] + thickness <= 400)
                    luaunit.assertTrue(line[i + 1] - thickness >= 84)
                    luaunit.assertTrue(line[i + 1] + thickness <= 84 + height)
                end
            end
        end
    end
    Vector4 = saved
end

function TestWire:testWireOutsideViewportIsNotDrawn()
    local canvas = { AddLine = function() error("Offscreen wire was drawn") end }
    Wire.DrawCurve(canvas, View.new(), 50, 600, 1, 150, 600, -1,
        Theme.COL_EXEC, 0, 84, 400, 200)
end
