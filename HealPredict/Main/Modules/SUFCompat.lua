-- HealPredict - Shadowed Unit Frames (SUF) Compatibility Module
-- Full support for SUF customizations including textures, orientation, and styles
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn

local HP = HealPredict
local Settings = HP.Settings

-- Local references for performance
local tinsert = table.insert
local mathmin = math.min
local mathmax = math.max
local mathfloor = math.floor
local pairs = pairs
local ipairs = ipairs
local UnitGUID = UnitGUID
local UnitExists = UnitExists
local UnitClass = UnitClass
local GetPlayerInfoByGUID = GetPlayerInfoByGUID
local GetTime = GetTime
local GetSpellTexture = GetSpellTexture
local fmt = string.format

local Engine = HP.Engine

-- Cached references to exported helpers
local CreateIndicatorEffect = HP.CreateIndicatorEffect
local CreateShieldTex       = HP.CreateShieldTex
local ApplyTextAnchor       = HP.ApplyTextAnchor
local ApplyDotAnchors       = HP.ApplyDotAnchors
local ShowIndicator         = HP.ShowIndicator
local HideIndicator         = HP.HideIndicator

local HEALER_COUNT_ANCHORS  = HP.HEALER_COUNT_ANCHORS
local HEAL_TEXT_ANCHORS     = HP.HEAL_TEXT_ANCHORS
local HOT_DOT_ANCHORS       = HP.HOT_DOT_ANCHORS
local DEFENSE_ANCHORS        = HP.DEFENSE_ANCHORS
local SHIELD_NAMES           = HP.SHIELD_NAMES

local HEALER_CLASSES = { PRIEST=true, PALADIN=true, DRUID=true, SHAMAN=true }

local SOUND_DEBOUNCE = 5
local _lastDispelSound = 0

local function PlayAlertSound(choiceIdx)
    if PlaySound then
        PlaySound(choiceIdx or 8959, "Master")
    end
end

