-- Pack registry: an in-memory claim of a Pack name and its contributions.
-- Loaded directly, the way the Preset library tests load that library. No PrettyUI.

local luaunit = require("luaunit")
local Packs = require("src/packs")

local function keysOf(value)
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

TestPacks = {}

function TestPacks:setUp()
    self.packs = Packs.new()
end

function TestPacks:tearDown()
    PersistentDB = nil
end

function TestPacks:testNilContributionsClaimsThePackName()
    local token, refusals = self.packs:RegisterDataPack("Voice", nil)
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
end

function TestPacks:testOmittedContributionsClaimsThePackName()
    local token, refusals = self.packs:RegisterDataPack("Voice")
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
end

function TestPacks:testEmptyContributionsClaimsThePackName()
    local token, refusals = self.packs:RegisterDataPack("Voice", {})
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
end

function TestPacks:testBlankNameIsRefusedBeforeTheNameIsClaimed()
    luaunit.assertErrorMsgContentEquals("Pack name is blank.", function()
        self.packs:RegisterDataPack("", nil)
    end)
    -- A second blank call is still a blank name, not a held one.
    luaunit.assertErrorMsgContentEquals("Pack name is blank.", function()
        self.packs:RegisterDataPack("", nil)
    end)
    local token, refusals = self.packs:RegisterDataPack("Voice", nil)
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
end

function TestPacks:testWhitespaceNameIsRefusedTheSameWay()
    luaunit.assertErrorMsgContentEquals("Pack name is blank.", function()
        self.packs:RegisterDataPack("  \t  ", nil)
    end)
    luaunit.assertErrorMsgContentEquals("Pack name is blank.", function()
        self.packs:RegisterDataPack("  \t  ", nil)
    end)
end

function TestPacks:testNonStringNameIsRefusedBeforeTheNameIsClaimed()
    for _, name in ipairs({ 12, true, {} }) do
        luaunit.assertErrorMsgContentEquals("Pack name is blank.", function()
            self.packs:RegisterDataPack(name, nil)
        end)
    end
    local token = self.packs:RegisterDataPack("Voice", nil)
    luaunit.assertNotNil(token)
end

function TestPacks:testPackNamesAreCaseSensitive()
    local upper = self.packs:RegisterDataPack("Voice", nil)
    local lower = self.packs:RegisterDataPack("voice", nil)
    luaunit.assertNotNil(upper)
    luaunit.assertNotNil(lower)
    luaunit.assertErrorMsgContentEquals("Pack name is already held.", function()
        self.packs:RegisterDataPack("Voice", nil)
    end)
    luaunit.assertErrorMsgContentEquals("Pack name is already held.", function()
        self.packs:RegisterDataPack("voice", nil)
    end)
end

function TestPacks:testPackNameIsTrimmedBeforeItIsClaimed()
    local token = self.packs:RegisterDataPack("  Voice  ", nil)
    luaunit.assertNotNil(token)
    luaunit.assertErrorMsgContentEquals("Pack name is already held.", function()
        self.packs:RegisterDataPack("Voice", nil)
    end)
end

function TestPacks:testContributionsThatAreNotATableAreRefusedBeforeTheNameIsClaimed()
    luaunit.assertErrorMsgContentEquals("Contributions must be a table.", function()
        self.packs:RegisterDataPack("Voice", "nope")
    end)
    local token, refusals = self.packs:RegisterDataPack("Voice", nil)
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
end

function TestPacks:testAListFieldThatIsNotATableIsRefusedBeforeTheNameIsClaimed()
    for _, field in ipairs({ "soundEffects", "audioFiles", "alertPresets" }) do
        local packs = Packs.new()
        local contributions = { [field] = "nope" }
        luaunit.assertErrorMsgContentEquals(field .. " must be a list.", function()
            packs:RegisterDataPack("Voice", contributions)
        end)
        local token = packs:RegisterDataPack("Voice", nil)
        luaunit.assertNotNil(token)
    end
end

