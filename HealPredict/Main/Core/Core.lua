-- HealPredict - Core.lua
-- Globals, colors, settings, spell data, frame tracking, aura scanning
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn

local ADDON_NAME = ...
local MetadataFn = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
local VERSION = MetadataFn and string.match(MetadataFn(ADDON_NAME, "Version") or "", "^(%d+%.%d+%.%d+[%.%d]*)$")

local Engine = LibStub("HealEngine-1.0")
local HEAL_MASK_OVERTIME = bit.bor(Engine.HOT_HEALS, Engine.CHANNEL_HEALS)
local isTBC = Engine.isTBC

---------------------------------------------------------------------------
-- Upvalued globals
---------------------------------------------------------------------------
local bit_band, bit_bor, bit_bnot = bit.band, bit.bor, bit.bnot
local fmt, mathmin, mathmax, mathfloor = format, min, max, math.floor
local pairs, ipairs, next, wipe, select = pairs, ipairs, next, wipe, select
local unpack, tinsert, type = unpack, tinsert, type

local GetTime = GetTime
local CreateColor = CreateColor
local UnitGUID = UnitGUID
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitCanAssist = UnitCanAssist
local UnitBuff = UnitBuff
local UnitDebuff = UnitDebuff
local UnitIsConnected = UnitIsConnected
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local InCombatLockdown = InCombatLockdown
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local CastingInfo = CastingInfo
local GetSpellPowerCost = GetSpellPowerCost
local UnitPower, UnitPowerMax = UnitPower, UnitPowerMax
local GetNumGroupMembers = GetNumGroupMembers
local UnitExists, UnitName, UnitClass = UnitExists, UnitName, UnitClass

---------------------------------------------------------------------------
-- Shield spell IDs (TBC)
---------------------------------------------------------------------------
local SHIELD_SPELLS = {
    -- Power Word: Shield (Priest, R1-R10)
    [17]=true, [592]=true, [600]=true, [3747]=true, [6065]=true, [6066]=true,
    [10898]=true, [10899]=true, [10900]=true, [10901]=true,
    -- Ice Barrier (Mage, R1-R5)
    [11426]=true, [13031]=true, [13032]=true, [13033]=true, [27134]=true,
    -- Mana Shield (Mage, R1-R6)
    [1463]=true, [8494]=true, [8495]=true, [10191]=true, [10192]=true, [10193]=true,
    -- Sacrifice (Warlock Voidwalker, R1-R6)
    [7812]=true, [19438]=true, [19440]=true, [19441]=true, [19442]=true, [19443]=true,
    -- Fire Ward (Mage, R1-R5)
    [543]=true, [8457]=true, [8458]=true, [10223]=true, [10225]=true,
    -- Frost Ward (Mage, R1-R4)
    [6143]=true, [8461]=true, [8462]=true, [10177]=true,
    -- Shadow Ward (Warlock, R1-R3)
    [6229]=true, [11739]=true, [11740]=true,
}
if isTBC then
    SHIELD_SPELLS[25217] = true   -- PW:S R11
    SHIELD_SPELLS[25218] = true   -- PW:S R12
    SHIELD_SPELLS[33405] = true   -- Ice Barrier R6
    SHIELD_SPELLS[27131] = true   -- Mana Shield R7
    SHIELD_SPELLS[27273] = true   -- Sacrifice R7
    SHIELD_SPELLS[27128] = true   -- Fire Ward R6
    SHIELD_SPELLS[28609] = true   -- Frost Ward R5
    SHIELD_SPELLS[32796] = true   -- Frost Ward R6
    SHIELD_SPELLS[28610] = true   -- Shadow Ward R4
end

---------------------------------------------------------------------------
-- Shield spell name abbreviations (for shield text feature)
---------------------------------------------------------------------------
local SHIELD_NAMES = {
    [17]="PW:S", [592]="PW:S", [600]="PW:S", [3747]="PW:S", [6065]="PW:S", [6066]="PW:S",
    [10898]="PW:S", [10899]="PW:S", [10900]="PW:S", [10901]="PW:S",
    [11426]="IceBr", [13031]="IceBr", [13032]="IceBr", [13033]="IceBr", [27134]="IceBr",
    [1463]="ManS", [8494]="ManS", [8495]="ManS", [10191]="ManS", [10192]="ManS", [10193]="ManS",
    [7812]="Sacr", [19438]="Sacr", [19440]="Sacr", [19441]="Sacr", [19442]="Sacr", [19443]="Sacr",
    [543]="FirW", [8457]="FirW", [8458]="FirW", [10223]="FirW", [10225]="FirW",
    [6143]="FroW", [8461]="FroW", [8462]="FroW", [10177]="FroW",
    [6229]="ShdW", [11739]="ShdW", [11740]="ShdW",
}
if isTBC then
    SHIELD_NAMES[25217] = "PW:S"   SHIELD_NAMES[25218] = "PW:S"
    SHIELD_NAMES[33405] = "IceBr"  SHIELD_NAMES[27131] = "ManS"
    SHIELD_NAMES[27273] = "Sacr"   SHIELD_NAMES[27128] = "FirW"
    SHIELD_NAMES[28609] = "FroW"   SHIELD_NAMES[32796] = "FroW"
    SHIELD_NAMES[28610] = "ShdW"
end

---------------------------------------------------------------------------
-- Shield spell data: base absorb amounts + spellpower coefficients
-- Used for calculated absorb tracking (nanShield-style).
-- school = "heal" → GetSpellBonusHealing()
-- school = N      → GetSpellBonusDamage(N)  (3=Fire, 4=Nature, 5=Frost)
-- No school/coeff → fixed base amount (no SP scaling)
---------------------------------------------------------------------------
local SHIELD_DATA = {
    -- Power Word: Shield: 20% of bonus healing (R1-R10)
    [17]    = { base = 48,   coeff = 0.2, school = "heal" },
    [592]   = { base = 94,   coeff = 0.2, school = "heal" },
    [600]   = { base = 166,  coeff = 0.2, school = "heal" },
    [3747]  = { base = 244,  coeff = 0.2, school = "heal" },
    [6065]  = { base = 313,  coeff = 0.2, school = "heal" },
    [6066]  = { base = 394,  coeff = 0.2, school = "heal" },
    [10898] = { base = 499,  coeff = 0.2, school = "heal" },
    [10899] = { base = 622,  coeff = 0.2, school = "heal" },
    [10900] = { base = 783,  coeff = 0.2, school = "heal" },
    [10901] = { base = 964,  coeff = 0.2, school = "heal" },
    -- Ice Barrier: 10% of frost spell damage (R1-R5)
    [11426] = { base = 455,  coeff = 0.1, school = 5 },
    [13031] = { base = 569,  coeff = 0.1, school = 5 },
    [13032] = { base = 700,  coeff = 0.1, school = 5 },
    [13033] = { base = 842,  coeff = 0.1, school = 5 },
    [27134] = { base = 952,  coeff = 0.1, school = 5 },
    -- Mana Shield: no SP scaling (R1-R6)
    [1463]  = { base = 120 },
    [8494]  = { base = 210 },
    [8495]  = { base = 300 },
    [10191] = { base = 390 },
    [10192] = { base = 480 },
    [10193] = { base = 570 },
    -- Sacrifice (Voidwalker): no SP scaling (R1-R6)
    [7812]  = { base = 319 },
    [19438] = { base = 529 },
    [19440] = { base = 794 },
    [19441] = { base = 1124 },
    [19442] = { base = 1503 },
    [19443] = { base = 1944 },
    -- Fire Ward: 10% of fire spell damage (R1-R5)
    [543]   = { base = 165,  coeff = 0.1, school = 3 },
    [8457]  = { base = 290,  coeff = 0.1, school = 3 },
    [8458]  = { base = 470,  coeff = 0.1, school = 3 },
    [10223] = { base = 675,  coeff = 0.1, school = 3 },
    [10225] = { base = 875,  coeff = 0.1, school = 3 },
    -- Frost Ward: 10% of frost spell damage (R1-R4)
    [6143]  = { base = 165,  coeff = 0.1, school = 5 },
    [8461]  = { base = 290,  coeff = 0.1, school = 5 },
    [8462]  = { base = 470,  coeff = 0.1, school = 5 },
    [10177] = { base = 675,  coeff = 0.1, school = 5 },
    -- Shadow Ward: no SP scaling (R1-R3)
    [6229]  = { base = 290 },
    [11739] = { base = 470 },
    [11740] = { base = 675 },
}
if isTBC then
    SHIELD_DATA[25217] = { base = 1144, coeff = 0.2, school = "heal" }  -- PW:S R11
    SHIELD_DATA[25218] = { base = 1265, coeff = 0.2, school = "heal" }  -- PW:S R12
    SHIELD_DATA[33405] = { base = 1075, coeff = 0.1, school = 5 }       -- Ice Barrier R6
    SHIELD_DATA[27131] = { base = 715 }                                  -- Mana Shield R7
    SHIELD_DATA[27273] = { base = 2900 }                                 -- Sacrifice R7
    SHIELD_DATA[27128] = { base = 1125, coeff = 0.1, school = 3 }       -- Fire Ward R6
    SHIELD_DATA[28609] = { base = 920,  coeff = 0.1, school = 5 }       -- Frost Ward R5
    SHIELD_DATA[32796] = { base = 1220, coeff = 0.1, school = 5 }       -- Frost Ward R6
    SHIELD_DATA[28610] = { base = 875 }                                  -- Shadow Ward R4
end

---------------------------------------------------------------------------
-- Defensive cooldown spell IDs (TBC)
---------------------------------------------------------------------------
local DEFENSIVE_SPELLS = {
    -- Invulnerabilities
    [642]   = { abbrev = "DVSHD",  priority = 1, category = "invuln" },  -- Divine Shield R1
    [1020]  = { abbrev = "DVSHD",  priority = 1, category = "invuln" },  -- Divine Shield R2
    [11958] = { abbrev = "ICEBL",  priority = 1, category = "invuln" },  -- Ice Block (talent)
    [19752] = { abbrev = "DVINT",  priority = 1, category = "invuln" },  -- Divine Intervention (cast)
    [19753] = { abbrev = "DVINT",  priority = 1, category = "invuln" },  -- Divine Intervention (buff)
    -- Strong mitigation
    [498]   = { abbrev = "DVPRO",  priority = 2, category = "strong" },  -- Divine Protection R1
    [5573]  = { abbrev = "DVPRO",  priority = 2, category = "strong" },  -- Divine Protection R2
    [1022]  = { abbrev = "BPROT",  priority = 3, category = "strong" },  -- Blessing of Protection R1
    [5599]  = { abbrev = "BPROT",  priority = 3, category = "strong" },  -- Blessing of Protection R2
    [10278] = { abbrev = "BPROT",  priority = 3, category = "strong" },  -- Blessing of Protection R3
    [871]   = { abbrev = "SWALL",  priority = 3, category = "strong" },  -- Shield Wall
    -- Weak mitigation
    [5277]  = { abbrev = "EVASN",  priority = 5, category = "weak" },    -- Evasion R1
    [22812] = { abbrev = "BSKIN",  priority = 6, category = "weak" },    -- Barkskin
}
if isTBC then
    DEFENSIVE_SPELLS[45438] = { abbrev = "ICEBL", priority = 1, category = "invuln" }  -- Ice Block (trainable)
    DEFENSIVE_SPELLS[26669] = { abbrev = "EVASN", priority = 5, category = "weak" }    -- Evasion R2
