-- HealPredict - Features.lua
-- Mana cost prediction, minimap button, raid check, test mode
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn
-- Modifications by PineappleTuesday

local HP = HealPredict

-- Local references for performance
local Settings      = HP.Settings
local Engine        = HP.Engine
local frameData     = HP.frameData
local frameGUID     = HP.frameGUID
local guidToCompact = HP.guidToCompact
local CreateShieldTex = HP.CreateShieldTex

local fmt, mathmin, mathmax, mathfloor = HP.fmt, HP.mathmin, HP.mathmax, HP.mathfloor
local pairs, ipairs, next, wipe = pairs, ipairs, next, wipe
local unpack, tinsert = HP.unpack, HP.tinsert

local CastingInfo = CastingInfo
local GetSpellPowerCost = GetSpellPowerCost
local UnitPower, UnitPowerMax = UnitPower, UnitPowerMax
local GetManaRegen = GetManaRegen
local UnitGUID = UnitGUID
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitExists, UnitName, UnitClass = UnitExists, UnitName, UnitClass
local UnitBuff = UnitBuff
local strsub = string.sub
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local UnitIsConnected = UnitIsConnected
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local GetNumGroupMembers = GetNumGroupMembers

---------------------------------------------------------------------------
-- Mana Cost Prediction (player frame only)
---------------------------------------------------------------------------
local manaCostTex = nil
local manaCostWatcher = nil

function HP.CreateManaCostBar()
    local manaBar = HP.PlayerFrame and HP.PlayerFrame.manabar
    if not manaBar then return end
    manaCostTex = manaBar:CreateTexture(nil, "ARTWORK", nil, 1)
    manaCostTex:SetColorTexture(1, 1, 1)
    manaCostTex:Hide()
    manaCostWatcher = CreateFrame("Frame")
    manaCostWatcher:SetScript("OnEvent", function()
        HP.UpdateManaCostBar()
    end)
end

function HP.UpdateManaCostBar()
    if not manaCostTex then return end
    if not Settings.showManaCost then
        manaCostTex:Hide()
        if manaCostWatcher then manaCostWatcher:UnregisterAllEvents() end
        return
    end

    local name, _, _, _, _, _, _, _, spellID = CastingInfo()
    if not spellID then
        manaCostTex:Hide()
        if manaCostWatcher then manaCostWatcher:UnregisterAllEvents() end
        return
    end

    -- Demand-attach: listen for mana changes while casting
    if manaCostWatcher and not manaCostWatcher._watching then
        manaCostWatcher:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
        manaCostWatcher._watching = true
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
        manaCostTex:Hide()
        return
    end

    local manaBar = HP.PlayerFrame.manabar
    if not manaBar then return end

    local maxMana = UnitPowerMax("player", 0)
    if maxMana <= 0 then return end

    local curMana = UnitPower("player", 0)
    local barW = manaBar:GetWidth()
    local endPx = curMana / maxMana * barW
    local startPx = mathmax(endPx - manaCost / maxMana * barW, 0)
    -- +1 pixel overlap to cover subpixel gap between StatusBar fill and our texture
    local costWidth = endPx - startPx + 1

    local c = Settings.colors.manaCostBar
    if c then
        manaCostTex:SetVertexColor(c[1], c[2], c[3], c[4])
    end
    manaCostTex:ClearAllPoints()
    manaCostTex:SetPoint("TOPLEFT", manaBar, "TOPLEFT", startPx, 0)
    manaCostTex:SetPoint("BOTTOMLEFT", manaBar, "BOTTOMLEFT", startPx, 0)
    manaCostTex:SetWidth(costWidth)
    manaCostTex:Show()
end

function HP.HideManaCostBar()
    if manaCostTex then manaCostTex:Hide() end
    if manaCostWatcher then
        manaCostWatcher:UnregisterAllEvents()
        manaCostWatcher._watching = false
    end
end

---------------------------------------------------------------------------
-- Flip colors utility (swap my <-> other)
---------------------------------------------------------------------------
function HP.FlipColors()
    local c = Settings.colors
    local swaps = {
        {"raidMyDirect", "raidOtherDirect"},
        {"raidMyHoT", "raidOtherHoT"},
        {"raidMyDirectOH", "raidOtherDirectOH"},
        {"raidMyHoTOH", "raidOtherHoTOH"},
        {"unitMyDirect", "unitOtherDirect"},
        {"unitMyHoT", "unitOtherHoT"},
        {"unitMyDirectOH", "unitOtherDirectOH"},
        {"unitMyHoTOH", "unitOtherHoTOH"},
    }
    for _, pair in ipairs(swaps) do
        c[pair[1]], c[pair[2]] = c[pair[2]], c[pair[1]]
    end
end

---------------------------------------------------------------------------
-- Flip unit/raid (swap raid <-> unit, preserving my/other roles)
---------------------------------------------------------------------------
function HP.FlipUnitRaidColors()
    local c = Settings.colors
    local swaps = {
        {"raidMyDirect", "unitMyDirect"},
        {"raidMyHoT", "unitMyHoT"},
        {"raidMyDirectOH", "unitMyDirectOH"},
        {"raidMyHoTOH", "unitMyHoTOH"},
        {"raidOtherDirect", "unitOtherDirect"},
        {"raidOtherHoT", "unitOtherHoT"},
        {"raidOtherDirectOH", "unitOtherDirectOH"},
        {"raidOtherHoTOH", "unitOtherHoTOH"},
    }
    for _, pair in ipairs(swaps) do
        c[pair[1]], c[pair[2]] = c[pair[2]], c[pair[1]]
    end
end

---------------------------------------------------------------------------
-- Mana Sustainability Forecast (Feature 6)
---------------------------------------------------------------------------
HP.manaHistory = {}
HP.manaLastSample = 0
local MANA_HISTORY_MAX = 10