------------------------------------------------------------------------
-- Class colors for class-colored heal bars (mirrors Render.lua)
------------------------------------------------------------------------
local CLASS_COLORS = {
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

local function GetClassColor(guid)
    if not guid then return 0.7, 0.7, 0.7 end
    local _, class = GetPlayerInfoByGUID(guid)
    if class then
        local cc = CLASS_COLORS[class]
        if cc then return cc[1], cc[2], cc[3] end
    end
    return 0.7, 0.7, 0.7
end

------------------------------------------------------------------------
-- Border thickness helper (mirrors Render.lua local)
------------------------------------------------------------------------
local function GetBorderThickness()
    return Settings.borderThickness or 2
end

------------------------------------------------------------------------
-- SUF Detection
------------------------------------------------------------------------
function HP.DetectSUF()
    local SUF = _G.ShadowUF
    if not SUF then return false end
    if not SUF.db then return false end
    return true, SUF
end

------------------------------------------------------------------------
-- Get the statusbar texture SUF is currently using.
-- SUF resolves and caches the texture via LibSharedMedia into
-- ShadowUF.Layout.mediaPath.statusbar — read it directly rather than
-- doing our own LSM lookup which may race against SUF's init.
------------------------------------------------------------------------
function HP.GetSUFMedia()
    local hasSUF, SUF = HP.DetectSUF()
    if not hasSUF then return nil end

    local texture = "Interface/TargetingFrame/UI-TargetingFrame-BarFill"

    if SUF.Layout and SUF.Layout.mediaPath and SUF.Layout.mediaPath.statusbar then
        texture = SUF.Layout.mediaPath.statusbar
    end

    return { statusBar = texture }
end

------------------------------------------------------------------------
-- Get SUF Unit Frames
-- SUF tracks every active unit frame in ShadowUF.Units.unitFrames,
-- keyed by unit-id string ("player", "party1", "raid5", etc.).
-- Header-driven frames (party/raid/arena/boss) are NOT registered as
-- globals like "SUFUnitparty1" — only solo frames such as
-- "SUFUnitplayer" are globals.
------------------------------------------------------------------------
function HP.GetSUFFrames()
    local hasSUF, SUF = HP.DetectSUF()
    if not hasSUF then return nil end

    local unitFrames = SUF.Units and SUF.Units.unitFrames
    if not unitFrames then return nil end

    local frames = {}

    -- Single unit frames (also available as globals, but unitFrames is canonical)
    local singleUnits = { "player", "target", "targettarget", "focus", "pet" }
    for _, unitType in ipairs(singleUnits) do
        local frame = unitFrames[unitType] or _G["SUFUnit" .. unitType]
        if frame and frame.healthBar then
            frames[unitType] = { frame = frame, type = unitType, unit = unitType }
        end
    end

    -- Party frames: party1 – party5
    frames.party = {}
    for i = 1, 5 do
        local frame = unitFrames["party" .. i]
        if frame and frame.healthBar then
            tinsert(frames.party, {
                frame = frame,
                type  = "party",
                unit  = "party" .. i,
                index = i,
            })
        end
    end

    -- Party pet frames: partypet1 – partypet5
    frames.partypet = {}
    for i = 1, 5 do
        local frame = unitFrames["partypet" .. i]
        if frame and frame.healthBar then
            tinsert(frames.partypet, {
                frame = frame,
                type  = "partypet",
                unit  = "partypet" .. i,
                index = i,
            })
        end
    end

    -- Raid frames: raid1 – raid40
    frames.raid = {}
    for i = 1, 40 do
        local frame = unitFrames["raid" .. i]
        if frame and frame.healthBar then
            tinsert(frames.raid, {
                frame = frame,
                type  = "raid",
                unit  = "raid" .. i,
                index = i,
            })
        end
    end

    -- Raid pet frames: raidpet1 – raidpet40
    frames.raidpet = {}
    for i = 1, 40 do
        local frame = unitFrames["raidpet" .. i]
        if frame and frame.healthBar then
            tinsert(frames.raidpet, {
                frame = frame,
                type  = "raidpet",
                unit  = "raidpet" .. i,
                index = i,
            })
        end
    end

    -- Arena frames: arena1 – arena5
    frames.arena = {}
    for i = 1, 5 do
        local frame = unitFrames["arena" .. i]
        if frame and frame.healthBar then
            tinsert(frames.arena, {
                frame = frame,
                type  = "arena",
                unit  = "arena" .. i,
                index = i,
            })
        end
    end

    -- Arena pet frames: arenapet1 – arenapet5
    frames.arenapet = {}
    for i = 1, 5 do
        local frame = unitFrames["arenapet" .. i]
        if frame and frame.healthBar then
            tinsert(frames.arenapet, {
                frame = frame,
                type  = "arenapet",
                unit  = "arenapet" .. i,
                index = i,
            })
        end
    end

    -- Boss frames: boss1 – boss4
    frames.boss = {}
    for i = 1, 4 do
        local frame = unitFrames["boss" .. i]
        if frame and frame.healthBar then
            tinsert(frames.boss, {
                frame = frame,
                type  = "boss",
                unit  = "boss" .. i,
                index = i,
            })
        end
    end

    return frames
end

------------------------------------------------------------------------
-- Setup HealPrediction on a SUF Frame
------------------------------------------------------------------------
function HP.SetupSUFFrame(frameInfo)
    if not frameInfo or not frameInfo.frame then return end

    local sufFrame = frameInfo.frame
    if not sufFrame.healthBar then return end

    -- Already set up?
    if HP.frameData[sufFrame] then return end

    local hb   = sufFrame.healthBar
    local unit = frameInfo.unit

    local media   = HP.GetSUFMedia()
    local texture = (media and media.statusBar)
                 or "Interface/TargetingFrame/UI-TargetingFrame-BarFill"

    -- Cache the StatusBar fill texture — we anchor prediction bars to it
    -- so they match the visible fill height, not the StatusBar frame
    -- (which may be taller if borders/padding are present).
    local fillTex = hb:GetStatusBarTexture()

    local fd = {
        hb       = hb,
        fillTex  = fillTex,
        usesGradient = false,
        bars     = {},
        _isSUF   = true,
        _sufType = frameInfo.type,
        unit     = unit,
        texture  = texture,
    }

    -- Overlay parented to the health bar so it moves/resizes with it.
    -- Frame level must be above the health bar to guarantee visibility.
    local overlay = CreateFrame("Frame", nil, hb)
    overlay:SetAllPoints(hb)
    overlay:SetFrameLevel(hb:GetFrameLevel() + 1)
    fd.overlay = overlay

    -- Bar texture: when useRaidTexture is enabled, use the selected
    -- statusbar texture for a textured look.  When disabled, use solid
    -- white so SetVertexColor produces exact configured colors.
    local function ApplyBarTexture(tex)
        if Settings.useRaidTexture then
            tex:SetTexture(Settings.useRaidTexture
                and "Interface\\RaidFrame\\Raid-Bar-Hp-Fill"
                or  "Interface\\TargetingFrame\\UI-StatusBar")
        else
            tex:SetColorTexture(1, 1, 1)
        end
    end

    -- Four prediction bar textures on the overlay
    for idx = 1, 4 do
        local tex = overlay:CreateTexture(nil, "BORDER", nil, 5)
        ApplyBarTexture(tex)
        tex:ClearAllPoints()
        tex:Hide()
        fd.bars[idx] = tex
    end

    -- Shield glow texture
    fd.shieldTex = CreateShieldTex(overlay)

    -- Overheal bar: shows heal amount that would exceed max health.
    -- Sublevel 4 (below prediction bars at 5) so prediction colors
    -- show through — the overheal bar only peeks out at edges/gaps.
    local overhealBar = overlay:CreateTexture(nil, "BORDER", nil, 4)
    ApplyBarTexture(overhealBar)
    overhealBar:Hide()
    fd.overhealBar = overhealBar

    -- Absorb bar: shows shield/absorb amount eating into the health fill
    local absorbBar = overlay:CreateTexture(nil, "BORDER", nil, 6)
    ApplyBarTexture(absorbBar)
    absorbBar:Hide()
    fd.absorbBar = absorbBar

    -- Health deficit text
    local deficitText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    deficitText:SetPoint("RIGHT", fd.hb, "RIGHT", -2 + (Settings.deficitOffsetX or 0), Settings.deficitOffsetY or 0)
    deficitText:SetJustifyH("RIGHT")
    deficitText:Hide()
    fd.deficitText = deficitText

    -- Shield text (abbreviated spell name)
    local shieldText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    shieldText:SetPoint("LEFT", fd.hb, "LEFT", 2, 0)
    shieldText:SetJustifyH("LEFT")
    shieldText:Hide()
    fd.shieldText = shieldText

    -- Healer count text (position configurable)
    local healerCountText = overlay:CreateFontString(nil, "OVERLAY")
    healerCountText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    ApplyTextAnchor(healerCountText, fd.hb, HEALER_COUNT_ANCHORS, Settings.healerCountPos, Settings.healerCountOffsetX, Settings.healerCountOffsetY)
    healerCountText:Hide()
    fd.healerCountText = healerCountText

    -- Trajectory marker (2px vertical line)
    local trajMarker = overlay:CreateTexture(nil, "OVERLAY", nil, 3)
    trajMarker:SetColorTexture(1, 1, 0, 0.7)
    trajMarker:SetWidth(2)
    trajMarker:Hide()
    fd.trajectoryMarker = trajMarker

    -- Indicator overlay frame: render above health bar to guarantee visibility
    local indicatorOverlay = CreateFrame("Frame", nil, sufFrame)
    indicatorOverlay:SetAllPoints(sufFrame)
    local hbLevel = fd.hb and fd.hb:GetFrameLevel() or sufFrame:GetFrameLevel()
    indicatorOverlay:SetFrameLevel(hbLevel + 2)
    fd.indicatorOverlay = indicatorOverlay

    -- AoE advisor border (4-edge strips on overlay)
    local aoeBorder = CreateFrame("Frame", nil, indicatorOverlay)
    aoeBorder:SetAllPoints(sufFrame)
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
    snipeFlash:SetAllPoints(sufFrame)
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
    fd.effects.hotExpiry = CreateIndicatorEffect(indicatorOverlay, sufFrame, "OVERLAY", 4, false, sufFrame)
    fd.hotExpiryBorder = fd.effects.hotExpiry.border

    fd.effects.dispel = CreateIndicatorEffect(indicatorOverlay, fd.hb or sufFrame, "OVERLAY", 3, false, sufFrame)
    fd.dispelOverlay = fd.effects.dispel.border

    -- Res tracker text (on overlay so it renders above health bar too)
    local resText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
    resText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    resText:SetText("|cff44ff44RES|r")
    if fd.hb then resText:SetPoint("CENTER", fd.hb, "CENTER", Settings.resOffsetX or 0, Settings.resOffsetY or 0) end
    resText:Hide()
    fd.resText = resText

    fd.effects.cluster = CreateIndicatorEffect(indicatorOverlay, sufFrame, "OVERLAY", 3, false, sufFrame)
    fd.clusterBorder = fd.effects.cluster.border

    fd.effects.healReduc = CreateIndicatorEffect(indicatorOverlay, sufFrame, "OVERLAY", 4, false, sufFrame)
    fd.healReducGlow = fd.effects.healReduc.border

    -- Defensive cooldown indicator effect (for border display mode)
    fd.effects.defensive = CreateIndicatorEffect(indicatorOverlay, sufFrame, "OVERLAY", 5, false, sufFrame)

    -- Charmed/Mind-controlled indicator effect
    fd.effects.charmed = CreateIndicatorEffect(indicatorOverlay, sufFrame, "OVERLAY", 6, false, sufFrame)
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
    deathPredText:SetPoint("CENTER", fd.hb or sufFrame, "CENTER", Settings.deathPredOffsetX or 0, Settings.deathPredOffsetY or 0)
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
    defensiveText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
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

    -- Incoming heal text
    local healText = overlay:CreateFontString(nil, "OVERLAY")
    healText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    if fd.hb then
        ApplyTextAnchor(healText, fd.hb, HEAL_TEXT_ANCHORS, Settings.healTextPos, Settings.healTextOffsetX, Settings.healTextOffsetY)
    end
    healText:Hide()
    fd.healText = healText

    if fd.hb then
        fd._hbWidth = fd.hb:GetWidth()
        fd.hb:HookScript("OnSizeChanged", function(_, w)
            fd._hbWidth = w
        end)
    end

    HP.frameData[sufFrame] = fd

    -- Hook the health bar's value changes for immediate response.
    -- The 0.05-second ticker also drives updates, so this is supplementary.
    hb:HookScript("OnValueChanged", function()
        HP.UpdateSUFFrame(sufFrame)
    end)

    return fd
end

------------------------------------------------------------------------
-- Position a single prediction bar (mirrors PositionBarAbs in Render.lua)
-- Anchors vertically to the fill texture (anchor) so bars match the
-- visible fill height, not the StatusBar frame which may include padding.
-- Horizontal offset is relative to the StatusBar frame (hb) since the
-- fill texture stretches horizontally with the value.
------------------------------------------------------------------------
local function PositionSUFBar(bar, anchor, hb, startPx, size)
    if size <= 0 then bar:Hide(); return startPx end
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT",    anchor, "TOPLEFT",    startPx, 0)
    bar:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", startPx, 0)
    bar:SetWidth(mathmax(size, 1))
    bar:Show()
    return startPx + size
end

-- Reversed variant: bars grow leftward from the health endpoint.
local function PositionSUFBarReversed(bar, anchor, hb, startPx, size, barW)
    if size <= 0 then bar:Hide(); return startPx end
    bar:ClearAllPoints()
    bar:SetPoint("TOPRIGHT",    anchor, "TOPRIGHT",    -startPx, 0)
    bar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -startPx, 0)
    bar:SetWidth(mathmax(size, 1))
    bar:Show()
    return startPx + size
