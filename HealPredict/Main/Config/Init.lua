-- HealPredict - Init.lua
-- OnLoad, OnEvent, slash commands, migrations, profile management
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn

local HP = HealPredict

-- Local references
local Settings     = HP.Settings
local CopyTable    = HP.CopyTable
local MergeDefaults = HP.MergeDefaults
local wipe         = HP.wipe
local pairs        = pairs
local type         = type

---------------------------------------------------------------------------
-- Character key: "Name - Realm"
---------------------------------------------------------------------------
local function GetCharKey()
    local name, realm = UnitName("player"), GetRealmName()
    return (name or "Unknown") .. " - " .. (realm or "Unknown")
end
HP.GetCharKey = GetCharKey

---------------------------------------------------------------------------
-- Profile migration helpers
---------------------------------------------------------------------------
local function MigrateSettings(sv)
    -- Migration: single timeLimit -> separate timeframes
    if sv.timeLimit and not sv.directTimeframe then
        sv.directTimeframe  = sv.timeLimit
        sv.channelTimeframe = sv.timeLimit
        sv.hotTimeframe     = sv.timeLimit
        sv.timeLimit        = nil
    end

    -- Migration: single showDefensives -> per-category toggles
    if sv.showDefensives ~= nil and sv.showInvulns == nil then
        sv.showInvulns   = sv.showDefensives
        sv.showStrongMit = sv.showDefensives
        sv.showWeakMit   = false
    end
end

---------------------------------------------------------------------------
-- Profile system
---------------------------------------------------------------------------
local DB_VERSION = 1

local function InitDB()
    -- Initialize the account-wide DB
    if not _G.HealPredictDB then
        _G.HealPredictDB = { version = DB_VERSION, profiles = {}, charMap = {} }
    end
    local db = _G.HealPredictDB
    if not db.profiles then db.profiles = {} end
    if not db.charMap then db.charMap = {} end
    if not db.version then db.version = DB_VERSION end

    -- Auto-switch defaults (stored at DB level, not per-profile)
    if db.autoSwitch == nil then db.autoSwitch = false end
    if not db.soloProfile  then db.soloProfile  = "Default" end
    if not db.partyProfile then db.partyProfile = "Default" end
    if not db.raidProfile  then db.raidProfile  = "Default" end

    -- Create "Default" profile if it doesn't exist
    if not db.profiles["Default"] then
        db.profiles["Default"] = CopyTable(HP.DEFAULTS)
    end

    -- Migrate from old per-character SavedVariables
    local charKey = GetCharKey()
    if _G.HealPredictSettings and next(_G.HealPredictSettings) then
        -- Old per-character settings exist — import as a new profile
        local oldSV = _G.HealPredictSettings
        MigrateSettings(oldSV)
        MergeDefaults(oldSV, HP.DEFAULTS)

        -- If this character doesn't have a profile assignment yet, create one
        if not db.charMap[charKey] then
            local profileName = charKey
            db.profiles[profileName] = CopyTable(oldSV)
            db.charMap[charKey] = profileName
        end

        -- Clear the old per-character data so migration only happens once
        wipe(_G.HealPredictSettings)
    end

    -- Ensure this character has a profile assignment
    if not db.charMap[charKey] then
        db.charMap[charKey] = "Default"
    end

    -- Get the active profile name and data
    local profileName = db.charMap[charKey]
    if not db.profiles[profileName] then
        -- Profile was deleted; fall back to Default
        db.charMap[charKey] = "Default"
        profileName = "Default"
    end

    -- Apply migrations on the active profile data
    MigrateSettings(db.profiles[profileName])
    MergeDefaults(db.profiles[profileName], HP.DEFAULTS)

    -- Restore encounter learning data (account-wide)
    if not db.encounterDB then db.encounterDB = {} end
    HP.encounterDB = db.encounterDB

    -- Restore instance learning data (account-wide)
    if not db.instanceDB then db.instanceDB = {} end
    HP.instanceDB = db.instanceDB

    -- Prune stale instance data (>30 days inactive)
    if HP.PruneInstanceData then HP.PruneInstanceData() end

    -- Store references for quick access
    HP.db = db
    HP.activeProfile = profileName

    return db, profileName