function TestPacks:testAcceptedSoundEffectStoresTrimmedFieldsAndIgnoresLaterWrites()
    local entry = {
        authorId = "  bell  ",
        label = "  Town bell  ",
        soundId = 2608,
        filename = "bell.wav",
    }
    local token, refusals = self.packs:RegisterDataPack("  Voice  ", {
        soundEffects = { entry },
    })
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
    entry.authorId = "other"
    entry.label = "changed"
    entry.soundId = 1
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", " bell "), {
        authorId = "bell",
        label = "Town bell",
        soundId = 2608,
    })
    luaunit.assertNil(self.packs:GetSoundEffect("voice", "bell"))
    luaunit.assertNil(self.packs:GetSoundEffect("Voice", "Bell"))
end

function TestPacks:testABadSoundEffectIsARefusalAndTheValidSiblingEnters()
    local token, refusals = self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "   ", soundId = 1 },
            { authorId = "chime", label = "Chime", soundId = 2 },
        },
    })
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {
        { kind = "soundEffects", authorId = "bell" },
    })
    luaunit.assertNil(self.packs:GetSoundEffect("Voice", "bell"))
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "chime"), {
        authorId = "chime",
        label = "Chime",
        soundId = 2,
    })
end

function TestPacks:testSoundEffectRefusalsKeepTheAuthorIdThePackPassed()
    local token, refusals = self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "   ", label = "Blank", soundId = 1 },
            { authorId = 4, label = "Number", soundId = 2 },
            "nope",
            { authorId = "label", label = 5, soundId = 3 },
            { authorId = "sound", label = "Sound", soundId = "9" },
            { authorId = "ok", label = "Ok", soundId = 8 },
        },
    })
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {
        { kind = "soundEffects", authorId = "   " },
        { kind = "soundEffects", authorId = 4 },
        { kind = "soundEffects" },
        { kind = "soundEffects", authorId = "label" },
        { kind = "soundEffects", authorId = "sound" },
    })
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "ok"), {
        authorId = "ok",
        label = "Ok",
        soundId = 8,
    })
end

function TestPacks:testDuplicateSoundEffectAuthorIdKeepsTheFirst()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "First", soundId = 1 },
            { authorId = " bell ", label = "Second", soundId = 2 },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "soundEffects", authorId = " bell " },
    })
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 1)
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").label, "First")
end

function TestPacks:testSoundEffectAuthorIdsAreCaseSensitive()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "Bell", label = "Upper", soundId = 1 },
            { authorId = "bell", label = "Lower", soundId = 2 },
        },
    })
    luaunit.assertEquals(refusals, {})
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "Bell").soundId, 1)
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 2)
end

function TestPacks:testAMissingListContributesNothing()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 1 } },
    })
    luaunit.assertEquals(refusals, {})
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 1)
    luaunit.assertNil(self.packs:GetAudioFile("Voice", "bell"))
    luaunit.assertNil(self.packs:GetAlertPreset("Voice", "bell"))
end

function TestPacks:testDuplicateAudioAndAlertPresetAuthorIdsKeepTheFirst()
    local first = { loaded = true, id = "first" }
    local second = { loaded = true, id = "second" }
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "First", audio = first },
            { authorId = "bell", label = "Second", audio = second },
        },
        alertPresets = {
            { authorId = "greet", name = "First", graph = { n = 1 } },
            { authorId = " greet ", name = "Second", graph = { n = 2 } },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "audioFiles", authorId = "bell" },
        { kind = "alertPresets", authorId = " greet " },
    })
    luaunit.assertIs(self.packs:GetAudioFile("Voice", "bell").audio, first)
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").name, "First")
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "greet").graph.n, 1)
end

function TestPacks:testANilHoleEndsTheSoundEffectList()
    local list = {
        { authorId = "bell", label = "Bell", soundId = 5 },
    }
    list[3] = { authorId = "chime", label = "Chime", soundId = 6 }
    local _, refusals = self.packs:RegisterDataPack("Voice", { soundEffects = list })
    luaunit.assertEquals(refusals, {})
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 5)
    luaunit.assertNil(self.packs:GetSoundEffect("Voice", "chime"))
end

