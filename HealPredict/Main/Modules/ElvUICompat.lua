-- HealPredict - ElvUI Compatibility Module
-- Full support for ElvUI customizations including textures, orientation, and styles
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn
-- Modifications by PineappleTuesday

local HP = HealPredict
local Settings = HP.Settings

-- Local references for performance
local tinsert = table.insert
local mathmin = math.min
local mathmax = math.max
local pairs = pairs
local ipairs = ipairs
local select = select
local unpack = unpack
local type = type

------------------------------------------------------------------------
-- ElvUI Detection and Settings Access
------------------------------------------------------------------------
function HP.DetectElvUI()
    if not _G.ElvUI then return false end
    local E = _G.ElvUI[1]
    if not E then return false end
    return true, E
end

-- Get ElvUI database settings for a specific frame
function HP.GetElvUIDB(frameType)
    local hasElvUI, E = HP.DetectElvUI()
    if not hasElvUI or not E.db then return nil end
    
    local db = E.db.unitframe
    if not db then return nil end
    
    -- Map frame types to ElvUI DB paths
    local dbPaths = {
        player = db.units and db.units.player,
        target = db.units and db.units.target,
        targettarget = db.units and db.units.targettarget,
        focus = db.units and db.units.focus,
        pet = db.units and db.units.pet,
        party = db.units and db.units.party,
        raid = db.units and db.units.raid,
        raid40 = db.units and db.units.raid40,
    }
    
    return dbPaths[frameType]
end

-- Get ElvUI global settings
function HP.GetElvUIGlobal()
    local hasElvUI, E = HP.DetectElvUI()
    if not hasElvUI or not E.db then return nil end
    return E.db.general or {}
end

-- Get ElvUI media/textures
function HP.GetElvUIMedia()
    local hasElvUI, E = HP.DetectElvUI()
    if not hasElvUI then return nil end
    
    -- ElvUI stores media in SharedMedia or E.media
    local media = E.media or {}
    return {
        statusBar = media.normTex or "Interface/TargetingFrame/UI-TargetingFrame-BarFill",
        glowTex = media.glowTex,
        blankTex = media.blankTex,
    }
end

------------------------------------------------------------------------
-- Get ElvUI Unit Frames (Comprehensive)
------------------------------------------------------------------------
function HP.GetElvUIFrames()
    local hasElvUI, E = HP.DetectElvUI()
    if not hasElvUI then return nil end
    
    local frames = {}
    local UF = E.UnitFrames
    if not UF then return nil end
    
    -- Get player frame
    if UF.player and UF.player.Health then
        frames.player = { frame = UF.player, type = "player", unit = "player" }
    end
    
    -- Get target frame
    if UF.target and UF.target.Health then
        frames.target = { frame = UF.target, type = "target", unit = "target" }
    end
    
    -- Get target of target frame
    if UF.targettarget and UF.targettarget.Health then
        frames.targettarget = { frame = UF.targettarget, type = "targettarget", unit = "targettarget" }
    end
    
    -- Get focus frame
    if UF.focus and UF.focus.Health then
        frames.focus = { frame = UF.focus, type = "focus", unit = "focus" }
    end
    
    -- Get pet frame
    if UF.pet and UF.pet.Health then
        frames.pet = { frame = UF.pet, type = "pet", unit = "pet" }
    end
    
    -- Get party frames (handle both single and grouped layouts)
    frames.party = {}
    if UF.party then
        if UF.party.groups then
            -- Grouped party frames (party1, party2, etc. as separate groups)
            for groupName, group in pairs(UF.party.groups) do
                if group and group.frames then
                    for i, frame in ipairs(group.frames) do
                        if frame and frame.Health then
                            tinsert(frames.party, { 
                                frame = frame, 
                                type = "party", 
                                unit = frame.unit or ("party" .. i),
                                group = groupName,
                                index = i 
                            })
                        end
                    end
                end
            end
        elseif UF.party.frames then
            -- Standard party frames array
            for i, frame in ipairs(UF.party.frames) do
                if frame and frame.Health then
                    tinsert(frames.party, { 
                        frame = frame, 
                        type = "party", 
                        unit = frame.unit or ("party" .. i),
                        index = i 
                    })
                end
            end
        end
    end
    
    -- Get raid frames (handle 10, 25, 40 man configurations)
    frames.raid = {}
    local raidTypes = { "raid", "raid40", "raidpet" }
    for _, raidType in ipairs(raidTypes) do
        if UF[raidType] then
            if UF[raidType].groups then
                for groupName, group in pairs(UF[raidType].groups) do
                    if group and group.frames then
                        for i, frame in ipairs(group.frames) do
                            if frame and frame.Health then
                                tinsert(frames.raid, { 
                                    frame = frame, 
                                    type = raidType, 
                                    unit = frame.unit or frame.displayedUnit,
                                    group = groupName,
                                    index = i 
                                })
                            end
                        end
                    end
                end
            elseif UF[raidType].frames then
                for i, frame in ipairs(UF[raidType].frames) do
                    if frame and frame.Health then
                        tinsert(frames.raid, { 
                            frame = frame, 
                            type = raidType, 
                            unit = frame.unit or frame.displayedUnit,
                            index = i 
                        })
                    end
                end
            end
        end
    end
    
    -- Get arena frames
    frames.arena = {}
    if UF.arena and UF.arena.frames then
        for i, frame in ipairs(UF.arena.frames) do
            if frame and frame.Health then
                tinsert(frames.arena, {
                    frame = frame,
                    type = "arena",
                    unit = frame.unit or ("arena" .. i),
                    index = i
                })
            end
        end
    end
    
    -- Get boss frames
    frames.boss = {}
    if UF.boss and UF.boss.frames then
        for i, frame in ipairs(UF.boss.frames) do
            if frame and frame.Health then
                tinsert(frames.boss, {
                    frame = frame,
                    type = "boss",
                    unit = frame.unit or ("boss" .. i),
                    index = i
                })
            end
        end
    end
    
    return frames
