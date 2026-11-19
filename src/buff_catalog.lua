-- Names for buff icons, the Common row, and "any of" groups for item buffs.
--
-- Sprite and item names come from the game's own lists ("pan Sprite" and "pan Obj").
-- Each id is looked up by its internal name when first used, so a game update that
-- renumbers icons keeps working. The number beside each name is only a fallback.

local BuffCatalog = {}

-- { internal sprite name, fallback id, label }
local SPRITES = {
    -- Seen on the buff bar; the game gives this icon a generic name.
    { "AIF_ATTRIB_CONSTITUTION_ICONS_1_1", 14268, "Incite" },
    -- The game numbers its combat buff icons; each is named once it's been seen on the bar.
    { "COMBAT_ICON_BUFF_0", 26093, "Overload" },
    { "COMBAT_ICON_BUFF_2", 26095, "Familiar" },
    { "BUFF_ICON_SPELL_STANDARD_COMBAT_TEMPORAL_ANOMALY", 1368, "Temporal anomaly" },
    { "BUFF_ICON_SPELL_LUNAR_SKILLING_FAST_ROCKERTUNITY", 1369, "Fast rockertunity" },
    { "BUFF_ICON_SPELL_LUNAR_SKILLING_LONGER_LUMBERJACK", 1370, "Longer lumberjack" },
    { "BUFF_ICON_SPELL_LUNAR_SKILLING_REPLENISH_ESSENCE", 1371, "Replenish essence" },
    { "COMBAT_BUFF_ICON_ARCH_RELIC_BERSERKERS_FURY", 10492, "Berserker's fury" },
    { "COMBAT_BUFF_ICON_ARCH_RELIC_CONSERVATION_OF_ENERGY", 10493, "Conservation of energy" },
    { "COMBAT_BUFF_ICON_ARCH_RELIC_DEATH_WARD", 10494, "Death ward" },
    { "COMBAT_BUFF_ICON_ARCH_RELIC_FURY_OF_THE_SMALL", 10495, "Fury of the small" },
    { "SKILL_BUFF_ICON_ARCH_EXCAVATION_FOCUS", 10496, "Excavation focus" },
    { "SKILL_BUFF_ICON_ARCH_PYLON_CHARGE", 10497, "Pylon charge" },
    { "SKILL_BUFF_ICON_ARCH_ORTHEN_ANACHRONIA", 12035, "Orthen anachronia" },
    { "BUFF_ICON_ANCIENT_MAGICKS_ANIMATE_DEAD", 14764, "Animate dead" },
    { "BUFF_ICON_ANCIENT_MAGICKS_EXSANGUINATE", 14765, "Exsanguinate" },
    { "BUFF_ICON_ANCIENT_MAGICKS_INCITE_FEAR", 14766, "Incite fear" },
    { "BUFF_ICON_MAGIC_ASPHYXIATE", 17606, "Asphyxiate" },
    { "BUFF_ICON_WEN_ICY_CHILL", 19116, "Icy chill" },
    { "BUFF_ICON_WEN_PRECISION", 19117, "Precision" },
    { "DEBUFF_ICON_BIK_EVOLVING_TOXIN", 19118, "Evolving toxin" },
    { "BUFF_ICON_BLOOD_KNIGHT_CROSSBOW", 19219, "Blood knight crossbow" },
    { "DEBUFF_ICON_BLOOD_KNIGHT_BOSS_EXSANGUINATED", 19220, "Blood knight boss exsanguinated" },
    { "DEBUFF_ICON_BLOOD_KNIGHT_BOSS_ISOLATE", 19221, "Blood knight boss isolate" },
    { "DEBUFF_ICON_BLOOD_KNIGHT_BOSS_BLOOD_BOUND", 19222, "Blood knight boss blood bound" },
    { "BUFF_ICON_EGW_GUTHIX_RUNE_A", 20225, "Egw guthix rune a" },
    { "BUFF_ICON_EGW_GUTHIX_RUNE_B", 20226, "Egw guthix rune b" },
    { "BUFF_ICON_EGW_GUTHIX_RUNE_E", 20227, "Egw guthix rune e" },
    { "BUFF_ICON_EGW_GUTHIX_RUNE_H", 20228, "Egw guthix rune h" },
    { "BUFF_ICON_EGW_GUTHIX_RUNE_V", 20229, "Egw guthix rune v" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_A", 20230, "Egw zamorak rune a" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_B", 20231, "Egw zamorak rune b" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_E", 20259, "Egw zamorak rune e" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_H", 20264, "Egw zamorak rune h" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_V", 20265, "Egw zamorak rune v" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_A_GREY", 20266, "Egw zamorak rune a grey" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_B_GREY", 20267, "Egw zamorak rune b grey" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_E_GREY", 20271, "Egw zamorak rune e grey" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_H_GREY", 20276, "Egw zamorak rune h grey" },
    { "BUFF_ICON_EGW_ZAMORAK_RUNE_V_GREY", 20277, "Egw zamorak rune v grey" },
    { "DEBUFF_ICON_EGWD_INFERNUS_CHOKING", 20293, "Egwd infernus choking" },
    { "DEBUFF_ICON_BLOOD_KNIGHT_BOSS_LORD_GHRAZI_ANTITANK", 20600, "Blood knight boss lord ghrazi antitank" },
    { "DEBUFF_ICON_BLOOD_KNIGHT_BOSS_LADY_GHRAZI_ANTITANK", 22188, "Blood knight boss lady ghrazi antitank" },
    { "DEBUFF_ICON_BLOOD_KNIGHT_BOSS_SANGUINE_STRIKE", 23338, "Blood knight boss sanguine strike" },
    { "BUFF_ICON_MELEE_BLOODLUST", 23875, "Bloodlust" },
    { "BUFF_ICON_MELEE_BLOODLUST_INACTIVE", 23876, "Bloodlust (inactive)" },
    { "BUFF_ICON_RANGED_SEARING_WINDS", 23877, "Searing winds" },
    { "BUFF_ICON_CONSTITUTION_VAMPYRE_SLAYER", 24776, "Vampyre slayer" },
    { "DEBUFF_ICON_BLEED", 24802, "Bleed" },
    { "BUFF_ICON_SKILLING_BRAZIER", 24803, "Brazier" },
    { "BUFF_ICON_NECROMANCY_INVOKE_ARISEN_FLESH", 24804, "Arisen flesh" },
    { "BUFF_ICON_BALANCE_BY_FORCE", 25515, "Balance by force" },
    { "COMBAT_BUFF_ICON_WATER_BOSS_DAMPEN_32PX", 30023, "Water boss dampen" },
    { "COMBAT_BUFF_ICON_WATER_BOSS_DRENCHED_27PX", 30024, "Water boss drenched" },
    { "COMBAT_BUFF_ICON_WATER_BOSS_NO_STUN_32PX", 30025, "Water boss no stun" },
    { "COMBAT_BUFF_ICON_WATER_BOSS_SHARKNADO_32PX", 30026, "Water boss sharknado" },
    { "COMBAT_BUFF_ICON_WATER_BOSS_SICKENED_32PX", 30027, "Water boss sickened" },
    { "COMBAT_BUFF_ICON_WATER_BOSS_TENTACLE_32PX", 30028, "Water boss tentacle" },
    { "DEBUFF_ICON_EXTREME_VULNERABILITY", 30092, "Extreme vulnerability" },
    { "BUFF_ICON_ANTI_DRAGONFIRE", 30093, "Antifire" },
    { "BUFF_ICON_ANTI_POISON", 30094, "Antipoison" },
    { "BUFF_ICON_WEAPON_POISON", 30095, "Weapon poison" },
    { "DEBUFF_ICON_DRAGONFIRE", 30096, "Dragonfire" },
    { "DEBUFF_ICON_POISONED", 30097, "Poisoned" },
    { "BUFF_ICON_NECROMANCY_BLOATED", 30098, "Bloated" },
    { "BUFF_ICON_NECROMANCY_BONE_SHIELD", 30099, "Bone shield" },
    { "BUFF_ICON_NECROMANCY_INVOKE_DEATH", 30100, "Invoke death" },
    { "BUFF_ICON_NECROMANCY_NECROSIS", 30101, "Necrosis" },
    { "BUFF_ICON_NECROMANCY_DARKNESS", 30122, "Darkness" },
    { "BUFF_ICON_NECROMANCY_RESIDUAL_SOUL", 30123, "Residual soul" },
    { "BUFF_ICON_NECROMANCY_SKILL_NEUTRAL", 30124, "Necromancy skill (neutral)" },
    { "BUFF_ICON_NECROMANCY_SKILL", 30125, "Necromancy skill" },
    { "BUFF_ICON_NECROMANCY_SPLIT_SOUL", 30126, "Split soul" },
    { "BUFF_ICON_NECROMANCY_NECRO_RASIAL_ARMGUARD_T95", 30127, "Rasial armguard" },
    { "BUFF_ICON_NECROMANCY_NECRO_RASIAL_ARMGUARD_T95_INACTIVE", 30128, "Rasial armguard (inactive)" },
    { "BUFF_ICON_NECROMANCY_THREADS_OF_FATE", 30129, "Threads of fate" },
    { "DEBUFF_ICON_NECROMANCY_HAUNTED", 30212, "Haunted" },
    { "DEBUFF_ICON_NECROMANCY_SKILL", 30213, "Necromancy skill" },
    { "BUFF_ICON_EVENT_BONANZA_UNIVERSAL", 31535, "Bonanza event" },
    { "BUFF_ICON_RANGED_IMBUED_SHADOWS", 31925, "Imbued shadows" },
    { "BUFF_ICON_NECROMANCY_LORD_OF_BONES", 33145, "Lord of bones" },
    { "DEBUFF_ICON_NECROMANCY_SHATTERING_BONES", 33146, "Shattering bones" },
    { "BUFF_ICON_EGW_GUTHIX_RUNE_B_GREY", 33554, "Egw guthix rune b grey" },
    { "BUFF_ICON_EGW_GUTHIX_RUNE_H_GREY", 33555, "Egw guthix rune h grey" },
    { "BUFF_ICON_COMBAT_ADRENALINE_CRIT", 33962, "Adrenaline crit" },
    { "BUFF_ICON_COMBAT_ADRENALINE_INCREASED", 33963, "Adrenaline increased" },
    { "DEBUFF_ICON_COMBAT_ADRENALINE_REDUCED", 33964, "Adrenaline reduced" },
    { "DEBUFF_ICON_RAID_REBIRTH_ANCHORED", 33967, "Raid rebirth anchored" },
    { "BUFF_ICON_RESURRECTION_DAMAGE_IMMUNITY", 33973, "Resurrection damage immunity" },
    { "BUFF_ICON_RESURRECTION", 33974, "Resurrection" },
    { "DEBUFF_ICON_RESURRECTION_SICKNESS", 33976, "Resurrection sickness" },
    { "BUFF_ICON_NECROMANCY_SPIRIT_SKELETON_WARRIOR", 34177, "Skeleton warrior" },
    { "BUFF_ICON_NECROMANCY_SPIRIT_VENGEFUL_GHOST", 34178, "Vengeful ghost" },
    { "BUFF_ICON_NECROMANCY_SPIRIT_PUTRID_ZOMBIE", 34179, "Putrid zombie" },
    { "BUFF_ICON_NECROMANCY_SPIRIT_PHANTOM_GUARDIAN", 34180, "Phantom guardian" },
    { "DEBUFF_ICON_IRONMAN_GROUP_COMPETITION_DROP", 34513, "Group competition drop" },
    { "BUFF_ICON_EGWD_JAS_BOSS_MAGIC_SURGING_STORM", 34997, "Egwd jas boss magic surging storm" },
    { "DEBUFF_ICON_EGWD_FUL_BOSS_MELEE_SEARED", 34998, "Egwd ful boss melee seared" },
    { "DEBUFF_ICON_EGWD_FUL_BOSS_MELEE_SCORCHED", 34999, "Egwd ful boss melee scorched" },
    { "BUFF_ICON_AMASCUT_BOSS_CHAIN_REACTION_STACKS", 35061, "Chain reaction" },
    { "BUFF_ICON_AMASCUT_BOSS_NO_TANK", 35062, "Amascut boss no tank" },
    { "BUFF_ICON_AMASCUT_BOSS_APMEKEN", 35063, "Amascut boss apmeken" },
    { "BUFF_ICON_AMASCUT_BOSS_CRONDIS", 35064, "Amascut boss crondis" },
    { "BUFF_ICON_AMASCUT_BOSS_HET", 35065, "Amascut boss het" },
    { "BUFF_ICON_AMASCUT_BOSS_SCABARAS", 35066, "Amascut boss scabaras" },
    { "BUFF_ICON_AMASCUT_BOSS_TUMEKEN", 35067, "Amascut boss tumeken" },
    { "BUFF_ICON_NECROMANCY_NECRO_DEVOURER_ARMGUARD_T95", 35068, "Devourer armguard" },
    { "BUFF_ICON_NECROMANCY_NECRO_DEVOURER_ARMGUARD_T95_INACTIVE", 35069, "Devourer armguard (inactive)" },
    { "BUFF_ICON_ANCIENT_MAGICKS_VAMPYRISM", 35768, "Vampyrism" },
    { "BUFF_ICON_SPELL_STANDARD_COMBAT_PENANCE", 35769, "Penance" },
}

-- Item buffs come in tiers and doses, so these match any item whose name contains `match`.
-- Some show on the bar as a sprite instead of the item, so `sprites` lists those by
-- internal name (each must also be in SPRITES).
-- `icon` is the internal item name shown in the picker; it must name a matching item.
local GROUPS = {
    { key = "porter", label = "Sign of the porter", match = "sign of the porter",
      icon = { "DIV_SIGN_PORTER7", 51490 } },
    { key = "overload", label = "Overload", match = "overload",
      sprites = { "COMBAT_ICON_BUFF_0" },
      icon = { "_4DOSEOVERLOAD", 15332 } },
    { key = "prayer_renewal", label = "Prayer renewal", match = "prayer renewal",
      icon = { "_4DOSEPRAYERRENEW", 21630 } },
    { key = "aggression", label = "Aggression potion", match = "aggression",
      icon = { "_4DOSEWILDERNESS_AGGRESSION_POTION", 37971 } },
}

-- The Common row, in order. Groups by key, sprites by internal name.
local COMMON = {
    { group = "porter" },
    { group = "overload" },
    { group = "prayer_renewal" },
    { group = "aggression" },
    { sprite = "COMBAT_ICON_BUFF_2" },
    { sprite = "BUFF_ICON_ANTI_DRAGONFIRE" },
    { sprite = "BUFF_ICON_ANTI_POISON" },
    { sprite = "BUFF_ICON_WEAPON_POISON" },
    { sprite = "DEBUFF_ICON_POISONED" },
    { sprite = "BUFF_ICON_NECROMANCY_DARKNESS" },
    { sprite = "BUFF_ICON_NECROMANCY_BONE_SHIELD" },
    { sprite = "BUFF_ICON_ANCIENT_MAGICKS_ANIMATE_DEAD" },
}

local function lookup(idTable, name, fallback)
    local ok, value = pcall(function() return idTable[name] end)
    if ok and math.type(value) == "integer" then
        return value
    end
    return fallback
end

local spriteById, spriteByName

local function buildSprites()
    if spriteById ~= nil then return end
    spriteById, spriteByName = {}, {}
    for _, row in ipairs(SPRITES) do
        local entry = { id = lookup(id.Sprite, row[1], row[2]), label = row[3] }
        spriteByName[row[1]] = entry
        if spriteById[entry.id] == nil then
            spriteById[entry.id] = entry.label
        end
    end
end

local objNames = {}

--- The item's display name, or nil. Cached, because the bar is read every tick.
---@param objId integer
---@return string|nil
function BuffCatalog.ObjName(objId)
    local cached = objNames[objId]
    if cached == nil then
        local ok, object = pcall(config.Obj.FromID, objId)
        cached = (ok and object ~= nil and type(object.name) == "string") and object.name or false
        objNames[objId] = cached
    end
    return cached or nil
end

---@param spriteId integer
---@return string|nil
function BuffCatalog.SpriteLabel(spriteId)
    buildSprites()
    return spriteById[spriteId]
end

---@param key string
function BuffCatalog.Group(key)
    for _, group in ipairs(GROUPS) do
        if group.key == key then return group end
    end
    return nil
end

--- The item id to show for a group, or nil if that item no longer matches the group.
function BuffCatalog.GroupIcon(group)
    local objId = lookup(id.Obj, group.icon[1], group.icon[2])
    local name = BuffCatalog.ObjName(objId)
    if name ~= nil and name:lower():find(group.match, 1, true) then
        return objId
    end
    return nil
end

--- A readable name for a buff read from the bar.
---@param buff { kind: string, id: integer }
---@return string
function BuffCatalog.Describe(buff)
    local name
    if buff.kind == "obj" then
        name = BuffCatalog.ObjName(buff.id)
    else
        name = BuffCatalog.SpriteLabel(buff.id)
    end
    return name or ("Icon " .. tostring(buff.id))
end

--- A pick for this buff, as stored on the node.
---@return Watchdog.BuffPick
function BuffCatalog.PickFor(buff)
    return { kind = buff.kind, id = buff.id, name = BuffCatalog.Describe(buff) }
end

--- The name a pick is shown and announced with.
---@param pick Watchdog.BuffPick|nil
---@return string|nil
function BuffCatalog.PickName(pick)
    if type(pick) ~= "table" then return nil end
    if pick.kind == "group" then
        local group = BuffCatalog.Group(pick.group)
        return (group and group.label) or pick.name
    end
    if pick.name ~= nil and pick.name ~= "" then return pick.name end
    if pick.id == nil then return nil end
    return BuffCatalog.Describe(pick)
end

--- Whether a buff read from the bar is the one a pick means.
function BuffCatalog.Matches(pick, buff)
    if pick.kind == "group" then
        local group = BuffCatalog.Group(pick.group)
        if group == nil then return false end
        if buff.kind == "sprite" then
            buildSprites()
            for _, spriteName in ipairs(group.sprites or {}) do
                local entry = spriteByName[spriteName]
                if entry ~= nil and entry.id == buff.id then return true end
            end
            return false
        end
        if buff.kind ~= "obj" then return false end
        local name = BuffCatalog.ObjName(buff.id)
        return name ~= nil and name:lower():find(group.match, 1, true) ~= nil
    end
    return buff.kind == pick.kind and buff.id == pick.id
end

--- The Common row as picks.
---@return Watchdog.BuffPick[]
function BuffCatalog.Common()
    buildSprites()
    local picks = {}
    for _, row in ipairs(COMMON) do
        if row.group ~= nil then
            local group = BuffCatalog.Group(row.group)
            picks[#picks + 1] = { kind = "group", group = group.key, name = group.label }
        else
            local entry = spriteByName[row.sprite]
            if entry ~= nil then
                picks[#picks + 1] = { kind = "sprite", id = entry.id, name = entry.label }
            end
        end
    end
    return picks
end

return BuffCatalog
