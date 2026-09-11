-- Modifiers.lua — Target Heal Modifier Tracking
-- Part of HealEngine-1.0 split architecture
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn

local Engine = LibStub("HealEngine-1.0")
if not Engine then return end

---------------------------------------------------------------------------
-- Local aliases from Engine
---------------------------------------------------------------------------
local unitMap    = Engine.unitMap
local targetMods = Engine.targetMods
local unitHasBuff = Engine.unitHasBuff

local wipe          = wipe
local pairs         = pairs
local mathmax       = math.max
local UnitAura      = UnitAura
local UnitHealthMax = UnitHealthMax

---------------------------------------------------------------------------
-- HEAL MODIFIER TRACKING (target buffs/debuffs)
---------------------------------------------------------------------------
-- Flat multipliers keyed by spellID (matched to LHC4 reference)
local HEAL_MODS = {
    -- Necrotic Poison
    [28776] = 0.10, -- Necrotic Poison (Naxx)
    [36693] = 0.55, -- Necrotic Poison (TK)
    [46296] = 0.25, -- Necrotic Poison (SWP)
    -- Gehennas' Curse
    [19716] = 0.25, -- Gehennas' Curse
    -- Mortal Strike (NPC variants)
    [13737] = 0.50, [15708] = 0.50, [16856] = 0.50, [17547] = 0.50,
    [19643] = 0.50, [24573] = 0.50, [27580] = 0.50, [29572] = 0.50,
    [31911] = 0.50, [32736] = 0.50, [35054] = 0.50, [37335] = 0.50,
    [39171] = 0.50, [40220] = 0.50, [44268] = 0.50, [43441] = 0.50,
    -- Mortal Strike (player ranks 1-6)
    [12294] = 0.50, [21551] = 0.50, [21552] = 0.50, [21553] = 0.50,
    [25248] = 0.50, [30330] = 0.50,
    -- Enfeeble (Prince Malchezaar)
    [30843] = 0.00,
    -- Aimed Shot (ranks 1-7)
    [19434] = 0.50, [20900] = 0.50, [20901] = 0.50, [20902] = 0.50,
    [20903] = 0.50, [20904] = 0.50, [27065] = 0.50,
    -- Demolish
    [34625] = 0.25,
    -- Solar Strike, Soul Strike, Filet
    [35189] = 0.50, [32315] = 0.50, [32378] = 0.50,
    -- Magma-Thrower's Curse
    [36917] = 0.50,
    -- Wretched Strike
    [44534] = 0.50,
    -- Ebon Poison
    [34366] = 0.75,
    -- Deathblow
    [36023] = 0.50, [36054] = 0.50,
    -- Shadow Spike
    [45885] = 0.50,
    -- Aura of Suffering (Reliquary of Souls)
    [41292] = 0.00,
    -- Arcing Smash
    [40599] = 0.50,
    -- Hex of Weakness (ranks 1-6) — NOT Aimed Shot!
    [9035]  = 0.80, [19281] = 0.80, [19282] = 0.80,
    [19283] = 0.80, [19284] = 0.80, [25470] = 0.80,
    -- Curse of the Bleeding Hollow
    [34073] = 0.85,
    -- Magic Dampening Field (SWP)
    [44475] = 0.25,
    -- Brood Affliction: Green (BWL)
    [23169] = 0.50,
    -- Mortal Cleave
    [22859] = 0.50, [38572] = 0.50, [39595] = 0.50,
    -- Darkness (M'uru)
    [45996] = 0.00,
    -- Aura of Desire (Reliquary of Souls) — INCREASES healing
    [41350] = 2.00,
    -- Fel Armor (Warlock buff)
    [28176] = 1.20,
    -- Veil of Shadow
    [7068]  = 0.25, [17820] = 0.25, [22687] = 0.25,
    [23224] = 0.25, [24674] = 0.25, [28440] = 0.25,
    -- Curse of the Deadwood
    [13583] = 0.50,
    -- Blood Fury (Orc racial)
    [23230] = 0.50,
    -- Curse of Infinity
    [31977] = 1.50,
}

-- Flat healing reduction debuffs (value = flat amount subtracted from each heal)
-- These are converted to a dynamic percentage based on target max health at scan time
local HEAL_FLAT_MODS = {
    -- Touch of the Forgotten (Mana-Tombs)
    [32858] = 345,   -- Reduces healing received by 345
    [38377] = 690,   -- Reduces healing received by 690 (heroic)
}

-- Stack-based modifiers (amount scales with stacks)
local HEAL_STACK_MODS = {
    -- Mortal Wound
    [25646] = function(s) return 1 - s * 0.10 end,
    [28467] = function(s) return 1 - s * 0.10 end,
    [30641] = function(s) return 1 - s * 0.05 end,
    [31464] = function(s) return 1 - s * 0.10 end,
    [36814] = function(s) return 1 - s * 0.10 end,
    [38770] = function(s) return 1 - s * 0.05 end,
    -- Dark Touched (Eredar Twins)
    [45347] = function(s) return 1 - s * 0.05 end,
    -- Nether Portal - Dominance
    [30423] = function(s) return 1 - s * 0.01 end,
    -- Wound Poison (ranks 1-5) — stack-based, NOT flat
    [13218] = function(s) return 1 - s * 0.10 end,
    [13222] = function(s) return 1 - s * 0.10 end,
    [13223] = function(s) return 1 - s * 0.10 end,
    [13224] = function(s) return 1 - s * 0.10 end,
    [27189] = function(s) return 1 - s * 0.10 end,
}

-- Boss debuffs on player (personal healing output reduction)
local PLAYER_DEBUFF_IDS = {
    [32346] = 0.50,  -- Stolen Soul
    [40099] = 0.50,  -- Vile Slime
    [38246] = 0.50,  -- Vile Sludge
    [45573] = 0.50,  -- Vile Sludge (variant)
    [31306] = 0.25,  -- Carrion Swarm (Anetheron, Mount Hyjal) — reduces the afflicted player's own healing done, not healing received
}

---------------------------------------------------------------------------
-- SCANNING TARGET HEALING MODIFIERS
---------------------------------------------------------------------------
local seenNames = {}

local function scanTargetMods(unit, guid)
    if not unitMap[guid] then return end

    local up, down = 1, 1
    wipe(seenNames)

    -- Buffs
    local i = 1
    while true do
        local name, _, stacks, _, _, _, _, _, _, spellID = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if not seenNames[name] then
            seenNames[name] = true
            if HEAL_MODS[spellID] then
                up = up * HEAL_MODS[spellID]
            elseif HEAL_STACK_MODS[spellID] then
                up = up * HEAL_STACK_MODS[spellID](stacks or 1)
            end
        end
        i = i + 1
    end

    -- Debuffs (percentage-based and flat)
    local flatTotal = 0
    i = 1
    while true do
        local name, _, stacks, _, _, _, _, _, _, spellID = UnitAura(unit, i, "HARMFUL")
        if not name then break end
        if HEAL_MODS[spellID] then
            down = down * HEAL_MODS[spellID]
        elseif HEAL_STACK_MODS[spellID] then
            down = down * HEAL_STACK_MODS[spellID](stacks or 1)
        elseif HEAL_FLAT_MODS[spellID] then
            flatTotal = flatTotal + HEAL_FLAT_MODS[spellID]
        end
        i = i + 1
    end

    -- Convert flat healing reduction to a percentage based on target max health
    if flatTotal > 0 then
        local maxHP = UnitHealthMax(unit) or 1
        if maxHP > 0 then
            -- flat / maxHP gives the fraction of health the reduction represents
            -- Clamp to 0..1 so the modifier never goes negative
            down = down * mathmax(0, 1 - flatTotal / maxHP)
        end
    end

    local mod = up * down
    if mod ~= targetMods[guid] then
        if targetMods[guid] or mod ~= 1 then
            targetMods[guid] = mod
            Engine.callbacks:Fire("HealComm_ModifierChanged", guid, mod)
        else
            targetMods[guid] = mod
        end
    end

    -- Player-specific modifiers (output side)
    if unit == "player" then
        local pDown = 1
        local unitHasDebuff = Engine.unitHasDebuff
        for debuffID, mult in pairs(PLAYER_DEBUFF_IDS) do
            if unitHasDebuff("player", debuffID) then
                pDown = pDown * mult
            end
        end
        Engine.myHealMod = pDown
    end
end

---------------------------------------------------------------------------
-- Expose on Engine table
---------------------------------------------------------------------------
Engine.scanTargetMods    = scanTargetMods
Engine.HEAL_MODS         = HEAL_MODS
Engine.HEAL_STACK_MODS   = HEAL_STACK_MODS
Engine.HEAL_FLAT_MODS    = HEAL_FLAT_MODS
Engine.PLAYER_DEBUFF_IDS = PLAYER_DEBUFF_IDS
