-- HealPredict - Render.lua
-- Heal calculation, bar painting, frame setup, hooks, events, refresh
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn
-- Modifications by PineappleTuesday

local HP = HealPredict

-- Local references for performance
local Settings     = HP.Settings
local Engine       = HP.Engine
local frameData    = HP.frameData
local frameGUID    = HP.frameGUID
local guidToUnit   = HP.guidToUnit
local guidToCompact = HP.guidToCompact
local guidToPlate  = HP.guidToPlate
local shieldGUIDs      = HP.shieldGUIDs
local shieldAmounts    = HP.shieldAmounts
local defenseGUIDs     = HP.defenseGUIDs
local SHIELD_NAMES     = HP.SHIELD_NAMES
local activeShields    = HP.activeShields
local dispelGUIDs      = HP.dispelGUIDs
local cdGUIDs          = HP.cdGUIDs
local resTargets       = HP.resTargets
local RES_SPELLS       = HP.RES_SPELLS
local EXTERNAL_CDS     = HP.EXTERNAL_CDS

local UnitInRange      = UnitInRange
local UnitTarget       = UnitTarget
local UnitCastingInfo  = UnitCastingInfo

local ApplyGradient = HP.ApplyGradient
local CachedColor   = HP.CachedColor
local HookIfExists  = HP.HookIfExists

local bit_band, bit_bor = HP.bit_band, HP.bit_bor
local fmt, mathmin, mathmax, mathfloor = HP.fmt, HP.mathmin, HP.mathmax, HP.mathfloor
local pairs, ipairs, next, wipe, select = pairs, ipairs, next, wipe, select
local unpack = HP.unpack


local pcall = pcall
local PlaySound = PlaySound
local PlaySoundFile = PlaySoundFile
local SOUNDKIT = SOUNDKIT

local HEALER_CLASSES = { PRIEST=true, PALADIN=true, DRUID=true, SHAMAN=true }
local _lastDispelSound = 0
local _lastLowManaSound = 0
local SOUND_DEBOUNCE = 5

---------------------------------------------------------------------------
-- Alert sound choices
---------------------------------------------------------------------------
local ALERT_SOUNDS = {
    { label = "Raid Warning",  play = function() PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master") end },
    { label = "Ready Check",   play = function() PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960, "Master") end },
    { label = "Alarm Clock",   play = function() PlaySoundFile("Sound\\Interface\\AlarmClockWarning3.ogg", "Master") end },
    { label = "Flag Captured", play = function() PlaySoundFile("Sound\\Spells\\PVPFlagTakenHorde.ogg", "Master") end },
    { label = "None" },
}
HP.ALERT_SOUNDS = ALERT_SOUNDS

local function PlayAlertSound(choiceIdx)
    local entry = ALERT_SOUNDS[choiceIdx or 1]
    if entry and entry.play then entry.play() end
end

local GetTime = GetTime
local UnitGUID = UnitGUID
local UnitCanAssist = UnitCanAssist
local UnitHealthMax = UnitHealthMax
local UnitIsConnected = UnitIsConnected
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local InCombatLockdown = InCombatLockdown
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitClass = UnitClass

local PlayerFrame    = HP.PlayerFrame
local PetFrame       = HP.PetFrame
local TargetFrame    = HP.TargetFrame
local TargetFrameToT = HP.TargetFrameToT
local FocusFrame     = HP.FocusFrame
local PartyFrames    = HP.PartyFrames
local PartyPetFrames = HP.PartyPetFrames

---------------------------------------------------------------------------
-- Deferral: batch updates to once-per-render
---------------------------------------------------------------------------
local lastRender = -1
local dirtyUnit    = {}
local dirtyCompact = {}
local hookedFrames = {}

local function QueueUnit(frame)
    if GetTime() > lastRender then
        dirtyUnit[frame] = true
    else
        HP.UpdateUnit(frame)
    end
end

local function QueueCompact(frame)
    if GetTime() > lastRender then
        dirtyCompact[frame] = true
    else
        HP.UpdateCompact(frame)
    end
end

---------------------------------------------------------------------------
-- Build the filter bitmask from saved booleans (cached)
---------------------------------------------------------------------------
local _filterCache = nil
local _filterShowOthers, _filterDirect, _filterHoT, _filterChannel, _filterBomb

local function BuildFilter()
    local so = Settings.showOthers
    local fd = Settings.filterDirect
    local fh = Settings.filterHoT
    local fc = Settings.filterChannel
    local fb = Settings.filterBomb
    if _filterCache and so == _filterShowOthers and fd == _filterDirect and fh == _filterHoT and fc == _filterChannel and fb == _filterBomb then
        return _filterCache
    end
    _filterShowOthers, _filterDirect, _filterHoT, _filterChannel, _filterBomb = so, fd, fh, fc, fb
    if not so then _filterCache = 0; return 0 end
    local mask = 0
    if fd then mask = bit_bor(mask, Engine.DIRECT_HEALS) end
    if fh then mask = bit_bor(mask, Engine.HOT_HEALS) end
    if fc then mask = bit_bor(mask, Engine.CHANNEL_HEALS) end
    if fb then mask = bit_bor(mask, Engine.BOMB_HEALS) end
    _filterCache = mask
    return mask
end

---------------------------------------------------------------------------
-- Core: get incoming heal amounts (separate timeframes per heal type)
---------------------------------------------------------------------------
-- Supplement engine amounts with Blizzard's UnitGetIncomingHeals so direct
-- heals from players who AREN'T running HealPredict still render. The API
-- only returns in-progress direct casts (not HoTs in TBC) and is already
-- scaled by the target's inbound heal modifier, matching our post-mod
-- engine totals. If the API reports more "other" healing than the engine
-- knows about, the delta is a non-HealPredict caster's direct heal — add
-- it to the "other direct" slot (ot1) so it colors as OtherDirect.
--
-- engineOther: sum of post-mod heals from other casters across the 5 slots,
--              keyed by layout (sorted vs non-sorted).
local function ApplyAPISupplement(unit, my1, my2, ot1, ot2, ot3, isSorted)
    if not UnitGetIncomingHeals then return my1, my2, ot1, ot2, ot3 end
    local apiTotal = UnitGetIncomingHeals(unit) or 0
    local apiSelf  = UnitGetIncomingHeals(unit, "player") or 0
    local apiOther = apiTotal - apiSelf
    if apiOther <= 0 then return my1, my2, ot1, ot2, ot3 end

    -- In sorted mode, slot 1 (my1) is otherBefore (other direct heals
    -- landing before mine) — it's "other", not "my", despite the name.
    -- In non-sorted, my1/my2 are self amounts.
    local engineOther
    if isSorted then
        engineOther = my1 + ot1 + ot3
    else
        engineOther = ot1 + ot2 + ot3
    end

    if apiOther > engineOther then
        ot1 = ot1 + (apiOther - engineOther)
    end
    return my1, my2, ot1, ot2, ot3
end

local function GetHeals(unit)
    if not unit or not (UnitCanAssist("player", unit) or type(unit) == "string" and unit:match("pet") and UnitExists(unit)) then
        return 0, 0, 0, 0, 0
    end

    local guid   = UnitGUID(unit)
    if not guid then return 0, 0, 0, 0, 0 end
    local filter = BuildFilter()
    local me     = UnitGUID("player")
    local mod    = Engine:GetHealModifier(guid) or 1.0

    local my1, my2, ot1, ot2
    if not Settings.useTimeLimit then
        local dA1, dA2, sA1, sA2 = Engine:GetHealAmountEx(
            guid, filter, nil, me, Engine.ALL_HEALS, nil)
        my1, my2 = (sA1 or 0) * mod, (sA2 or 0) * mod
        ot1, ot2 = (dA1 or 0) * mod, (dA2 or 0) * mod
    else
        local now = GetTime()
        local sT1, sT2, dT1, dT2 = 0, 0, 0, 0

        local directMask = bit_bor(Engine.DIRECT_HEALS, Engine.BOMB_HEALS)
        local directEnd  = now + Settings.directTimeframe
        local filterD    = bit_band(filter, directMask)
        if filterD > 0 then
            local d1, d2, s1, s2 = Engine:GetHealAmountEx(
                guid, filterD, directEnd, me, directMask, directEnd)
            sT1 = sT1 + (s1 or 0); sT2 = sT2 + (s2 or 0)
            dT1 = dT1 + (d1 or 0); dT2 = dT2 + (d2 or 0)
        end

        local channelEnd = now + Settings.channelTimeframe
        local filterC    = bit_band(filter, Engine.CHANNEL_HEALS)
        if filterC > 0 then
            local d1, d2, s1, s2 = Engine:GetHealAmountEx(
                guid, Engine.CHANNEL_HEALS, channelEnd, me, Engine.CHANNEL_HEALS, channelEnd)
            sT1 = sT1 + (s1 or 0); sT2 = sT2 + (s2 or 0)
            dT1 = dT1 + (d1 or 0); dT2 = dT2 + (d2 or 0)
        end

        local hotEnd  = now + Settings.hotTimeframe
        local filterH = bit_band(filter, Engine.HOT_HEALS)
        if filterH > 0 then
            local d1, d2, s1, s2 = Engine:GetHealAmountEx(
                guid, Engine.HOT_HEALS, hotEnd, me, Engine.HOT_HEALS, hotEnd)
            sT1 = sT1 + (s1 or 0); sT2 = sT2 + (s2 or 0)
            dT1 = dT1 + (d1 or 0); dT2 = dT2 + (d2 or 0)
        end

        my1, my2, ot1, ot2 = sT1 * mod, sT2 * mod, dT1 * mod, dT2 * mod
    end

    return ApplyAPISupplement(unit, my1, my2, ot1, ot2, 0, false)
end

local function GetHealsSorted(unit)
    if not unit or not (UnitCanAssist("player", unit) or type(unit) == "string" and unit:match("pet") and UnitExists(unit)) then
        return 0, 0, 0, 0, 0
    end
    local guid = UnitGUID(unit)
    if not guid then return 0, 0, 0, 0, 0 end
    local filter = BuildFilter()
    local mod = Engine:GetHealModifier(guid) or 1.0
    local ob, sa, oa, ha, oh = Engine:GetHealAmountSorted(guid, filter, Engine.ALL_HEALS)
    local my1, my2, ot1, ot2, ot3 =
        ob * mod, sa * mod, oa * mod, ha * mod, (oh or 0) * mod
    return ApplyAPISupplement(unit, my1, my2, ot1, ot2, ot3, true)
end

-- Export for ElvUI compatibility module
HP.GetHeals = GetHeals
HP.GetHealsSorted = GetHealsSorted
HP.BuildFilter = BuildFilter