end

local DEF_CAT_SETTING = { invuln = "showInvulns", strong = "showStrongMit", weak = "showWeakMit" }

---------------------------------------------------------------------------
-- External cooldown spell IDs (TBC) — tracked on targets
---------------------------------------------------------------------------
local EXTERNAL_CDS = {
    -- Priest
    [10060] = "PINF",   -- Power Infusion
    -- Paladin
    [1022]  = "BPROT",  -- Blessing of Protection R1
    [5599]  = "BPROT",  -- Blessing of Protection R2
    [10278] = "BPROT",  -- Blessing of Protection R3
    [6940]  = "BSAC",   -- Blessing of Sacrifice R1
    [20729] = "BSAC",   -- Blessing of Sacrifice R2
    -- Druid
    [29166] = "INNERV", -- Innervate
    -- Shaman
    [16190] = "MTIDE",  -- Mana Tide Totem (aura on party)
}
if isTBC then
    EXTERNAL_CDS[33206] = "PSUP"   -- Pain Suppression
    EXTERNAL_CDS[27147] = "BSAC"   -- Blessing of Sacrifice R3
    EXTERNAL_CDS[27148] = "BSAC"   -- Blessing of Sacrifice R4
    EXTERNAL_CDS[32182] = "HERO"   -- Heroism
    EXTERNAL_CDS[2825]  = "BLUST"  -- Bloodlust
end

---------------------------------------------------------------------------
-- HoT dot tracking: maps spell IDs to dot index (1-5) per HoT type
-- Each HoT type now has its own unique dot position
---------------------------------------------------------------------------
local HOT_DOT_SPELLS = {
    -- 1 = Renew (Priest, R1-R10)
    [139]   = 1, [6074]  = 1, [6075]  = 1, [6076]  = 1, [6077]  = 1,
    [6078]  = 1, [10927] = 1, [10928] = 1, [10929] = 1, [25315] = 1,
    -- 2 = Rejuvenation (Druid, R1-R11)
    [774]   = 2, [1058]  = 2, [1430]  = 2, [2090]  = 2, [2091]  = 2,
    [3627]  = 2, [8910]  = 2, [9839]  = 2, [9840]  = 2, [9841]  = 2,
    [25299] = 2,
    -- 3 = Regrowth HoT (Druid, R1-R9)
    [8936]  = 3, [8938]  = 3, [8939]  = 3, [8940]  = 3, [8941]  = 3,
    [9750]  = 3, [9856]  = 3, [9857]  = 3, [9858]  = 3,
}
if isTBC then
    HOT_DOT_SPELLS[25221] = 1   -- Renew R11
    HOT_DOT_SPELLS[25222] = 1   -- Renew R12
    HOT_DOT_SPELLS[26981] = 2   -- Rejuvenation R12
    HOT_DOT_SPELLS[26982] = 2   -- Rejuvenation R13
    HOT_DOT_SPELLS[26980] = 3   -- Regrowth R10
    HOT_DOT_SPELLS[25292] = 3   -- Regrowth R11
    HOT_DOT_SPELLS[33763] = 4   -- Lifebloom
    HOT_DOT_SPELLS[974]   = 5   -- Earth Shield
end

-- HoT spell icons for icon display mode (index -> icon texture path)
local HOT_DOT_ICONS = {
    "Interface\\Icons\\Spell_Holy_Renew",           -- 1 = Renew
    "Interface\\Icons\\Spell_Nature_Rejuvenation",  -- 2 = Rejuvenation
    "Interface\\Icons\\Spell_Nature_ResistNature",  -- 3 = Regrowth
}
if isTBC then
    HOT_DOT_ICONS[4] = "Interface\\Icons\\INV_Misc_Herb_Felblossom"   -- 4 = Lifebloom
    HOT_DOT_ICONS[5] = "Interface\\Icons\\Spell_Nature_SkinofEarth"   -- 5 = Earth Shield
end

---------------------------------------------------------------------------
-- Dispellable debuff types by class (TBC)
---------------------------------------------------------------------------
local DISPEL_BY_CLASS = {
    PRIEST  = { Magic = true, Disease = true },
    PALADIN = { Magic = true, Disease = true, Poison = true },
    DRUID   = { Curse = true, Poison = true },
    SHAMAN  = { Disease = true, Poison = true },
}

local _, _playerClass = UnitClass("player")
local canDispel = DISPEL_BY_CLASS[_playerClass] or {}

---------------------------------------------------------------------------
-- Resurrection spell IDs (TBC)
---------------------------------------------------------------------------
local RES_SPELLS = {
    -- Priest: Resurrection (R1-R5)
    [2006]=true,[2010]=true,[10880]=true,[10881]=true,[20770]=true,
    -- Paladin: Redemption (R1-R5)
    [7328]=true,[10322]=true,[10324]=true,[20772]=true,[20773]=true,
    -- Shaman: Ancestral Spirit (R1-R5)
    [2008]=true,[20609]=true,[20610]=true,[20611]=true,[20612]=true,
    -- Druid: Rebirth (R1-R5)
    [20484]=true,[20739]=true,[20742]=true,[20747]=true,[20748]=true,
}
if isTBC then
    RES_SPELLS[25435] = true  -- Resurrection R6
    RES_SPELLS[25436] = true  -- Redemption R6
    RES_SPELLS[25590] = true  -- Ancestral Spirit R6
    RES_SPELLS[26994] = true  -- Rebirth R6
end

---------------------------------------------------------------------------
-- Frame references
---------------------------------------------------------------------------
local PlayerFrame = PlayerFrame
local PetFrame = PetFrame
local TargetFrame = TargetFrame
local TargetFrameToT = TargetFrameToT
local FocusFrame = FocusFrame

local PartyFrames = {}
local PartyPetFrames = {}
for i = 1, MAX_PARTY_MEMBERS do
    PartyFrames[i] = _G["PartyMemberFrame" .. i]
    PartyPetFrames[i] = _G["PartyMemberFrame" .. i .. "PetFrame"]
end

---------------------------------------------------------------------------
-- SetGradient compatibility
-- TBC Anniversary: SetGradient(orient, r1,g1,b1, r2,g2,b2)
-- Modern Classic:  SetGradient(orient, ColorMixin, ColorMixin)
---------------------------------------------------------------------------
local ApplyGradient
do
    local probe = UIParent:CreateTexture()
    local usesColorObj = pcall(probe.SetGradient, probe, "HORIZONTAL",
                               CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 1))
    probe:Hide()
    if usesColorObj then
        ApplyGradient = function(tex, orient, c1, c2)
            tex:SetGradient(orient, c1, c2)
        end
    else
        ApplyGradient = function(tex, orient, c1, c2)
            tex:SetGradient(orient, c1:GetRGB(), c2:GetRGB())
            tex:SetAlpha(c1.a or c2.a or 1)
        end
    end
end

---------------------------------------------------------------------------
-- Color utilities
---------------------------------------------------------------------------
local cachedColors = {}
local function CachedColor(r, g, b, a)
    a = a or 1
    cachedColors[r] = cachedColors[r] or {}
    cachedColors[r][g] = cachedColors[r][g] or {}
    cachedColors[r][g][b] = cachedColors[r][g][b] or {}
    if not cachedColors[r][g][b][a] then
        cachedColors[r][g][b][a] = CreateColor(r, g, b, a)
    end
    return cachedColors[r][g][b][a]
end

local function RGBtoHSL(r, g, b, a)
    local hi, lo = mathmax(r, g, b), mathmin(r, g, b)
    local h, s, l = 0, 0, (hi + lo) * 0.5
    if hi ~= lo then
        local d = hi - lo
        s = l > 0.5 and d / (2 - hi - lo) or d / (hi + lo)
        if hi == r then
            h = (g - b) / d + (g < b and 6 or 0)
        elseif hi == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h / 6
    end
    return h, s, l, a or 1
end

local function HSLtoRGB(h, s, l, a)
    if s == 0 then return l, l, l, a or 1 end
    local function ch(p, q, t)
        if t < 0 then t = t + 1 elseif t > 1 then t = t - 1 end
        if t < 1/6 then return p + (q - p) * 6 * t end
        if t < 0.5 then return q end
        if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
        return p
    end
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    return ch(p, q, h + 1/3), ch(p, q, h), ch(p, q, h - 1/3), a or 1
end

local function DimColor(factor, r, g, b, a)
    local h, s, l = RGBtoHSL(r, g, b, a)
    return HSLtoRGB(h, s, factor * l, a)
end

local function MakeGradientPair(r, g, b, a)
    return r, g, b, a, DimColor(0.667, r, g, b, a)
end

local function ShiftHue(r, g, b, a)
    local h, s, l = RGBtoHSL(r, g, b, a)
    if h < 0.333 then
        h = h * 1.5
    else
        h = (h - 0.333) * 0.5 + 0.5
    end
    h = (h + 0.5) % 1
    if h < 0.5 then
        h = h * 0.667
    else
        h = (h - 0.5) * 1.333 + 0.333
    end
    return HSLtoRGB(h % 1, s, l, a)
end

