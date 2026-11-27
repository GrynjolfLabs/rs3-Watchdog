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
        version = "1.1.0",
        paragraphs = {
            { title = "Watchdog 1.1.0 comes out swinging!" },
            "Thank you for trying Watchdog and for all the feedback since 1.0.0. This update makes saving safer, gives you more control over Screen Flash and Sound Effect, and smooths out a few rough edges.",

            { title = "Saving" },
            "Each of your alerts is now saved on its own instead of sharing one save. Your existing alerts move over on their own the first time you load this version, so you do not need to export or rebuild anything.",
            "If a save fails, you will see a \"Could not save\" dialog letting you know the change did not go through and that the last saved copy is still there. If a single alert is too big, it will say \"Too big to save\".",

            { title = "Screen Flash" },
            "Screen Flash now has inputs for Rise, Fall, Cycles, and Sticky. Rise and Fall are in seconds and default to 1. One cycle is a rise followed by a fall. Cycles sets how many pairs of rises and falls play and defaults to 3.",
            "Leave Sticky off to play that count and stop, or turn Sticky on to keep repeating until Dismiss fires.",
            "The old Dismiss On dropdown has been converted into a Player Input node. Any flash saved before Sticky existed loads with Sticky on, and any flash that dismissed on mouse or keyboard automatically gains a Player Input node wired to Dismiss.",

            { title = "Player Input" },
            "Player Input is a new trigger that fires when you move the mouse, click, or press a key. It has checkboxes for Mouse move, Keyboard, and Mouse click, all on by default, and you can toggle them or wire a bool into each.",
            "It replaces the old flash dismiss setting, and you can wire it to any other action too.",

            { title = "Sound Effect" },
            "Sound Effect now has Volume and Loops, matching Custom Sound. Volume is a percentage that defaults to 100.",

            { title = "Presets and Chat Permission" },
            "Creating an alert from a Preset now keeps you on the alert list, since a Preset is already ready to use. Starting a blank alert still opens the editor.",
            "If a new alert or an import includes a Game Message or Player Chat node while chat permission is off, a \"Chat permission\" dialog will remind you that those nodes do nothing until you grant permission.",

            { title = "Editor and Panel" },
            "You will find a new Reset Positions button on the Watchdog panel right under Toggle. Click it to move the infobox and toasts back to their starting spots.",
            "Long import/exports should no longer be cut off prematurely.",
        },
    },
}
return catalog