---------------------------------------------------------------------------
-- Position anchors for configurable text elements
-- Healer count: 1=TL, 2=TR, 3=BL, 4=BR
-- Heal text:    1=Left, 2=Right, 3=Top, 4=Bottom
---------------------------------------------------------------------------
local HEALER_COUNT_ANCHORS = {
    { "TOPLEFT",     "TOPLEFT",     2,  -1, "LEFT"  },
    { "TOPRIGHT",    "TOPRIGHT",    -1, -1, "RIGHT" },
    { "BOTTOMLEFT",  "BOTTOMLEFT",  2,  1,  "LEFT"  },
    { "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 1,  "RIGHT" },
}

local HEAL_TEXT_ANCHORS = {
    { "RIGHT", "LEFT",   -4, 0, "RIGHT" },
    { "LEFT",  "RIGHT",   4, 0, "LEFT"  },
    { "BOTTOM","TOP",     0, 2, "CENTER"},
    { "TOP",   "BOTTOM",  0,-2, "CENTER"},
}

-- HoT dot anchors: { anchorPoint, relPoint, baseX, baseY }
-- Dots are sized by Settings.hotDotSize with Settings.hotDotSpacing spacing
local HOT_DOT_ANCHORS = {
    { "BOTTOMLEFT",  "BOTTOMLEFT",   2,  1 },
    { "BOTTOMRIGHT", "BOTTOMRIGHT", -14,  1 },
    { "TOPLEFT",     "TOPLEFT",      2, -5 },
    { "TOPRIGHT",    "TOPRIGHT",   -14, -5 },
}
local HOT_DOT_POS_LABELS = { "Bottom-Left", "Bottom-Right", "Top-Left", "Top-Right" }

-- Defensive display anchors: { anchorPoint, relPoint, offsetX, offsetY, justifyH }
local DEFENSE_ANCHORS = {
    { "CENTER",       "CENTER",       0,  0, "CENTER" },
    { "TOPLEFT",      "TOPLEFT",      4, -2, "LEFT"   },
    { "TOPRIGHT",     "TOPRIGHT",    -4, -2, "RIGHT"  },
    { "BOTTOMLEFT",   "BOTTOMLEFT",   4,  2, "LEFT"   },
    { "BOTTOMRIGHT",  "BOTTOMRIGHT", -4,  2, "RIGHT"  },
}
local DEFENSE_POS_LABELS = { "Center", "Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right" }

-- Apply anchors for HoT dots (own and other healers')
-- Row mode: 1 = Two rows (own below, other above), 2 = Single row (all together)
local function ApplyDotAnchors(fd)
    if not fd or not fd.hotDots then return end
    local pos = Settings.hotDotsPos or 1
    local a = HOT_DOT_ANCHORS[pos] or HOT_DOT_ANCHORS[1]
    local spacing = Settings.hotDotSpacing or 6
    local rowMode = Settings.hotDotRowMode or 1
    local size = Settings.hotDotSize or 4
    local hb = fd.hb
    if not hb then return end
    
    -- Calculate row offset based on size
    local rowOffset = size + 2  -- Small gap between rows
    
    local ox = Settings.hotDotsOffsetX or 0
    local oy = Settings.hotDotsOffsetY or 0

    -- Position own HoT dots (5 dots)
    for di = 1, 5 do
        if fd.hotDots[di] then
            fd.hotDots[di]:ClearAllPoints()
            local xOffset = a[3] + (di - 1) * spacing + ox
            local yOffset = a[4] + oy
            fd.hotDots[di]:SetPoint(a[1], hb, a[2], xOffset, yOffset)
        end
    end

    -- Position other healers' HoT dots
    if fd.hotDotsOther then
        for di = 1, 5 do
            if fd.hotDotsOther[di] then
                fd.hotDotsOther[di]:ClearAllPoints()
                local xOffset, yOffset
                if rowMode == 2 then
                    xOffset = a[3] + (5 + di - 1) * spacing + 4 + ox
                    yOffset = a[4] + oy
                else
                    xOffset = a[3] + (di - 1) * spacing + ox
                    yOffset = a[4] + rowOffset + oy
                end
                fd.hotDotsOther[di]:SetPoint(a[1], hb, a[2], xOffset, yOffset)
            end
        end
    end
end

local function ApplyTextAnchor(fs, hb, anchors, pos, ox, oy)
    local a = anchors[pos] or anchors[1]
    fs:ClearAllPoints()
    fs:SetPoint(a[1], hb, a[2], a[3] + (ox or 0), a[4] + (oy or 0))
    fs:SetJustifyH(a[5])
end

-- Refresh HoT dot anchors and sizes across all frames
function HP.RefreshHoTDots()
    local size = Settings.hotDotSize or 4
    local isIconMode = (Settings.hotDotDisplayMode or 1) == 2
    
    for frame, fd in pairs(frameData) do
        if fd.hotDots then
            -- Update size (works for both textures and frames)
            for di = 1, 5 do
                if fd.hotDots[di] then
                    fd.hotDots[di]:SetSize(size, size)
                end
            end
            -- Update other healers' dots size
            if fd.hotDotsOther then
                for di = 1, 5 do
                    if fd.hotDotsOther[di] then
                        fd.hotDotsOther[di]:SetSize(size, size)
                    end
                end
            end
            -- Re-apply anchors
            ApplyDotAnchors(fd)
        end
    end
end

-- Update HoT dot cooldown displays
local function UpdateHoTCooldown(fd, guid, isOther)
    if not fd or not guid then return end
    
    local cds = isOther and fd.hotDotOtherCooldowns or fd.hotDotCooldowns
    if not cds then return end
    
    local activeHoTs = isOther and HP.hotDotOtherGUIDs[guid] or HP.hotDotGUIDs[guid]
    if not activeHoTs then return end
    
    for di = 1, 5 do
        local cd = cds[di]
        if cd and activeHoTs[di] then
            local hotInfo = activeHoTs[di]
            if type(hotInfo) == "table" and hotInfo.expiration then
                local now = GetTime()
                local duration = hotInfo.duration or 12
                local startTime = hotInfo.expiration - duration
                local remaining = hotInfo.expiration - now
                
                if remaining > 0 and Settings.hotDotShowCooldown ~= false then
                    cd:SetCooldown(startTime, duration)
                    cd:Show()
                else
                    cd:Hide()
                end
            else
                cd:Hide()
            end
        elseif cd then
            cd:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Fill bar positioning â€” absolute pixel from health bar TOPLEFT
-- Avoids anchoring to GetStatusBarTexture() which desyncs with smooth anims
---------------------------------------------------------------------------
local function PositionBarAbs(hb, bar, amount, startPx, cap, barW)
    if cap <= 0 or amount <= 0 then bar:Hide(); return startPx end
    local size = (amount / cap) * barW
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", hb, "TOPLEFT", startPx, 0)
    bar:SetPoint("BOTTOMLEFT", hb, "BOTTOMLEFT", startPx, 0)
    bar:SetWidth(mathmax(size, 1))
    bar:Show()
    return startPx + size
end

---------------------------------------------------------------------------
-- Class colors for class-colored heal bars
---------------------------------------------------------------------------
local RAID_CLASS_COLORS = {
    ["WARRIOR"]     = { 0.78, 0.61, 0.43 },
    ["PALADIN"]     = { 0.96, 0.55, 0.73 },
    ["HUNTER"]      = { 0.67, 0.83, 0.45 },
    ["ROGUE"]       = { 1.00, 0.96, 0.41 },
    ["PRIEST"]      = { 1.00, 1.00, 1.00 },
    ["DEATHKNIGHT"] = { 0.77, 0.12, 0.23 },
    ["SHAMAN"]      = { 0.00, 0.44, 0.87 },
    ["MAGE"]        = { 0.25, 0.78, 0.92 },
    ["WARLOCK"]     = { 0.58, 0.51, 0.79 },
    ["DRUID"]       = { 1.00, 0.49, 0.04 },
    ["MONK"]        = { 0.00, 1.00, 0.60 },
    ["DEMONHUNTER"] = { 0.64, 0.19, 0.79 },
    ["EVOKER"]      = { 0.20, 0.58, 0.50 },
}

local function GetClassColorFromGUID(guid)
    if not guid then return 0.7, 0.7, 0.7 end
    local _, class = GetPlayerInfoByGUID(guid)
    if class then
        local cc = RAID_CLASS_COLORS[class]
        if cc then return cc[1] or 0.7, cc[2] or 0.7, cc[3] or 0.7 end
    end
    return 0.7, 0.7, 0.7 -- Default gray
end

-- Helper to apply test mode class colors - separated to reduce upvalues in RenderPrediction
local function ApplyTestModeClassColors(bars, amounts, my1, my2, ot1, ot2, opaMul, dimFactor, testFrameIndex)
    local ot3 = amounts[5] or 0
    local testClasses = {
        { r = 1.0,  g = 1.0,  b = 1.0,  amt = my1, isSelf = true  },
        { r = 0.0,  g = 1.0,  b = 0.6,  amt = my2, isSelf = true  },
        { r = 0.96, g = 0.55, b = 0.73, amt = ot1, isSelf = false },
        { r = 1.0,  g = 0.96, b = 0.41, amt = ot2, isSelf = false },
        { r = 0.41, g = 0.80, b = 0.94, amt = ot3, isSelf = false },
    }
    if testFrameIndex == 2 then
        testClasses[3] = { r = 0.67, g = 0.83, b = 0.45, amt = ot1, isSelf = false }
        testClasses[4] = { r = 0.0,  g = 1.0,  b = 1.0,  amt = ot2, isSelf = false }
    end
    for idx = 1, 5 do
        local tc = testClasses[idx]
        local bar = bars[idx]
        if bar and tc then
            local aDim = tc.isSelf and 1.0 or dimFactor
            bar:SetVertexColor(tc.r, tc.g, tc.b, opaMul * aDim)
            amounts[idx] = tc.amt
        elseif bar then
            bar:Hide()
        end
    end
end

-- Helper for real mode class colors - separated to reduce upvalues
local function ApplyRealModeClassColors(bars, amounts, unit, opaMul, dimFactor)
    local guid = UnitGUID(unit)
    if not guid then return false end
    local casterHeals = Engine:GetHealAmountByCaster(guid, Engine.ALL_HEALS)
    local casterCount = #casterHeals

    -- Cap total from per-caster data to the original heal total so the
    -- overheal bar doesn't appear when the normal prediction says no overheal.
    local origTotal = (amounts[1] or 0) + (amounts[2] or 0) + (amounts[3] or 0) + (amounts[4] or 0) + (amounts[5] or 0)

    for idx = casterCount + 1, 5 do
        if bars[idx] then bars[idx]:Hide() end
        amounts[idx] = 0
    end

    local assignedTotal = 0
    for idx, healInfo in ipairs(casterHeals) do
        if idx > 5 then break end
        local bar = bars[idx]
        if bar then
            local r, g, b = GetClassColorFromGUID(healInfo.caster)
            local aDim = healInfo.isSelf and 1.0 or dimFactor
            bar:SetVertexColor(r, g, b, opaMul * aDim)
            local amt = healInfo.amount or 0
            -- Don't let per-caster total exceed the original heal total
            amt = mathmin(amt, mathmax(origTotal - assignedTotal, 0))
            amounts[idx] = amt
            assignedTotal = assignedTotal + amt
        end
    end

    -- Fill remaining bars with API-only healers (not tracked by the engine).
    -- Scan group members to find who else is casting a direct heal on this
    -- target so their class color shows up instead of collapsing into a
    -- generic "other" bar.
    if casterCount < 5 and UnitGetIncomingHeals and assignedTotal < origTotal then
        local nextIdx = casterCount + 1
        local engineGUIDs = {}
        for _, hi in ipairs(casterHeals) do
            engineGUIDs[hi.caster] = true
        end

        local memberCount = GetNumGroupMembers and GetNumGroupMembers() or 0
        local prefix = (IsInRaid and IsInRaid()) and "raid" or "party"
        for i = 1, memberCount do
            if nextIdx > 5 then break end
            local mUnit = prefix .. i
            local mGUID = UnitGUID(mUnit)
            if mGUID and not engineGUIDs[mGUID] then
                local mHeal = UnitGetIncomingHeals(unit, mUnit)
                if mHeal and mHeal > 0 then
                    local bar = bars[nextIdx]
                    if bar then
                        local r, g, b = GetClassColorFromGUID(mGUID)
                        bar:SetVertexColor(r, g, b, opaMul * dimFactor)
                        local amt = mathmin(mHeal, origTotal - assignedTotal)
                        amounts[nextIdx] = amt
                        assignedTotal = assignedTotal + amt
                        nextIdx = nextIdx + 1
                    end
                end
            end
        end
    end

    return true
end

---------------------------------------------------------------------------
-- Color palette keys for compact vs unit frames
---------------------------------------------------------------------------
-- Slot 5 is the dedicated foreign-HoT slot in sorted mode. In unsorted
-- mode slot 5 is always 0, but we give it the OtherHoT color anyway for
-- consistency.
local COMPACT_PAL  = { "raidMyDirect", "raidMyHoT", "raidOtherDirect", "raidOtherHoT", "raidOtherHoT" }
local COMPACT_OHPL = { "raidMyDirectOH", "raidMyHoTOH", "raidOtherDirectOH", "raidOtherHoTOH", "raidOtherHoTOH" }
local UNIT_PAL     = { "unitMyDirect", "unitMyHoT", "unitOtherDirect", "unitOtherHoT", "unitOtherHoT" }
local UNIT_OHPL    = { "unitMyDirectOH", "unitMyHoTOH", "unitOtherDirectOH", "unitOtherHoTOH", "unitOtherHoTOH" }

local COMPACT_PAL_SORTED  = { "raidOtherDirect", "raidMyDirect", "raidOtherHoT", "raidMyHoT", "raidOtherHoT" }
local COMPACT_OHPL_SORTED = { "raidOtherDirectOH", "raidMyDirectOH", "raidOtherHoTOH", "raidMyHoTOH", "raidOtherHoTOH" }
local UNIT_PAL_SORTED     = { "unitOtherDirect", "unitMyDirect", "unitOtherHoT", "unitMyHoT", "unitOtherHoT" }
local UNIT_OHPL_SORTED    = { "unitOtherDirectOH", "unitMyDirectOH", "unitOtherHoTOH", "unitMyHoTOH", "unitOtherHoTOH" }

---------------------------------------------------------------------------
-- Core render: paint the 4 prediction bars + shield glow
---------------------------------------------------------------------------
local UnitHealth = UnitHealth

local function RenderPrediction(frame, unit, overflowCap, useGradient, pal, palOH)
    local fd = frameData[frame]
    if not fd or not fd.bars then return 0, 0, 0 end

    local hb = fd.hb
    if not hb then return 0, 0, 0 end

    local isSorted = Settings.smartOrdering

    -- Use hb:GetValue() to match the smooth-animated health bar position.
    -- UnitHealth() returns the real value but desyncs with the visual bar fill.
    local _, cap = hb:GetMinMaxValues()
    if not cap or cap <= 0 then return 0, 0, 0 end
    local hp = hb:GetValue() or 0

    -- Test mode: only inject fake data into test frames, not all frames
    local my1, my2, ot1, ot2, ot3
    if HP._testMode and fd._isTestFrame then
        if cap > 0 then
            if isSorted then
                my1, my2, ot1, ot2, ot3 = cap * 0.10, cap * 0.20, cap * 0.05, cap * 0.12, cap * 0.08
            else
                my1, my2, ot1, ot2, ot3 = cap * 0.25, cap * 0.15, cap * 0.10, cap * 0.05, 0
            end
        else
            my1, my2, ot1, ot2, ot3 = 0, 0, 0, 0, 0
        end
    elseif isSorted then
        my1, my2, ot1, ot2, ot3 = GetHealsSorted(unit)
    else
        my1, my2, ot1, ot2, ot3 = GetHeals(unit)
    end
    ot3 = ot3 or 0

    local overhealing = cap <= 0 and 0 or mathmax((hp + my1 + my2 + ot1 + ot2 + ot3) / cap - 1, 0)
    local activePal = pal
    if Settings.useOverhealColors and overhealing >= Settings.overhealThreshold then
        activePal = palOH
    end

    local colors = Settings.colors
    local bars = fd.bars
    local opaMul = Settings.barOpacity
    local dimFactor
    if isSorted then
        dimFactor = Settings.dimNonImminent and 0.6 or 1.0
    else
        dimFactor = (Settings.dimNonImminent and Settings.useTimeLimit) and 0.6 or 1.0
    end

    local amounts = { my1, my2, ot1, ot2, ot3 }

    -- Class-colored bars mode (when smart ordering + class colors enabled)
    local useClassColors = Settings.smartOrderingClassColors and isSorted and unit
    if useClassColors then
        if HP._testMode and fd._isTestFrame then
            ApplyTestModeClassColors(bars, amounts, my1, my2, ot1, ot2, opaMul, dimFactor, fd._testFrameIndex)
        else
            ApplyRealModeClassColors(bars, amounts, unit, opaMul, dimFactor)
        end
    end

    -- Standard 5-bar mode (when not using class colors)
    if not useClassColors then
        for idx = 1, 5 do
            local cData = colors[activePal[idx]]
            if cData then
                local aDim
                if isSorted then
                    aDim = (idx == 3 or idx == 4 or idx == 5) and dimFactor or 1.0
                else
                    aDim = (idx == 2 or idx == 4 or idx == 5) and dimFactor or 1.0
                end
                local r, g, b, a = cData[1], cData[2], cData[3], cData[4] * opaMul * aDim
                if a == 0 then
                    amounts[idx] = 0
                elseif useGradient then
                    local r2, g2, b2 = cData[5], cData[6], cData[7]
                    ApplyGradient(bars[idx], "VERTICAL",
                        CachedColor(r2, g2, b2, a), CachedColor(r, g, b, a))
                else
                    if bars[idx] then bars[idx]:SetVertexColor(r, g, b, a) end
                end
            end
        end
    end

    my1, my2, ot1, ot2, ot3 = amounts[1], amounts[2], amounts[3], amounts[4], amounts[5]

    local barW = fd._hbWidth or hb:GetWidth()
    local healthPx = (cap > 0 and barW > 0) and (hp / cap) * barW or 0
    local rawTotal
    local total1, total2

    if isSorted then
        rawTotal = my1 + my2 + ot1 + ot2 + ot3
        total1 = my1 + my2
        total2 = ot1 + ot2 + ot3
        local totalAll = rawTotal
        if overflowCap then
            totalAll = mathmin(totalAll, cap * overflowCap - hp)
        end
        totalAll = mathmax(totalAll, 0)

        local remain = totalAll
        my1 = mathmin(my1, remain); remain = remain - my1
        my2 = mathmin(my2, remain); remain = remain - my2
        ot1 = mathmin(ot1, remain); remain = remain - ot1
        ot2 = mathmin(ot2, remain); remain = remain - ot2
        ot3 = remain

        local curPx = healthPx
        curPx = PositionBarAbs(hb, bars[1], my1, curPx, cap, barW)
        curPx = PositionBarAbs(hb, bars[2], my2, curPx, cap, barW)
        curPx = PositionBarAbs(hb, bars[3], ot1, curPx, cap, barW)
        curPx = PositionBarAbs(hb, bars[4], ot2, curPx, cap, barW)
        if bars[5] then PositionBarAbs(hb, bars[5], ot3, curPx, cap, barW) end
    else
        if Settings.overlayMode then
            total1 = mathmax(my1, ot1)
            total2 = mathmax(my2, ot2)
        else
            total1 = my1 + ot1
            total2 = my2 + ot2
        end

        rawTotal = total1 + total2
        local totalAll = rawTotal
        if overflowCap then
            totalAll = mathmin(totalAll, cap * overflowCap - hp)
        end
        totalAll = mathmax(totalAll, 0)

        total1 = mathmin(total1, totalAll)
        total2 = totalAll - total1
        my1 = mathmin(my1, total1)
        my2 = mathmin(my2, total2)
        ot1 = total1 - my1
        ot2 = total2 - my2

        local curPx = healthPx
        curPx = PositionBarAbs(hb, bars[1], my1, curPx, cap, barW)
        curPx = PositionBarAbs(hb, bars[3], ot1, curPx, cap, barW)
        curPx = PositionBarAbs(hb, bars[2], my2, curPx, cap, barW)
        PositionBarAbs(hb, bars[4], ot2, curPx, cap, barW)
        if bars[5] then bars[5]:Hide() end
    end

    local guid = unit and UnitGUID(unit)

    -- Shield glow
    if fd.shieldTex then
        local showShield = Settings.showShieldGlow and guid and shieldGUIDs[guid]
        -- Test mode: Frames 4-7 show shield glow
        if not showShield and Settings.showShieldGlow and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 >= 4) then
            showShield = true
        end
        if showShield then
            if cap > 0 and barW > 0 then
                fd.shieldTex:ClearAllPoints()
                fd.shieldTex:SetPoint("TOPLEFT", hb, "TOPLEFT", healthPx - 7, 0)
                fd.shieldTex:SetHeight(hb:GetHeight())
                fd.shieldTex:Show()
            else
                fd.shieldTex:Hide()
            end
        else
            fd.shieldTex:Hide()
        end
    end

    -- Shield text (abbreviated spell name) â€” Issue 7: configurable offset
    if fd.shieldText then
        if Settings.showShieldText and guid and shieldGUIDs[guid] then
            local abbr = SHIELD_NAMES[shieldGUIDs[guid]]
            if abbr then
                fd.shieldText:SetText("|cff88bbff" .. abbr .. "|r")
                fd.shieldText:ClearAllPoints()
                if fd.usesGradient then
                    -- Compact/raid frame: LEFT anchor
                    fd.shieldText:SetPoint("LEFT", hb, "LEFT",
                        2 + (Settings.shieldTextOffsetX or 0),
                        Settings.shieldTextOffsetY or 0)
                else
                    -- Unit frame: BOTTOM anchor
                    fd.shieldText:SetPoint("BOTTOM", hb, "BOTTOM",
                        Settings.shieldTextOffsetX or 0,
                        1 + (Settings.shieldTextOffsetY or 0))
                end
                fd.shieldText:Show()
            else
                fd.shieldText:Hide()
            end
        else
            fd.shieldText:Hide()
        end
    end

    -- Absorb bar â€” proportional to actual shield amount when available
    -- Drawn LEFT from the health fill edge (overlaying the health bar)
    if fd.absorbBar then
        local showAbsorb = Settings.showAbsorbBar and guid and shieldGUIDs[guid]
        -- Test mode: Frames 4-7 show absorb bar
        if not showAbsorb and Settings.showAbsorbBar and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 >= 4) then
            showAbsorb = true
        end
        if showAbsorb and cap > 0 and barW > 0 then
            local absorbAmt = shieldAmounts[guid]
            -- Test mode: simulate a shield worth 25% of max health
            if not absorbAmt and HP._testMode and fd._isTestFrame then
                absorbAmt = cap * 0.25
            end
            local absorbWidth
            if absorbAmt and absorbAmt > 0 then
                absorbWidth = mathmax((absorbAmt / cap) * barW, 2)
            else
                -- Fallback: small indicator when tooltip scanning didn't find a value
                absorbWidth = mathmax(barW * 0.05, 4)
            end
            -- Clamp: don't extend beyond the health fill or past the left edge
            absorbWidth = mathmin(absorbWidth, healthPx)
            if absorbWidth >= 1 then
                local absorbStart = healthPx - absorbWidth
                local c = colors.absorbBar
                if c then
                    fd.absorbBar:SetVertexColor(c[1], c[2], c[3], c[4] * opaMul)
                    fd.absorbBar:ClearAllPoints()
                    fd.absorbBar:SetPoint("TOPLEFT", hb, "TOPLEFT", absorbStart, 0)
                    fd.absorbBar:SetPoint("BOTTOMLEFT", hb, "BOTTOMLEFT", absorbStart, 0)
                    fd.absorbBar:SetWidth(absorbWidth)
                    fd.absorbBar:Show()
                end
            else
                fd.absorbBar:Hide()
            end
        else
            fd.absorbBar:Hide()
        end
    end

    -- Overheal amount bar
    if fd.overhealBar then
        local showOverheal = Settings.showOverhealBar
        -- Test mode: Frame 8 shows overheal bar
        if not showOverheal and Settings.showOverhealBar and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 0) then
            showOverheal = true
        end
        if showOverheal and cap > 0 and barW > 0 then
            local rawOverheal = mathmax(hp + rawTotal - cap, 0)
            -- Test mode: fake overheal for frame 8
            if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 0) then
                rawOverheal = cap * 0.12
            end
            if rawOverheal > 0 then
                local maxOHWidth = barW * 0.15
                local ohWidth = mathmin((rawOverheal / cap) * barW, maxOHWidth)
                local cData = colors.overhealBar
                if cData then
                    if Settings.overhealGradient then
                        local ovhPct = mathmin(rawOverheal / cap, 1)
                        local grad = HP.OVERHEAL_GRAD
                        local gr, gg, gb
                        if ovhPct < 0.3 then
                            local t = ovhPct / 0.3
                            gr = grad[1][1] + t * (grad[2][1] - grad[1][1])
                            gg = grad[1][2] + t * (grad[2][2] - grad[1][2])
                            gb = grad[1][3] + t * (grad[2][3] - grad[1][3])
                        elseif ovhPct < 0.7 then
                            local t = (ovhPct - 0.3) / 0.4
                            gr = grad[2][1] + t * (grad[3][1] - grad[2][1])
                            gg = grad[2][2] + t * (grad[3][2] - grad[2][2])
                            gb = grad[2][3] + t * (grad[3][3] - grad[2][3])
                        else
                            gr, gg, gb = grad[3][1], grad[3][2], grad[3][3]
                        end
                        fd.overhealBar:SetVertexColor(gr, gg, gb, (cData[4] or 0.6) * opaMul)
                    elseif useGradient and cData[5] then
                        ApplyGradient(fd.overhealBar, "VERTICAL",
                            CachedColor(cData[5], cData[6], cData[7], cData[4] * opaMul),
                            CachedColor(cData[1], cData[2], cData[3], cData[4] * opaMul))
                    else
                        fd.overhealBar:SetVertexColor(cData[1], cData[2], cData[3], cData[4] * opaMul)
                    end
                    fd.overhealBar:ClearAllPoints()
                    fd.overhealBar:SetPoint("TOPLEFT", hb, "TOPLEFT", barW, 0)
                    fd.overhealBar:SetPoint("BOTTOMLEFT", hb, "BOTTOMLEFT", barW, 0)
                    fd.overhealBar:SetWidth(mathmax(ohWidth, 1))
                    fd.overhealBar:Show()
                end
            else
                fd.overhealBar:Hide()
            end
        else
            fd.overhealBar:Hide()
        end
    end

    -- Health trajectory marker
    if fd.trajectoryMarker then
        local showTrajectory = Settings.healthTrajectory and cap > 0 and barW > 0 and guid
        -- Test mode: Frame 8 shows trajectory marker
        if not showTrajectory and Settings.healthTrajectory and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 0) then
            showTrajectory = true
        end
        if showTrajectory then
            local dps = guid and HP.GetDamageRate(guid) or 0
            -- Test mode: fake DPS for frame 8
            if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 0) then
                dps = 50
            end
            if dps > 0 then
                local predictedHP = hp + (rawTotal or 0) - (dps * Settings.trajectoryWindow)
                predictedHP = mathmax(0, mathmin(predictedHP, cap))
                local markerPx = (predictedHP / cap) * barW
                fd.trajectoryMarker:ClearAllPoints()
                fd.trajectoryMarker:SetPoint("TOPLEFT", hb, "TOPLEFT", markerPx, 0)
                fd.trajectoryMarker:SetHeight(hb:GetHeight())
                if predictedHP >= hp then
                    fd.trajectoryMarker:SetColorTexture(0.2, 1, 0.2, 0.7)
                else
                    fd.trajectoryMarker:SetColorTexture(1, 0.2, 0.2, 0.7)
                end
                fd.trajectoryMarker:Show()
            else
                fd.trajectoryMarker:Hide()
            end
        else
            fd.trajectoryMarker:Hide()
        end
    end

    -- Issue 4 fix: return rawTotal (unclamped) as 3rd value for deficit calc
    return total1, total2, rawTotal