---------------------------------------------------------------------------
-- General utilities
---------------------------------------------------------------------------
local function CopyTable(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in next, src, nil do
        out[CopyTable(k)] = CopyTable(v)
    end
    return out
end

local function MergeDefaults(dest, defs)
    for k, v in pairs(defs) do
        if dest[k] == nil then
            dest[k] = type(v) == "table" and CopyTable(v) or v
        elseif type(v) == "table" and type(dest[k]) == "table" then
            MergeDefaults(dest[k], v)
        end
    end
end

local function HookIfExists(name, fn)
    if _G[name] then hooksecurefunc(name, fn) end
end

---------------------------------------------------------------------------
-- HP global table — shared across all modules
---------------------------------------------------------------------------
local HP = {}
_G.HealPredict = HP

-- Export constants needed by other files
HP.ADDON_NAME      = ADDON_NAME
HP.VERSION         = VERSION
HP.Engine           = Engine
HP.HEAL_MASK_OVERTIME = HEAL_MASK_OVERTIME
HP.HOT_DOT_ICONS     = HOT_DOT_ICONS

-- Export upvalued globals for other modules
HP.bit_band   = bit_band
HP.bit_bor    = bit_bor
HP.bit_bnot   = bit_bnot
HP.fmt        = fmt
HP.mathmin    = mathmin
HP.mathmax    = mathmax
HP.mathfloor  = mathfloor
HP.unpack     = unpack
HP.tinsert    = tinsert
HP.wipe       = wipe

-- Export utility functions
HP.ApplyGradient    = ApplyGradient
HP.CachedColor      = CachedColor
HP.MakeGradientPair = MakeGradientPair
HP.ShiftHue         = ShiftHue
HP.DimColor         = DimColor
HP.CopyTable        = CopyTable
HP.MergeDefaults    = MergeDefaults
HP.HookIfExists     = HookIfExists

-- Export spell data
HP.SHIELD_SPELLS    = SHIELD_SPELLS
HP.SHIELD_NAMES     = SHIELD_NAMES
HP.DEFENSIVE_SPELLS = DEFENSIVE_SPELLS
HP.DEF_CAT_SETTING  = DEF_CAT_SETTING
HP.EXTERNAL_CDS     = EXTERNAL_CDS
HP.DISPEL_BY_CLASS  = DISPEL_BY_CLASS
HP.RES_SPELLS       = RES_SPELLS
HP.HOT_DOT_SPELLS   = HOT_DOT_SPELLS
HP.canDispel        = canDispel

-- Export frame references
HP.PlayerFrame    = PlayerFrame
HP.PetFrame       = PetFrame
HP.TargetFrame    = TargetFrame
HP.TargetFrameToT = TargetFrameToT
HP.FocusFrame     = FocusFrame
HP.PartyFrames    = PartyFrames
HP.PartyPetFrames = PartyPetFrames

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local DEFAULTS = {
    showOthers        = true,
    filterDirect      = true,
    filterHoT         = true,
    filterChannel     = true,
    filterBomb        = true,
    useTimeLimit      = false,
    directTimeframe   = 8.0,
    channelTimeframe  = 3.0,
    hotTimeframe      = 3.0,
    useOverhealColors = false,
    overhealThreshold = 0.20,
    overlayMode       = false,
    useRaidOverflow   = true,
    raidOverflow      = 0.05,
    usePartyOverflow  = true,
    partyOverflow     = 0.25,
    useUnitOverflow   = true,
    unitOverflow      = 0.00,
    panelScale        = 1.0,
    showShieldGlow    = true,
    showShieldText    = false,
    showAbsorbBar     = true,
    showDefensives    = true,
    showInvulns       = true,
    showStrongMit     = true,
    showWeakMit       = false,
    showDefensiveIcon = true,
    defensiveIconSize = 16,
    defensiveTextSize = 11,
    defensiveDisplayMode = 3, -- 1=Text only, 2=Icon only, 3=Icon+Text
    defensiveStyle = 3, -- 1=No effect, 2=Static, 3=Glow, 4=Spinning, 5=Slashes
    defensivePos = 1, -- 1=Center, 2=Top-Left, 3=Top-Right, 4=Bottom-Left, 5=Bottom-Right
    defensiveOffsetX   = 0,
    defensiveOffsetY   = 0,
    showHealthDeficit = false,
    deficitOffsetX    = 0,
    deficitOffsetY    = 0,
    showOverhealBar   = false,
    showManaCost      = true,
    showNameplates    = true,
    showHealText      = true,
    dimNonImminent    = true,
    smartOrdering     = false,
    smartOrderingClassColors = false, -- Color heal bars by caster class
    useUnitColorsOnly = false, -- Substitute raid colors with unit colors
    fastRaidUpdate    = false,
    fastUpdateRate    = 30,
    useRaidTexture    = false,
    barOpacity        = 1.0,
    healerCount       = true,
    healerCountPos    = 2,
    healerCountOffsetX = 0,
    healerCountOffsetY = 0,
    healTextPos       = 2,
    healTextOffsetX   = 0,
    healTextOffsetY   = 0,
    overhealGradient  = false,
    healthTrajectory  = false,
    trajectoryWindow  = 3,
    aoeAdvisor        = false,
    aoeHintThreshold  = 3,
    manaForecast      = false,
    manaForecastPos   = 1,
    snipeDetection    = false,
    snipeThreshold    = 0.5,
    showOnPlayer      = true,
    showOnTarget      = true,
    showOnToT         = true,
    showOnFocus       = true,
    showOnParty       = true,
    showOnPet         = true,
    shieldTextOffsetX = 0,
    shieldTextOffsetY = 0,
    showMinimapButton = true,
    minimapAngle      = 220,
    rangeIndicator     = false,
    rangeAlpha         = 0.35,
    hotExpiryWarning   = false,
    hotExpiryThreshold = 3,
    dispelHighlight    = false,
    resTracker         = true,
    resOffsetX         = 0,
    resOffsetY         = 0,
    clusterDetection   = false,
    clusterThreshold   = 0.70,
    clusterMinCount    = 3,
    healingEfficiency  = false,
    oocRegenTimer      = false,
    oocRegenTimerPos   = 1,
    healReductionGlow  = true,
    healReductionText  = true,
    healReductionTextPos = 4, -- 1=TL, 2=TR, 3=C, 4=BL, 5=BR
    healReductionThreshold = 0, -- minimum % reduction to show indicator
    healReducOffsetX   = 0,
    healReducOffsetY   = 0,
    cdTracker          = true,
    cdOffsetX          = 0,
    cdOffsetY          = 0,
    hotTrackerDots     = false,
    hotTrackerDotsOthers = false,
    hotDotsPos         = 1,
    hotDotSize         = 4,
    hotDotSpacing      = 6,
    hotDotRowMode      = 1,   -- 1 = Two rows (own/other), 2 = Single row
    hotDotDisplayMode  = 1,   -- 1 = Colored dots, 2 = Spell icons
    hotDotShowCooldown = true, -- Show cooldown sweep on icons
    hotDotsOffsetX     = 0,
    hotDotsOffsetY     = 0,
    lowManaWarning     = false,
    lowManaThreshold   = 20,
    lowManaOffsetX     = -2,
    lowManaOffsetY     = 1,
    borderThickness    = 2,
    barHeight          = 4,
    
    -- Overheal Stats
    overhealStats      = false,
    overhealStatsPos   = 1, -- 1=Top-Left, 2=Top-Right, 3=Bottom-Left, 4=Bottom-Right
    overhealStatsLocked = true,
    overhealStatsScale = 1.0,
    overhealStatsVisibility = 1, -- 1=Always, 2=Raid, 3=Dungeon, 4=Raid&Dungeon
    overhealStatsResetMode = 1, -- 1=After delay, 2=Boss kill, 3=Instance end
    overhealStatsResetDelay = 8, -- seconds after last heal
    overhealStatsHideOOC = false, -- Hide out of combat

    -- Heal Queue Timeline
    healQueue              = false,
    healQueueLocked        = true,
    healQueueScale         = 1.0,
    healQueueWidth         = 260,
    healQueueShowTarget    = 1,   -- 1=Current target, 2=Mouseover, 3=Both
    healQueueLookahead     = 4,   -- seconds into the future
    healQueueShowDeficit   = true, -- show deficit marker
    healQueueShowNames     = true, -- show caster names
    healQueueHideOOC       = true, -- hide out of combat

    -- Smart Encounter Learning
    smartLearning          = false,
    instanceTracking       = true, -- Track healing across entire instance runs
    encounterSuggestionMode = 1, -- 1=Chat, 2=UI Panel, 3=Both, 4=Disabled
    panelHideDelay         = 5,   -- seconds before auto-hiding encounter panel
    dataRetentionDays      = 30,  -- days before pruning old data
    maxRunHistory          = 10,  -- max runs kept per instance
    instanceTrackingScope  = 3,   -- 1=Dungeons only, 2=Raids only, 3=Both
    cdAdvisorWidget        = true, -- Show cooldown advisor overlay widget
    cdAdvisorScope         = 1,   -- 1=Boss encounters only, 2=Full instance (trash + bosses)

    -- Test Mode Layout
    testModeLayout = 1, -- 1=Solo (8 frames), 2=Dungeon (5 party frames), 3=Raid (25 frames)
    
    -- Death Prediction
    deathPrediction    = false,
    deathPredThreshold = 3, -- Seconds until death to trigger warning
    deathPredOffsetX   = 0,
    deathPredOffsetY   = 0,
    indicatorSize      = 12,
    showCharmed        = true,
    charmedStyle       = 3,  -- 1=Static, 2=Glow, 3=Spinning, 4=Slashes
    soundDispel        = true,
    soundLowMana       = false,
    dispelSoundChoice  = 1,
    lowManaSoundChoice = 1,
    hotExpiryStyle     = 1,   -- 1=Static, 2=Glow, 3=Spinning
    dispelStyle        = 1,
    healReducStyle     = 1,
    clusterStyle       = 1,
    colors = {
        raidMyDirect     = { MakeGradientPair(0.043, 0.533, 0.412, 1.0) },
        raidMyHoT        = { MakeGradientPair(0.043, 0.533, 0.412, 0.5) },
        raidMyDirectOH   = { MakeGradientPair(ShiftHue(0.043, 0.533, 0.412, 1.0)) },
        raidMyHoTOH      = { MakeGradientPair(ShiftHue(0.043, 0.533, 0.412, 0.5)) },
        raidOtherDirect  = { MakeGradientPair(0.082, 0.349, 0.282, 1.0) },
        raidOtherHoT     = { MakeGradientPair(0.082, 0.349, 0.282, 0.5) },
        raidOtherDirectOH = { MakeGradientPair(ShiftHue(0.082, 0.349, 0.282, 1.0)) },
        raidOtherHoTOH   = { MakeGradientPair(ShiftHue(0.082, 0.349, 0.282, 0.5)) },
        unitMyDirect     = { MakeGradientPair(0.0, 0.827, 0.765, 1.0) },
        unitMyHoT        = { MakeGradientPair(0.0, 0.827, 0.765, 0.5) },
        unitMyDirectOH   = { MakeGradientPair(ShiftHue(0.0, 0.827, 0.765, 1.0)) },
        unitMyHoTOH      = { MakeGradientPair(ShiftHue(0.0, 0.827, 0.765, 0.5)) },
        unitOtherDirect  = { MakeGradientPair(0.0, 0.631, 0.557, 1.0) },
        unitOtherHoT     = { MakeGradientPair(0.0, 0.631, 0.557, 0.5) },
        unitOtherDirectOH = { MakeGradientPair(ShiftHue(0.0, 0.631, 0.557, 1.0)) },
        unitOtherHoTOH   = { MakeGradientPair(ShiftHue(0.0, 0.631, 0.557, 0.5)) },
        absorbBar        = { 0.85, 0.85, 0.2, 0.7 },
        overhealBar      = { MakeGradientPair(0.8, 0.2, 0.2, 0.6) },
        manaCostBar      = { 0.2, 0.2, 0.8, 0.5 },
        hotExpiry        = { 1.0, 0.6, 0.0, 0.7 },
        dispelMagic      = { 0.2, 0.6, 1.0, 0.6 },
        dispelCurse      = { 0.6, 0.0, 1.0, 0.6 },
        dispelDisease    = { 0.6, 0.4, 0.0, 0.6 },
        dispelPoison     = { 0.0, 0.6, 0.2, 0.6 },
        aoeBorder        = { 0.2, 0.8, 1.0, 0.8 },
        clusterBorder    = { 0.9, 0.9, 0.2, 0.6 },
        healReduction    = { 0.6, 0.0, 0.0, 0.7 },
        -- Your HoT dots (individual colors for each HoT type)
        hotDotRenew      = { 1.0, 1.0, 1.0, 1.0 },  -- White (Priest Renew)
        hotDotRejuv      = { 0.2, 0.8, 0.2, 1.0 },  -- Green (Druid Rejuvenation)
        hotDotRegrowth   = { 1.0, 0.6, 0.0, 1.0 },  -- Orange (Druid Regrowth)
        hotDotLifebloom  = { 0.0, 1.0, 0.4, 1.0 },  -- Bright Green (Druid Lifebloom)
        hotDotEarthShield = { 0.4, 0.6, 1.0, 1.0 }, -- Blue (Shaman Earth Shield)
        -- Other healers' HoT dots (individual colors)
        hotDotRenewOther      = { 0.8, 0.8, 0.8, 1.0 },  -- Light Gray
        hotDotRejuvOther      = { 0.15, 0.6, 0.15, 1.0 }, -- Dark Green
        hotDotRegrowthOther   = { 0.8, 0.48, 0.0, 1.0 },  -- Dark Orange
        hotDotLifebloomOther  = { 0.0, 0.8, 0.32, 1.0 },  -- Dark Bright Green
        hotDotEarthShieldOther = { 0.32, 0.48, 0.8, 1.0 },
        defensiveBorder  = { 1.0, 0.8, 0.0, 1.0 }, -- Gold (invuln color by default)
        charmed          = { 0.9, 0.2, 0.9, 0.8 }, -- Magenta/purple for charmed/mind-controlled
        shieldGlow       = { 1.0, 0.9, 0.3, 0.6 }, -- Yellow/gold glow for shields
    },
}

local Settings = CopyTable(DEFAULTS)

HP.DEFAULTS = DEFAULTS
HP.Settings = Settings

---------------------------------------------------------------------------
-- Frame tracking: single table per frame instead of 13 weak tables
---------------------------------------------------------------------------
local weak = { __mode = "k" }
HP.frameData     = setmetatable({}, weak)
HP.frameGUID     = setmetatable({}, weak)

HP.guidToUnit    = {}
HP.guidToCompact = {}
HP.guidToPlate   = {}

---------------------------------------------------------------------------
-- Aura tracking
---------------------------------------------------------------------------
HP.shieldGUIDs    = {}
HP.shieldAmounts  = {}
HP.defenseGUIDs   = {}
HP.dispelGUIDs    = {}
HP.resTargets     = {}
HP.cdGUIDs        = {}
HP.hotDotGUIDs    = {}  -- Your own HoTs
HP.hotDotOtherGUIDs = {}  -- Other healers' HoTs
HP.clusterGUIDs   = {}
HP.clusterLastCalc = 0
HP.charmedGUIDs    = {}
HP.spellStats     = {}
HP.efficiencySession = 0

---------------------------------------------------------------------------
-- Burst detection state for Cooldown Usage Advisor
---------------------------------------------------------------------------
local _burstAccum = 0
local _burstWindowStart = 0
local _burstLastEvent = 0
local BURST_WINDOW = 2      -- rolling window in seconds
local BURST_COOLDOWN = 5    -- min seconds between BURST events
local BURST_THRESHOLD = 0.30 -- 30% of raid max HP
local _cachedRaidMaxHP = 0
local _cachedRaidMaxTime = 0

local function GetCachedRaidMaxHP()
    local now = GetTime()
    if now - _cachedRaidMaxTime < 5 then return _cachedRaidMaxHP end
    local total = 0
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
                total = total + UnitHealthMax(unit)
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
                total = total + UnitHealthMax(unit)
            end
        end
        total = total + UnitHealthMax("player")
    else
        total = UnitHealthMax("player")
    end
    _cachedRaidMaxHP = total
    _cachedRaidMaxTime = now
    return total
end

---------------------------------------------------------------------------
-- Calculated shield absorb system (nanShield-style)
-- Instead of parsing broken TBC tooltips, we calculate absorb amounts
-- from known spell data and track remaining via combat log events.
-- Self-cast shields use our actual spellpower for accurate values.
-- Other-cast shields use base absorb (conservative estimate).
---------------------------------------------------------------------------
local activeShields = {}  -- [guid] = { [spellID] = { amount=N, source=srcGUID } }

local GetSpellBonusHealing = GetSpellBonusHealing
local GetSpellBonusDamage  = GetSpellBonusDamage

local function CalcShieldAmount(spellID, sourceGUID)
    local data = SHIELD_DATA[spellID]
    if not data then return nil end
    local amount = data.base
    -- Add spellpower scaling for self-cast shields only
    local myGUID = UnitGUID("player")
    if sourceGUID and sourceGUID == myGUID and data.coeff and data.coeff > 0 then
        local sp = 0
        if data.school == "heal" then
            sp = GetSpellBonusHealing and GetSpellBonusHealing() or 0
        elseif type(data.school) == "number" then
            sp = GetSpellBonusDamage and GetSpellBonusDamage(data.school) or 0
        end
        amount = amount + data.coeff * sp
    end
    return mathfloor(amount)
end

local function RecalcShieldTotal(guid)
    local shields = activeShields[guid]
    if not shields or not next(shields) then
        HP.shieldAmounts[guid] = nil
        return
    end
    local total = 0
    for _, info in pairs(shields) do
        total = total + (info.amount or 0)
    end
    HP.shieldAmounts[guid] = total > 0 and total or nil
end

---------------------------------------------------------------------------
-- Combat log handler: track shield apply/remove and damage absorbed
---------------------------------------------------------------------------
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

function HP.OnCombatLog()
    local _, eventType, _, srcGUID, _, _, _, dstGUID, dstName, _, _,
          p12, p13, p14, p15, p16, p17, p18, p19, p20 = CombatLogGetCurrentEventInfo()

    -- Shield aura applied or refreshed
    if eventType == "SPELL_AURA_APPLIED" or eventType == "SPELL_AURA_REFRESH" then
        local spellID = p12
        if SHIELD_SPELLS[spellID] then
            local amount = CalcShieldAmount(spellID, srcGUID)
            if amount and amount > 0 then
                if not activeShields[dstGUID] then activeShields[dstGUID] = {} end
                activeShields[dstGUID][spellID] = { amount = amount, source = srcGUID }
                RecalcShieldTotal(dstGUID)
            end
        end
        -- Record external CD usage for Cooldown Usage Advisor
        if Settings.smartLearning then
            local cdAbbrev = EXTERNAL_CDS[spellID]
            if cdAbbrev then
                local scope = Settings.cdAdvisorScope or 1
                if HP.currentEncounter then
                    HP.RecordEncounterEvent("CD_USED", cdAbbrev)
                elseif scope == 2 and HP.currentInstance then
                    HP.RecordInstanceEvent("CD_USED", cdAbbrev)
                end
            end
        end
        return
    end

    -- Shield aura removed
    if eventType == "SPELL_AURA_REMOVED" then
        local spellID = p12
        if SHIELD_SPELLS[spellID] and activeShields[dstGUID] then
            activeShields[dstGUID][spellID] = nil
            if not next(activeShields[dstGUID]) then activeShields[dstGUID] = nil end
            RecalcShieldTotal(dstGUID)
        end
        return
    end

    -- Player's heals: snipe detection + efficiency tracking + overheal stats
    if eventType == "SPELL_HEAL" or eventType == "SPELL_PERIODIC_HEAL" then
        local myGUID = UnitGUID("player")
        if srcGUID == myGUID then
            local spellID = p12
            local spellName = p13
            local healAmount = p15 or 0
            local overhealing = p16 or 0
            local totalHeal = healAmount + overhealing

            if eventType == "SPELL_HEAL" then
                if Settings.snipeDetection then
                    if totalHeal > 0 and overhealing / totalHeal > Settings.snipeThreshold then
                        HP.OnSnipe(dstGUID, spellID, totalHeal, overhealing)
                    end
                end

                if Settings.healingEfficiency then
                    local stats = HP.spellStats[spellID]
                    if not stats then
                        stats = { casts = 0, totalHeal = 0, totalOverheal = 0 }
                        HP.spellStats[spellID] = stats
                    end
                    stats.casts = stats.casts + 1
                    stats.totalHeal = stats.totalHeal + totalHeal
                    stats.totalOverheal = stats.totalOverheal + overhealing
                end
            end

            -- Overheal Statistics tracking
            if Settings.overhealStats and totalHeal > 0 then
                HP.RecordOverheal(spellName or "Unknown", totalHeal, overhealing)
            end
            
            -- Encounter Learning tracking
            if Settings.smartLearning and totalHeal > 0 then
                HP.RecordEncounterHeal(spellName or "Unknown", totalHeal, overhealing, dstGUID)
            end
            -- Instance-wide tracking
            if HP.currentInstance and totalHeal > 0 then
                HP.RecordInstanceHeal(spellName or "Unknown", totalHeal, overhealing)
            end
        end
        return
    end

    -- Clean up damage history on death
    if eventType == "UNIT_DIED" then
        if HP.damageHistory then HP.damageHistory[dstGUID] = nil end
        -- Instance tracking: record party/raid member deaths
        if HP.currentInstance and HP.RecordInstanceDeath then
            local name = dstName or "Unknown"
            HP.RecordInstanceDeath(name)
        end
        return
    end

    -- Fully-absorbed hits fire as MISS with missType "ABSORB" in Classic
    if eventType == "SWING_MISSED" then
        local missType, _, absAmt = p12, p13, p14
        if missType == "ABSORB" and absAmt and type(absAmt) == "number" and absAmt > 0 and activeShields[dstGUID] then
            local remaining = absAmt
            for spellID, info in pairs(activeShields[dstGUID]) do
                if remaining <= 0 then break end
                local sub = mathmin(remaining, info.amount)
                info.amount = info.amount - sub
                remaining = remaining - sub
                if info.amount <= 0 then
                    activeShields[dstGUID][spellID] = nil
                end
            end
            if not next(activeShields[dstGUID]) then activeShields[dstGUID] = nil end
            RecalcShieldTotal(dstGUID)
            if HP.NotifyGUIDs then HP.NotifyGUIDs(dstGUID) end
        end
        return
    end

    if eventType == "SPELL_MISSED" or eventType == "RANGE_MISSED" then
        local missType, _, absAmt = p15, p16, p17
        if missType == "ABSORB" and absAmt and type(absAmt) == "number" and absAmt > 0 and activeShields[dstGUID] then
            local remaining = absAmt
            for spellID, info in pairs(activeShields[dstGUID]) do
                if remaining <= 0 then break end
                local sub = mathmin(remaining, info.amount)
                info.amount = info.amount - sub
                remaining = remaining - sub
                if info.amount <= 0 then
                    activeShields[dstGUID][spellID] = nil
                end
            end
            if not next(activeShields[dstGUID]) then activeShields[dstGUID] = nil end
            RecalcShieldTotal(dstGUID)
            if HP.NotifyGUIDs then HP.NotifyGUIDs(dstGUID) end
        end
        return
    end

    -- Damage events: subtract absorbed amount from active shields + track for trajectory
    local absorbed, damageAmount
    if eventType == "SWING_DAMAGE" then
        absorbed = p17
        damageAmount = p12
    elseif eventType == "SPELL_DAMAGE" or eventType == "SPELL_PERIODIC_DAMAGE" or eventType == "RANGE_DAMAGE" then
        absorbed = p20
        damageAmount = p15
    elseif eventType == "ENVIRONMENTAL_DAMAGE" then
        absorbed = p18
        damageAmount = p13
    end

    -- Damage history for health trajectory and death prediction
    if damageAmount and type(damageAmount) == "number" and damageAmount > 0 then
        if Settings.healthTrajectory or Settings.deathPrediction then
            local hist = HP.damageHistory[dstGUID]
            if not hist then hist = {}; HP.damageHistory[dstGUID] = hist end
            local now = GetTime()
            hist[#hist + 1] = { now, damageAmount }
            -- Prune stale entries from front (chronological order)
            local cutoff = 0
            for i = 1, #hist do
                if now - hist[i][1] > 5 then cutoff = i else break end
            end
            if cutoff > 0 then
                local n = #hist
                for i = 1, n - cutoff do
                    hist[i] = hist[i + cutoff]
                end
                for i = n - cutoff + 1, n do
                    hist[i] = nil
                end
            end
        end

        -- Burst detection for Cooldown Usage Advisor
        if Settings.smartLearning then
            local scope = Settings.cdAdvisorScope or 1
            local tracking = HP.currentEncounter or (scope == 2 and HP.currentInstance)
            if tracking then
                local now2 = GetTime()
                -- Reset accumulator if window expired
                if now2 - _burstWindowStart > BURST_WINDOW then
                    _burstAccum = 0
                    _burstWindowStart = now2
                end
                _burstAccum = _burstAccum + damageAmount
                -- Check threshold (with cooldown between events)
                if now2 - _burstLastEvent >= BURST_COOLDOWN then
                    local raidHP = GetCachedRaidMaxHP()
                    if raidHP > 0 and _burstAccum >= raidHP * BURST_THRESHOLD then
                        -- Capture ability name from spell events
                        local abilityName
                        if eventType == "SPELL_DAMAGE" or eventType == "SPELL_PERIODIC_DAMAGE" or eventType == "RANGE_DAMAGE" then
                            abilityName = p13
                        end
                        if HP.currentEncounter then
                            HP.RecordEncounterEvent("BURST", abilityName or "Raid Damage", { damage = _burstAccum })
                        elseif scope == 2 and HP.currentInstance then
                            HP.RecordInstanceEvent("BURST", abilityName or "Raid Damage", { damage = _burstAccum })
                        end
                        _burstLastEvent = now2
                        _burstAccum = 0
                    end
                end
            end
        end
    end

    if absorbed and type(absorbed) == "number" and absorbed > 0 and activeShields[dstGUID] then
        local remaining = absorbed
        for spellID, info in pairs(activeShields[dstGUID]) do
            if remaining <= 0 then break end
            local sub = mathmin(remaining, info.amount)
            info.amount = info.amount - sub
            remaining = remaining - sub
            if info.amount <= 0 then
                activeShields[dstGUID][spellID] = nil
            end
        end
        if not next(activeShields[dstGUID]) then activeShields[dstGUID] = nil end
        RecalcShieldTotal(dstGUID)
        -- Queue re-render so the absorb bar shrinks in real time
        if HP.NotifyGUIDs then HP.NotifyGUIDs(dstGUID) end
    end
end

---------------------------------------------------------------------------
-- Aura scanning: detect shield/defensive presence + bootstrap amounts
-- Absorb amounts come from combat log tracking (activeShields).
-- Bootstrap: if a shield is found via UnitBuff but not yet tracked by
-- the combat log (e.g. shield was active before addon loaded), calculate
-- from spell data using the buff source unit.
---------------------------------------------------------------------------
local _scanningAuras = false

function HP.ScanAuras(unit)
    if not unit then return false end
    if _scanningAuras then return false end
    if not UnitExists(unit) then return false end
    local guid = UnitGUID(unit)
    if not guid then return false end

    local wantShield  = Settings.showShieldGlow or Settings.showAbsorbBar or Settings.showShieldText
    local wantDefense = Settings.showDefensives
    local wantDispel  = Settings.dispelHighlight and next(canDispel)
    local wantCD      = Settings.cdTracker
    local wantHotDots = Settings.hotTrackerDots
    local wantHotDotsOthers = Settings.hotTrackerDotsOthers
    local wantCharmed = Settings.showCharmed
    if not wantShield and not wantDefense and not wantDispel and not wantCD and not wantHotDots and not wantHotDotsOthers and not wantCharmed then return false end

    local hadShield  = HP.shieldGUIDs[guid]
    local hadDefense = HP.defenseGUIDs[guid]
    local hadAmount  = HP.shieldAmounts[guid]
    local hadDispel  = HP.dispelGUIDs[guid]
    local hadCD      = HP.cdGUIDs[guid]
    local hadHotDots = HP.hotDotGUIDs[guid]
    local hadHotDotsOthers = HP.hotDotOtherGUIDs[guid]
    local hadCharmed = HP.charmedGUIDs[guid]

    HP.shieldGUIDs[guid]  = nil
    HP.defenseGUIDs[guid] = nil
    HP.dispelGUIDs[guid]  = nil
    HP.cdGUIDs[guid]      = nil
    HP.hotDotGUIDs[guid]  = nil
    HP.hotDotOtherGUIDs[guid] = nil
    HP.charmedGUIDs[guid] = nil

    _scanningAuras = true

    local ok, _ = pcall(function()
        local bestDef = nil
        local bestDefSpellId = nil
        local bestCD = nil
        local foundShields = nil  -- track which shield spellIDs are actually on the unit
        local playerGUID = UnitGUID("player")  -- cache player GUID once
        local index = 1
        while true do
            local _, _, _, _, duration, expirationTime, source, _, _, spellId = UnitBuff(unit, index)
            if not spellId then break end

            if wantShield and SHIELD_SPELLS[spellId] then
                HP.shieldGUIDs[guid] = spellId
                if not foundShields then foundShields = {} end
                foundShields[spellId] = true
                -- Bootstrap: calculate amount for shields not yet tracked by combat log
                if not activeShields[guid] or not activeShields[guid][spellId] then
                    local srcGUID = source and UnitGUID(source)
                    local amount = CalcShieldAmount(spellId, srcGUID)
                    if amount and amount > 0 then
                        if not activeShields[guid] then activeShields[guid] = {} end
                        activeShields[guid][spellId] = { amount = amount, source = srcGUID }
                    end
                end
            end

            if wantDefense then
                local def = DEFENSIVE_SPELLS[spellId]
                if def then
                    local catKey = DEF_CAT_SETTING[def.category]
                    if catKey and Settings[catKey] then
                        if not bestDef or def.priority < bestDef.priority then
                            bestDef = def
                            bestDefSpellId = spellId
                        end
                    end
                end
            end

            if wantCD and EXTERNAL_CDS[spellId] then
                local srcGUID = source and UnitGUID(source)
                if srcGUID and srcGUID ~= playerGUID then
                    bestCD = EXTERNAL_CDS[spellId]
                end
            end

            if HOT_DOT_SPELLS[spellId] then
                local srcGUID = source and UnitGUID(source)
                local dotSlot = HOT_DOT_SPELLS[spellId]
                local exp = expirationTime or 0
                local dur = duration or 0
                -- Track your own HoTs (reuse existing dotInfo table)
                if wantHotDots and srcGUID and srcGUID == playerGUID then
                    if not HP.hotDotGUIDs[guid] then HP.hotDotGUIDs[guid] = {} end
                    local existing = HP.hotDotGUIDs[guid][dotSlot]
                    if existing then
                        existing.expiration = exp
                        existing.duration = dur
                    else
                        HP.hotDotGUIDs[guid][dotSlot] = { expiration = exp, duration = dur }
                    end
                end
                -- Track other healers' HoTs (reuse existing dotInfo table)
                if wantHotDotsOthers and srcGUID and srcGUID ~= playerGUID then
                    if not HP.hotDotOtherGUIDs[guid] then HP.hotDotOtherGUIDs[guid] = {} end
                    local existing = HP.hotDotOtherGUIDs[guid][dotSlot]
                    if existing then
                        existing.expiration = exp
                        existing.duration = dur
                    else
                        HP.hotDotOtherGUIDs[guid][dotSlot] = { expiration = exp, duration = dur }
                    end
                end
            end

            index = index + 1
        end

        -- Clean up stale activeShields entries for shields no longer present as buffs
        if activeShields[guid] then
            for spellID in pairs(activeShields[guid]) do
                if not foundShields or not foundShields[spellID] then
                    activeShields[guid][spellID] = nil
                end
            end
            if not next(activeShields[guid]) then activeShields[guid] = nil end
        end

        -- Recalc absorb total from combat-log-tracked shield data
        RecalcShieldTotal(guid)

        if bestDef then
            -- Create a copy so we don't mutate the original DEFENSIVE_SPELLS table
            HP.defenseGUIDs[guid] = {
                abbrev = bestDef.abbrev,
                priority = bestDef.priority,
                category = bestDef.category,
                spellId = bestDefSpellId
            }
        end

        if bestCD then
            HP.cdGUIDs[guid] = bestCD
        end

        -- Dispel detection: scan debuffs for types this class can dispel
        if wantDispel then
            local dIdx = 1
            while true do
                local _, _, _, debuffType, _, _, _, _, _, dSpellId = UnitDebuff(unit, dIdx)
                if not dSpellId then break end
                if debuffType and canDispel[debuffType] then
                    HP.dispelGUIDs[guid] = debuffType
                    break
                end
                dIdx = dIdx + 1
            end
        end

        -- Charmed/Mind-controlled detection
        if wantCharmed then
            if UnitIsCharmed(unit) then
                HP.charmedGUIDs[guid] = true
            end
        end
    end)

    _scanningAuras = false

    -- Detect hotDot changes (compare table contents)
    local hotDotsChanged = false
    local newDots = HP.hotDotGUIDs[guid]
    if (newDots ~= nil) ~= (hadHotDots ~= nil) then
        hotDotsChanged = true
    elseif newDots and hadHotDots then
        for k in pairs(newDots) do if not hadHotDots[k] then hotDotsChanged = true; break end end
        if not hotDotsChanged then
            for k in pairs(hadHotDots) do if not newDots[k] then hotDotsChanged = true; break end end
        end
    end

    -- Detect external hotDot changes
    local hotDotsOthersChanged = false
    local newDotsOthers = HP.hotDotOtherGUIDs[guid]
    if (newDotsOthers ~= nil) ~= (hadHotDotsOthers ~= nil) then
        hotDotsOthersChanged = true
    elseif newDotsOthers and hadHotDotsOthers then
        for k in pairs(newDotsOthers) do if not hadHotDotsOthers[k] then hotDotsOthersChanged = true; break end end
        if not hotDotsOthersChanged then
            for k in pairs(hadHotDotsOthers) do if not newDotsOthers[k] then hotDotsOthersChanged = true; break end end
        end
    end

    return (HP.shieldGUIDs[guid] ~= nil) ~= (hadShield ~= nil)
        or (HP.defenseGUIDs[guid] ~= nil) ~= (hadDefense ~= nil)
        or HP.shieldAmounts[guid] ~= hadAmount
        or HP.dispelGUIDs[guid] ~= hadDispel
        or HP.cdGUIDs[guid] ~= hadCD
        or hotDotsChanged
        or hotDotsOthersChanged
        or (HP.charmedGUIDs[guid] ~= nil) ~= (hadCharmed ~= nil)
end

-- Export for Render.lua cleanup on GUID disappearance
HP.activeShields = activeShields

---------------------------------------------------------------------------
-- Overheal severity gradient color stops (Feature 3)
-- green → orange → red
---------------------------------------------------------------------------
HP.OVERHEAL_GRAD = {{0, 0.3, 0.1}, {1, 0.6, 0}, {1, 0.15, 0.1}}

---------------------------------------------------------------------------
-- Damage History for Health Trajectory (Feature 4)
---------------------------------------------------------------------------
HP.damageHistory = {}

function HP.GetDamageRate(guid)
    local hist = HP.damageHistory[guid]
    if not hist or #hist == 0 then return 0 end
    local now = GetTime()
    local window = Settings.trajectoryWindow
    local total = 0
    for i = #hist, 1, -1 do
        if now - hist[i][1] <= window then
            total = total + hist[i][2]
        else
            break
        end
    end
    return total / window
end

---------------------------------------------------------------------------
-- AoE Heal Target Advisor (Feature 5)
---------------------------------------------------------------------------
HP.aoeTargetGUID = nil
HP.aoeLastCalc = 0

local _aoeSubDeficit = {}
local _aoeSubLowest = {}

function HP.GetBestAoETarget()
    local now = GetTime()
    if now - HP.aoeLastCalc < 0.5 then return HP.aoeTargetGUID end
    HP.aoeLastCalc = now
    HP.aoeTargetGUID = nil

    if not IsInRaid() then return nil end

    wipe(_aoeSubDeficit)
    wipe(_aoeSubLowest)
    local subDeficit = _aoeSubDeficit
    local subLowest = _aoeSubLowest
    local count = GetNumGroupMembers()
    for i = 1, count do
        local unit = "raid" .. i
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit) then
            local _, _, subgroup = GetRaidRosterInfo(i)
            if subgroup then
                local hp = UnitHealth(unit)
                local mx = UnitHealthMax(unit)
                local deficit = mx - hp
                if deficit > 0 then
                    subDeficit[subgroup] = (subDeficit[subgroup] or 0) + deficit
                    if not subLowest[subgroup] or deficit > subLowest[subgroup][2] then
                        local entry = subLowest[subgroup]
                        if not entry then entry = {}; subLowest[subgroup] = entry end
                        entry[1] = UnitGUID(unit)
                        entry[2] = deficit
                    end
                end
            end
        end
    end

    local bestGroup, bestDef = nil, 0
    for sg, def in pairs(subDeficit) do
        if def > bestDef then bestGroup = sg; bestDef = def end
    end

    if bestGroup and subLowest[bestGroup] then
        HP.aoeTargetGUID = subLowest[bestGroup][1]
    end
    return HP.aoeTargetGUID
end

---------------------------------------------------------------------------
-- Cluster Detection (v1.0.4)
-- Highlights subgroups where multiple low-health members are grouped.
---------------------------------------------------------------------------
local _clusterOld = {}

function HP.CalcClusterGUIDs()
    local now = GetTime()
    if now - HP.clusterLastCalc < 0.5 then return end
    HP.clusterLastCalc = now

    wipe(_clusterOld)
    for guid in pairs(HP.clusterGUIDs) do _clusterOld[guid] = true end
    wipe(HP.clusterGUIDs)

    if not IsInRaid() then
        if HP.NotifyGUIDs then
            for guid in pairs(_clusterOld) do HP.NotifyGUIDs(guid) end
        end
        return
    end

    local threshold = Settings.clusterThreshold
    local minCount = Settings.clusterMinCount
    -- Reuse sub-bucket tables, just reset counts
    if not HP._clusterBuckets then HP._clusterBuckets = {} end
    local subBuckets = HP._clusterBuckets
    for _, bucket in pairs(subBuckets) do bucket._n = 0 end
    local count = GetNumGroupMembers()
    for i = 1, count do
        local unit = "raid" .. i
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit) then
            local _, _, subgroup = GetRaidRosterInfo(i)
            if subgroup then
                local hp = UnitHealth(unit)
                local mx = UnitHealthMax(unit)
                if mx > 0 and hp / mx < threshold then
                    if not subBuckets[subgroup] then subBuckets[subgroup] = { _n = 0 } end
                    local bucket = subBuckets[subgroup]
                    bucket._n = bucket._n + 1
                    bucket[bucket._n] = UnitGUID(unit)
                end
            end
        end
    end

    for _, bucket in pairs(subBuckets) do
        if bucket._n >= minCount then
            for i = 1, bucket._n do
                HP.clusterGUIDs[bucket[i]] = true
            end
        end
    end

    -- Notify changed GUIDs
    if HP.NotifyGUIDs then
        for guid in pairs(_clusterOld) do
            if not HP.clusterGUIDs[guid] then HP.NotifyGUIDs(guid) end
        end
        for guid in pairs(HP.clusterGUIDs) do
            if not old[guid] then HP.NotifyGUIDs(guid) end
        end
    end