function HP.SampleMana()
    local now = GetTime()
    if now - HP.manaLastSample < 2 then return end
    HP.manaLastSample = now

    local mx = UnitPowerMax("player", 0)
    if mx <= 0 then return end

    local pct = UnitPower("player", 0) / mx
    local hist = HP.manaHistory

    -- Detect mana spikes (potions, Innervate, Mana Tide, etc.)
    -- If mana jumped up by >5% in one sample interval, reset history
    -- so the prediction isn't skewed by a one-time gain
    if #hist > 0 then
        local prevPct = hist[#hist][2]
        if pct - prevPct > 0.05 then
            wipe(hist)
        end
    end

    hist[#hist + 1] = { now, pct }
    if #hist > MANA_HISTORY_MAX then
        local excess = #hist - MANA_HISTORY_MAX
        for i = 1, MANA_HISTORY_MAX do
            hist[i] = hist[i + excess]
        end
        for i = MANA_HISTORY_MAX + 1, MANA_HISTORY_MAX + excess do
            hist[i] = nil
        end
    end
end

function HP.GetManaForecast()
    local hist = HP.manaHistory
    if #hist < 3 then return nil end

    -- Use recent window only (last ~12s = 6 samples at 2s intervals)
    -- so prediction responds quickly to regen buff changes
    local startIdx = mathmax(1, #hist - 6)
    local first = hist[startIdx]
    local last = hist[#hist]
    local elapsed = last[1] - first[1]
    if elapsed < 4 then return nil end

    local drain = first[2] - last[2]
    if drain <= 0 then return nil end

    return last[2] / (drain / elapsed)
end

local manaForecastText = nil
local manaForecastBar = nil

local function ResolveManaBar()
    local pf = HP.PlayerFrame
    if not pf then return nil end
    return pf.manabar
        or pf.manaBar
        or pf.ManaBar
        or (pf.GetName and pf:GetName() and _G[pf:GetName() .. "ManaBar"])
        or _G["PlayerFrameManaBar"]
        or nil
end

-- Position anchors: 1=Above, 2=Center, 3=Below, 4=Right
local FORECAST_ANCHORS = {
    function(fs, bar) fs:SetPoint("BOTTOM", bar, "TOP", 0, 2) end,
    function(fs, bar) fs:SetPoint("CENTER", bar, "CENTER", 0, 0) end,
    function(fs, bar) fs:SetPoint("TOP", bar, "BOTTOM", 0, -2) end,
    function(fs, bar) fs:SetPoint("LEFT", bar, "RIGHT", 4, 0) end,
}

function HP.UpdateManaForecastAnchor()
    if not manaForecastText or not manaForecastBar then return end
    local pos = Settings.manaForecastPos or 1
    local fn = FORECAST_ANCHORS[pos]
    if not fn then fn = FORECAST_ANCHORS[1] end
    manaForecastText:ClearAllPoints()
    fn(manaForecastText, manaForecastBar)
end

function HP.CreateManaForecastText()
    local manaBar = ResolveManaBar()
    if not manaBar then return end
    manaForecastBar = manaBar

    -- Create an overlay frame so the text draws above all player frame art
    local overlay = CreateFrame("Frame", nil, manaBar)
    overlay:SetAllPoints(manaBar)
    overlay:SetFrameLevel(manaBar:GetFrameLevel() + 3)

    manaForecastText = overlay:CreateFontString(nil, "OVERLAY")
    manaForecastText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    manaForecastText:SetTextColor(1, 0.8, 0)
    manaForecastText:Hide()

    HP.UpdateManaForecastAnchor()
end

function HP.UpdateManaForecast()
    if not manaForecastText then return end
    if not Settings.manaForecast then
        manaForecastText:Hide()
        if HP.UpdateOOCRegenAnchor then HP.UpdateOOCRegenAnchor() end
        return
    end

    HP.SampleMana()
    local seconds = HP.GetManaForecast()
    if not seconds then
        manaForecastText:Hide()
        if HP.UpdateOOCRegenAnchor then HP.UpdateOOCRegenAnchor() end
        return
    end

    local secs = mathfloor(seconds)
    if secs < 15 then
        manaForecastText:SetTextColor(1, 0.2, 0.2)
    elseif secs < 30 then
        manaForecastText:SetTextColor(1, 0.6, 0)
    else
        manaForecastText:SetTextColor(1, 0.8, 0)
    end
    manaForecastText:SetFormattedText("OOM: %ds", secs)
    manaForecastText:Show()
end

function HP.ResetManaHistory()
    wipe(HP.manaHistory)
    HP.manaLastSample = 0
    if manaForecastText then manaForecastText:Hide() end
end

---------------------------------------------------------------------------
-- Out-of-Combat Regen Timer (v1.0.4)
---------------------------------------------------------------------------
local oocRegenText = nil
local oocRegenBar = nil

function HP.CreateOOCRegenText()
    local manaBar = ResolveManaBar()
    if not manaBar then return end
    oocRegenBar = manaBar

    local overlay = CreateFrame("Frame", nil, manaBar)
    overlay:SetAllPoints(manaBar)
    overlay:SetFrameLevel(manaBar:GetFrameLevel() + 3)

    oocRegenText = overlay:CreateFontString(nil, "OVERLAY")
    oocRegenText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    oocRegenText:SetTextColor(0.4, 1.0, 0.4)
    oocRegenText:Hide()

    HP.UpdateOOCRegenAnchor()
end

function HP.UpdateOOCRegenAnchor()
    if not oocRegenText or not oocRegenBar then return end
    local pos = Settings.oocRegenTimerPos or 1
    local fn = FORECAST_ANCHORS[pos]
    if not fn then fn = FORECAST_ANCHORS[1] end
    oocRegenText:ClearAllPoints()
    fn(oocRegenText, oocRegenBar)
end

function HP.UpdateOOCRegen()
    if not oocRegenText then return end
    if not Settings.oocRegenTimer then
        oocRegenText:Hide()
        return
    end

    -- Hide when in combat or mana is full
    if InCombatLockdown() then
        oocRegenText:Hide()
        return
    end

    local maxMana = UnitPowerMax("player", 0)
    if maxMana <= 0 then oocRegenText:Hide(); return end

    local curMana = UnitPower("player", 0)
    if curMana / maxMana >= 0.999 then
        oocRegenText:Hide()
        return
    end

    -- Use WoW API for actual regen rate — includes spirit, mp5, buffs, flasks,
    -- potions (active regen effects), and all other mana regeneration sources.
    -- This is far more accurate than sampling mana over time.
    local base = GetManaRegen and GetManaRegen()
    if not base or base <= 0 then oocRegenText:Hide(); return end

    local deficit = maxMana - curMana
    local secs = mathfloor(deficit / base)

    if secs < 60 then
        oocRegenText:SetFormattedText("Full: %ds", secs)
    else
        oocRegenText:SetFormattedText("Full: %dm", mathfloor(secs / 60))
    end
    if manaForecastText and manaForecastText:IsShown()
       and (Settings.oocRegenTimerPos or 1) == (Settings.manaForecastPos or 1) then
        oocRegenText:ClearAllPoints()
        oocRegenText:SetPoint("TOP", manaForecastText, "BOTTOM", 0, -2)
    else
        HP.UpdateOOCRegenAnchor()
    end
    oocRegenText:Show()
end

function HP.ResetOOCRegen()
    if oocRegenText then oocRegenText:Hide() end
end

---------------------------------------------------------------------------
-- Healing Efficiency Report (v1.0.4)
---------------------------------------------------------------------------
function HP.DoEfficiencyReport()
    local stats = HP.spellStats
    if not next(stats) then
        print("|cff33ccffHealPredict:|r No healing data recorded. Enable 'Track healing efficiency' and heal!")
        return
    end

    local elapsed = GetTime() - (HP.efficiencySession or 0)
    local elapsedMin = mathfloor(elapsed / 60)

    print("|cff33ccffHealPredict:|r Healing Efficiency Report (" .. elapsedMin .. "m session)")

    -- Sort by effective healing descending
    local sorted = {}
    for spellID, s in pairs(stats) do
        local effective = s.totalHeal - s.totalOverheal
        sorted[#sorted + 1] = { id = spellID, casts = s.casts, eff = effective, oh = s.totalOverheal, total = s.totalHeal }
    end
    table.sort(sorted, function(a, b) return a.eff > b.eff end)

    for _, row in ipairs(sorted) do
        local spellName = GetSpellInfo and GetSpellInfo(row.id) or ("ID:" .. row.id)
        local effPct = row.total > 0 and mathfloor(row.eff / row.total * 100) or 0
        local effColor = effPct >= 90 and "44ff44" or (effPct >= 70 and "ffff44" or "ff6644")
        print(fmt("  |cffffffff%s|r: %dx | %d eff | %d oh | |cff%s%d%%|r",
            spellName, row.casts, mathfloor(row.eff), mathfloor(row.oh), effColor, effPct))
    end
end

function HP.ResetEfficiency()
    wipe(HP.spellStats)
    HP.efficiencySession = GetTime()
    print("|cff33ccffHealPredict:|r Efficiency data reset.")
end

---------------------------------------------------------------------------
-- Heal Snipe Stats (Feature 7)
---------------------------------------------------------------------------
function HP.DoSnipeReport()
    local stats = HP.snipeStats
    if stats.count == 0 then
        print("|cff33ccffHealPredict:|r No snipes detected this session.")
        return
    end
    print("|cff33ccffHealPredict:|r Snipe report:")
    print(fmt("  Total snipes: |cffff4444%d|r", stats.count))
    print(fmt("  Total wasted healing: |cffff4444%d|r", mathfloor(stats.totalWasted)))

    local log = HP.snipeLog
    if #log > 0 then
        print("  Recent snipes:")
        for i = #log, mathmax(#log - 4, 1), -1 do
            local e = log[i]
            local spellName = GetSpellInfo and GetSpellInfo(e.spell) or ("ID:" .. e.spell)
            print(fmt("    %s — %d/%d overhealed (%.0f%%)",
                spellName, mathfloor(e.oh), mathfloor(e.total), e.oh / e.total * 100))
        end
    end
end

---------------------------------------------------------------------------
-- Raid Heal Data Check
---------------------------------------------------------------------------
local HEALER_CLASSES = { PRIEST=true, PALADIN=true, DRUID=true, SHAMAN=true }

function HP.DoRaidCheck()
    if not IsInGroup() and not IsInRaid() then
        print("|cff33ccffHealPredict:|r Not in a group.")
        return
    end

    local prefix = IsInRaid() and "raid" or "party"
    local count = GetNumGroupMembers()
    local hasComm, noComm = {}, {}

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local name = UnitName(unit)
            local _, cls = UnitClass(unit)
            local guid = UnitGUID(unit)

            if HEALER_CLASSES[cls] then
                local hasData = false
                if guid then
                    local amount = Engine:GetCasterHealAmount(guid)
                    if amount and amount > 0 then hasData = true
                    else hasData = Engine:GUIDHasHealed(guid) end
                end
                local entry = fmt("  %s (%s)", name or "?", cls or "?")
                if hasData then
                    tinsert(hasComm, entry)
                else
                    tinsert(noComm, entry)
                end
            end
        end
    end

    print("|cff33ccffHealPredict:|r Raid heal data check:")
    if #hasComm > 0 then
        print("|cff44ff44Sending heal data:|r")
        for _, s in ipairs(hasComm) do print(s) end
    end
    if #noComm > 0 then
        print("|cffff8844No heal data (yet):|r")
        for _, s in ipairs(noComm) do print(s) end
    end
    if #hasComm == 0 and #noComm == 0 then
        print("  No healers found in group.")
    end
    print("|cff888888Note: 'No data' means no heals detected yet.|r")
end

---------------------------------------------------------------------------
-- Minimap Button
---------------------------------------------------------------------------
local minimapBtn = nil

-- Detect if minimap is square (ElvUI, etc.)
local function IsSquareMinimap()
    local w, h = Minimap:GetWidth(), Minimap:GetHeight()
    return abs(w - h) < 5  -- Allow small margin for error
end

-- Calculate radius for minimap positioning
local function GetMinimapRadius()
    if IsSquareMinimap() then
        -- For square minimaps, use a slightly smaller radius
        -- and clamp to edges
        return math.min(Minimap:GetWidth(), Minimap:GetHeight()) / 2 + 5
    end
    -- Default circular minimap radius
    return 78
end

-- Clamp position for square minimaps to keep button on edges
local function ClampToSquareMinimap(x, y, radius)
    local halfSize = math.min(Minimap:GetWidth(), Minimap:GetHeight()) / 2
    local maxDist = halfSize + 5
    
    local dist = math.sqrt(x * x + y * y)
    if dist > maxDist then
        local scale = maxDist / dist
        x = x * scale
        y = y * scale
    end
    return x, y
end

local function UpdateMinimapButtonPosition()
    if not minimapBtn then return end
    
    -- Check if MinimapButton addon or similar is managing this button
    if minimapBtn.isManaged then return end
    
    local angle = math.rad(Settings.minimapAngle or 225)
    local radius = GetMinimapRadius()
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    
    -- Clamp for square minimaps
    if IsSquareMinimap() then
        x, y = ClampToSquareMinimap(x, y, radius)
    end
    
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapBtn then return end

    minimapBtn = CreateFrame("Button", "HealPredictMinimapBtn", Minimap)
    minimapBtn:SetSize(31, 31)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetFrameLevel(8)
    minimapBtn:EnableMouse(true)
    minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapBtn:RegisterForDrag("LeftButton")
    
    -- Compatibility: Flag for MinimapButton addon
    minimapBtn.isMinimapButton = true
    minimapBtn.minimapPos = Settings.minimapAngle or 225
    
    -- Compatibility: Register with global minimap buttons list
    if not _G.MinimapButtonButtons then
        _G.MinimapButtonButtons = {}
    end
    _G.MinimapButtonButtons["HealPredictMinimapBtn"] = minimapBtn

    local bg = minimapBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER")
    bg:SetTexture("Interface\\AddOns\\HealPredict\\icon")
    bg:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    minimapBtn.icon = bg  -- Reference for MinimapButton addon

    local border = minimapBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local hl = minimapBtn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetSize(24, 24)
    hl:SetPoint("CENTER")
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")

    minimapBtn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" and IsShiftKeyDown() then
            HP.ShowChangelog(HP.VERSION or "1.0.4")
        elseif button == "LeftButton" then
            if SlashCmdList["HEALPREDICT"] then
                SlashCmdList["HEALPREDICT"]("")
            elseif HP.ToggleOptions then
                HP.ToggleOptions()
            end
        elseif button == "RightButton" then
            if SlashCmdList["HPTEST"] then
                SlashCmdList["HPTEST"]()
            end
        end
    end)

    minimapBtn:SetScript("OnDragStart", function()
        -- Don't allow dragging if managed by another addon
        if minimapBtn.isManaged then return end
        minimapBtn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            Settings.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            minimapBtn.minimapPos = Settings.minimapAngle
            UpdateMinimapButtonPosition()
        end)
    end)

    minimapBtn:SetScript("OnDragStop", function()
        minimapBtn:SetScript("OnUpdate", nil)
        HP.SaveSettings()
    end)

    minimapBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local L = HP.L or {}
        GameTooltip:AddLine(L["MINIMAP_TITLE"] or "|cff33ccffHealPredict|r")
        GameTooltip:AddLine(L["MINIMAP_LEFTCLICK"] or "Left-click: Toggle options", 1, 1, 1)
        GameTooltip:AddLine(L["MINIMAP_SHIFT_CLICK"] or "Shift-left-click: Changelog", 1, 1, 1)
        GameTooltip:AddLine(L["MINIMAP_RIGHTCLICK"] or "Right-click: Toggle test mode", 1, 1, 1)
        GameTooltip:AddLine(L["MINIMAP_DRAG"] or "Drag: Reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    minimapBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdateMinimapButtonPosition()
end

-- Allow external management (MinimapButton addon compatibility)
function HP.SetMinimapButtonManaged(managed)
    if minimapBtn then
        minimapBtn.isManaged = managed
        if managed then
            minimapBtn:SetParent(UIParent)
        else
            minimapBtn:SetParent(Minimap)
            UpdateMinimapButtonPosition()
        end
    end
end

function HP.ToggleMinimapButton()
    if not minimapBtn then CreateMinimapButton() end
    if Settings.showMinimapButton then
        minimapBtn:Show()
    else
        minimapBtn:Hide()
    end
end

---------------------------------------------------------------------------
-- MinimapButtonButton (MBB) Compatibility
---------------------------------------------------------------------------
local function RegisterWithMBB()
    if not minimapBtn then return end
    
    -- MBB stores its options in MinimapButtonButtonOptions
    -- The whitelist contains buttons that should always be collected
    if _G.MinimapButtonButtonOptions and _G.MinimapButtonButtonOptions.whitelist then
        -- Add our button to MBB's whitelist if not already there
        if not _G.MinimapButtonButtonOptions.whitelist["HealPredictMinimapBtn"] then
            _G.MinimapButtonButtonOptions.whitelist["HealPredictMinimapBtn"] = true
            
            -- Trigger MBB to rescan if the collect function is available
            if _G.MinimapButtonButton and _G.MinimapButtonButton.Logic and _G.MinimapButtonButton.Logic.Main then
                local Main = _G.MinimapButtonButton.Logic.Main
                if Main.collectMinimapButtonsAndUpdateLayout then
                    Main.collectMinimapButtonsAndUpdateLayout()
                end
            end
        end
    end
end

-- Register with MBB after both addons are loaded
C_Timer.After(2, function()
    RegisterWithMBB()
    -- Try again after a longer delay for slow-loading scenarios
    C_Timer.After(3, RegisterWithMBB)
end)

---------------------------------------------------------------------------
-- Test mode
---------------------------------------------------------------------------
local testContainer = nil
local testFrameList = {}

-- Layout configurations
local LAYOUT_CONFIG = {
    { -- Solo (8 frames, vertical)
        count = 8,
        frameSize = {72, 30},
        containerSize = {82, 8 * 38 + 26},
        label = "HP Test (Solo)",
    },
    { -- Dungeon (5 frames, party style vertical)
        count = 5,
        frameSize = {72, 40},
        containerSize = {82, 5 * 46 + 26},
        label = "HP Test (Dungeon)",
    },
    { -- Raid (25 frames, grid layout)
        count = 25,
        frameSize = {72, 30},
        containerSize = {82 * 5 + 16, math.ceil(25/5) * 38 + 26},
        label = "HP Test (Raid)",
    },
}

function HP.BuildTestFrames()
    if testContainer then return end
    
    local layout = Settings.testModeLayout or 1
    local config = LAYOUT_CONFIG[layout]
    local TEST_COUNT = config.count

    testContainer = CreateFrame("Frame", "HPTestContainer", UIParent, "BackdropTemplate")
    testContainer:SetSize(unpack(config.containerSize))
    testContainer:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    testContainer:SetFrameStrata("HIGH")
    testContainer:EnableMouse(true)
    testContainer:SetMovable(true)
    testContainer:RegisterForDrag("LeftButton")
    testContainer:SetScript("OnDragStart", testContainer.StartMoving)
    testContainer:SetScript("OnDragStop", testContainer.StopMovingOrSizing)
    local lbl = testContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOP", 0, -6)
    lbl:SetText(config.label)

    local names = { "Healbot", "Tankadin", "Shadowdps", "Restokin", "Firemage", "ProtWar", "Hunter", "Rogue", 
                    "DK", "BMHunter", "RetPala", "EleSham", "EnhSham", "AffLock", "DemoLock", "DestroLock",
                    "ArcMage", "FrostMage", "Feral", "Balance", "HolyPala", "Disc", "Holy", "ShadPri", "SurvHunter" }
    local classClr = {
        { 0.0, 1.0, 0.6 }, { 0.96, 0.55, 0.73 }, { 0.6, 0.2, 0.8 }, { 1.0, 0.49, 0.04 }, { 0.25, 0.78, 0.92 },
        { 0.78, 0.61, 0.43 }, { 0.67, 0.83, 0.45 }, { 1.0, 0.96, 0.41 }, { 0.77, 0.12, 0.23 }, { 0.67, 0.83, 0.45 },
        { 0.96, 0.55, 0.73 }, { 0.0, 0.44, 0.87 }, { 0.0, 0.44, 0.87 }, { 0.58, 0.51, 0.79 }, { 0.58, 0.51, 0.79 },
        { 0.58, 0.51, 0.79 }, { 0.25, 0.78, 0.92 }, { 0.25, 0.78, 0.92 }, { 1.0, 0.49, 0.04 }, { 1.0, 0.49, 0.04 },
        { 0.96, 0.55, 0.73 }, { 1.0, 1.0, 1.0 }, { 1.0, 1.0, 1.0 }, { 0.6, 0.2, 0.8 }, { 0.67, 0.83, 0.45 },
    }
    local hpPct = { 0.72, 0.55, 0.38, 0.85, 0.60, 0.45, 0.68, 0.33, 0.77, 0.52, 0.41, 0.88, 0.62, 0.35, 0.71, 0.49, 0.83, 0.58, 0.44, 0.91, 0.67, 0.39, 0.74, 0.56, 0.48 }
    local maxHP = UnitHealthMax("player") or 10000

    for i = 1, TEST_COUNT do
        local id = "HPTestFrame" .. i
        local f = CreateFrame("Button", id, testContainer)
        f:SetSize(unpack(config.frameSize))
        
        -- Position based on layout
        if layout == 3 then
            -- Raid grid: 5 columns
            local col = (i - 1) % 5
            local row = math.floor((i - 1) / 5)
            f:SetPoint("TOPLEFT", testContainer, "TOPLEFT", 8 + col * 82, -18 - row * 38)
        else
            -- Solo/Dungeon: vertical stack
            local spacing = layout == 2 and 46 or 38
            f:SetPoint("TOP", testContainer, "TOP", 0, -18 - (i - 1) * spacing)
        end

        local hb = CreateFrame("StatusBar", id .. "HB", f)
        hb:SetAllPoints(f)
        hb:SetMinMaxValues(0, maxHP)
        hb:SetValue(maxHP * hpPct[i])
        hb:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
        hb:SetStatusBarColor(unpack(classClr[i]))

        local bg = hb:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.8)

        local bdr = f:CreateTexture(nil, "OVERLAY")
        bdr:SetAllPoints()
        bdr:SetTexture("Interface\\RaidFrame\\Raid-Border")

        local nm = hb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nm:SetPoint("CENTER", 0, 0)
        nm:SetText(names[i])

        f.healthBar = hb
        f.displayedUnit = "player"
        f.unit = "player"
        testFrameList[i] = f
        
        -- Make test frame draggable by forwarding to container
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function() testContainer:StartMoving() end)
        f:SetScript("OnDragStop", function() testContainer:StopMovingOrSizing() end)

        local fd = { hb = hb, usesGradient = true, bars = {}, _hbWidth = 72 }
        -- Parent bar textures to the health bar (not the button frame) so they
        -- render above the StatusBar fill texture instead of behind it.
        for idx = 1, 5 do
            local tex = hb:CreateTexture(id .. "Bar" .. idx, "BORDER", nil, 5)
            tex:ClearAllPoints()
            tex:SetColorTexture(1, 1, 1)
            fd.bars[idx] = tex
        end

        -- Overlay frame above the StatusBar fill for textures that overlap health
        local overlay = CreateFrame("Frame", nil, hb)
        overlay:SetAllPoints(hb)
        overlay:SetFrameLevel(hb:GetFrameLevel() + 1)
        fd.overlay = overlay

        fd.shieldTex = CreateShieldTex(overlay)

        local absorbBar = overlay:CreateTexture(nil, "BORDER", nil, 6)
        absorbBar:SetColorTexture(1, 1, 1)
        absorbBar:Hide()
        fd.absorbBar = absorbBar

        local overhealBar = overlay:CreateTexture(nil, "BORDER", nil, 6)
        overhealBar:SetColorTexture(1, 1, 1)
        overhealBar:Hide()
        fd.overhealBar = overhealBar

        local deficitText = hb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        deficitText:SetPoint("RIGHT", hb, "RIGHT", -2 + (Settings.deficitOffsetX or 0), Settings.deficitOffsetY or 0)
        deficitText:SetJustifyH("RIGHT")
        deficitText:Hide()
        fd.deficitText = deficitText

        local shieldText = hb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        shieldText:SetPoint("LEFT", hb, "LEFT", 2, 0)
        shieldText:SetJustifyH("LEFT")
        shieldText:Hide()
        fd.shieldText = shieldText

        -- Healer count text (position configurable)
        local healerCountText = hb:CreateFontString(nil, "OVERLAY")
        healerCountText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        HP.ApplyTextAnchor(healerCountText, hb, HP.HEALER_COUNT_ANCHORS, Settings.healerCountPos, Settings.healerCountOffsetX, Settings.healerCountOffsetY)
        healerCountText:Hide()
        fd.healerCountText = healerCountText

        -- Trajectory marker
        local trajMarker = hb:CreateTexture(nil, "OVERLAY", nil, 3)
        trajMarker:SetColorTexture(1, 1, 0, 0.7)
        trajMarker:SetWidth(2)
        trajMarker:Hide()
        fd.trajectoryMarker = trajMarker

        -- Indicator overlay frame: render above health bar for visibility
        local indicatorOverlay = CreateFrame("Frame", nil, f)
        indicatorOverlay:SetAllPoints(f)
        indicatorOverlay:SetFrameLevel(hb:GetFrameLevel() + 2)
        fd.indicatorOverlay = indicatorOverlay

        -- AoE advisor border (4-edge strips on overlay)
        local aoeBorder = CreateFrame("Frame", nil, indicatorOverlay)
        aoeBorder:SetAllPoints(f)
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
            e[info[3]](e, Settings.borderThickness or 2)
            aoeEdges[#aoeEdges + 1] = e
        end
        fd.aoeBorder = aoeBorder
        fd._aoeEdges = aoeEdges

        -- Snipe flash (on overlay)
        local snipeFlash = indicatorOverlay:CreateTexture(nil, "OVERLAY", nil, 5)
        snipeFlash:SetTexture("Interface\\RaidFrame\\Raid-Border")
        snipeFlash:SetAllPoints(f)
        snipeFlash:SetVertexColor(1, 0.1, 0.1, 0)
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
        fd.effects.hotExpiry = HP.CreateIndicatorEffect(indicatorOverlay, f, "OVERLAY", 4, false, f)
        fd.hotExpiryBorder = fd.effects.hotExpiry.border

        fd.effects.dispel = HP.CreateIndicatorEffect(indicatorOverlay, hb, "OVERLAY", 3, false, f)
        fd.dispelOverlay = fd.effects.dispel.border

        -- Res tracker text (on overlay)
        local resText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
        resText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        resText:SetText("|cff44ff44RES|r")
        resText:SetPoint("CENTER", hb, "CENTER", Settings.resOffsetX or 0, Settings.resOffsetY or 0)
        resText:Hide()
        fd.resText = resText

        fd.effects.cluster = HP.CreateIndicatorEffect(indicatorOverlay, f, "OVERLAY", 3, false, f)
        fd.clusterBorder = fd.effects.cluster.border

        fd.effects.healReduc = HP.CreateIndicatorEffect(indicatorOverlay, f, "OVERLAY", 4, false, f)
        fd.healReducGlow = fd.effects.healReduc.border
        
        -- Defensive cooldown indicator effect (for border display mode)
        fd.effects.defensive = HP.CreateIndicatorEffect(indicatorOverlay, f, "OVERLAY", 5, false, f)

        -- Charmed/Mind-controlled indicator effect
        fd.effects.charmed = HP.CreateIndicatorEffect(indicatorOverlay, f, "OVERLAY", 6, false, f)

        -- Heal reduction text (on overlay)
        local healReducText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
        healReducText:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
        healReducText:SetTextColor(1, 0.3, 0.3)
        healReducText:SetPoint("BOTTOMLEFT", hb, "BOTTOMLEFT", 2, 1)
        healReducText:Hide()
        fd.healReducText = healReducText
        -- Add position update function for test frames
        fd._applyHealReducTextPos = function()
            if not hb or not fd.healReducText then return end
            local pos = Settings.healReductionTextPos or 4
            local ox = Settings.healReducOffsetX or 0
            local oy = Settings.healReducOffsetY or 0
            fd.healReducText:ClearAllPoints()
            if pos == 1 then
                fd.healReducText:SetPoint("TOPLEFT", hb, "TOPLEFT", 2 + ox, -1 + oy)
            elseif pos == 2 then
                fd.healReducText:SetPoint("TOPRIGHT", hb, "TOPRIGHT", -2 + ox, -1 + oy)
            elseif pos == 3 then
                fd.healReducText:SetPoint("CENTER", hb, "CENTER", ox, oy)
            elseif pos == 4 then
                fd.healReducText:SetPoint("BOTTOMLEFT", hb, "BOTTOMLEFT", 2 + ox, 1 + oy)
            else
                fd.healReducText:SetPoint("BOTTOMRIGHT", hb, "BOTTOMRIGHT", -2 + ox, 1 + oy)
            end
        end

        -- CD tracker text (on overlay)
        local cdText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
        cdText:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE")
        cdText:SetTextColor(0.3, 1.0, 0.3)
        cdText:SetPoint("TOPRIGHT", hb, "TOPRIGHT", -2 + (Settings.cdOffsetX or 0), -1 + (Settings.cdOffsetY or 0))
        cdText:Hide()
        fd.cdText = cdText

        -- Defensive cooldown display (icon + text)
        local defensiveContainer = CreateFrame("Frame", nil, indicatorOverlay)
        defensiveContainer:SetSize(40, 20)
        defensiveContainer:SetPoint("CENTER", hb, "CENTER", Settings.defensiveOffsetX or 0, Settings.defensiveOffsetY or 0)
        defensiveContainer:Hide()
        fd.defensiveContainer = defensiveContainer
        
        local defensiveIcon = defensiveContainer:CreateTexture(nil, "OVERLAY", nil, 7)
        defensiveIcon:SetSize(16, 16)
        defensiveIcon:SetPoint("LEFT", defensiveContainer, "LEFT", 0, 0)
        defensiveIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        fd.defensiveIcon = defensiveIcon
        
        local defensiveText = defensiveContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        defensiveText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
        defensiveText:SetPoint("LEFT", defensiveIcon, "RIGHT", 2, 0)
        fd.defensiveText = defensiveText

        -- Low mana warning text (on overlay)
        local manaWarnText = indicatorOverlay:CreateFontString(nil, "OVERLAY")
        manaWarnText:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE")
        manaWarnText:SetTextColor(0.4, 0.6, 1.0)
        manaWarnText:SetPoint("BOTTOMRIGHT", hb, "BOTTOMRIGHT", Settings.lowManaOffsetX or -2, Settings.lowManaOffsetY or 1)
        manaWarnText:Hide()
        fd.manaWarnText = manaWarnText

        -- HoT tracker dots/icons (mirrors Render.lua SetupCompact)
        if fd.hb then
            local dotSize = Settings.hotDotSize or 4
            local isIconMode = (Settings.hotDotDisplayMode or 1) == 2
            fd.hotDots = {}
            fd.hotDotCooldowns = {}
            for di = 1, 5 do
                if isIconMode then
                    local iconFrame = CreateFrame("Frame", nil, indicatorOverlay)
                    iconFrame:SetSize(dotSize, dotSize)
                    iconFrame:Hide()
                    local iconTex = iconFrame:CreateTexture(nil, "OVERLAY", nil, 7)
                    iconTex:SetAllPoints(iconFrame)
                    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    iconTex:SetTexture(HP.HOT_DOT_ICONS[di])
                    local cooldown = CreateFrame("Cooldown", nil, iconFrame, "CooldownFrameTemplate")
                    cooldown:SetAllPoints(iconFrame)
                    cooldown:SetReverse(true)
                    cooldown:SetHideCountdownNumbers(true)
                    cooldown.noCooldownCount = true
                    cooldown:Hide()
                    fd.hotDots[di] = iconFrame
                    fd.hotDotCooldowns[di] = cooldown
                else
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
                    local iconFrame = CreateFrame("Frame", nil, indicatorOverlay)
                    iconFrame:SetSize(dotSize, dotSize)
                    iconFrame:Hide()
                    local iconTex = iconFrame:CreateTexture(nil, "OVERLAY", nil, 7)
                    iconTex:SetAllPoints(iconFrame)
                    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    iconTex:SetTexture(HP.HOT_DOT_ICONS[di])
                    iconTex:SetDesaturated(true)
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
                    local dot = indicatorOverlay:CreateTexture(nil, "OVERLAY", nil, 7)
                    dot:SetSize(dotSize, dotSize)
                    dot:Hide()
                    fd.hotDotsOther[di] = dot
                end
            end

            -- Apply anchors using shared function
            if HP.ApplyDotAnchors then
                HP.ApplyDotAnchors(fd)
            else
                local a = HP.HOT_DOT_ANCHORS[Settings.hotDotsPos] or HP.HOT_DOT_ANCHORS[1]
                local spacing = Settings.hotDotSpacing or 6
                for di = 1, 5 do
                    fd.hotDots[di]:ClearAllPoints()
                    fd.hotDots[di]:SetPoint(a[1], fd.hb, a[2], a[3] + (di - 1) * spacing, a[4])
                end
                for di = 1, 5 do
                    fd.hotDotsOther[di]:ClearAllPoints()
                    fd.hotDotsOther[di]:SetPoint(a[1], fd.hb, a[2], a[3] + (di - 1) * spacing, a[4] + dotSize + 2)
                end
            end
        end

        fd._isTestFrame = true
        fd._testFrameIndex = i
        frameData[f] = fd

        local guid = UnitGUID("player")
        if guid then
            guidToCompact[guid] = guidToCompact[guid] or {}
            guidToCompact[guid][f] = true
            frameGUID[f] = guid
        end
    end
end

function HP.TeardownTest()
    local guid = UnitGUID("player")
    local layout = Settings.testModeLayout or 1
    local count = LAYOUT_CONFIG[layout].count
    for i = 1, count do
        local f = testFrameList[i]
        if f then
            f:Hide()
            if guid and guidToCompact[guid] then
                guidToCompact[guid][f] = nil
                if not next(guidToCompact[guid]) then
                    guidToCompact[guid] = nil
                end
            end
            frameGUID[f] = nil
            frameData[f] = nil
        end
    end
    if testContainer then
        testContainer:Hide()
        testContainer = nil
    end
    testFrameList = {}
end

-- Expose testContainer for Init.lua
function HP.GetTestContainer()
    return testContainer
end

---------------------------------------------------------------------------
-- Debug: nameplate diagnostics (/hp np)
---------------------------------------------------------------------------
function HP.DebugNameplates()
    print("|cff33ccffHealPredict Nameplate Debug|r")
    print(fmt("  showNameplates=%s", tostring(Settings.showNameplates)))

    local count = 0
    local tracked = 0
    for _, unit in ipairs(C_NamePlate and C_NamePlate.GetNamePlates() or {}) do
        count = count + 1
        local plate = unit
        local uf = plate.UnitFrame or plate.unitFrame
        local hasHB = (uf and (uf.healthBar or uf.healthbar or uf.HealthBar)) and "Y" or "N"
        local plateName = plate.GetName and plate:GetName() or "anon"
        local pUnit = plate.namePlateUnitToken or (uf and uf.displayedUnit) or "?"
        local friendly = pUnit ~= "?" and UnitCanAssist("player", pUnit) or false
        local inFD = uf and frameData[uf] and "Y" or "N"
        if uf and HP.guidToPlate and UnitGUID(pUnit) and HP.guidToPlate[UnitGUID(pUnit)] then
            tracked = tracked + 1
        end
        print(fmt("  [%s] unit=%s friendly=%s uf=%s hb=%s tracked=%s",
            plateName, pUnit, tostring(friendly),
            uf and "Y" or "N", hasHB, inFD))
    end
    if count == 0 then
        print("  No nameplates currently visible.")
    else
        print(fmt("  Total: %d plates, %d tracked by HP", count, tracked))
    end
end

---------------------------------------------------------------------------
-- Debug: print HealEngine state for current target (/hp debug)
-- Helps diagnose Issues 3,4,8 (Renew, PoH, absorbs not predicting)
---------------------------------------------------------------------------
function HP.DebugTarget()
    local unit = "target"
    if not UnitExists(unit) then unit = "player" end

    local name = UnitName(unit)
    local guid = UnitGUID(unit)
    local hp = UnitHealth(unit)
    local max = UnitHealthMax(unit)
    local me = UnitGUID("player")

    print("|cff33ccffHealPredict Debug|r — " .. (name or "?") .. " (" .. (unit or "?") .. ")")
    print("  GUID: " .. (guid or "nil"))
    print(fmt("  Health: %d / %d (%.0f%%)", hp, max, max > 0 and hp/max*100 or 0))

    -- Engine internals
    local inUnitMap = Engine.unitMap and Engine.unitMap[guid] or nil
    local myInMap = Engine.unitMap and Engine.unitMap[me] or nil
    print(fmt("  Engine: myGUID=%s  inUnitMap=%s  myUnit=%s",
        Engine.myGUID and strsub(Engine.myGUID, 1, 20) or "NIL",
        inUnitMap and tostring(inUnitMap) or "NO",
        myInMap and tostring(myInMap) or "NO"))

    -- Scan auras for known heal spell IDs and check rankOf
    local auraInfo = {}
    local idx = 1
    while true do
        local aName, _, _, _, _, _, source, _, _, sid = UnitBuff(unit, idx)
        if not aName then break end
        local hasRank = sid and Engine.rankOf and Engine.rankOf[sid]
        local isTick = aName and Engine.tickInfo and Engine.tickInfo[aName]
        local isCast = aName and Engine.castInfo and Engine.castInfo[aName]
        if hasRank or isTick or isCast then
            tinsert(auraInfo, fmt("    [%s] id=%s rank=%s tick=%s cast=%s src=%s",
                aName, tostring(sid),
                hasRank and tostring(hasRank) or "NO",
                isTick and "Y" or "N",
                isCast and "Y" or "N",
                source and (UnitGUID(source) == me and "SELF" or strsub(source, 1, 8)) or "?"))
        end
        idx = idx + 1
    end
    if #auraInfo > 0 then
        print("  |cffaaaaff[Heal-related auras]|r")
        for _, line in ipairs(auraInfo) do print(line) end
    end

    -- Heal data
    local mod = Engine:GetHealModifier(guid) or 1
    local selfAmt = Engine:GetHealAmount(guid, Engine.ALL_HEALS, nil, me) or 0
    local othersAmt = Engine:GetOthersHealAmount(guid, Engine.ALL_HEALS) or 0
    print(fmt("  Engine: self=%.0f  others=%.0f  mod=%.2f", selfAmt, othersAmt, mod))

    -- Ticking records
    local tickCount = 0
    if Engine.ticking then
        for casterGUID, spells in pairs(Engine.ticking) do
            for sName, rec in pairs(spells) do
                if rec.targets and rec.targets[guid] then
                    local e = rec.targets[guid]
                    tickCount = tickCount + 1
                    print(fmt("  |cff44ff44TICK|r [%s] from %s: amt=%.0f stacks=%d tLeft=%d end=%.1f",
                        sName, casterGUID == me and "SELF" or strsub(casterGUID, 1, 16),
                        e[1] or 0, e[2] or 0, e[4] or 0, e[3] or 0))
                end
            end
        end
    end

    -- Inbound records
    local inCount = 0
    if Engine.inbound then
        for casterGUID, spells in pairs(Engine.inbound) do
            for sid, rec in pairs(spells) do
                if rec.targets and rec.targets[guid] then
                    local e = rec.targets[guid]
                    inCount = inCount + 1
                    print(fmt("  |cffffff44CAST|r [%s id=%d] from %s: amt=%.0f end=%.1f",
                        rec.spellName or "?", sid,
                        casterGUID == me and "SELF" or strsub(casterGUID, 1, 16),
                        e[1] or 0, e[3] or 0))
                end
            end
        end
    end

    if tickCount == 0 and inCount == 0 then
        print("  No active heal records on this target.")
    end

    -- Shield data
    local shield = HP.shieldAmounts[guid]
    if shield then
        print(fmt("  |cff8888ffShield absorb:|r %d", shield))
    end

    -- Settings check
    print(fmt("  testMode=%s  showOthers=%s  filterHoT=%s",
        tostring(HP._testMode), tostring(Settings.showOthers), tostring(Settings.filterHoT)))

    -- Health bar diagnostics: find all frames tracking this GUID
    if guid then
        local barInfo = {}
        for frame, fd in pairs(frameData) do
            local fGUID = HP.frameGUID[frame]
            if fGUID == guid and fd.hb then
                local hb = fd.hb
                local bMin, bMax = hb:GetMinMaxValues()
                local bVal = hb:GetValue()
                local bW = hb:GetWidth()
                local fillPct = bMax > 0 and (bVal / bMax * 100) or 0
                local fName = frame.GetName and frame:GetName() or "anon"
                local fType = fd.frameType or (fd.usesGradient and "compact" or "unit")
                tinsert(barInfo, fmt("    [%s] type=%s  bar: %d/%d (%.0f%%)  w=%.0f  vis=%s",
                    fName, fType, bVal, bMax, fillPct, bW,
                    hb:IsVisible() and "Y" or "N"))
            end
        end
        if #barInfo > 0 then
            print("  |cffffaa44[Health bar state]|r")
            for _, line in ipairs(barInfo) do print(line) end
            print(fmt("    API: UnitHealth=%d  UnitHealthMax=%d", hp, max))
        end
    end
end



---------------------------------------------------------------------------
-- Overheal Statistics System
---------------------------------------------------------------------------
local overhealStats = {
    session = {
        totalHealing = 0,
        effectiveHealing = 0,
        overhealing = 0,
        spells = {}, -- [spellName] = {casts, total, overheal}
    }
}
HP.overhealStats = overhealStats

-- Display frame for overheal stats
local overhealStatsFrame = nil

local function CreateOverhealStatsFrame()
    if overhealStatsFrame then return overhealStatsFrame end
    
    local f = CreateFrame("Frame", "HP_OverhealStats", UIParent)
    f:SetSize(220, 60)
    f:SetFrameStrata("BACKGROUND")
    f:Hide()
    
    -- Background
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    f.bg = bg
    
    -- Border (visible when unlocked)
    local border = CreateFrame("Frame", nil, f, "BackdropTemplate")
    border:SetAllPoints()
    border:SetBackdrop({
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 12,
    })
    border:SetBackdropBorderColor(1, 0.8, 0, 1) -- Gold border when unlocked
    border:Hide()
    f.border = border
    
    -- Drag handle (visible when unlocked)
    local handle = f:CreateTexture(nil, "OVERLAY")
    handle:SetSize(16, 16)
    handle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    handle:SetTexture("Interface\\RAIDFRAME\\UI-RAIDFRAME-ARROW")
    handle:SetTexCoord(0, 1, 0, 1)
    handle:SetVertexColor(1, 0.8, 0)
    handle:Hide()
    f.handle = handle
    
    -- Lock status text
    local lockText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lockText:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
    lockText:SetText("|cffffff00UNLOCKED|r")
    lockText:Hide()
    f.lockText = lockText
    
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    title:SetText("|cff33ccffOverheal Stats|r")
    f.title = title
    
    local mainText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    mainText:SetJustifyH("LEFT")
    f.mainText = mainText
    
    local detailText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detailText:SetPoint("TOPLEFT", mainText, "BOTTOMLEFT", 0, -2)
    detailText:SetJustifyH("LEFT")
    f.detailText = detailText
    
    -- Mouse handling for dragging
    f:SetScript("OnMouseDown", function(self, button)
        if not Settings.overhealStatsLocked and button == "LeftButton" then
            self:StartMoving()
        end
    end)
    f:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        -- Save user-dragged position
        local point, _, relPoint, x, y = self:GetPoint()
        if point then
            Settings.overhealStatsCustomPos = { point, relPoint, x, y }
        end
    end)
    f:EnableMouse(true)
    f:SetMovable(true)
    
    -- Apply initial scale
    local scale = Settings.overhealStatsScale or 1
    f:SetScale(scale)
    
    overhealStatsFrame = f
    return f
end

function HP.UpdateOverhealStatsAnchor()
    local f = CreateOverhealStatsFrame()

    f:ClearAllPoints()
    local custom = Settings.overhealStatsCustomPos
    if custom then
        f:SetPoint(custom[1], UIParent, custom[2], custom[3], custom[4])
    else
        local pos = Settings.overhealStatsPos or 1
        if pos == 1 then -- Top-Left
            f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 10, -10)
        elseif pos == 2 then -- Top-Right
            f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
        elseif pos == 3 then -- Bottom-Left
            f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 10, 10)
        else -- Bottom-Right
            f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -10, 10)
        end
    end

    if Settings.overhealStats then
        -- Don't show if hide-out-of-combat is on and we're not in combat
        local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
        if Settings.overhealStatsHideOOC and not inCombat then
            f:Hide()
        else
            f:Show()
        end
    else
        f:Hide()
    end
