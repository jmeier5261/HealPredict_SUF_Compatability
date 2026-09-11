-- CastTracking.lua — Cast Events, Combat Log, HoT Monitor, Roster, Zone
-- Part of HealEngine-1.0 split architecture
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn
-- Modifications by PineappleTuesday

local Engine = LibStub("HealEngine-1.0")
if not Engine then return end

---------------------------------------------------------------------------
-- Local aliases from Engine
---------------------------------------------------------------------------
local inbound        = Engine.inbound
local ticking        = Engine.ticking
local unitMap        = Engine.unitMap
local groupMap       = Engine.groupMap
local hotCount       = Engine.hotCount
local compressCache  = Engine.compressGUID
local decompressCache = Engine.decompressGUID
local newRecord      = Engine.newRecord
local addTarget      = Engine.addTarget
local dropTarget     = Engine.dropTarget
local wipeAllTargets = Engine.wipeAllTargets
local purgeAll       = Engine.purgeAll

local sendWire     = Engine.sendWire
local updateChannel = Engine.updateChannel
local parseDirect  = Engine.parseDirect
local parseChannel = Engine.parseChannel
local parseHoT     = Engine.parseHoT
local parseBomb    = Engine.parseBomb
local stopDirect   = Engine.stopDirect
local stopHoT      = Engine.stopHoT
local scanTargetMods = Engine.scanTargetMods

local castInfo = Engine.castInfo
local tickInfo = Engine.tickInfo

local DIRECT  = Engine._DIRECT
local CHANNEL = Engine._CHANNEL
local HOT     = Engine._HOT
local BOMB    = Engine._BOMB
local TICKING = Engine._TICKING

local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x01

local bit_band  = bit.band
local mathmax   = math.max
local mathceil  = math.ceil
local GetTime   = GetTime
local GetSpellInfo   = GetSpellInfo
local CastingInfo    = CastingInfo
local UnitGUID       = UnitGUID
local UnitName       = UnitName
local UnitInRaid     = UnitInRaid
local UnitIsVisible  = UnitIsVisible
local UnitIsCharmed  = UnitIsCharmed
local UnitPlayerControlled = UnitPlayerControlled
local IsInRaid       = IsInRaid
local IsInGroup      = IsInGroup
local IsInInstance   = IsInInstance
local GetZonePVPInfo = GetZonePVPInfo
local GetNumGroupMembers = GetNumGroupMembers
local GetRaidRosterInfo  = GetRaidRosterInfo
local GetSpellBonusHealing = GetSpellBonusHealing
local GetSpellCritChance   = GetSpellCritChance
local IsSpellInRange       = IsSpellInRange
local CheckInteractDistance = CheckInteractDistance
local strsplit   = strsplit
local strformat  = string.format
local strmatch   = string.match
local select     = select
local pairs      = pairs
local next       = next
local wipe       = wipe
local tinsert    = table.insert
local tconcat    = table.concat
local unpack     = unpack

local buckets     = Engine.buckets
local bucketFrame = Engine.bucketFrame
local BUCKET_WINDOW = Engine.BUCKET_WINDOW