end

---------------------------------------------------------------------------
-- Safe wrapper: pcall around RenderPrediction to prevent one bad frame
-- from bricking the entire addon.  Logs each distinct error once per
-- session so the user can report it without chat spam.
---------------------------------------------------------------------------
local renderErrors = {}

local function SafeRender(frame, unit, overflowCap, useGradient, pal, palOH)
    local ok, r1, r2, r3 = pcall(RenderPrediction, frame, unit, overflowCap, useGradient, pal, palOH)
    if ok then
        return r1, r2, r3
    end
    -- r1 is the error message on failure
    local msg = tostring(r1)
    if not renderErrors[msg] then
        renderErrors[msg] = true
        print("|cff33ccffHealPredict:|r |cffff4444Render error:|r " .. msg)
    end
    -- Hide all bars on this frame so stale visuals don't linger
    local fd = frameData[frame]
    if fd and fd.bars then
        for idx = 1, 5 do if fd.bars[idx] then fd.bars[idx]:Hide() end end
    end
    return 0, 0, 0
end

---------------------------------------------------------------------------
-- Suppress Blizzard's built-in heal prediction on compact frames
---------------------------------------------------------------------------
local BLIZZ_PREDICT_KEYS = {
    "myHealPrediction", "otherHealPrediction", "totalAbsorb",
    "totalAbsorbOverlay", "myHealAbsorb", "myHealAbsorbLeftShadow",
    "myHealAbsorbRightShadow", "overAbsorbGlow", "overHealAbsorbGlow",
}

local function HideBlizzardPrediction(frame)
    for _, key in ipairs(BLIZZ_PREDICT_KEYS) do
        local el = frame[key]
        if el and el.IsShown and el:IsShown() then
            el:Hide()
            el:SetAlpha(0)
        end
    end
end

---------------------------------------------------------------------------
-- Indicator Effect System
-- Supports: 1=Static, 2=Glow (pulsing alpha), 3=Spinning (orbiting dots), 4=Slashes
---------------------------------------------------------------------------
HP._spinningFrames = {}
HP._hasSpinningLines = false

local function PerimeterPos(t, W, H)
    local perim = 2 * (W + H)
    t = t % perim
    if t < W then return t, 0
    elseif t < W + H then return W, t - W
    elseif t < 2 * W + H then return W - (t - W - H), H
    else return 0, H - (t - 2 * W - H) end
end

local function GetBorderThickness()
    return Settings.borderThickness or 2
end

local function CreateIndicatorEffect(parent, sizeRef, layer, sublevel, useColorTex, frameRef)
    local eff = { style = 0, useColorTex = useColorTex, parent = parent, _frameRef = frameRef or parent, _sizeRef = sizeRef }
    if useColorTex then
        local tex = parent:CreateTexture(nil, layer, nil, sublevel)
        tex:SetColorTexture(1, 1, 1)
        tex:SetAllPoints(sizeRef)
        tex:Hide()
        eff.border = tex
    else
        local bf = CreateFrame("Frame", nil, parent)
        bf:SetAllPoints(sizeRef)
        bf:Hide()
        local T = GetBorderThickness()
        local edges = {}
        local top = bf:CreateTexture(nil, "OVERLAY")
        top:SetColorTexture(1, 1, 1); top:SetHeight(T)
        top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
        edges[1] = top
        local bot = bf:CreateTexture(nil, "OVERLAY")
        bot:SetColorTexture(1, 1, 1); bot:SetHeight(T)
        bot:SetPoint("BOTTOMLEFT"); bot:SetPoint("BOTTOMRIGHT")
        edges[2] = bot
        local lft = bf:CreateTexture(nil, "OVERLAY")
        lft:SetColorTexture(1, 1, 1); lft:SetWidth(T)
        lft:SetPoint("TOPLEFT"); lft:SetPoint("BOTTOMLEFT")
        edges[3] = lft
        local rgt = bf:CreateTexture(nil, "OVERLAY")
        rgt:SetColorTexture(1, 1, 1); rgt:SetWidth(T)
        rgt:SetPoint("TOPRIGHT"); rgt:SetPoint("BOTTOMRIGHT")
        edges[4] = rgt
        eff.border = bf
        eff.edges = edges
    end
    return eff
end

local function EnsureEffectStyle(eff, targetStyle)
    if targetStyle == 2 and not eff.glowAG then
        local ag = eff.border:CreateAnimationGroup()
        local anim = ag:CreateAnimation("Alpha")
        anim:SetFromAlpha(0.3)
        anim:SetToAlpha(1.0)
        anim:SetDuration(0.8)
        anim:SetSmoothing("IN_OUT")
        ag:SetLooping("BOUNCE")
        eff.glowAG = ag
    end
    if targetStyle == 3 and not eff.lines then
        eff.lines = {}
        for i = 1, 16 do
            local dot = eff.parent:CreateTexture(nil, "OVERLAY", nil, 7)
            dot:SetColorTexture(1, 1, 1)
            dot:SetSize(3, 3)
            dot:Hide()
            eff.lines[i] = dot
        end
        eff._spinOffset = 0
        eff._lastSpin = nil
    end
    if targetStyle == 4 and not eff.dashes then
        local clipFrame = CreateFrame("Frame", nil, eff.parent)
        clipFrame:SetAllPoints(eff._sizeRef or eff.parent)
        clipFrame:SetClipsChildren(true)
        clipFrame:Show()
        eff._dashClip = clipFrame
        eff.dashes = {}
        for i = 1, 5 do
            local line = clipFrame:CreateLine(nil, "OVERLAY", nil, 7)
            line:SetThickness(2)
            line:Hide()
            eff.dashes[i] = line
        end
        eff._dashOffset = 0
    end
end

local function ShowIndicator(fd, key, style, colorData)
    if not fd.effects then return end
    local eff = fd.effects[key]
    if not eff or not colorData then return end
    local r, g, b, a = colorData[1], colorData[2], colorData[3], colorData[4] or 1

    local function HideDashes()
        if eff.dashes then
            for i = 1, #eff.dashes do eff.dashes[i]:Hide() end
            if eff._dashClip then eff._dashClip:Hide() end
        end
    end
    local function HideSpinning()
        if eff.lines then
            for i = 1, #eff.lines do eff.lines[i]:Hide() end
        end
    end
    local function HideRings()
        if eff.rings then
            for i = 1, #eff.rings do eff.rings[i]:Hide() end
        end
    end
    local function HideWave()
        if eff.waveDots then
            for i = 1, #eff.waveDots do eff.waveDots[i]:Hide() end
        end
    end

    if eff.edges then
        local T = GetBorderThickness()
        eff.edges[1]:SetHeight(T)
        eff.edges[2]:SetHeight(T)
        eff.edges[3]:SetWidth(T)
        eff.edges[4]:SetWidth(T)
    end

    if style == 1 then
        if eff.edges then
            for _, e in ipairs(eff.edges) do e:SetColorTexture(r, g, b) end
            eff.border:SetAlpha(a)
        else
            eff.border:SetColorTexture(r, g, b)
            eff.border:SetAlpha(a)
        end
        eff.border:Show()
        if eff.glowAG then eff.glowAG:Stop() end
        HideSpinning(); HideDashes(); HideRings(); HideWave()
        HP._spinningFrames[eff] = nil
    elseif style == 2 then
        EnsureEffectStyle(eff, 2)
        if eff.edges then
            for _, e in ipairs(eff.edges) do e:SetColorTexture(r, g, b) end
        else
            eff.border:SetColorTexture(r, g, b)
            eff.border:SetAlpha(a)
        end
        eff.border:Show()
        if not eff.glowAG:IsPlaying() then eff.glowAG:Play() end
        HideSpinning(); HideDashes(); HideRings(); HideWave()
        HP._spinningFrames[eff] = nil
    elseif style == 3 then
        EnsureEffectStyle(eff, 3)
        eff.border:Hide()
        if eff.glowAG then eff.glowAG:Stop() end
        local dotSize = GetBorderThickness() + 1
        for i = 1, #eff.lines do
            eff.lines[i]:SetSize(dotSize, dotSize)
            eff.lines[i]:SetColorTexture(r, g, b)
            eff.lines[i]:SetAlpha(a)
            eff.lines[i]:Show()
        end
        HideDashes(); HideRings(); HideWave()
        if not HP._spinningFrames[eff] then
            eff._lastSpin = nil
        end
        HP._spinningFrames[eff] = { frame = eff._frameRef or eff.parent }
        HP._hasSpinningLines = true
    elseif style == 4 then
        EnsureEffectStyle(eff, 4)
        eff.border:Hide()
        if eff.glowAG then eff.glowAG:Stop() end
        HideSpinning(); HideRings(); HideWave()
        if eff._dashClip then eff._dashClip:Show() end
        local lineThick = GetBorderThickness()
        for i = 1, #eff.dashes do
            eff.dashes[i]:SetThickness(lineThick)
            eff.dashes[i]:SetColorTexture(r, g, b, a)
            eff.dashes[i]:Show()
        end
        if not HP._spinningFrames[eff] then
            eff._lastSpin = nil
        end
        HP._spinningFrames[eff] = { frame = eff._frameRef or eff.parent }
        HP._hasSpinningLines = true
    elseif style == 5 then
        -- Pulse Ring: expanding circles
        if not eff.rings then
            eff.rings = {}
            for i = 1, 3 do
                local ring = eff.parent:CreateTexture(nil, "OVERLAY", nil, 7)
                ring:SetColorTexture(1, 1, 1)
                ring:SetBlendMode("ADD")
                ring:Hide()
                eff.rings[i] = ring
            end
            eff._ringOffset = 0
        end
        eff.border:Hide()
        if eff.glowAG then eff.glowAG:Stop() end
        HideSpinning(); HideDashes(); HideWave()
        for i = 1, #eff.rings do
            eff.rings[i]:SetColorTexture(r, g, b)
            eff.rings[i]:SetAlpha(a * (1 - (i-1)/3))
            eff.rings[i]:Show()
        end
        eff._ringColor = {r, g, b, a}
        if not HP._spinningFrames[eff] then
            eff._lastSpin = nil
        end
        HP._spinningFrames[eff] = { frame = eff._frameRef or eff.parent, style = 5 }
        HP._hasSpinningLines = true
    elseif style == 6 then
        -- Strobe: rapid flash
        eff.border:Show()
        if eff.edges then
            for _, e in ipairs(eff.edges) do e:SetColorTexture(r, g, b) end
        else
            eff.border:SetColorTexture(r, g, b)
        end
        eff.border:SetAlpha(a)
        if eff.glowAG then eff.glowAG:Stop() end
        HideSpinning(); HideDashes(); HideRings(); HideWave()
        eff._strobeState = { on = true, lastToggle = 0 }
        eff._strobeColor = {r, g, b, a}
        if not HP._spinningFrames[eff] then
            eff._lastSpin = nil
        end
        HP._spinningFrames[eff] = { frame = eff._frameRef or eff.parent, style = 6 }
        HP._hasSpinningLines = true
    elseif style == 7 then
        -- Wave: traveling sine dots
        if not eff.waveDots then
            eff.waveDots = {}
            for i = 1, 12 do
                local dot = eff.parent:CreateTexture(nil, "OVERLAY", nil, 7)
                dot:SetColorTexture(1, 1, 1)
                dot:SetSize(4, 4)
                dot:Hide()
                eff.waveDots[i] = dot
            end
            eff._waveOffset = 0
        end
        eff.border:Hide()
        if eff.glowAG then eff.glowAG:Stop() end
        HideSpinning(); HideDashes(); HideRings()
        for i = 1, #eff.waveDots do
            eff.waveDots[i]:SetColorTexture(r, g, b)
            eff.waveDots[i]:SetAlpha(a)
            eff.waveDots[i]:Show()
        end
        if not HP._spinningFrames[eff] then
            eff._lastSpin = nil
        end
        HP._spinningFrames[eff] = { frame = eff._frameRef or eff.parent, style = 7 }
        HP._hasSpinningLines = true
    end
end

local function HideIndicator(fd, key)
    if not fd.effects then return end
    local eff = fd.effects[key]
    if not eff then return end
    eff.border:Hide()
    if eff.glowAG then eff.glowAG:Stop() end
    if eff.lines then
        for i = 1, #eff.lines do eff.lines[i]:Hide() end
    end
    if eff.dashes then
        for i = 1, #eff.dashes do eff.dashes[i]:Hide() end
        if eff._dashClip then eff._dashClip:Hide() end
    end
    if eff.rings then
        for i = 1, #eff.rings do eff.rings[i]:Hide() end
    end
    if eff.waveDots then
        for i = 1, #eff.waveDots do eff.waveDots[i]:Hide() end
    end
    HP._spinningFrames[eff] = nil
    if not next(HP._spinningFrames) then HP._hasSpinningLines = false end
end

HP.CreateIndicatorEffect = CreateIndicatorEffect

---------------------------------------------------------------------------
-- Public update entrypoints
---------------------------------------------------------------------------
local function HideAllCompactExtras(fd)
    if fd.bars then
        for idx = 1, 5 do if fd.bars[idx] then fd.bars[idx]:Hide() end end
    end
    if fd.shieldTex       then fd.shieldTex:Hide() end
    if fd.absorbBar       then fd.absorbBar:Hide() end
    if fd.overhealBar     then fd.overhealBar:Hide() end
    if fd.deficitText     then fd.deficitText:Hide() end
    if fd.shieldText      then fd.shieldText:Hide() end
    if fd.healerCountText then fd.healerCountText:Hide() end
    if fd.trajectoryMarker then fd.trajectoryMarker:Hide() end
    if fd.aoeBorder       then fd.aoeBorder:Hide() end
    if fd.snipeFlash      then fd.snipeFlash:Hide() end
    if fd.effects then
        for key in pairs(fd.effects) do HideIndicator(fd, key) end
    end
    if fd.resText         then fd.resText:Hide() end
    if fd.healReducText   then fd.healReducText:Hide() end
    if fd.cdText          then fd.cdText:Hide() end
    if fd.defensiveContainer then fd.defensiveContainer:Hide() end
    if fd.effects and fd.effects.defensive then HP.HideIndicator(fd, "defensive") end
    if fd.effects and fd.effects.charmed then HP.HideIndicator(fd, "charmed") end
    if fd.hotDots then for di = 1, 5 do if fd.hotDots[di] then pcall(function() fd.hotDots[di]:Hide() end) end end end
    if fd.hotDotsOther then for di = 1, 5 do if fd.hotDotsOther[di] then pcall(function() fd.hotDotsOther[di]:Hide() end) end end end
    if fd.manaWarnText    then fd.manaWarnText:Hide() end
end