end

-- Fade out and reset 8s after last heal recorded
local overhealLastHealTime = 0
local overhealFadeTimer = nil

-- OOC visibility state
local wasInCombat = false
local oocHideTimer = nil
local oocStartTime = nil

function HP.RecordOverheal(spellName, amount, overheal)
    if not Settings.overhealStats then return end

    -- Show frame when healing (respecting visibility settings)
    -- This ensures frame appears even when "hide OOC" is enabled
    if HP.ShouldShowOverhealStats() then
        CreateOverhealStatsFrame():Show()
    end

    -- Cancel any pending OOC hide timer (healing keeps the frame visible)
    if oocHideTimer then
        oocHideTimer = nil
        oocStartTime = nil
    end

    -- Restore text visibility if it was cleared
    if overhealStatsFrame then
        overhealStatsFrame.mainText:SetAlpha(1)
        overhealStatsFrame.detailText:SetAlpha(1)
    end

    local stats = overhealStats.session
    stats.totalHealing = stats.totalHealing + amount
    stats.overhealing = stats.overhealing + overheal
    stats.effectiveHealing = stats.effectiveHealing + (amount - overheal)

    local spell = stats.spells[spellName]
    if not spell then
        spell = { casts = 0, total = 0, overheal = 0 }
        stats.spells[spellName] = spell
    end
    spell.casts = spell.casts + 1
    spell.total = spell.total + amount
    spell.overheal = spell.overheal + overheal

    -- Throttle display updates to once per 0.5s to reduce garbage
    local now = GetTime()
    if not overhealStatsFrame or not overhealStatsFrame._lastDisplayUpdate or now - overhealStatsFrame._lastDisplayUpdate >= 0.5 then
        HP.UpdateOverhealStatsDisplay()
        if overhealStatsFrame then overhealStatsFrame._lastDisplayUpdate = now end
    elseif not overhealStatsFrame._displayPending then
        overhealStatsFrame._displayPending = true
        C_Timer.After(0.5, function()
            if overhealStatsFrame then
                overhealStatsFrame._displayPending = nil
                overhealStatsFrame._lastDisplayUpdate = GetTime()
                HP.UpdateOverhealStatsDisplay()
            end
        end)
    end

    -- Schedule fade+reset: each heal pushes the deadline forward
    overhealLastHealTime = GetTime()
    if not overhealFadeTimer then
        overhealFadeTimer = true
        local function CheckFade()
            local resetMode = Settings.overhealStatsResetMode or 1
            if resetMode ~= 1 then
                overhealFadeTimer = nil
                return -- Only auto-reset in "After delay" mode
            end
            
            local delay = Settings.overhealStatsResetDelay or 8
            local elapsed = GetTime() - overhealLastHealTime
            if elapsed >= delay then
                overhealFadeTimer = nil
                if overhealStatsFrame then
                    HP.ResetOverhealStats()
                    overhealStatsFrame.mainText:SetText("")
                    overhealStatsFrame.detailText:SetText("")
                end
            else
                -- Check again when the delay window should expire
                C_Timer.After(delay - elapsed + 0.1, CheckFade)
            end
        end
        local delay = Settings.overhealStatsResetDelay or 8
        C_Timer.After(delay + 0.1, CheckFade)
    end