function TestPacks:testAFailedClaimLeavesTheAcceptedSoundEffect()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 5 } },
    })
    luaunit.assertErrorMsgContentEquals("Pack name is already held.", function()
        self.packs:RegisterDataPack("  Voice  ", {
            soundEffects = { { authorId = "bell", label = "Other", soundId = 9 } },
        })
    end)
    luaunit.assertErrorMsgContentEquals("Pack name is blank.", function()
        self.packs:RegisterDataPack("   ", {
            soundEffects = { { authorId = "bell", label = "Other", soundId = 9 } },
        })
    end)
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 5)
end

function TestPacks:testAcceptedAudioFileStoresTheResourceAndDoesNotLoadIt()
    local calls = 0
    local resource = {
        loaded = true,
        Load = function() calls = calls + 1 end,
    }
    local entry = {
        authorId = "  bell  ",
        label = "  Town bell  ",
        audio = resource,
        filename = "bell.wav",
    }
    local token, refusals = self.packs:RegisterDataPack("Voice", {
        audioFiles = { entry },
    })
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
    luaunit.assertEquals(calls, 0)
    entry.label = "changed"
    entry.authorId = "other"
    entry.filename = "other.wav"
    local got = self.packs:GetAudioFile("Voice", "bell")
    luaunit.assertEquals(got.authorId, "bell")
    luaunit.assertEquals(got.label, "Town bell")
    luaunit.assertIs(got.audio, resource)
    luaunit.assertEquals(keysOf(got), { "audio", "authorId", "label" })
    luaunit.assertEquals(calls, 0)
end

function TestPacks:testAnAudioFileThatIsMissingOrNotLoadedIsARefusal()
    local unloaded = { loaded = false, Load = function(self) self.loaded = true end }
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "missing", label = "Missing" },
            { authorId = "unloaded", label = "Unloaded", audio = unloaded },
            { authorId = "text", label = "Text", audio = "bell.wav" },
            { authorId = "blank", label = "  ", audio = { loaded = true } },
            { authorId = "ok", label = "Ok", audio = { loaded = true } },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "audioFiles", authorId = "missing" },
        { kind = "audioFiles", authorId = "unloaded" },
        { kind = "audioFiles", authorId = "text" },
        { kind = "audioFiles", authorId = "blank" },
    })
    luaunit.assertEquals(unloaded.loaded, false)
    luaunit.assertNil(self.packs:GetAudioFile("Voice", "unloaded"))
    luaunit.assertEquals(self.packs:GetAudioFile("Voice", "ok").audio.loaded, true)
end

function TestPacks:testTheSameAuthorIdMayEnterOnceInEachKind()
    local resource = { loaded = true }
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 5 } },
        audioFiles = { { authorId = "bell", label = "Bell file", audio = resource } },
        alertPresets = { { authorId = "bell", name = "Bell alert", graph = { nodes = {} } } },
    })
    luaunit.assertEquals(refusals, {})
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 5)
    luaunit.assertIs(self.packs:GetAudioFile("Voice", "bell").audio, resource)
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "bell").name, "Bell alert")
end

function TestPacks:testRefusalsFollowSoundEffectsThenAudioFiles()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        audioFiles = { { authorId = "file", label = "", audio = { loaded = true } } },
        soundEffects = {
            { authorId = "bad", label = "", soundId = 1 },
            { authorId = "also", label = "Ok", soundId = false },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "soundEffects", authorId = "bad" },
        { kind = "soundEffects", authorId = "also" },
        { kind = "audioFiles", authorId = "file" },
    })
end