end

------------------------------------------------------------------------
-- Get ElvUI Frame Settings
------------------------------------------------------------------------
function HP.GetElvUIFrameSettings(frameInfo)
    if not frameInfo or not frameInfo.type then return nil end
    
    local db = HP.GetElvUIDB(frameInfo.type)
    if not db then return nil end
    
    local healthDB = db.health or {}
    
    return {
        -- Orientation: "HORIZONTAL" or "VERTICAL"
        orientation = healthDB.orientation or "HORIZONTAL",
        
        -- Fill direction: true = reversed (fill from right/top), false = normal
        reverseFill = healthDB.reverseFill or false,
        
        -- Custom texture path
        texture = healthDB.texture,
        
        -- Bar colors
        color = healthDB.color,
        colorByValue = healthDB.colorByValue,
        
        -- Size settings
        width = db.width,
        height = db.height,
        
        -- Position settings
        position = db.health and db.health.position,
        
        -- Attach to element (for cutaway support)
        attachTo = healthDB.attachTo,
        
        -- X/Y offsets
        xOffset = healthDB.xOffset or 0,
        yOffset = healthDB.yOffset or 0,
    }
end

------------------------------------------------------------------------
-- Setup HealPrediction on ElvUI Frame (Full Customization Support)
------------------------------------------------------------------------
function HP.SetupElvUIFrame(frameInfo)
    if not frameInfo or not frameInfo.frame then return end
    
    local elvFrame = frameInfo.frame
    if not elvFrame.Health then return end
    
    -- Already set up?
    if HP.frameData[elvFrame] then return end
    
    local hb = elvFrame.Health
    local unit = frameInfo.unit
    
    -- Get ElvUI settings for this frame type
    local elvSettings = HP.GetElvUIFrameSettings(frameInfo)
    local media = HP.GetElvUIMedia()
    
    -- Determine texture to use
    local texture = "Interface/TargetingFrame/UI-TargetingFrame-BarFill" -- Default
    if elvSettings and elvSettings.texture then
        texture = elvSettings.texture
    elseif media and media.statusBar then
        texture = media.statusBar
    end
    
    -- Store frame data
    local fd = { 
        hb = hb, 
        usesGradient = false, 
        bars = {},
        _isElvUI = true,
        _elvType = frameInfo.type,
        _elvSettings = elvSettings,
        unit = unit,
        texture = texture,
    }
    
    -- Create overlay frame that matches ElvUI's orientation
    local overlay = CreateFrame("Frame", nil, hb)
    overlay:SetAllPoints(hb)
    overlay:SetFrameLevel(hb:GetFrameLevel() + 1)
    fd.overlay = overlay
    
    -- Create prediction bars with proper orientation support
    for idx = 1, 5 do
        local tex = overlay:CreateTexture(nil, "BORDER", nil, 5)
        tex:SetTexture(texture)
        tex:SetDrawLayer("BORDER", 5)
        tex:Hide()
        fd.bars[idx] = tex
    end
    
    -- Store reference
    HP.frameData[elvFrame] = fd
    
    -- Hook into ElvUI's PostUpdateHealth if available
    if elvFrame.PostUpdateHealth then
        local original = elvFrame.PostUpdateHealth
        elvFrame.PostUpdateHealth = function(...)
            original(...)
            -- Update our prediction bars after ElvUI updates
            C_Timer.After(0, function()
                HP.UpdateElvUIFrame(elvFrame)
            end)
        end
    end
    
    -- Hook into ElvUI's UpdateElement if available (for configuration changes)
    if elvFrame.UpdateElement then
        local original = elvFrame.UpdateElement
        elvFrame.UpdateElement = function(frame, element, ...)
            original(frame, element, ...)
            -- If health element was updated, refresh our bars
            if element == "Health" then
                -- Re-read settings in case they changed
                local newSettings = HP.GetElvUIFrameSettings(frameInfo)
                if newSettings then
                    fd._elvSettings = newSettings
                    -- Update texture if changed
                    local newMedia = HP.GetElvUIMedia()
                    local newTexture = newSettings.texture or (newMedia and newMedia.statusBar) or texture
                    if newTexture ~= fd.texture then
                        fd.texture = newTexture
                        for idx = 1, 5 do
                            if fd.bars[idx] then
                                fd.bars[idx]:SetTexture(newTexture)
                            end
                        end
                    end
                end
                HP.UpdateElvUIFrame(elvFrame)
            end
        end
    end
    
    return fd