end

function HP.UpdateOverhealStatsDisplay()
    if not overhealStatsFrame then return end
    
    local stats = overhealStats.session
    local pct = stats.totalHealing > 0 and (stats.overhealing / stats.totalHealing * 100) or 0
    
    overhealStatsFrame.mainText:SetText(fmt("Session: |cffff5555%.1f%%|r overheal", pct))
    
    -- Find top 3 overheal spells
    local sorted = {}
    for name, data in pairs(stats.spells) do
        local spellPct = data.total > 0 and (data.overheal / data.total * 100) or 0
        table.insert(sorted, { name = name, pct = spellPct, overheal = data.overheal })
    end
    table.sort(sorted, function(a, b) return a.overheal > b.overheal end)
    
    local detail = ""
    for i = 1, math.min(3, #sorted) do
        local s = sorted[i]
        detail = detail .. fmt("%s: %.0f%%\n", s.name, s.pct)
    end
    
    overhealStatsFrame.detailText:SetText(detail)
    local h = 40 + overhealStatsFrame.detailText:GetStringHeight()
    -- Ensure minimum height so the UNLOCKED text is visible when frame is movable
    if not Settings.overhealStatsLocked then h = math.max(h, 60) end
    overhealStatsFrame:SetHeight(h)
end

function HP.ResetOverhealStats()
    overhealStats.session = {
        totalHealing = 0,
        effectiveHealing = 0,
        overhealing = 0,
        spells = {},
    }
    HP.UpdateOverhealStatsDisplay()
end

-- Show/hide based on setting
function HP.ToggleOverhealStats()
    if Settings.overhealStats then
        local f = CreateOverhealStatsFrame()
        HP.UpdateOverhealStatsAnchor()
        -- Respect hide-out-of-combat: only show if in combat or OOC hide is off
        local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
        if Settings.overhealStatsHideOOC and not inCombat then
            f:Hide()
        else
            f:Show()
        end
    elseif overhealStatsFrame then
        overhealStatsFrame:Hide()
    end
end

-- Set frame movable state (show/hide border and handle)
function HP.SetOverhealStatsMovable(unlocked)
    if not overhealStatsFrame then return end
    
    Settings.overhealStatsLocked = not unlocked
    
    if unlocked then
        overhealStatsFrame.border:Show()
        overhealStatsFrame.handle:Show()
        overhealStatsFrame.lockText:Show()
        overhealStatsFrame:SetAlpha(1)
        -- Ensure frame is tall enough to show the UNLOCKED text
        if overhealStatsFrame:GetHeight() < 60 then
            overhealStatsFrame:SetHeight(60)
        end
    else
        overhealStatsFrame.border:Hide()
        overhealStatsFrame.handle:Hide()
        overhealStatsFrame.lockText:Hide()
        overhealStatsFrame:SetAlpha(1)
    end
end

-- Update frame scale
function HP.UpdateOverhealStatsScale()
    if not overhealStatsFrame then return end
    local scale = Settings.overhealStatsScale or 1
    overhealStatsFrame:SetScale(scale)
end

-- Check if overheal stats should be visible based on visibility setting
function HP.ShouldShowOverhealStats()
    if not Settings.overhealStats then return false end
    
    local visibility = Settings.overhealStatsVisibility or 1
    if visibility == 1 then -- Always
        return true
    end
    
    local inInstance, instanceType = IsInInstance()
    if visibility == 2 then -- Raid only
        return inInstance and (instanceType == "raid")
    elseif visibility == 3 then -- Dungeon only
        return inInstance and (instanceType == "party")
    elseif visibility == 4 then -- Raid & Dungeon
        return inInstance and (instanceType == "raid" or instanceType == "party")
    end
    return true
end

-- Update frame visibility based on settings
function HP.UpdateOverhealStatsVisibility()
    if not overhealStatsFrame then return end
    if HP.ShouldShowOverhealStats() then
        -- Respect OOC hide
        local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
        if Settings.overhealStatsHideOOC and not inCombat then
            overhealStatsFrame:Hide()
        else
            overhealStatsFrame:Show()
            HP.UpdateOverhealStatsAnchor()
        end
    else
        overhealStatsFrame:Hide()
    end
end

-- Handle out of combat visibility with delay
function HP.UpdateOverhealStatsCombatStatus()
    if not Settings.overhealStatsHideOOC then return end
    if not overhealStatsFrame then return end
    if not HP.ShouldShowOverhealStats() then return end

    local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
    if inCombat then
        -- Cancel any pending OOC hide
        if oocHideTimer then
            oocHideTimer = nil
            oocStartTime = nil
        end
        overhealStatsFrame:Show()
    else
        -- Hide immediately
        overhealStatsFrame:Hide()
        oocHideTimer = nil
        oocStartTime = nil
    end
end

-- Handle reset based on reset mode
local function HandleOverhealReset()
    local resetMode = Settings.overhealStatsResetMode or 1
    if resetMode == 1 then return end -- After delay is handled by timer
    
    -- For boss kill and instance end, we reset immediately
    HP.ResetOverhealStats()
    if overhealStatsFrame then
        overhealStatsFrame.mainText:SetText("")
        overhealStatsFrame.detailText:SetText("")
    end
end

-- Boss kill detection
local function OnBossKill()
    local resetMode = Settings.overhealStatsResetMode or 1
    if resetMode == 2 then -- Boss kill
        HandleOverhealReset()
    end
end

-- Instance end detection (player leaves instance)
local wasInInstance = false
local lastInstanceType = nil
local function CheckInstanceEnd()
    local inInstance, instanceType = IsInInstance()
    local resetMode = Settings.overhealStatsResetMode or 1
    
    if resetMode == 3 then -- Instance end
        if wasInInstance and not inInstance then
            -- Player left instance
            HandleOverhealReset()
        end
    end
    
    wasInInstance = inInstance
    lastInstanceType = instanceType
end

-- Set up event handlers for boss kills and instance changes
local overhealEventFrame = CreateFrame("Frame")
overhealEventFrame:RegisterEvent("BOSS_KILL")
overhealEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
overhealEventFrame:SetScript("OnEvent", function(self, event)
    if event == "BOSS_KILL" then
        OnBossKill()
    elseif event == "PLAYER_ENTERING_WORLD" then
        CheckInstanceEnd()
        HP.UpdateOverhealStatsVisibility()
    end
end)

-- Periodic check for combat status (OOC hide) and instance state
C_Timer.NewTicker(1, function()
    HP.UpdateOverhealStatsCombatStatus()
    HP.UpdateHealQueueCombatStatus()
    CheckInstanceEnd()
end)

---------------------------------------------------------------------------
-- Heal Queue Timeline
---------------------------------------------------------------------------
local healQueueFrame = nil
local healQueueBars = {}       -- reusable bar pool
local healQueueLabels = {}     -- reusable label pool
local healQueueDeficitLine = nil
local HQ_BAR_HEIGHT = 14
local HQ_MAX_BARS = 12
local HQ_HEADER_H = 18
local HQ_PADDING = 3

-- Class color lookup for caster GUIDs
local HQ_CLASS_COLORS = {
    ["WARRIOR"]     = { 0.78, 0.61, 0.43 },
    ["PALADIN"]     = { 0.96, 0.55, 0.73 },
    ["HUNTER"]      = { 0.67, 0.83, 0.45 },
    ["ROGUE"]       = { 1.00, 0.96, 0.41 },
    ["PRIEST"]      = { 1.00, 1.00, 1.00 },
    ["SHAMAN"]      = { 0.00, 0.44, 0.87 },
    ["MAGE"]        = { 0.25, 0.78, 0.92 },
    ["WARLOCK"]     = { 0.53, 0.53, 0.93 },
    ["DRUID"]       = { 1.00, 0.49, 0.04 },
}

local function HQ_GetClassColor(guid)
    if not guid then return 0.7, 0.7, 0.7 end
    local _, class = GetPlayerInfoByGUID(guid)
    if class and HQ_CLASS_COLORS[class] then
        return unpack(HQ_CLASS_COLORS[class])
    end
    return 0.7, 0.7, 0.7
end

local function HQ_GetShortName(guid)
    if not guid then return "?" end
    local _, _, _, _, _, name = GetPlayerInfoByGUID(guid)
    if name then
        -- Return first name only (strip server)
        return name:match("^([^%-]+)") or name
    end
    return "?"
end

local function CreateHealQueueFrame()
    if healQueueFrame then return healQueueFrame end

    local f = CreateFrame("Frame", "HP_HealQueue", UIParent)
    f:SetSize(Settings.healQueueWidth or 260, 60)
    f:SetFrameStrata("BACKGROUND")
    f:Hide()

    -- Background
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.7)
    f.bg = bg

    -- Border (visible when unlocked)
    local border = CreateFrame("Frame", nil, f, "BackdropTemplate")
    border:SetAllPoints()
    border:SetBackdrop({
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 12,
    })
    border:SetBackdropBorderColor(1, 0.8, 0, 1)
    border:Hide()
    f.border = border

    -- Drag handle
    local handle = f:CreateTexture(nil, "OVERLAY")
    handle:SetSize(16, 16)
    handle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    handle:SetTexture("Interface\\RAIDFRAME\\UI-RAIDFRAME-ARROW")
    handle:SetTexCoord(0, 1, 0, 1)
    handle:SetVertexColor(1, 0.8, 0)
    handle:Hide()
    f.handle = handle

    -- Lock status text
    local lockText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lockText:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
    lockText:SetText("|cffffff00UNLOCKED|r")
    lockText:Hide()
    f.lockText = lockText

    -- Title + target name
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -3)
    title:SetText("|cff33ccffHeal Queue|r")
    f.title = title

    local targetText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetText:SetPoint("LEFT", title, "RIGHT", 6, 0)
    targetText:SetJustifyH("LEFT")
    f.targetText = targetText

    -- "No incoming heals" text
    local emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    emptyText:SetText("|cff888888No incoming heals|r")
    emptyText:Hide()
    f.emptyText = emptyText

    -- Timeline area (child frame for bars)
    local timeline = CreateFrame("Frame", nil, f)
    timeline:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -(HQ_HEADER_H + 2))
    timeline:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    f.timeline = timeline

    -- Deficit marker (vertical red line)
    local defLine = timeline:CreateTexture(nil, "OVERLAY")
    defLine:SetWidth(2)
    defLine:SetColorTexture(1, 0.2, 0.2, 0.8)
    defLine:Hide()
    f.deficitLine = defLine
    healQueueDeficitLine = defLine

    -- Deficit label
    local defLabel = timeline:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    defLabel:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE")
    defLabel:Hide()
    f.deficitLabel = defLabel

    -- Pre-create bar pool
    for i = 1, HQ_MAX_BARS do
        local bar = timeline:CreateTexture(nil, "ARTWORK")
        bar:SetHeight(HQ_BAR_HEIGHT)
        bar:Hide()
        healQueueBars[i] = bar

        local label = timeline:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
        label:SetJustifyH("LEFT")
        label:Hide()
        healQueueLabels[i] = label
    end

    -- Mouse handling for dragging
    f:SetScript("OnMouseDown", function(self, button)
        if not Settings.healQueueLocked and button == "LeftButton" then
            self:StartMoving()
        end
    end)
    f:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        if point then
            Settings.healQueueCustomPos = { point, relPoint, x, y }
        end
    end)
    f:EnableMouse(true)
    f:SetMovable(true)

    -- Apply initial scale
    f:SetScale(Settings.healQueueScale or 1)

    healQueueFrame = f

    -- OnUpdate is set later via HP.StartHealQueueTicker() so it can reference
    -- the local HealQueueOnUpdate function defined after frame creation.

    return f