end

------------------------------------------------------------------------
-- Hide all SUF extras (visibility gate helper)
------------------------------------------------------------------------
local function HideAllSUFExtras(fd)
    if fd.bars then
        for idx = 1, 4 do if fd.bars[idx] then fd.bars[idx]:Hide() end end
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
    if fd.hotDots then for di = 1, 5 do if fd.hotDots[di] then pcall(function() fd.hotDots[di]:Hide() end) end end end
    if fd.hotDotsOther then for di = 1, 5 do if fd.hotDotsOther[di] then pcall(function() fd.hotDotsOther[di]:Hide() end) end end end
    if fd.manaWarnText    then fd.manaWarnText:Hide() end
    if fd.healText        then fd.healText:Hide() end
    if fd.deathPredText   then fd.deathPredText:Hide() end
end

------------------------------------------------------------------------
-- Update HealPrediction on a SUF Frame
-- Mirrors the overflow / clamping logic from RenderPrediction so that
-- heal bars extend past the health bar edge up to the configured cap.
------------------------------------------------------------------------
function HP.UpdateSUFFrame(sufFrame)
    local fd = HP.frameData[sufFrame]
    if not fd or not fd._isSUF then return end

    local hb = fd.hb
    if not hb then return end

    -- Visibility gate: respect showOnParty for party/raid SUF frames
    local sufType = fd._sufType
    if (sufType == "party" or sufType == "raid") and not Settings.showOnParty then
        HideAllSUFExtras(fd)
        return
    end

    -- Anchor for vertical alignment: use the fill texture so bars match
    -- the visible fill height, falling back to the StatusBar frame.
    local anchor = fd.fillTex or hb

    -- Prefer the frame's live unit attribute; fall back to the stored unit.
    local unit = sufFrame.unit or fd.unit
    if not unit or not UnitExists(unit) then
        HideAllSUFExtras(fd)
        return
    end

    local _, cap = hb:GetMinMaxValues()
    local hp     = hb:GetValue()
    local barW   = hb:GetWidth()

    if not cap or cap <= 0 or barW <= 0 then
        HideAllSUFExtras(fd)
        return
    end

    -- Read orientation and fill direction from the actual health bar — this
    -- is the authoritative source (matches how incheal.lua reads it).
    local isVertical = hb:GetOrientation() == "VERTICAL"
    local isReversed = hb:GetReverseFill()

    -- Overflow cap: how far past 100% the bars may extend.
    -- Pick the right setting per frame type, matching the core renderer.
    local overflowCap
    if sufType == "party" then
        overflowCap = 1.0 + (Settings.usePartyOverflow and Settings.partyOverflow or 0)
    elseif sufType == "raid" then
        overflowCap = 1.0 + (Settings.useRaidOverflow and Settings.raidOverflow or 0)
    else
        overflowCap = 1.0 + (Settings.useUnitOverflow and Settings.unitOverflow or 0)
    end

    -- Get heal amounts from HealPredict's engine (HealComm protocol)
    local my1, my2, ot1, ot2
    if Settings.smartOrdering and HP.GetHealsSorted then
        my1, my2, ot1, ot2 = HP.GetHealsSorted(unit)
    elseif HP.GetHeals then
        my1, my2, ot1, ot2 = HP.GetHeals(unit)
    else
        return
    end

    local isSorted = Settings.smartOrdering

    -- Supplement with the native WoW API for heals from OTHER players
    -- who aren't running HealPredict.  Only compare the OTHER-heal
    -- portion — self heals can differ between API and Engine due to
    -- spell power / modifier calculation differences, and supplementing
    -- that difference would create a phantom extra bar.
    if UnitGetIncomingHeals then
        local apiTotal = UnitGetIncomingHeals(unit) or 0
        local apiSelf  = UnitGetIncomingHeals(unit, "player") or 0
        local apiOther = apiTotal - apiSelf
        local engineOther = ot1 + ot2
        if isSorted then
            -- In sorted mode my1 is otherBefore (not "my" heals).
            -- Include it so engine-tracked heals aren't double-counted.
            engineOther = engineOther + my1
        end
        if apiOther > engineOther then
            ot1 = ot1 + (apiOther - engineOther)
        end
    end

    -- Pick the correct color palette per frame type.
    -- SUF party/raid use the "raid" (compact) palette; single-unit frames
    -- use the "unit" palette.  Matches Core/Render.lua.
    local isCompact = (sufType == "party" or sufType == "raid")
    local pal, palOH
    if isCompact then
        if isSorted then
            -- Sorted slots are by timing (before/after), not heal type.
            -- Slot 3 is other-direct heals landing after ours, not HoTs,
            -- so use raidOtherDirect for both other-heal slots.
            pal   = { "raidOtherDirect", "raidMyDirect", "raidOtherDirect", "raidMyHoT" }
            palOH = { "raidOtherDirectOH", "raidMyDirectOH", "raidOtherDirectOH", "raidMyHoTOH" }
        else
            pal   = { "raidMyDirect", "raidMyHoT", "raidOtherDirect", "raidOtherHoT" }
            palOH = { "raidMyDirectOH", "raidMyHoTOH", "raidOtherDirectOH", "raidOtherHoTOH" }
        end
    else
        if isSorted then
            pal   = { "unitOtherDirect", "unitMyDirect", "unitOtherDirect", "unitMyHoT" }
            palOH = { "unitOtherDirectOH", "unitMyDirectOH", "unitOtherDirectOH", "unitMyHoTOH" }
        else
            pal   = { "unitMyDirect", "unitMyHoT", "unitOtherDirect", "unitOtherHoT" }
            palOH = { "unitMyDirectOH", "unitMyHoTOH", "unitOtherDirectOH", "unitOtherHoTOH" }
        end
    end

    local colors  = Settings.colors
    local opaMul  = Settings.barOpacity
    local dimFactor = (isSorted and Settings.dimNonImminent) and 0.6
                   or ((not isSorted and Settings.dimNonImminent and Settings.useTimeLimit) and 0.6 or 1.0)

    local amounts = { my1, my2, ot1, ot2 }

    -- Class-colored bars: each bar gets the caster's class color.
    -- Only available in sorted mode, matching the core renderer.
    local useClassColors = Settings.smartOrderingClassColors and isSorted and unit
    if useClassColors and Engine and Engine.GetHealAmountByCaster then
        local guid = UnitGUID(unit)
        if guid then
            local casterHeals = Engine:GetHealAmountByCaster(guid, Engine.ALL_HEALS)
            local casterCount = casterHeals and #casterHeals or 0
            local origTotal = my1 + my2 + ot1 + ot2

            for idx = casterCount + 1, 4 do
                if fd.bars[idx] then fd.bars[idx]:Hide() end
                amounts[idx] = 0
            end

            local assignedTotal = 0
            for idx, healInfo in ipairs(casterHeals) do
                if idx > 4 then break end
                local bar = fd.bars[idx]
                if bar then
                    local r, g, b = GetClassColor(healInfo.caster)
                    local aDim = healInfo.isSelf and 1.0 or dimFactor
                    bar:SetVertexColor(r, g, b, opaMul * aDim)
                    local amt = healInfo.amount or 0
                    amt = mathmin(amt, mathmax(origTotal - assignedTotal, 0))
                    amounts[idx] = amt
                    assignedTotal = assignedTotal + amt
                end
            end

            -- Fill remaining bars with API-only healers (not tracked by
            -- HealComm).  Scan group members to find who else is healing
            -- this target so we can show their class color.
            if casterCount < 4 and UnitGetIncomingHeals and assignedTotal < origTotal then
                local nextIdx = casterCount + 1
                local engineGUIDs = {}
                for _, hi in ipairs(casterHeals) do
                    engineGUIDs[hi.caster] = true
                end

                local memberCount = GetNumGroupMembers() or 0
                local prefix = IsInRaid() and "raid" or "party"
                for i = 1, memberCount do
                    if nextIdx > 4 then break end
                    local mUnit = prefix .. i
                    local mGUID = UnitGUID(mUnit)
                    if mGUID and not engineGUIDs[mGUID] then
                        local mHeal = UnitGetIncomingHeals(unit, mUnit)
                        if mHeal and mHeal > 0 then
                            local bar = fd.bars[nextIdx]
                            if bar then
                                local r, g, b = GetClassColor(mGUID)
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

            my1, my2, ot1, ot2 = amounts[1], amounts[2], amounts[3], amounts[4]
        end
    end

    -- Standard palette coloring (when not using class colors)
    if not useClassColors then
        local activePal = pal
        local overhealing = cap <= 0 and 0 or mathmax((hp + my1 + my2 + ot1 + ot2) / cap - 1, 0)
        if Settings.useOverhealColors and overhealing >= (Settings.overhealThreshold or 0) then
            activePal = palOH
        end

        -- When overhealing, skip the dim factor so bars in the overflow
        -- region maintain consistent opacity (HoT palette colors already
        -- have reduced alpha which, combined with dimming, makes the
        -- overflow portion nearly invisible against the frame background).
        local isOverhealing = overhealing > 0

        for idx = 1, 4 do
            local cData = colors and colors[activePal[idx]]
            if cData and fd.bars[idx] then
                local aDim = 1.0
                if not isOverhealing then
                    if isSorted then
                        aDim = (idx == 3 or idx == 4) and dimFactor or 1.0
                    else
                        aDim = (idx == 2 or idx == 4) and dimFactor or 1.0
                    end
                end
                fd.bars[idx]:SetVertexColor(cData[1], cData[2], cData[3], cData[4] * opaMul * aDim)
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Clamp heal amounts at the HP level (not the pixel level) so bars
    -- can extend past the health bar edge up to overflowCap.
    -- This mirrors the logic in RenderPrediction exactly.
    -- ----------------------------------------------------------------
    local rawTotal
    local bars = fd.bars

    if useClassColors then
        -- Class color mode: amounts[] was already filled per-caster.
        -- Just clamp the total and distribute proportionally.
        rawTotal = (amounts[1] or 0) + (amounts[2] or 0) + (amounts[3] or 0) + (amounts[4] or 0)
        local totalAll = mathmin(rawTotal, cap * overflowCap - hp)
        totalAll = mathmax(totalAll, 0)

        local remain = totalAll
        for idx = 1, 4 do
            local a = amounts[idx] or 0
            a = mathmin(a, remain)
            amounts[idx] = a
            remain = remain - a
        end

    elseif isSorted then
        rawTotal = my1 + my2 + ot1 + ot2
        local totalAll = rawTotal
        totalAll = mathmin(totalAll, cap * overflowCap - hp)
        totalAll = mathmax(totalAll, 0)

        local remain = totalAll
        my1 = mathmin(my1, remain); remain = remain - my1
        my2 = mathmin(my2, remain); remain = remain - my2
        ot1 = mathmin(ot1, remain); remain = remain - ot1
        ot2 = remain

    else
        local total1, total2
        if Settings.overlayMode then
            total1 = mathmax(my1, ot1)
            total2 = mathmax(my2, ot2)
        else
            total1 = my1 + ot1
            total2 = my2 + ot2
        end

        rawTotal = total1 + total2
        local totalAll = rawTotal
        totalAll = mathmin(totalAll, cap * overflowCap - hp)
        totalAll = mathmax(totalAll, 0)

        total1 = mathmin(total1, totalAll)
        total2 = totalAll - total1
        my1 = mathmin(my1, total1)
        my2 = mathmin(my2, total2)
        ot1 = total1 - my1
        ot2 = total2 - my2
    end

    -- ----------------------------------------------------------------
    -- Position bars using the SAME bar-to-amount mapping as the core
    -- renderer.  Each bar[N] keeps its palette color; the render order
    -- determines stacking.  This is critical: the core renderer does
    -- NOT iterate bars sequentially — it maps specific bars to specific
    -- amounts so colors stay correct.
    --
    -- Sorted:     bars[1]=my1, bars[2]=my2, bars[3]=ot1, bars[4]=ot2
    -- Non-sorted: bars[1]=my1, bars[3]=ot1, bars[2]=my2, bars[4]=ot2
    -- Class:      bars[1..4] = amounts[1..4] (sequential per-caster)
    -- ----------------------------------------------------------------
    local renderOrder  -- { {bar, amount}, ... } in stacking order
    if useClassColors then
        renderOrder = {
            { bars[1], amounts[1] or 0 },
            { bars[2], amounts[2] or 0 },
            { bars[3], amounts[3] or 0 },
            { bars[4], amounts[4] or 0 },
        }
    elseif isSorted then
        renderOrder = {
            { bars[1], my1 },
            { bars[2], my2 },
            { bars[3], ot1 },
            { bars[4], ot2 },
        }
    else
        renderOrder = {
            { bars[1], my1 },
            { bars[3], ot1 },
            { bars[2], my2 },
            { bars[4], ot2 },
        }
    end

    -- curPx tracks the pixel endpoint of all prediction bars (used by
    -- the overheal bar to know exactly how far the bars extend).
    local curPx = 0
    local barSize = barW  -- reference dimension (barW for horizontal, barH for vertical)

    if isVertical then
        local barH = hb:GetHeight()
        if barH <= 0 then
            for idx = 1, 4 do if bars[idx] then bars[idx]:Hide() end end
            return
        end
        barSize = barH
        local healthPx = (hp / cap) * barH
        curPx = healthPx

        for _, entry in ipairs(renderOrder) do
            local bar, amount = entry[1], entry[2]
            if not bar then break end

            if amount > 0 then
                local size = (amount / cap) * barH
                bar:ClearAllPoints()
                if isReversed then
                    bar:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, -curPx)
                    bar:SetPoint("TOPLEFT",  anchor, "TOPLEFT",  0, -curPx)
                else
                    bar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, curPx)
                    bar:SetPoint("BOTTOMLEFT",  anchor, "BOTTOMLEFT",  0, curPx)
                end
                bar:SetHeight(mathmax(size, 1))
                bar:Show()
                curPx = curPx + size
            else
                bar:Hide()
            end
        end

    else
        -- Horizontal (the common case)
        local healthPx = (hp / cap) * barW
        curPx = healthPx

        for _, entry in ipairs(renderOrder) do
            local bar, amount = entry[1], entry[2]
            if not bar then break end

            if amount > 0 then
                local size = (amount / cap) * barW
                if isReversed then
                    curPx = PositionSUFBarReversed(bar, anchor, hb, curPx, size, barW)
                else
                    curPx = PositionSUFBar(bar, anchor, hb, curPx, size)
                end
            else
                bar:Hide()
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Overheal bar — shows heal amount that would exceed max health.
    -- Positioned at the far edge of the health bar, extending outward.
    -- Width is derived from curPx (the actual pixel endpoint of the
    -- prediction bars) so it exactly covers the overflow region.
    -- ----------------------------------------------------------------
    if fd.overhealBar then
        if Settings.showOverhealBar and cap > 0 and barW > 0 then
            local rawOverheal = mathmax(hp + rawTotal - cap, 0)
            -- ohWidth = how far prediction bars actually extend past the
            -- bar edge, derived from the pixel endpoint of the bars.
            local ohWidth = mathmax(curPx - barSize, 0)
            -- Only show the overheal bar when prediction bars do NOT
            -- already cover the overflow region.  When they do, the
            -- overheal bar is redundant and bleeds through dimmed bars.
            local predictionCoversOverflow = (curPx > barSize + 0.5)
            if rawOverheal > 0 and ohWidth > 0 and not predictionCoversOverflow then
                local cData = colors and colors.overhealBar
                if cData then
                    if Settings.overhealGradient and HP.OVERHEAL_GRAD then
                        -- Gradient COLOR uses unclamped overheal normalized
                        -- to the overflow range so the full green-orange-red
                        -- spectrum is visible within the configured cap.
                        local overflowRange = cap * (overflowCap - 1.0)
                        local ovhPct = overflowRange > 0
                            and mathmin(rawOverheal / overflowRange, 1)
                            or 1
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
                    else
                        fd.overhealBar:SetVertexColor(cData[1], cData[2], cData[3], cData[4] * opaMul)
                    end
                    -- Position at the BAR EDGE (100% health), not at the
                    -- fill texture edge.  Vertical alignment from anchor,
                    -- horizontal position from hb at barW offset — matches
                    -- the core renderer's approach.
                    fd.overhealBar:ClearAllPoints()
                    if isVertical then
                        local barH = hb:GetHeight()
                        if isReversed then
                            fd.overhealBar:SetPoint("TOPLEFT",  anchor, "TOPLEFT",  0, 0)
                            fd.overhealBar:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
                        else
                            fd.overhealBar:SetPoint("BOTTOMLEFT",  anchor, "BOTTOMLEFT",  0, barH)
                            fd.overhealBar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, barH)
                        end
                        fd.overhealBar:SetHeight(mathmax(ohWidth, 1))
                    else
                        if isReversed then
                            fd.overhealBar:SetPoint("TOPRIGHT",    anchor, "TOPRIGHT",    -barW, 0)
                            fd.overhealBar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -barW, 0)
                        else
                            fd.overhealBar:SetPoint("TOPLEFT",    anchor, "TOPLEFT",    barW, 0)
                            fd.overhealBar:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", barW, 0)
                        end
                        fd.overhealBar:SetWidth(mathmax(ohWidth, 1))
                    end
                    fd.overhealBar:Show()
                else
                    fd.overhealBar:Hide()
                end
            else
                fd.overhealBar:Hide()
            end
        else
            fd.overhealBar:Hide()
        end
    end

    -- ----------------------------------------------------------------
    -- Absorb bar — shows shield amount eating into the health fill.
    -- Positioned at the left edge of the health endpoint, growing inward.
    -- ----------------------------------------------------------------
    local guid = unit and UnitGUID(unit)
    if fd.absorbBar then
        local showAbsorb = Settings.showAbsorbBar and guid and HP.shieldGUIDs and HP.shieldGUIDs[guid]
        if showAbsorb and cap > 0 and barW > 0 then
            local absorbAmt = HP.shieldAmounts and HP.shieldAmounts[guid]
            local absorbWidth
            if absorbAmt and absorbAmt > 0 then
                absorbWidth = mathmax((absorbAmt / cap) * barW, 2)
            else
                absorbWidth = mathmax(barW * 0.05, 4)
            end
            local healthPx = (hp / cap) * barW
            absorbWidth = mathmin(absorbWidth, healthPx)
            if absorbWidth >= 1 then
                local absorbStart = healthPx - absorbWidth
                local cData = colors and colors.absorbBar
                if cData then
                    fd.absorbBar:SetVertexColor(cData[1], cData[2], cData[3], cData[4] * opaMul)
                    fd.absorbBar:ClearAllPoints()
                    fd.absorbBar:SetPoint("TOPLEFT",    anchor, "TOPLEFT",    absorbStart, 0)
                    fd.absorbBar:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", absorbStart, 0)
                    fd.absorbBar:SetWidth(absorbWidth)
                    fd.absorbBar:Show()
                else
                    fd.absorbBar:Hide()
                end
            else
                fd.absorbBar:Hide()
            end
        else
            fd.absorbBar:Hide()
        end
    end

    -- ================================================================
    -- INDICATOR / VISUAL FEATURES
    -- Mirrors UpdateCompact logic from Render.lua
    -- ================================================================

    -- Shield glow
    if fd.shieldTex then
        local showShield = Settings.showShieldGlow and guid and HP.shieldGUIDs[guid]
        if showShield then
            if cap > 0 and barW > 0 then
                local healthPx = (hp / cap) * barW
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

    -- Shield text (abbreviated spell name)
    if fd.shieldText then
        if Settings.showShieldText and guid and HP.shieldGUIDs[guid] then
            local abbr = SHIELD_NAMES[HP.shieldGUIDs[guid]]
            if abbr then
                fd.shieldText:SetText("|cff88bbff" .. abbr .. "|r")
                fd.shieldText:ClearAllPoints()
                if isCompact then
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

    -- Health deficit text
    if fd.deficitText then
        if Settings.showHealthDeficit then
            if hb then
                local deficit = (cap and cap > 0) and (cap - (hp + (rawTotal or 0))) or 0
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
    if fd.healerCountText then
        if Settings.healerCount then
            local hCount = guid and Engine:GetActiveCasterCount(guid) or 0
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

    -- Health trajectory marker
    if fd.trajectoryMarker then
        local showTrajectory = Settings.healthTrajectory and cap > 0 and barW > 0 and guid
        if showTrajectory then
            local dps = guid and HP.GetDamageRate(guid) or 0
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

    -- AoE advisor border
    if fd.aoeBorder then
        if Settings.aoeAdvisor then
            local showAoE = (guid and HP.aoeTargetGUID == guid)
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
            if Engine.ticking then
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
        if Settings.dispelHighlight and guid and HP.dispelGUIDs[guid] then
            local dType = HP.dispelGUIDs[guid]
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
        else
            HideIndicator(fd, "dispel")
            fd._dispelSounded = nil
        end
    end

    -- Res tracker
    if fd.resText then
        if Settings.resTracker then
            local showRes = (guid and HP.resTargets[guid])
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
        if Settings.cdTracker and guid and HP.cdGUIDs[guid] then
            fd.cdText:SetText(HP.cdGUIDs[guid])
            fd.cdText:Show()
        else
            fd.cdText:Hide()
        end
    end

    -- HoT tracker dots (your own HoTs) - 5 individual HoT types
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
            if isIconMode and HP.UpdateHoTCooldown then
                HP.UpdateHoTCooldown(fd, guid, false)
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
            if isIconMode and HP.UpdateHoTCooldown then
                HP.UpdateHoTCooldown(fd, guid, true)
            end
        else
            for di = 1, 5 do
                if fd.hotDotsOther[di] then
                    pcall(function() fd.hotDotsOther[di]:Hide() end)
                end
            end
        end
    end

    -- Low mana warning — healer class cache
    if not fd._classChecked and unit then
        local _, cls = UnitClass(unit)
        fd._isHealer = cls and HEALER_CLASSES[cls] or false
        fd._classChecked = true
    end

    if fd.manaWarnText then
        if Settings.lowManaWarning and fd._isHealer and unit then
            -- Poll mana every update (ticker runs at 20fps; text changes
            -- are cheap so no need for a separate 2s timer like compact frames)
            local mana = UnitPower(unit, 0)
            local maxMana = UnitPowerMax(unit, 0)
            if maxMana and maxMana > 0 then
                local threshold = Settings.lowManaThreshold or 20
                local pct = mathfloor(mana / maxMana * 100)
                if pct <= threshold then
                    fd.manaWarnText:SetText("|cff6699ff" .. pct .. "%|r")
                    fd.manaWarnText:Show()
                else
                    fd.manaWarnText:Hide()
                end
            else
                fd.manaWarnText:Hide()
            end
        else
            fd.manaWarnText:Hide()
        end
    end

    -- Defensive cooldown display (icon/text + optional border effect)
    local displayMode = Settings.defensiveDisplayMode or 3
    local borderStyle = Settings.defensiveStyle or 3 -- 1=No effect, 2=Static, 3=Glow, 4=Spinning, 5=Slashes

    -- Border effect (separate from icon/text display)
    if borderStyle > 1 and fd.effects and fd.effects.defensive then
        local hasDef = Settings.showDefensives and guid and HP.defenseGUIDs[guid]

        if hasDef then
            local def = HP.defenseGUIDs[guid]

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
                ShowIndicator(fd, "defensive", indicatorStyle, {r, g, b})
            else
                HideIndicator(fd, "defensive")
            end
        else
            HideIndicator(fd, "defensive")
        end
    else
        HideIndicator(fd, "defensive")
    end

    -- Icon/text container mode
    if fd.defensiveContainer and fd.defensiveIcon and fd.defensiveText then
        if Settings.showDefensives and guid then
            local def = HP.defenseGUIDs[guid]

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
    -- Note: HP.charmedGUIDs is populated by ScanAuras which is gated
    -- behind other settings in UNIT_AURA.  We check UnitIsCharmed
    -- directly as a fallback so charmed detection always works on SUF
    -- frames regardless of which other features are enabled.
    if fd.effects and fd.effects.charmed then
        if Settings.showCharmed and unit then
            local showCharmed = (guid and HP.charmedGUIDs[guid])
                             or UnitIsCharmed(unit)

            if showCharmed then
                local c = Settings.colors.charmed
                ShowIndicator(fd, "charmed", Settings.charmedStyle or 3, c)
            else
                HideIndicator(fd, "charmed")
            end
        else
            HideIndicator(fd, "charmed")
        end
    end

    -- Death prediction warning
    if Settings.deathPrediction then
        if guid then
            HP.UpdateDeathPrediction(sufFrame, fd, guid)
        end
    elseif not Settings.deathPrediction then
        if fd.deathPredText then
            fd.deathPredText:Hide()
        end
    end

    -- Incoming heal text (hold-max display)
    if fd.healText then
        if Settings.showHealText then
            local totalHeals = (rawTotal or 0)
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

