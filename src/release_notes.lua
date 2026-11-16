-- Oldest first. A version with no entry never pops.
-- A paragraph is a string, a title { title = "Known issues" },
-- a list { bullets = { "First.", "Second." } }, or a picture:
-- { image = "releases/tutorial", width = 893, height = 554 }
-- image is a path under resources/images, without the .png extension.

---@type Watchdog.ReleaseNote[]
local catalog = {
    {
        version = "1.0.0",
        paragraphs = {
            { title = "Watchdog 1.0.0 is out!" },
            "This is the first release, and my first plugin on RuneScape's new plugin API. I am so excited to bring this to you :D",

            { title = "What are Watchdog Alerts?" },
            "An alert is a trigger wired to an action. The trigger watches the game. The action is what you see or hear. That is the whole idea, and you can build one now.",

            { title = "Setting up your first Alert" },
            "Open the manager with F8 (configurable in settings), or with the Toggle button in the Watchdog panel.",
            "I recommend you start with a Preset. That copies a ready-to-go alert, and you can edit it to your liking.",

            { title = "Using the Alert Editor" },
            "If the editor feels unfamiliar, hit the info button in the top right. That opens the Tutorial, and it is worth a look before you build anything.",
            { image = "releases/tutorial", width = 893, height = 554 },
            "Double-click empty space, or click +, to add a node. Then drag from one pin to another.",
            "You can create a new alert from scratch, or you can start with a Preset. There is a starter pack with a few ready to go, including low life points, low prayer, and low food.",
            "When you have a graph you like, the star in the title bar saves it as your own Preset that you can use later.",

            { title = "Chat permissions and restricted areas" },
            "Game Message and Player Chat triggers and the Game Message action stay unavailable until you grant the chat permission.",
            "In a restricted area, Watchdog will not trigger Spawn, Game Message, or Location triggers.",

            { title = "Planned features" },
            {
                bullets = {
                    "Drag to reorder and group alerts.",
                    "Interactive tutorial.",
                    "Area select, copy/paste, delete operations in editor.",
                    "Display current state of nodes.",
                    "Chat picker for chat nodes.",
                    "More nodes!",
                }
            },

            { title = "Known issues" },
            {
                bullets = {
                    "Angle brackets are stripped from text until an API bug is fixed.",
                    "Have to click twice on some controls in editor until I make my own components.",
                    "Lag when loading sound effects.",
                }
            },
        },
    },
    {
        version = "1.0.1",
        paragraphs = {
            { title = "Watchdog 1.0.1 is out!" },
            "A small one this time. Screen Flash does what the Cycles pin says, Sound Effect can be quieter and repeat, and your old alerts should keep working the way they already do.",

            { title = "Screen Flash" },
            "Cycles is how many times the flash rises and falls. Leave Sticky off and it plays that many, then it stops. Turn Sticky on and it keeps going until something hits Dismiss.",
            "You can use a fraction too. That extra bit is only the next rise. Rise 1, Fall 1, and Cycles 2.5 plays two full flashes, then half of the next rise, and it ends at 4.5 seconds.",
            "If you already had a flash set to dismiss on mouse, keyboard, or both, it still does. Loading it adds a Player Input on Dismiss with those same checks, so you do not have to rebuild it. A flash saved before Sticky existed keeps looping, same as before.",

            { title = "Player Input" },
            "Player Input fires when you move the mouse, click, or press a key. Each of those is a checkbox on the node. Leave it on, turn it off, or wire a bool into it.",

            { title = "Sound Effect" },
            "Sound Effect now has Volume and Loops, same as Custom Sound. Volume is a percent, and 100 is as loud as it goes. Loops starts at 0.",

            { title = "Editor" },
            "Dragged the info box or a toast somewhere and want them back? Reset Positions is on the Watchdog panel, and it puts both back where they started. A long import or export paste shows every line now too.",
        },
    },
}
return catalog