end

------------------------------------------------------------------------
-- Update HealPrediction on ElvUI Frame (Orientation Aware)
------------------------------------------------------------------------
function HP.UpdateElvUIFrame(elvFrame)
    local fd = HP.frameData[elvFrame]
    if not fd or not fd._isElvUI then return end
    
    local hb = fd.hb
    if not hb then return end
    
    local unit = fd.unit or elvFrame.unit
    if not unit or not UnitExists(unit) then
        for idx = 1, 5 do
            if fd.bars[idx] then fd.bars[idx]:Hide() end
        end
        return
    end
    
    -- Get current values
    local _, cap = hb:GetMinMaxValues()
    local hp = hb:GetValue()
    local barW = hb:GetWidth()
    local barH = hb:GetHeight()
    
    if cap <= 0 or barW <= 0 or barH <= 0 then
        for idx = 1, 5 do
            if fd.bars[idx] then fd.bars[idx]:Hide() end
        end
        return
    end
    
    -- Get ElvUI settings
    local settings = fd._elvSettings or {}
    local isVertical = settings.orientation == "VERTICAL"
    local isReversed = settings.reverseFill
    
    -- Get heal amounts (ot3 = foreign-HoT slot)
    local my1, my2, ot1, ot2, ot3
    if Settings.smartOrdering and HP.GetHealsSorted then
        my1, my2, ot1, ot2, ot3 = HP.GetHealsSorted(unit)
    elseif HP.GetHeals then
        my1, my2, ot1, ot2, ot3 = HP.GetHeals(unit)
    else
        return
    end
    ot3 = ot3 or 0

    -- Pick the correct color palette per frame type, mirroring Core/Render
    -- and SUFCompat. ElvUI party/raid frames use the "raid" (compact)
    -- palette; single-unit frames use the "unit" palette.
    -- useUnitColorsOnly forces party/raid to use the unit palette too.
    local elvType = fd._elvType
    local isCompact = (elvType == "party" or elvType == "raid"
                       or elvType == "raid40" or elvType == "raidpet")
    local useUnitPal = (not isCompact) or Settings.useUnitColorsOnly
    local isSorted = Settings.smartOrdering
    local pal, palOH
    if not useUnitPal then
        if isSorted then
            pal   = { "raidOtherDirect", "raidMyDirect", "raidOtherDirect", "raidMyHoT", "raidOtherHoT" }
            palOH = { "raidOtherDirectOH", "raidMyDirectOH", "raidOtherDirectOH", "raidMyHoTOH", "raidOtherHoTOH" }
        else
            pal   = { "raidMyDirect", "raidMyHoT", "raidOtherDirect", "raidOtherHoT", "raidOtherHoT" }
            palOH = { "raidMyDirectOH", "raidMyHoTOH", "raidOtherDirectOH", "raidOtherHoTOH", "raidOtherHoTOH" }
        end
    else
        if isSorted then
            pal   = { "unitOtherDirect", "unitMyDirect", "unitOtherDirect", "unitMyHoT", "unitOtherHoT" }
            palOH = { "unitOtherDirectOH", "unitMyDirectOH", "unitOtherDirectOH", "unitMyHoTOH", "unitOtherHoTOH" }
        else
            pal   = { "unitMyDirect", "unitMyHoT", "unitOtherDirect", "unitOtherHoT", "unitOtherHoT" }
            palOH = { "unitMyDirectOH", "unitMyHoTOH", "unitOtherDirectOH", "unitOtherHoTOH", "unitOtherHoTOH" }
        end
    end

    local amounts = {my1, my2, ot1, ot2, ot3}
    local colors = Settings.colors
    local opaMul = Settings.barOpacity

    local activePal = pal
    if Settings.useOverhealColors then
        local overhealing = mathmax((hp + my1 + my2 + ot1 + ot2 + ot3) / cap - 1, 0)
        if overhealing >= (Settings.overhealThreshold or 0) then
            activePal = palOH
        end
    end
    
    -- Calculate health position
    local healthPercent = hp / cap
    local healthPxH = healthPercent * barW  -- Horizontal position
    local healthPxV = healthPercent * barH  -- Vertical position
    
    -- Track position for stacking bars
    local currentPosH = healthPxH
    local currentPosV = healthPxV
    
    for idx = 1, 5 do
        local amount = amounts[idx] or 0
        local bar = fd.bars[idx]
        if not bar then return end
        
        if amount > 0 then
            local cData = colors[activePal[idx]]
            if cData then
                bar:SetVertexColor(cData[1], cData[2], cData[3], cData[4] * opaMul)
            end
            
            -- Calculate bar size based on heal amount
            local healPercent = amount / cap
            
            if isVertical then
                -- Vertical orientation (health fills bottom to top or top to bottom)
                local h = mathmin(healPercent * barH, barH - healthPxV)
                if h > 0.5 then
                    if isReversed then
                        -- Reversed: fill from top
                        bar:SetPoint("TOP", hb, "TOP", 0, -currentPosV)
                    else
                        -- Normal: fill from bottom
                        bar:SetPoint("BOTTOM", hb, "BOTTOM", 0, currentPosV)
                    end
                    bar:SetSize(barW, h)
                    bar:Show()
                    currentPosV = currentPosV + h
                else
                    bar:Hide()
                end
            else
                -- Horizontal orientation (default)
                local w = mathmin(healPercent * barW, barW - healthPxH)
                if w > 0.5 then
                    if isReversed then
                        -- Reversed: fill from right
                        bar:SetPoint("RIGHT", hb, "RIGHT", -currentPosH, 0)
                    else
                        -- Normal: fill from left
                        bar:SetPoint("LEFT", hb, "LEFT", currentPosH, 0)
                    end
                    bar:SetSize(w, barH)
                    bar:Show()
                    currentPosH = currentPosH + w
                else
                    bar:Hide()
                end
            end
        else
            bar:Hide()
        end
    end
