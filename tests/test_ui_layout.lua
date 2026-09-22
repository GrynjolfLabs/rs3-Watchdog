local luaunit = require("luaunit")
TestUILayout = {}
function TestUILayout:setUp()
    self.saved = {}
    for _, key in ipairs({ "ui", "id", "config", "prettyui", "Vector4", "pcall" }) do
        self.saved[key] = _G[key]
    end
end
function TestUILayout:tearDown()
    for _, key in ipairs({ "ui", "id", "config", "prettyui", "Vector4", "pcall" }) do
        _G[key] = self.saved[key]
    end
end
function TestUILayout:testManagerControlsAtMinimumWidth()
    local errors = {}
    local nativePcall = pcall
    _G.pcall = function(fn, ...)
        local result = table.pack(nativePcall(fn, ...))
        if not result[1] then
            errors[#errors + 1] = result[2]
        end
        return table.unpack(result, 1, result.n)
    end
    local function component(parent)
        local c = { children = {}, parent = parent, x = 0, y = 0, width = 0, height = 0 }
        if parent then
            parent.children[#parent.children + 1] = c
        end
        function c:SetSize(w, h)
            self.width = w
            self.height = h
        end
        function c:SetPos(x, y)
            self.x = x
            self.y = y
        end
        function c:MoveToFront() end
        function c:Destroy()
            self.destroyed = true
            for _, child in ipairs(self.children) do
                child:Destroy()
            end
        end
        function c:Subscribe(event, fn)
            self[event] = fn
        end
        function c:SetScrollSize(w, h)
            self.scrollW = w
            self.scrollH = h
        end
        return setmetatable(c, {
            __newindex = function(t, k, v)
                if k == "alignHorizontal" or k == "alignVertical" or k == "alignment" then
                    assert(v == 1 or v == 2, "Invalid native alignment value: " .. tostring(v))
                end
                rawset(t, k, v)
            end,
        })
    end
    ui = {
        Layer = { new = component },
        Panel = { new = component },
        Text = { new = component },
        Sprite = { new = component },
        Check = { new = component },
        AlignMode = { TOPLEFT = 1, CENTRE = 2 },
        CheckAlignMode = { LEFT = 1 },
        Hook = { ONBUTTONPRESSED = 1 },
    }
    Vector4 = {
        new = function(...)
            return { ... }
        end,
    }
    ui.Canvas = {
        new = function(parent)
            local c = component(parent)
            c.rectangles = {}
            c.lines = {}
            function c:AddRectangle(...)
                self.rectangles[#self.rectangles + 1] = { ... }
            end
            function c:AddLine(...)
                self.lines[#self.lines + 1] = { ... }
            end
            return c
        end,
    }
    id = { Sprite = { RS3_ICON_RUNEMETRICS_NEW_2 = 102, RS3_ICON_EXTERNAL_LINK_24PX_2 = 100, HUD_COMBAT_BTN_BIN = 101 }, Font = { MUSEO_SANS_15PT_REGULAR = 1 }, StyleSheet = { CHECKBOX_DEFAULT = 1 } }
    config = { Cursor = { CURSOR_OPEN = 1 }, Font = { CINZEL_13PT_BOLD = {
        GetStringWidth = function(_, text) return #text * 8 end,
    } } }
    local buttons = {}
    local function button(parent, text, action, opts)
        local root = component(parent)
        root:SetSize(opts.width or opts.size or 28, opts.height or opts.size or 28)
        local b = {
            root = root,
            content = component(root),
            text = text,
            action = action,
            options = opts,
            disabled = opts.disabled,
        }
        function b:SetDisabled(v)
            self.disabled = v
        end
        function b:SetActive(v)
            self.active = v
        end
        function b:Destroy()
            self.root:Destroy()
        end
        buttons[#buttons + 1] = b
        return b
    end
    prettyui = {
        SimpleButton = {
            new = button,
            getSize = function(text)
                return #text * 8 + 16, 24
            end,
        },
        SpriteButton = { new = button },
        FancyButton = {
            getSize = function()
                return 146, 27
            end,
        },
    }
    prettyui.CheckboxButton = {
        new = function(parent, choices, opts)
            local root = component(parent)
            root:SetPos(opts.x, opts.y)
            root:SetSize(opts.width, 22)
            local row = component(root)
            local box = component(row)
            box:SetSize(14, 14)
            local label = component(row)
            row:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                opts.onChange()
            end)
            return {
                root = root,
                items = { { row = row, box = box, label = label } },
                Destroy = function()
                    root:Destroy()
                end,
            }
        end,
    }
    local host = {}
    local content = component()
    content:SetSize(696, 500)
    function host:AddSimpleButton(text, action, opts)
        return button(content, text, action, opts)
    end
    function host:AddFancyButton(text, action, opts)
        local b = button(content, text, action, opts)
        b.root:SetSize(b.root.width, 27)
        b.left = component(b.root)
        b.middle = component(b.root)
        b.right = component(b.root)
        b.label = component(b.root)
        return b
    end
    function host:AddTabs(entries, opts)
        return { root = component(content), SetActive = function() end, Destroy = function() end }
    end
    local Manager = require("ui/manager")
    local opens = 0
    local entries = {
        { id = 1, kind = "alert", name = "Low health", enabled = true },
        { id = 2, kind = "group", name = "Combat", children = {
            { id = 3, kind = "alert", name = "Food", enabled = false },
        } },
    }
    local m = Manager.new({
        scopes = function()
            return {
                { key = "global", label = "All characters", doc = { entries = entries } },
                { key = "player_other", label = "Other", doc = { entries = {} } },
            }
        end,
        onOpenAlert = function()
            opens = opens + 1
        end,
    })
    m:Mount(content, host)
    m:SetVisible(true)
    assert(#errors == 0, table.concat(errors, "\n"))
    local function activeButtons(text)
        local out = {}
        for _, b in ipairs(buttons) do
            if b.text == text and not b.root.destroyed then
                out[#out + 1] = b
            end
        end
        return out
    end
    local primary = activeButtons("+ New alert")[1]
    assert(
        primary.root.height == 28
            and primary.left.height == 28
            and primary.middle.height == 28
            and primary.right.height == 28
            and primary.label.height == 28
    )
    assert(primary.root.height == activeButtons("+ New group")[1].root.height)
    assert(#activeButtons("ARROW_UP") == 0, "Move arrows visible by default")
    assert(#activeButtons("PENCIL") == 3, "Rename buttons missing after title construction")
    assert(#activeButtons("EXPORT") == 3, "Export buttons missing after title construction")
    assert(#activeButtons("TRASH") == 3, "Delete buttons missing after title construction")
    for i, row in ipairs(m.treePanel.children) do
        if i > 1 then
            assert(#row.children >= 6, "Selection or action cells missing")
            local cell = row.children[#row.children - 3]
            local check = cell.children[1]
            local item = check.children[1]
            assert(item[ui.Hook.ONBUTTONPRESSED], "PrettyUI selection handler missing")
            local box = item.children[1]
            assert(
                box.width == 14 and box.height == 14 and box.x == 7 and box.y == 7,
                "Checkbox sprite resized or off center"
            )
            assert(
                check.x * 2 + check.width == cell.width and check.y * 2 + check.height == cell.height,
                "Selection checkbox is not centered"
            )
        end
    end
    local first = m.treePanel.children[2]
    local selectCell = first.children[#first.children - 3]
    selectCell.children[1].children[1][ui.Hook.ONBUTTONPRESSED]()
    assert(m.selected[1], "Checkbox did not select its alert")
    m:ClearSelection()
    m:_rebuild()
    local title = activeButtons("Low health")
    title[#title].action()
    assert(opens == 1, "Single click did not open")
    assert(title[#title].content.alignHorizontal == ui.AlignMode.TOPLEFT)
    m:ToggleMoveMode()
    m:_rebuild()
    assert(m.moveMode)
    assert(#activeButtons("ARROW_UP") == 3, "Move controls missing")
    m:ToggleSelection(1, false)
    m:_rebuild()
    assert(not m.moveMode and m:HasSelection())
    m:ToggleMoveMode()
    m:_rebuild()
    assert(m.moveMode and not m:HasSelection())
    m:SetActiveScope("player_other")
    m:_rebuild()
    assert(not m.moveMode)
    -- Rows including nesting must fit the native horizontal panel at minimum width.
    m:SetActiveScope("global")
    for _, moving in ipairs({ false, true }) do
        m.moveMode = moving
        m:_rebuild()
        for _, row in ipairs(m.treePanel.children) do
            local width = 0
            for _, cell in ipairs(row.children) do
                width = width + cell.width
            end
            width = width + math.max(0, #row.children - 1) * (row.spacing or 0)
            assert(width <= row.width, ("Row overflows: %s > %s"):format(width, row.width))
        end
    end
    assert(#errors == 0, table.concat(errors, "\n"))
end