end

---------------------------------------------------------------------------
-- Load profile data into active Settings table
---------------------------------------------------------------------------
local function LoadProfile(profileName)
    local db = HP.db
    if not db or not db.profiles[profileName] then return end

    HP.activeProfile = profileName
    db.charMap[GetCharKey()] = profileName

    wipe(Settings)
    -- First merge defaults to ensure all settings exist
    for k, v in pairs(HP.DEFAULTS) do
        Settings[k] = type(v) == "table" and CopyTable(v) or v
    end
    -- Then override with profile values
    for k, v in pairs(db.profiles[profileName]) do
        Settings[k] = CopyTable(v)
    end
end
HP.LoadProfile = LoadProfile

---------------------------------------------------------------------------
-- Save current Settings into the active profile
---------------------------------------------------------------------------
function HP.SaveSettings()
    local db = HP.db
    if not db then return end

    local profileName = HP.activeProfile or "Default"
    if not db.profiles[profileName] then
        db.profiles[profileName] = {}
    end

    wipe(db.profiles[profileName])
    for k, v in pairs(Settings) do
        db.profiles[profileName][k] = CopyTable(v)
    end
end

---------------------------------------------------------------------------
-- Profile management API
---------------------------------------------------------------------------
function HP.GetProfileList()
    local list = {}
    local db = HP.db
    if db and db.profiles then
        for name in pairs(db.profiles) do
            list[#list + 1] = name
        end
        table.sort(list)
    end
    return list
end

function HP.CreateProfile(name)
    if not name or name == "" then return false end
    local db = HP.db
    if not db then return false end
    if db.profiles[name] then return false end  -- already exists

    db.profiles[name] = CopyTable(HP.DEFAULTS)
    return true
end

function HP.CopyProfile(srcName, destName, allowOverwrite)
    local db = HP.db
    if not db then return false end
    if not db.profiles[srcName] then return false end
    if not destName or destName == "" then return false end
    if db.profiles[destName] and not allowOverwrite then return false, "exists" end

    db.profiles[destName] = CopyTable(db.profiles[srcName])
    return true
end

function HP.DeleteProfile(name)
    local db = HP.db
    if not db then return false end
    if name == "Default" then return false end  -- can't delete Default
    if not db.profiles[name] then return false end

    db.profiles[name] = nil

    -- Reassign any characters using this profile to Default
    for charKey, profName in pairs(db.charMap) do
        if profName == name then
            db.charMap[charKey] = "Default"
        end
    end

    -- If WE were using this profile, switch to Default
    if HP.activeProfile == name then
        LoadProfile("Default")
    end

    return true
end

function HP.SwitchProfile(name)
    local db = HP.db
    if not db or not db.profiles[name] then return false end

    -- Save current settings first
    HP.SaveSettings()

    -- Switch
    LoadProfile(name)

    -- Apply visual changes
    local optFrame = HP.GetOptionsFrame()
    if optFrame then
        optFrame:SetScale(Settings.panelScale)
    end
    if Settings.fastRaidUpdate then
        HP.StartFastUpdate()
    else
        HP.StopFastUpdate()
    end
    HP.ToggleMinimapButton()
    HP.RefreshBarTextures()
    HP.RefreshAll()
    if HP.RefreshOptions then HP.RefreshOptions() end

    return true
end

---------------------------------------------------------------------------
-- Profile auto-switch based on group size
---------------------------------------------------------------------------
HP._lastGroupType = nil

function HP.CheckAutoSwitch()
    local db = HP.db
    if not db or not db.autoSwitch then return end

    local groupType
    if IsInRaid() then
        groupType = "raid"
    elseif IsInGroup() then
        groupType = "party"
    else
        groupType = "solo"
    end

    if groupType == HP._lastGroupType then return end
    HP._lastGroupType = groupType

    local profileKey = groupType .. "Profile"
    local targetProfile = db[profileKey]
    if not targetProfile or targetProfile == HP.activeProfile then return end
    if not db.profiles[targetProfile] then return end

    HP.SwitchProfile(targetProfile)
    print("|cff33ccffHealPredict:|r Auto-switched to profile '" .. targetProfile .. "' (" .. groupType .. ")")
end

function HP.ResetDefaults()
    wipe(Settings)
    for k, v in pairs(HP.DEFAULTS) do
        Settings[k] = CopyTable(v)
    end
    HP.SaveSettings()
end

---------------------------------------------------------------------------
-- OnLoad / OnEvent for the XML frame
---------------------------------------------------------------------------
function HP_CoreFrame_OnLoad(self)
    self:RegisterEvent("ADDON_LOADED")

    local driver = CreateFrame("Frame")
    if C_NamePlate then
        driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    end
    driver:RegisterEvent("GROUP_ROSTER_UPDATE")
    driver:RegisterEvent("UNIT_PET")
    driver:RegisterEvent("UNIT_AURA")
    driver:RegisterEvent("UNIT_SPELLCAST_START")
    driver:RegisterEvent("UNIT_SPELLCAST_STOP")
    driver:RegisterEvent("UNIT_SPELLCAST_FAILED")
    driver:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    driver:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    driver:RegisterEvent("ENCOUNTER_START")
    driver:RegisterEvent("ENCOUNTER_END")
    driver:RegisterEvent("BOSS_KILL")
    driver:RegisterEvent("PLAYER_REGEN_DISABLED")
    driver:RegisterEvent("PLAYER_REGEN_ENABLED")
    driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    driver:SetScript("OnEvent", function(_, event, ...)
        if event == "COMBAT_LOG_EVENT_UNFILTERED" then
            HP.OnCombatLog()
        elseif event == "ENCOUNTER_START" then
            local encounterID, encounterName, difficultyID, groupSize = ...
            -- Instance tracking: start a boss pull (also starts encounter tracking internally)
            if HP.currentInstance and HP.StartInstancePull then
                HP.StartInstancePull(encounterName, encounterID, difficultyID)
            end
            -- Encounter learning (only if instance tracking didn't already start it)
            if Settings.smartLearning and not HP.currentEncounter then
                HP.StartEncounterTracking(encounterName, encounterID, difficultyID)
            end
        elseif event == "ENCOUNTER_END" then
            local encounterID, encounterName, difficultyID, groupSize, success = ...
            local wasKill = success == 1
            -- Instance tracking: end the boss pull (also ends encounter tracking internally)
            if HP.currentInstance and HP.EndInstancePull then
                HP.EndInstancePull(wasKill)
            end
            -- Encounter learning (only if instance pull didn't already end it)
            if HP.currentEncounter then
                HP.EndEncounterTracking(wasKill)
            end
        elseif event == "BOSS_KILL" then
            -- Fallback for Classic Era where ENCOUNTER_END may not fire
            local bossID, bossName = ...
            if HP.currentInstance and HP.EndInstancePull then
                local inst = HP.currentInstance
                if inst.currentPull and inst.currentPull.isBoss then
                    HP.EndInstancePull(true)
                end
            end
            if HP.currentEncounter then
                HP.EndEncounterTracking(true)
            end
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- Instance tracking: start a trash pull if no boss pull is active
            if HP.currentInstance and HP.StartInstancePull then
                local inst = HP.currentInstance
                if not inst.currentPull then
                    HP.StartInstancePull(nil, nil)
                end
            end
            -- Entering combat - check if we're fighting a boss (existing)
            if Settings.smartLearning then
                C_Timer.After(2, function()
                    if not HP.currentEncounter and InCombatLockdown() then
                        for i = 1, 4 do
                            local unit = "boss" .. i
                            if UnitExists(unit) then
                                local name = UnitName(unit)
                                HP.StartEncounterTracking(name, nil)
                                break
                            end
                        end
                    end
                end)
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- Instance tracking: end trash pull after a short delay
            if HP.currentInstance and HP.EndInstancePull then
                local inst = HP.currentInstance
                if inst.currentPull and not inst.currentPull.isBoss then
                    C_Timer.After(3, function()
                        if HP.currentInstance and not InCombatLockdown() then
                            local pull = HP.currentInstance.currentPull
                            if pull and not pull.isBoss then
                                HP.EndInstancePull(true)
                            end
                        end
                    end)
                end
            end
            -- Leaving combat - end encounter if active (standalone only)
            -- Skip if inside instance tracking with a boss pull — ENCOUNTER_END/BOSS_KILL handles it
            if HP.currentEncounter and not (HP.currentInstance and HP.currentInstance.currentPull and HP.currentInstance.currentPull.isBoss) then
                -- Delay to allow ENCOUNTER_END to arrive first
                C_Timer.After(5, function()
                    if HP.currentEncounter and not InCombatLockdown() then
                        HP.EndEncounterTracking(false)
                    end
                end)
            end
        elseif event == "ZONE_CHANGED_NEW_AREA" then
            -- Instance tracking: detect entering/leaving instances
            local inInstance, instanceType = IsInInstance()
            if inInstance and instanceType ~= "pvp" and instanceType ~= "arena" then
                if not HP.currentInstance and HP.StartInstanceRun then
                    HP.StartInstanceRun()
                end
            else
                if HP.currentInstance and HP.EndInstanceRun then
                    HP.EndInstanceRun(false)
                end
            end
        else
            HP.OnEvent(event, ...)
        end
    end)
    driver:SetScript("OnUpdate", HP.Tick)

    HP.InitAllUnitFrames()
    HP.CreateManaCostBar()
    HP.CreateManaForecastText()
    HP.CreateOOCRegenText()
    HP.UpdateOverhealStatsAnchor()
    HP.CreateOptions()

    SLASH_HEALPREDICT1 = "/healpredict"
    SLASH_HEALPREDICT2 = "/hp"
    SlashCmdList["HEALPREDICT"] = function(msg)
        msg = (msg or ""):lower():trim()
        if msg == "rc" then
            HP.DoRaidCheck()
            return
        end
        if msg == "debug" then
            HP.DebugTarget()
            return
        end
        if msg == "np" then
            HP.DebugNameplates()
            return
        end
        if msg == "snipes" then
            HP.DoSnipeReport()
            return
        end
        if msg == "changelog" then
            HP.ShowChangelog(HP.VERSION or "1.0.4")
            return
        end
        if msg == "stats" then
            HP.DoEfficiencyReport()
            return
        end
        if msg == "stats reset" then
            HP.ResetEfficiency()
            return
        end
        if msg == "learning" or msg == "learn" then
            HP.ShowLearningPanel()
            return
        end
        if msg == "preview" then
            HP.PreviewEncounterPanel()
            return
        end
        if msg == "instance" or msg == "inst" then
            if HP.ShowInstanceData then
                HP.ShowInstanceData()
            else
                print("|cff33ccffHealPredict:|r Instance tracking not available.")
            end
            return
        end
        if msg:sub(1, 9) == "learning " then
            local bossName = msg:sub(10)
            if bossName and bossName ~= "" then
                print(HP.FormatEncounterSummary(bossName))
            else
                HP.ShowLearningPanel()
            end
            return
        end
        local optFrame = HP.GetOptionsFrame()
        if not optFrame then return end
        if optFrame:IsShown() then
            optFrame:Hide()
        else
            HP.RefreshOptions()
            optFrame:Show()
        end
    end

    SLASH_HPTEST1 = "/hptest"
    SlashCmdList["HPTEST"] = function()
        if HP._testMode then
            HP._testMode = false
            if HP._ticker then
                HP._ticker:Cancel()
                HP._ticker = nil
            end
            HP.TeardownTest()
            HP.RefreshAll()
            print("|cff33ccffHealPredict:|r Test mode OFF")
        else
            HP._testMode = true
            HP.BuildTestFrames()
            local tc = HP.GetTestContainer()
            if tc then tc:Show() end
            HP._ticker = C_Timer.NewTicker(0.5, function()
                if HP._testMode then HP.RefreshAll() end
            end)
            print("|cff33ccffHealPredict:|r Test mode ON")
        end
    end

    SLASH_HPCOMPAT1 = "/hpcompat"
    SlashCmdList["HPCOMPAT"] = function(msg)
        msg = (msg or ""):lower():trim()
        
        if msg == "elvui" or msg == "elv" then
            if HP.DebugElvUIFrames then
                HP.DebugElvUIFrames()
            else
                print("|cff33ccffHealPredict:|r ElvUI debug not available")
            end
            return
        end

        if msg == "suf" or msg == "shadowed" then
            if HP.DebugSUFFrames then
                HP.DebugSUFFrames()
            else
                print("|cff33ccffHealPredict:|r SUF debug not available")
            end
            return
        end
        
        print("|cff33ccffHealPredict:|r |cffffcc00Compatibility Information|r")
        print("|cff33ccffHealPredict:|r HealPredict is designed for Blizzard's default UI.")
        print("|cff33ccffHealPredict:|r ")
        print("|cff33ccffHealPredict:|r |cffffff00Custom Unit Frame Addons:|r")
        print("|cff33ccffHealPredict:|r - |cff00ff00ElvUI:|r Full support - all customizations supported")
        print("|cff33ccffHealPredict:|r - TukUI: Limited support (similar to ElvUI)")
        print("|cff33ccffHealPredict:|r - |cff00ff00Shadowed Unit Frames (SUF):|r Full support - all customizations supported")
        print("|cff33ccffHealPredict:|r - VuhDo: Limited support")
        print("|cff33ccffHealPredict:|r ")
        print("|cff33ccffHealPredict:|r |cff00ff00What works:|r")
        print("|cff33ccffHealPredict:|r - Blizzard Compact Raid Frames (even with UI addons)")
        print("|cff33ccffHealPredict:|r - Nameplates (if using Blizzard nameplate base)")
        print("|cff33ccffHealPredict:|r - ElvUI unit frames with ALL customizations:")
        print("|cff33ccffHealPredict:|r   - Custom textures")
        print("|cff33ccffHealPredict:|r   - Vertical/horizontal orientation")
        print("|cff33ccffHealPredict:|r   - Reversed fill direction")
        print("|cff33ccffHealPredict:|r   - Custom colors and transparency")
        print("|cff33ccffHealPredict:|r ")
        print("|cff33ccffHealPredict:|r |cff00ffffCommands:|r")
        print("|cff33ccffHealPredict:|r - |cff00ff00/hpcompat elvui|r - Debug ElvUI frames")
        print("|cff33ccffHealPredict:|r - |cff00ff00/hpcompat suf|r - Debug Shadowed Unit Frames")
        print("|cff33ccffHealPredict:|r ")
        
        if HP._customUIDetected then
            print("|cff33ccffHealPredict:|r |cffffcc00Detected:|r " .. table.concat(HP._customUIList, ", "))
            if HP._elvUIActive then
                print("|cff33ccffHealPredict:|r |cff00ff00ElvUI integration: ACTIVE|r")
            end
        end
    end
end

function HP_CoreFrame_OnEvent(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == HP.ADDON_NAME then
        -- Initialize profile DB (handles migration from old per-char format)
        local db, profileName = InitDB()
        LoadProfile(profileName)

        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("PLAYER_LOGOUT")
        self:UnregisterEvent("ADDON_LOADED")

        local optFrame = HP.GetOptionsFrame()
        if optFrame then
            optFrame:SetScale(Settings.panelScale)
        end

        if Settings.fastRaidUpdate then
            HP.StartFastUpdate()
        end

        HP.efficiencySession = GetTime()
        HP.ToggleMinimapButton()

        -- Show changelog popup if version changed
        if HP.CheckChangelog then HP.CheckChangelog() end

        -- Detect custom UI addons and show compatibility notice
        C_Timer.After(2, function()
            local hasElvUI = _G.ElvUI and _G.ElvUI[1]
            local hasTukUI = _G.Tukui and _G.Tukui[1]
            local hasShadowUF = _G.ShadowUF
            local hasVuhDo = _G.VuhDo
            
            if hasElvUI or hasTukUI or hasShadowUF or hasVuhDo then
                local addons = {}
                if hasElvUI then tinsert(addons, "ElvUI") end
                if hasTukUI then tinsert(addons, "TukUI") end
                if hasShadowUF then tinsert(addons, "ShadowedUF") end
                if hasVuhDo then tinsert(addons, "VuhDo") end
                
                print("|cff33ccffHealPredict:|r |cffffcc00Compatibility Notice|r")
                print("|cff33ccffHealPredict:|r Detected: " .. table.concat(addons, ", "))
                
                if hasElvUI then
                    print("|cff33ccffHealPredict:|r |cff00ff00ElvUI full customization support active!|r")
                    print("|cff33ccffHealPredict:|r Supports: textures, orientation, reversed fill, colors")
                end
                if hasShadowUF then
                    print("|cff33ccffHealPredict:|r |cff00ff00SUF full customization support active!|r")
                    print("|cff33ccffHealPredict:|r Supports: textures, orientation, reversed fill, colors")
                end
                if not hasElvUI and not hasShadowUF then
                    print("|cff33ccffHealPredict:|r Custom unit frames may have limited support.")
                end
                
                print("|cff33ccffHealPredict:|r Use |cff00ff00/hp compat|r for more info.")
                
                -- Store for later use
                HP._customUIDetected = true
                HP._customUIList = addons
            end
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        HP.RefreshAll()
        if HP.ToggleHealQueue then HP.ToggleHealQueue() end
        if HP.ResetManaHistory then HP.ResetManaHistory() end
        if HP.ResetOOCRegen then HP.ResetOOCRegen() end
        C_Timer.After(1, function()
            if HP.CheckAutoSwitch then HP.CheckAutoSwitch() end
        end)
        
        -- Initialize ElvUI compatibility if detected
        C_Timer.After(3, function()
            if HP.DetectElvUI and HP.DetectElvUI() then
                HP.InitElvUICompat()
            end
        end)

        -- Initialize SUF compatibility if detected
        C_Timer.After(3, function()
            if HP.DetectSUF and HP.DetectSUF() then
                HP.InitSUFCompat()
            end
        end)
        
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")

    elseif event == "PLAYER_LOGOUT" then
        -- End active encounter/instance before saving
        if HP.currentEncounter then
            HP.EndEncounterTracking(false)
        end
        if HP.currentInstance and HP.EndInstanceRun then
            HP.EndInstanceRun(false)
        end
        -- Persist encounter and instance learning data
        if HP.db then
            HP.db.encounterDB = HP.encounterDB or {}
            HP.db.instanceDB = HP.instanceDB or {}
        end
        HP.SaveSettings()
    end
end

_G.HP_CoreFrame_OnLoad  = HP_CoreFrame_OnLoad
_G.HP_CoreFrame_OnEvent = HP_CoreFrame_OnEvent