------------------------------------------------------------------------
-- Initialize SUF Compatibility
------------------------------------------------------------------------
function HP.InitSUFCompat()
    local hasSUF, SUF = HP.DetectSUF()
    if not hasSUF then return false end

    print("|cff33ccffHealPredict:|r Initializing SUF compatibility...")

    local frameList = HP.GetSUFFrames()
    if not frameList then
        print("|cff33ccffHealPredict:|r |cffff4440Could not find SUF frames|r")
        return false
    end

    local setupCount = 0

    local singleTypes = { "player", "target", "targettarget", "focus", "pet" }
    for _, unitType in ipairs(singleTypes) do
        if frameList[unitType] then
            HP.SetupSUFFrame(frameList[unitType])
            setupCount = setupCount + 1
        end
    end

    local groupTypes = { "party", "partypet", "raid", "raidpet", "arena", "arenapet", "boss" }
    for _, groupType in ipairs(groupTypes) do
        if frameList[groupType] then
            for _, frameInfo in ipairs(frameList[groupType]) do
                HP.SetupSUFFrame(frameInfo)
                setupCount = setupCount + 1
            end
        end
    end

    -- Hook RefreshAll: when colors or settings change at runtime, also
    -- update SUF frames immediately so the new values are visible.
    if HP.RefreshAll then
        local origRefreshAll = HP.RefreshAll
        HP.RefreshAll = function(...)
            origRefreshAll(...)
            HP.UpdateAllSUFFrames()
        end
    end

    -- Hook RefreshBarTextures: when toggled at runtime, re-apply the
    -- correct texture mode (solid color vs statusbar) to SUF bars.
    if HP.RefreshBarTextures then
        local origRefresh = HP.RefreshBarTextures
        HP.RefreshBarTextures = function(...)
            origRefresh(...)
            local texPath = Settings.useRaidTexture
                and "Interface\\RaidFrame\\Raid-Bar-Hp-Fill"
                or nil
            for frame, fd in pairs(HP.frameData) do
                if fd._isSUF then
                    local apply = function(tex)
                        if texPath then
                            tex:SetTexture(texPath)
                        else
                            tex:SetColorTexture(1, 1, 1)
                        end
                    end
                    for idx = 1, 4 do
                        if fd.bars[idx] then apply(fd.bars[idx]) end
                    end
                    if fd.overhealBar then apply(fd.overhealBar) end
                    if fd.absorbBar then apply(fd.absorbBar) end
                end
            end
        end
    end

    -- Mana cost bar: redirect to SUF's player power bar when Blizzard's
    -- PlayerFrame is hidden.  Hook CreateManaCostBar to target the SUF
    -- player frame's powerBar instead.
    if frameList.player and frameList.player.frame and frameList.player.frame.powerBar then
        local sufPowerBar = frameList.player.frame.powerBar
        -- Create the mana cost texture on SUF's power bar
        local sufManaCostTex = sufPowerBar:CreateTexture(nil, "ARTWORK", nil, 1)
        sufManaCostTex:SetColorTexture(1, 1, 1)
        sufManaCostTex:Hide()
        HP._sufManaCostTex = sufManaCostTex
        HP._sufPowerBar = sufPowerBar

        -- Hook the existing UpdateManaCostBar to also update SUF's version
        if HP.UpdateManaCostBar then
            local origUpdate = HP.UpdateManaCostBar
            HP.UpdateManaCostBar = function(...)
                origUpdate(...)
                -- Mirror onto SUF power bar
                if not sufManaCostTex or not sufPowerBar then return end
                if not Settings.showManaCost then
                    sufManaCostTex:Hide()
                    return
                end

                local name, _, _, _, _, _, _, _, spellID = CastingInfo()
                if not spellID then
                    sufManaCostTex:Hide()
                    return
                end

                local costTable = GetSpellPowerCost(spellID)
                local manaCost = 0
                if costTable then
                    for _, entry in pairs(costTable) do
                        if entry.type == 0 then
                            manaCost = entry.cost
                            break
                        end
                    end
                end

                if manaCost <= 0 then
                    sufManaCostTex:Hide()
                    return
                end

                local maxMana = UnitPowerMax("player", 0)
                if maxMana <= 0 then return end

                local curMana = UnitPower("player", 0)
                local barW = sufPowerBar:GetWidth()
                local endPx = curMana / maxMana * barW
                local startPx = mathmax(endPx - manaCost / maxMana * barW, 0)
                local costWidth = endPx - startPx + 1

                local c = Settings.colors and Settings.colors.manaCostBar
                if c then
                    sufManaCostTex:SetVertexColor(c[1], c[2], c[3], c[4])
                end
                sufManaCostTex:ClearAllPoints()
                sufManaCostTex:SetPoint("TOPLEFT", sufPowerBar, "TOPLEFT", startPx, 0)
                sufManaCostTex:SetPoint("BOTTOMLEFT", sufPowerBar, "BOTTOMLEFT", startPx, 0)
                sufManaCostTex:SetWidth(costWidth)
                sufManaCostTex:Show()
            end
        end

        -- Hook HideManaCostBar to also hide SUF's version
        if HP.HideManaCostBar then
            local origHide = HP.HideManaCostBar
            HP.HideManaCostBar = function(...)
                origHide(...)
                if sufManaCostTex then sufManaCostTex:Hide() end
            end
        end
    end

    -- Mana forecast + OOC regen timer: the core creates these on
    -- Blizzard's PlayerFrame mana bar (hidden when SUF is active).
    -- Create SUF-specific versions on the SUF player power bar.
    if frameList.player and frameList.player.frame and frameList.player.frame.powerBar then
        local sufPB = frameList.player.frame.powerBar

        -- Position anchors: 1=Above, 2=Center, 3=Below, 4=Right
        local ANCHORS = {
            function(fs, bar) fs:SetPoint("BOTTOM", bar, "TOP", 0, 2) end,
            function(fs, bar) fs:SetPoint("CENTER", bar, "CENTER", 0, 0) end,
            function(fs, bar) fs:SetPoint("TOP", bar, "BOTTOM", 0, -2) end,
            function(fs, bar) fs:SetPoint("LEFT", bar, "RIGHT", 4, 0) end,
        }

        -- Mana sustainability forecast text
        local forecastOverlay = CreateFrame("Frame", nil, sufPB)
        forecastOverlay:SetAllPoints(sufPB)
        forecastOverlay:SetFrameLevel(sufPB:GetFrameLevel() + 3)

        local sufForecastText = forecastOverlay:CreateFontString(nil, "OVERLAY")
        sufForecastText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
        sufForecastText:SetTextColor(1, 0.8, 0)
        sufForecastText:Hide()

        local function AnchorForecast()
            local pos = Settings.manaForecastPos or 1
            local fn = ANCHORS[pos] or ANCHORS[1]
            sufForecastText:ClearAllPoints()
            fn(sufForecastText, sufPB)
        end
        AnchorForecast()

        -- OOC regen timer text
        local sufOOCText = forecastOverlay:CreateFontString(nil, "OVERLAY")
        sufOOCText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
        sufOOCText:SetTextColor(0.4, 1.0, 0.4)
        sufOOCText:Hide()

        local function AnchorOOC()
            local pos = Settings.oocRegenTimerPos or 1
            local fn = ANCHORS[pos] or ANCHORS[1]
            sufOOCText:ClearAllPoints()
            fn(sufOOCText, sufPB)
        end
        AnchorOOC()

        -- Hook the core update functions to mirror onto SUF texts
        if HP.UpdateManaForecast then
            local origForecast = HP.UpdateManaForecast
            HP.UpdateManaForecast = function(...)
                origForecast(...)
                if not Settings.manaForecast then
                    sufForecastText:Hide()
                    return
                end

                if HP.SampleMana then HP.SampleMana() end
                local seconds = HP.GetManaForecast and HP.GetManaForecast()
                if not seconds then
                    sufForecastText:Hide()
                    return
                end

                local secs = mathfloor(seconds)
                if secs < 15 then
                    sufForecastText:SetTextColor(1, 0.2, 0.2)
                elseif secs < 30 then
                    sufForecastText:SetTextColor(1, 0.6, 0)
                else
                    sufForecastText:SetTextColor(1, 0.8, 0)
                end
                sufForecastText:SetFormattedText("OOM: %ds", secs)
                sufForecastText:Show()
            end
        end

        if HP.UpdateOOCRegen then
            local origOOC = HP.UpdateOOCRegen
            HP.UpdateOOCRegen = function(...)
                origOOC(...)
                if not Settings.oocRegenTimer then
                    sufOOCText:Hide()
                    return
                end

                if InCombatLockdown() then
                    sufOOCText:Hide()
                    return
                end

                local maxMana = UnitPowerMax("player", 0)
                if maxMana <= 0 then sufOOCText:Hide(); return end

                local curMana = UnitPower("player", 0)
                if curMana / maxMana >= 0.999 then
                    sufOOCText:Hide()
                    return
                end

                local base = GetManaRegen and GetManaRegen()
                if not base or base <= 0 then sufOOCText:Hide(); return end

                local deficit = maxMana - curMana
                local secs = mathfloor(deficit / base)

                if secs < 60 then
                    sufOOCText:SetFormattedText("Full: %ds", secs)
                else
                    sufOOCText:SetFormattedText("Full: %dm", mathfloor(secs / 60))
                end

                -- Stack below forecast text if both visible at same position
                if sufForecastText:IsShown()
                   and (Settings.oocRegenTimerPos or 1) == (Settings.manaForecastPos or 1) then
                    sufOOCText:ClearAllPoints()
                    sufOOCText:SetPoint("TOP", sufForecastText, "BOTTOM", 0, -2)
                else
                    AnchorOOC()
                end
                sufOOCText:Show()
            end
        end

        -- Hook anchor updates for position changes from options panel
        if HP.UpdateManaForecastAnchor then
            local origAnchor = HP.UpdateManaForecastAnchor
            HP.UpdateManaForecastAnchor = function(...)
                origAnchor(...)
                AnchorForecast()
            end
        end
        if HP.UpdateOOCRegenAnchor then
            local origAnchor = HP.UpdateOOCRegenAnchor
            HP.UpdateOOCRegenAnchor = function(...)
                origAnchor(...)
                AnchorOOC()
            end
        end
        if HP.ResetOOCRegen then
            local origReset = HP.ResetOOCRegen
            HP.ResetOOCRegen = function(...)
                origReset(...)
                if sufOOCText then sufOOCText:Hide() end
            end
        end
    end

    -- Low mana warning: the core renderer's 2-second mana poll uses
    -- frame.displayedUnit which doesn't exist on SUF frames.  Hook
    -- the poll to also check SUF frames with healer class tags.
    if HP.frameData then
        local origTick = HP.Tick
        if origTick then
            -- Tag healer class on SUF party/raid frames for mana checks
            for frame, fd in pairs(HP.frameData) do
                if fd._isSUF and not fd._classChecked then
                    local u = frame.unit or fd.unit
                    if u and UnitExists(u) then
                        local _, cls = UnitClass(u)
                        fd._isHealer = cls and HEALER_CLASSES[cls] or false
                        fd._classChecked = true
                    end
                end
            end
        end
    end

    -- Snipe detection: HP.OnSnipe only flashes frames in guidToCompact.
    -- Hook it to also flash SUF frames matching the sniped target GUID.
    if HP.OnSnipe then
        local origOnSnipe = HP.OnSnipe
        HP.OnSnipe = function(dstGUID, ...)
            origOnSnipe(dstGUID, ...)
            -- Flash any SUF frame showing this GUID
            for frame, fd in pairs(HP.frameData) do
                if fd._isSUF and fd.snipeAG then
                    local u = frame.unit or fd.unit
                    if u and UnitGUID(u) == dstGUID then
                        fd.snipeFlash:Show()
                        fd.snipeFlash:SetAlpha(0.8)
                        fd.snipeAG:Stop()
                        fd.snipeAG:Play()
                    end
                end
            end
        end
    end

    -- Watch for group roster changes so new party/raid frames are picked
    -- up without requiring a /reload.  SUF creates header-driven frames
    -- dynamically when the player joins a group; we need a short delay
    -- to let SUF finish initializing the new frames before we set them up.
    local rosterWatcher = CreateFrame("Frame")
    rosterWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterWatcher:RegisterEvent("GROUP_JOINED")
    rosterWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    rosterWatcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    local pendingRefresh = false
    rosterWatcher:SetScript("OnEvent", function()
        if not pendingRefresh then
            pendingRefresh = true
            C_Timer.After(1, function()
                pendingRefresh = false
                HP.RefreshSUFFrames()
            end)
        end
    end)

    -- Ticker: drive updates at ~20fps regardless of health bar events
    C_Timer.NewTicker(0.05, function()
        HP.UpdateAllSUFFrames()
    end)

    print("|cff33ccffHealPredict:|r |cff00ff00SUF compatibility active|r (" .. setupCount .. " frames)")
    HP._sufUIActive = true
    return true