end

------------------------------------------------------------------------
-- Initialize ElvUI Compatibility
------------------------------------------------------------------------
function HP.InitElvUICompat()
    local hasElvUI, E = HP.DetectElvUI()
    if not hasElvUI then return false end
    
    print("|cff33ccffHealPredict:|r Initializing ElvUI compatibility...")
    
    local frameList = HP.GetElvUIFrames()
    if not frameList then
        print("|cff33ccffHealPredict:|r |cffff4440Could not find ElvUI frames|r")
        return false
    end
    
    -- Setup all frame types
    local setupCount = 0
    
    -- Main unit frames
    if frameList.player then 
        HP.SetupElvUIFrame(frameList.player)
        setupCount = setupCount + 1
    end
    if frameList.target then 
        HP.SetupElvUIFrame(frameList.target)
        setupCount = setupCount + 1
    end
    if frameList.targettarget then 
        HP.SetupElvUIFrame(frameList.targettarget)
        setupCount = setupCount + 1
    end
    if frameList.focus then 
        HP.SetupElvUIFrame(frameList.focus)
        setupCount = setupCount + 1
    end
    if frameList.pet then 
        HP.SetupElvUIFrame(frameList.pet)
        setupCount = setupCount + 1
    end
    
    -- Party frames
    if frameList.party then
        for _, frameInfo in ipairs(frameList.party) do
            HP.SetupElvUIFrame(frameInfo)
            setupCount = setupCount + 1
        end
    end
    
    -- Raid frames
    if frameList.raid then
        for _, frameInfo in ipairs(frameList.raid) do
            HP.SetupElvUIFrame(frameInfo)
            setupCount = setupCount + 1
        end
    end
    
    -- Arena frames
    if frameList.arena then
        for _, frameInfo in ipairs(frameList.arena) do
            HP.SetupElvUIFrame(frameInfo)
            setupCount = setupCount + 1
        end
    end
    
    -- Boss frames
    if frameList.boss then
        for _, frameInfo in ipairs(frameList.boss) do
            HP.SetupElvUIFrame(frameInfo)
            setupCount = setupCount + 1
        end
    end
    
    -- Hook into ElvUI's group roster updates
    if E.UnitFrames and E.UnitFrames.CreateAndUpdateHeaderGroup then
        local original = E.UnitFrames.CreateAndUpdateHeaderGroup
        E.UnitFrames.CreateAndUpdateHeaderGroup = function(...)
            local result = original(...)
            C_Timer.After(0.5, function()
                HP.RefreshElvUIFrames()
            end)
            return result
        end
    end
    
    -- Hook into ElvUI's config changes
    if E.UpdateAll then
        local original = E.UpdateAll
        E.UpdateAll = function(self, ...)
            original(self, ...)
            -- Refresh all our frames when ElvUI config is updated
            C_Timer.After(0.5, function()
                HP.RefreshAllElvUISettings()
            end)
        end
    end
    
    -- Start update ticker for ElvUI frames
    C_Timer.NewTicker(0.05, function() -- 20 FPS for smoother updates
        HP.UpdateAllElvUIFrames()
    end)
    
    print("|cff33ccffHealPredict:|r |cff00ff00ElvUI compatibility active|r (" .. setupCount .. " frames)")
    HP._elvUIActive = true
    return true