function TestPacks:testAcceptedAlertPresetCopiesTheSnapshotAndSkipsThePresetLibrary()
    local writes = 0
    PersistentDB = {
        data = {},
        GetString = function(self, key) return self.data[key] end,
        SetString = function(self, key, value)
            writes = writes + 1
            self.data[key] = value
            return true
        end,
    }
    local graph = { nodes = { { type = "action.popup", body = "Hello" } } }
    local layout = { { id = 7, x = 10, y = 20, extra = true } }
    local variables = {
        { nodeId = 7, pinName = "body", label = "Body" },
        { nodeId = 7, pinName = "body" },
        { nodeId = 3, pinName = "hold" },
    }
    local entry = {
        authorId = "  greet  ",
        name = "  Greeting  ",
        graph = graph,
        layout = layout,
        variables = variables,
        id = 99,
    }
    local token, refusals = self.packs:RegisterDataPack("Voice", {
        alertPresets = { entry },
    })
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
    luaunit.assertEquals(writes, 0)
    graph.nodes[1].body = "changed"
    layout[1].x = 99
    variables[1].pinName = "other"
    entry.name = "changed"
    local got = self.packs:GetAlertPreset("Voice", "greet")
    luaunit.assertEquals(got.authorId, "greet")
    luaunit.assertEquals(got.name, "Greeting")
    luaunit.assertEquals(keysOf(got), { "authorId", "graph", "layout", "name", "variables" })
    luaunit.assertEquals(got.graph.nodes[1].body, "Hello")
    luaunit.assertEquals(got.graph.nodes[1].type, "action.popup")
    luaunit.assertFalse(rawequal(got.graph, graph))
    luaunit.assertEquals(got.layout, { { id = 7, x = 10, y = 20 } })
    luaunit.assertEquals(got.variables, {
        { nodeId = 7, pinName = "body" },
        { nodeId = 3, pinName = "hold" },
    })
end

function TestPacks:testAlertPresetNameFollowsThePresetLengthRule()
    local eighty = string.rep("a", 80)
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            { authorId = "blank", name = "   ", graph = {} },
            { authorId = "long", name = " " .. string.rep("b", 81), graph = {} },
            { authorId = "text", name = 12, graph = {} },
            { authorId = "fits", name = "  " .. eighty .. "  ", graph = { ok = true } },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "alertPresets", authorId = "blank" },
        { kind = "alertPresets", authorId = "long" },
        { kind = "alertPresets", authorId = "text" },
    })
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "fits").name, eighty)
    luaunit.assertNil(self.packs:GetAlertPreset("Voice", "blank"))
end

function TestPacks:testAlertPresetGraphMustBeATable()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            { authorId = "none", name = "None" },
            { authorId = "text", name = "Text", graph = "[]" },
            { authorId = "ok", name = "Ok", graph = {} },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "alertPresets", authorId = "none" },
        { kind = "alertPresets", authorId = "text" },
    })
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "ok").graph, {})
end

function TestPacks:testAlertPresetLayoutMustBeAnArrayOfPlacements()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            { authorId = "map", name = "Map", graph = {}, layout = { id = 1, x = 0, y = 0 } },
            { authorId = "mixed", name = "Mixed", graph = {}, layout = { { id = 1 }, note = true } },
            { authorId = "row", name = "Row", graph = {}, layout = { "nope" } },
            { authorId = "id", name = "Id", graph = {}, layout = { { id = "1", x = 0, y = 0 } } },
            { authorId = "x", name = "X", graph = {}, layout = { { id = 1, x = false, y = 0 } } },
            { authorId = "y", name = "Y", graph = {}, layout = { { id = 1, x = 0, y = "2" } } },
            {
                authorId = "ok",
                name = "Ok",
                graph = { nodes = {} },
                layout = { { id = 99 }, { id = 4, x = 0, y = 3 } },
            },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "alertPresets", authorId = "map" },
        { kind = "alertPresets", authorId = "mixed" },
        { kind = "alertPresets", authorId = "row" },
        { kind = "alertPresets", authorId = "id" },
        { kind = "alertPresets", authorId = "x" },
        { kind = "alertPresets", authorId = "y" },
    })
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "ok").layout, {
        { id = 99, x = 0, y = 0 },
        { id = 4, x = 0, y = 3 },
    })
end

function TestPacks:testAMissingLayoutOrVariableListIsEmpty()
    local got = self.packs:RegisterDataPack("Voice", {
        alertPresets = { { authorId = "bare", name = "Bare", graph = { version = 1 } } },
    })
    luaunit.assertNotNil(got)
    local preset = self.packs:GetAlertPreset("Voice", "bare")
    luaunit.assertEquals(preset.layout, {})
    luaunit.assertEquals(preset.variables, {})
    luaunit.assertEquals(preset.graph.version, 1)
end