end

-- Get a bar from the pool (or create new if needed)
local function HQ_GetBar(index)
    if not healQueueBars[index] then
        local bar = healQueueFrame.timeline:CreateTexture(nil, "ARTWORK")
        bar:SetHeight(HQ_BAR_HEIGHT)
        bar:Hide()
        healQueueBars[index] = bar

        local label = healQueueFrame.timeline:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
        label:SetJustifyH("LEFT")
        label:Hide()
        healQueueLabels[index] = label
    end
    return healQueueBars[index], healQueueLabels[index]
end

function HP.UpdateHealQueueAnchor()
    local f = CreateHealQueueFrame()
    f:ClearAllPoints()

    local custom = Settings.healQueueCustomPos
    if custom then
        f:SetPoint(custom[1], UIParent, custom[2], custom[3], custom[4])
    else
        -- Default: bottom-center of screen
        f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 180)
    end

    if Settings.healQueue then
        -- Don't show if hide-out-of-combat is on and we're not in combat
        local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
        if Settings.healQueueHideOOC and Settings.healQueueLocked and not inCombat then
            f:Hide()
        else
            f:Show()
        end
    else
        f:Hide()
    end
end

function HP.ToggleHealQueue()
    if Settings.healQueue then
        local f = CreateHealQueueFrame()
        HP.UpdateHealQueueAnchor()
        HP.StartHealQueueTicker()
        -- Respect hide-out-of-combat: only show if in combat or OOC hide is off
        local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
        if Settings.healQueueHideOOC and Settings.healQueueLocked and not inCombat then
            f:Hide()
        else
            f:Show()
        end
    elseif healQueueFrame then
        healQueueFrame:Hide()
        HP.StopHealQueueTicker()
    end