---------------------------------------------------------------------------
-- DECOMPRESS HELPER — convert compressed target string to full GUIDs
-- Used for callback firing (consumers expect full GUIDs, wire uses compressed)
---------------------------------------------------------------------------
local decompTmp = {}
local function decompressTargets(compressedCSV)
    wipe(decompTmp)
    local parts = { strsplit(",", compressedCSV) }
    for i = 1, #parts do
        local full = decompressCache[parts[i]] or parts[i]
        if full then decompTmp[i] = full end
    end
    return unpack(decompTmp, 1, #parts)
end

---------------------------------------------------------------------------
-- CAST TARGET RESOLUTION
---------------------------------------------------------------------------
-- Priority: UNIT_SPELLCAST_SENT target > current target > mouseover
local castTargets  = {}   -- castTargets[spellID] = targetGUID
local castPriority = {}

local function setCastTarget(spellID, guid, prio)
    if not castTargets[spellID] or (prio or 0) >= (castPriority[spellID] or 0) then
        castTargets[spellID] = guid
        castPriority[spellID] = prio or 0
    end
end

---------------------------------------------------------------------------
-- SPELLCAST EVENTS
---------------------------------------------------------------------------
local function onCastSent(unit, target, castGUID, spellID)
    if unit ~= "player" then return end
    -- Resolve target GUID from name
    if target and target ~= "" then
        local guid
        -- Check party/raid for name match in unitMap
        for g, u in pairs(unitMap) do
            if UnitName(u) == target then
                guid = g
                break
            end
        end
        -- Fallback: direct API scan if unitMap miss (handles server suffixes, late roster updates)
        if not guid then
            if UnitName("target") == target then
                guid = UnitGUID("target")
                -- Add friendly NPC targets to unitMap so CLEU + GetTargets work
                if guid and not unitMap[guid] and UnitIsFriend("player", "target") then
                    unitMap[guid] = "target"
                end
            elseif UnitName("mouseover") == target then
                guid = UnitGUID("mouseover")
                if guid and not unitMap[guid] and UnitIsFriend("player", "mouseover") then
                    unitMap[guid] = "mouseover"
                end
            else
                -- Scan group units directly
                local prefix, count
                if IsInRaid() then
                    prefix, count = "raid", GetNumGroupMembers()
                elseif GetNumGroupMembers() > 0 then
                    prefix, count = "party", GetNumGroupMembers() - 1
                end
                if prefix then
                    for i = 1, count do
                        local u = prefix .. i
                        if UnitName(u) == target then
                            guid = UnitGUID(u)
                            -- Also backfill unitMap so subsequent casts resolve instantly
                            if guid and not unitMap[guid] then
                                unitMap[guid] = u
                            end
                            break
                        end
                    end
                end
            end
        end
        if guid then
            setCastTarget(spellID, guid, 10)
        end
    end
end

local function onCastStart(unit, cast, spellID)
    if unit ~= "player" then return end
    local spellName = GetSpellInfo(spellID)
    if not spellName then return end

    -- Not a healing spell we track?
    if not castInfo[spellName] and not tickInfo[spellName] then return end
    if UnitIsCharmed("player") or not UnitPlayerControlled("player") then return end

    -- Try exact spellID first (from UNIT_SPELLCAST_SENT), then wildcard 0 (from hooks)
    local castGUID = castTargets[spellID] or castTargets[0]
    local castUnit = castGUID and unitMap[castGUID]

    -- Self-target spells fallback
    local SELF_TARGET_SPELLS = Engine.SELF_TARGET_SPELLS
    if not castUnit and SELF_TARGET_SPELLS and SELF_TARGET_SPELLS[spellName] then
        castGUID = Engine.myGUID
        castUnit = "player"
    end
    -- Fallback: resolve castUnit from GUID via direct API if unitMap missed it
    if castGUID and not castUnit then
        local prefix, count
        if IsInRaid() then
            prefix, count = "raid", 40
        elseif GetNumGroupMembers() > 0 then
            prefix, count = "party", GetNumGroupMembers() - 1
        end
        if prefix then
            for i = 1, count do
                local u = prefix .. i
                if UnitGUID(u) == castGUID then
                    castUnit = u
                    unitMap[castGUID] = u
                    break
                end
            end
        end
        if not castUnit and UnitGUID("target") == castGUID then
            castUnit = "target"
            if UnitIsFriend("player", "target") then unitMap[castGUID] = "target" end
        end
        if not castUnit and UnitGUID("mouseover") == castGUID then
            castUnit = "mouseover"
            if UnitIsFriend("player", "mouseover") then unitMap[castGUID] = "mouseover" end
        end
    end
    if not castGUID or not castUnit then return end

    -- Once castGUID/castUnit are resolved, this cast attempt owns the cache
    -- slots for spellID — clear them on every exit path from here on so a
    -- failed calculation never leaves a stale (possibly high-priority) GUID
    -- sitting in castTargets[0]/[spellID], silently misattributing or
    -- blocking the next cast of this spell on a different target.
    local function clearCastTarget()
        castTargets[spellID] = nil
        castPriority[spellID] = nil
        castTargets[0] = nil
        castPriority[0] = nil
    end

    -- Calculate the heal
    local CalculateHeal = Engine.CalculateHeal
    local GetTargets = Engine.GetTargets
    local myGUID = Engine.myGUID

    local healType, amount, numTicks, tickInterval
    healType, amount, numTicks, tickInterval = CalculateHeal(castGUID, spellID, castUnit)
    if not amount then clearCastTarget(); return end

    -- Get targets (multi-target for PoH, Binding Heal, etc.)
    local targets = GetTargets(healType, castGUID, spellID, amount)
    if not targets then clearCastTarget(); return end

    if healType == DIRECT then
        local startMs, endMs = select(4, CastingInfo())
        if not startMs or not endMs then clearCastTarget(); return end
        local dur = (endMs - startMs) / 1000
        parseDirect(myGUID, spellID, amount, dur, strsplit(",", targets))
        sendWire(strformat("D:%.3f:%d:%d:%s", dur, spellID, amount, targets))
        Engine.callbacks:Fire("HealComm_HealStarted", myGUID, spellID, DIRECT, GetTime() + dur, decompressTargets(targets))

    elseif healType == CHANNEL then
        parseChannel(myGUID, spellID, amount, numTicks, strsplit(",", targets))
        -- Penance: first tick already landed by the time other addons see it
        local wireTicks = numTicks
        if spellName == (GetSpellInfo(53007) or "Penance") then
            wireTicks = numTicks - 1
        end
        sendWire(strformat("C::%d:%d:%s:%s", spellID, amount, wireTicks, targets))
        Engine.callbacks:Fire("HealComm_HealStarted", myGUID, spellID, CHANNEL, GetTime() + numTicks * (tickInterval or 1), decompressTargets(targets))
    end

    clearCastTarget()
end

local function onCastStop(unit, cast, spellID, interrupted)
    if unit ~= "player" then return end
    local spellName = GetSpellInfo(spellID)
    if not spellName then return end
    local myGUID = Engine.myGUID

    -- Default interrupted to true (called from UNIT_SPELLCAST_INTERRUPTED)
    if interrupted == nil then interrupted = true end

    local spells = inbound[myGUID]
    local rec = spells and spells[spellID]
    if rec then
        local targetList = {}
        for guid in pairs(rec.targets) do tinsert(targetList, compressCache[guid]) end
        wipeAllTargets(rec)
        spells[spellID] = nil
        if not next(spells) then inbound[myGUID] = nil end

        if #targetList > 0 then
            local tgts = tconcat(targetList, ",")
            sendWire(strformat("S:%d:%s", spellID, tgts))
            Engine.callbacks:Fire("HealComm_HealStopped", myGUID, spellID, DIRECT, interrupted, decompressTargets(tgts))
        end
    end
end

local function onCastSucceeded(unit, cast, spellID)
    if unit ~= "player" then return end
    -- Direct heals complete on SUCCEEDED — not interrupted
    onCastStop(unit, cast, spellID, false)
end

local function onCastDelayed(unit, cast, spellID)
    if unit ~= "player" then return end
    local myGUID = Engine.myGUID
    local spells = inbound[myGUID]
    local rec = spells and spells[spellID]
    if rec then
        local _, _, _, _, endMs = CastingInfo()
        if endMs then
            local newEnd = endMs / 1000
            rec.endTime = newEnd
            for guid, e in pairs(rec.targets) do e[3] = newEnd end

            local targetList = {}
            for guid in pairs(rec.targets) do tinsert(targetList, compressCache[guid]) end
            if #targetList > 0 then
                local tgts = tconcat(targetList, ",")
                sendWire(strformat("F:%.3f:%d:%d:%s", newEnd - GetTime(), spellID, rec.targets[next(rec.targets)] and rec.targets[next(rec.targets)][1] or 0, tgts))
                Engine.callbacks:Fire("HealComm_HealDelayed", myGUID, spellID, DIRECT, newEnd, decompressTargets(tgts))
            end
        end
    end
end

local function onChannelStop(unit, cast, spellID)
    if unit ~= "player" then return end
    local spellName = GetSpellInfo(spellID)
    if not spellName then return end
    local myGUID = Engine.myGUID

    local spells = ticking[myGUID]
    local rec = spells and spells[spellName]
    if rec then
        local targetList = {}
        for guid in pairs(rec.targets) do tinsert(targetList, compressCache[guid]) end
        wipeAllTargets(rec)
        spells[spellName] = nil
        if not next(spells) then ticking[myGUID] = nil end

        if #targetList > 0 then
            local tgts = tconcat(targetList, ",")
            sendWire(strformat("S:%d:%s", spellID, tgts))
            Engine.callbacks:Fire("HealComm_HealStopped", myGUID, spellID, CHANNEL, false, decompressTargets(tgts))
        end
    end
end

---------------------------------------------------------------------------
-- COMBAT LOG — track heal ticks, HoT applications/removals
---------------------------------------------------------------------------
local TRACKED_EVENTS = {
    SPELL_HEAL = true,
    SPELL_PERIODIC_HEAL = true,
    SPELL_AURA_APPLIED = true,
    SPELL_AURA_REFRESH = true,
    SPELL_AURA_APPLIED_DOSE = true,
    SPELL_AURA_REMOVED = true,
    SPELL_AURA_REMOVED_DOSE = true,
}

local unitHasBuff = Engine.unitHasBuff

local function onCombatLog(...)
    local _, eventType, _, srcGUID, _, srcFlags, _, dstGUID, _, _, _, clSpellID, spellName = ...
    if not TRACKED_EVENTS[eventType] then return end

    local dstUnit = unitMap[dstGUID]
    if not dstUnit then return end

    -- Use the combat log's spellID directly (arg12) — it's the actual
    -- rank-specific ID. Only fall back to aura/GetSpellInfo if missing.
    local spellID = clSpellID
    if not spellID or not Engine.rankOf[spellID] then
        -- Try aura scan (catches rank-specific ID from the live buff)
        local _, _, sid = unitHasBuff(dstUnit, spellName)
        if sid and Engine.rankOf[sid] then
            spellID = sid
        end
    end
    if not spellID or not Engine.rankOf[spellID] then
        -- Last resort: GetSpellInfo returns the base rank spellID
        local baseSID = select(7, GetSpellInfo(spellName))
        if baseSID then spellID = baseSID end
    end

    -- Heal tick landed — decrement ticksLeft
    if eventType == "SPELL_HEAL" or eventType == "SPELL_PERIODIC_HEAL" then
        local rec = srcGUID and ticking[srcGUID] and ticking[srcGUID][spellName]
        if rec and rec.targets[dstGUID] and bit_band(rec.healType, TICKING) > 0 then
            local e = rec.targets[dstGUID]
            e[4] = mathmax(e[4] - 1, 0) -- ticksLeft
            e[3] = GetTime() + rec.interval * e[4]  -- recalc endTime

            -- Empirical tick amount: replace prediction with actual combat log value
            -- Skip crit ticks (inflated by 1.5x, not representative of normal ticks)
            local clAmount, clOverheal, _, clCrit = select(15, ...)
            if clAmount and not clCrit and e[2] > 0 then
                local fullTick = clAmount + (clOverheal or 0)
                if fullTick > 0 then
                    e[1] = fullTick / e[2]
                end
            end

            -- Multi-target: bucket the update
            if rec.multiTarget and srcGUID then
                buckets[srcGUID] = buckets[srcGUID] or {}
                local bk = buckets[srcGUID][spellName]
                if not bk then
                    bk = { timer = BUCKET_WINDOW, kind = "tick", spellID = rec.spellID }
                    buckets[srcGUID][spellName] = bk
                end
                if not bk[dstGUID] then
                    bk[dstGUID] = true
                    tinsert(bk, dstGUID)
                    bucketFrame:Show()
                end
            else
                Engine.callbacks:Fire("HealComm_HealUpdated", srcGUID, rec.spellID, rec.healType, e[3], dstGUID)
            end
        end

    -- New HoT applied (from ourselves only — remote comes via wire)
    elseif (eventType == "SPELL_AURA_APPLIED" or eventType == "SPELL_AURA_REFRESH" or eventType == "SPELL_AURA_APPLIED_DOSE")
       and bit_band(srcFlags, AFFILIATION_MINE) == AFFILIATION_MINE then

        if tickInfo[spellName] then
            local CalculateHoT = Engine.CalculateHoT
            local GetTargets = Engine.GetTargets
            local myGUID = Engine.myGUID

            local ht, perTick, numTicks, interval, bombAmt = CalculateHoT(dstGUID, spellID or 0)
            if ht then
                local targets = GetTargets(ht, dstGUID, spellID or 0)
                if targets then
                    parseHoT(srcGUID, (eventType == "SPELL_AURA_REFRESH"), spellID or 0, perTick, numTicks, interval, strsplit(",", targets))

                    if bombAmt then
                        local bombTgts = GetTargets(BOMB, dstGUID, spellName)
                        parseBomb(srcGUID, false, spellID or 0, bombAmt, strsplit(",", bombTgts or targets))
                        sendWire(strformat("B:%d:%d:%d:%s:%d::%d:%s", numTicks, spellID or 0, bombAmt, bombTgts or targets, perTick, interval, targets))
                    else
                        sendWire(strformat("H:%d:%d:%d::%d:%s", numTicks, spellID or 0, perTick, interval, targets))
                    end

                    Engine.callbacks:Fire("HealComm_HealStarted", srcGUID, spellID or 0, ht, GetTime() + numTicks * interval, decompressTargets(targets))
                end
            end
        end

    -- Stack removed (e.g. Lifebloom 3→2 or 2→1) — recalculate and send update
    elseif eventType == "SPELL_AURA_REMOVED_DOSE" and bit_band(srcFlags, AFFILIATION_MINE) == AFFILIATION_MINE then
        local rec = srcGUID and ticking[srcGUID] and ticking[srcGUID][spellName]
        if rec and rec.targets[dstGUID] then
            local CalculateHoT = Engine.CalculateHoT
            local GetTargets = Engine.GetTargets
            local ht, perTick, numTicks, interval, bombAmt = CalculateHoT(dstGUID, spellID or 0)
            if ht and perTick then
                local compressed = compressCache[dstGUID]
                -- Update the existing record's per-tick amount
                parseHoT(srcGUID, true, spellID or 0, perTick, numTicks, interval, compressed)

                -- Update bomb if applicable
                if bombAmt then
                    local bombTgts = GetTargets(BOMB, dstGUID, spellName)
                    parseBomb(srcGUID, true, spellID or 0, bombAmt, strsplit(",", bombTgts or compressed))
                    sendWire(strformat("UB:%d:%d:%d:%s:%d:%d:%s", numTicks, spellID or 0, bombAmt, bombTgts or compressed, perTick, interval, compressed))
                else
                    sendWire(strformat("U:%d:%d:%d:%d:%s", spellID or 0, perTick, numTicks, interval, compressed))
                end

                Engine.callbacks:Fire("HealComm_HealUpdated", srcGUID, spellID or 0, ht, rec.endTime, dstGUID)
            end
        end

    -- HoT removed
    elseif eventType == "SPELL_AURA_REMOVED" and bit_band(srcFlags, AFFILIATION_MINE) == AFFILIATION_MINE then
        local rec = srcGUID and ticking[srcGUID] and ticking[srcGUID][spellName]
        if rec and rec.targets[dstGUID] then
            local compressed = compressCache[dstGUID]
            dropTarget(rec, dstGUID)
            if not next(rec.targets) then
                ticking[srcGUID][spellName] = nil
                if not next(ticking[srcGUID]) then ticking[srcGUID] = nil end
            end
            sendWire(strformat("HS:%d:%s", rec.spellID, compressed))
            Engine.callbacks:Fire("HealComm_HealStopped", srcGUID, rec.spellID, HOT, false, dstGUID)
        end
    end

    -- Foreign HoT removal: clear foreign-estimate records promptly on
    -- dispel / cleanse so the prediction bar doesn't linger.
    if eventType == "SPELL_AURA_REMOVED"
       and bit_band(srcFlags, AFFILIATION_MINE) == 0
       and srcGUID and srcGUID ~= Engine.myGUID then
        local rec = ticking[srcGUID] and ticking[srcGUID][spellName]
        if rec and rec.foreignEstimate and rec.targets[dstGUID] then
            dropTarget(rec, dstGUID)
            if not next(rec.targets) then
                ticking[srcGUID][spellName] = nil
                if not next(ticking[srcGUID]) then ticking[srcGUID] = nil end
            end
            Engine.callbacks:Fire("HealComm_HealStopped", srcGUID, rec.spellID, HOT, false, dstGUID)
        end
    end

    -- Prayer of Mending tracking (TBC only, both self and foreign priests).
    -- PoM is a buff that heals its holder on damage, then jumps to a new
    -- target with one charge consumed. We represent it as a BOMB record
    -- with one target = current holder. On jump, the combat log fires
    -- SPELL_AURA_REMOVED (old holder) then SPELL_AURA_APPLIED (new holder);
    -- we drop the old target and add the new one.
    if Engine.pomData and spellName == Engine.pomData.spellName
       and srcGUID and Engine.EstimatePoM then

        local bombName = spellName .. "_bomb"
        if eventType == "SPELL_AURA_APPLIED" or eventType == "SPELL_AURA_REFRESH" then
            local healAmt = Engine.EstimatePoM(srcGUID, spellID or 0)
            if healAmt and healAmt > 0 then
                inbound[srcGUID] = inbound[srcGUID] or {}
                local rec = inbound[srcGUID][bombName]
                if not rec then
                    rec = newRecord(BOMB, spellID or 0, bombName)
                    inbound[srcGUID][bombName] = rec
                end
                rec.endTime = GetTime() + (Engine.pomData.duration or 30)
                addTarget(rec, dstGUID, healAmt, 1, rec.endTime, 0)
                Engine.callbacks:Fire("HealComm_HealStarted",
                    srcGUID, spellID or 0, BOMB, rec.endTime, dstGUID)
            end
        elseif eventType == "SPELL_AURA_REMOVED" then
            local spells = inbound[srcGUID]
            local rec = spells and spells[bombName]
            if rec and rec.targets[dstGUID] then
                dropTarget(rec, dstGUID)
                if not next(rec.targets) then
                    spells[bombName] = nil
                    if not next(spells) then inbound[srcGUID] = nil end
                end
                Engine.callbacks:Fire("HealComm_HealStopped",
                    srcGUID, spellID or 0, BOMB, false, dstGUID)
            end
        end
    end

    -- Foreign HoT tracking: another player cast a tracked HoT on a unit
    -- we're watching, and they aren't running HealPredict (no wire data).
    -- Estimate the amount from our own +healing as a caster-stat proxy;
    -- empirical tick updates above will correct once the first tick lands.
    if (eventType == "SPELL_AURA_APPLIED" or eventType == "SPELL_AURA_REFRESH" or eventType == "SPELL_AURA_APPLIED_DOSE")
       and bit_band(srcFlags, AFFILIATION_MINE) == 0
       and srcGUID and srcGUID ~= Engine.myGUID
       and Engine.EstimateForeignHoT then

        local existing = ticking[srcGUID] and ticking[srcGUID][spellName]
        if not existing or existing.foreignEstimate then
            local perTick, numTicks, interval, bombAmt =
                Engine.EstimateForeignHoT(spellID or 0, spellName)
            if perTick and numTicks and interval then
                local compressed = compressCache[dstGUID]
                if compressed then
                    parseHoT(srcGUID, (eventType == "SPELL_AURA_REFRESH"),
                        spellID or 0, perTick, numTicks, interval, compressed)
                    local rec = ticking[srcGUID] and ticking[srcGUID][spellName]
                    if rec then
                        rec.foreignEstimate = true
                        if bombAmt then
                            parseBomb(srcGUID, (eventType == "SPELL_AURA_REFRESH"),
                                spellID or 0, bombAmt, compressed)
                        end
                        Engine.callbacks:Fire("HealComm_HealStarted",
                            srcGUID, spellID or 0, HOT,
                            GetTime() + numTicks * interval, dstGUID)
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- HOT MONITOR — clean up out-of-range and expired HoTs periodically
-- Covers ALL casters, not just the local player
---------------------------------------------------------------------------
local hotMonitor = Engine.hotMonitor or CreateFrame("Frame")
Engine.hotMonitor = hotMonitor
hotMonitor:Hide()

local HOT_CHECK_INTERVAL = 5
local hotTimer = 0

-- Temp tables for safe collect-then-remove iteration
local _pendingRemove = {}
local _pendingGuids  = {}

hotMonitor:SetScript("OnUpdate", function(self, elapsed)
    hotTimer = hotTimer + elapsed
    if hotTimer < HOT_CHECK_INTERVAL then return end
    hotTimer = 0

    local now = GetTime()
    local anyActive = false

    -- 1) Clean all casters' expired ticking records (time-based)
    -- Collect expired records/targets first, then remove
    for casterGUID, spells in pairs(ticking) do
        wipe(_pendingRemove)
        for sName, rec in pairs(spells) do
            if rec.endTime > 0 and rec.endTime <= now then
                -- Entirely expired — collect whole record for removal
                _pendingRemove[sName] = rec
            else
                -- Per-target expiry — collect expired GUIDs
                wipe(_pendingGuids)
                for guid, e in pairs(rec.targets) do
                    local eTime = e[3] > 0 and e[3] or rec.endTime
                    if eTime > 0 and eTime <= now then
                        _pendingGuids[#_pendingGuids + 1] = guid
                    end
                end
                -- Remove collected targets
                for i = 1, #_pendingGuids do
                    local guid = _pendingGuids[i]
                    dropTarget(rec, guid)
                    Engine.callbacks:Fire("HealComm_HealStopped", casterGUID, rec.spellID, rec.healType, false, guid)
                end
                if not next(rec.targets) then
                    _pendingRemove[sName] = rec
                end
            end
        end
        -- Remove collected records
        for sName, rec in pairs(_pendingRemove) do
            -- Clean remaining targets (for fully-expired records)
            for guid in pairs(rec.targets) do
                dropTarget(rec, guid)
                Engine.callbacks:Fire("HealComm_HealStopped", casterGUID, rec.spellID, rec.healType, false, guid)
            end
            spells[sName] = nil
        end
        if not next(spells) then ticking[casterGUID] = nil end
    end

    -- 2) Clean expired direct/bomb heals from all casters
    for casterGUID, spells in pairs(inbound) do
        wipe(_pendingRemove)
        for sid, rec in pairs(spells) do
            if rec.endTime > 0 and rec.endTime <= now then
                _pendingRemove[sid] = rec
            end
        end
        for sid, rec in pairs(_pendingRemove) do
            wipeAllTargets(rec)
            spells[sid] = nil
        end
        if not next(spells) then inbound[casterGUID] = nil end
    end

    -- 3) Out-of-range cleanup: collect disappeared GUIDs first
    wipe(_pendingGuids)
    for guid, count in pairs(hotCount) do
        if count > 0 then
            local unit = unitMap[guid]
            if unit and not UnitIsVisible(unit) then
                _pendingGuids[#_pendingGuids + 1] = guid
            else
                anyActive = true
            end
        end
    end
    -- Now remove collected GUIDs (safe: hotCount not being iterated)
    for i = 1, #_pendingGuids do
        local guid = _pendingGuids[i]
        for casterGUID, spells in pairs(ticking) do
            wipe(_pendingRemove)
            for sName, rec in pairs(spells) do
                if rec.targets[guid] then
                    dropTarget(rec, guid)
                    if not next(rec.targets) then
                        _pendingRemove[sName] = true
                    end
                end
            end
            for sName in pairs(_pendingRemove) do
                spells[sName] = nil
            end
            if not next(spells) then ticking[casterGUID] = nil end
        end
        Engine.callbacks:Fire("HealComm_GUIDDisappeared", guid)
    end

    if not anyActive and not next(ticking) and not next(inbound) then self:Hide() end
end)

