-- Tutorial copy for the graph editor. Sections after the first start collapsed.
-- The client draws a newline as a missing-glyph box, so each paragraph is its own AddText.

local EditorHelp = {}

local FOOTER_CLEARANCE = 24

local function section(win, title, paragraphs, expanded)
    local block = win:AddCollapseButton(title, { expanded = expanded == true })
    for _, paragraph in ipairs(paragraphs) do
        block:AddText(paragraph)
    end
    return block
end

---@param win any
function EditorHelp.fill(win)
    section(win, "Node editor", {
        "A node is one box and it does one job.",
        "An alert is those boxes with connection wires between them.",
        "A trigger watches the game. An action does something you can see or hear. Connect them and the action runs when the trigger does.",
        "The colored bar on a node is its kind. Triggers are red. Actions are blue.",
    }, true)

    section(win, "Moving around", {
        "Drag empty space to slide the graph.",
        "The mouse wheel zooms toward the cursor. The slider in the title bar zooms from the middle of the view.",
        "The grid button puts the view back where it started.",
        "Zoom out and the words and small controls hide. Zoom back in to read and click them.",
    })

    section(win, "Adding a node", {
        "Double-click empty space, or click +.",
        "A list opens, grouped by kind. Triggers come first, then actions.",
        "Click a name to place that node. Click outside the list to close it.",
        "+ places the new node in the middle of the view. A double-click places it where you clicked.",
        "Drag a wire off a pin and let go on empty space. The list shows only nodes that pin can connect to, and the one you pick is already wired.",
    })

    section(win, "Pins and wires", {
        "Pins are the sockets on the sides. Left receives. Right sends. Start the drag from either pin.",
        "White triangles are exec pins and define the flow. The wire leaves the right side of one node and arrives on the left side of the next.",
        "One exec out can feed several nodes. They run in the same step. Watchdog does not pick which one goes first. Several wires can arrive at the same exec in.",
        "Colored squares carry values. Cyan is a number. Orange is text. Green is true or false. Gold is a coordinate. Unmapped are magenta.",
        "Same colors connect. Grey pins mean anything can connect.",
        "A triangle will not connect to a square. A node will not connect to itself.",
        "The editor refuses a wire that loops back to an earlier node. Reset and Close are exceptions, because those pins end the chain.",
        "If the wire snaps back, the editor refused the connection.",
        "A square on the left holds one wire. A new wire replaces the old one. A square on the right can feed several nodes.",
        "Drag the same two pins together again to disconnect the wire. To move a wire, drag it off the pin on the left.",
    })

    section(win, "On the node", {
        "Drag a node by its header or body to move it.",
        "The pencil in the header renames that node. The X deletes the node and its wires.",
        "An unconnected data pin allows manual editing of the value.",
        "Wire that pin and the control goes away. The wire supplies the value.",
        "Triangles (exec in pins) on the left have a green square with a play mark beside them. Click it and it runs once. This is a good way to test your alerts.",
    })

    section(win, "A first alert", {
        "Under Trigger, choose Game Message. It runs when the game prints a chat line.",
        "Type a word into Message contains to match only lines with that word. Leave it empty and every line of the chosen type matches.",
        "The type filters which chat lines trigger. Any means all of them.",
        "Drag the message out pin and drop it on an empty spot. Choose the Toast Action and see it automatically connect.",
        "Wire the trigger's out triangle to the toast's show triangle.",
        "The alert runs only while it is enabled in the alert list. A new alert starts enabled.",
        "Click the play mark beside show to test the Toast.",
    })

    section(win, "Presets", {
        "A preset is a saved copy of an alert. Use one to make that graph again without rebuilding it.",
        "Click the star in the title bar to open the create preset dialog.",
        "Change the name of the Preset if desired.",
        "Mark Variable marks a data pin that you fill in each time you use the preset. Pick the node, then the pin. The row shows that pin and the value it has now.",
        "Only an unconnected text, number, dropdown, or matcher pin can be marked. Wired pins and exec pins are skipped.",
        "You can save with nothing marked. Every alert you make from it is an exact copy.",
        "On the alert list, + New alert opens your presets. Presets that came with a pack are listed under the pack name.",
        "Click a preset to create an alert from it. The new alert stays on the list. If you marked pins, fill them in and click Create. From scratch makes a blank alert and opens it.",
    })

    section(win, "More nodes", {
        "Logic has And, Or, Not, and Xor. They combine true or false answers. Xor means one side or the other, not both.",
        "Compare takes two values and a comparison, and answers true or false.",
        "Branch is under Flow. It reads a boolean and flows out the true or the false pin.",
        "Sequence runs then1, then2, then3, and then4 in that order. Use Sequence when the order matters.",
        "Counter counts how many times it has been run.",
        "Do Once lets the first signal through, then ignores the rest until reset.",
        "Gate starts closed. It lets a signal through only while open. Open, close, and toggle change the gate. They do not pass the signal on.",
        "FlipFlop alternates between a and b.",
        "Math does arithmetic.",
        "To String and To Number are under Convert. They change a value so it fits a pin of another type.",
        "Inventory reads what you are carrying. Item Count sums matching stacks. Item Count Changed also reports the previous sum and how much it moved.",
    })

    -- The Close button is anchored over the bottom of the scrolling page.
    win:AddText({ text = "", height = FOOTER_CLEARANCE, rowBackground = false })
    win:RefreshRowBackgrounds()
end

return EditorHelp