function HP.UpdateCompact(frame)
    local fd = HP.frameData[frame]
    local overflow
    if fd and fd._isParty then
        overflow = 1.0 + (Settings.usePartyOverflow and Settings.partyOverflow or 0)
    else
        overflow = 1.0 + (Settings.useRaidOverflow and Settings.raidOverflow or 0)
    end
    if not fd then return end

    -- Suppress Blizzard's built-in heal prediction every update
    HideBlizzardPrediction(frame)

    -- Visibility gate: respect showOnParty for compact frames
    if not Settings.showOnParty then
        HideAllCompactExtras(fd)
        return
    end
    local grad = fd.usesGradient
    local pal, palOH
    if Settings.useUnitColorsOnly then
        pal = Settings.smartOrdering and UNIT_PAL_SORTED or UNIT_PAL
        palOH = Settings.smartOrdering and UNIT_OHPL_SORTED or UNIT_OHPL
    else
        pal = Settings.smartOrdering and COMPACT_PAL_SORTED or COMPACT_PAL
        palOH = Settings.smartOrdering and COMPACT_OHPL_SORTED or COMPACT_OHPL
    end
    local t1, t2, rawT = SafeRender(frame, frame.displayedUnit, overflow, grad, pal, palOH)

    -- Issue 4 fix: use rawTotal (unclamped) for deficit so it reflects all incoming heals
    if fd.deficitText then
        local showDeficit = Settings.showHealthDeficit
        -- Test mode: Frame 7 shows health deficit
        if not showDeficit and Settings.showHealthDeficit and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 7) then
            showDeficit = true
        end
        if showDeficit then
            local hb = fd.hb
            if hb then
                local _, cap = hb:GetMinMaxValues()
                local hp = hb:GetValue() or 0
                local deficit = (cap and cap > 0) and (cap - (hp + (rawT or 0))) or 0
                -- Test mode: fake deficit for frame 7
                if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 7) then
                    deficit = 5234
                end
                if deficit > 0 then
                    fd.deficitText:SetFormattedText("|cffff4444-%d|r", mathfloor(deficit))
                    fd.deficitText:Show()
                else
                    fd.deficitText:Hide()
                end
            end
        else
            fd.deficitText:Hide()
        end
    end

    -- Healer count per target
    local unit = frame.displayedUnit
    local guid = unit and UnitGUID(unit)
    if fd.healerCountText then
        if Settings.healerCount then
            local hCount = guid and Engine:GetActiveCasterCount(guid) or 0
            if HP._testMode and fd._isTestFrame then 
                -- Test mode: frames 1-3 = 2 healers, frame 7 = 3 healers, others = 1
                local idx = fd._testFrameIndex or 1
                if idx <= 3 then
                    hCount = 2
                elseif idx == 7 then
                    hCount = 3
                else
                    hCount = 1
                end
            end
            if hCount > 0 then
                fd.healerCountText:SetText(hCount)
                fd.healerCountText:Show()
            else
                fd.healerCountText:Hide()
            end
        else
            fd.healerCountText:Hide()
        end
    end

    -- AoE advisor border
    if fd.aoeBorder then
        if Settings.aoeAdvisor then
            local showAoE = (guid and HP.aoeTargetGUID == guid)
            if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 2) then
                showAoE = true
            end
            if showAoE then
                local ac = Settings.colors.aoeBorder
                if ac and fd._aoeEdges then
                    for _, e in ipairs(fd._aoeEdges) do e:SetColorTexture(ac[1], ac[2], ac[3]) end
                    fd.aoeBorder:SetAlpha(ac[4] or 0.8)
                end
                fd.aoeBorder:Show()
            else
                fd.aoeBorder:Hide()
            end
        else
            fd.aoeBorder:Hide()
        end
    end

    -- HoT expiry warning
    if fd.hotExpiryBorder then
        if Settings.hotExpiryWarning and guid then
            local showExpiry = false
            if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 3) then
                showExpiry = true
            elseif Engine.ticking then
                local playerGUID = UnitGUID("player")
                local now = GetTime()
                local thresh = Settings.hotExpiryThreshold
                if playerGUID and Engine.ticking[playerGUID] then
                    for _, rec in pairs(Engine.ticking[playerGUID]) do
                        if rec.targets and rec.targets[guid] then
                            local endTime = rec.targets[guid][3]
                            if endTime then
                                local remain = endTime - now
                                if remain > 0 and remain < thresh then
                                    showExpiry = true
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if showExpiry then
                ShowIndicator(fd, "hotExpiry", Settings.hotExpiryStyle or 1, Settings.colors.hotExpiry)
            else
                HideIndicator(fd, "hotExpiry")
            end
        else
            HideIndicator(fd, "hotExpiry")
        end
    end

    -- Dispel highlight
    if fd.dispelOverlay then
        if Settings.dispelHighlight and guid and dispelGUIDs[guid] then
            local dType = dispelGUIDs[guid]
            local dc = Settings.colors["dispel" .. dType]
            if dc then
                ShowIndicator(fd, "dispel", Settings.dispelStyle or 1, dc)
                if Settings.soundDispel and not fd._dispelSounded then
                    local now = GetTime()
                    if now - _lastDispelSound >= SOUND_DEBOUNCE then
                        _lastDispelSound = now
                        PlayAlertSound(Settings.dispelSoundChoice)
                    end
                    fd._dispelSounded = true
                end
            else
                HideIndicator(fd, "dispel")
            end
        elseif Settings.dispelHighlight and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 4) then
            local dc = Settings.colors.dispelMagic
            if dc then
                ShowIndicator(fd, "dispel", Settings.dispelStyle or 1, dc)
            end
        else
            HideIndicator(fd, "dispel")
            fd._dispelSounded = nil
        end
    end

    -- Res tracker
    if fd.resText then
        if Settings.resTracker then
            local showRes = (guid and resTargets[guid])
            if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 5) then
                showRes = true
            end
            if showRes then
                fd.resText:Show()
            else
                fd.resText:Hide()
            end
        else
            fd.resText:Hide()
        end
    end

    -- Cluster detection
    if fd.clusterBorder then
        if Settings.clusterDetection then
            local showCluster = (guid and HP.clusterGUIDs[guid])
            if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) == 2 or (fd._testFrameIndex or 0) == 3) then
                showCluster = true
            end
            if showCluster then
                ShowIndicator(fd, "cluster", Settings.clusterStyle or 1, Settings.colors.clusterBorder)
            else
                HideIndicator(fd, "cluster")
            end
        else
            HideIndicator(fd, "cluster")
        end
    end

    -- Heal reduction indicator
    if fd.healReducGlow then
        if Settings.healReductionGlow and guid then
            local mod = Engine:GetHealModifier(guid) or 1.0
            local showReduc = mod < 1.0
            if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 5) then
                showReduc = true
                mod = 0.0
            end
            if showReduc then
                local pct = mathfloor((1 - mod) * 100)
                local minPct = Settings.healReductionThreshold or 0
                if pct >= minPct then
                    if Settings.healReductionText then
                        -- Update position before showing
                        if fd._applyHealReducTextPos then fd._applyHealReducTextPos() end
                        fd.healReducText:SetFormattedText("-%d%%", pct)
                        fd.healReducText:Show()
                    else
                        fd.healReducText:Hide()
                    end
                    local hrStyle = Settings.healReducStyle or 1
                    if hrStyle == 8 then
                        HideIndicator(fd, "healReduc")
                    else
                        ShowIndicator(fd, "healReduc", hrStyle, Settings.colors.healReduction)
                    end
                else
                    HideIndicator(fd, "healReduc")
                    if fd.healReducText then fd.healReducText:Hide() end
                end
            else
                HideIndicator(fd, "healReduc")
                if fd.healReducText then fd.healReducText:Hide() end
            end
        else
            HideIndicator(fd, "healReduc")
            if fd.healReducText then fd.healReducText:Hide() end
        end
    end

    -- CD tracker display
    if fd.cdText then
        if Settings.cdTracker and guid and cdGUIDs[guid] then
            fd.cdText:SetText(cdGUIDs[guid])
            fd.cdText:Show()
        elseif Settings.cdTracker and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 1) then
            fd.cdText:SetText("PSUP")
            fd.cdText:Show()
        else
            fd.cdText:Hide()
        end
    end

    -- HoT tracker dots (your own HoTs) - 5 individual HoT types
    -- HoT tracker (own HoTs) - supports both dot color mode and icon mode
    if fd.hotDots then
        local isIconMode = (Settings.hotDotDisplayMode or 1) == 2
        local dotColors = Settings.colors
        local hotColorKeys = { "hotDotRenew", "hotDotRejuv", "hotDotRegrowth", "hotDotLifebloom", "hotDotEarthShield" }
        
        if Settings.hotTrackerDots and guid and HP.hotDotGUIDs[guid] then
            local active = HP.hotDotGUIDs[guid]
            for di = 1, 5 do
                if fd.hotDots[di] then
                    if active[di] then
                        if not isIconMode then
                            -- Dot mode: Set color
                            local c = dotColors[hotColorKeys[di]]
                            if c then 
                                pcall(function() fd.hotDots[di]:SetColorTexture(c[1], c[2], c[3]) end)
                            end
                        end
                        pcall(function() fd.hotDots[di]:Show() end)
                    else
                        pcall(function() fd.hotDots[di]:Hide() end)
                    end
                end
            end
            -- Update cooldown sweeps for icon mode
            if isIconMode then
                UpdateHoTCooldown(fd, guid, false)
            end
        elseif Settings.hotTrackerDots and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 < 4) then
            -- Test mode: show Renew and Rejuv
            local testDurations = { 15, 12 } -- Renew 15s, Rejuv 12s
            for di = 1, 2 do
                if fd.hotDots[di] then
                    if not isIconMode then
                        local c = dotColors[hotColorKeys[di]]
                        if c then
                            pcall(function() fd.hotDots[di]:SetColorTexture(c[1], c[2], c[3]) end)
                        end
                    end
                    pcall(function() fd.hotDots[di]:Show() end)
                    -- Simulate cooldown sweep in icon mode (set once, loops naturally)
                    if isIconMode and fd.hotDotCooldowns and fd.hotDotCooldowns[di] then
                        if Settings.hotDotShowCooldown ~= false then
                            if not fd._testCDStart then
                                fd._testCDStart = GetTime()
                            end
                            local dur = testDurations[di]
                            local elapsed = GetTime() - fd._testCDStart
                            local startTime = fd._testCDStart + (mathfloor(elapsed / dur) * dur)
                            fd.hotDotCooldowns[di]:SetCooldown(startTime, dur)
                            fd.hotDotCooldowns[di]:Show()
                        else
                            fd.hotDotCooldowns[di]:Hide()
                        end
                    end
                end
            end
            for di = 3, 5 do
                if fd.hotDots[di] then
                    pcall(function() fd.hotDots[di]:Hide() end)
                end
                if fd.hotDotCooldowns and fd.hotDotCooldowns[di] then
                    fd.hotDotCooldowns[di]:Hide()
                end
            end
        else
            for di = 1, 5 do 
                if fd.hotDots[di] then
                    pcall(function() fd.hotDots[di]:Hide() end)
                end
            end
        end
    end

    -- HoT tracker (other healers' HoTs) - 5 individual HoT types
    if fd.hotDotsOther then
        local isIconMode = (Settings.hotDotDisplayMode or 1) == 2
        local dotColors = Settings.colors
        local hotColorKeysOther = { "hotDotRenewOther", "hotDotRejuvOther", "hotDotRegrowthOther", "hotDotLifebloomOther", "hotDotEarthShieldOther" }
        
        if Settings.hotTrackerDotsOthers and guid and HP.hotDotOtherGUIDs[guid] then
            local active = HP.hotDotOtherGUIDs[guid]
            for di = 1, 5 do
                if fd.hotDotsOther[di] then
                    if active[di] then
                        if not isIconMode then
                            -- Dot mode: Set color
                            local c = dotColors[hotColorKeysOther[di]]
                            if c then 
                                pcall(function() fd.hotDotsOther[di]:SetColorTexture(c[1], c[2], c[3]) end)
                            end
                        end
                        pcall(function() fd.hotDotsOther[di]:Show() end)
                    else
                        pcall(function() fd.hotDotsOther[di]:Hide() end)
                    end
                end
            end
            -- Update cooldown sweeps for icon mode
            if isIconMode then
                UpdateHoTCooldown(fd, guid, true)
            end
        else
            for di = 1, 5 do 
                if fd.hotDotsOther[di] then
                    pcall(function() fd.hotDotsOther[di]:Hide() end)
                end
            end
        end
    end

    -- Low mana warning â€” healer class cache
    if not fd._classChecked and frame.displayedUnit then
        local _, cls = UnitClass(frame.displayedUnit)
        fd._isHealer = cls and HEALER_CLASSES[cls] or false
        fd._classChecked = true
    end

    if fd.manaWarnText then
        if not Settings.lowManaWarning then
            fd.manaWarnText:Hide()
        elseif HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 1) then
            fd.manaWarnText:SetText("|cff6699ff18%|r")
            fd.manaWarnText:Show()
        end
        -- Visibility for live play is handled by the 2s mana poll (avoids flicker)
    end

    -- Defensive cooldown display (icon/text + optional border effect)
    local displayMode = Settings.defensiveDisplayMode or 3
    local borderStyle = Settings.defensiveStyle or 3 -- 1=No effect, 2=Static, 3=Glow, 4=Spinning, 5=Slashes
    
    -- Border effect (separate from icon/text display)
    -- borderStyle: 1=No effect, 2=Static, 3=Glow, 4=Spinning, 5=Slashes
    if borderStyle > 1 and fd.effects and fd.effects.defensive then
        local hasDef = Settings.showDefensives and guid and defenseGUIDs[guid]
        
        -- Test mode: show defensive border on frame 1
        if not hasDef and Settings.showDefensives and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 1) then
            hasDef = true
        end
        
        if hasDef then
            local def = defenseGUIDs[guid]
            
            -- Test mode: mock defensive data
            if not def and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 1) then
                def = { abbrev = "DVSHD", category = "invuln", spellId = 642 }
            end
            
            if def then
                local c = Settings.colors.defensiveBorder or {1.0, 0.8, 0.0, 1.0}
                local r, g, b = c[1], c[2], c[3]
                if def.category == "invuln" and not Settings.colors.defensiveBorder then
                    r, g, b = 1.0, 0.8, 0.0
                elseif def.category == "strong" and not Settings.colors.defensiveBorder then
                    r, g, b = 0.4, 0.8, 1.0
                elseif def.category == "weak" and not Settings.colors.defensiveBorder then
                    r, g, b = 0.6, 0.8, 0.6
                end
                -- Convert borderStyle to indicator style (1=None, 2=Static, 3=Glow, 4=Spinning, 5=Slashes)
                -- ShowIndicator expects: 1=Static, 2=Glow, 3=Spinning, 4=Slashes
                local indicatorStyle = borderStyle - 1
                HP.ShowIndicator(fd, "defensive", indicatorStyle, {r, g, b})
            else
                HP.HideIndicator(fd, "defensive")
            end
        else
            HP.HideIndicator(fd, "defensive")
        end
    else
        HP.HideIndicator(fd, "defensive")
    end
    
    -- Icon/text container mode
    if fd.defensiveContainer and fd.defensiveIcon and fd.defensiveText then
        local showDef = Settings.showDefensives and guid and defenseGUIDs[guid]
        
        -- Test mode: show defensive on frame 1
        if not showDef and Settings.showDefensives and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 1) then
            showDef = true
        end
        
        if Settings.showDefensives and (guid or (HP._testMode and fd._isTestFrame)) then
            local def = defenseGUIDs[guid]
            
            -- Test mode: mock defensive data
            if not def and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 1) then
                def = { abbrev = "DVSHD", category = "invuln", spellId = 642 }
            end
            
            if def then
                local iconSize = Settings.defensiveIconSize or 16
                local textSize = Settings.defensiveTextSize or 11
                local pos = Settings.defensivePos or 1
                local a = DEFENSE_ANCHORS[pos] or DEFENSE_ANCHORS[1]
                
                -- Apply position anchor to container (with user offsets)
                local dox = Settings.defensiveOffsetX or 0
                local doy = Settings.defensiveOffsetY or 0
                fd.defensiveContainer:ClearAllPoints()
                fd.defensiveContainer:SetPoint(a[1], fd.hb, a[2], a[3] + dox, a[4] + doy)
                
                -- Mode 1: Text only
                if displayMode == 1 then
                    fd.defensiveIcon:Hide()
                    fd.defensiveText:SetText(def.abbrev)
                    fd.defensiveText:SetFont(STANDARD_TEXT_FONT, textSize, "OUTLINE")
                    local r, g, b = 0.3, 1.0, 0.3
                    if def.category == "invuln" then r, g, b = 1.0, 0.8, 0.0
                    elseif def.category == "strong" then r, g, b = 0.4, 0.8, 1.0
                    elseif def.category == "weak" then r, g, b = 0.6, 0.8, 0.6 end
                    fd.defensiveText:SetTextColor(r, g, b)
                    fd.defensiveText:SetPoint("CENTER", fd.defensiveContainer, "CENTER", 0, 0)
                    fd.defensiveText:Show()
                    fd.defensiveContainer:SetWidth(fd.defensiveText:GetStringWidth() + 4)
                    fd.defensiveContainer:Show()
                
                -- Mode 2: Icon only
                elseif displayMode == 2 then
                    if def.spellId then
                        fd.defensiveIcon:SetTexture(GetSpellTexture(def.spellId))
                        fd.defensiveIcon:SetSize(iconSize, iconSize)
                        fd.defensiveIcon:SetPoint("CENTER", fd.defensiveContainer, "CENTER", 0, 0)
                        fd.defensiveIcon:Show()
                    else
                        fd.defensiveIcon:Hide()
                    end
                    fd.defensiveText:Hide()
                    fd.defensiveContainer:SetWidth(iconSize + 4)
                    fd.defensiveContainer:Show()
                
                -- Mode 3: Icon + Text (default)
                elseif displayMode == 3 then
                    if def.spellId then
                        fd.defensiveIcon:SetTexture(GetSpellTexture(def.spellId))
                        fd.defensiveIcon:SetSize(iconSize, iconSize)
                        fd.defensiveIcon:SetPoint("LEFT", fd.defensiveContainer, "LEFT", 0, 0)
                        fd.defensiveIcon:Show()
                    else
                        fd.defensiveIcon:Hide()
                    end
                    fd.defensiveText:SetText(def.abbrev)
                    fd.defensiveText:SetFont(STANDARD_TEXT_FONT, textSize, "OUTLINE")
                    local r, g, b = 0.3, 1.0, 0.3
                    if def.category == "invuln" then r, g, b = 1.0, 0.8, 0.0
                    elseif def.category == "strong" then r, g, b = 0.4, 0.8, 1.0
                    elseif def.category == "weak" then r, g, b = 0.6, 0.8, 0.6 end
                    fd.defensiveText:SetTextColor(r, g, b)
                    if def.spellId then
                        fd.defensiveText:SetPoint("LEFT", fd.defensiveIcon, "RIGHT", 2, 0)
                    else
                        fd.defensiveText:SetPoint("LEFT", fd.defensiveContainer, "LEFT", 0, 0)
                    end
                    fd.defensiveText:Show()
                    local w = fd.defensiveText:GetStringWidth() + 4
                    if def.spellId then w = w + iconSize + 2 end
                    fd.defensiveContainer:SetWidth(w)
                    fd.defensiveContainer:Show()
                end
            else
                fd.defensiveContainer:Hide()
            end
        else
            fd.defensiveContainer:Hide()
        end
    end

    -- Charmed/Mind-controlled indicator
    if fd.effects and fd.effects.charmed then
        if Settings.showCharmed and guid then
            local showCharmed = HP.charmedGUIDs[guid]
            
            -- Test mode: show charmed indicator on frame 2
            if not showCharmed and HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 2) then
                showCharmed = true
            end
            
            if showCharmed then
                local c = Settings.colors.charmed
                HP.ShowIndicator(fd, "charmed", Settings.charmedStyle or 3, c)
            else
                HP.HideIndicator(fd, "charmed")
            end
        else
            HP.HideIndicator(fd, "charmed")
        end
    end
    
    -- Death prediction warning
    if Settings.deathPrediction then
        -- Test mode: show fake death prediction on frame 4
        if HP._testMode and fd._isTestFrame and ((fd._testFrameIndex or 0) % 8 == 4) then
            local text = fd.deathPredText or HP.CreateDeathPredText(frame, fd)
            -- Cycle between 1.0s (red/critical) and 2.5s (yellow/warning)
            local cycle = (GetTime() % 4) 
            local timeToDeath = cycle < 2 and 1.0 or 2.5
            text:SetText(fmt("%.1fs", timeToDeath))
            if timeToDeath < 1.5 then
                text:SetTextColor(1, 0, 0) -- Critical: Red
            else
                text:SetTextColor(1, 1, 0) -- Warning: Yellow
            end
            text:Show()
        elseif guid then
            HP.UpdateDeathPrediction(frame, fd, guid)
        end
    elseif not Settings.deathPrediction then
        if fd.deathPredText then
            fd.deathPredText:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Issue 6: per-frame visibility gate map