end

------------------------------------------------------------------------
-- Refresh SUF Frame List (for dynamic groups / roster changes)
------------------------------------------------------------------------
function HP.RefreshSUFFrames()
    local frameList = HP.GetSUFFrames()
    if not frameList then return end

    local lists = { frameList.party, frameList.partypet, frameList.raid, frameList.raidpet, frameList.arena, frameList.arenapet, frameList.boss }
    for _, list in ipairs(lists) do
        if list then
            for _, frameInfo in ipairs(list) do
                if not HP.frameData[frameInfo.frame] then
                    HP.SetupSUFFrame(frameInfo)
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Refresh All SUF Settings (texture change, etc.)
------------------------------------------------------------------------
function HP.RefreshAllSUFSettings()
    local media = HP.GetSUFMedia()
    for frame, fd in pairs(HP.frameData) do
        if fd._isSUF then
            local newTexture = (media and media.statusBar) or fd.texture
            if newTexture ~= fd.texture then
                fd.texture = newTexture
                -- Prediction/overheal/absorb bars use SetColorTexture so
                -- they don't need a texture update — colors come purely
                -- from SetVertexColor.
            end
            HP.UpdateSUFFrame(frame)
        end
    end
end

------------------------------------------------------------------------
-- Update All SUF Frames
------------------------------------------------------------------------
function HP.UpdateAllSUFFrames()
    for frame, fd in pairs(HP.frameData) do
        if fd._isSUF then
            HP.UpdateSUFFrame(frame)
        end
    end