---------------------------------------------------------------------------
-- GROUP ROSTER MANAGEMENT
---------------------------------------------------------------------------
local activePets = Engine.activePets

local function clearGroupData()
    wipe(compressCache)
    wipe(decompressCache)
    wipe(activePets)
    Engine.myGUID = Engine.myGUID or UnitGUID("player")
    wipe(unitMap)
    unitMap[Engine.myGUID] = "player"
    wipe(groupMap)
    wipe(hotCount)
    purgeAll()
end

local function refreshRoster()
    updateChannel()
    wipe(activePets)
    -- Always rebuild unitMap/groupMap cleanly to prevent stale GUID→unit mappings
    -- (e.g. after pet death, player disconnect/reconnect, role swap)
    wipe(unitMap)
    wipe(groupMap)
    Engine.myGUID = Engine.myGUID or UnitGUID("player")
    unitMap[Engine.myGUID] = "player"

    local function addUnit(unit)
        local guid = UnitGUID(unit)
        if not guid then return end
        local raidIdx = UnitInRaid(unit)
        local group = raidIdx and select(3, GetRaidRosterInfo(raidIdx + 1)) or 1
        unitMap[guid] = unit
        groupMap[guid] = group

        local pet = Engine.petLookup[unit]
        local petGUID = pet and UnitGUID(pet)
        activePets[unit] = petGUID
        if petGUID then
            unitMap[petGUID] = pet
            groupMap[petGUID] = group
        end
    end

    if GetNumGroupMembers() == 0 then
        addUnit("player")
    elseif not IsInRaid() then
        addUnit("player")
        for i = 1, MAX_PARTY_MEMBERS do
            addUnit("party" .. i)
        end
    else
        for i = 1, MAX_RAID_MEMBERS do
            addUnit("raid" .. i)
        end
    end