end

---------------------------------------------------------------------------
-- Heal Snipe Detection (Feature 7)
---------------------------------------------------------------------------
HP.snipeLog = {}
HP.snipeStats = { count = 0, totalWasted = 0 }

function HP.OnSnipe(dstGUID, spellID, totalHeal, overhealing)
    local entry = { time = GetTime(), dst = dstGUID, spell = spellID, total = totalHeal, oh = overhealing }
    local log = HP.snipeLog
    log[#log + 1] = entry
    if #log > 10 then table.remove(log, 1) end
    HP.snipeStats.count = HP.snipeStats.count + 1
    HP.snipeStats.totalWasted = HP.snipeStats.totalWasted + overhealing

    -- Flash the target's compact frames
    local compactSet = HP.guidToCompact[dstGUID]
    if compactSet then
        for frame in pairs(compactSet) do
            local fd = HP.frameData[frame]
            if fd and fd.snipeAG then
                fd.snipeFlash:Show()
                fd.snipeFlash:SetAlpha(0.8)
                fd.snipeAG:Stop()
                fd.snipeAG:Play()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Smart Encounter Learning System
-- Learns healing patterns per boss encounter for performance optimization
---------------------------------------------------------------------------
HP.encounterDB = {} -- Per-boss statistics and learning data
HP.currentEncounter = nil -- Active encounter tracking

-- Initialize encounter data structure for a boss
function HP.InitEncounterData(bossName, bossID, difficultyID)
    local key = bossID and (bossID .. "-" .. (difficultyID or 0)) or (bossName or "Unknown")
    if not HP.encounterDB[key] then
        HP.encounterDB[key] = {
            bossName = bossName,
            firstSeen = time(),
            attempts = 0,
            kills = 0,
            wipes = 0,
            personalBests = {
                hps = 0,
                efficiency = 0, -- effective healing / total healing
                overheal = 100, -- lower is better
                oomTime = nil,  -- time when went OOM (nil = never)
            },
            averages = {
                hps = 0,
                overheal = 0,
                casts = 0,
            },
            -- Spell usage patterns
            spellUsage = {}, -- [spellName] = { casts = 0, avgHeal = 0, overheal = 0 }
            -- Timing patterns
            timings = {
                preCastOffset = {}, -- How early before damage you pre-cast
                cooldownUsage = {}, -- When major CDs are used (time into fight)
            },
            -- Death analysis
            deaths = {}, -- [playerName] = { count = 0, causes = {} }
            -- Key moments learned
            keyMoments = {}, -- { time = 45, type = "burst", ability = "Incinerate" }
        }
    end
    return HP.encounterDB[key]
end

-- Start tracking an encounter
function HP.StartEncounterTracking(bossName, bossID, difficultyID)
    if HP.currentEncounter then return end -- prevent double-start

    -- Reset burst detection accumulators
    _burstAccum = 0
    _burstWindowStart = 0
    _burstLastEvent = 0
    _cachedRaidMaxHP = 0
    _cachedRaidMaxTime = 0

    local data = HP.InitEncounterData(bossName, bossID, difficultyID)
    data.attempts = data.attempts + 1

    HP.currentEncounter = {
        bossName = bossName,
        bossID = bossID,
        difficultyID = difficultyID,
        startTime = GetTime(),
        data = data,
        -- Session stats
        totalHealing = 0,
        effectiveHealing = 0,
        overhealing = 0,
        casts = 0,
        spellUsage = {},
        wentOOM = nil,
        manaSnapshots = {}, -- Track mana at different fight stages
        -- Event log for learning
        events = {},
    }
    
    print("|cff33ccffHealPredict:|r Learning mode active for: " .. (bossName or "Unknown"))

    if HP.ShowEncounterPanel then HP.ShowEncounterPanel() end
end

-- Record a heal event during encounter
function HP.RecordEncounterHeal(spellName, amount, overheal, targetGUID)
    if not HP.currentEncounter then return end
    
    local enc = HP.currentEncounter
    local effective = amount - overheal
    
    enc.totalHealing = enc.totalHealing + amount
    enc.effectiveHealing = enc.effectiveHealing + effective
    enc.overhealing = enc.overhealing + overheal
    enc.casts = enc.casts + 1
    
    -- Track per-spell usage
    if not enc.spellUsage[spellName] then
        enc.spellUsage[spellName] = { casts = 0, total = 0, effective = 0, overheal = 0 }
    end
    local spell = enc.spellUsage[spellName]
    spell.casts = spell.casts + 1
    spell.total = spell.total + amount
    spell.effective = spell.effective + effective
    spell.overheal = spell.overheal + overheal
    
end

-- Record mana snapshot (works for both encounter and instance tracking)
function HP.RecordManaSnapshot()
    local target = HP.currentEncounter or HP.currentInstance
    if not target then return end

    local now = GetTime()
    local elapsed = now - target.startTime
    local maxMana = UnitPowerMax("player", 0)
    if maxMana <= 0 then return end
    local mana = UnitPower("player", 0) -- 0 = mana
    local pct = (mana / maxMana) * 100

    target.manaSnapshots[#target.manaSnapshots + 1] = {
        time = elapsed,
        mana = mana,
        maxMana = maxMana,
        pct = pct,
    }

    -- Prune snapshots older than 90s to bound memory (60s window + 30s buffer)
    while #target.manaSnapshots > 2 and (elapsed - target.manaSnapshots[1].time) > 90 do
        table.remove(target.manaSnapshots, 1)
    end

    -- Detect OOM (encounter tracking only)
    if HP.currentEncounter and mana == 0 and not HP.currentEncounter.wentOOM then
        HP.currentEncounter.wentOOM = elapsed
        HP.currentEncounter.events[#HP.currentEncounter.events + 1] = {
            time = elapsed,
            type = "OOM",
            note = "Went out of mana",
        }
    end
end

-- Record significant event (damage spike, ability used, etc)
function HP.RecordEncounterEvent(eventType, note, data)
    if not HP.currentEncounter then return end

    local now = GetTime()
    local elapsed = now - HP.currentEncounter.startTime

    HP.currentEncounter.events[#HP.currentEncounter.events + 1] = {
        time = elapsed,
        type = eventType,
        note = note,
        data = data,
    }
end

-- Record significant event for instance-wide tracking (scope=2)
function HP.RecordInstanceEvent(eventType, note, data)
    if not HP.currentInstance then return end

    local now = GetTime()
    local elapsed = now - HP.currentInstance.startTime

    if not HP.currentInstance.events then HP.currentInstance.events = {} end
    HP.currentInstance.events[#HP.currentInstance.events + 1] = {
        time = elapsed,
        type = eventType,
        note = note,
        data = data,
    }
end

-- End encounter and save data
function HP.EndEncounterTracking(success)
    if not HP.currentEncounter then return end

    -- Reset burst detection accumulators
    _burstAccum = 0
    _burstWindowStart = 0
    _burstLastEvent = 0

    local enc = HP.currentEncounter
    local data = enc.data
    local elapsed = GetTime() - enc.startTime

    -- Guard against zero-duration or zero-healing encounters
    if elapsed <= 0 or enc.totalHealing <= 0 then
        HP.currentEncounter = nil
        return
    end

    -- Calculate final stats (safe: elapsed>0 and totalHealing>0 guaranteed)
    local avgHPS = enc.effectiveHealing / elapsed
    local overhealPct = (enc.overhealing / enc.totalHealing) * 100
    local efficiency = (enc.effectiveHealing / enc.totalHealing) * 100

    -- Update last activity timestamp for pruning
    data.lastSeen = time()

    -- Update exponentially weighted moving averages
    local n = math.min(data.attempts, 10)
    data.averages.hps = ((data.averages.hps * (n - 1)) + avgHPS) / n
    data.averages.overheal = ((data.averages.overheal * (n - 1)) + overhealPct) / n
    data.averages.casts = ((data.averages.casts * (n - 1)) + enc.casts) / n

    -- Update personal bests (kills only — success must be boolean true)
    if success == true then
        data.kills = data.kills + 1
        if avgHPS > data.personalBests.hps then
            data.personalBests.hps = avgHPS
            print("|cff33ccffHealPredict:|r New HPS record on " .. (enc.bossName or "Unknown") .. "! " .. string.format("%.0f", avgHPS))
        end
        if efficiency > data.personalBests.efficiency then
            data.personalBests.efficiency = efficiency
        end
        if overhealPct < data.personalBests.overheal then
            data.personalBests.overheal = overhealPct
        end
        if enc.wentOOM and (not data.personalBests.oomTime or enc.wentOOM > data.personalBests.oomTime) then
            data.personalBests.oomTime = enc.wentOOM -- Later OOM is better
        end
    else
        data.wipes = data.wipes + 1
    end

    -- Merge spell usage into historical data (correct weighted averaging)
    for spellName, spellData in pairs(enc.spellUsage) do
        if not data.spellUsage[spellName] then
            data.spellUsage[spellName] = { casts = 0, avgHeal = 0, overheal = 0 }
        end
        local hist = data.spellUsage[spellName]
        local prevCasts = hist.casts
        hist.casts = prevCasts + spellData.casts
        if hist.casts > 0 then
            local newAvgHeal = spellData.total / spellData.casts
            local newAvgOverheal = spellData.overheal / spellData.casts
            hist.avgHeal = (hist.avgHeal * prevCasts + newAvgHeal * spellData.casts) / hist.casts
            hist.overheal = (hist.overheal * prevCasts + newAvgOverheal * spellData.casts) / hist.casts
        end
    end
    
    -- Save key moments (damage spikes, etc) with ±3s merge tolerance
    for _, event in ipairs(enc.events) do
        if event.type == "BURST" or event.type == "OOM" or event.type == "CD_USED" then
            -- Try to merge with existing moment of same type+note within ±3s
            local merged = false
            for _, km in ipairs(data.keyMoments) do
                if km.type == event.type and km.note == event.note then
                    local diff = math.abs(km.time - event.time)
                    if diff <= 3 then
                        -- Weighted-average timestamp for increasing precision
                        local c = km.count or 1
                        km.time = (km.time * c + event.time) / (c + 1)
                        km.count = c + 1
                        merged = true
                        break
                    end
                end
            end
            if not merged then
                event.count = 1
                data.keyMoments[#data.keyMoments + 1] = event
            end
            -- Cap at 30 moments; evict lowest-count when full
            if #data.keyMoments > 30 then
                local minIdx, minCount = 1, (data.keyMoments[1].count or 1)
                for i = 2, #data.keyMoments do
                    local c = data.keyMoments[i].count or 1
                    if c < minCount then minIdx = i; minCount = c end
                end
                table.remove(data.keyMoments, minIdx)
            end
        end
    end
    
    print(string.format("|cff33ccffHealPredict:|r Encounter ended. HPS: %.0f, Overheal: %.1f%%", avgHPS, overhealPct))

    -- Do one final panel update so player sees end-of-fight stats
    if HP.UpdateEncounterSuggestions then HP.UpdateEncounterSuggestions() end
    if HP.HideEncounterPanel then HP.HideEncounterPanel() end

    HP.currentEncounter = nil
end

-- Get smart suggestions for current encounter
function HP.GetEncounterSuggestions()
    if not HP.currentEncounter then return {} end
    
    local enc = HP.currentEncounter
    local data = enc.data
    local suggestions = {}
    local now = GetTime()
    local elapsed = now - enc.startTime
    
    -- Compare to personal best
    if data.personalBests.hps > 0 and elapsed > 0 then
        local currentHPS = enc.effectiveHealing / elapsed
        local hpsRatio = currentHPS / data.personalBests.hps
        
        if hpsRatio < 0.8 then
            suggestions[#suggestions + 1] = {
                type = "WARNING",
                message = string.format("HPS is %.0f%% below your best (%.0f)", (1 - hpsRatio) * 100, data.personalBests.hps),
                icon = "⚠️",
            }
        elseif hpsRatio > 1.1 then
            suggestions[#suggestions + 1] = {
                type = "GOOD",
                message = string.format("HPS is %.0f%% above your best!", (hpsRatio - 1) * 100),
                icon = "✓",
            }
        end
    end
    
    -- Check overheal
    local currentOverheal = enc.totalHealing > 0 and (enc.overhealing / enc.totalHealing) * 100 or 0
    if currentOverheal > 40 then
        suggestions[#suggestions + 1] = {
            type = "TIP",
            message = string.format("Overhealing at %.1f%% - try lower ranks or wait for deficits", currentOverheal),
            icon = "💡",
        }
    end
    
    -- Predict OOM (sliding window: last 60 seconds of snapshots)
    if #enc.manaSnapshots >= 2 then
        local last = enc.manaSnapshots[#enc.manaSnapshots]
        local windowStart = last
        for i = #enc.manaSnapshots - 1, 1, -1 do
            local snap = enc.manaSnapshots[i]
            if last.time - snap.time >= 60 then break end
            windowStart = snap
        end
        local manaUsed = windowStart.mana - last.mana
        local timePassed = last.time - windowStart.time

        if timePassed > 10 and manaUsed > 0 then
            local burnRate = manaUsed / timePassed -- mana per second
            local remaining = UnitPower("player", 0)
            local timeToOOM = remaining / burnRate
            
            if timeToOOM < 30 then
                suggestions[#suggestions + 1] = {
                    type = "URGENT",
                    message = string.format("OOM in ~%.0f seconds! Conserve mana!", timeToOOM),
                    icon = "🔥",
                }
            elseif timeToOOM < 60 then
                suggestions[#suggestions + 1] = {
                    type = "WARNING",
                    message = string.format("OOM in ~%.0f seconds", timeToOOM),
                    icon = "⚠️",
                }
            end
        end
    end
    
    -- Check for learned key moments (require at least 3 observations)
    -- Also check instance keyMoments when scope=2
    local momentSources = { data.keyMoments }
    if (Settings.cdAdvisorScope or 1) == 2 then
        local instKey = HP.GetInstanceKey and HP.GetInstanceKey()
        if instKey and HP.instanceDB[instKey] and HP.instanceDB[instKey].keyMoments then
            momentSources[#momentSources + 1] = HP.instanceDB[instKey].keyMoments
        end
    end

    -- Collect CD_USED moments at current fight time for cross-reference
    local cdUsedNotes = {}
    for _, moments in ipairs(momentSources) do
        for _, moment in ipairs(moments) do
            if moment.type == "CD_USED" and (moment.count or 1) >= 3 then
                local diff = math.abs(moment.time - elapsed)
                if diff <= 5 then
                    cdUsedNotes[moment.note] = true
                end
            end
        end
    end
    local cdHistoryStr = ""
    if next(cdUsedNotes) then
        local cds = {}
        for cd in pairs(cdUsedNotes) do cds[#cds + 1] = cd end
        cdHistoryStr = " — " .. table.concat(cds, "/") .. " used here historically"
    end

    for _, moments in ipairs(momentSources) do
        for _, moment in ipairs(moments) do
            if moment.type == "BURST" and (moment.count or 1) >= 3 then
                local timeToEvent = moment.time - elapsed
                if timeToEvent > 0 and timeToEvent <= 15 then
                    local msg, priority
                    if timeToEvent <= 3 then
                        -- Urgent: red
                        msg = string.format("%s NOW! (in %.0fs)%s", moment.note or "Raid Damage", timeToEvent, cdHistoryStr)
                        priority = 1
                    elseif timeToEvent <= 8 then
                        -- Warning: orange
                        msg = string.format("%s in ~%.0fs — save CDs!%s", moment.note or "Raid Damage", timeToEvent, cdHistoryStr)
                        priority = 2
                    else
                        -- Info: blue
                        msg = string.format("%s in ~%.0fs (observed %dx)", moment.note or "Raid Damage", timeToEvent, moment.count or 3)
                        priority = 3
                    end
                    suggestions[#suggestions + 1] = {
                        type = "PREDICT",
                        message = msg,
                        icon = "⏰",
                        priority = priority,
                    }
                end
            end
        end
    end

    return suggestions
end

-- Format encounter data for display
function HP.FormatEncounterSummary(key)
    local data = HP.encounterDB[key]
    if not data then return "No data for " .. key end
    local displayName = data.bossName or key

    local lines = {
        string.format("|cff33ccff%s|r", displayName),
        string.format("Attempts: %d (%d kills, %d wipes)", data.attempts, data.kills, data.wipes),
        "",
        "|cff33ccffPersonal Bests:|r",
        string.format("  HPS: %.0f", data.personalBests.hps),
        string.format("  Efficiency: %.1f%%", data.personalBests.efficiency),
        string.format("  Overheal: %.1f%%", data.personalBests.overheal),
        data.personalBests.oomTime and string.format("  OOM Time: %.0fs", data.personalBests.oomTime) or "  OOM Time: Never",
        "",
        "|cff33ccffAverages (last 10):|r",
        string.format("  HPS: %.0f", data.averages.hps),
        string.format("  Overheal: %.1f%%", data.averages.overheal),
        string.format("  Casts: %.0f", data.averages.casts),
    }
    
    if next(data.spellUsage) then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cff33ccffSpell Usage:|r"
        for spellName, spellData in pairs(data.spellUsage) do
            lines[#lines + 1] = string.format("  %s: %d casts, %.1f%% OH", spellName, spellData.casts, spellData.overheal)
        end
    end
    
    return table.concat(lines, "\n")
end

-- Show a summary of all learned encounters in chat
function HP.ShowLearningPanel()
    local count = 0
    for _ in pairs(HP.encounterDB) do count = count + 1 end

    if count == 0 then
        print("|cff33ccffHealPredict:|r No encounter data yet. Fight some bosses with learning enabled!")
        return
    end

    print("|cff33ccffHealPredict:|r |cffffcc00Encounter Learning Data|r (" .. count .. " boss(es))")
    for key, data in pairs(HP.encounterDB) do
        local displayName = data.bossName or key
        local line = string.format("  |cff00ff00%s|r - %d attempts (%d kills, %d wipes)",
            displayName, data.attempts, data.kills, data.wipes)
        if data.personalBests.hps > 0 then
            line = line .. string.format(" - Best HPS: %.0f", data.personalBests.hps)
        end
        print("|cff33ccffHealPredict:|r " .. line)
    end
    print("|cff33ccffHealPredict:|r Use |cff00ff00/hp learning <bossname>|r for detailed stats.")
end

---------------------------------------------------------------------------
-- Instance-Wide Learning System
-- Tracks entire dungeon/raid runs including trash and boss pulls
---------------------------------------------------------------------------
HP.instanceDB = {}       -- Per-instance statistics (saved)
HP.currentInstance = nil  -- Active instance tracking session

local function GetMaxRunHistory() return Settings.maxRunHistory or 10 end

-- Generate instance key: "Name-Difficulty-MapID"
function HP.GetInstanceKey()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return nil end
    if instanceType == "pvp" or instanceType == "arena" then return nil end
    -- Scope filter: 1=dungeons only, 2=raids only, 3=both
    local scope = Settings.instanceTrackingScope or 3
    if scope == 1 and instanceType ~= "party" then return nil end
    if scope == 2 and instanceType ~= "raid" then return nil end

    local name, _, _, difficultyName, _, _, _, mapID = GetInstanceInfo()
    if not name or not mapID then return nil end

    local difficulty = difficultyName or "Normal"
    return name .. "-" .. difficulty .. "-" .. mapID, name, mapID, difficulty
end

-- Initialize instance data structure
function HP.InitInstanceData(key, instanceName, mapID, difficulty)
    if not HP.instanceDB[key] then
        HP.instanceDB[key] = {
            instanceName = instanceName,
            mapID = mapID,
            difficulty = difficulty,
            firstSeen = time(),
            totalRuns = 0,
            completedRuns = 0,
            averages = {
                duration = 0, hps = 0, overhealPct = 0, casts = 0, deaths = 0,
            },
            personalBests = {
                fastestClear = nil,
                highestHPS = 0,
                lowestOverheal = 100,
                efficiency = 0,
            },
            runs = {},
            bosses = {},
        }
    end
    return HP.instanceDB[key]
end

-- Start tracking instance run
function HP.StartInstanceRun()
    if HP.currentInstance then return end -- already tracking
    local key, name, mapID, difficulty = HP.GetInstanceKey()
    if not key then return end
    if not Settings.instanceTracking then return end

    local data = HP.InitInstanceData(key, name, mapID, difficulty)
    data.totalRuns = data.totalRuns + 1

    HP.currentInstance = {
        key = key,
        name = name,
        instanceName = name,
        mapID = mapID,
        difficulty = difficulty,
        data = data,
        startTime = GetTime(),
        pullCount = 0,
        currentPull = nil,
        totalHealing = 0,
        effectiveHealing = 0,
        overhealing = 0,
        casts = 0,
        deaths = {},
        bossesKilled = {},
        spellUsage = {},
        manaSnapshots = {},
    }

    print(fmt("|cff33ccffHealPredict:|r Instance tracking started: %s (%s)", name, difficulty))
    if HP.ShowEncounterPanel then HP.ShowEncounterPanel(true) end
end

-- End instance run (on zone change or logout)
function HP.EndInstanceRun(completed)
    if not HP.currentInstance then return end

    local inst = HP.currentInstance
    local data = inst.data
    local elapsed = GetTime() - inst.startTime

    -- Too short, probably just zoned in and out
    if elapsed < 60 then
        HP.currentInstance = nil
        return
    end

    -- Auto-detect completion: all historically known bosses killed this run
    if not completed and #inst.bossesKilled > 0 then
        local knownBosses = 0
        for _ in pairs(data.bosses) do knownBosses = knownBosses + 1 end
        if knownBosses > 0 and #inst.bossesKilled >= knownBosses then
            completed = true
        end
    end

    local avgHPS = elapsed > 0 and (inst.effectiveHealing / elapsed) or 0
    local overhealPct = inst.totalHealing > 0 and (inst.overhealing / inst.totalHealing) * 100 or 0
    local efficiency = inst.totalHealing > 0 and (inst.effectiveHealing / inst.totalHealing) * 100 or 0
    local deathCount = 0
    for _, c in pairs(inst.deaths) do deathCount = deathCount + c end

    -- Build top 5 spells
    local topSpells = {}
    local spellList = {}
    for name, stats in pairs(inst.spellUsage) do
        spellList[#spellList + 1] = { name = name, casts = stats.casts, total = stats.total, overheal = stats.overheal }
    end
    table.sort(spellList, function(a, b) return a.casts > b.casts end)
    for i = 1, mathmin(5, #spellList) do
        local s = spellList[i]
        topSpells[s.name] = { casts = s.casts, avgHeal = s.total / s.casts, overheal = s.overheal }
    end

    -- Store run in history (FIFO)
    local run = {
        timestamp = time(),
        duration = elapsed,
        completed = completed,
        totalHealing = inst.totalHealing,
        effectiveHealing = inst.effectiveHealing,
        overhealPct = overhealPct,
        casts = inst.casts,
        deaths = inst.deaths,
        bossesKilled = inst.bossesKilled,
        topSpells = topSpells,
    }
    tinsert(data.runs, run)
    while #data.runs > GetMaxRunHistory() do
        table.remove(data.runs, 1)
    end

    if completed then
        data.completedRuns = data.completedRuns + 1
    end

    -- Update rolling averages (completed runs only)
    if completed then
        local n = mathmin(data.completedRuns, GetMaxRunHistory())
        data.averages.duration   = ((data.averages.duration * (n - 1)) + elapsed) / n
        data.averages.hps        = ((data.averages.hps * (n - 1)) + avgHPS) / n
        data.averages.overhealPct = ((data.averages.overhealPct * (n - 1)) + overhealPct) / n
        data.averages.casts      = ((data.averages.casts * (n - 1)) + inst.casts) / n
        data.averages.deaths     = ((data.averages.deaths * (n - 1)) + deathCount) / n

        -- Personal bests
        if not data.personalBests.fastestClear or elapsed < data.personalBests.fastestClear then
            data.personalBests.fastestClear = elapsed
        end
        if avgHPS > data.personalBests.highestHPS then
            data.personalBests.highestHPS = avgHPS
        end
        if overhealPct < data.personalBests.lowestOverheal then
            data.personalBests.lowestOverheal = overhealPct
        end
        if efficiency > data.personalBests.efficiency then
            data.personalBests.efficiency = efficiency
        end
    end

    print(fmt("|cff33ccffHealPredict:|r Instance run ended. Duration: %dm %ds, HPS: %.0f, Overheal: %.1f%%",
        mathfloor(elapsed / 60), mathfloor(elapsed % 60), avgHPS, overhealPct))

    if HP.HideEncounterPanel then HP.HideEncounterPanel() end
    HP.currentInstance = nil
end

-- Record heal during instance run (trash or boss)
function HP.RecordInstanceHeal(spellName, amount, overheal)
    if not HP.currentInstance then return end

    local inst = HP.currentInstance
    local effective = amount - overheal

    inst.totalHealing = inst.totalHealing + amount
    inst.effectiveHealing = inst.effectiveHealing + effective
    inst.overhealing = inst.overhealing + overheal
    inst.casts = inst.casts + 1

    -- Per-spell tracking
    if not inst.spellUsage[spellName] then
        inst.spellUsage[spellName] = { casts = 0, total = 0, effective = 0, overheal = 0 }
    end
    local spell = inst.spellUsage[spellName]
    spell.casts = spell.casts + 1
    spell.total = spell.total + amount
    spell.effective = spell.effective + effective
    spell.overheal = spell.overheal + overheal

    -- Also record to current pull if active
    if inst.currentPull then
        inst.currentPull.totalHealing = inst.currentPull.totalHealing + amount
        inst.currentPull.effectiveHealing = inst.currentPull.effectiveHealing + effective
        inst.currentPull.casts = inst.currentPull.casts + 1
    end
end

-- Start tracking a pull (trash or boss)
function HP.StartInstancePull(bossName, bossID, difficultyID)
    if not HP.currentInstance then return end

    local inst = HP.currentInstance
    inst.pullCount = inst.pullCount + 1
    inst.currentPull = {
        pullNumber = inst.pullCount,
        isBoss = bossName ~= nil,
        bossName = bossName,
        bossID = bossID,
        startTime = GetTime(),
        totalHealing = 0,
        effectiveHealing = 0,
        casts = 0,
    }

    -- Also start encounter tracking if boss
    if bossName then
        HP.StartEncounterTracking(bossName, bossID, difficultyID)
    end
end

-- End pull tracking
function HP.EndInstancePull(success)
    if not HP.currentInstance or not HP.currentInstance.currentPull then return end

    local inst = HP.currentInstance
    local pull = inst.currentPull

    if pull.isBoss and success == true then
        inst.bossesKilled[#inst.bossesKilled + 1] = pull.bossName
        inst.data.bosses[pull.bossName] = true
    end

    -- End encounter tracking if boss
    if pull.isBoss then
        HP.EndEncounterTracking(success == true)
    end

    inst.currentPull = nil
end

-- Record instance death
function HP.RecordInstanceDeath(playerName)
    if not HP.currentInstance then return end
    local inst = HP.currentInstance
    inst.deaths[playerName] = (inst.deaths[playerName] or 0) + 1
end

-- Prune old instance data (keep last N days based on Settings, 0 = never)
function HP.PruneInstanceData()
    local days = Settings.dataRetentionDays or 30
    if days == 0 then return end -- never auto-prune
    local now = time()
    local retentionSec = days * 24 * 60 * 60

    for key, data in pairs(HP.instanceDB) do
        local lastRun = data.runs[#data.runs]
        local lastActivity = lastRun and lastRun.timestamp or data.firstSeen
        if now - lastActivity > retentionSec then
            HP.instanceDB[key] = nil
        end
    end

    -- Also prune encounter data older than retention period (by last activity)
    for key, data in pairs(HP.encounterDB) do
        local lastActivity = data.lastSeen or data.firstSeen
        if lastActivity and (now - lastActivity) > retentionSec then
            HP.encounterDB[key] = nil
        end
    end
end

-- Show instance learning data in chat
function HP.ShowInstanceData()
    local count = 0
    for _ in pairs(HP.instanceDB) do count = count + 1 end

    if count == 0 then
        print("|cff33ccffHealPredict:|r No instance data yet. Run some dungeons with learning enabled!")
        return
    end

    print("|cff33ccffHealPredict:|r |cffffcc00Instance Learning Data|r (" .. count .. " instance(s))")
    for key, data in pairs(HP.instanceDB) do
        local line = fmt("  |cff00ff00%s|r (%s) - %d runs (%d completed)",
            data.instanceName, data.difficulty, data.totalRuns, data.completedRuns)
        if data.personalBests.highestHPS > 0 then
            line = line .. fmt(" - Best HPS: %.0f", data.personalBests.highestHPS)
        end
        if data.personalBests.fastestClear then
            line = line .. fmt(" - Fastest: %dm %ds",
                mathfloor(data.personalBests.fastestClear / 60),
                mathfloor(data.personalBests.fastestClear % 60))
        end
        print("|cff33ccffHealPredict:|r " .. line)
    end
end