function TestPacks:testAlertPresetVariablesMustBeAListOfPins()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        alertPresets = {
            { authorId = "map", name = "Map", graph = {}, variables = { nodeId = 1, pinName = "body" } },
            { authorId = "row", name = "Row", graph = {}, variables = { "nope" } },
            { authorId = "node", name = "Node", graph = {}, variables = { { nodeId = "1", pinName = "body" } } },
            { authorId = "pin", name = "Pin", graph = {}, variables = { { nodeId = 1, pinName = 2 } } },
            {
                authorId = "ok",
                name = "Ok",
                graph = {},
                variables = {
                    { nodeId = 5, pinName = "z" },
                    { nodeId = 5, pinName = "z", label = "later" },
                    { nodeId = 1, pinName = "a" },
                },
            },
        },
    })
    luaunit.assertEquals(refusals, {
        { kind = "alertPresets", authorId = "map" },
        { kind = "alertPresets", authorId = "row" },
        { kind = "alertPresets", authorId = "node" },
        { kind = "alertPresets", authorId = "pin" },
    })
    luaunit.assertEquals(self.packs:GetAlertPreset("Voice", "ok").variables, {
        { nodeId = 5, pinName = "z" },
        { nodeId = 1, pinName = "a" },
    })
end

function TestPacks:testRefusalsFollowSoundEffectsThenAudioFilesThenAlertPresets()
    local _, refusals = self.packs:RegisterDataPack("Voice", {
        alertPresets = { { authorId = "preset", name = "", graph = {} } },
        audioFiles = { { authorId = "file", label = "File" } },
        soundEffects = { { authorId = "bell", label = "Bell", soundId = "nope" } },
    })
    luaunit.assertEquals(refusals, {
        { kind = "soundEffects", authorId = "bell" },
        { kind = "audioFiles", authorId = "file" },
        { kind = "alertPresets", authorId = "preset" },
    })
end

function TestPacks:testClearReleasesOnlyTheReturnedToken()
    local token = self.packs:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 5 } },
    })
    self.packs:Clear("Voice")
    self.packs:Clear({})
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 5)
    self.packs:Clear(token)
    luaunit.assertNil(self.packs:GetSoundEffect("Voice", "bell"))
    local again = self.packs:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Next", soundId = 6 } },
    })
    self.packs:Clear(token)
    luaunit.assertEquals(self.packs:GetSoundEffect("Voice", "bell").soundId, 6)
    self.packs:Clear(again)
    luaunit.assertNil(self.packs:GetSoundEffect("Voice", "bell"))
    self.packs:Clear(again)
    luaunit.assertNil(self.packs:GetSoundEffect("Voice", "bell"))
end

function TestPacks:testAFreshRegistryStartsEmptyAndIsNotPersisted()
    local writes = 0
    PersistentDB = {
        GetString = function() return "stale" end,
        SetString = function() writes = writes + 1 end,
    }
    luaunit.assertNil(self.packs:GetSoundEffect("Voice", "bell"))
    luaunit.assertNil(self.packs:GetAudioFile("Voice", "bell"))
    luaunit.assertNil(self.packs:GetAlertPreset("Voice", "greet"))
    local token, refusals = self.packs:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 1 } },
        audioFiles = { { authorId = "bell", label = "File", audio = { loaded = true } } },
        alertPresets = { { authorId = "bell", name = "Bell", graph = {} } },
    })
    luaunit.assertNotNil(token)
    luaunit.assertEquals(refusals, {})
    luaunit.assertEquals(writes, 0)
    local fresh = Packs.new()
    luaunit.assertNil(fresh:GetSoundEffect("Voice", "bell"))
    luaunit.assertNil(fresh:GetAudioFile("Voice", "bell"))
    luaunit.assertNil(fresh:GetAlertPreset("Voice", "bell"))
end

function TestPacks:testHeldNameIsRefusedAndLeavesTheRegistration()
    local token = self.packs:RegisterDataPack("Voice", nil)
    luaunit.assertErrorMsgContentEquals("Pack name is already held.", function()
        self.packs:RegisterDataPack("Voice", nil)
    end)
    -- The token from the first call still releases the name, so the refusal did not replace it.
    self.packs:Clear(token)
    local again, refusals = self.packs:RegisterDataPack("Voice", nil)
    luaunit.assertNotNil(again)
    luaunit.assertEquals(refusals, {})
end