---------------------------------------------------------------------------
local FRAME_GATE = {
    player = "showOnPlayer",
    target = "showOnTarget",
    tot    = "showOnToT",
    focus  = "showOnFocus",
    party  = "showOnParty",
    pet    = "showOnPet",
}

local function HideAllUnitExtras(fd)
    if fd.bars then
        for idx = 1, 5 do if fd.bars[idx] then fd.bars[idx]:Hide() end end
    end
    if fd.shieldTex   then fd.shieldTex:Hide() end
    if fd.absorbBar   then fd.absorbBar:Hide() end
    if fd.overhealBar then fd.overhealBar:Hide() end
    if fd.healText    then fd.healText:Hide() end
    if fd.shieldText  then fd.shieldText:Hide() end
end

function HP.UpdateUnit(frame)
    local overflow = 1.0 + (Settings.useUnitOverflow and Settings.unitOverflow or 0)
    local fd = frameData[frame]
    if not fd then return end

    -- Issue 6: check per-frame visibility setting
    local ft = fd.frameType
    local gateKey = ft and FRAME_GATE[ft]
    if gateKey and not Settings[gateKey] then
        HideAllUnitExtras(fd)
        return
    end

    local pal = Settings.smartOrdering and UNIT_PAL_SORTED or UNIT_PAL
    local palOH = Settings.smartOrdering and UNIT_OHPL_SORTED or UNIT_OHPL
    local unit = frame.unit or (fd and fd.expectedUnit)
    local t1, t2 = SafeRender(frame, unit, overflow, false, pal, palOH)

    -- Issue 5 fix: hold-max display â€” don't flicker down when HoT/direct overlap
    if fd.healText then
        if Settings.showHealText then
            local totalHeals = (t1 or 0) + (t2 or 0)
            local now = GetTime()
            if totalHeals >= (fd._healTextMax or 0) then
                fd._healTextMax = totalHeals
                fd._healTextExpire = now + 0.5
            elseif now > (fd._healTextExpire or 0) then
                fd._healTextMax = totalHeals
            end
            local display = mathmax(totalHeals, fd._healTextMax or 0)
            if display > 0 then
                fd.healText:SetText("|cff44ff44+" .. mathfloor(display) .. "|r")
                fd.healText:Show()
            else
                fd._healTextMax = nil
                fd._healTextExpire = nil
                fd.healText:Hide()
            end
        else
            fd._healTextMax = nil
            fd._healTextExpire = nil
            fd.healText:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Texture helpers for frame init
---------------------------------------------------------------------------
local function FindChild(frame, ...)
    if not frame then return nil end
    for i = 1, select("#", ...) do
        if not frame.GetChildren then return nil end
        frame = select(select(i, ...), frame:GetChildren())
        if not frame then return nil end
    end
    return frame
end

local function FindNamedTex(frame, name)
    if not frame then return nil end
    while frame and not frame:GetName() do
        frame = frame:GetParent()
    end
    if not frame then return nil end
    name = name and string.gsub(name, "%$parent", frame:GetName())
    return name and _G[name]
end

local function MakeTex(frame, name, layer, sub)
    if not frame then return nil end
    local existing = FindNamedTex(frame, name)
    if existing then
        if existing.SetTexture then return existing end
        if existing.Fill then return existing.Fill end
    end
    return frame:CreateTexture(name, layer, nil, sub)
end

---------------------------------------------------------------------------
-- Create shield glow texture on a frame
---------------------------------------------------------------------------
local function CreateShieldTex(parent)
    local tex = parent:CreateTexture(nil, "ARTWORK", nil, 2)
    tex:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
    tex:SetBlendMode("ADD")
    tex:SetWidth(16)
    tex:Hide()
    return tex
end

-- Export for Features.lua (test mode)
HP.CreateShieldTex = CreateShieldTex
HP.ApplyTextAnchor = ApplyTextAnchor
HP.ApplyDotAnchors = ApplyDotAnchors
HP.ShowIndicator = ShowIndicator
HP.HideIndicator = HideIndicator
HP.HEALER_COUNT_ANCHORS = HEALER_COUNT_ANCHORS
HP.HEAL_TEXT_ANCHORS = HEAL_TEXT_ANCHORS
HP.HOT_DOT_ANCHORS = HOT_DOT_ANCHORS
HP.HOT_DOT_POS_LABELS = HOT_DOT_POS_LABELS
HP.DEFENSE_ANCHORS = DEFENSE_ANCHORS
HP.DEFENSE_POS_LABELS = DEFENSE_POS_LABELS

---------------------------------------------------------------------------
-- Get the correct bar texture path based on settings
---------------------------------------------------------------------------
local function GetUnitBarTexture()
    return Settings.useRaidTexture
        and "Interface\\RaidFrame\\Raid-Bar-Hp-Fill"
        or  "Interface\\TargetingFrame\\UI-StatusBar"
end

---------------------------------------------------------------------------
-- Refresh bar textures on all unit frames when texture toggle changes
---------------------------------------------------------------------------
function HP.RefreshBarTextures()
    local texPath = GetUnitBarTexture()
    for frame, fd in pairs(frameData) do
        if fd.bars and not fd.usesGradient then
            for idx = 1, 5 do
                local bar = fd.bars[idx]
                if bar and bar.SetTexture then
                    bar:SetTexture(texPath)
                end
            end
            if fd.overhealBar and fd.overhealBar.SetTexture then
                fd.overhealBar:SetTexture(texPath)
            end
            if fd.absorbBar and fd.absorbBar.SetTexture then
                fd.absorbBar:SetTexture(texPath)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Refresh border thickness across all frames
---------------------------------------------------------------------------
function HP.RefreshBorderThickness()
    local T = GetBorderThickness()
    for frame, fd in pairs(frameData) do
        if fd.effects then
            for _, eff in pairs(fd.effects) do
                if eff.edges then
                    eff.edges[1]:SetHeight(T)
                    eff.edges[2]:SetHeight(T)
                    eff.edges[3]:SetWidth(T)
                    eff.edges[4]:SetWidth(T)
                end
            end
        end
        if fd._aoeEdges then
            fd._aoeEdges[1]:SetHeight(T)
            fd._aoeEdges[2]:SetHeight(T)
            fd._aoeEdges[3]:SetWidth(T)
            fd._aoeEdges[4]:SetWidth(T)
        end
    end
end

---------------------------------------------------------------------------
-- Force-apply range alpha to all currently dimmed frames (called from slider)
---------------------------------------------------------------------------
function HP.ApplyRangeAlpha()
    local rangeAlpha = Settings.rangeAlpha
    for frame, fd in pairs(frameData) do
        if fd.usesGradient and frame.displayedUnit then
            local inRange, checkedRange = UnitInRange(frame.displayedUnit)
            local a = (checkedRange and not inRange) and rangeAlpha or 1.0
            fd._rangeAlpha = a
            frame:SetAlpha(a)
        end
    end
end