end

------------------------------------------------------------------------
-- Cleanup SUF Frames
------------------------------------------------------------------------
function HP.CleanupSUFFrames()
    for frame, fd in pairs(HP.frameData) do
        if fd._isSUF then
            -- Bars
            if fd.bars then
                for idx = 1, 4 do
                    if fd.bars[idx] then fd.bars[idx]:Hide() end
                end
            end
            if fd.overhealBar then fd.overhealBar:Hide() end
            if fd.absorbBar then fd.absorbBar:Hide() end
            if fd.overlay then fd.overlay:Hide() end

            -- Indicator elements
            if fd.shieldTex       then fd.shieldTex:Hide() end
            if fd.deficitText     then fd.deficitText:Hide() end
            if fd.shieldText      then fd.shieldText:Hide() end
            if fd.healerCountText then fd.healerCountText:Hide() end
            if fd.trajectoryMarker then fd.trajectoryMarker:Hide() end
            if fd.indicatorOverlay then fd.indicatorOverlay:Hide() end
            if fd.aoeBorder       then fd.aoeBorder:Hide() end
            if fd.snipeFlash      then fd.snipeFlash:Hide() end
            if fd.effects then
                for key in pairs(fd.effects) do HideIndicator(fd, key) end
            end
            if fd.resText         then fd.resText:Hide() end
            if fd.healReducText   then fd.healReducText:Hide() end
            if fd.deathPredText   then fd.deathPredText:Hide() end
            if fd.cdText          then fd.cdText:Hide() end
            if fd.defensiveContainer then fd.defensiveContainer:Hide() end
            if fd.hotDots then for di = 1, 5 do if fd.hotDots[di] then pcall(function() fd.hotDots[di]:Hide() end) end end end
            if fd.hotDotsOther then for di = 1, 5 do if fd.hotDotsOther[di] then pcall(function() fd.hotDotsOther[di]:Hide() end) end end end
            if fd.manaWarnText    then fd.manaWarnText:Hide() end
            if fd.healText        then fd.healText:Hide() end
        end
    end
    HP._sufUIActive = false
