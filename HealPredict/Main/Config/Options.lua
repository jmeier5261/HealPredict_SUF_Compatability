-- HealPredict - Options.lua
-- Tabbed settings panel with scroll support
-- Author: DarkpoisOn
-- License: All Rights Reserved (c) 2026 DarkpoisOn

local HP = HealPredict
local isTBC = HP.Engine and HP.Engine.isTBC

-- Local references for performance
local Settings       = HP.Settings
local MakeGradientPair = HP.MakeGradientPair
local CopyTable      = HP.CopyTable
local MergeDefaults  = HP.MergeDefaults

local fmt, mathmin, mathmax, mathfloor = HP.fmt, HP.mathmin, HP.mathmax, HP.mathfloor
local pairs, ipairs, next, wipe = pairs, ipairs, next, wipe
local unpack, tinsert = HP.unpack, HP.tinsert

---------------------------------------------------------------------------
-- Base64 encoder/decoder for profile export/import
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REV = {}
for i = 1, 64 do B64_REV[B64:sub(i, i)] = i - 1 end

local function Base64Encode(data)
    local out = {}
    local len = #data
    for i = 1, len, 3 do
        local b1 = data:byte(i)
        local b2 = i + 1 <= len and data:byte(i + 1) or 0
        local b3 = i + 2 <= len and data:byte(i + 2) or 0
        local n = b1 * 65536 + b2 * 256 + b3
        out[#out + 1] = B64:sub(mathfloor(n / 262144) + 1, mathfloor(n / 262144) + 1)
        out[#out + 1] = B64:sub(mathfloor(n / 4096) % 64 + 1, mathfloor(n / 4096) % 64 + 1)
        if i + 1 <= len then
            out[#out + 1] = B64:sub(mathfloor(n / 64) % 64 + 1, mathfloor(n / 64) % 64 + 1)
        else
            out[#out + 1] = "="
        end
        if i + 2 <= len then
            out[#out + 1] = B64:sub(n % 64 + 1, n % 64 + 1)
        else
            out[#out + 1] = "="
        end
    end
    return table.concat(out)
end

local function Base64Decode(data)
    data = data:gsub("[^A-Za-z0-9+/=]", "")
    local out = {}
    for i = 1, #data, 4 do
        local c1 = B64_REV[data:sub(i, i)] or 0
        local c2 = B64_REV[data:sub(i + 1, i + 1)] or 0
        local c3 = B64_REV[data:sub(i + 2, i + 2)]
        local c4 = B64_REV[data:sub(i + 3, i + 3)]
        out[#out + 1] = string.char(c1 * 4 + mathfloor(c2 / 16))
        if c3 then
            out[#out + 1] = string.char((c2 % 16) * 16 + mathfloor(c3 / 4))
        end
        if c4 then
            out[#out + 1] = string.char((c3 % 4) * 64 + c4)
        end
    end
    return table.concat(out)
end

---------------------------------------------------------------------------
-- Simple settings serializer/deserializer
-- Format: key=value pairs separated by \n
-- Supports: booleans, numbers, and color sub-table
---------------------------------------------------------------------------
local function SerializeSettings(s)
    local lines = {}
    local sortedKeys = {}
    for k in pairs(s) do
        if k ~= "colors" then sortedKeys[#sortedKeys + 1] = k end
    end
    table.sort(sortedKeys)

    for _, k in ipairs(sortedKeys) do
        local v = s[k]
        if type(v) == "boolean" then
            lines[#lines + 1] = k .. "=" .. (v and "T" or "F")
        elseif type(v) == "number" then
            lines[#lines + 1] = k .. "=" .. fmt("%.6g", v)
        end
    end

    -- Serialize colors sub-table
    if s.colors and type(s.colors) == "table" then
        local colorKeys = {}
        for ck in pairs(s.colors) do colorKeys[#colorKeys + 1] = ck end
        table.sort(colorKeys)
        for _, ck in ipairs(colorKeys) do
            local cv = s.colors[ck]
            if type(cv) == "table" then
                local vals = {}
                for ci = 1, #cv do
                    vals[ci] = fmt("%.4g", cv[ci])
                end
                lines[#lines + 1] = "C." .. ck .. "=" .. table.concat(vals, ",")
            end
        end
    end

    return table.concat(lines, "\n")
end

local function DeserializeSettings(text)
    local s = {}
    s.colors = {}
    for line in text:gmatch("[^\n]+") do
        local k, v = line:match("^([^=]+)=(.+)$")
        if k and v then
            if k:sub(1, 2) == "C." then
                -- Color entry
                local colorKey = k:sub(3)
                local vals = {}
                for num in v:gmatch("[^,]+") do
                    vals[#vals + 1] = tonumber(num)
                end
                if #vals > 0 then
                    s.colors[colorKey] = vals
                end
            elseif v == "T" then
                s[k] = true
            elseif v == "F" then
                s[k] = false
            else
                local n = tonumber(v)
                if n then s[k] = n end
            end
        end
    end
    return s
end

---------------------------------------------------------------------------
-- Export/Import API
---------------------------------------------------------------------------
function HP.ExportProfile()
    HP.SaveSettings()
    local serialized = SerializeSettings(Settings)
    return "HP1:" .. Base64Encode(serialized)
end

function HP.ImportProfile(encodedStr)
    if not encodedStr or encodedStr == "" then return false, "Empty input" end
    local prefix, payload = encodedStr:match("^(HP%d+):(.+)$")
    if not prefix or not payload then return false, "Invalid format (missing HP1: prefix)" end
    if prefix ~= "HP1" then return false, "Unknown version: " .. prefix end

    local ok, decoded = pcall(Base64Decode, payload)
    if not ok or not decoded or decoded == "" then return false, "Base64 decode failed" end

    local ok2, imported = pcall(DeserializeSettings, decoded)
    if not ok2 or not imported then return false, "Deserialization failed" end

    -- Validate: must have at least a few expected keys
    if imported.showOthers == nil and imported.filterDirect == nil then
        return false, "Data does not appear to be a HealPredict profile"
    end

    -- Count settings before merge
    local importCount = 0
    for k, v in pairs(imported) do
        if k ~= "colors" and v ~= nil then
            importCount = importCount + 1
        end
    end
    local colorCount = 0
    for _ in pairs(imported.colors or {}) do colorCount = colorCount + 1 end

    -- Merge with defaults to fill any missing keys
    MergeDefaults(imported, HP.DEFAULTS)

    -- Apply to current settings
    wipe(Settings)
    for k, v in pairs(imported) do
        Settings[k] = CopyTable(v)
    end
    HP.SaveSettings()

    return true, importCount, colorCount
end

---------------------------------------------------------------------------
-- Options panel — sectioned layout with inline color swatches
---------------------------------------------------------------------------
local optionsFrame = nil
local optWidgets = { checks = {}, sliders = {}, swatches = {}, buttons = {} }

local function DrawSection(parent, text, anchorFrame, anchorPt, ox, oy)
    local hdr = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", anchorFrame, anchorPt or "BOTTOMLEFT", ox or 0, oy or -16)
    hdr:SetText(text)
    hdr:SetTextColor(0.9, 0.75, 0.3)

    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    line:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    line:SetPoint("RIGHT", parent, "RIGHT", -18, 0)
    return hdr, line
end

local function BuildCheck(parent, text, anchor, pt, ox, oy, getter, setter, tooltip)
    local n = "HP_Opt_" .. text:gsub("[%s%.%(%)]", "")
    local cb = CreateFrame("CheckButton", n, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, pt or "BOTTOMLEFT", ox or 0, oy or -4)
    local lbl = _G[n .. "Text"]
    if lbl then lbl:SetText(text); lbl:SetTextColor(0.95, 0.95, 0.95) end
    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self) setter(self:GetChecked()); HP.RefreshAll() end)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(text, 1, 1, 1)
            GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    tinsert(optWidgets.checks, { cb = cb, get = getter })
    return cb
end

local function BuildSlider(parent, tag, lo, hi, step, anchor, pt, ox, oy, getter, setter, pattern)
    pattern = pattern or "%d"
    local n = "HP_Sl_" .. tag
    local sl = CreateFrame("Slider", n, parent, "HP_SliderTemplate")
    sl:SetPoint("TOPLEFT", anchor, pt or "BOTTOMLEFT", ox or 0, oy or -20)
    sl:SetWidth(200)
    sl:SetMinMaxValues(lo, hi)
    sl:SetValueStep(step)
    sl:SetObeyStepOnDrag(true)
    sl.Text = _G[n .. "Text"]
    sl.Low  = _G[n .. "Low"]
    sl.High = _G[n .. "High"]
    sl:SetValue(getter())
    sl.Text:SetText(fmt(pattern, sl:GetValue()))
    sl.Low:SetText(lo)
    sl.High:SetText(hi)
    sl:SetScript("OnValueChanged", function(self, v)
        self.Text:SetText(fmt(pattern, v)); setter(v); HP.RefreshAll()
    end)
    tinsert(optWidgets.sliders, { sl = sl, get = getter, pattern = pattern })
    return sl
end

local SWATCH_LABELS = {"Direct", "HoT", "Direct (OH)", "HoT (OH)"}

local function BuildSwatchRow(parent, label, keys, anchor, pt, ox, oy, tooltip, customLabels)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", anchor, pt or "BOTTOMLEFT", ox or 0, oy or -8)
    lbl:SetText(label)

    if tooltip then
        local tipFrame = CreateFrame("Frame", nil, parent)
        tipFrame:SetAllPoints(lbl)
        tipFrame:EnableMouse(true)
        tipFrame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        tipFrame:SetScript("OnLeave", GameTooltip_Hide)
    end

    local showLabels = customLabels or (#keys >= 4)
    local labelsToUse = customLabels or SWATCH_LABELS
    local prev = lbl
    for i, key in ipairs(keys) do
        local sn = "HP_Col_" .. key
        local sw = CreateFrame("Button", sn, parent, "HP_SwatchTemplate")
        sw._colorKey = key
        sw:SetPoint("LEFT", prev, "RIGHT", prev == lbl and 8 or 1, 0)
        prev = sw

        local c = Settings.colors[key]
        sw:GetNormalTexture():SetVertexColor(c[1], c[2], c[3], c[4])

        sw:SetScript("OnClick", function()
            local cc = Settings.colors[key]
            local function onPick(old)
                local nr, ng, nb, na
                if old then
                    nr, ng, nb, na = unpack(old)
                else
                    na = 1.0 - OpacitySliderFrame:GetValue()
                    nr, ng, nb = ColorPickerFrame:GetColorRGB()
                end
                sw:GetNormalTexture():SetVertexColor(nr, ng, nb, na)
                Settings.colors[key] = { MakeGradientPair(nr, ng, nb, na) }
                HP.SaveSettings()
                HP.RefreshAll()
            end
            ColorPickerFrame.hasOpacity = true
            ColorPickerFrame.opacity = 1.0 - cc[4]
            ColorPickerFrame.previousValues = { cc[1], cc[2], cc[3], cc[4] }
            ColorPickerFrame.func = onPick
            ColorPickerFrame.swatchFunc = onPick
            ColorPickerFrame.opacityFunc = onPick
            ColorPickerFrame.cancelFunc = onPick
            ColorPickerFrame:SetColorRGB(cc[1], cc[2], cc[3])
            ColorPickerFrame:Hide(); ColorPickerFrame:Show()
        end)

        if showLabels and labelsToUse[i] then
            local swLabel = labelsToUse[i]
            sw:HookScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(swLabel, 1, 1, 1)
                GameTooltip:Show()
            end)
            sw:HookScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        tinsert(optWidgets.swatches, sw)
    end
    return lbl
end

---------------------------------------------------------------------------
-- Issue 2 fix: Create a dedicated options frame (not reusing HP_CoreFrame)
-- This avoids InterfaceOptions_AddCategory reparenting the event frame
---------------------------------------------------------------------------
function HP.CreateOptions()
    if optionsFrame then return optionsFrame end

    local host = CreateFrame("Frame", "HP_OptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame = host

    host:SetSize(460, 594)
    host:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    host:SetFrameStrata("DIALOG")
    host:EnableMouse(true)
    host:SetMovable(true)
    host:RegisterForDrag("LeftButton")
    host:SetScript("OnDragStart", host.StartMoving)
    host:SetScript("OnDragStop", host.StopMovingOrSizing)
    if host.SetBackdrop then
        host:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        host:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
        host:SetBackdropBorderColor(0.35, 0.35, 0.45, 1)
    end
    host:Hide()

    -- Register with UISpecialFrames so Escape closes the panel
    tinsert(UISpecialFrames, "HP_OptionsFrame")
    host:SetScript("OnHide", function()
        HP.SaveSettings()
        if HP._testMode then SlashCmdList["HPTEST"]() end
    end)

    local cls = CreateFrame("Button", nil, host, "UIPanelCloseButton")
    cls:SetPoint("TOPRIGHT", -1, -1)
    cls:SetScript("OnClick", function() host:Hide() end)

    local title = host:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", host, "TOP", 0, -12)
    title:SetText("|cff33ccffHealPredict|r")

    local sub = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetTextColor(0.55, 0.55, 0.55)
    sub:SetText(HP.VERSION and ("v" .. HP.VERSION .. "  by DarkpoisOn") or "by DarkpoisOn")

    --------------- Profile bar ---------------
    local profileLabel = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profileLabel:SetPoint("TOPLEFT", host, "TOPLEFT", 12, -50)
    profileLabel:SetText("Profile:")
    profileLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Profile dropdown (custom, lightweight — no UIDropDownMenu)
    local profileDropdown = CreateFrame("Frame", "HP_ProfileDropdown", host, "BackdropTemplate")
    profileDropdown:SetSize(160, 20)
    profileDropdown:SetPoint("LEFT", profileLabel, "RIGHT", 6, 0)
    if profileDropdown.SetBackdrop then
        profileDropdown:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        profileDropdown:SetBackdropColor(0.1, 0.1, 0.15, 0.9)
        profileDropdown:SetBackdropBorderColor(0.3, 0.3, 0.4, 1)
    end

    local profileText = profileDropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profileText:SetPoint("LEFT", 6, 0)
    profileText:SetPoint("RIGHT", -18, 0)
    profileText:SetJustifyH("LEFT")
    profileText:SetText(HP.activeProfile or "Default")

    local profileArrow = profileDropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profileArrow:SetPoint("RIGHT", -4, 0)
    profileArrow:SetText("v")
    profileArrow:SetTextColor(0.6, 0.6, 0.6)

    -- Profile popup menu
    local profileMenu = CreateFrame("Frame", "HP_ProfileMenu", host, "BackdropTemplate")
    profileMenu:SetFrameStrata("TOOLTIP")
    profileMenu:SetSize(160, 20)
    profileMenu:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 0, -2)
    if profileMenu.SetBackdrop then
        profileMenu:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        profileMenu:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
        profileMenu:SetBackdropBorderColor(0.3, 0.3, 0.4, 1)
    end
    profileMenu:EnableMouse(true)
    profileMenu:Hide()

    local menuEntries = {}

    local function RebuildProfileMenu()
        for _, entry in ipairs(menuEntries) do entry:Hide() end
        wipe(menuEntries)

        local profiles = HP.GetProfileList()
        local totalH = 4
        for idx, name in ipairs(profiles) do
            local row = CreateFrame("Button", nil, profileMenu)
            row:SetSize(152, 18)
            row:SetPoint("TOPLEFT", profileMenu, "TOPLEFT", 4, -totalH)

            local rowBg = row:CreateTexture(nil, "HIGHLIGHT")
            rowBg:SetAllPoints()
            rowBg:SetColorTexture(0.2, 0.8, 1.0, 0.15)

            local rowText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rowText:SetPoint("LEFT", 4, 0)
            rowText:SetText(name)

            if name == HP.activeProfile then
                rowText:SetTextColor(0.2, 0.8, 1.0)
            else
                rowText:SetTextColor(0.85, 0.85, 0.85)
            end

            row:SetScript("OnClick", function()
                profileMenu:Hide()
                if name ~= HP.activeProfile then
                    HP.SwitchProfile(name)
                    profileText:SetText(HP.activeProfile)
                end
            end)

            menuEntries[idx] = row
            totalH = totalH + 18
        end
        totalH = totalH + 4
        profileMenu:SetHeight(mathmax(totalH, 24))
    end

    profileDropdown:EnableMouse(true)
    profileDropdown:SetScript("OnMouseDown", function()
        if profileMenu:IsShown() then
            profileMenu:Hide()
        else
            RebuildProfileMenu()
            profileMenu:Show()
        end
    end)

    -- Close menu when clicking elsewhere
    profileMenu:SetScript("OnShow", function()
        profileMenu:SetPropagateKeyboardInput(false)
    end)
    host:HookScript("OnHide", function() profileMenu:Hide() end)

    -- "New" button
    local btnNew = CreateFrame("Button", "HP_BtnNewProf", host, "UIPanelButtonTemplate")
    btnNew:SetSize(40, 20)
    btnNew:SetPoint("LEFT", profileDropdown, "RIGHT", 4, 0)
    btnNew:SetText("New")
    btnNew:GetFontString():SetFont(btnNew:GetFontString():GetFont(), 10)
    btnNew:SetScript("OnClick", function()
        -- Simple input using StaticPopup
        StaticPopupDialogs["HP_NEW_PROFILE"] = {
            text = "Enter new profile name:",
            button1 = "Create",
            button2 = "Cancel",
            hasEditBox = true,
            maxLetters = 40,
            OnAccept = function(self)
                local name = self.EditBox:GetText():trim()
                if name ~= "" then
                    if HP.CreateProfile(name) then
                        HP.SwitchProfile(name)
                        profileText:SetText(HP.activeProfile)
                        if HP.RefreshOptions then HP.RefreshOptions() end
                    else
                        print("|cff33ccffHealPredict:|r Profile '" .. name .. "' already exists.")
                    end
                end
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local name = self:GetText():trim()
                if name ~= "" then
                    if HP.CreateProfile(name) then
                        HP.SwitchProfile(name)
                        profileText:SetText(HP.activeProfile)
                        if HP.RefreshOptions then HP.RefreshOptions() end
                    end
                end
                parent:Hide()
            end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("HP_NEW_PROFILE")
    end)

    -- "Copy" button
    local btnCopy = CreateFrame("Button", "HP_BtnCopyProf", host, "UIPanelButtonTemplate")
    btnCopy:SetSize(42, 20)
    btnCopy:SetPoint("LEFT", btnNew, "RIGHT", 2, 0)
    btnCopy:SetText("Copy")
    btnCopy:GetFontString():SetFont(btnCopy:GetFontString():GetFont(), 10)
    btnCopy:SetScript("OnClick", function()
        StaticPopupDialogs["HP_COPY_PROFILE"] = {
            text = "Copy current profile to new name:",
            button1 = "Copy",
            button2 = "Cancel",
            hasEditBox = true,
            maxLetters = 40,
            OnAccept = function(self)
                local destName = self.EditBox:GetText():trim()
                if destName ~= "" then
                    HP.SaveSettings()
                    local ok, reason = HP.CopyProfile(HP.activeProfile, destName)
                    if ok then
                        HP.SwitchProfile(destName)
                        profileText:SetText(HP.activeProfile)
                        if HP.RefreshOptions then HP.RefreshOptions() end
                        print("|cff33ccffHealPredict:|r Copied to '" .. destName .. "'")
                    elseif reason == "exists" then
                        print("|cff33ccffHealPredict:|r Profile '" .. destName .. "' already exists.")
                    else
                        print("|cff33ccffHealPredict:|r Could not copy profile.")
                    end
                end
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local destName = self:GetText():trim()
                if destName ~= "" then
                    HP.SaveSettings()
                    local ok = HP.CopyProfile(HP.activeProfile, destName)
                    if ok then
                        HP.SwitchProfile(destName)
                        profileText:SetText(HP.activeProfile)
                        if HP.RefreshOptions then HP.RefreshOptions() end
                    end
                end
                parent:Hide()
            end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("HP_COPY_PROFILE")
    end)

    -- "Delete" button
    local btnDel = CreateFrame("Button", "HP_BtnDelProf", host, "UIPanelButtonTemplate")
    btnDel:SetSize(36, 20)
    btnDel:SetPoint("LEFT", btnCopy, "RIGHT", 2, 0)
    btnDel:SetText("Del")
    btnDel:GetFontString():SetFont(btnDel:GetFontString():GetFont(), 10)
    btnDel:SetScript("OnClick", function()
        local current = HP.activeProfile
        if current == "Default" then
            print("|cff33ccffHealPredict:|r Cannot delete the Default profile.")
            return
        end
        StaticPopupDialogs["HP_DEL_PROFILE"] = {
            text = "Delete profile '" .. current .. "'?\nThis character will switch to Default.",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function()
                HP.DeleteProfile(current)
                profileText:SetText(HP.activeProfile)
                if optionsFrame then optionsFrame:SetScale(Settings.panelScale) end
                HP.ToggleMinimapButton()
                HP.RefreshBarTextures()
                HP.RefreshAll()
                if HP.RefreshOptions then HP.RefreshOptions() end
                if Settings.fastRaidUpdate then HP.StartFastUpdate() else HP.StopFastUpdate() end
                print("|cff33ccffHealPredict:|r Profile '" .. current .. "' deleted.")
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("HP_DEL_PROFILE")
    end)

    -- Export button
    local btnExport = CreateFrame("Button", "HP_BtnExport", host, "UIPanelButtonTemplate")
    btnExport:SetSize(50, 20)
    btnExport:SetPoint("LEFT", btnDel, "RIGHT", 4, 0)
    btnExport:SetText("Export")
    btnExport:GetFontString():SetFont(btnExport:GetFontString():GetFont(), 10)
    btnExport:SetScript("OnClick", function()
        local encoded = HP.ExportProfile()
        StaticPopupDialogs["HP_EXPORT"] = {
            text = "Copy this string to share your profile:",
            button1 = "Done",
            hasEditBox = true,
            maxLetters = 0,
            OnShow = function(self)
                self.EditBox:SetText(encoded)
                self.EditBox:HighlightText()
                self.EditBox:SetFocus()
                self.EditBox:SetWidth(300)
            end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("HP_EXPORT")
    end)

    -- Import button
    local btnImport = CreateFrame("Button", "HP_BtnImport", host, "UIPanelButtonTemplate")
    btnImport:SetSize(50, 20)
    btnImport:SetPoint("LEFT", btnExport, "RIGHT", 2, 0)
    btnImport:SetText("Import")
    btnImport:GetFontString():SetFont(btnImport:GetFontString():GetFont(), 10)
    btnImport:SetScript("OnClick", function()
        StaticPopupDialogs["HP_IMPORT"] = {
            text = "Paste a HealPredict profile string:",
            button1 = "Import",
            button2 = "Cancel",
            hasEditBox = true,
            maxLetters = 0,
            OnShow = function(self)
                self.EditBox:SetText("")
                self.EditBox:SetFocus()
                self.EditBox:SetWidth(300)
            end,
            OnAccept = function(self)
                local input = self.EditBox:GetText():trim()
                local ok, count, colorCount = HP.ImportProfile(input)
                if ok then
                    print("|cff33ccffHealPredict:|r Profile imported successfully (" .. (count or "?") .. " settings, " .. (colorCount or "?") .. " colors).")
                    if optionsFrame then optionsFrame:SetScale(Settings.panelScale) end
                    HP.ToggleMinimapButton()
                    HP.RefreshBarTextures()
                    HP.RefreshAll()
                    if Settings.fastRaidUpdate then HP.StartFastUpdate() else HP.StopFastUpdate() end
                    if HP.RefreshOptions then HP.RefreshOptions() end
                else
                    print("|cff33ccffHealPredict:|r Import failed: " .. (count or "unknown error"))
                end
            end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("HP_IMPORT")
    end)

    -- Store profile UI refs for RefreshOptions
    HP._profileText = profileText
    HP._profileMenu = profileMenu

    --------------- Tab system with scroll ---------------
    local tabFrames = {}   -- the scroll child (content parent)
    local tabScrolls = {}  -- the clip regions
    local tabButtons = {}
    local TAB_NAMES = { "Heal Bars", "Indicators", "Mana & Alerts", "General", "Analytics" }
    local TAB_HEIGHTS = { 1400, 2800, 650, 420, 1180 }
    local CONTENT_TOP = -100  -- below title + subtitle + profile bar + tab row

    local function ShowTab(idx)
        for i in ipairs(TAB_NAMES) do
            tabScrolls[i]:SetShown(i == idx)
            if tabButtons[i] then
                if i == idx then
                    tabButtons[i]._bg:SetColorTexture(0.12, 0.12, 0.18, 1)
                    tabButtons[i]._ul:Show()
                    tabButtons[i]._fs:SetTextColor(0.2, 0.8, 1)
                else
                    tabButtons[i]._bg:SetColorTexture(0.06, 0.06, 0.09, 0.6)
                    tabButtons[i]._ul:Hide()
                    tabButtons[i]._fs:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
    end

    for i, name in ipairs(TAB_NAMES) do
        -- Clip region
        local clip = CreateFrame("Frame", nil, host)
        clip:SetPoint("TOPLEFT", host, "TOPLEFT", 12, CONTENT_TOP)
        clip:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -12, 40)
        clip:SetClipsChildren(true)
        clip:Hide()

        -- Scroll frame inside clip
        local scroll = CreateFrame("ScrollFrame", "HP_Scroll" .. i, clip)
        scroll:SetAllPoints()
        scroll:EnableMouseWheel(true)

        -- Scrollbar track + thumb (only visible when content overflows)
        local track = CreateFrame("Frame", nil, clip)
        track:SetWidth(4)
        track:SetPoint("TOPRIGHT", clip, "TOPRIGHT", 0, 0)
        track:SetPoint("BOTTOMRIGHT", clip, "BOTTOMRIGHT", 0, 0)
        local trackBg = track:CreateTexture(nil, "BACKGROUND")
        trackBg:SetAllPoints()
        trackBg:SetColorTexture(0.2, 0.2, 0.25, 0.3)

        local thumb = CreateFrame("Frame", nil, track)
        thumb:SetWidth(4)
        thumb:SetHeight(20)
        thumb:SetPoint("TOP", track, "TOP", 0, 0)
        thumb:EnableMouse(true)
        local thumbTex = thumb:CreateTexture(nil, "OVERLAY")
        thumbTex:SetAllPoints()
        thumbTex:SetColorTexture(0.4, 0.4, 0.5, 0.6)

        local function UpdateScrollbar()
            local viewH = scroll:GetHeight()
            local contentH = TAB_HEIGHTS[i]
            if contentH <= viewH then
                track:Hide()
                return
            end
            track:Show()
            local trackH = track:GetHeight()
            local thumbH = mathmax(20, trackH * (viewH / contentH))
            thumb:SetHeight(thumbH)
            local maxScroll = contentH - viewH
            local cur = scroll:GetVerticalScroll()
            local ratio = cur / maxScroll
            local thumbTravel = trackH - thumbH
            thumb:ClearAllPoints()
            thumb:SetPoint("TOP", track, "TOP", 0, -(ratio * thumbTravel))
        end

        scroll:SetScript("OnMouseWheel", function(self, delta)
            local cur = self:GetVerticalScroll()
            local maxScroll = mathmax(0, TAB_HEIGHTS[i] - self:GetHeight())
            local newVal = mathmin(mathmax(cur - delta * 30, 0), maxScroll)
            self:SetVerticalScroll(newVal)
            UpdateScrollbar()
        end)

        -- Thumb drag scrolling
        thumb:RegisterForDrag("LeftButton")
        thumb:SetScript("OnDragStart", function(self)
            local startY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local startScroll = scroll:GetVerticalScroll()
            self:SetScript("OnUpdate", function()
                local curY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local trackH = track:GetHeight()
                local thumbH = self:GetHeight()
                local dragRange = trackH - thumbH
                if dragRange <= 0 then return end
                local maxScroll = mathmax(0, TAB_HEIGHTS[i] - scroll:GetHeight())
                local delta = startY - curY
                local newVal = startScroll + (delta / dragRange) * maxScroll
                newVal = mathmin(mathmax(newVal, 0), maxScroll)
                scroll:SetVerticalScroll(newVal)
                UpdateScrollbar()
            end)
        end)
        thumb:SetScript("OnDragStop", function(self)
            self:SetScript("OnUpdate", nil)
        end)

        scroll:SetScript("OnScrollRangeChanged", function() UpdateScrollbar() end)
        scroll:SetScript("OnSizeChanged", function() UpdateScrollbar() end)

        -- Scroll child (content frame)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(436, TAB_HEIGHTS[i])
        scroll:SetScrollChild(content)

        -- Initial scrollbar state
        C_Timer.After(0, UpdateScrollbar)

        tabScrolls[i] = clip
        tabFrames[i] = content

        -- Flat tab button — matches dark panel, cyan underline accent
        local btn = CreateFrame("Button", "HP_Tab" .. i, host)
        local tabW = mathfloor((460 - 16 - (#TAB_NAMES - 1) * 4) / #TAB_NAMES)
        btn:SetSize(tabW, 22)

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.06, 0.09, 0.6)
        btn._bg = bg

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(0.2, 0.8, 1, 0.06)

        -- Cyan underline for active tab
        local ul = btn:CreateTexture(nil, "OVERLAY")
        ul:SetHeight(2)
        ul:SetPoint("BOTTOMLEFT", 0, 0)
        ul:SetPoint("BOTTOMRIGHT", 0, 0)
        ul:SetColorTexture(0.2, 0.8, 1, 0.8)
        ul:Hide()
        btn._ul = ul

        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER", 0, 1)
        fs:SetText(name)
        btn._fs = fs

        if i == 1 then
            btn:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -76)
        else
            btn:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", 4, 0)
        end
        btn:SetScript("OnClick", function() ShowTab(i) end)
        tabButtons[i] = btn
    end

    ShowTab(1)

    local p1 = tabFrames[1]
    local p2 = tabFrames[2]
    local p3 = tabFrames[3]
    local p4 = tabFrames[4]
    local p5 = tabFrames[5]

    --=======================================================================
    -- TAB 1: Heal Bars  (Visibility, Filters, Timing, Bars, Overlays, Bar Colors)
    --=======================================================================
    local function BuildHealBarsTab(p1)

    --------------- Section: Frame Visibility ---------------
    local secVis = DrawSection(p1, "FRAME VISIBILITY", p1, "TOPLEFT", 0, 0)

    local cbPlayer = BuildCheck(p1, "Show on Player frame",
        secVis, "BOTTOMLEFT", 0, -6,
        function() return Settings.showOnPlayer end,
        function(v) Settings.showOnPlayer = v; HP.RefreshAll() end)

    local cbTarget = BuildCheck(p1, "Show on Target frame",
        cbPlayer, "BOTTOMLEFT", 0, -2,
        function() return Settings.showOnTarget end,
        function(v) Settings.showOnTarget = v; HP.RefreshAll() end)

    local cbToT = BuildCheck(p1, "Show on Target of Target frame",
        cbTarget, "BOTTOMLEFT", 0, -2,
        function() return Settings.showOnToT end,
        function(v) Settings.showOnToT = v; HP.RefreshAll() end)

    local cbFocus
    if isTBC then
        cbFocus = BuildCheck(p1, "Show on Focus frame",
            cbToT, "BOTTOMLEFT", 0, -2,
            function() return Settings.showOnFocus end,
            function(v) Settings.showOnFocus = v; HP.RefreshAll() end)
    end

    local cbParty = BuildCheck(p1, "Show on Party frames",
        (cbFocus or cbToT), "BOTTOMLEFT", 0, -2,
        function() return Settings.showOnParty end,
        function(v) Settings.showOnParty = v; HP.RefreshAll() end)

    local cbPet = BuildCheck(p1, "Show on Pet frames",
        cbParty, "BOTTOMLEFT", 0, -2,
        function() return Settings.showOnPet end,
        function(v) Settings.showOnPet = v; HP.RefreshAll() end)

    --------------- Section: Healing Filters ---------------
    local secFilter = DrawSection(p1, "HEALING FILTERS", cbPet, "BOTTOMLEFT", 0, -10)

    local cbOthers = BuildCheck(p1, "Show healing from other players",
        secFilter, "BOTTOMLEFT", 0, -6,
        function() return Settings.showOthers end,
        function(v) Settings.showOthers = v end,
        "Display heal predictions from other healers in your raid or party.")

    local cbDirect = BuildCheck(p1, "Direct heals",
        cbOthers, "BOTTOMLEFT", 20, -2,
        function() return Settings.filterDirect end,
        function(v) Settings.filterDirect = v end)

    local cbHoT = BuildCheck(p1, "HoT (heal over time)",
        cbDirect, "BOTTOMLEFT", 0, -2,
        function() return Settings.filterHoT end,
        function(v) Settings.filterHoT = v end)

    local cbChan = BuildCheck(p1, "Channeled heals",
        cbHoT, "BOTTOMLEFT", 0, -2,
        function() return Settings.filterChannel end,
        function(v) Settings.filterChannel = v end)

    local cbBomb = BuildCheck(p1, "Bomb heals (Prayer of Mending, etc.)",
        cbChan, "BOTTOMLEFT", 0, -2,
        function() return Settings.filterBomb end,
        function(v) Settings.filterBomb = v end)

    --------------- Section: Prediction Timing ---------------
    local secThresh = DrawSection(p1, "PREDICTION TIMING", cbBomb, "BOTTOMLEFT", -20, -10)

    local cbTime = BuildCheck(p1, "Limit prediction window",
        secThresh, "BOTTOMLEFT", 0, -6,
        function() return Settings.useTimeLimit end,
        function(v) Settings.useTimeLimit = v end,
        "Only show heals that will land within the specified timeframe. Useful for filtering out long HoTs that would clutter the display.")

    local cbDim = BuildCheck(p1, "Dim non-imminent heals (beyond time window)",
        cbTime, "BOTTOMLEFT", 20, -2,
        function() return Settings.dimNonImminent end,
        function(v) Settings.dimNonImminent = v end,
        "Reduces opacity of HoT/channel bars to distinguish them from direct heals landing soon.")

    local slDirect = BuildSlider(p1, "DirectTF", 0.5, 18.0, 0.5,
        cbDim, "BOTTOMLEFT", 0, -8,
        function() return Settings.directTimeframe end,
        function(v) Settings.directTimeframe = v end, "Direct: %.1fs")

    local slChannel = BuildSlider(p1, "ChanTF", 1.0, 18.0, 0.5,
        slDirect, "BOTTOMLEFT", 0, -18,
        function() return Settings.channelTimeframe end,
        function(v) Settings.channelTimeframe = v end, "Channel: %.1fs")

    local slHoTTime = BuildSlider(p1, "HoTTF", 1.0, 18.0, 0.5,
        slChannel, "BOTTOMLEFT", 0, -18,
        function() return Settings.hotTimeframe end,
        function(v) Settings.hotTimeframe = v end, "HoT: %.1fs")

    local cbOH = BuildCheck(p1, "Recolor bars when overhealing exceeds (%)",
        slHoTTime, "BOTTOMLEFT", -20, -28,
        function() return Settings.useOverhealColors end,
        function(v) Settings.useOverhealColors = v end)

    local slOH = BuildSlider(p1, "OHPct", 0, 100, 1,
        cbOH, "BOTTOMLEFT", 20, -8,
        function() return Settings.overhealThreshold * 100 end,
        function(v) Settings.overhealThreshold = v / 100 end)

    --------------- Section: Overflow Limits ---------------
    local secOver = DrawSection(p1, "OVERFLOW LIMITS", slOH, "BOTTOMLEFT", -20, -24)

    local cbRO = BuildCheck(p1, "Cap raid frame overflow (%)",
        secOver, "BOTTOMLEFT", 0, -6,
        function() return Settings.useRaidOverflow end,
        function(v) Settings.useRaidOverflow = v end)

    local slRO = BuildSlider(p1, "RaidOF", 0, 100, 1,
        cbRO, "BOTTOMLEFT", 20, -8,
        function() return Settings.raidOverflow * 100 end,
        function(v) Settings.raidOverflow = v / 100 end)

    local cbPO = BuildCheck(p1, "Cap party frame overflow (%)",
        slRO, "BOTTOMLEFT", -20, -24,
        function() return Settings.usePartyOverflow end,
        function(v) Settings.usePartyOverflow = v end)

    local slPO = BuildSlider(p1, "PartyOF", 0, 100, 1,
        cbPO, "BOTTOMLEFT", 20, -8,
        function() return Settings.partyOverflow * 100 end,
        function(v) Settings.partyOverflow = v / 100 end)

    local cbUO = BuildCheck(p1, "Cap unit frame overflow (%)",
        slPO, "BOTTOMLEFT", -20, -24,
        function() return Settings.useUnitOverflow end,
        function(v) Settings.useUnitOverflow = v end)

    local slUO = BuildSlider(p1, "UnitOF", 0, 100, 1,
        cbUO, "BOTTOMLEFT", 20, -8,
        function() return Settings.unitOverflow * 100 end,
        function(v) Settings.unitOverflow = v / 100 end)

    --------------- Section: Bars & Overlays ---------------
    local secDisp = DrawSection(p1, "BARS & OVERLAYS", slUO, "BOTTOMLEFT", -20, -10)

    local cbOverlay = BuildCheck(p1, "Overlay mode (stack my + other heals)",
        secDisp, "BOTTOMLEFT", 0, -6,
        function() return Settings.overlayMode end,
        function(v) Settings.overlayMode = v end,
        "When enabled, your heals and others' heals overlap instead of stacking end-to-end. Shows the larger of the two.")

    local cbSorted = BuildCheck(p1, "Smart heal ordering (arrival time)",
        cbOverlay, "BOTTOMLEFT", 0, -2,
        function() return Settings.smartOrdering end,
        function(v) Settings.smartOrdering = v end,
        "Reorders heal bars by arrival time: other heals landing before yours, your heal, other heals landing after, then all HoTs.")

    local cbSortedClassColor = BuildCheck(p1, "Class-colored heal bars (requires Smart Ordering)",
        cbSorted, "BOTTOMLEFT", 20, -2,
        function() return Settings.smartOrderingClassColors end,
        function(v) Settings.smartOrderingClassColors = v; HP.RefreshAll() end,
        "Colors each heal bar by the caster's class color. Only works when Smart Ordering is enabled.")

    local cbAltTex = BuildCheck(p1, "Use raid-style texture on unit frame bars",
        cbSortedClassColor, "BOTTOMLEFT", -20, -2,
        function() return Settings.useRaidTexture end,
        function(v) Settings.useRaidTexture = v; HP.RefreshBarTextures() end)

    local cbNameplates
    if C_NamePlate then
        cbNameplates = BuildCheck(p1, "Show heal bars on friendly nameplates",
            cbAltTex, "BOTTOMLEFT", 0, -2,
            function() return Settings.showNameplates end,
            function(v) Settings.showNameplates = v; HP.RefreshAll() end)
    end

    local slOpacity = BuildSlider(p1, "BarAlpha", 10, 100, 5,
        (cbNameplates or cbAltTex), "BOTTOMLEFT", 20, -12,
        function() return Settings.barOpacity * 100 end,
        function(v) Settings.barOpacity = v / 100; HP.RefreshAll() end, "Bar Opacity: %d%%")

    local cbOHBar = BuildCheck(p1, "Overheal amount bar",
        slOpacity, "BOTTOMLEFT", -20, -24,
        function() return Settings.showOverhealBar end,
        function(v) Settings.showOverhealBar = v end)

    local cbOvhGrad = BuildCheck(p1, "Overheal severity gradient",
        cbOHBar, "BOTTOMLEFT", 20, -2,
        function() return Settings.overhealGradient end,
        function(v) Settings.overhealGradient = v end,
        "Colors overheal bar by severity: green (low) through orange to red (high).")

    local srOvhColor = BuildSwatchRow(p1, "Overheal Bar:",
        { "overhealBar" },
        cbOvhGrad, "BOTTOMLEFT", -20, -4)

    --------------- Section: Bar Colors ---------------
    local secColors = DrawSection(p1, "BAR COLORS", srOvhColor, "BOTTOMLEFT", 0, -10)

    local sr1 = BuildSwatchRow(p1, "My Raid Heals:",
        { "raidMyDirect", "raidMyHoT", "raidMyDirectOH", "raidMyHoTOH" },
        secColors, "BOTTOMLEFT", 0, -6,
        "Your own heal predictions on raid and compact unit frames.")

    local sr2 = BuildSwatchRow(p1, "Other Raid Heals:",
        { "raidOtherDirect", "raidOtherHoT", "raidOtherDirectOH", "raidOtherHoTOH" },
        sr1, "BOTTOMLEFT", 0, -4,
        "Other players' heal predictions on raid and compact unit frames.")

    local sr3 = BuildSwatchRow(p1, "My Unit Heals:",
        { "unitMyDirect", "unitMyHoT", "unitMyDirectOH", "unitMyHoTOH" },
        sr2, "BOTTOMLEFT", 0, -4,
        "Your own heal predictions on player, target, party, and focus frames.")

    local sr4 = BuildSwatchRow(p1, "Other Unit Heals:",
        { "unitOtherDirect", "unitOtherHoT", "unitOtherDirectOH", "unitOtherHoTOH" },
        sr3, "BOTTOMLEFT", 0, -4,
        "Other players' heal predictions on player, target, party, and focus frames.")

    local flipBtn = CreateFrame("Button", "HP_BtnFlip", p1, "UIPanelButtonTemplate")
    flipBtn:SetSize(110, 20)
    flipBtn:SetPoint("TOPLEFT", sr4, "BOTTOMLEFT", 0, -6)
    flipBtn:SetText("Flip My/Other")
    flipBtn:SetScript("OnClick", function()
        HP.FlipColors()
        HP.RefreshOptions()
        HP.RefreshAll()
    end)

    local flipURBtn = CreateFrame("Button", "HP_BtnFlipUR", p1, "UIPanelButtonTemplate")
    flipURBtn:SetSize(110, 20)
    flipURBtn:SetPoint("LEFT", flipBtn, "RIGHT", 6, 0)
    flipURBtn:SetText("Flip Unit/Raid")
    flipURBtn:SetScript("OnClick", function()
        HP.FlipUnitRaidColors()
        HP.RefreshOptions()
        HP.RefreshAll()
    end)

    BuildCheck(p1, "Use only unit colors",
        flipBtn, "BOTTOMLEFT", 0, -6,
        function() return Settings.useUnitColorsOnly end,
        function(v) Settings.useUnitColorsOnly = v end,
        "When enabled, raid and compact frames substitute the \"My/Other Unit Heals\" colors above instead of the \"My/Other Raid Heals\" colors. Useful for keeping a single color scheme across all frame types.")

    end -- BuildHealBarsTab
    BuildHealBarsTab(p1)

    --=======================================================================
    -- TAB 5: Analytics  (Overheal Stats, Heal Queue, Encounter, Instance)
    --=======================================================================
    local function BuildAnalyticsTab(p5)

    --------------- Section: Overheal Statistics ---------------
    local secOverhealStats = DrawSection(p5, "OVERHEAL STATISTICS", p5, "TOPLEFT", 0, 0)

    local cbOverhealStats = BuildCheck(p5, "Show session overheal statistics",
        secOverhealStats, "BOTTOMLEFT", 0, -6,
        function() return Settings.overhealStats end,
        function(v)
            Settings.overhealStats = v
            HP.RefreshAll()
            if v and Settings.overhealStatsHideOOC then
                C_Timer.After(0, function()
                    if HP.UpdateOverhealStatsCombatStatus then HP.UpdateOverhealStatsCombatStatus() end
                end)
            end
        end,
        "Displays a small panel showing your overheal percentage and per-spell breakdown for this session.")

    local OVERHEAL_STATS_POS_LABELS = { "Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right" }
    local btnOverhealStatsPos = CreateFrame("Button", "HP_BtnOHSPos", p5, "UIPanelButtonTemplate")
    btnOverhealStatsPos:SetSize(140, 20)
    btnOverhealStatsPos:SetPoint("TOPLEFT", cbOverhealStats, "BOTTOMLEFT", 0, -4)
    btnOverhealStatsPos:SetText("Position: " .. (OVERHEAL_STATS_POS_LABELS[Settings.overhealStatsPos] or "Top-Left"))
    btnOverhealStatsPos:SetScript("OnClick", function(self)
        local pos = (Settings.overhealStatsPos or 1) % #OVERHEAL_STATS_POS_LABELS + 1
        Settings.overhealStatsPos = pos
        Settings.overhealStatsCustomPos = nil
        self:SetText("Position: " .. OVERHEAL_STATS_POS_LABELS[pos])
        if HP.UpdateOverhealStatsAnchor then HP.UpdateOverhealStatsAnchor() end
    end)
    tinsert(optWidgets.buttons, { btn = btnOverhealStatsPos, refresh = function()
        btnOverhealStatsPos:SetText("Position: " .. (OVERHEAL_STATS_POS_LABELS[Settings.overhealStatsPos] or "Top-Left"))
    end })

    local btnOverhealLock = CreateFrame("Button", "HP_BtnOHSLock", p5, "UIPanelButtonTemplate")
    btnOverhealLock:SetSize(140, 20)
    btnOverhealLock:SetPoint("TOPLEFT", btnOverhealStatsPos, "BOTTOMLEFT", 0, -4)
    btnOverhealLock:SetText(Settings.overhealStatsLocked and "Unlock Frame" or "Lock Frame")
    btnOverhealLock:SetScript("OnClick", function(self)
        Settings.overhealStatsLocked = not Settings.overhealStatsLocked
        self:SetText(Settings.overhealStatsLocked and "Unlock Frame" or "Lock Frame")
        if HP.SetOverhealStatsMovable then HP.SetOverhealStatsMovable(not Settings.overhealStatsLocked) end
    end)
    tinsert(optWidgets.buttons, { btn = btnOverhealLock, refresh = function()
        btnOverhealLock:SetText(Settings.overhealStatsLocked and "Unlock Frame" or "Lock Frame")
    end })

    local slOverhealScale = BuildSlider(p5, "OHSScale", 50, 150, 5,
        btnOverhealLock, "BOTTOMLEFT", 0, -16,
        function() return (Settings.overhealStatsScale or 1) * 100 end,
        function(v)
            Settings.overhealStatsScale = v / 100
            if HP.UpdateOverhealStatsScale then HP.UpdateOverhealStatsScale() end
        end, "Panel scale: %d%%")

    -- Visibility mode dropdown
    local OVERHEAL_VISIBILITY_LABELS = { "Always", "Raid Only", "Dungeon Only", "Raid & Dungeon" }
    local btnOverhealVisibility = CreateFrame("Button", "HP_BtnOHSVisibility", p5, "UIPanelButtonTemplate")
    btnOverhealVisibility:SetSize(180, 20)
    btnOverhealVisibility:SetPoint("TOPLEFT", slOverhealScale, "BOTTOMLEFT", 0, -16)
    btnOverhealVisibility:SetText("Show: " .. (OVERHEAL_VISIBILITY_LABELS[Settings.overhealStatsVisibility or 1] or "Always"))
    btnOverhealVisibility:SetScript("OnClick", function(self)
        local mode = (Settings.overhealStatsVisibility or 1) % #OVERHEAL_VISIBILITY_LABELS + 1
        Settings.overhealStatsVisibility = mode
        self:SetText("Show: " .. OVERHEAL_VISIBILITY_LABELS[mode])
        if HP.UpdateOverhealStatsVisibility then HP.UpdateOverhealStatsVisibility() end
    end)
    tinsert(optWidgets.buttons, { btn = btnOverhealVisibility, refresh = function()
        btnOverhealVisibility:SetText("Show: " .. (OVERHEAL_VISIBILITY_LABELS[Settings.overhealStatsVisibility or 1] or "Always"))
    end })

    -- Reset mode dropdown
    local OVERHEAL_RESET_LABELS = { "After delay", "Boss kill", "Instance end" }
    local btnOverhealReset = CreateFrame("Button", "HP_BtnOHSReset", p5, "UIPanelButtonTemplate")
    btnOverhealReset:SetSize(180, 20)
    btnOverhealReset:SetPoint("TOPLEFT", btnOverhealVisibility, "BOTTOMLEFT", 0, -4)
    btnOverhealReset:SetText("Reset: " .. (OVERHEAL_RESET_LABELS[Settings.overhealStatsResetMode or 1] or "After delay"))
    btnOverhealReset:SetScript("OnClick", function(self)
        local mode = (Settings.overhealStatsResetMode or 1) % #OVERHEAL_RESET_LABELS + 1
        Settings.overhealStatsResetMode = mode
        self:SetText("Reset: " .. OVERHEAL_RESET_LABELS[mode])
    end)
    tinsert(optWidgets.buttons, { btn = btnOverhealReset, refresh = function()
        btnOverhealReset:SetText("Reset: " .. (OVERHEAL_RESET_LABELS[Settings.overhealStatsResetMode or 1] or "After delay"))
    end })

    -- Reset delay slider (only for "After delay" mode)
    local slOverhealDelay = BuildSlider(p5, "OHSResetDelay", 3, 60, 1,
        btnOverhealReset, "BOTTOMLEFT", 0, -16,
        function() return Settings.overhealStatsResetDelay or 8 end,
        function(v)
            Settings.overhealStatsResetDelay = v
        end, "Reset delay: %ds")

    -- Hide out of combat checkbox
    local cbOverhealOOC = BuildCheck(p5, "Hide out of combat",
        slOverhealDelay, "BOTTOMLEFT", 0, -8,
        function() return Settings.overhealStatsHideOOC end,
        function(v)
            Settings.overhealStatsHideOOC = v
            if HP.UpdateOverhealStatsCombatStatus then HP.UpdateOverhealStatsCombatStatus() end
        end)

    --------------- Section: Heal Queue Timeline ---------------
    local secHealQueue = DrawSection(p5, "HEAL QUEUE TIMELINE", cbOverhealOOC, "BOTTOMLEFT", 0, -10)

    local cbHealQueue = BuildCheck(p5, "Show heal queue timeline",
        secHealQueue, "BOTTOMLEFT", 0, -6,
        function() return Settings.healQueue end,
        function(v)
            Settings.healQueue = v
            if HP.ToggleHealQueue then HP.ToggleHealQueue() end
            if v then
                if HP.StartHealQueueTicker then HP.StartHealQueueTicker() end
                if Settings.healQueueHideOOC then
                    C_Timer.After(0, function()
                        if HP.UpdateHealQueueCombatStatus then HP.UpdateHealQueueCombatStatus() end
                    end)
                end
            else
                if HP.StopHealQueueTicker then HP.StopHealQueueTicker() end
            end
        end,
        "Displays a timeline showing all incoming heals on your target, color-coded by healer class.")

    -- Lock/Unlock button
    local btnHealQueueLock = CreateFrame("Button", "HP_BtnHQLock", p5, "UIPanelButtonTemplate")
    btnHealQueueLock:SetSize(140, 20)
    btnHealQueueLock:SetPoint("TOPLEFT", cbHealQueue, "BOTTOMLEFT", 0, -4)
    btnHealQueueLock:SetText(Settings.healQueueLocked and "Unlock Frame" or "Lock Frame")
    btnHealQueueLock:SetScript("OnClick", function(self)
        Settings.healQueueLocked = not Settings.healQueueLocked
        self:SetText(Settings.healQueueLocked and "Unlock Frame" or "Lock Frame")
        if HP.SetHealQueueMovable then HP.SetHealQueueMovable(not Settings.healQueueLocked) end
    end)
    tinsert(optWidgets.buttons, { btn = btnHealQueueLock, refresh = function()
        btnHealQueueLock:SetText(Settings.healQueueLocked and "Unlock Frame" or "Lock Frame")
    end })

    -- Scale slider
    local slHealQueueScale = BuildSlider(p5, "HQScale", 50, 200, 5,
        btnHealQueueLock, "BOTTOMLEFT", 0, -16,
        function() return (Settings.healQueueScale or 1) * 100 end,
        function(v)
            Settings.healQueueScale = v / 100
            if HP.UpdateHealQueueScale then HP.UpdateHealQueueScale() end
        end, "Panel scale: %d%%")

    -- Width slider
    local slHealQueueWidth = BuildSlider(p5, "HQWidth", 160, 400, 10,
        slHealQueueScale, "BOTTOMLEFT", 0, -16,
        function() return Settings.healQueueWidth or 260 end,
        function(v)
            Settings.healQueueWidth = v
            if HP.UpdateHealQueueWidth then HP.UpdateHealQueueWidth() end
        end, "Width: %dpx")

    -- Lookahead slider
    local slHealQueueLookahead = BuildSlider(p5, "HQLookahead", 2, 10, 1,
        slHealQueueWidth, "BOTTOMLEFT", 0, -16,
        function() return Settings.healQueueLookahead or 4 end,
        function(v) Settings.healQueueLookahead = v end,
        "Lookahead: %ds")

    -- Target mode button
    local HQ_TARGET_LABELS = { "Current Target", "Mouseover", "Mouseover > Target" }
    local btnHealQueueTarget = CreateFrame("Button", "HP_BtnHQTarget", p5, "UIPanelButtonTemplate")
    btnHealQueueTarget:SetSize(200, 20)
    btnHealQueueTarget:SetPoint("TOPLEFT", slHealQueueLookahead, "BOTTOMLEFT", 0, -16)
    btnHealQueueTarget:SetText("Show: " .. (HQ_TARGET_LABELS[Settings.healQueueShowTarget or 1] or "Current Target"))
    btnHealQueueTarget:SetScript("OnClick", function(self)
        local mode = (Settings.healQueueShowTarget or 1) % #HQ_TARGET_LABELS + 1
        Settings.healQueueShowTarget = mode
        self:SetText("Show: " .. HQ_TARGET_LABELS[mode])
    end)
    tinsert(optWidgets.buttons, { btn = btnHealQueueTarget, refresh = function()
        btnHealQueueTarget:SetText("Show: " .. (HQ_TARGET_LABELS[Settings.healQueueShowTarget or 1] or "Current Target"))
    end })

    -- Show deficit marker checkbox
    local cbHealQueueDeficit = BuildCheck(p5, "Show deficit marker",
        btnHealQueueTarget, "BOTTOMLEFT", 0, -4,
        function() return Settings.healQueueShowDeficit end,
        function(v) Settings.healQueueShowDeficit = v end,
        "Red vertical line marking where incoming heals cover the target's health deficit.")

    -- Show caster names checkbox
    local cbHealQueueNames = BuildCheck(p5, "Show spell names & timers",
        cbHealQueueDeficit, "BOTTOMLEFT", 0, -2,
        function() return Settings.healQueueShowNames end,
        function(v) Settings.healQueueShowNames = v end,
        "Show spell name and time-to-land on each bar in the timeline.")

    -- Hide out of combat checkbox
    local cbHealQueueOOC = BuildCheck(p5, "Hide queue out of combat",
        cbHealQueueNames, "BOTTOMLEFT", 0, -2,
        function() return Settings.healQueueHideOOC end,
        function(v) Settings.healQueueHideOOC = v end,
        "Hides the heal queue timeline when you are not in combat.")

    --------------- Section: Smart Learning ---------------
    local secLearning = DrawSection(p5, "SMART LEARNING", cbHealQueueOOC, "BOTTOMLEFT", 0, -10)

    local cbEncounter = BuildCheck(p5, "Enable boss encounter learning",
        secLearning, "BOTTOMLEFT", 0, -6,
        function() return Settings.smartLearning end,
        function(v)
            Settings.smartLearning = v
            if v then
                print("|cff33ccffHealPredict:|r Smart Encounter Learning enabled. Fight bosses to start learning!")
            end
        end,
        "Tracks your healing patterns on each boss encounter, learns from attempts, and provides real-time suggestions.")

    local cbInstanceTracking = BuildCheck(p5, "Enable instance-wide tracking",
        cbEncounter, "BOTTOMLEFT", 0, -2,
        function() return Settings.instanceTracking end,
        function(v)
            Settings.instanceTracking = v
            if v then
                print("|cff33ccffHealPredict:|r Instance tracking enabled. Enter a dungeon or raid to start tracking!")
            end
        end,
        "Tracks healing performance across entire dungeon and raid runs (trash + bosses). Records pull count, HPS, overheal, deaths, and top spells. Data persists across sessions.")

    -- CD Advisor overlay checkbox
    local cbCDAdvisor = BuildCheck(p5, "Show cooldown advisor overlay",
        cbInstanceTracking, "BOTTOMLEFT", 0, -2,
        function() return Settings.cdAdvisorWidget end,
        function(v) Settings.cdAdvisorWidget = v end,
        "Shows a compact warning near screen center when learned damage spikes are approaching.")

    -- CD Advisor scope button
    local CD_SCOPE_LABELS = { "Boss Only", "Full Instance" }
    local btnCDScope = CreateFrame("Button", "HP_BtnCDScope", p5, "UIPanelButtonTemplate")
    btnCDScope:SetSize(180, 20)
    btnCDScope:SetPoint("TOPLEFT", cbCDAdvisor, "BOTTOMLEFT", 20, -4)
    btnCDScope:SetText("Tracking: " .. (CD_SCOPE_LABELS[Settings.cdAdvisorScope or 1] or "Boss Only"))
    btnCDScope:SetScript("OnClick", function(self)
        local scope = (Settings.cdAdvisorScope or 1) % #CD_SCOPE_LABELS + 1
        Settings.cdAdvisorScope = scope
        self:SetText("Tracking: " .. CD_SCOPE_LABELS[scope])
    end)
    btnCDScope:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Boss Only tracks damage patterns during boss encounters.\nFull Instance also tracks trash pulls.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btnCDScope:SetScript("OnLeave", function() GameTooltip:Hide() end)
    tinsert(optWidgets.buttons, { btn = btnCDScope, refresh = function()
        btnCDScope:SetText("Tracking: " .. (CD_SCOPE_LABELS[Settings.cdAdvisorScope or 1] or "Boss Only"))
    end })

    -- Instance tracking scope
    local INSTANCE_SCOPE_LABELS = { "Dungeons Only", "Raids Only", "Both" }
    local btnInstanceScope = CreateFrame("Button", "HP_BtnInstanceScope", p5, "UIPanelButtonTemplate")
    btnInstanceScope:SetSize(180, 20)
    btnInstanceScope:SetPoint("TOPLEFT", btnCDScope, "BOTTOMLEFT", 0, -2)
    btnInstanceScope:SetText("Track: " .. (INSTANCE_SCOPE_LABELS[Settings.instanceTrackingScope or 3] or "Both"))
    btnInstanceScope:SetScript("OnClick", function(self)
        local scope = (Settings.instanceTrackingScope or 3) % #INSTANCE_SCOPE_LABELS + 1
        Settings.instanceTrackingScope = scope
        self:SetText("Track: " .. INSTANCE_SCOPE_LABELS[scope])
    end)
    tinsert(optWidgets.buttons, { btn = btnInstanceScope, refresh = function()
        btnInstanceScope:SetText("Track: " .. (INSTANCE_SCOPE_LABELS[Settings.instanceTrackingScope or 3] or "Both"))
    end })

    -- Suggestion display mode
    local ENCOUNTER_SUGGESTION_LABELS = { "Chat", "UI Panel", "Both", "Disabled" }
    local btnSuggestionMode = CreateFrame("Button", "HP_BtnSuggestionMode", p5, "UIPanelButtonTemplate")
    btnSuggestionMode:SetSize(180, 20)
    btnSuggestionMode:SetPoint("TOPLEFT", btnInstanceScope, "BOTTOMLEFT", 0, -2)
    btnSuggestionMode:SetText("Suggestions: " .. (ENCOUNTER_SUGGESTION_LABELS[Settings.encounterSuggestionMode or 1] or "Chat"))
    btnSuggestionMode:SetScript("OnClick", function(self)
        local mode = (Settings.encounterSuggestionMode or 1) % #ENCOUNTER_SUGGESTION_LABELS + 1
        Settings.encounterSuggestionMode = mode
        self:SetText("Suggestions: " .. ENCOUNTER_SUGGESTION_LABELS[mode])
    end)
    tinsert(optWidgets.buttons, { btn = btnSuggestionMode, refresh = function()
        btnSuggestionMode:SetText("Suggestions: " .. (ENCOUNTER_SUGGESTION_LABELS[Settings.encounterSuggestionMode or 1] or "Chat"))
    end })

    -- Panel auto-hide delay slider
    local slPanelHide = BuildSlider(p5, "PanelHide", 2, 30, 1,
        btnSuggestionMode, "BOTTOMLEFT", -20, -14,
        function() return Settings.panelHideDelay or 5 end,
        function(v) Settings.panelHideDelay = v end, "Panel auto-hide: %ds")

    -- Data retention slider (0 = never auto-prune)
    local function fmtRetention(v) return v == 0 and "Data retention: Never" or fmt("Data retention: %dd", v) end
    local slRetention = BuildSlider(p5, "DataRet", 0, 90, 1,
        slPanelHide, "BOTTOMLEFT", 0, -18,
        function() return Settings.dataRetentionDays end,
        function(v) Settings.dataRetentionDays = v end, "%d")
    -- Override OnValueChanged + refresh entry to use custom format
    slRetention:SetScript("OnValueChanged", function(self, v)
        self.Text:SetText(fmtRetention(v)); Settings.dataRetentionDays = v; HP.RefreshAll()
    end)
    slRetention.Text:SetText(fmtRetention(Settings.dataRetentionDays))
    optWidgets.sliders[#optWidgets.sliders].pattern = nil
    optWidgets.sliders[#optWidgets.sliders].fmtFn = fmtRetention

    -- Max run history slider
    local slMaxRuns = BuildSlider(p5, "MaxRuns", 5, 50, 5,
        slRetention, "BOTTOMLEFT", 0, -18,
        function() return Settings.maxRunHistory or 10 end,
        function(v) Settings.maxRunHistory = v end, "Max run history: %d")

    -- Preview panel button
    local btnPreviewPanel = CreateFrame("Button", "HP_BtnPreviewPanel", p5, "UIPanelButtonTemplate")
    btnPreviewPanel:SetSize(180, 20)
    btnPreviewPanel:SetPoint("TOPLEFT", slMaxRuns, "BOTTOMLEFT", 20, -10)
    btnPreviewPanel:SetText("Preview Panel")
    btnPreviewPanel:SetScript("OnClick", function()
        if HP.PreviewEncounterPanel then HP.PreviewEncounterPanel() end
    end)

    -- View encounter data button
    local btnEncounterStats = CreateFrame("Button", "HP_BtnEncounterStats", p5, "UIPanelButtonTemplate")
    btnEncounterStats:SetSize(180, 20)
    btnEncounterStats:SetPoint("TOPLEFT", btnPreviewPanel, "BOTTOMLEFT", 0, -2)
    btnEncounterStats:SetText("View Encounter Data")
    btnEncounterStats:SetScript("OnClick", function()
        if HP.ShowLearningPanel then HP.ShowLearningPanel() end
    end)

    -- View instance data button
    local btnInstanceStats = CreateFrame("Button", "HP_BtnInstanceStats", p5, "UIPanelButtonTemplate")
    btnInstanceStats:SetSize(180, 20)
    btnInstanceStats:SetPoint("TOPLEFT", btnEncounterStats, "BOTTOMLEFT", 0, -2)
    btnInstanceStats:SetText("View Instance Data")
    btnInstanceStats:SetScript("OnClick", function()
        if HP.ShowInstanceData then HP.ShowInstanceData() end
    end)

    -- Clear all data button
    local btnClearAll = CreateFrame("Button", "HP_BtnClearAllData", p5, "UIPanelButtonTemplate")
    btnClearAll:SetSize(180, 20)
    btnClearAll:SetPoint("TOPLEFT", btnInstanceStats, "BOTTOMLEFT", 0, -2)
    btnClearAll:SetText("Clear All Data")
    btnClearAll:SetScript("OnClick", function()
        HP.encounterDB = {}
        if HP.db then HP.db.encounterDB = HP.encounterDB end
        HP.instanceDB = {}
        if HP.db then HP.db.instanceDB = HP.instanceDB end
        HP.currentInstance = nil
        print("|cff33ccffHealPredict:|r All encounter and instance data has been cleared.")
    end)

    end -- BuildAnalyticsTab
    BuildAnalyticsTab(p5)

    --=======================================================================
    -- TAB 2: Indicators  (All raid/unit frame indicators with colors)
    --=======================================================================
    local function BuildIndicatorsTab(p2)

    --------------- Section: Indicator Border ---------------
    local secBorder = DrawSection(p2, "INDICATOR BORDER", p2, "TOPLEFT", 0, 0)

    local slBorderThick = BuildSlider(p2, "BorderT", 1, 4, 1,
        secBorder, "BOTTOMLEFT", 0, -20,
        function() return Settings.borderThickness end,
        function(v) Settings.borderThickness = v; if HP.RefreshBorderThickness then HP.RefreshBorderThickness() end end, "Indicator border: %dpx")

    --------------- Section: Shields & Absorbs ---------------
    local secShield = DrawSection(p2, "SHIELDS & ABSORBS", slBorderThick, "BOTTOMLEFT", 0, -10)

    local cbShield = BuildCheck(p2, "Shield glow on health bars",
        secShield, "BOTTOMLEFT", 0, -6,
        function() return Settings.showShieldGlow end,
        function(v) Settings.showShieldGlow = v end)

    local cbShieldText = BuildCheck(p2, "Show shield spell name",
        cbShield, "BOTTOMLEFT", 20, -2,
        function() return Settings.showShieldText end,
        function(v) Settings.showShieldText = v end)

    local slShieldX = BuildSlider(p2, "ShieldX", -50, 50, 1,
        cbShieldText, "BOTTOMLEFT", 0, -8,
        function() return Settings.shieldTextOffsetX end,
        function(v) Settings.shieldTextOffsetX = v end, "X: %d")

    local slShieldY = BuildSlider(p2, "ShieldY", -30, 30, 1,
        slShieldX, "BOTTOMLEFT", 0, -18,
        function() return Settings.shieldTextOffsetY end,
        function(v) Settings.shieldTextOffsetY = v end, "Y: %d")

    local cbAbsorbBar = BuildCheck(p2, "Absorb presence bar on health bars",
        slShieldY, "BOTTOMLEFT", -20, -24,
        function() return Settings.showAbsorbBar end,
        function(v) Settings.showAbsorbBar = v end)

    local srAbsorbColor = BuildSwatchRow(p2, "Absorb Bar:",
        { "absorbBar" },
        cbAbsorbBar, "BOTTOMLEFT", 0, -4)

    --------------- Section: Defensives ---------------
    local secDef = DrawSection(p2, "DEFENSIVES", srAbsorbColor, "BOTTOMLEFT", 0, -10)

    local cbDefense = BuildCheck(p2, "Defensive status text on raid frames",
        secDef, "BOTTOMLEFT", 0, -6,
        function() return Settings.showDefensives end,
        function(v) Settings.showDefensives = v end)

    local cbInvulns = BuildCheck(p2, "Invulnerabilities (Divine Shield, Ice Block)",
        cbDefense, "BOTTOMLEFT", 20, -2,
        function() return Settings.showInvulns end,
        function(v) Settings.showInvulns = v end)

    local cbStrongMit = BuildCheck(p2, "Strong mitigation (BOP, Shield Wall)",
        cbInvulns, "BOTTOMLEFT", 0, -2,
        function() return Settings.showStrongMit end,
        function(v) Settings.showStrongMit = v end)

    local cbWeakMit = BuildCheck(p2, "Weak mitigation (Evasion, Barkskin)",
        cbStrongMit, "BOTTOMLEFT", 0, -2,
        function() return Settings.showWeakMit end,
        function(v) Settings.showWeakMit = v end)

    local cbDefenseIcon = BuildCheck(p2, "Show defensive spell icon",
        cbWeakMit, "BOTTOMLEFT", 0, -6,
        function() return Settings.showDefensiveIcon ~= false end,
        function(v) Settings.showDefensiveIcon = v end,
        "Displays the spell icon next to the defensive cooldown text for better visibility.")

    local slDefenseIconSize = BuildSlider(p2, "IconSize", 10, 24, 1,
        cbDefenseIcon, "BOTTOMLEFT", 0, -16,
        function() return Settings.defensiveIconSize or 16 end,
        function(v) Settings.defensiveIconSize = v end, "Icon size: %d")

    local slDefenseTextSize = BuildSlider(p2, "TxtSize", 8, 14, 1,
        slDefenseIconSize, "BOTTOMLEFT", 0, -10,
        function() return Settings.defensiveTextSize or 11 end,
        function(v) Settings.defensiveTextSize = v end, "Text size: %d")

    local DEFENSE_MODE_LABELS = { "Text only", "Icon only", "Icon + Text" }
    local btnDefenseMode = CreateFrame("Button", "HP_BtnDefenseMode", p2, "UIPanelButtonTemplate")
    btnDefenseMode:SetSize(160, 20)
    btnDefenseMode:SetPoint("TOPLEFT", slDefenseTextSize, "BOTTOMLEFT", 0, -8)
    btnDefenseMode:SetText("Display: " .. (DEFENSE_MODE_LABELS[Settings.defensiveDisplayMode or 3] or "Icon + Text"))
    btnDefenseMode:SetScript("OnClick", function(self)
        local mode = (Settings.defensiveDisplayMode or 3) % #DEFENSE_MODE_LABELS + 1
        Settings.defensiveDisplayMode = mode
        self:SetText("Display: " .. DEFENSE_MODE_LABELS[mode])
        HP.RefreshAll()
    end)
    btnDefenseMode:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Defensive Display Mode", 1, 1, 1)
        GameTooltip:AddLine("Controls the icon/text display on raid frames", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Text only: Shows abbreviation only", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Icon only: Shows spell icon only", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Icon + Text: Shows both (default)", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Use 'Border style' for additional indicator effect", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    btnDefenseMode:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnDefenseMode, refresh = function()
        -- Migrate old settings that had mode 4 (border effect)
        local mode = Settings.defensiveDisplayMode or 3
        if mode > 3 then mode = 3 end
        btnDefenseMode:SetText("Display: " .. (DEFENSE_MODE_LABELS[mode] or "Icon + Text"))
    end })

    local DEFENSE_EFFECT_LABELS = { "No effect", "Static", "Glow", "Spinning", "Slashes", "Pulse Ring", "Strobe", "Wave" }
    local btnDefenseStyle = CreateFrame("Button", "HP_BtnDefenseStyle", p2, "UIPanelButtonTemplate")
    btnDefenseStyle:SetSize(160, 20)
    btnDefenseStyle:SetPoint("TOPLEFT", btnDefenseMode, "BOTTOMLEFT", 0, -6)
    btnDefenseStyle:SetText("Border style: " .. (DEFENSE_EFFECT_LABELS[(Settings.defensiveStyle or 3)] or "Glow"))
    btnDefenseStyle:SetScript("OnClick", function(self)
        local s = (Settings.defensiveStyle or 3) % #DEFENSE_EFFECT_LABELS + 1
        Settings.defensiveStyle = s
        self:SetText("Border style: " .. DEFENSE_EFFECT_LABELS[s])
        HP.RefreshAll()
    end)
    btnDefenseStyle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Defensive Border Style", 1, 1, 1)
        GameTooltip:AddLine("Select border effect for defensive cooldowns", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("No effect: Disabled", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    btnDefenseStyle:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnDefenseStyle, refresh = function()
        btnDefenseStyle:SetText("Border style: " .. (DEFENSE_EFFECT_LABELS[(Settings.defensiveStyle or 3)] or "Glow"))
    end })

    local srDefenseColor = BuildSwatchRow(p2, "Defensive Border:",
        { "defensiveBorder" },
        btnDefenseStyle, "BOTTOMLEFT", 0, -4,
        "Color for defensive cooldown border effect (when using border style).")

    local slDefenseX = BuildSlider(p2, "DefenseX", -50, 50, 1,
        srDefenseColor, "BOTTOMLEFT", 20, -8,
        function() return Settings.defensiveOffsetX or 0 end,
        function(v) Settings.defensiveOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "X: %d")

    local slDefenseY = BuildSlider(p2, "DefenseY", -30, 30, 1,
        slDefenseX, "BOTTOMLEFT", 0, -18,
        function() return Settings.defensiveOffsetY or 0 end,
        function(v) Settings.defensiveOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Y: %d")

    --------------- Section: Dispel Highlight ---------------
    local EFFECT_STYLE_LABELS = { "Static", "Glow", "Spinning", "Slashes", "Pulse Ring", "Strobe", "Wave" }

    local secDispel = DrawSection(p2, "DISPEL HIGHLIGHT", slDefenseY, "BOTTOMLEFT", -20, -10)

    local cbDispel = BuildCheck(p2, "Dispel highlight on raid frames",
        secDispel, "BOTTOMLEFT", 0, -6,
        function() return Settings.dispelHighlight end,
        function(v) Settings.dispelHighlight = v end,
        "Color-codes raid frames when a target has a dispellable debuff matching your class abilities.")

    local btnDispelStyle = CreateFrame("Button", "HP_BtnDispelStyle", p2, "UIPanelButtonTemplate")
    btnDispelStyle:SetSize(140, 20)
    btnDispelStyle:SetPoint("TOPLEFT", cbDispel, "BOTTOMLEFT", 0, -4)
    btnDispelStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.dispelStyle] or "Static"))
    btnDispelStyle:SetScript("OnClick", function(self)
        local s = (Settings.dispelStyle or 1) % #EFFECT_STYLE_LABELS + 1
        Settings.dispelStyle = s
        self:SetText("Style: " .. EFFECT_STYLE_LABELS[s])
        HP.RefreshAll()
    end)
    btnDispelStyle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Indicator Effect Style", 1, 1, 1)
        GameTooltip:AddLine("Static: solid border. Glow: pulsing alpha. Spinning: orbiting dots. Slashes: diagonal lines sweeping across.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnDispelStyle:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnDispelStyle, refresh = function()
        btnDispelStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.dispelStyle] or "Static"))
    end })

    local srDispelMagic = BuildSwatchRow(p2, "Dispel Magic:",
        { "dispelMagic" },
        btnDispelStyle, "BOTTOMLEFT", -0, -4,
        "Overlay color for Magic debuffs.")

    local srDispelCurse = BuildSwatchRow(p2, "Dispel Curse:",
        { "dispelCurse" },
        srDispelMagic, "BOTTOMLEFT", 0, -4,
        "Overlay color for Curse debuffs.")

    local srDispelDisease = BuildSwatchRow(p2, "Dispel Disease:",
        { "dispelDisease" },
        srDispelCurse, "BOTTOMLEFT", 0, -4,
        "Overlay color for Disease debuffs.")

    local srDispelPoison = BuildSwatchRow(p2, "Dispel Poison:",
        { "dispelPoison" },
        srDispelDisease, "BOTTOMLEFT", 0, -4,
        "Overlay color for Poison debuffs.")

    --------------- Section: Heal Reduction ---------------
    local secHealReduc = DrawSection(p2, "HEAL REDUCTION", srDispelPoison, "BOTTOMLEFT", 0, -10)

    local cbHealReduc = BuildCheck(p2, "Heal reduction indicator",
        secHealReduc, "BOTTOMLEFT", 0, -6,
        function() return Settings.healReductionGlow end,
        function(v) Settings.healReductionGlow = v end,
        "Shows a red glow and percentage on raid frames when a target has a healing reduction debuff (Mortal Strike, etc.).")

    local HEAL_REDUC_LABELS = { "Static", "Glow", "Spinning", "Slashes", "Pulse Ring", "Strobe", "Wave", "No effect" }
    local btnHealReducStyle = CreateFrame("Button", "HP_BtnHealReducStyle", p2, "UIPanelButtonTemplate")
    btnHealReducStyle:SetSize(140, 20)
    btnHealReducStyle:SetPoint("TOPLEFT", cbHealReduc, "BOTTOMLEFT", 0, -8)
    btnHealReducStyle:SetText("Style: " .. (HEAL_REDUC_LABELS[Settings.healReducStyle] or "Static"))
    btnHealReducStyle:SetScript("OnClick", function(self)
        local s = (Settings.healReducStyle or 1) % #HEAL_REDUC_LABELS + 1
        Settings.healReducStyle = s
        self:SetText("Style: " .. HEAL_REDUC_LABELS[s])
        HP.RefreshAll()
    end)
    btnHealReducStyle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Indicator Effect Style", 1, 1, 1)
        GameTooltip:AddLine("Static: solid border. Glow: pulsing alpha. Spinning: orbiting dots. Slashes: diagonal lines. No effect: text only.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnHealReducStyle:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnHealReducStyle, refresh = function()
        btnHealReducStyle:SetText("Style: " .. (HEAL_REDUC_LABELS[Settings.healReducStyle] or "Static"))
    end })

    local cbHealReducText = BuildCheck(p2, "Show reduction percentage text",
        btnHealReducStyle, "BOTTOMLEFT", 0, -8,
        function() return Settings.healReductionText end,
        function(v) Settings.healReductionText = v; HP.RefreshAll() end,
        "Shows the heal reduction percentage (e.g. -50%) on the raid frame.")

    local slHealReducThresh = BuildSlider(p2, "HealReducThresh", 0, 100, 5,
        cbHealReducText, "BOTTOMLEFT", 20, -16,
        function() return Settings.healReductionThreshold end,
        function(v) Settings.healReductionThreshold = v; HP.RefreshAll() end,
        "Min reduction: %d%%")

    local srHealReducColor = BuildSwatchRow(p2, "Heal Reduction:",
        { "healReduction" },
        slHealReducThresh, "BOTTOMLEFT", -20, -10,
        "Glow color for targets with healing reduction debuffs.")

    local slHealReducX = BuildSlider(p2, "HealReducX", -50, 50, 1,
        srHealReducColor, "BOTTOMLEFT", 20, -8,
        function() return Settings.healReducOffsetX or 0 end,
        function(v) Settings.healReducOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Text X: %d")

    local slHealReducY = BuildSlider(p2, "HealReducY", -30, 30, 1,
        slHealReducX, "BOTTOMLEFT", 0, -18,
        function() return Settings.healReducOffsetY or 0 end,
        function(v) Settings.healReducOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Text Y: %d")

    --------------- Section: HoT Expiry Warning ---------------
    local secHotExpiry = DrawSection(p2, "HOT EXPIRY WARNING", slHealReducY, "BOTTOMLEFT", -20, -10)

    local cbHotExpiry = BuildCheck(p2, "HoT expiry warning border",
        secHotExpiry, "BOTTOMLEFT", 0, -6,
        function() return Settings.hotExpiryWarning end,
        function(v) Settings.hotExpiryWarning = v end,
        "Shows an orange border when your HoTs on a target are about to expire.")

    local btnHotExpiryStyle = CreateFrame("Button", "HP_BtnHotExpiryStyle", p2, "UIPanelButtonTemplate")
    btnHotExpiryStyle:SetSize(140, 20)
    btnHotExpiryStyle:SetPoint("TOPLEFT", cbHotExpiry, "BOTTOMLEFT", 0, -4)
    btnHotExpiryStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.hotExpiryStyle] or "Static"))
    btnHotExpiryStyle:SetScript("OnClick", function(self)
        local s = (Settings.hotExpiryStyle or 1) % #EFFECT_STYLE_LABELS + 1
        Settings.hotExpiryStyle = s
        self:SetText("Style: " .. EFFECT_STYLE_LABELS[s])
        HP.RefreshAll()
    end)
    btnHotExpiryStyle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Indicator Effect Style", 1, 1, 1)
        GameTooltip:AddLine("Static: solid border. Glow: pulsing alpha. Spinning: orbiting dots. Slashes: diagonal lines sweeping across.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnHotExpiryStyle:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnHotExpiryStyle, refresh = function()
        btnHotExpiryStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.hotExpiryStyle] or "Static"))
    end })

    local slHotThresh = BuildSlider(p2, "HotExp", 1, 8, 1,
        btnHotExpiryStyle, "BOTTOMLEFT", 20, -24,
        function() return Settings.hotExpiryThreshold end,
        function(v) Settings.hotExpiryThreshold = v end, "Threshold: %ds")

    local srHotExpiryColor = BuildSwatchRow(p2, "HoT Expiry:",
        { "hotExpiry" },
        slHotThresh, "BOTTOMLEFT", -20, -4,
        "Border color when your HoTs are about to expire on a target.")

    --------------- Section: HoT Tracker Dots ---------------
    local secHotDots = DrawSection(p2, "HOT TRACKER DOTS", srHotExpiryColor, "BOTTOMLEFT", 0, -10)

    local cbHotDots = BuildCheck(p2, "HoT tracker dots",
        secHotDots, "BOTTOMLEFT", 0, -6,
        function() return Settings.hotTrackerDots end,
        function(v) Settings.hotTrackerDots = v end,
        "Shows small colored dots on raid frames for your active HoTs (Renew, Rejuv, Regrowth, Lifebloom, Earth Shield).")

    local cbHotDotsOthers = BuildCheck(p2, "Show other healers' HoT dots",
        cbHotDots, "BOTTOMLEFT", 0, -2,
        function() return Settings.hotTrackerDotsOthers end,
        function(v) Settings.hotTrackerDotsOthers = v end,
        "Shows small colored dots for HoTs from other healers. Displayed above your own HoT dots with different colors.")

    -- HoT Dot size slider
    local slHotDotSize = BuildSlider(p2, "DotSize", 2, 24, 1,
        cbHotDotsOthers, "BOTTOMLEFT", 20, -8,
        function() return Settings.hotDotSize or 4 end,
        function(v)
            Settings.hotDotSize = v
            if HP.RefreshHoTDots then HP.RefreshHoTDots() end
        end, "Dot size: %dpx")

    -- HoT Dot spacing slider
    local slHotDotSpacing = BuildSlider(p2, "DotSpace", 4, 28, 1,
        slHotDotSize, "BOTTOMLEFT", 0, -16,
        function() return Settings.hotDotSpacing or 6 end,
        function(v)
            Settings.hotDotSpacing = v
            if HP.RefreshHoTDots then HP.RefreshHoTDots() end
        end, "Spacing: %dpx")

    -- HoT Dot row mode button
    local HOT_DOT_ROW_LABELS = { "Two rows (own/other)", "Single row" }
    local btnHotDotRowMode = CreateFrame("Button", "HP_BtnHotDotRow", p2, "UIPanelButtonTemplate")
    btnHotDotRowMode:SetSize(170, 20)
    btnHotDotRowMode:SetPoint("TOPLEFT", slHotDotSpacing, "BOTTOMLEFT", 0, -4)
    btnHotDotRowMode:SetText("Layout: " .. (HOT_DOT_ROW_LABELS[Settings.hotDotRowMode or 1] or "Two rows"))
    btnHotDotRowMode:SetScript("OnClick", function(self)
        local mode = (Settings.hotDotRowMode or 1) % 2 + 1
        Settings.hotDotRowMode = mode
        self:SetText("Layout: " .. HOT_DOT_ROW_LABELS[mode])
        if HP.RefreshHoTDots then HP.RefreshHoTDots() end
    end)
    btnHotDotRowMode:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("HoT Dot Layout", 1, 1, 1)
        GameTooltip:AddLine("Two rows: Your HoTs on bottom row, other healers' HoTs above.", nil, nil, nil, true)
        GameTooltip:AddLine("Single row: All HoTs in one continuous row.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    btnHotDotRowMode:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnHotDotRowMode, refresh = function()
        btnHotDotRowMode:SetText("Layout: " .. (HOT_DOT_ROW_LABELS[Settings.hotDotRowMode or 1] or "Two rows"))
    end })

    -- HoT Dot display mode button
    local HOT_DOT_DISPLAY_LABELS = { "Colored dots", "Spell icons" }
    local btnHotDotDisplay = CreateFrame("Button", "HP_BtnHotDotDisplay", p2, "UIPanelButtonTemplate")
    btnHotDotDisplay:SetSize(170, 20)
    btnHotDotDisplay:SetPoint("TOPLEFT", btnHotDotRowMode, "BOTTOMLEFT", 0, -4)
    btnHotDotDisplay:SetText("Display: " .. (HOT_DOT_DISPLAY_LABELS[Settings.hotDotDisplayMode or 1] or "Colored dots"))
    btnHotDotDisplay:SetScript("OnClick", function(self)
        local mode = (Settings.hotDotDisplayMode or 1) % 2 + 1
        Settings.hotDotDisplayMode = mode
        self:SetText("Display: " .. HOT_DOT_DISPLAY_LABELS[mode])
        -- Auto-adjust size/spacing for icon mode vs dot mode
        if mode == 2 and (Settings.hotDotSize or 4) < 14 then
            Settings.hotDotSize = 14
            Settings.hotDotSpacing = 16
        elseif mode == 1 and (Settings.hotDotSize or 4) > 10 then
            Settings.hotDotSize = 4
            Settings.hotDotSpacing = 6
        end
        HP.RefreshOptions()
        print("|cff33ccffHealPredict:|r HoT display mode changed to " .. HOT_DOT_DISPLAY_LABELS[mode] .. ". Reload UI to apply (/reload).")
    end)
    btnHotDotDisplay:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("HoT Display Mode", 1, 1, 1)
        GameTooltip:AddLine("Colored dots: Small colored squares for each HoT type.", nil, nil, nil, true)
        GameTooltip:AddLine("Spell icons: Actual spell icons with cooldown sweep.", nil, nil, nil, true)
        GameTooltip:AddLine(" ", nil, nil, nil, true)
        GameTooltip:AddLine("Changing this requires a /reload to apply.", 1, 0.8, 0, true)
        GameTooltip:Show()
    end)
    btnHotDotDisplay:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnHotDotDisplay, refresh = function()
        btnHotDotDisplay:SetText("Display: " .. (HOT_DOT_DISPLAY_LABELS[Settings.hotDotDisplayMode or 1] or "Colored dots"))
    end })

    -- HoT Dot cooldown sweep toggle
    local cbHotDotCooldown = BuildCheck(p2, "Show cooldown sweep on icons",
        btnHotDotDisplay, "BOTTOMLEFT", 0, -4,
        function() return Settings.hotDotShowCooldown end,
        function(v) Settings.hotDotShowCooldown = v end,
        "Shows a cooldown sweep animation on spell icons to indicate remaining HoT duration.")

    local HOT_DOT_LABELS = isTBC
        and { "Renew", "Rejuv", "Regrowth", "Lifebloom", "Earth Shield" }
        or  { "Renew", "Rejuv", "Regrowth" }
    local HOT_DOT_LABELS_OTHER = isTBC
        and { "Renew (Other)", "Rejuv (Other)", "Regrowth (Other)", "Lifebloom (Other)", "Earth Shield (Other)" }
        or  { "Renew (Other)", "Rejuv (Other)", "Regrowth (Other)" }
    local HOT_DOT_KEYS = isTBC
        and { "hotDotRenew", "hotDotRejuv", "hotDotRegrowth", "hotDotLifebloom", "hotDotEarthShield" }
        or  { "hotDotRenew", "hotDotRejuv", "hotDotRegrowth" }
    local HOT_DOT_KEYS_OTHER = isTBC
        and { "hotDotRenewOther", "hotDotRejuvOther", "hotDotRegrowthOther", "hotDotLifebloomOther", "hotDotEarthShieldOther" }
        or  { "hotDotRenewOther", "hotDotRejuvOther", "hotDotRegrowthOther" }

    local srHotDotOwn = BuildSwatchRow(p2, "Your HoT Dots:",
        HOT_DOT_KEYS,
        cbHotDotCooldown, "BOTTOMLEFT", -20, -4,
        "Colors for your HoT tracker dots.",
        HOT_DOT_LABELS)

    local srHotDotOther = BuildSwatchRow(p2, "Other Healers' HoT Dots:",
        HOT_DOT_KEYS_OTHER,
        srHotDotOwn, "BOTTOMLEFT", 0, -4,
        "Colors for other healers' HoT dots.",
        HOT_DOT_LABELS_OTHER)

    local slHotDotsX = BuildSlider(p2, "HotDotsX", -50, 50, 1,
        srHotDotOther, "BOTTOMLEFT", 20, -8,
        function() return Settings.hotDotsOffsetX or 0 end,
        function(v) Settings.hotDotsOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "X: %d")

    local slHotDotsY = BuildSlider(p2, "HotDotsY", -30, 30, 1,
        slHotDotsX, "BOTTOMLEFT", 0, -18,
        function() return Settings.hotDotsOffsetY or 0 end,
        function(v) Settings.hotDotsOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Y: %d")

    --------------- Section: Charmed/Possessed ---------------
    local secCharmed = DrawSection(p2, "CHARMED / POSSESSED", slHotDotsY, "BOTTOMLEFT", -20, -10)

    local cbCharmed = BuildCheck(p2, "Charmed/Possessed indicator",
        secCharmed, "BOTTOMLEFT", 0, -6,
        function() return Settings.showCharmed end,
        function(v) Settings.showCharmed = v end,
        "Shows a magenta/purple indicator when a teammate is mind-controlled or charmed (hostile to you).")

    local btnCharmedStyle = CreateFrame("Button", "HP_BtnCharmedStyle", p2, "UIPanelButtonTemplate")
    btnCharmedStyle:SetSize(140, 20)
    btnCharmedStyle:SetPoint("TOPLEFT", cbCharmed, "BOTTOMLEFT", 0, -4)
    btnCharmedStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.charmedStyle or 3] or "Spinning"))
    btnCharmedStyle:SetScript("OnClick", function(self)
        local s = (Settings.charmedStyle or 3) % #EFFECT_STYLE_LABELS + 1
        Settings.charmedStyle = s
        self:SetText("Style: " .. EFFECT_STYLE_LABELS[s])
        HP.RefreshAll()
    end)
    btnCharmedStyle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Charmed Indicator Style", 1, 1, 1)
        GameTooltip:AddLine("Static: solid border. Glow: pulsing alpha. Spinning: orbiting dots. Slashes: diagonal lines sweeping across.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnCharmedStyle:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnCharmedStyle, refresh = function()
        btnCharmedStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.charmedStyle or 3] or "Spinning"))
    end })

    local srCharmedColor = BuildSwatchRow(p2, "Charmed/Possessed:",
        { "charmed" },
        btnCharmedStyle, "BOTTOMLEFT", -0, -4,
        "Indicator color for mind-controlled or charmed teammates (hostile to you).")

    --------------- Section: Cluster Detection ---------------
    local secCluster = DrawSection(p2, "CLUSTER DETECTION", srCharmedColor, "BOTTOMLEFT", 0, -10)

    local cbCluster = BuildCheck(p2, "Cluster detection",
        secCluster, "BOTTOMLEFT", 0, -6,
        function() return Settings.clusterDetection end,
        function(v) Settings.clusterDetection = v end,
        "Highlights subgroups where multiple members are below a health threshold.")

    local btnClusterStyle = CreateFrame("Button", "HP_BtnClusterStyle", p2, "UIPanelButtonTemplate")
    btnClusterStyle:SetSize(140, 20)
    btnClusterStyle:SetPoint("TOPLEFT", cbCluster, "BOTTOMLEFT", 0, -4)
    btnClusterStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.clusterStyle] or "Static"))
    btnClusterStyle:SetScript("OnClick", function(self)
        local s = (Settings.clusterStyle or 1) % #EFFECT_STYLE_LABELS + 1
        Settings.clusterStyle = s
        self:SetText("Style: " .. EFFECT_STYLE_LABELS[s])
        HP.RefreshAll()
    end)
    btnClusterStyle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Indicator Effect Style", 1, 1, 1)
        GameTooltip:AddLine("Static: solid border. Glow: pulsing alpha. Spinning: orbiting dots. Slashes: diagonal lines sweeping across.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnClusterStyle:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnClusterStyle, refresh = function()
        btnClusterStyle:SetText("Style: " .. (EFFECT_STYLE_LABELS[Settings.clusterStyle] or "Static"))
    end })

    local slClusterThresh = BuildSlider(p2, "ClustT", 40, 90, 5,
        btnClusterStyle, "BOTTOMLEFT", 20, -24,
        function() return Settings.clusterThreshold * 100 end,
        function(v) Settings.clusterThreshold = v / 100 end, "HP threshold: %d%%")

    local slClusterMin = BuildSlider(p2, "ClustM", 2, 5, 1,
        slClusterThresh, "BOTTOMLEFT", 0, -28,
        function() return Settings.clusterMinCount end,
        function(v) Settings.clusterMinCount = v end, "Min members: %d")

    local srClusterColor = BuildSwatchRow(p2, "Cluster Border:",
        { "clusterBorder" },
        slClusterMin, "BOTTOMLEFT", -20, -10,
        "Border color for cluster-detected subgroup members.")

    --------------- Section: AoE Advisor ---------------
    local secAoE = DrawSection(p2, "AOE ADVISOR", srClusterColor, "BOTTOMLEFT", 0, -10)

    local cbAoE = BuildCheck(p2, "AoE heal target advisor",
        secAoE, "BOTTOMLEFT", 0, -6,
        function() return Settings.aoeAdvisor end,
        function(v) Settings.aoeAdvisor = v end,
        "Highlights the best target for AoE heals based on subgroup health deficits in raids.")

    local srAoEColor = BuildSwatchRow(p2, "AoE Advisor:",
        { "aoeBorder" },
        cbAoE, "BOTTOMLEFT", 0, -4,
        "Border color for the AoE heal target advisor highlight.")

    --------------- Section: Death Prediction ---------------
    local secDeathPred = DrawSection(p2, "DEATH PREDICTION", srAoEColor, "BOTTOMLEFT", 0, -10)

    local cbDeathPred = BuildCheck(p2, "Enable death prediction warnings",
        secDeathPred, "BOTTOMLEFT", 0, -6,
        function() return Settings.deathPrediction end,
        function(v) Settings.deathPrediction = v; HP.RefreshAll() end,
        "Calculates incoming DPS vs healing and warns when targets will die before your heal lands. Red = critical, Yellow = urgent.")

    local slDeathPredThresh = BuildSlider(p2, "DeathPredT", 1, 5, 0.5,
        cbDeathPred, "BOTTOMLEFT", 0, -16,
        function() return Settings.deathPredThreshold end,
        function(v) Settings.deathPredThreshold = v end, "Warning at: %.1fs")

    local slDeathPredX = BuildSlider(p2, "DeathPredX", -50, 50, 1,
        slDeathPredThresh, "BOTTOMLEFT", 0, -18,
        function() return Settings.deathPredOffsetX or 0 end,
        function(v) Settings.deathPredOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "X: %d")

    local slDeathPredY = BuildSlider(p2, "DeathPredY", -30, 30, 1,
        slDeathPredX, "BOTTOMLEFT", 0, -18,
        function() return Settings.deathPredOffsetY or 0 end,
        function(v) Settings.deathPredOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Y: %d")

    --------------- Section: Range & Visibility ---------------
    local secRange = DrawSection(p2, "RANGE & VISIBILITY", slDeathPredY, "BOTTOMLEFT", -0, -16)

    local cbRange = BuildCheck(p2, "Dim out-of-range targets",
        secRange, "BOTTOMLEFT", 0, -6,
        function() return Settings.rangeIndicator end,
        function(v) Settings.rangeIndicator = v end,
        "Reduces opacity of heal bars on raid frames when the target is out of healing range.")

    local slRangeAlpha = BuildSlider(p2, "RangeA", 10, 90, 5,
        cbRange, "BOTTOMLEFT", 20, -8,
        function() return Settings.rangeAlpha * 100 end,
        function(v)
            Settings.rangeAlpha = v / 100
            -- Force-apply new alpha to all dimmed frames immediately
            if HP.ApplyRangeAlpha then HP.ApplyRangeAlpha() end
        end, "Dimmed opacity: %d%%")

    local cbHealerCount = BuildCheck(p2, "Show healer count per target",
        slRangeAlpha, "BOTTOMLEFT", -20, -2,
        function() return Settings.healerCount end,
        function(v) Settings.healerCount = v end,
        "Shows the number of active healers casting on each raid frame target.")

    local slHealerCountX = BuildSlider(p2, "HealerCntX", -50, 50, 1,
        cbHealerCount, "BOTTOMLEFT", 20, -8,
        function() return Settings.healerCountOffsetX or 0 end,
        function(v) Settings.healerCountOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "X: %d")

    local slHealerCountY = BuildSlider(p2, "HealerCntY", -30, 30, 1,
        slHealerCountX, "BOTTOMLEFT", 0, -18,
        function() return Settings.healerCountOffsetY or 0 end,
        function(v) Settings.healerCountOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Y: %d")

    local cbTrajectory = BuildCheck(p2, "Predictive health trajectory",
        slHealerCountY, "BOTTOMLEFT", -20, -2,
        function() return Settings.healthTrajectory end,
        function(v) Settings.healthTrajectory = v end,
        "Shows a marker predicting where health will be based on incoming damage rate.")

    local slTrajWindow = BuildSlider(p2, "TrajWin", 1, 5, 1,
        cbTrajectory, "BOTTOMLEFT", 20, -8,
        function() return Settings.trajectoryWindow end,
        function(v) Settings.trajectoryWindow = v end, "Window: %ds")

    --------------- Section: Tracking ---------------
    local secTrack = DrawSection(p2, "TRACKING", slTrajWindow, "BOTTOMLEFT", -20, -10)

    local cbResTracker = BuildCheck(p2, "Incoming res tracker",
        secTrack, "BOTTOMLEFT", 0, -6,
        function() return Settings.resTracker end,
        function(v) Settings.resTracker = v end,
        "Shows 'RES' text on dead raid members being resurrected by a party/raid member.")

    local slResX = BuildSlider(p2, "ResX", -50, 50, 1,
        cbResTracker, "BOTTOMLEFT", 20, -8,
        function() return Settings.resOffsetX or 0 end,
        function(v) Settings.resOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Res X: %d")

    local slResY = BuildSlider(p2, "ResY", -30, 30, 1,
        slResX, "BOTTOMLEFT", 0, -18,
        function() return Settings.resOffsetY or 0 end,
        function(v) Settings.resOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Res Y: %d")

    local cbCDTracker = BuildCheck(p2, "Raid cooldown tracker",
        slResY, "BOTTOMLEFT", -20, -2,
        function() return Settings.cdTracker end,
        function(v) Settings.cdTracker = v end,
        "Shows external cooldowns received on raid frame targets (Pain Suppression, BOP, Innervate, etc.).")

    local slCDX = BuildSlider(p2, "CDX", -50, 50, 1,
        cbCDTracker, "BOTTOMLEFT", 20, -8,
        function() return Settings.cdOffsetX or 0 end,
        function(v) Settings.cdOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "CD X: %d")

    local slCDY = BuildSlider(p2, "CDY", -30, 30, 1,
        slCDX, "BOTTOMLEFT", 0, -18,
        function() return Settings.cdOffsetY or 0 end,
        function(v) Settings.cdOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "CD Y: %d")

    --------------- Section: Text Overlays ---------------
    local secText = DrawSection(p2, "TEXT OVERLAYS", slCDY, "BOTTOMLEFT", -20, -10)

    local cbDeficit = BuildCheck(p2, "Predictive health deficit on raid frames",
        secText, "BOTTOMLEFT", 0, -6,
        function() return Settings.showHealthDeficit end,
        function(v) Settings.showHealthDeficit = v end)

    local slDeficitX = BuildSlider(p2, "DeficitX", -50, 50, 1,
        cbDeficit, "BOTTOMLEFT", 20, -8,
        function() return Settings.deficitOffsetX or 0 end,
        function(v) Settings.deficitOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Deficit X: %d")

    local slDeficitY = BuildSlider(p2, "DeficitY", -30, 30, 1,
        slDeficitX, "BOTTOMLEFT", 0, -18,
        function() return Settings.deficitOffsetY or 0 end,
        function(v) Settings.deficitOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Deficit Y: %d")

    local cbHealTxt = BuildCheck(p2, "Incoming heal text on unit frames",
        slDeficitY, "BOTTOMLEFT", -20, -2,
        function() return Settings.showHealText end,
        function(v) Settings.showHealText = v end)

    local slHealTextX = BuildSlider(p2, "HealTxtX", -50, 50, 1,
        cbHealTxt, "BOTTOMLEFT", 20, -8,
        function() return Settings.healTextOffsetX or 0 end,
        function(v) Settings.healTextOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "X: %d")

    local slHealTextY = BuildSlider(p2, "HealTxtY", -30, 30, 1,
        slHealTextX, "BOTTOMLEFT", 0, -18,
        function() return Settings.healTextOffsetY or 0 end,
        function(v) Settings.healTextOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Y: %d")

    --------------- Section: Low Mana Warning ---------------
    local secLowMana = DrawSection(p2, "LOW MANA WARNING", slHealTextY, "BOTTOMLEFT", -20, -10)

    local cbLowMana = BuildCheck(p2, "Low mana warning on raid frames (healers)",
        secLowMana, "BOTTOMLEFT", 0, -6,
        function() return Settings.lowManaWarning end,
        function(v) Settings.lowManaWarning = v end,
        "Shows mana percentage text on raid frames for healer classes (Priest, Paladin, Druid, Shaman) when below threshold.")

    local slLowManaThresh = BuildSlider(p2, "LowManaT", 10, 40, 5,
        cbLowMana, "BOTTOMLEFT", 20, -8,
        function() return Settings.lowManaThreshold end,
        function(v) Settings.lowManaThreshold = v end, "Mana threshold: %d%%")

    local slLowManaX = BuildSlider(p2, "LowManaX", -50, 50, 1,
        slLowManaThresh, "BOTTOMLEFT", 0, -18,
        function() return Settings.lowManaOffsetX end,
        function(v) Settings.lowManaOffsetX = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "X: %d")

    local slLowManaY = BuildSlider(p2, "LowManaY", -30, 30, 1,
        slLowManaX, "BOTTOMLEFT", 0, -18,
        function() return Settings.lowManaOffsetY end,
        function(v) Settings.lowManaOffsetY = v; if HP.ReanchorTexts then HP.ReanchorTexts() end end, "Y: %d")

    end -- BuildIndicatorsTab
    BuildIndicatorsTab(p2)

    --=======================================================================
    -- TAB 3: Mana & Alerts  (Player Mana, Snipe Detection, Sound Alerts)
    --=======================================================================
    local function BuildManaAlertsTab(p3)

    --------------- Section: Mana Cost ---------------
    local secManaCost = DrawSection(p3, "MANA COST", p3, "TOPLEFT", 0, 0)

    local cbManaCost = BuildCheck(p3, "Show mana cost on player mana bar",
        secManaCost, "BOTTOMLEFT", 0, -6,
        function() return Settings.showManaCost end,
        function(v) Settings.showManaCost = v end)

    local srManaCostColor = BuildSwatchRow(p3, "Mana Cost:",
        { "manaCostBar" },
        cbManaCost, "BOTTOMLEFT", 0, -4)

    --------------- Section: Mana Forecast ---------------
    local secMana = DrawSection(p3, "MANA FORECAST", srManaCostColor, "BOTTOMLEFT", 0, -10)

    local cbManaForecast = BuildCheck(p3, "Mana sustainability forecast",
        secMana, "BOTTOMLEFT", 0, -6,
        function() return Settings.manaForecast end,
        function(v)
            Settings.manaForecast = v
            if not v then HP.ResetManaHistory() end
        end,
        "Shows estimated time to OOM on the player frame while mana is draining.")

    local FORECAST_POS_LABELS = { "Above", "Center", "Below", "Right" }
    local btnForecastPos = CreateFrame("Button", "HP_BtnForecastPos", p3, "UIPanelButtonTemplate")
    btnForecastPos:SetSize(130, 20)
    btnForecastPos:SetPoint("TOPLEFT", cbManaForecast, "BOTTOMLEFT", 20, -4)
    btnForecastPos:SetText("Position: " .. (FORECAST_POS_LABELS[Settings.manaForecastPos] or "Above"))
    btnForecastPos:SetScript("OnClick", function(self)
        local pos = (Settings.manaForecastPos or 1) % #FORECAST_POS_LABELS + 1
        Settings.manaForecastPos = pos
        self:SetText("Position: " .. FORECAST_POS_LABELS[pos])
        if HP.UpdateManaForecastAnchor then HP.UpdateManaForecastAnchor() end
    end)
    btnForecastPos:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("OOM Text Position", 1, 1, 1)
        GameTooltip:AddLine("Click to cycle: Above, Center, Below, Right of mana bar.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnForecastPos:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnForecastPos, refresh = function()
        btnForecastPos:SetText("Position: " .. (FORECAST_POS_LABELS[Settings.manaForecastPos] or "Above"))
    end })

    --------------- Section: OOC Regen Timer ---------------
    local secOOC = DrawSection(p3, "OOC REGEN TIMER", btnForecastPos, "BOTTOMLEFT", -20, -10)

    local cbOOCRegen = BuildCheck(p3, "Out-of-combat regen timer",
        secOOC, "BOTTOMLEFT", 0, -6,
        function() return Settings.oocRegenTimer end,
        function(v) Settings.oocRegenTimer = v; if not v then HP.ResetOOCRegen() end end,
        "Shows estimated time to full mana when out of combat with low mana.")

    local OOC_POS_LABELS = { "Above", "Center", "Below", "Right" }
    local btnOOCPos = CreateFrame("Button", "HP_BtnOOCPos", p3, "UIPanelButtonTemplate")
    btnOOCPos:SetSize(130, 20)
    btnOOCPos:SetPoint("TOPLEFT", cbOOCRegen, "BOTTOMLEFT", 20, -4)
    btnOOCPos:SetText("Position: " .. (OOC_POS_LABELS[Settings.oocRegenTimerPos] or "Above"))
    btnOOCPos:SetScript("OnClick", function(self)
        local pos = (Settings.oocRegenTimerPos or 1) % #OOC_POS_LABELS + 1
        Settings.oocRegenTimerPos = pos
        self:SetText("Position: " .. OOC_POS_LABELS[pos])
        if HP.UpdateOOCRegenAnchor then HP.UpdateOOCRegenAnchor() end
    end)
    btnOOCPos:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Regen Timer Position", 1, 1, 1)
        GameTooltip:AddLine("Click to cycle: Above, Center, Below, Right of mana bar.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnOOCPos:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnOOCPos, refresh = function()
        btnOOCPos:SetText("Position: " .. (OOC_POS_LABELS[Settings.oocRegenTimerPos] or "Above"))
    end })

    --------------- Section: Snipe Detection ---------------
    local secSnipe = DrawSection(p3, "SNIPE DETECTION", btnOOCPos, "BOTTOMLEFT", -20, -10)

    local cbSnipe = BuildCheck(p3, "Heal snipe detection",
        secSnipe, "BOTTOMLEFT", 0, -6,
        function() return Settings.snipeDetection end,
        function(v) Settings.snipeDetection = v end,
        "Flashes the raid frame when your heal is largely wasted due to overhealing.")

    local slSnipeThresh = BuildSlider(p3, "SnipeT", 30, 80, 5,
        cbSnipe, "BOTTOMLEFT", 20, -8,
        function() return Settings.snipeThreshold * 100 end,
        function(v) Settings.snipeThreshold = v / 100 end, "Threshold: %d%%")

    --------------- Section: Healing Efficiency ---------------
    local secEfficiency = DrawSection(p3, "HEALING EFFICIENCY", slSnipeThresh, "BOTTOMLEFT", -20, -10)

    local cbEfficiency = BuildCheck(p3, "Track healing efficiency (/hp stats)",
        secEfficiency, "BOTTOMLEFT", 0, -6,
        function() return Settings.healingEfficiency end,
        function(v) Settings.healingEfficiency = v end,
        "Records per-spell effective healing vs overhealing. View with /hp stats, reset with /hp stats reset.")

    --------------- Section: Sound Alerts ---------------
    local secSounds = DrawSection(p3, "SOUND ALERTS", cbEfficiency, "BOTTOMLEFT", 0, -10)

    local alertSounds = HP.ALERT_SOUNDS or {}
    local function getSoundLabel(idx)
        local s = alertSounds[idx or 1]
        return s and s.label or "Raid Warning"
    end

    local cbSoundDispel = BuildCheck(p3, "Sound alert: dispel needed",
        secSounds, "BOTTOMLEFT", 0, -6,
        function() return Settings.soundDispel end,
        function(v) Settings.soundDispel = v end,
        "Plays a sound when a new dispellable debuff is detected. Debounced (max 1 per 5s).")

    local btnDispelSound = CreateFrame("Button", "HP_BtnDispelSound", p3, "UIPanelButtonTemplate")
    btnDispelSound:SetSize(120, 20)
    btnDispelSound:SetPoint("TOPLEFT", cbSoundDispel, "BOTTOMLEFT", 20, -4)
    btnDispelSound:SetText(getSoundLabel(Settings.dispelSoundChoice))
    btnDispelSound:SetScript("OnClick", function(self)
        local n = #alertSounds
        if n == 0 then return end
        local idx = ((Settings.dispelSoundChoice or 1) % n) + 1
        Settings.dispelSoundChoice = idx
        self:SetText(getSoundLabel(idx))
    end)
    btnDispelSound:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Dispel Alert Sound", 1, 1, 1)
        GameTooltip:AddLine("Click to cycle through available sounds.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnDispelSound:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnDispelSound, refresh = function()
        btnDispelSound:SetText(getSoundLabel(Settings.dispelSoundChoice))
    end })

    local btnDispelPreview = CreateFrame("Button", "HP_BtnDispelPrev", p3, "UIPanelButtonTemplate")
    btnDispelPreview:SetSize(20, 20)
    btnDispelPreview:SetPoint("LEFT", btnDispelSound, "RIGHT", 4, 0)
    btnDispelPreview:SetText("|cff44ff44>|r")
    btnDispelPreview:SetScript("OnClick", function()
        local entry = alertSounds[Settings.dispelSoundChoice or 1]
        if entry and entry.play then entry.play() end
    end)
    btnDispelPreview:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Preview", 1, 1, 1)
        GameTooltip:Show()
    end)
    btnDispelPreview:SetScript("OnLeave", GameTooltip_Hide)

    local cbSoundLowMana = BuildCheck(p3, "Sound alert: healer low mana",
        btnDispelSound, "BOTTOMLEFT", -20, -2,
        function() return Settings.soundLowMana end,
        function(v) Settings.soundLowMana = v end,
        "Plays a sound when a healer's mana drops below the low mana threshold. Debounced (max 1 per 5s).")

    local btnLowManaSound = CreateFrame("Button", "HP_BtnLowManaSound", p3, "UIPanelButtonTemplate")
    btnLowManaSound:SetSize(120, 20)
    btnLowManaSound:SetPoint("TOPLEFT", cbSoundLowMana, "BOTTOMLEFT", 20, -4)
    btnLowManaSound:SetText(getSoundLabel(Settings.lowManaSoundChoice))
    btnLowManaSound:SetScript("OnClick", function(self)
        local n = #alertSounds
        if n == 0 then return end
        local idx = ((Settings.lowManaSoundChoice or 1) % n) + 1
        Settings.lowManaSoundChoice = idx
        self:SetText(getSoundLabel(idx))
    end)
    btnLowManaSound:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Low Mana Alert Sound", 1, 1, 1)
        GameTooltip:AddLine("Click to cycle through available sounds.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btnLowManaSound:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = btnLowManaSound, refresh = function()
        btnLowManaSound:SetText(getSoundLabel(Settings.lowManaSoundChoice))
    end })

    local btnLowManaPreview = CreateFrame("Button", "HP_BtnLowManaPrev", p3, "UIPanelButtonTemplate")
    btnLowManaPreview:SetSize(20, 20)
    btnLowManaPreview:SetPoint("LEFT", btnLowManaSound, "RIGHT", 4, 0)
    btnLowManaPreview:SetText("|cff44ff44>|r")
    btnLowManaPreview:SetScript("OnClick", function()
        local entry = alertSounds[Settings.lowManaSoundChoice or 1]
        if entry and entry.play then entry.play() end
    end)
    btnLowManaPreview:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Preview", 1, 1, 1)
        GameTooltip:Show()
    end)
    btnLowManaPreview:SetScript("OnLeave", GameTooltip_Hide)

    end -- BuildManaAlertsTab
    BuildManaAlertsTab(p3)

    --=======================================================================
    -- TAB 4: General  (Performance, Profiles, Misc)
    --=======================================================================
    local function BuildGeneralTab(p4)

    --------------- Section: Performance ---------------
    local secPerf = DrawSection(p4, "PERFORMANCE", p4, "TOPLEFT", 0, 0)

    local cbFast = BuildCheck(p4, "Fast raid frame updates",
        secPerf, "BOTTOMLEFT", 0, -6,
        function() return Settings.fastRaidUpdate end,
        function(v)
            Settings.fastRaidUpdate = v
            if v then HP.StartFastUpdate() else HP.StopFastUpdate() end
        end,
        "Polls raid frames at a fixed rate for smoother bar updates. Uses more CPU. Without this, bars update only on health/heal events.")

    local slFastRate = BuildSlider(p4, "FastRate", 10, 60, 5,
        cbFast, "BOTTOMLEFT", 0, -8,
        function() return Settings.fastUpdateRate end,
        function(v)
            Settings.fastUpdateRate = v
            if Settings.fastRaidUpdate then
                HP.StopFastUpdate()
                HP.StartFastUpdate()
            end
        end, "Poll rate: %d FPS")

    local slScale = BuildSlider(p4, "PanelScale", 50, 150, 5,
        slFastRate, "BOTTOMLEFT", 0, -18,
        function() return Settings.panelScale * 100 end,
        function(v)
            Settings.panelScale = v / 100
        end, "Panel scale: %d%%")
    slScale:SetScript("OnMouseUp", function(self)
        local v = self:GetValue()
        Settings.panelScale = v / 100
        if optionsFrame then optionsFrame:SetScale(v / 100) end
    end)

    --------------- Section: Profile Auto-Switch ---------------
    local secAutoSwitch = DrawSection(p4, "PROFILE AUTO-SWITCH", slScale, "BOTTOMLEFT", 0, -18)

    local cbAutoSwitch = BuildCheck(p4, "Auto-switch profiles by group size",
        secAutoSwitch, "BOTTOMLEFT", 0, -6,
        function()
            local db = HP.db
            return db and db.autoSwitch or false
        end,
        function(v)
            if HP.db then HP.db.autoSwitch = v end
        end,
        "Automatically switch between profiles when you join/leave a group or raid.")

    local AUTOSWITCH_TYPES = { "solo", "party", "raid" }
    local AUTOSWITCH_LABELS = { "Solo:", "Party:", "Raid:" }
    local autoswitchBtns = {}
    local autoswitchLabels = {}

    for asIdx, asType in ipairs(AUTOSWITCH_TYPES) do
        local dbKey = asType .. "Profile"
        local lbl = p4:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if asIdx == 1 then
            lbl:SetPoint("TOPLEFT", cbAutoSwitch, "BOTTOMLEFT", 0, -6)
        else
            lbl:SetPoint("TOPLEFT", autoswitchLabels[asIdx - 1], "BOTTOMLEFT", 0, -8)
        end
        lbl:SetText(AUTOSWITCH_LABELS[asIdx])
        lbl:SetWidth(40)
        autoswitchLabels[asIdx] = lbl

        local btn = CreateFrame("Button", "HP_BtnAS_" .. asType, p4, "UIPanelButtonTemplate")
        btn:SetSize(130, 20)
        btn:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        local function getProfileName()
            return HP.db and HP.db[dbKey] or "Default"
        end
        btn:SetText(getProfileName())
        btn:SetScript("OnClick", function(self)
            local profiles = HP.GetProfileList()
            if #profiles == 0 then return end
            local current = getProfileName()
            local curIdx = 1
            for pi, name in ipairs(profiles) do
                if name == current then curIdx = pi; break end
            end
            local nextIdx = curIdx % #profiles + 1
            if HP.db then HP.db[dbKey] = profiles[nextIdx] end
            self:SetText(profiles[nextIdx])
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(AUTOSWITCH_LABELS[asIdx] .. " Profile", 1, 1, 1)
            GameTooltip:AddLine("Click to cycle through available profiles.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
        autoswitchBtns[asIdx] = btn
        tinsert(optWidgets.buttons, { btn = btn, refresh = function()
            btn:SetText(getProfileName())
        end })
    end

    --------------- Section: Misc ---------------
    local secMisc = DrawSection(p4, "MISC", autoswitchLabels[3], "BOTTOMLEFT", 0, -10)

    local cbMinimap = BuildCheck(p4, "Show minimap button",
        secMisc, "BOTTOMLEFT", 0, -6,
        function() return Settings.showMinimapButton end,
        function(v) Settings.showMinimapButton = v; HP.ToggleMinimapButton() end)

    end -- BuildGeneralTab
    BuildGeneralTab(p4)

    -- Apply saved scale on creation
    host:SetScale(Settings.panelScale)

    --------------- Scale grip (bottom-right corner drag) ---------------
    local grip = CreateFrame("Frame", nil, host)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:EnableMouse(true)
    grip:SetFrameLevel(host:GetFrameLevel() + 10)

    for i = 0, 2 do
        local ln = grip:CreateTexture(nil, "OVERLAY")
        ln:SetColorTexture(0.6, 0.6, 0.6, 0.7)
        ln:SetSize(2, 8 + i * 3)
        ln:SetPoint("BOTTOMRIGHT", -i * 5, 0)
    end

    local baseW, baseH, baseScale, startX, startY
    grip:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        baseW, baseH = host:GetSize()
        baseScale = host:GetScale()
        startX, startY = GetCursorPosition()
    end)
    grip:SetScript("OnMouseUp", function()
        baseW = nil
        Settings.panelScale = host:GetScale()
        HP.SaveSettings()
    end)
    grip:SetScript("OnUpdate", function()
        if not baseW then return end
        local cx, cy = GetCursorPosition()
        local dx = (cx - startX) / UIParent:GetEffectiveScale()
        local dy = (startY - cy) / UIParent:GetEffectiveScale()
        local delta = mathmax(dx, dy)
        local newScale = mathmax(0.5, mathmin(1.5, baseScale + delta / 400))
        host:SetScale(newScale)
    end)

    --------------- Bottom buttons ---------------
    local defBtn = CreateFrame("Button", "HP_BtnDefaults", host, "UIPanelButtonTemplate")
    defBtn:SetSize(90, 22)
    defBtn:SetPoint("BOTTOMLEFT", 12, 10)
    defBtn:SetText("Defaults")
    defBtn:SetScript("OnClick", function()
        HP.ResetDefaults(); HP.RefreshOptions(); HP.RefreshAll()
    end)

    local testBtn = CreateFrame("Button", "HP_BtnTest", host, "UIPanelButtonTemplate")
    testBtn:SetSize(90, 22)
    testBtn:SetPoint("BOTTOMRIGHT", -12, 10)
    testBtn:SetText("Test Mode")
    testBtn:SetScript("OnClick", function() SlashCmdList["HPTEST"]() end)

    -- Test Mode Layout selector
    local TEST_LAYOUT_LABELS = { "Solo (8)", "Dungeon (5)", "Raid (25)" }
    local layoutBtn = CreateFrame("Button", "HP_BtnTestLayout", host, "UIPanelButtonTemplate")
    layoutBtn:SetSize(110, 22)
    layoutBtn:SetPoint("BOTTOMRIGHT", testBtn, "BOTTOMLEFT", -8, 0)
    layoutBtn:SetText("Layout: " .. (TEST_LAYOUT_LABELS[Settings.testModeLayout] or "Solo"))
    layoutBtn:SetScript("OnClick", function(self)
        local layout = (Settings.testModeLayout or 1) % #TEST_LAYOUT_LABELS + 1
        Settings.testModeLayout = layout
        self:SetText("Layout: " .. TEST_LAYOUT_LABELS[layout])
        -- Restart test mode if active
        if HP._testMode then
            SlashCmdList["HPTEST"]()
            C_Timer.After(0.1, function() SlashCmdList["HPTEST"]() end)
        end
    end)
    layoutBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Test Mode Layout", 1, 1, 1)
        GameTooltip:AddLine("Solo: 8 individual test frames", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Dungeon: 5 frames like party frames", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Raid: 25 frames in raid grid", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    layoutBtn:SetScript("OnLeave", GameTooltip_Hide)
    tinsert(optWidgets.buttons, { btn = layoutBtn, refresh = function()
        layoutBtn:SetText("Layout: " .. (TEST_LAYOUT_LABELS[Settings.testModeLayout] or "Solo"))
    end })

    --------------- ElvUI Beta Warning ---------------
    if HP.DetectElvUI and HP.DetectElvUI() then
        local warningFrame = CreateFrame("Frame", nil, host)
        warningFrame:SetSize(400, 40)
        warningFrame:SetPoint("BOTTOM", 0, 35)
        
        -- Warning icon texture
        local warningIcon = warningFrame:CreateTexture(nil, "OVERLAY")
        warningIcon:SetSize(16, 16)
        warningIcon:SetPoint("CENTER", -105, 0)
        warningIcon:SetTexture("Interface\DialogFrame\UI-Dialog-Icon-AlertNew")
        
        local warningText = warningFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        warningText:SetPoint("CENTER", 20, 0)
        warningText:SetText("|cffffcc00ElvUI Compatibility: BETA|r")
        
        local subText = warningFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        subText:SetPoint("TOP", warningText, "BOTTOM", 0, -2)
        subText:SetText("If you encounter bugs, please report them and switch to Blizzard frames for now.")
        subText:SetTextColor(1, 0.8, 0.4)
        
        -- Add tooltip with more info
        warningFrame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("ElvUI Beta Compatibility", 1, 0.82, 0)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("HealPredict's ElvUI support is currently in beta testing.", 1, 1, 1, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Known limitations:", 0.8, 0.8, 0.8)
            GameTooltip:AddLine("- Some custom textures may not align perfectly", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("- Vertical orientation bars are experimental", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("If you experience issues:", 0.8, 0.8, 0.8)
            GameTooltip:AddLine("1. Report the bug to the addon author", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("2. Temporarily switch to Blizzard default UI", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("3. Use /hpcompat elvui to debug", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        warningFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    return host
end

function HP.RefreshOptions()
    if not optionsFrame then return end
    for _, w in ipairs(optWidgets.checks) do
        w.cb:SetChecked(w.get())
    end
    for _, w in ipairs(optWidgets.sliders) do
        local v = w.get()
        w.sl:SetValue(v)
        if w.fmtFn then
            w.sl.Text:SetText(w.fmtFn(v))
        else
            w.sl.Text:SetText(fmt(w.pattern, v))
        end
    end
    for _, sw in ipairs(optWidgets.swatches) do
        local c = Settings.colors[sw._colorKey]
        if c then sw:GetNormalTexture():SetVertexColor(c[1], c[2], c[3], c[4]) end
    end
    for _, w in ipairs(optWidgets.buttons) do
        w.refresh()
    end
    -- Refresh profile dropdown text
    if HP._profileText then
        HP._profileText:SetText(HP.activeProfile or "Default")
    end
    if HP._profileMenu and HP._profileMenu:IsShown() then
        HP._profileMenu:Hide()
    end
end

-- Store reference to optionsFrame for Init.lua
function HP.GetOptionsFrame()
    return optionsFrame
end
