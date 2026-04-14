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
local pairs = pairs
local ipairs = ipairs
local UnitGUID = UnitGUID
local UnitExists = UnitExists
local GetPlayerInfoByGUID = GetPlayerInfoByGUID

local Engine = HP.Engine

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

    -- Overheal bar: shows heal amount that would exceed max health
    local overhealBar = overlay:CreateTexture(nil, "BORDER", nil, 6)
    ApplyBarTexture(overhealBar)
    overhealBar:Hide()
    fd.overhealBar = overhealBar

    -- Absorb bar: shows shield/absorb amount eating into the health fill
    local absorbBar = overlay:CreateTexture(nil, "BORDER", nil, 6)
    ApplyBarTexture(absorbBar)
    absorbBar:Hide()
    fd.absorbBar = absorbBar

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
-- Update HealPrediction on a SUF Frame
-- Mirrors the overflow / clamping logic from RenderPrediction so that
-- heal bars extend past the health bar edge up to the configured cap.
------------------------------------------------------------------------
function HP.UpdateSUFFrame(sufFrame)
    local fd = HP.frameData[sufFrame]
    if not fd or not fd._isSUF then return end

    local hb = fd.hb
    if not hb then return end

    -- Anchor for vertical alignment: use the fill texture so bars match
    -- the visible fill height, falling back to the StatusBar frame.
    local anchor = fd.fillTex or hb

    -- Prefer the frame's live unit attribute; fall back to the stored unit.
    local unit = sufFrame.unit or fd.unit
    if not unit or not UnitExists(unit) then
        for idx = 1, 4 do
            if fd.bars[idx] then fd.bars[idx]:Hide() end
        end
        return
    end

    local _, cap = hb:GetMinMaxValues()
    local hp     = hb:GetValue()
    local barW   = hb:GetWidth()

    if not cap or cap <= 0 or barW <= 0 then
        for idx = 1, 4 do
            if fd.bars[idx] then fd.bars[idx]:Hide() end
        end
        return
    end

    -- Read orientation and fill direction from the actual health bar — this
    -- is the authoritative source (matches how incheal.lua reads it).
    local isVertical = hb:GetOrientation() == "VERTICAL"
    local isReversed = hb:GetReverseFill()

    -- Overflow cap: how far past 100% the bars may extend.
    -- Pick the right setting per frame type, matching the core renderer.
    local sufType = fd._sufType
    local overflowCap
    if sufType == "party" then
        overflowCap = 1.0 + (Settings.usePartyOverflow and Settings.partyOverflow or 0)
    elseif sufType == "raid" then
        overflowCap = 1.0 + (Settings.useRaidOverflow and Settings.raidOverflow or 0)
    else
        overflowCap = 1.0 + (Settings.useUnitOverflow and Settings.unitOverflow or 0)
    end

    -- Get heal amounts
    local my1, my2, ot1, ot2
    if Settings.smartOrdering and HP.GetHealsSorted then
        my1, my2, ot1, ot2 = HP.GetHealsSorted(unit)
    elseif HP.GetHeals then
        my1, my2, ot1, ot2 = HP.GetHeals(unit)
    else
        return
    end

    local isSorted = Settings.smartOrdering

    -- Pick the correct color palette per frame type.
    -- SUF party/raid use the "raid" (compact) palette; single-unit frames
    -- use the "unit" palette.  Matches Core/Render.lua.
    local isCompact = (sufType == "party" or sufType == "raid")
    local pal, palOH
    if isCompact then
        if isSorted then
            pal   = { "raidOtherDirect", "raidMyDirect", "raidOtherHoT", "raidMyHoT" }
            palOH = { "raidOtherDirectOH", "raidMyDirectOH", "raidOtherHoTOH", "raidMyHoTOH" }
        else
            pal   = { "raidMyDirect", "raidMyHoT", "raidOtherDirect", "raidOtherHoT" }
            palOH = { "raidMyDirectOH", "raidMyHoTOH", "raidOtherDirectOH", "raidOtherHoTOH" }
        end
    else
        if isSorted then
            pal   = { "unitOtherDirect", "unitMyDirect", "unitOtherHoT", "unitMyHoT" }
            palOH = { "unitOtherDirectOH", "unitMyDirectOH", "unitOtherHoTOH", "unitMyHoTOH" }
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

        for idx = 1, 4 do
            local cData = colors and colors[activePal[idx]]
            if cData and fd.bars[idx] then
                local aDim
                if isSorted then
                    aDim = (idx == 3 or idx == 4) and dimFactor or 1.0
                else
                    aDim = (idx == 2 or idx == 4) and dimFactor or 1.0
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
    local orderedAmounts

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
        orderedAmounts = amounts

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
        orderedAmounts = { my1, my2, ot1, ot2 }

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
        orderedAmounts = { my1, ot1, my2, ot2 }
    end

    local bars = fd.bars

    if isVertical then
        local barH = hb:GetHeight()
        if barH <= 0 then
            for idx = 1, 4 do if bars[idx] then bars[idx]:Hide() end end
            return
        end
        local healthPx = (hp / cap) * barH
        local curPx    = healthPx

        for idx = 1, 4 do
            local amount = orderedAmounts[idx] or 0
            local bar    = bars[idx]
            if not bar then break end

            if amount > 0 then
                local size = (amount / cap) * barH
                bar:ClearAllPoints()
                if isReversed then
                    local offset = barH - curPx
                    bar:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, -(barH - offset))
                    bar:SetPoint("TOPLEFT",  anchor, "TOPLEFT",  0, -(barH - offset))
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
        local curPx    = healthPx

        for idx = 1, 4 do
            local amount = orderedAmounts[idx] or 0
            local bar    = bars[idx]
            if not bar then break end

            if amount > 0 then
                -- No pixel clamping — bars extend past the bar edge.
                -- The amount was already capped at the HP level above.
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
    -- Mirrors RenderPrediction logic exactly.
    -- ----------------------------------------------------------------
    if fd.overhealBar then
        if Settings.showOverhealBar and cap > 0 and barW > 0 then
            local rawOverheal = mathmax(hp + rawTotal - cap, 0)
            if rawOverheal > 0 then
                -- Bar WIDTH is capped at the overflow percentage.
                local maxOHWidth = barW * (overflowCap - 1.0)
                local clampedOH  = mathmin(rawOverheal, cap * (overflowCap - 1.0))
                local ohWidth    = mathmin((clampedOH / cap) * barW, maxOHWidth)
                local cData = colors and colors.overhealBar
                if cData then
                    if Settings.overhealGradient and HP.OVERHEAL_GRAD then
                        -- Gradient COLOR uses unclamped overheal normalized
                        -- to the overflow range so the full green→orange→red
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
    if fd.absorbBar then
        local guid = unit and UnitGUID(unit)
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

    if frameList.party then
        for _, frameInfo in ipairs(frameList.party) do
            HP.SetupSUFFrame(frameInfo)
            setupCount = setupCount + 1
        end
    end

    if frameList.raid then
        for _, frameInfo in ipairs(frameList.raid) do
            HP.SetupSUFFrame(frameInfo)
            setupCount = setupCount + 1
        end
    end

    if frameList.arena then
        for _, frameInfo in ipairs(frameList.arena) do
            HP.SetupSUFFrame(frameInfo)
            setupCount = setupCount + 1
        end
    end

    if frameList.boss then
        for _, frameInfo in ipairs(frameList.boss) do
            HP.SetupSUFFrame(frameInfo)
            setupCount = setupCount + 1
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

    local lists = { frameList.party, frameList.raid, frameList.arena, frameList.boss }
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
            if fd.bars then
                for idx = 1, 4 do
                    if fd.bars[idx] then fd.bars[idx]:Hide() end
                end
            end
            if fd.overhealBar then fd.overhealBar:Hide() end
            if fd.absorbBar then fd.absorbBar:Hide() end
            if fd.overlay then fd.overlay:Hide() end
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

    print("|cff33ccffHealPredict:|r Party: " .. (frames.party and #frames.party or 0))
    print("|cff33ccffHealPredict:|r Raid:  " .. (frames.raid  and #frames.raid  or 0))
    print("|cff33ccffHealPredict:|r Arena: " .. (frames.arena and #frames.arena or 0))
    print("|cff33ccffHealPredict:|r Boss:  " .. (frames.boss  and #frames.boss  or 0))

    local count = 0
    for _, fd in pairs(HP.frameData) do
        if fd._isSUF then count = count + 1 end
    end
    print("|cff33ccffHealPredict:|r Tracked SUF frames: " .. count)
end