end

function HP.SetHealQueueMovable(unlocked)
    if not healQueueFrame then return end

    Settings.healQueueLocked = not unlocked

    if unlocked then
        healQueueFrame.border:Show()
        healQueueFrame.handle:Show()
        healQueueFrame.lockText:Show()
        healQueueFrame:SetAlpha(1)
        if healQueueFrame:GetHeight() < 60 then
            healQueueFrame:SetHeight(60)
        end
    else
        healQueueFrame.border:Hide()
        healQueueFrame.handle:Hide()
        healQueueFrame.lockText:Hide()
        healQueueFrame:SetAlpha(1)
    end
end

function HP.UpdateHealQueueScale()
    if not healQueueFrame then return end
    healQueueFrame:SetScale(Settings.healQueueScale or 1)
end

function HP.UpdateHealQueueWidth()
    if not healQueueFrame then return end
    healQueueFrame:SetSize(Settings.healQueueWidth or 260, healQueueFrame:GetHeight())
end

-- Cached bar data for smooth OnUpdate interpolation (no allocations per frame)
local hqBarCache = {}    -- [i] = { landTime, barWidth, yOff, r, g, b, alpha, spellShort }
local hqActiveCount = 0  -- number of active bars this cycle
local hqDeficitTime = 0  -- landTime of the deficit marker entry (0 = hidden)
local hqLookahead = 4
local hqLastDataRefresh = 0
local HQ_DATA_INTERVAL = 0.1  -- refresh data 10x/sec