end

------------------------------------------------------------------------
-- Refresh ElvUI Frame List (for dynamic groups)
------------------------------------------------------------------------
function HP.RefreshElvUIFrames()
    local frameList = HP.GetElvUIFrames()
    if not frameList then return end
    
    -- Check for new party frames
    if frameList.party then
        for _, frameInfo in ipairs(frameList.party) do
            if not HP.frameData[frameInfo.frame] then
                HP.SetupElvUIFrame(frameInfo)
            end
        end
    end
    
    -- Check for new raid frames
    if frameList.raid then
        for _, frameInfo in ipairs(frameList.raid) do
            if not HP.frameData[frameInfo.frame] then
                HP.SetupElvUIFrame(frameInfo)
            end
        end
    end
    
    -- Check for new arena frames
    if frameList.arena then
        for _, frameInfo in ipairs(frameList.arena) do
            if not HP.frameData[frameInfo.frame] then
                HP.SetupElvUIFrame(frameInfo)
            end
        end
    end
end

------------------------------------------------------------------------
-- Refresh All ElvUI Settings (when config changes)
------------------------------------------------------------------------
function HP.RefreshAllElvUISettings()
    for frame, fd in pairs(HP.frameData) do
        if fd._isElvUI then
            -- Re-read settings
            local frameInfo = {
                frame = frame,
                type = fd._elvType,
                unit = fd.unit,
            }
            local newSettings = HP.GetElvUIFrameSettings(frameInfo)
            if newSettings then
                fd._elvSettings = newSettings
                
                -- Update texture if changed
                local media = HP.GetElvUIMedia()
                local newTexture = newSettings.texture or (media and media.statusBar) or fd.texture
                if newTexture ~= fd.texture then
                    fd.texture = newTexture
                    for idx = 1, 5 do
                        if fd.bars[idx] then
                            fd.bars[idx]:SetTexture(newTexture)
                        end
                    end
                end
            end
            
            -- Force update
            HP.UpdateElvUIFrame(frame)
        end
    end