---------------------------------------------------------------------------
-- Setup compact/raid frames
---------------------------------------------------------------------------
local function SetupCompact(frame)
    if frame:IsForbidden() or frameData[frame] then return end

    -- Hide Blizzard's built-in heal prediction elements
    HideBlizzardPrediction(frame)

    -- Disable Blizzard's range alpha on this frame so it doesn't fight with ours
    if frame.optionTable then
        frame.optionTable.displayRange = false
    end

    -- Tag as party frame if parented under CompactPartyFrame
    local isParty = false
    local parent = frame:GetParent()
    if parent and parent == _G.CompactPartyFrame then
        isParty = true
    end

    local fd = {
        hb = frame.healthBar,
        usesGradient = true,
        bars = {},
        _isParty = isParty,
    }

    -- Parent bar textures to the health bar so they render above its fill
    -- texture. Parenting to `frame` causes them to appear behind the
    -- health bar (child frames render on top of parent textures).
    local barParent = fd.hb or frame

    for idx = 1, 5 do
        local tex = MakeTex(barParent, nil, "BORDER", 5)
        tex:ClearAllPoints()
        tex:SetColorTexture(1, 1, 1)
        tex:Hide()
        fd.bars[idx] = tex
    end

    fd.shieldTex = CreateShieldTex(barParent)

    local absorbBar = barParent:CreateTexture(nil, "BORDER", nil, 6)
    absorbBar:SetColorTexture(1, 1, 1)
    absorbBar:Hide()
    fd.absorbBar = absorbBar

    local overhealBar = barParent:CreateTexture(nil, "BORDER", nil, 6)
    overhealBar:SetColorTexture(1, 1, 1)
    overhealBar:Hide()
    fd.overhealBar = overhealBar

    local deficitText = barParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    deficitText:SetPoint("RIGHT", fd.hb, "RIGHT", -2 + (Settings.deficitOffsetX or 0), Settings.deficitOffsetY or 0)
    deficitText:SetJustifyH("RIGHT")
    deficitText:Hide()
    fd.deficitText = deficitText

    local shieldText = barParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    shieldText:SetPoint("LEFT", fd.hb, "LEFT", 2, 0)
    shieldText:SetJustifyH("LEFT")
    shieldText:Hide()
    fd.shieldText = shieldText

    -- Healer count text (position configurable)
    local healerCountText = barParent:CreateFontString(nil, "OVERLAY")
    healerCountText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    ApplyTextAnchor(healerCountText, fd.hb, HEALER_COUNT_ANCHORS, Settings.healerCountPos, Settings.healerCountOffsetX, Settings.healerCountOffsetY)
    healerCountText:Hide()
    fd.healerCountText = healerCountText

    -- Trajectory marker (2px vertical line)
    local trajMarker = barParent:CreateTexture(nil, "OVERLAY", nil, 3)
    trajMarker:SetColorTexture(1, 1, 0, 0.7)
    trajMarker:SetWidth(2)
    trajMarker:Hide()
    fd.trajectoryMarker = trajMarker

    -- Indicator overlay frame: render above health bar to guarantee visibility
    local indicatorOverlay = CreateFrame("Frame", nil, frame)
    indicatorOverlay:SetAllPoints(frame)
    local hbLevel = fd.hb and fd.hb:GetFrameLevel() or frame:GetFrameLevel()
    indicatorOverlay:SetFrameLevel(hbLevel + 2)
    fd.indicatorOverlay = indicatorOverlay

    -- AoE advisor border (4-edge strips on overlay)
    local aoeBorder = CreateFrame("Frame", nil, indicatorOverlay)
    aoeBorder:SetAllPoints(frame)
    aoeBorder:Hide()
    local aoeEdges = {}
    for _, info in ipairs({
        {"TOPLEFT", "TOPRIGHT", "SetHeight"},
        {"BOTTOMLEFT", "BOTTOMRIGHT", "SetHeight"},
        {"TOPLEFT", "BOTTOMLEFT", "SetWidth"},
        {"TOPRIGHT", "BOTTOMRIGHT", "SetWidth"},
    }) do
        local e = aoeBorder:CreateTexture(nil, "OVERLAY")
        e:SetColorTexture(1, 1, 1)
        e:SetPoint(info[1]); e:SetPoint(info[2])
        e[info[3]](e, GetBorderThickness())
        aoeEdges[#aoeEdges + 1] = e
    end
    fd.aoeBorder = aoeBorder
    fd._aoeEdges = aoeEdges

    -- Snipe flash (red border, on overlay)
    local snipeFlash = indicatorOverlay:CreateTexture(nil, "OVERLAY", nil, 5)
    snipeFlash:SetTexture("Interface\\RaidFrame\\Raid-Border")
    snipeFlash:SetAllPoints(frame)
    snipeFlash:SetVertexColor(1, 0.1, 0.1, 1)
    snipeFlash:SetAlpha(0)
    snipeFlash:Hide()
    local snipeAG = snipeFlash:CreateAnimationGroup()
    local snipeAlpha = snipeAG:CreateAnimation("Alpha")
    snipeAlpha:SetFromAlpha(0.8)
    snipeAlpha:SetToAlpha(0)
    snipeAlpha:SetDuration(0.5)
    snipeAG:SetScript("OnFinished", function() snipeFlash:SetAlpha(0); snipeFlash:Hide() end)
    fd.snipeFlash = snipeFlash
    fd.snipeAG = snipeAG

    -- Indicator effects (supports Static/Glow/Spinning styles)
    fd.effects = {}
    fd.effects.hotExpiry = CreateIndicatorEffect(indicatorOverlay, frame, "OVERLAY", 4, false, frame)
    fd.hotExpiryBorder = fd.effects.hotExpiry.border

    fd.effects.dispel = CreateIndicatorEffect(indicatorOverlay, fd.hb or frame, "OVERLAY", 3, false, frame)
    fd.dispelOverlay = fd.effects.dispel.border

    -- Res tracker text (on overlay so it renders above health bar too)
    local resText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
    resText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    resText:SetText("|cff44ff44RES|r")
    if fd.hb then resText:SetPoint("CENTER", fd.hb, "CENTER", Settings.resOffsetX or 0, Settings.resOffsetY or 0) end
    resText:Hide()
    fd.resText = resText

    fd.effects.cluster = CreateIndicatorEffect(indicatorOverlay, frame, "OVERLAY", 3, false, frame)
    fd.clusterBorder = fd.effects.cluster.border

    fd.effects.healReduc = CreateIndicatorEffect(indicatorOverlay, frame, "OVERLAY", 4, false, frame)
    fd.healReducGlow = fd.effects.healReduc.border
    
    -- Defensive cooldown indicator effect (for border display mode)
    fd.effects.defensive = CreateIndicatorEffect(indicatorOverlay, frame, "OVERLAY", 5, false, frame)
    fd.healReducGlow = fd.effects.healReduc.border

    -- Charmed/Mind-controlled indicator effect
    fd.effects.charmed = CreateIndicatorEffect(indicatorOverlay, frame, "OVERLAY", 6, false, frame)
    fd.charmedGlow = fd.effects.charmed.border

    -- Heal reduction text (on overlay)
    local healReducText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
    healReducText:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
    healReducText:SetTextColor(1, 0.3, 0.3)
    healReducText:Hide()
    fd.healReducText = healReducText
    -- Apply position based on setting
    local function ApplyHealReducTextPos()
        if not fd.hb or not fd.healReducText then return end
        local pos = Settings.healReductionTextPos or 4
        local hrText = fd.healReducText
        local ox = Settings.healReducOffsetX or 0
        local oy = Settings.healReducOffsetY or 0
        hrText:ClearAllPoints()
        -- 1=TL, 2=TR, 3=C, 4=BL, 5=BR
        if pos == 1 then
            hrText:SetPoint("TOPLEFT", fd.hb, "TOPLEFT", 2 + ox, -1 + oy)
        elseif pos == 2 then
            hrText:SetPoint("TOPRIGHT", fd.hb, "TOPRIGHT", -2 + ox, -1 + oy)
        elseif pos == 3 then
            hrText:SetPoint("CENTER", fd.hb, "CENTER", ox, oy)
        elseif pos == 4 then
            hrText:SetPoint("BOTTOMLEFT", fd.hb, "BOTTOMLEFT", 2 + ox, 1 + oy)
        else -- 5
            hrText:SetPoint("BOTTOMRIGHT", fd.hb, "BOTTOMRIGHT", -2 + ox, 1 + oy)
        end
    end
    ApplyHealReducTextPos()
    fd._applyHealReducTextPos = ApplyHealReducTextPos
    
    -- Death prediction text (on overlay)
    local deathPredText = indicatorOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    deathPredText:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    deathPredText:SetPoint("CENTER", fd.hb or frame, "CENTER", Settings.deathPredOffsetX or 0, Settings.deathPredOffsetY or 0)
    deathPredText:Hide()
    fd.deathPredText = deathPredText

    -- CD tracker text (on overlay)
    local cdText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
    cdText:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE")
    cdText:SetTextColor(0.3, 1.0, 0.3)
    if fd.hb then cdText:SetPoint("TOPRIGHT", fd.hb, "TOPRIGHT", -2 + (Settings.cdOffsetX or 0), -1 + (Settings.cdOffsetY or 0)) end
    cdText:Hide()
    fd.cdText = cdText

    -- Defensive cooldown display (icon + styled text for better visibility)
    local defensiveContainer = CreateFrame("Frame", nil, indicatorOverlay)
    defensiveContainer:SetSize(40, 20)
    if fd.hb then defensiveContainer:SetPoint("CENTER", fd.hb, "CENTER", Settings.defensiveOffsetX or 0, Settings.defensiveOffsetY or 0) end
    defensiveContainer:Hide()
    fd.defensiveContainer = defensiveContainer
    
    -- Defensive icon (left side)
    local defensiveIcon = defensiveContainer:CreateTexture(nil, "OVERLAY", nil, 7)
    defensiveIcon:SetSize(16, 16)
    defensiveIcon:SetPoint("LEFT", defensiveContainer, "LEFT", 0, 0)
    defensiveIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- Trim borders
    fd.defensiveIcon = defensiveIcon
    
    -- Defensive text (right of icon, bold and larger)
    local defensiveText = defensiveContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    defensiveText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE") -- Larger size (was 9)
    defensiveText:SetPoint("LEFT", defensiveIcon, "RIGHT", 2, 0)
    fd.defensiveText = defensiveText

    -- HoT tracker dots/icons (5 for each HoT type: Renew, Rejuv, Regrowth, Lifebloom, Earth Shield)
    if fd.hb then
        local dotSize = Settings.hotDotSize or 4
        local isIconMode = (Settings.hotDotDisplayMode or 1) == 2
        fd.hotDots = {}
        fd.hotDotCooldowns = {} -- Store cooldown frames
        for di = 1, 5 do
            if isIconMode then
                -- Icon mode: Create frame with texture and cooldown
                local iconFrame = CreateFrame("Frame", nil, indicatorOverlay)
                iconFrame:SetSize(dotSize, dotSize)
                iconFrame:Hide()
                
                local iconTex = iconFrame:CreateTexture(nil, "OVERLAY", nil, 7)
                iconTex:SetAllPoints(iconFrame)
                iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                iconTex:SetTexture(HP.HOT_DOT_ICONS[di])
                
                -- Add cooldown sweep
                local cooldown = CreateFrame("Cooldown", nil, iconFrame, "CooldownFrameTemplate")
                cooldown:SetAllPoints(iconFrame)
                cooldown:SetReverse(true)
                cooldown:SetHideCountdownNumbers(true)
                cooldown.noCooldownCount = true
                cooldown:Hide()
                
                fd.hotDots[di] = iconFrame
                fd.hotDotCooldowns[di] = cooldown
            else
                -- Dot mode: Simple color texture
                local dot = indicatorOverlay:CreateTexture(nil, "OVERLAY", nil, 7)
                dot:SetSize(dotSize, dotSize)
                dot:Hide()
                fd.hotDots[di] = dot
            end
        end
        
        -- Other healers' HoT dots/icons
        fd.hotDotsOther = {}
        fd.hotDotOtherCooldowns = {}
        for di = 1, 5 do
            if isIconMode then
                -- Icon mode
                local iconFrame = CreateFrame("Frame", nil, indicatorOverlay)
                iconFrame:SetSize(dotSize, dotSize)
                iconFrame:Hide()
                
                local iconTex = iconFrame:CreateTexture(nil, "OVERLAY", nil, 7)
                iconTex:SetAllPoints(iconFrame)
                iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                iconTex:SetTexture(HP.HOT_DOT_ICONS[di])
                iconTex:SetDesaturated(true) -- Gray out other healers' icons
                iconTex:SetAlpha(0.8)
                
                local cooldown = CreateFrame("Cooldown", nil, iconFrame, "CooldownFrameTemplate")
                cooldown:SetAllPoints(iconFrame)
                cooldown:SetReverse(true)
                cooldown:SetHideCountdownNumbers(true)
                cooldown.noCooldownCount = true
                cooldown:Hide()
                
                fd.hotDotsOther[di] = iconFrame
                fd.hotDotOtherCooldowns[di] = cooldown
            else
                -- Dot mode
                local dot = indicatorOverlay:CreateTexture(nil, "OVERLAY", nil, 7)
                dot:SetSize(dotSize, dotSize)
                dot:Hide()
                fd.hotDotsOther[di] = dot
            end
        end
        
        -- Apply anchors using the shared function
        ApplyDotAnchors(fd)
    end

    -- Low mana warning text (on overlay)
    local manaWarnText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
    manaWarnText:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE")
    manaWarnText:SetTextColor(0.4, 0.6, 1.0)
    if fd.hb then manaWarnText:SetPoint("BOTTOMRIGHT", fd.hb, "BOTTOMRIGHT", Settings.lowManaOffsetX or -2, Settings.lowManaOffsetY or 1) end
    manaWarnText:Hide()
    fd.manaWarnText = manaWarnText

    if fd.hb then
        fd._hbWidth = fd.hb:GetWidth()
        fd.hb:HookScript("OnSizeChanged", function(_, w)
            fd._hbWidth = w
        end)
    end

    -- Note: Range alpha is now handled via polling in HP.Tick() to avoid taint
    -- (HookFrameAlpha was causing ADDON_ACTION_BLOCKED errors in combat)

    frameData[frame] = fd
end

---------------------------------------------------------------------------
-- Robust health bar resolution for unit frames
-- TBC Anniversary uses inconsistent casing across frame types
---------------------------------------------------------------------------
local function ResolveHealthBar(frame)
    if not frame then return nil end
    return frame.healthbar
        or frame.healthBar
        or frame.HealthBar
        or (frame.GetName and frame:GetName() and _G[frame:GetName() .. "HealthBar"])
        or nil
end

local function SetupNameplate(frame)
    if not Settings.showNameplates then return end
    if frameData[frame] then return end

    local hb = ResolveHealthBar(frame)
    if not hb then return end  -- no health bar found, can't render predictions

    -- Create an overlay frame parented to the health bar to avoid forbidden frame
    -- restrictions on nameplate UnitFrames. Our textures live on this overlay.
    local ok, overlay = pcall(CreateFrame, "Frame", nil, hb)
    if not ok or not overlay then return end
    overlay:SetAllPoints(hb)
    overlay:SetFrameLevel(hb:GetFrameLevel() + 1)

    local fd = { hb = hb, usesGradient = false, bars = {}, overlay = overlay }

    for idx = 1, 5 do
        local tex = overlay:CreateTexture(nil, "BORDER", nil, 5)
        tex:ClearAllPoints()
        tex:SetTexture("Interface/TargetingFrame/UI-TargetingFrame-BarFill")
        tex:Hide()
        fd.bars[idx] = tex
    end

    fd.shieldTex = CreateShieldTex(overlay)

    local absorbBar = overlay:CreateTexture(nil, "BORDER", nil, 6)
    absorbBar:SetColorTexture(1, 1, 1)
    absorbBar:Hide()
    fd.absorbBar = absorbBar

    local overhealBar = overlay:CreateTexture(nil, "BORDER", nil, 6)
    overhealBar:SetColorTexture(1, 1, 1)
    overhealBar:Hide()
    fd.overhealBar = overhealBar

    fd._hbWidth = hb:GetWidth()
    hb:HookScript("OnSizeChanged", function(_, w)
        fd._hbWidth = w
    end)

    frameData[frame] = fd
end

---------------------------------------------------------------------------
-- Setup unit frames (player, target, party, etc.)
---------------------------------------------------------------------------
local function SetupUnit(frame, texSpecs, frameType, expectedUnit)
    if not frame then return end

    local fd = { hb = ResolveHealthBar(frame), usesGradient = false, bars = {}, frameType = frameType, expectedUnit = expectedUnit }
    local texPath = GetUnitBarTexture()

    -- Always create an overlay frame on the health bar so prediction textures
    -- render above the health bar fill.  The old FindChild approach was fragile
    -- across WoW versions â€” TBC Anniversary changed PlayerFrame's child
    -- hierarchy, causing BACKGROUND-layer textures to hide behind the fill.
    -- An overlay at frameLevel+1 guarantees correct stacking for every frame.
    local overlay
    if fd.hb then
        overlay = CreateFrame("Frame", nil, fd.hb)
        overlay:SetAllPoints(fd.hb)
        overlay:SetFrameLevel(fd.hb:GetFrameLevel() + 1)
        fd.overlay = overlay
    end

    for idx = 1, 5 do
        local spec = texSpecs[idx]
        if spec then
            local parent = overlay or frame
            local tex = MakeTex(parent, spec.name, spec.layer, spec.sub)
            if tex then
                tex:ClearAllPoints()
                tex:SetTexture(texPath)
                tex:Hide()
            end
            fd.bars[idx] = tex
        end
    end

    local texParent = overlay or fd.hb or frame
    fd.shieldTex = CreateShieldTex(texParent)

    local absorbBar = texParent:CreateTexture(nil, "BORDER", nil, 6)
    absorbBar:SetTexture(texPath)
    absorbBar:Hide()
    fd.absorbBar = absorbBar

    local overhealBar = texParent:CreateTexture(nil, "BORDER", nil, 6)
    overhealBar:SetTexture(texPath)
    overhealBar:Hide()
    fd.overhealBar = overhealBar

    if fd.hb then
        local healText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ApplyTextAnchor(healText, fd.hb, HEAL_TEXT_ANCHORS, Settings.healTextPos, Settings.healTextOffsetX, Settings.healTextOffsetY)
        healText:Hide()
        fd.healText = healText

        local shieldText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        shieldText:SetPoint("BOTTOM", fd.hb, "BOTTOM", 0, 1)
        shieldText:SetJustifyH("CENTER")
        shieldText:Hide()
        fd.shieldText = shieldText
    end

    frameData[frame] = fd

    if fd.hb then
        fd._hbWidth = fd.hb:GetWidth()
        fd.hb:HookScript("OnSizeChanged", function(_, w)
            fd._hbWidth = w
            QueueUnit(frame)
        end)
    end

    if not hookedFrames[frame] then
        local regUnit = frame.unit or expectedUnit
        if regUnit then
            local proxy = CreateFrame("Frame")
            proxy:RegisterUnitEvent("UNIT_MAXHEALTH", regUnit)
            proxy:RegisterUnitEvent("UNIT_HEALTH_FREQUENT", regUnit)
            proxy:SetScript("OnEvent", function()
                QueueUnit(frame)
            end)
            hookedFrames[frame] = proxy
        else
            hookedFrames[frame] = true
        end
    end
end

-- Texture spec builders
local function TS(depth, name, layer, sub)
    return { depth = depth, name = name, layer = layer, sub = sub }
end

local PLAYER_SPECS = {
    TS({1, 1}, "$parentMyHealBar1", "BACKGROUND"),
    TS({1, 1}, "$parentMyHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar1", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar3", "BACKGROUND"),
}

local TARGET_SPECS = {
    TS({}, "$parentMyHealBar1", "ARTWORK", 1),
    TS({}, "$parentMyHealBar2", "ARTWORK", 1),
    TS({}, "$parentOtherHealBar1", "ARTWORK", 1),
    TS({}, "$parentOtherHealBar2", "ARTWORK", 1),
    TS({}, "$parentOtherHealBar3", "ARTWORK", 1),
}

local PET_SPECS = {
    TS({1, 1}, "$parentMyHealBar1", "OVERLAY"),
    TS({1, 1}, "$parentMyHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar1", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar3", "BACKGROUND"),
}

local PARTY_SPECS = {
    TS({1, 1}, "$parentMyHealBar1", "OVERLAY"),
    TS({1, 1}, "$parentMyHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar1", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar3", "BACKGROUND"),
}

local PARTYPET_SPECS = {
    TS({1, 1}, "$parentMyHealBar1", "BACKGROUND"),
    TS({1, 1}, "$parentMyHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar1", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar2", "BACKGROUND"),
    TS({1, 1}, "$parentOtherHealBar3", "BACKGROUND"),
}

local TOT_SPECS = TARGET_SPECS

---------------------------------------------------------------------------
-- GUID tracking helpers
---------------------------------------------------------------------------
local function TrackGUID(frame, unit, registry)
    local old = frameGUID[frame]
    local new = unit and UnitGUID(unit)
    if new == old then return end
    if old and registry[old] then
        registry[old][frame] = nil
        if not next(registry[old]) then registry[old] = nil end
    end
    if new then
        registry[new] = registry[new] or {}
        registry[new][frame] = true
    end
    frameGUID[frame] = new
end

---------------------------------------------------------------------------
-- Blizzard hooks
---------------------------------------------------------------------------
HookIfExists("CompactUnitFrame_UpdateUnitEvents", function(frame)
    if not frame:IsForbidden() then
        -- Only unregister UNIT_HEALTH if UNIT_HEALTH_FREQUENT is confirmed active,
        -- otherwise the health bar would never receive updates
        if frame:IsEventRegistered("UNIT_HEALTH_FREQUENT") then
            frame:UnregisterEvent("UNIT_HEALTH")
        end
    end
end)

HookIfExists("CompactUnitFrame_OnEvent", function(self, event, ...)
    if event == self.updateAllEvent
       and (not self.updateAllFilter or self.updateAllFilter(self, event, ...)) then
        return
    end
    local u = ...
    if u == self.unit or u == self.displayedUnit then
        if event == "UNIT_HEALTH_FREQUENT" or event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
            QueueCompact(self)
        end
    end
end)

-- REMOVED: Hooks on CompactUnitFrame_UpdateAll, UpdateHealth, UpdateMaxHealth
-- These were causing taint errors (ADDON_ACTION_BLOCKED) in combat.
-- We now use a polling-based approach in HP.Tick() instead.

local function OnUnitUpdate(frame)
    TrackGUID(frame, frame.unit, guidToUnit)
    QueueUnit(frame)
end

-- NOTE: We intentionally do NOT hook UnitFrame_Update, UnitFrame_SetUnit, or
-- UnitFrame_OnEvent.  hooksecurefunc post-hooks on those functions taint the
-- caller's execution context (TargetFrame:Update), causing
-- ADDON_ACTION_BLOCKED on TargetFrame:HideBase() via EditMode.
-- Instead we rely on HealthBar-level hooks (safe â€” status bars aren't
-- protected) plus event-driven proxies for target/focus changes.

HookIfExists("UnitFrameHealthBar_OnUpdate", function(self)
    if not self.disconnected and not self.lockValues then
        if not self.ignoreNoUnit or UnitGUID(self.unit) then
            local frame = self:GetParent()
            local fd = frameData[frame]
            -- SUF/ElvUI frames reuse Blizzard's UnitFrameHealthBar template;
            -- routing them through QueueUnit would paint them with UNIT_PAL
            -- before their own renderer re-paints with the correct palette.
            if fd and not fd._isSUF and not fd._isElvUI then
                TrackGUID(frame, frame.unit, guidToUnit)
                QueueUnit(frame)
            end
        end
    end
end)

HookIfExists("UnitFrameHealthBar_Update", function(sb)
    if sb and not sb.lockValues then
        local frame = sb:GetParent()
        local fd = frameData[frame]
        if fd and not fd._isSUF and not fd._isElvUI then
            TrackGUID(frame, frame.unit, guidToUnit)
            QueueUnit(frame)
        end
    end
end)

-- Event-driven proxy for target/focus/ToT changes (replaces taint-causing hooks)
do
    local unitProxy = CreateFrame("Frame")
    unitProxy:RegisterEvent("PLAYER_TARGET_CHANGED")
    unitProxy:RegisterEvent("UNIT_TARGET")
    if FocusFrame then unitProxy:RegisterEvent("PLAYER_FOCUS_CHANGED") end
    unitProxy:SetScript("OnEvent", function(_, event, arg1)
        if event == "PLAYER_TARGET_CHANGED" then
            if TargetFrame and frameData[TargetFrame] then
                TrackGUID(TargetFrame, "target", guidToUnit)
                QueueUnit(TargetFrame)
            end
            if TargetFrameToT and frameData[TargetFrameToT] then
                TrackGUID(TargetFrameToT, "targettarget", guidToUnit)
                QueueUnit(TargetFrameToT)
            end
        elseif event == "PLAYER_FOCUS_CHANGED" then
            if FocusFrame and frameData[FocusFrame] then
                TrackGUID(FocusFrame, "focus", guidToUnit)
                QueueUnit(FocusFrame)
            end
        elseif event == "UNIT_TARGET" and arg1 == "target" then
            if TargetFrameToT and frameData[TargetFrameToT] then
                TrackGUID(TargetFrameToT, "targettarget", guidToUnit)
                QueueUnit(TargetFrameToT)
            end
        end
    end)
end

-- Compact frame setup hooks
HookIfExists("DefaultCompactUnitFrameSetup", SetupCompact)
HookIfExists("DefaultCompactMiniFrameSetup", SetupCompact)

-- Suppress Blizzard's built-in heal prediction on frames we manage
HookIfExists("CompactUnitFrame_UpdateHealPrediction", function(frame)
    if HP.frameData[frame] then HideBlizzardPrediction(frame) end
end)


-- SAFE range opacity control using polling (no taint-causing hooks)
-- We completely replace Blizzard's range alpha by setting it to 1 in our setup
-- and using our own polling to apply the correct alpha.

-- Range update timer (60 FPS for smoother transitions)
local lastRangeUpdate = 0
local RANGE_UPDATE_INTERVAL = 0.016  -- 60 FPS

-- Update range alpha for all managed frames (called from HP.Tick)
-- Always applies alpha to prevent Blizzard's default behavior from taking over
local function UpdateRangeAlphas()
    if not Settings.rangeIndicator then return end
    
    for frame, fd in pairs(HP.frameData) do
        -- Skip test frames - they shouldn't be affected by range alpha
        if fd.usesGradient and frame:IsVisible() and frame.displayedUnit and not fd._isTestFrame then
            local inRange, checkedRange = UnitInRange(frame.displayedUnit)
            local targetAlpha = (checkedRange and not inRange) and Settings.rangeAlpha or 1.0
            
            -- Always apply alpha to fight against Blizzard's default range updates
            -- Use pcall to catch any errors in combat
            pcall(function()
                frame:SetAlpha(targetAlpha)
            end)
        end
    end
end

-- Polling-based range update (called from HP.Tick)
local function TickRangeUpdate(elapsed)
    if not Settings.rangeIndicator then return end
    lastRangeUpdate = lastRangeUpdate + elapsed
    if lastRangeUpdate >= RANGE_UPDATE_INTERVAL then
        lastRangeUpdate = 0
        UpdateRangeAlphas()
    end
end

-- Export for HP.Tick
HP.TickRangeUpdate = TickRangeUpdate
HookIfExists("DefaultCompactNamePlateFrameSetup", SetupNameplate)

-- Hook Blizzard's range check to prevent it from overriding our alpha
if _G.CompactUnitFrame_UpdateInRange then
    hooksecurefunc("CompactUnitFrame_UpdateInRange", function(frame)
        if not Settings.rangeIndicator then return end
        if not frame or frame:IsForbidden() then return end
        local fd = HP.frameData[frame]
        -- Skip test frames
        if fd and fd.usesGradient and not fd._isTestFrame then
            local inRange, checkedRange = UnitInRange(frame.displayedUnit)
            local targetAlpha = (checkedRange and not inRange) and Settings.rangeAlpha or 1.0
            pcall(function() frame:SetAlpha(targetAlpha) end)
        end
    end)
end

-- ULTRA-AGGRESSIVE: Separate OnUpdate handler just for alpha (144 FPS)
-- This runs independently of HP.Tick to ensure alpha is enforced constantly
local alphaEnforcer = CreateFrame("Frame")
alphaEnforcer:Hide() -- Will show when rangeIndicator is enabled
local lastAlphaUpdate = 0
local ALPHA_INTERVAL = 0.007 -- 144 FPS

alphaEnforcer:SetScript("OnUpdate", function(self, elapsed)
    lastAlphaUpdate = lastAlphaUpdate + elapsed
    if lastAlphaUpdate < ALPHA_INTERVAL then return end
    lastAlphaUpdate = 0
    
    for frame, fd in pairs(HP.frameData) do
        -- Skip test frames
        if fd.usesGradient and frame:IsVisible() and frame.displayedUnit and not fd._isTestFrame then
            local inRange, checkedRange = UnitInRange(frame.displayedUnit)
            local targetAlpha = (checkedRange and not inRange) and Settings.rangeAlpha or 1.0
            -- Always set, don't check current value
            pcall(function() frame:SetAlpha(targetAlpha) end)
        end
    end
end)

-- Toggle the enforcer based on setting
local function ToggleAlphaEnforcer()
    if Settings.rangeIndicator then
        alphaEnforcer:Show()
    else
        alphaEnforcer:Hide()
        -- Restore full opacity when disabled
        for frame, fd in pairs(HP.frameData) do
            if fd.usesGradient then
                pcall(function() frame:SetAlpha(1.0) end)
            end
        end
    end
end

-- Check periodically if the enforcer should be running
C_Timer.NewTicker(1, ToggleAlphaEnforcer)
HP.ToggleAlphaEnforcer = ToggleAlphaEnforcer

-- Raid reservation hook
do
    local lastReserved
    HookIfExists("CompactRaidFrameReservation_GetFrame", function(self, key)
        lastReserved = self.reservations[key]
    end)

    local specMap = {
        raid    = { mapFn = UnitGUID, setup = SetupCompact },
        pet     = { setup = SetupCompact },
        flagged = { mapFn = UnitGUID, setup = SetupCompact },
        target  = { setup = SetupCompact },
    }

    HookIfExists("CompactRaidFrameContainer_GetUnitFrame", function(self, unit, ftype)
        if lastReserved then
            lastReserved = nil
            return
        end
        local info = specMap[ftype]
        if not info then return end
        local key = info.mapFn and info.mapFn(unit) or unit
        local reserved = self.frameReservations[ftype]
        local f = reserved and reserved.reservations and reserved.reservations[key]
        if f then info.setup(f) end
    end)
end

---------------------------------------------------------------------------
-- HealEngine callbacks
---------------------------------------------------------------------------
local function NotifyGUIDs(...)
    for j = 1, select("#", ...) do
        local guid = select(j, ...)
        local found = false
        if guidToUnit[guid] then
            for f in pairs(guidToUnit[guid]) do QueueUnit(f) end
            found = true
        end
        if guidToCompact[guid] then
            for f in pairs(guidToCompact[guid]) do QueueCompact(f) end
            found = true
        end
        if guidToPlate[guid] then
            QueueCompact(guidToPlate[guid])
            found = true
        end
        -- Fallback: if GUID wasn't found in any registry, scan compact frames
        -- This catches pet frames whose GUID tracking drifted out of sync
        if not found then
            -- First scan party/raid containers for any frames showing this GUID
            -- This is especially important for pet frames that appear dynamically
            local function CheckContainer(container)
                if not container or not container.GetNumChildren then return end
                for i = 1, container:GetNumChildren() do
                    local child = select(i, container:GetChildren())
                    if child and child.healthBar and not frameData[child] then
                        SetupCompact(child)
                    end
                    if child and child.displayedUnit then
                        if UnitGUID(child.displayedUnit) == guid then
                            if not frameData[child] then SetupCompact(child) end
                            TrackGUID(child, child.displayedUnit, guidToCompact)
                            QueueCompact(child)
                            found = true
                        end
                    end
                end
            end
            CheckContainer(_G.CompactPartyFrame)
            CheckContainer(_G.CompactRaidFrameContainer)
            
            -- Also scan our existing frames. SUF/ElvUI frames have their
            -- own renderer (UpdateSUFFrame / UpdateElvUIFrame) driven by
            -- their compat ticker — never route them through QueueUnit, or
            -- the unit palette will paint over their raid palette.
            for frame, fd in pairs(frameData) do
                if fd.usesGradient and frame.displayedUnit then
                    if UnitGUID(frame.displayedUnit) == guid then
                        TrackGUID(frame, frame.displayedUnit, guidToCompact)
                        QueueCompact(frame)
                    end
                elseif not fd.usesGradient and not fd._isSUF and not fd._isElvUI and frame.unit then
                    if UnitGUID(frame.unit) == guid then
                        TrackGUID(frame, frame.unit, guidToUnit)
                        QueueUnit(frame)
                    end
                end
            end
        end
    end
end

-- Export for Features.lua / Init.lua
HP.NotifyGUIDs = NotifyGUIDs

local commCallbacks = {}

-- Debug: print heals for a unit (run /run HP.DebugHeals("target") to test)
function HP.DebugHeals(unit)
    unit = unit or "target"
    local guid = UnitGUID(unit)
    print("DebugHeals for", unit, "=", guid and guid:sub(1, 20) or "nil")
    print("  UnitCanAssist:", UnitCanAssist("player", unit))
    
    local my1, my2, ot1, ot2
    if Settings.smartOrdering then
        my1, my2, ot1, ot2 = GetHealsSorted(unit)
    else
        my1, my2, ot1, ot2 = GetHeals(unit)
    end
    print(string.format("  My heals: %d, %d | Others: %d, %d", my1 or 0, my2 or 0, ot1 or 0, ot2 or 0))
    
    -- Check if in HealEngine
    local filter = BuildFilter()
    local me = UnitGUID("player")
    local direct = Engine:GetHealAmount(guid, Engine.DIRECT_HEALS, nil, me)
    local hot = Engine:GetHealAmount(guid, Engine.HOT_HEALS, nil, me)
    print("  Engine direct:", direct or 0, "HOT:", hot or 0)
    
    -- Check unitMap
    print("  In unitMap:", Engine.unitMap and Engine.unitMap[guid] and "yes" or "no")
end

-- Callback args: self, event, casterGUID, spellID, bitType, endTime, ...targets
function commCallbacks.HealComm_HealStarted(_, _, _, _, _, _, ...)
    NotifyGUIDs(...)
end

function commCallbacks.HealComm_HealStopped(_, _, _, _, _, _, ...)
    NotifyGUIDs(...)
end

function commCallbacks.HealComm_HealDelayed(_, _, _, _, _, _, ...)
    NotifyGUIDs(...)
end

function commCallbacks.HealComm_ModifierChanged(_, _, guid)
    NotifyGUIDs(guid)
end

function commCallbacks.HealComm_GUIDDisappeared(_, _, guid)
    shieldGUIDs[guid] = nil
    HP.shieldAmounts[guid] = nil
    defenseGUIDs[guid] = nil
    activeShields[guid] = nil
    HP.damageHistory[guid] = nil
    dispelGUIDs[guid] = nil
    resTargets[guid] = nil
    cdGUIDs[guid] = nil
    HP.hotDotGUIDs[guid] = nil
    HP.hotDotOtherGUIDs[guid] = nil
    HP.clusterGUIDs[guid] = nil
    HP.charmedGUIDs[guid] = nil
    NotifyGUIDs(guid)
end

commCallbacks.HealComm_HealUpdated = commCallbacks.HealComm_HealStarted

Engine.RegisterCallback(commCallbacks, "HealComm_HealStarted")
Engine.RegisterCallback(commCallbacks, "HealComm_HealUpdated")
Engine.RegisterCallback(commCallbacks, "HealComm_HealStopped")
Engine.RegisterCallback(commCallbacks, "HealComm_HealDelayed")
Engine.RegisterCallback(commCallbacks, "HealComm_ModifierChanged")
Engine.RegisterCallback(commCallbacks, "HealComm_GUIDDisappeared")

---------------------------------------------------------------------------
-- Refresh all tracked frames
---------------------------------------------------------------------------
function HP.RefreshAll()
    for _, set in pairs(guidToUnit) do
        if set then
            for f in pairs(set) do OnUnitUpdate(f) end
        end
    end
    for _, set in pairs(guidToCompact) do
        if set then
            for f in pairs(set) do QueueCompact(f) end
        end
    end
    for _, f in pairs(guidToPlate) do
        if Settings.showNameplates then
            QueueCompact(f)
        else
            local fd = frameData[f]
            if fd then
                for idx = 1, 5 do
                    if fd.bars and fd.bars[idx] then fd.bars[idx]:Hide() end
                end
                if fd.shieldTex then fd.shieldTex:Hide() end
                if fd.absorbBar then fd.absorbBar:Hide() end
                if fd.overhealBar then fd.overhealBar:Hide() end
            end
        end
    end
    -- Update heal reduction text positions on all frames
    for f, fd in pairs(frameData) do
        if fd and fd._applyHealReducTextPos then
            fd._applyHealReducTextPos()
        end
    end
    
    -- Hide death predictions if disabled
    if not Settings.deathPrediction then
        if HP.HideAllDeathPredictions then
            HP.HideAllDeathPredictions()
        end
    end
end

---------------------------------------------------------------------------
-- Reanchor configurable text elements across all frames
---------------------------------------------------------------------------
function HP.ReanchorTexts()
    for frame, fd in pairs(frameData) do
        if fd.hb then
            if fd.healerCountText then
                ApplyTextAnchor(fd.healerCountText, fd.hb, HEALER_COUNT_ANCHORS, Settings.healerCountPos, Settings.healerCountOffsetX, Settings.healerCountOffsetY)
            end
            if fd.healText then
                ApplyTextAnchor(fd.healText, fd.hb, HEAL_TEXT_ANCHORS, Settings.healTextPos, Settings.healTextOffsetX, Settings.healTextOffsetY)
            end
            if fd.hotDots then
                ApplyDotAnchors(fd)
            end
            if fd.deficitText then
                fd.deficitText:ClearAllPoints()
                fd.deficitText:SetPoint("RIGHT", fd.hb, "RIGHT", -2 + (Settings.deficitOffsetX or 0), Settings.deficitOffsetY or 0)
            end
            if fd.resText then
                fd.resText:ClearAllPoints()
                fd.resText:SetPoint("CENTER", fd.hb, "CENTER", Settings.resOffsetX or 0, Settings.resOffsetY or 0)
            end
            if fd._applyHealReducTextPos then
                fd._applyHealReducTextPos()
            end
            if fd.deathPredText then
                fd.deathPredText:ClearAllPoints()
                fd.deathPredText:SetPoint("CENTER", fd.hb, "CENTER", Settings.deathPredOffsetX or 0, Settings.deathPredOffsetY or 0)
            end
            if fd.cdText then
                fd.cdText:ClearAllPoints()
                fd.cdText:SetPoint("TOPRIGHT", fd.hb, "TOPRIGHT", -2 + (Settings.cdOffsetX or 0), -1 + (Settings.cdOffsetY or 0))
            end
            if fd.defensiveContainer then
                local dpos = Settings.defensivePos or 1
                local da = DEFENSE_ANCHORS[dpos] or DEFENSE_ANCHORS[1]
                fd.defensiveContainer:ClearAllPoints()
                fd.defensiveContainer:SetPoint(da[1], fd.hb, da[2], da[3] + (Settings.defensiveOffsetX or 0), da[4] + (Settings.defensiveOffsetY or 0))
            end
            if fd.manaWarnText then
                fd.manaWarnText:ClearAllPoints()
                fd.manaWarnText:SetPoint("BOTTOMRIGHT", fd.hb, "BOTTOMRIGHT", Settings.lowManaOffsetX or -2, Settings.lowManaOffsetY or 1)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Fast raid update ticker
---------------------------------------------------------------------------
local fastTickerRunning = false

local function FastUpdateLoop()
    if not Settings.fastRaidUpdate then
        fastTickerRunning = false
        return
    end
    local interval = 1 / (Settings.fastUpdateRate or 30)
    if not IsInGroup() and not IsInRaid() then
        C_Timer.After(1.0, FastUpdateLoop)
        return
    end
    for _, set in pairs(guidToCompact) do
        if set then
            for f in pairs(set) do
                if f:IsVisible() and f.displayedUnit then
                    QueueCompact(f)
                end
            end
        end
    end
    C_Timer.After(interval, FastUpdateLoop)
end

function HP.StartFastUpdate()
    if fastTickerRunning then return end
    fastTickerRunning = true
    local interval = 1 / (Settings.fastUpdateRate or 30)
    C_Timer.After(interval, FastUpdateLoop)
end

function HP.StopFastUpdate()
    fastTickerRunning = false
end

---------------------------------------------------------------------------
-- Process deferred updates (runs every rendered frame)
---------------------------------------------------------------------------
function HP.Tick()
    for f in pairs(dirtyUnit) do HP.UpdateUnit(f) end
    for f in pairs(dirtyCompact) do HP.UpdateCompact(f) end
    wipe(dirtyUnit)
    wipe(dirtyCompact)
    lastRender = GetTime()

    local now = GetTime()

    -- AoE advisor recalculation (every 0.5s)
    if Settings.aoeAdvisor then
        if not HP._lastAoECalc or now - HP._lastAoECalc >= 0.5 then
            HP._lastAoECalc = now
            local oldGUID = HP.aoeTargetGUID
            HP.GetBestAoETarget()
            if HP.aoeTargetGUID ~= oldGUID then
                if oldGUID then HP.NotifyGUIDs(oldGUID) end
                if HP.aoeTargetGUID then HP.NotifyGUIDs(HP.aoeTargetGUID) end
            end
        end
    end

    -- Mana forecast update (every 2s)
    if HP.UpdateManaForecast then
        if not HP._lastManaUpdate or now - HP._lastManaUpdate >= 2 then
            HP._lastManaUpdate = now
            HP.UpdateManaForecast()
        end
    end
    
    -- Encounter learning: mana snapshot (every 5s during encounter or instance combat)
    if (Settings.smartLearning or Settings.instanceTracking) and (HP.currentEncounter or HP.currentInstance) then
        if not HP._lastManaSnapshot or now - HP._lastManaSnapshot >= 5 then
            HP._lastManaSnapshot = now
            HP.RecordManaSnapshot()
        end
    end

    -- Encounter/instance suggestions update (every 3s during encounter or instance)
    if (Settings.smartLearning or Settings.instanceTracking) and (HP.currentEncounter or HP.currentInstance) then
        if (Settings.encounterSuggestionMode or 1) ~= 4 then -- 4 = Disabled
            if not HP._lastSuggestionUpdate or now - HP._lastSuggestionUpdate >= 3 then
                HP._lastSuggestionUpdate = now
                if HP.UpdateEncounterSuggestions then HP.UpdateEncounterSuggestions() end
            end
        end
    end

    -- Heal Queue data refresh (every 0.1s — positions interpolated per-frame via OnUpdate)
    if Settings.healQueue and HP.UpdateHealQueue then
        if not HP._lastHealQueueRefresh or now - HP._lastHealQueueRefresh >= 0.1 then
            HP._lastHealQueueRefresh = now
            HP.UpdateHealQueue()
        end
    end

    -- OOC regen timer update (every 2s)
    if HP.UpdateOOCRegen then
        if not HP._lastOOCUpdate or now - HP._lastOOCUpdate >= 2 then
            HP._lastOOCUpdate = now
            HP.UpdateOOCRegen()
        end
    end

    -- Low mana warning polling (every 2s)
    if Settings.lowManaWarning then
        if not HP._lastLowManaCheck or now - HP._lastLowManaCheck >= 2 then
            HP._lastLowManaCheck = now
            local threshold = Settings.lowManaThreshold or 20
            for _, set in pairs(guidToCompact) do
                if set then
                    for f in pairs(set) do
                        if f:IsVisible() and f.displayedUnit then
                            local fd = frameData[f]
                            if fd and fd._isHealer and fd.manaWarnText and not fd._isTestFrame then
                                local mana = UnitPower(f.displayedUnit, 0)
                                local maxMana = UnitPowerMax(f.displayedUnit, 0)
                                if maxMana and maxMana > 0 then
                                    local pct = mathfloor(mana / maxMana * 100)
                                    if pct <= threshold then
                                        fd.manaWarnText:SetText("|cff6699ff" .. pct .. "%|r")
                                        fd.manaWarnText:Show()
                                        if Settings.soundLowMana and not fd._lowManaSounded then
                                            if now - _lastLowManaSound >= SOUND_DEBOUNCE then
                                                _lastLowManaSound = now
                                                PlayAlertSound(Settings.lowManaSoundChoice)
                                            end
                                            fd._lowManaSounded = true
                                        end
                                    else
                                        fd.manaWarnText:Hide()
                                        fd._lowManaSounded = nil
                                    end
                                else
                                    fd.manaWarnText:Hide()
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Range indicator disabled cleanup - restore full opacity
    if not Settings.rangeIndicator and HP._rangeWasEnabled then
        HP._rangeWasEnabled = false
        for frame, fd in pairs(frameData) do
            if fd._rangeAlpha and fd._rangeAlpha < 1.0 then
                fd._rangeAlpha = 1.0
                frame:SetAlpha(1.0)
            end
        end
    elseif Settings.rangeIndicator then
        HP._rangeWasEnabled = true
    end

    -- Cluster detection recalculation (every 0.5s)
    if Settings.clusterDetection then
        if not HP._lastClusterCalc or now - HP._lastClusterCalc >= 0.5 then
            HP._lastClusterCalc = now
            HP.CalcClusterGUIDs()
        end
    end

    -- HoT expiry polling (every 0.5s) â€” time-based, needs polling not just events
    if Settings.hotExpiryWarning then
        if not HP._lastHotExpiryCheck or now - HP._lastHotExpiryCheck >= 0.5 then
            HP._lastHotExpiryCheck = now
            local playerGUID = UnitGUID("player")
            if playerGUID and Engine.ticking and Engine.ticking[playerGUID] then
                local thresh = Settings.hotExpiryThreshold
                for _, rec in pairs(Engine.ticking[playerGUID]) do
                    if rec.targets then
                        for tGUID, entry in pairs(rec.targets) do
                            local endTime = entry[3]
                            if endTime and endTime - now > 0 and endTime - now < thresh then
                                NotifyGUIDs(tGUID)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Res target cleanup (stale entries > 12s)
    if Settings.resTracker then
        for tGUID, info in pairs(resTargets) do
            if now - info.start > 12 then
                resTargets[tGUID] = nil
                NotifyGUIDs(tGUID)
            end
        end
    end

    -- Pet frame GUID re-sync (every 3s safety net)
    if not HP._lastPetSync or now - HP._lastPetSync >= 3 then
        HP._lastPetSync = now
        -- Unit-style pet frames
        if PetFrame and frameData[PetFrame] then
            TrackGUID(PetFrame, PetFrame.unit or "pet", guidToUnit)
        end
        for i = 1, MAX_PARTY_MEMBERS do
            local pf = PartyPetFrames[i]
            if pf and frameData[pf] then
                TrackGUID(pf, pf.unit or ("partypet" .. i), guidToUnit)
            end
        end
        -- Compact/raid pet frames
        for frame, fd in pairs(frameData) do
            if fd.usesGradient and frame.displayedUnit then
                local du = frame.displayedUnit
                if du:match("pet") then
                    TrackGUID(frame, du, guidToCompact)
                end
            end
        end
    end

    -- Compact frame polling (replaces removed hooks to avoid taint)
    -- Poll for GUID changes, health changes, and range updates
    if not HP._lastCompactPoll or now - HP._lastCompactPoll >= 0.016 then  -- 60 FPS
        HP._lastCompactPoll = now
        
        -- Auto-setup any visible compact frames that don't have our data yet
        -- This catches pet frames and other dynamic frames
        if CompactPartyFrame and CompactPartyFrame.GetNumChildren then
            for i = 1, CompactPartyFrame:GetNumChildren() do
                local child = select(i, CompactPartyFrame:GetChildren())
                if child and child.healthBar and not frameData[child] then
                    if child:IsVisible() then
                        SetupCompact(child)
                    end
                end
            end
        end
        if CompactRaidFrameContainer and CompactRaidFrameContainer.GetNumChildren then
            for i = 1, CompactRaidFrameContainer:GetNumChildren() do
                local child = select(i, CompactRaidFrameContainer:GetChildren())
                if child and child.healthBar and not frameData[child] then
                    if child:IsVisible() then
                        SetupCompact(child)
                    end
                end
            end
        end
        
        for frame, fd in pairs(frameData) do
            if fd.usesGradient and frame:IsVisible() then
                local displayedUnit = frame.displayedUnit
                if displayedUnit then
                    -- Check for unit changes
                    local newGUID = UnitGUID(displayedUnit)
                    if newGUID ~= fd.lastPolledGUID then
                        fd.lastPolledGUID = newGUID
                        TrackGUID(frame, displayedUnit, guidToCompact)
                        QueueCompact(frame)
                    end
                    -- Check for health/maxhealth changes
                    local hp = UnitHealth(displayedUnit)
                    local maxhp = UnitHealthMax(displayedUnit)
                    if hp ~= fd.lastHealth or maxhp ~= fd.lastMaxHealth then
                        fd.lastHealth = hp
                        fd.lastMaxHealth = maxhp
                        QueueCompact(frame)
                    end
                end
            end
        end
    end

    -- Range alpha updates (30 FPS polling, no hooks)
    if HP.TickRangeUpdate then
        HP.TickRangeUpdate(now - lastRender)
    end

    -- Spinning / Dashes indicator animation
    if HP._hasSpinningLines then
        for eff, info in pairs(HP._spinningFrames) do
            local efd = frameData[info.frame]
            if efd then
                local elapsed = now - (eff._lastSpin or now)
                eff._lastSpin = now

                if eff.lines and eff.lines[1] and eff.lines[1]:IsShown() then
                    eff._spinOffset = (eff._spinOffset or 0) + 60 * elapsed
                    local W = efd._hbWidth or 72
                    local H = efd.hb and efd.hb:GetHeight() or 30
                    local perim = 2 * (W + H)
                    local N = #eff.lines
                    for i = 1, N do
                        local t = eff._spinOffset + (i - 1) * perim / N
                        local px, py = PerimeterPos(t, W, H)
                        eff.lines[i]:ClearAllPoints()
                        eff.lines[i]:SetPoint("CENTER", efd.hb or info.frame, "TOPLEFT", px, -py)
                    end
                end

                if eff.dashes and eff.dashes[1] and eff.dashes[1]:IsShown() then
                    eff._dashOffset = (eff._dashOffset or 0) + 60 * elapsed
                    local W = efd._hbWidth or 72
                    local H = efd.hb and efd.hb:GetHeight() or 20
                    local N = #eff.dashes
                    local skew = H * 0.4
                    local cycle = W + skew + 20
                    local spacing = cycle / N
                    local anchor = efd.hb or info.frame
                    for i = 1, N do
                        local x = (eff._dashOffset + (i - 1) * spacing) % cycle - skew
                        eff.dashes[i]:SetStartPoint("BOTTOMLEFT", anchor, x, 0)
                        eff.dashes[i]:SetEndPoint("TOPLEFT", anchor, x + skew, 0)
                    end
                end

                -- Style 5: Pulse Ring animation
                if info.style == 5 and eff.rings then
                    eff._ringOffset = (eff._ringOffset or 0) + 8 * elapsed
                    local W = efd._hbWidth or 72
                    local H = efd.hb and efd.hb:GetHeight() or 30
                    local cycle = 8.0 -- Much slower 8 second cycle
                    local t = eff._ringOffset % cycle
                    local N = #eff.rings
                    local r, g, b, baseA = unpack(eff._ringColor)
                    for i = 1, N do
                        local ringT = (t + (i-1) * (cycle/N)) % cycle
                        local progress = ringT / cycle
                        local size = 15 + progress * math.max(W, H) * 0.7
                        -- Smoother alpha curve
                        local alpha = baseA * (1 - progress * progress)
                        eff.rings[i]:SetSize(size, size)
                        eff.rings[i]:SetAlpha(alpha)
                        eff.rings[i]:SetPoint("CENTER", efd.hb or info.frame, "CENTER", 0, 0)
                    end
                end

                -- Style 6: Strobe animation
                if info.style == 6 then
                    local interval = 0.15
                    eff._strobeState = eff._strobeState or { on = true, lastToggle = 0 }
                    if now - eff._strobeState.lastToggle >= interval then
                        eff._strobeState.on = not eff._strobeState.on
                        eff._strobeState.lastToggle = now
                        eff.border:SetAlpha(eff._strobeState.on and 1 or 0.2)
                    end
                end

                -- Style 7: Wave animation
                if info.style == 7 and eff.waveDots then
                    eff._waveOffset = (eff._waveOffset or 0) + 80 * elapsed
                    local W = efd._hbWidth or 72
                    local H = efd.hb and efd.hb:GetHeight() or 30
                    local N = #eff.waveDots
                    local amplitude = H * 0.3
                    local frequency = 2
                    for i = 1, N do
                        local x = ((eff._waveOffset * 0.5) + (i-1) * (W/N)) % W
                        local sinePhase = (x / W) * frequency * (2 * math.pi)
                        local y = H/2 + amplitude * math.sin(sinePhase)
                        eff.waveDots[i]:ClearAllPoints()
                        eff.waveDots[i]:SetPoint("CENTER", efd.hb or info.frame, "BOTTOMLEFT", x, y)
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Init unit frames at load time
---------------------------------------------------------------------------
function HP.InitAllUnitFrames()
    SetupUnit(PlayerFrame, PLAYER_SPECS, "player", "player")
    SetupUnit(PetFrame, PET_SPECS, "pet", "pet")
    SetupUnit(TargetFrame, TARGET_SPECS, "target", "target")
    SetupUnit(TargetFrameToT, TOT_SPECS, "tot", "targettarget")

    if WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC or
       WOW_PROJECT_ID == 5 then
        SetupUnit(FocusFrame, TARGET_SPECS, "focus", "focus")
    end

    for i = 1, MAX_PARTY_MEMBERS do
        SetupUnit(PartyFrames[i], PARTY_SPECS, "party", "party" .. i)
        SetupUnit(PartyPetFrames[i], PARTYPET_SPECS, "pet", "partypet" .. i)
    end

    -- Initial GUID tracking pass so RefreshAll() finds all unit frames
    C_Timer.After(0, function()
        local allUnitFrames = { PlayerFrame, PetFrame, TargetFrame, TargetFrameToT, FocusFrame }
        for i = 1, MAX_PARTY_MEMBERS do
            allUnitFrames[#allUnitFrames + 1] = PartyFrames[i]
            allUnitFrames[#allUnitFrames + 1] = PartyPetFrames[i]
        end
        for _, f in ipairs(allUnitFrames) do
            if f then
                local fd = frameData[f]
                local unit = f.unit or (fd and fd.expectedUnit)
                if unit then
                    TrackGUID(f, unit, guidToUnit)
                    QueueUnit(f)
                end
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Events: nameplates, roster, auras
---------------------------------------------------------------------------
function HP.OnEvent(event, arg1, arg2, arg3)
    if event == "GROUP_ROSTER_UPDATE" then
        if InCombatLockdown() then
            for _, set in pairs(guidToCompact) do
                if set then
                    for f in pairs(set) do QueueCompact(f) end
                end
            end
        end
        if HP.CheckAutoSwitch then HP.CheckAutoSwitch() end
    elseif event == "UNIT_PET" then
        -- Re-sync pet frame GUIDs when pets change (summon/dismiss/swap)
        -- Force immediate re-track using fresh UnitGUID() calls
        if arg1 == "player" then
            if PetFrame and frameData[PetFrame] then
                local petGUID = UnitGUID("pet")
                local oldGUID = frameGUID[PetFrame]
                if petGUID ~= oldGUID then
                    -- Clean up old GUID entry
                    if oldGUID and guidToUnit[oldGUID] then
                        guidToUnit[oldGUID][PetFrame] = nil
                        if not next(guidToUnit[oldGUID]) then guidToUnit[oldGUID] = nil end
                    end
                    -- Register new GUID
                    if petGUID then
                        guidToUnit[petGUID] = guidToUnit[petGUID] or {}
                        guidToUnit[petGUID][PetFrame] = true
                    end
                    frameGUID[PetFrame] = petGUID
                    -- Only update if pet exists; skip if dismissed/dead to avoid stale frame errors
                    if petGUID and UnitExists("pet") then
                        QueueUnit(PetFrame)
                        HP.UpdateUnit(PetFrame)
                        HP.ScanAuras("pet")
                    end
                end
            end
        else
            local idx = arg1:match("^party(%d)$")
            if idx then
                local pf = PartyPetFrames[tonumber(idx)]
                -- Setup frame if it exists but we haven't tracked it yet
                if pf and not frameData[pf] then
                    SetupUnit(pf, PARTYPET_SPECS, "pet", "partypet" .. idx)
                end
                if pf then
                    local unit = pf.unit or ("partypet" .. idx)
                    local petGUID = UnitGUID(unit)
                    local oldGUID = frameGUID[pf]
                    if petGUID ~= oldGUID then
                        if oldGUID and guidToUnit[oldGUID] then
                            guidToUnit[oldGUID][pf] = nil
                            if not next(guidToUnit[oldGUID]) then guidToUnit[oldGUID] = nil end
                        end
                        if petGUID then
                            guidToUnit[petGUID] = guidToUnit[petGUID] or {}
                            guidToUnit[petGUID][pf] = true
                        end
                        frameGUID[pf] = petGUID
                        -- Only update if pet exists; skip if dismissed/dead to avoid stale frame errors
                        if petGUID and UnitExists(unit) then
                            QueueUnit(pf)
                            HP.UpdateUnit(pf)
                            HP.ScanAuras(unit)
                        end
                    end
                end
            end
        end
        -- Also re-sync compact/raid frames showing pets
        -- First, try to set up any new pet frames we haven't seen yet
        local partyContainer = _G.CompactPartyFrame
        if partyContainer and partyContainer.GetNumChildren then
            for i = 1, partyContainer:GetNumChildren() do
                local child = select(i, partyContainer:GetChildren())
                if child and child.healthBar and not frameData[child] then
                    SetupCompact(child)
                end
            end
        end
        local raidContainer = _G.CompactRaidFrameContainer
        if raidContainer and raidContainer.GetNumChildren then
            for i = 1, raidContainer:GetNumChildren() do
                local child = select(i, raidContainer:GetChildren())
                if child and child.healthBar and not frameData[child] then
                    SetupCompact(child)
                end
            end
        end
        -- Then re-track GUIDs and queue all known pet frames for update
        for frame, fd in pairs(frameData) do
            if fd.usesGradient and frame.displayedUnit then
                local du = frame.displayedUnit
                if du:match("pet") then
                    TrackGUID(frame, du, guidToCompact)
                    QueueCompact(frame)
                end
            end
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if not C_NamePlate then return end
        if not Settings.showNameplates then return end
        if not UnitCanAssist("player", arg1) then return end
        local plate = C_NamePlate.GetNamePlateForUnit(arg1)
        if not plate then return end
        -- TBC Anniversary: resolve the unit frame on the nameplate
        -- Try plate.UnitFrame (modern), plate.unitFrame, or the plate itself
        local uf = plate.UnitFrame or plate.unitFrame
        if not uf then
            -- Check if the plate itself has a health bar (some TBC versions)
            if ResolveHealthBar(plate) then
                uf = plate
            else
                -- Last resort: scan child frames for one with a health bar
                local children = { plate:GetChildren() }
                for _, child in ipairs(children) do
                    if ResolveHealthBar(child) then
                        uf = child
                        break
                    end
                end
            end
        end
        if not uf then return end
        local guid = UnitGUID(arg1)
        if guid then
            if not frameData[uf] then SetupNameplate(uf) end
            if not frameData[uf] then return end  -- SetupNameplate failed (no health bar)
            uf.displayedUnit = arg1
            guidToPlate[guid] = uf
            QueueCompact(uf)
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local guid = UnitGUID(arg1)
        if guid then guidToPlate[guid] = nil end
    elseif event == "UNIT_AURA" then
        if Settings.showShieldGlow or Settings.showDefensives or Settings.showAbsorbBar or Settings.showShieldText or Settings.dispelHighlight or Settings.cdTracker or Settings.hotTrackerDots then
            local changed = HP.ScanAuras(arg1)
            if changed then
                local guid = UnitGUID(arg1)
                if guid then NotifyGUIDs(guid) end
            end
        end
    elseif event == "UNIT_SPELLCAST_START" then
        if arg1 == "player" and Settings.showManaCost then
            HP.UpdateManaCostBar()
        end
        -- Res tracking: detect resurrection casts
        if Settings.resTracker and RES_SPELLS then
            local spellID = arg3
            if not spellID and UnitCastingInfo then
                local _, _, _, _, _, _, _, _, sid = UnitCastingInfo(arg1)
                spellID = sid
            end
            if spellID and RES_SPELLS[spellID] then
                local target = UnitTarget and UnitTarget(arg1)
                if target and UnitIsDeadOrGhost(target) then
                    local tGUID = UnitGUID(target)
                    local cGUID = UnitGUID(arg1)
                    if tGUID and cGUID then
                        resTargets[tGUID] = { caster = cGUID, start = GetTime() }
                        NotifyGUIDs(tGUID)
                    end
                end
            end
        end
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then
            HP.HideManaCostBar()
        end
        -- Res tracking: clear entries for this caster
        if Settings.resTracker then
            local cGUID = UnitGUID(arg1)
            if cGUID then
                for tGUID, info in pairs(resTargets) do
                    if info.caster == cGUID then
                        resTargets[tGUID] = nil
                        NotifyGUIDs(tGUID)
                    end
                end
            end
        end
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_PET")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UNIT_TARGET")
if FocusFrame then eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED") end
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
if C_NamePlate then eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED") end
eventFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
eventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
if C_EventUtils and C_EventUtils.IsEventValid("FRIENDLY_NAME_PLATE_CREATED") then
    eventFrame:RegisterEvent("FRIENDLY_NAME_PLATE_CREATED")
end
eventFrame:SetScript("OnEvent", function(_, event, ...) HP.OnEvent(event, ...) end)

HP.eventFrame = eventFrame
HP.NotifyGUIDs = NotifyGUIDs