-- Data refresh: recalculates entries, colors, sizes. Called ~10x/sec from HP.Tick()
function HP.UpdateHealQueue()
    if not Settings.healQueue then return end
    if not healQueueFrame then return end

    -- OOC hide (skip when frame is unlocked so user can position it)
    if Settings.healQueueHideOOC and Settings.healQueueLocked then
        local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
        if not inCombat then
            healQueueFrame:Hide()
            return
        end
    end

    -- Determine target GUID
    local showMode = Settings.healQueueShowTarget or 1
    local unit, guid
    if showMode == 2 then
        unit = "mouseover"
        guid = UnitExists("mouseover") and UnitGUID("mouseover") or nil
    elseif showMode == 3 then
        if UnitExists("mouseover") then
            unit = "mouseover"
            guid = UnitGUID("mouseover")
        elseif UnitExists("target") then
            unit = "target"
            guid = UnitGUID("target")
        end
    else
        unit = "target"
        guid = UnitExists("target") and UnitGUID("target") or nil
    end

    if not guid or not unit then
        hqActiveCount = 0
        hqDeficitTime = 0
        for i = 1, HQ_MAX_BARS do
            if healQueueBars[i] then healQueueBars[i]:Hide() end
            if healQueueLabels[i] then healQueueLabels[i]:Hide() end
        end
        if healQueueDeficitLine then healQueueDeficitLine:Hide() end
        healQueueFrame.deficitLabel:Hide()
        healQueueFrame.targetText:SetText("")
        healQueueFrame.emptyText:Show()
        healQueueFrame:SetHeight(HQ_HEADER_H + 20)
        healQueueFrame:Show()
        return
    end

    healQueueFrame.emptyText:Hide()

    -- Show target name
    local targetName = UnitName(unit) or "Unknown"
    local hp = UnitHealth(unit)
    local maxHP = UnitHealthMax(unit)
    local deficit = maxHP - hp
    local deficitPct = maxHP > 0 and mathfloor(deficit / maxHP * 100) or 0

    if deficit > 0 then
        healQueueFrame.targetText:SetText(fmt("%s |cffff5555(-%d, %d%%)|r", targetName, deficit, deficitPct))
    else
        healQueueFrame.targetText:SetText(fmt("%s |cff55ff55(Full)|r", targetName))
    end

    -- Get timeline data from engine
    local lookahead = Settings.healQueueLookahead or 4
    hqLookahead = lookahead
    local entries = Engine:GetHealTimeline(guid, lookahead)
    local timelineWidth = healQueueFrame.timeline:GetWidth()

    if #entries == 0 then
        hqActiveCount = 0
        hqDeficitTime = 0
        for i = 1, HQ_MAX_BARS do
            if healQueueBars[i] then healQueueBars[i]:Hide() end
            if healQueueLabels[i] then healQueueLabels[i]:Hide() end
        end
        if healQueueDeficitLine then healQueueDeficitLine:Hide() end
        healQueueFrame.deficitLabel:Hide()
        healQueueFrame.emptyText:Show()
        healQueueFrame:SetHeight(HQ_HEADER_H + 20)
        healQueueFrame:Show()
        return
    end

    -- Build bar cache (colors, sizes, positions — everything except time-dependent X)
    local barCount = mathmin(#entries, HQ_MAX_BARS)
    hqActiveCount = barCount
    local showNames = Settings.healQueueShowNames
    local totalHeight = HQ_HEADER_H + 2
    local cumHeal = 0
    hqDeficitTime = 0

    for i = 1, barCount do
        local entry = entries[i]
        local bar, label = HQ_GetBar(i)

        -- Cache the landing time for smooth OnUpdate interpolation
        local cache = hqBarCache[i]
        if not cache then
            cache = {}
            hqBarCache[i] = cache
        end
        cache.landTime = entry.landTime

        -- Bar width proportional to heal size relative to maxHP
        local healFrac = maxHP > 0 and (entry.amount / maxHP) or 0.1
        healFrac = mathmax(0.03, mathmin(0.4, healFrac))
        cache.barWidth = mathmax(8, healFrac * timelineWidth)
        cache.yOff = -((i - 1) * (HQ_BAR_HEIGHT + HQ_PADDING))

        -- Color by class
        local r, g, b = HQ_GetClassColor(entry.caster)
        local alpha = 0.85
        if entry.healType == Engine.HOT_HEALS or entry.healType == Engine.CHANNEL_HEALS then
            alpha = 0.55
        end
        if entry.isSelf then
            alpha = mathmin(1.0, alpha + 0.15)
        end
        cache.r, cache.g, cache.b, cache.alpha = r, g, b, alpha

        -- Label text (pre-build spell short name, time is updated in OnUpdate)
        local spellShort = entry.spellName or ""
        if #spellShort > 12 then spellShort = strsub(spellShort, 1, 11) .. "." end
        cache.spellShort = spellShort
        cache.showLabel = showNames

        -- Apply static properties to bar
        bar:SetHeight(HQ_BAR_HEIGHT)
        bar:SetColorTexture(r, g, b, alpha)
        bar:Show()

        if showNames then
            label:Show()
        else
            label:Hide()
        end

        -- Track deficit marker
        cumHeal = cumHeal + entry.amount
        if hqDeficitTime == 0 and cumHeal >= deficit and deficit > 0 then
            hqDeficitTime = entry.landTime
        end

        totalHeight = totalHeight + HQ_BAR_HEIGHT + HQ_PADDING
    end

    -- Hide unused bars
    for i = barCount + 1, HQ_MAX_BARS do
        if healQueueBars[i] then healQueueBars[i]:Hide() end
        if healQueueLabels[i] then healQueueLabels[i]:Hide() end
    end

    -- Deficit line visibility (position updated in OnUpdate)
    if not Settings.healQueueShowDeficit or deficit <= 0 or hqDeficitTime == 0 then
        if healQueueDeficitLine then healQueueDeficitLine:Hide() end
        healQueueFrame.deficitLabel:Hide()
    end

    -- Resize frame height to fit content
    local minH = HQ_HEADER_H + 20
    if not Settings.healQueueLocked then minH = mathmax(minH, 60) end
    healQueueFrame:SetHeight(mathmax(minH, totalHeight + 6))
    healQueueFrame:Show()
end

-- Smooth per-frame position update (runs every rendered frame via OnUpdate)
local function HealQueueOnUpdate()
    if hqActiveCount == 0 then return end
    local now = GetTime()
    local lookahead = hqLookahead
    local timeline = healQueueFrame.timeline
    local timelineWidth = timeline:GetWidth()
    if timelineWidth <= 0 then return end

    for i = 1, hqActiveCount do
        local cache = hqBarCache[i]
        if not cache then break end
        local bar = healQueueBars[i]
        local label = healQueueLabels[i]
        if not bar then break end

        -- Smooth X position based on current time
        local timeFrac = (cache.landTime - now) / lookahead
        timeFrac = mathmax(0, mathmin(1, timeFrac))
        local xPos = timeFrac * timelineWidth

        -- Clamp bar width so it doesn't overflow
        local barWidth = cache.barWidth
        if xPos + barWidth > timelineWidth then
            barWidth = mathmax(8, timelineWidth - xPos)
        end

        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", timeline, "TOPLEFT", xPos, cache.yOff)
        bar:SetWidth(barWidth)

        -- Update label with live time countdown
        if cache.showLabel and label then
            local timeLeft = cache.landTime - now
            label:ClearAllPoints()
            label:SetPoint("LEFT", bar, "LEFT", 2, 0)
            label:SetText(fmt("%s %.1fs", cache.spellShort, timeLeft))
        end
    end

    -- Smooth deficit line position
    if hqDeficitTime > 0 and Settings.healQueueShowDeficit then
        local timeFrac = (hqDeficitTime - now) / lookahead
        timeFrac = mathmax(0, mathmin(1, timeFrac))
        local xPos = timeFrac * timelineWidth

        healQueueDeficitLine:ClearAllPoints()
        healQueueDeficitLine:SetPoint("TOPLEFT", timeline, "TOPLEFT", xPos, 0)
        healQueueDeficitLine:SetPoint("BOTTOMLEFT", timeline, "BOTTOMLEFT", xPos, 0)
        healQueueDeficitLine:Show()

        healQueueFrame.deficitLabel:ClearAllPoints()
        healQueueFrame.deficitLabel:SetPoint("BOTTOM", healQueueDeficitLine, "TOP", 0, 1)
        healQueueFrame.deficitLabel:SetText("|cffff5555Full|r")
        healQueueFrame.deficitLabel:Show()
    end
end

-- Start/Stop: hook into HP.Tick() for data, OnUpdate for animation
function HP.StartHealQueueTicker()
    if not healQueueFrame then return end
    healQueueFrame:SetScript("OnUpdate", HealQueueOnUpdate)
end

function HP.StopHealQueueTicker()
    if not healQueueFrame then return end
    healQueueFrame:SetScript("OnUpdate", nil)
end

-- OOC hide handling (piggyback on existing 1s ticker below overheal stats)
local hqWasInCombat = false

function HP.UpdateHealQueueCombatStatus()
    if not Settings.healQueue then return end
    if not Settings.healQueueHideOOC then return end
    if not healQueueFrame then return end
    -- Never hide while unlocked (user is positioning)
    if not Settings.healQueueLocked then return end

    local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
    if inCombat and not hqWasInCombat then
        healQueueFrame:Show()
        HP.StartHealQueueTicker()
    elseif not inCombat and hqWasInCombat then
        healQueueFrame:Hide()
    end
    hqWasInCombat = inCombat
end

-- Heal queue is initialized via HP.ToggleHealQueue() in PLAYER_ENTERING_WORLD
-- (after saved settings are loaded from profile)

---------------------------------------------------------------------------
-- Death Prediction System
-- Reuses HP.damageHistory from Core.lua (health trajectory) to avoid
-- duplicate tracking. Format: [guid] = { {[1]=timestamp, [2]=amount}, ... }
---------------------------------------------------------------------------
local deathPredFrames = {} -- [frame] = deathPredText

local function GetIncomingDPS(guid)
    local hist = HP.damageHistory[guid]
    if not hist or #hist == 0 then return 0 end

    local now = GetTime()
    local totalDmg = 0
    local window = 3 -- 3 second rolling window
    local count = 0

    for i = #hist, 1, -1 do
        if now - hist[i][1] <= window then
            totalDmg = totalDmg + hist[i][2]
            count = count + 1
        else
            break
        end
    end

    return count > 0 and (totalDmg / window) or 0
end

function HP.GetDeathPrediction(guid, currentHealth)
    if not Settings.deathPrediction then return nil end
    
    local incomingDPS = GetIncomingDPS(guid)
    if incomingDPS <= 0 then return nil end
    
    -- Get incoming heals from HealEngine
    local incomingHeal = Engine and Engine:GetHealAmount(guid, Engine.ALL_HEALS) or 0
    
    local effectiveHealth = currentHealth + incomingHeal
    local timeToDeath = effectiveHealth / incomingDPS
    
    return timeToDeath
end

function HP.CreateDeathPredText(frame, fd)
    if deathPredFrames[frame] then return deathPredFrames[frame] end
    
    local text = fd.indicatorOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    text:SetPoint("CENTER", fd.hb or frame, "CENTER", Settings.deathPredOffsetX or 0, Settings.deathPredOffsetY or 0)
    text:Hide()

    deathPredFrames[frame] = text
    return text
end

function HP.UpdateDeathPrediction(frame, fd, guid)
    if not Settings.deathPrediction then
        if deathPredFrames[frame] then
            deathPredFrames[frame]:Hide()
        end
        return
    end
    
    local unit = frame.displayedUnit or frame.unit
    if not unit then return end
    
    local health = UnitHealth(unit)
    local maxHealth = UnitHealthMax(unit)
    
    if health <= 0 or maxHealth <= 0 then
        if deathPredFrames[frame] then
            deathPredFrames[frame]:Hide()
        end
        return
    end
    
    local timeToDeath = HP.GetDeathPrediction(guid, health)
    if not timeToDeath then
        if deathPredFrames[frame] then
            deathPredFrames[frame]:Hide()
        end
        return
    end
    
    local threshold = Settings.deathPredThreshold or 3
    local text = deathPredFrames[frame] or HP.CreateDeathPredText(frame, fd)
    
    if timeToDeath < threshold then
        text:SetText(fmt("%.1fs", timeToDeath))
        if timeToDeath < 1.5 then
            text:SetTextColor(1, 0, 0) -- Critical: Red
        else
            text:SetTextColor(1, 1, 0) -- Warning: Yellow
        end
        text:Show()
    else
        text:Hide()
    end
end

function HP.HideAllDeathPredictions()
    for frame, text in pairs(deathPredFrames) do
        text:Hide()
    end
end

-- Damage cleanup now handled inline in Core.lua combat log handler

-- ========================================================================================
-- ENCOUNTER SUGGESTIONS PANEL
-- ========================================================================================

local encounterSuggestionsFrame = nil
local encounterChatThrottle = {} -- [message] = lastPrintTime

-- ========================================================================================
-- CD ADVISOR OVERLAY WIDGET
-- ========================================================================================

local cdAdvisorFrame = nil

local CD_ADVISOR_COLORS = {
    [1] = { 1, 0.2, 0.2 },   -- red (urgent, 0-3s)
    [2] = { 1, 0.6, 0.1 },   -- orange (warning, 3-8s)
    [3] = { 0.3, 0.7, 1.0 }, -- blue (info, 8-15s)
}

local function CreateCDAdvisorFrame()
    if cdAdvisorFrame then return cdAdvisorFrame end

    local f = CreateFrame("Frame", "HP_CDAdvisor", UIParent, "BackdropTemplate")
    f:SetSize(280, 28)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0, 0, 0, 0.8)
    f:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("CENTER", f, "CENTER", 0, 0)
    text:SetJustifyH("CENTER")
    f.text = text

    -- Draggable
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        if point then
            Settings.cdAdvisorPos = { point = point, x = x, y = y }
        end
    end)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)

    -- Restore saved position or default
    local pos = Settings.cdAdvisorPos
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOP", UIParent, "CENTER", 0, -120)
    end

    f:Hide()
    cdAdvisorFrame = f
    return f
end

local function ShowCDAdvisor(message, priority)
    if not Settings.cdAdvisorWidget then return end
    local f = CreateCDAdvisorFrame()
    local color = CD_ADVISOR_COLORS[priority] or CD_ADVISOR_COLORS[3]
    f.text:SetText(message)
    f.text:SetTextColor(color[1], color[2], color[3])
    -- Auto-size width to text
    local textWidth = f.text:GetStringWidth()
    f:SetWidth(math.max(textWidth + 24, 200))
    -- Border color matches urgency
    f:SetBackdropBorderColor(color[1], color[2], color[3], 0.9)
    f:Show()
end

local function HideCDAdvisor()
    if cdAdvisorFrame then cdAdvisorFrame:Hide() end
end

local function CreateEncounterSuggestionsFrame()
    if encounterSuggestionsFrame then return encounterSuggestionsFrame end

    local f = CreateFrame("Frame", "HP_EncounterSuggestions", UIParent, "BackdropTemplate")
    f:SetSize(260, 180)
    f:SetFrameStrata("MEDIUM")
    f:Hide()

    -- Background
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.75)
    f:SetBackdropBorderColor(0.2, 0.8, 1, 0.8) -- Teal border

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -8)
    title:SetJustifyH("LEFT")
    title:SetText("|cff33ccffHEALING LEARNING|r")
    f.title = title

    -- Separator line below title
    local sep1 = f:CreateTexture(nil, "ARTWORK")
    sep1:SetHeight(1)
    sep1:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    sep1:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    sep1:SetColorTexture(0.2, 0.8, 1, 0.4)

    -- Stats section
    local statsText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statsText:SetPoint("TOPLEFT", sep1, "BOTTOMLEFT", 0, -4)
    statsText:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    statsText:SetJustifyH("LEFT")
    statsText:SetSpacing(2)
    f.statsText = statsText

    -- Separator line below stats
    local sep2 = f:CreateTexture(nil, "ARTWORK")
    sep2:SetHeight(1)
    sep2:SetPoint("TOPLEFT", statsText, "BOTTOMLEFT", 0, -4)
    sep2:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    sep2:SetColorTexture(0.2, 0.8, 1, 0.4)

    -- Suggestions section
    local suggestionsText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    suggestionsText:SetPoint("TOPLEFT", sep2, "BOTTOMLEFT", 0, -4)
    suggestionsText:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    suggestionsText:SetJustifyH("LEFT")
    suggestionsText:SetSpacing(2)
    f.suggestionsText = suggestionsText

    -- Timers section
    local timersText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timersText:SetPoint("TOPLEFT", suggestionsText, "BOTTOMLEFT", 0, -4)
    timersText:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    timersText:SetJustifyH("LEFT")
    timersText:SetSpacing(2)
    f.timersText = timersText

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Dragging
    f:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then self:StartMoving() end
    end)
    f:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        -- Save position
        local point, _, _, x, y = self:GetPoint(1)
        if point then
            Settings.encounterPanelPos = { point = point, x = x, y = y }
        end
    end)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)

    -- Restore saved position or default to top-right
    local pos = Settings.encounterPanelPos
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -100)
    end

    encounterSuggestionsFrame = f
    return f
end

local function FormatNumber(n)
    if n >= 1000 then
        return string.format("%.1fk", n / 1000)
    end
    return string.format("%.0f", n)
end