end

------------------------------------------------------------------------
-- Update All ElvUI Frames
------------------------------------------------------------------------
function HP.UpdateAllElvUIFrames()
    for frame, fd in pairs(HP.frameData) do
        if fd._isElvUI then
            HP.UpdateElvUIFrame(frame)
        end
    end
end

------------------------------------------------------------------------
-- Cleanup ElvUI Frames
------------------------------------------------------------------------
function HP.CleanupElvUIFrames()
    for frame, fd in pairs(HP.frameData) do
        if fd._isElvUI then
            if fd.bars then
                for idx = 1, 5 do
                    if fd.bars[idx] then 
                        fd.bars[idx]:Hide() 
                    end
                end
            end
            if fd.overlay then
                fd.overlay:Hide()
            end
        end
    end
    HP._elvUIActive = false
end

------------------------------------------------------------------------
-- Debug: Print ElvUI Frame Info
------------------------------------------------------------------------
function HP.DebugElvUIFrames()
    print("|cff33ccffHealPredict:|r |cffffcc00ElvUI Frame Debug|r")
    
    local hasElvUI, E = HP.DetectElvUI()
    if not hasElvUI then
        print("|cff33ccffHealPredict:|r ElvUI not detected")
        return
    end
    
    local frames = HP.GetElvUIFrames()
    if not frames then
        print("|cff33ccffHealPredict:|r Could not get ElvUI frames")
        return
    end
    
    print("|cff33ccffHealPredict:|r Main frames:")
    for frameType, frameInfo in pairs({
        player = frames.player,
        target = frames.target,
        targettarget = frames.targettarget,
        focus = frames.focus,
        pet = frames.pet,
    }) do
        if frameInfo then
            local settings = HP.GetElvUIFrameSettings(frameInfo)
            local orient = settings and settings.orientation or "HORIZONTAL"
            local reversed = settings and settings.reverseFill and "yes" or "no"
            print(string.format("  %s: %s (orient=%s, reversed=%s)", 
                frameType, 
                frameInfo.unit or "unknown",
                orient,
                reversed
            ))
        end
    end
    
    print("|cff33ccffHealPredict:|r Party frames: " .. (frames.party and #frames.party or 0))
    print("|cff33ccffHealPredict:|r Raid frames: " .. (frames.raid and #frames.raid or 0))
    print("|cff33ccffHealPredict:|r Arena frames: " .. (frames.arena and #frames.arena or 0))
    print("|cff33ccffHealPredict:|r Boss frames: " .. (frames.boss and #frames.boss or 0))
    
    -- Check our tracked frames
    local elvCount = 0
    for frame, fd in pairs(HP.frameData) do
        if fd._isElvUI then
            elvCount = elvCount + 1
        end
    end
    print("|cff33ccffHealPredict:|r HealPredict tracked ElvUI frames: " .. elvCount)
end