end

------------------------------------------------------------------------
-- Debug: Print SUF Frame Info
------------------------------------------------------------------------
function HP.DebugSUFFrames()
    print("|cff33ccffHealPredict:|r |cffffcc00SUF Frame Debug|r")

    local hasSUF, SUF = HP.DetectSUF()
    if not hasSUF then
        print("|cff33ccffHealPredict:|r SUF not detected")
        return
    end

    local frames = HP.GetSUFFrames()
    if not frames then
        print("|cff33ccffHealPredict:|r Could not get SUF frames")
        return
    end

    print("|cff33ccffHealPredict:|r Main frames:")
    for _, unitType in ipairs({ "player", "target", "targettarget", "focus", "pet" }) do
        local fi = frames[unitType]
        if fi then
            local hb      = fi.frame.healthBar
            local orient  = hb and hb:GetOrientation() or "?"
            local rev     = hb and tostring(hb:GetReverseFill()) or "?"
            print(string.format("  %s (orient=%s, reversed=%s)", unitType, orient, rev))
        end
    end

    print("|cff33ccffHealPredict:|r Party:     " .. (frames.party    and #frames.party    or 0))
    print("|cff33ccffHealPredict:|r PartyPet:  " .. (frames.partypet and #frames.partypet or 0))
    print("|cff33ccffHealPredict:|r Raid:      " .. (frames.raid     and #frames.raid     or 0))
    print("|cff33ccffHealPredict:|r RaidPet:   " .. (frames.raidpet  and #frames.raidpet  or 0))
    print("|cff33ccffHealPredict:|r Arena:     " .. (frames.arena    and #frames.arena    or 0))
    print("|cff33ccffHealPredict:|r ArenaPet:  " .. (frames.arenapet and #frames.arenapet or 0))
    print("|cff33ccffHealPredict:|r Boss:      " .. (frames.boss     and #frames.boss     or 0))

    local count = 0
    for _, fd in pairs(HP.frameData) do
        if fd._isSUF then count = count + 1 end
    end
    print("|cff33ccffHealPredict:|r Tracked SUF frames: " .. count)

    -- Print live heal data for all tracked SUF frames
    print("|cff33ccffHealPredict:|r Settings:")
    print("  showOthers=" .. tostring(Settings.showOthers)
        .. " filterDirect=" .. tostring(Settings.filterDirect)
        .. " filterHoT=" .. tostring(Settings.filterHoT)
        .. " smartOrdering=" .. tostring(Settings.smartOrdering))
    print("|cff33ccffHealPredict:|r Live heal data (all tracked SUF frames):")
    local printed = 0
    for frame, fd in pairs(HP.frameData) do
        if fd._isSUF then
            local u = frame.unit or fd.unit
            local exists = u and UnitExists(u)
            local m1, m2, o1, o2 = 0, 0, 0, 0
            if exists then
                if Settings.smartOrdering and HP.GetHealsSorted then
                    m1, m2, o1, o2 = HP.GetHealsSorted(u)
                elseif HP.GetHeals then
                    m1, m2, o1, o2 = HP.GetHeals(u)
                end
            end
            local total = m1 + m2 + o1 + o2
            local color = total > 0 and "|cff00ff00" or "|cff888888"
            print(string.format("  %s%s|r: exists=%s my=%.0f+%.0f other=%.0f+%.0f type=%s",
                color, u or "nil", tostring(exists), m1, m2, o1, o2, fd._sufType or "?"))
            printed = printed + 1
        end
    end
    if printed == 0 then
        print("  |cffff4444(no SUF frames in HP.frameData)|r")
    end
end