function HP.UpdateEncounterSuggestions()
    local hasEncounter = HP.currentEncounter ~= nil
    local hasInstance = HP.currentInstance ~= nil
    if not hasEncounter and not hasInstance then return end

    local mode = Settings.encounterSuggestionMode or 1 -- 1=Chat, 2=Panel, 3=Both, 4=Disabled
    if mode == 4 then return end

    local now = GetTime()

    -- Encounter-specific stats (boss fight)
    local enc = HP.currentEncounter
    local data, currentHPS, overhealPct, bestHPS, hpsDiff, suggestions, timers
    if enc then
        data = enc.data
        local elapsed = now - enc.startTime
        if elapsed < 1 then return end

        currentHPS = enc.effectiveHealing / elapsed
        overhealPct = 0
        if enc.totalHealing > 0 then
            overhealPct = (enc.overhealing / enc.totalHealing) * 100
        end

        bestHPS = data.personalBests.hps
        hpsDiff = ""
        if bestHPS > 0 then
            local ratio = currentHPS / bestHPS
            if ratio >= 1 then
                hpsDiff = string.format(" |cff00ff00(+%.0f%%)|r", (ratio - 1) * 100)
            else
                hpsDiff = string.format(" |cffff4444(-%.0f%%)|r", (1 - ratio) * 100)
            end
        end

        suggestions = HP.GetEncounterSuggestions()

        timers = {}
        for _, moment in ipairs(data.keyMoments) do
            local timeInFight = moment.time
            local label = moment.note or moment.type
            local found = false
            for _, t in ipairs(timers) do
                if t.label == label then found = true; break end
            end
            if not found then
                timers[#timers + 1] = { label = label, time = timeInFight }
            end
        end
    end

    -- Instance-wide stats
    local inst = HP.currentInstance
    local instHPS, instOverhealPct, instElapsed
    if inst then
        instElapsed = now - inst.startTime
        if instElapsed > 0 then
            instHPS = inst.effectiveHealing / instElapsed
        else
            instHPS = 0
        end
        instOverhealPct = 0
        if inst.totalHealing > 0 then
            instOverhealPct = (inst.overhealing / inst.totalHealing) * 100
        end
    end

    -- === UI Panel mode ===
    if mode == 2 or mode == 3 then
        local f = CreateEncounterSuggestionsFrame()

        -- Title: show boss name during encounter, instance name otherwise
        if enc then
            f.title:SetText("|cff33ccffHEALING LEARNING:|r " .. (enc.bossName or "Unknown"))
        elseif inst then
            local diffText = inst.difficulty or ""
            if diffText ~= "" then diffText = " (" .. diffText .. ")" end
            f.title:SetText("|cff33ccffINSTANCE:|r " .. (inst.name or "Unknown") .. diffText)
        end

        -- Stats
        local statsLines = {}
        if enc then
            statsLines[#statsLines + 1] = string.format("Casts: %d  |  Overheal: %.0f%%", enc.casts, overhealPct)
            statsLines[#statsLines + 1] = string.format("Current HPS: %s", FormatNumber(currentHPS))
            if bestHPS and bestHPS > 0 then
                statsLines[#statsLines + 1] = string.format("Personal Best: %s%s", FormatNumber(bestHPS), hpsDiff)
            end
        end
        if inst then
            if enc then
                -- Show instance summary below boss stats
                statsLines[#statsLines + 1] = ""
                statsLines[#statsLines + 1] = string.format("|cff33ccffInstance:|r Pull %d  |  HPS: %s  |  Overheal: %.0f%%",
                    inst.pullCount, FormatNumber(instHPS), instOverhealPct)
            else
                -- Instance-only (trash fighting or idle in instance)
                statsLines[#statsLines + 1] = string.format("Pulls: %d  |  Overheal: %.0f%%", inst.pullCount, instOverhealPct)
                statsLines[#statsLines + 1] = string.format("Instance HPS: %s", FormatNumber(instHPS))
                -- Compare to instance average if available
                local key = HP.GetInstanceKey and HP.GetInstanceKey()
                if key and HP.instanceDB[key] then
                    local iData = HP.instanceDB[key]
                    local avgHPS = iData.averages and iData.averages.hps or 0
                    if avgHPS > 0 then
                        local ratio = instHPS / avgHPS
                        local diff
                        if ratio >= 1 then
                            diff = string.format("|cff00ff00+%.0f%%|r", (ratio - 1) * 100)
                        else
                            diff = string.format("|cffff4444-%.0f%%|r", (1 - ratio) * 100)
                        end
                        statsLines[#statsLines + 1] = string.format("Avg HPS: %s (%s)", FormatNumber(avgHPS), diff)
                    end
                end
            end
        end
        f.statsText:SetText(table.concat(statsLines, "\n"))

        -- Suggestions (encounter only)
        if suggestions and #suggestions > 0 then
            local sugLines = { "|cff33ccffSuggestions:|r" }
            for _, s in ipairs(suggestions) do
                sugLines[#sugLines + 1] = "  > " .. s.message
            end
            f.suggestionsText:SetText(table.concat(sugLines, "\n"))
            f.suggestionsText:Show()
        else
            f.suggestionsText:SetText("")
            f.suggestionsText:Hide()
        end

        -- Timers (encounter only)
        if timers and #timers > 0 then
            local timerLines = { "|cff33ccffLearned Timers:|r" }
            for _, t in ipairs(timers) do
                timerLines[#timerLines + 1] = string.format("  * %s (at ~%.0fs)", t.label, t.time)
            end
            f.timersText:SetText(table.concat(timerLines, "\n"))
            f.timersText:Show()
        else
            f.timersText:SetText("")
            f.timersText:Hide()
        end

        -- Auto-resize height based on content
        local totalHeight = 16
        totalHeight = totalHeight + f.title:GetStringHeight() + 6
        totalHeight = totalHeight + f.statsText:GetStringHeight() + 6
        if f.suggestionsText:IsShown() then
            totalHeight = totalHeight + f.suggestionsText:GetStringHeight() + 6
        end
        if f.timersText:IsShown() then
            totalHeight = totalHeight + f.timersText:GetStringHeight() + 6
        end
        totalHeight = totalHeight + 8
        f:SetHeight(math.max(totalHeight, 80))

        f:Show()
    end

    -- === Chat mode ===
    if (mode == 1 or mode == 3) and suggestions then
        for _, s in ipairs(suggestions) do
            local msg = s.message
            local lastPrint = encounterChatThrottle[msg]
            if not lastPrint or (now - lastPrint) >= 30 then
                encounterChatThrottle[msg] = now
                print("|cff33ccffHealPredict:|r " .. msg)
            end
        end
    end

    -- === CD Advisor Widget ===
    if Settings.smartLearning and Settings.cdAdvisorWidget and suggestions then
        -- Find highest-priority PREDICT suggestion (lowest number = highest priority)
        local bestMsg, bestPriority = nil, 999
        for _, s in ipairs(suggestions) do
            if s.type == "PREDICT" and s.priority and s.priority < bestPriority then
                bestMsg = s.message
                bestPriority = s.priority
            end
        end
        if bestMsg then
            ShowCDAdvisor(bestMsg, bestPriority)
        else
            HideCDAdvisor()
        end
    else
        HideCDAdvisor()
    end
end

function HP.ShowEncounterPanel(instanceMode)
    local mode = Settings.encounterSuggestionMode or 1
    if mode == 2 or mode == 3 then
        local f = CreateEncounterSuggestionsFrame()
        if instanceMode and HP.currentInstance then
            local inst = HP.currentInstance
            local diffText = inst.difficulty or ""
            if diffText ~= "" then diffText = " (" .. diffText .. ")" end
            f.title:SetText("|cff33ccffINSTANCE:|r " .. (inst.name or "Unknown") .. diffText)
            f.statsText:SetText("Instance tracking started...")
        else
            f.title:SetText("|cff33ccffHEALING LEARNING:|r " .. (HP.currentEncounter and HP.currentEncounter.bossName or ""))
            f.statsText:SetText("Encounter starting...")
        end
        f.suggestionsText:SetText("")
        f.suggestionsText:Hide()
        f.timersText:SetText("")
        f.timersText:Hide()
        f:SetHeight(80)
        f:Show()
    end
    -- Reset chat throttle for new encounter
    wipe(encounterChatThrottle)
end

function HP.HideEncounterPanel()
    -- Hide CD advisor immediately
    HideCDAdvisor()

    if encounterSuggestionsFrame and encounterSuggestionsFrame:IsShown() then
        -- Delay so player can see final stats (configurable)
        C_Timer.After(Settings.panelHideDelay or 5, function()
            -- Don't hide if still tracking an instance or encounter
            if not HP.currentEncounter and not HP.currentInstance and encounterSuggestionsFrame then
                encounterSuggestionsFrame:Hide()
            end
        end)
    end
end

-- ========================================================================================
-- ENCOUNTER PANEL PREVIEW (fake data demo for /hp preview)
-- ========================================================================================

local previewTicker = nil
local previewElapsed = 0

local PREVIEW_BOSS = "Teron Gorefiend"

local PREVIEW_SUGGESTIONS = {
    { { message = "OOM in ~45s - conserve mana" }, { message = "Overheal high (38%) - try lower rank" } },
    { { message = "OOM in ~32s - conserve mana!" }, { message = "HPS is 12% below your best (1,320)" } },
    { { message = "HPS is 8% above your best!" } },
    { { message = "Shadow of Death incoming in 4s!" }, { message = "OOM in ~58s" } },
    { { message = "Incinerate incoming in 3s!" }, { message = "Overheal dropping - good pacing" } },
}

-- CD Advisor preview messages (cycles: info → warning → urgent)
local PREVIEW_CD_ADVISOR = {
    { message = "Incinerate in ~12s (observed 5x)", priority = 3 },
    { message = "Shadow of Death in ~6s \226\128\148 save CDs!", priority = 2 },
    { message = "Crushing Shadows NOW! (in 2s) \226\128\148 HERO/BPROT used here historically", priority = 1 },
}

local PREVIEW_TIMERS = {
    { label = "Incinerate", time = 45 },
    { label = "Shadow of Death", time = 90 },
    { label = "Crushing Shadows", time = 135 },
}

function HP.PreviewEncounterPanel()
    -- If already previewing, stop it
    if previewTicker then
        previewTicker:Cancel()
        previewTicker = nil
        previewElapsed = 0
        if encounterSuggestionsFrame then encounterSuggestionsFrame:Hide() end
        HideCDAdvisor()
        print("|cff33ccffHealPredict:|r Panel preview stopped.")
        return
    end

    local f = CreateEncounterSuggestionsFrame()
    previewElapsed = 0
    local sugIdx = 1
    local cdaIdx = 1

    print("|cff33ccffHealPredict:|r Showing panel preview with fake data. Type |cffffff00/hp preview|r again to stop.")

    local function UpdatePreview()
        previewElapsed = previewElapsed + 3

        -- Simulate climbing stats with some variance
        local fakeCasts = math.floor(previewElapsed * 1.6 + math.random(0, 5))
        local fakeOverheal = 14 + math.random(0, 24)
        local fakeHPS = 980 + math.random(0, 400)
        local bestHPS = 1320

        local ratio = fakeHPS / bestHPS
        local hpsDiff
        if ratio >= 1 then
            hpsDiff = string.format(" |cff00ff00(+%.0f%%)|r", (ratio - 1) * 100)
        else
            hpsDiff = string.format(" |cffff4444(-%.0f%%)|r", (1 - ratio) * 100)
        end

        -- Title
        f.title:SetText("|cff33ccffHEALING LEARNING:|r " .. PREVIEW_BOSS)

        -- Stats (including instance context preview)
        local fakePull = math.floor(previewElapsed / 18) + 1
        local fakeInstHPS = 720 + math.random(0, 300)
        f.statsText:SetText(table.concat({
            string.format("Casts: %d  |  Overheal: %d%%", fakeCasts, fakeOverheal),
            string.format("Current HPS: %s", FormatNumber(fakeHPS)),
            string.format("Personal Best: %s%s", FormatNumber(bestHPS), hpsDiff),
            "",
            string.format("|cff33ccffInstance:|r Pull %d  |  HPS: %s  |  Overheal: %d%%",
                fakePull, FormatNumber(fakeInstHPS), fakeOverheal - 4),
        }, "\n"))

        -- Rotate suggestions
        local sug = PREVIEW_SUGGESTIONS[sugIdx]
        sugIdx = sugIdx % #PREVIEW_SUGGESTIONS + 1
        local sugLines = { "|cff33ccffSuggestions:|r" }
        for _, s in ipairs(sug) do
            sugLines[#sugLines + 1] = "  > " .. s.message
        end
        f.suggestionsText:SetText(table.concat(sugLines, "\n"))
        f.suggestionsText:Show()

        -- Timers
        local timerLines = { "|cff33ccffLearned Timers:|r" }
        for _, t in ipairs(PREVIEW_TIMERS) do
            timerLines[#timerLines + 1] = string.format("  * %s (at ~%ds)", t.label, t.time)
        end
        f.timersText:SetText(table.concat(timerLines, "\n"))
        f.timersText:Show()

        -- Auto-resize
        local totalHeight = 16
        totalHeight = totalHeight + f.title:GetStringHeight() + 6
        totalHeight = totalHeight + f.statsText:GetStringHeight() + 6
        if f.suggestionsText:IsShown() then
            totalHeight = totalHeight + f.suggestionsText:GetStringHeight() + 6
        end
        if f.timersText:IsShown() then
            totalHeight = totalHeight + f.timersText:GetStringHeight() + 6
        end
        totalHeight = totalHeight + 8
        f:SetHeight(math.max(totalHeight, 80))

        f:Show()

        -- Cycle CD Advisor preview
        if Settings.cdAdvisorWidget then
            local cda = PREVIEW_CD_ADVISOR[cdaIdx]
            cdaIdx = cdaIdx % #PREVIEW_CD_ADVISOR + 1
            ShowCDAdvisor(cda.message, cda.priority)
        end
    end

    -- Show immediately, then tick every 3 seconds
    UpdatePreview()
    previewTicker = C_Timer.NewTicker(3, UpdatePreview)
end