end

---------------------------------------------------------------------------
-- ZONE MANAGEMENT
---------------------------------------------------------------------------
Engine.zoneMod = 1

local function onZoneChanged()
    local pvp = GetZonePVPInfo()
    local inst = select(2, IsInInstance())

    Engine.zoneMod = 1
    if pvp == "combat" or inst == "arena" or inst == "pvp" then
        Engine.zoneMod = 0.90
    end

    local instType = Engine.instType
    if inst ~= instType then
        Engine.setInstType(inst)
        updateChannel()
        purgeAll()
    end
    Engine.setInstType(inst)
end

---------------------------------------------------------------------------
-- Expose on Engine table for Init.lua
---------------------------------------------------------------------------
-- castTargets/castPriority are diagnostic-only exposures (for /hp debug) so
-- a stuck cast-target slot can actually be observed instead of guessed at.
Engine.castTargets     = castTargets
Engine.castPriority    = castPriority
Engine.setCastTarget   = setCastTarget
Engine.onCastSent      = onCastSent
Engine.onCastStart     = onCastStart
Engine.onCastStop      = onCastStop
Engine.onCastSucceeded = onCastSucceeded
Engine.onCastDelayed   = onCastDelayed
Engine.onChannelStop   = onChannelStop
Engine.onCombatLog     = onCombatLog
Engine.clearGroupData  = clearGroupData
Engine.refreshRoster   = refreshRoster
Engine.onZoneChanged   = onZoneChanged

-- For backward compat with channel start handler alias
Engine.UNIT_SPELLCAST_CHANNEL_START = onCastStart
