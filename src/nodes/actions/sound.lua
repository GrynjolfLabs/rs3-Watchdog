local AudioBus = require("src/audio_bus")
local Packs = require("src/packs")
local Controls = require("src/ui/controls")
local SoundEffect = require("src/ui/controls/sound_effect")

local Sound = {}

local DEFAULT_SOUND_ID = id.Sound.TOWN_CRIER_BELL_RING_1

---@param registry LibNodeGraph.Registry
function Sound.Register(registry)
    registry:RegisterNodeType("action.sound", {
        category = "action",
        displayName = "Sound Effect",
        pins = {
            { name = "in",     kind = "exec", direction = "in" },
            AudioBus.Pin(),
            {
                name = "soundId",
                kind = "data",
                direction = "in",
                dataType = "number",
                default = DEFAULT_SOUND_ID
            },
            { name = "volume", kind = "data", direction = "in", dataType = "number", default = 100 },
            { name = "loops",  kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function(ctx)
            -- The registry resolves a raw id or a pack record to the stored
            -- builtin sound id. A pack sound effect has no private hold.
            local soundId = Packs:ResolveSoundEffect(ctx:In("soundId"))
            if soundId ~= nil then
                local volume = ctx:In("volume")
                if type(volume) ~= "number" then volume = 100 end
                local loops = ctx:In("loops")
                if type(loops) ~= "number" then loops = 0 end
                ---@type SoundPlaybackParams
                local params = audio.SoundPlaybackParams.new()
                params.volume = volume / 100
                params.numLoops = loops
                params.audioBus = AudioBus.Resolve(ctx:In("bus"))
                audio.Play(soundId, params)
            end
        end,
    })
end

-- dataType stays "number" so a number output can still wire in. The control
-- is this pin only; other number pins keep the scalar number control.
Controls.RegisterNodePinControl("action.sound", "soundId", SoundEffect)

return Sound
