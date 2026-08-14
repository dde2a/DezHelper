local ADDON_NAME = ...

local Dez = CreateFrame("Frame")
local rows = {}
local candidates = {}
local visibleItems = {}
local selected = {}
local currentKey
local refreshPending
local pendingAttempt
local attemptSequence = 0
local History
local historyRows = {}
local HISTORY_LIMIT = 50
local UpdateHistory

local locale = GetLocale()
local translations = {
    en = {
        uncommon = "Uncommon",
        rare = "Rare",
        epic = "Epic",
        loaded = "Loaded. Type |cffffffff/dez|r to open the window.",
        unavailableCombat = "Unavailable in combat",
        disenchant = "Disenchant next item",
        selectItem = "Select at least one item",
        loading = "Loading…",
        displayed = "%d shown • %d selected",
        subtitle = "Select the items you want to disenchant.",
        size = "Size",
        quality = "Quality:",
        selectAll = "Select all",
        itemDetails = "%s  •  ilvl %d",
        itemDetailsUpgrade = "%s  •  ilvl %d  •  %s %d/%d",
        upgrade = "Upgrade",
        blocked = "%s cannot be disenchanted and was removed from the list.",
        blockedReset = "The learned exclusion list has been cleared.",
        history = "History",
        historyTitle = "Disenchant history",
        historyEmpty = "No successful disenchant recorded yet.",
        historyDetails = "%s  •  ilvl %d",
        clearHistory = "Clear",
        clearHistoryConfirm = "Clear the entire disenchant history?",
    },
    fr = {
        uncommon = "Inhabituel",
        rare = "Rare",
        epic = "Épique",
        loaded = "Chargé. Tapez |cffffffff/dez|r pour ouvrir la fenêtre.",
        unavailableCombat = "Indisponible en combat",
        disenchant = "Désenchanter le prochain objet",
        selectItem = "Sélectionnez au moins un objet",
        loading = "Chargement…",
        displayed = "%d affiché(s) • %d sélectionné(s)",
        subtitle = "Sélectionnez les objets à désenchanter.",
        size = "Taille",
        quality = "Qualité :",
        selectAll = "Tout sélectionner",
        itemDetails = "%s  •  ilvl %d",
        itemDetailsUpgrade = "%s  •  ilvl %d  •  %s %d/%d",
        upgrade = "Amélioration",
        blocked = "%s ne peut pas être désenchanté et a été retiré de la liste.",
        blockedReset = "La liste des exclusions apprises a été réinitialisée.",
        history = "Historique",
        historyTitle = "Historique des désenchantements",
        historyEmpty = "Aucun désenchantement réussi enregistré.",
        historyDetails = "%s  •  ilvl %d",
        clearHistory = "Vider",
        clearHistoryConfirm = "Vider tout l’historique des désenchantements ?",
    },
}
local L = locale == "frFR" and translations.fr or translations.en

local QUALITY_COLORS = {
    [2] = "ff1eff00",
    [3] = "ff0070dd",
    [4] = "ffa335ee",
}

local QUALITY_LABELS = {
    [2] = L.uncommon,
    [3] = L.rare,
    [4] = L.epic,
}

-- Some special progression items are equipment but are explicitly flagged by
-- Blizzard as non-disenchantable. Keep verified exceptions as a final safety
-- net when their tooltip data is not available yet.
local KNOWN_NON_DISENCHANTABLE = {
    [117364] = true, -- Seal of Ghoulish Glee
    [228411] = true, -- Cyrce's Circlet
    [264507] = true, -- Crucible of Erratic Energies
}

local defaults = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    quality = {
        [2] = true,
        [3] = true,
        [4] = false,
    },
    scale = 0.85,
    blockedItems = {},
    history = {},
}

local function CopyDefaults(source, destination)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(destination[key]) ~= "table" then
                destination[key] = {}
            end
            CopyDefaults(value, destination[key])
        elseif destination[key] == nil then
            destination[key] = value
        end
    end
end

local function ItemKey(bag, slot)
    return bag .. ":" .. slot
end

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9b59b6DezHelper|r : " .. message)
end

local function IsCandidate(link, quality, classID, equipLoc)
    if not link or not quality then
        return false
    end

    -- WoW ne fournit pas de prédicat public universel "peut être désenchanté".
    -- Les armes et armures inhabituelles à épiques constituent le filtre sûr
    -- le plus proche; le serveur garde toujours la décision finale.
    local isEquipment = classID == 2 or classID == 4
    local hasEquipSlot = equipLoc and equipLoc ~= ""
    return isEquipment and hasEquipSlot and quality >= 2 and quality <= 4
end

local function GetItemLevel(link)
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        return C_Item.GetDetailedItemLevelInfo(link) or 0
    end
    return 0
end

local function GetItemUpgrade(link)
    if not C_Item or not C_Item.GetItemUpgradeInfo then
        return nil
    end

    local info = C_Item.GetItemUpgradeInfo(link)
    if not info or not info.currentLevel or not info.maxLevel or info.maxLevel <= 0 then
        return nil
    end

    return {
        currentLevel = info.currentLevel,
        maxLevel = info.maxLevel,
        track = info.trackString or L.upgrade,
    }
end

local function IsRefundable(bag, slot)
    if not C_Item or not C_Item.CanBeRefunded or not ItemLocation then
        return false
    end

    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    return location and location:IsValid() and C_Item.CanBeRefunded(location) or false
end

local function IsBlocked(itemID)
    return itemID and DezHelperDB.blockedItems[tostring(itemID)] == true
end

local function HasCannotDisenchantLine(bag, slot, itemID)
    if itemID and KNOWN_NON_DISENCHANTABLE[itemID] then
        return true
    end
    if not C_TooltipInfo or not C_TooltipInfo.GetBagItem then
        return false
    end

    local success, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
    if not success or not data or not data.lines then
        return false
    end

    local errorLineType = Enum and Enum.TooltipDataLineType
        and Enum.TooltipDataLineType.ErrorLine or 41
    for _, line in ipairs(data.lines) do
        local text = line.leftText
        if text then
            if (ITEM_DISENCHANT_NOT_DISENCHANTABLE and text == ITEM_DISENCHANT_NOT_DISENCHANTABLE)
                or (ERR_CANT_BE_DISENCHANTED and text == ERR_CANT_BE_DISENCHANTED)
                or (SPELL_FAILED_CANT_BE_DISENCHANTED and text == SPELL_FAILED_CANT_BE_DISENCHANTED) then
                return true
            end

            if line.type == errorLineType then
                local lowerText = text:lower()
                if lowerText:find("disenchant", 1, true)
                    or lowerText:find("désenchant", 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

local function IsDisenchantFailure(messageType, message)
    return (LE_GAME_ERR_CANT_BE_DISENCHANTED and messageType == LE_GAME_ERR_CANT_BE_DISENCHANTED)
        or (ERR_CANT_BE_DISENCHANTED and message == ERR_CANT_BE_DISENCHANTED)
        or (SPELL_FAILED_CANT_BE_DISENCHANTED and message == SPELL_FAILED_CANT_BE_DISENCHANTED)
        or (ITEM_DISENCHANT_NOT_DISENCHANTABLE and message == ITEM_DISENCHANT_NOT_DISENCHANTABLE)
        or (SPELL_FAILED_BAD_TARGETS and message == SPELL_FAILED_BAD_TARGETS)
end

local function GetBagItemGUID(bag, slot)
    if not C_Item or not C_Item.GetItemGUID or not ItemLocation then
        return nil
    end

    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    if not location or not location:IsValid() then
        return nil
    end
    return C_Item.GetItemGUID(location)
end

local function AddHistoryEntry(item)
    local history = DezHelperDB.history
    table.insert(history, 1, {
        timestamp = time(),
        itemID = item.itemID,
        link = item.link,
        name = item.name,
        icon = item.icon,
        quality = item.quality,
        level = item.level,
        character = UnitName("player"),
        realm = GetRealmName(),
    })

    while #history > HISTORY_LIMIT do
        table.remove(history)
    end

    if UpdateHistory then
        UpdateHistory()
    end
end

local function ConfirmPendingAttempt()
    if not pendingAttempt then
        return
    end

    local currentGUID = GetBagItemGUID(pendingAttempt.bag, pendingAttempt.slot)
    local containerInfo = C_Container.GetContainerItemInfo(pendingAttempt.bag, pendingAttempt.slot)
    local itemChanged
    if pendingAttempt.guid then
        itemChanged = currentGUID ~= pendingAttempt.guid
    else
        itemChanged = not containerInfo
            or containerInfo.itemID ~= pendingAttempt.itemID
            or containerInfo.hyperlink ~= pendingAttempt.link
    end

    pendingAttempt.itemChanged = pendingAttempt.itemChanged or itemChanged
    if pendingAttempt.itemChanged and pendingAttempt.castSucceeded then
        AddHistoryEntry(pendingAttempt)
        pendingAttempt = nil
    end
end

local function ScanBags()
    wipe(candidates)

    for bag = 0, 5 do
        local slots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, slots do
            local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
            if containerInfo and containerInfo.hyperlink and not containerInfo.isLocked then
                local name, link, quality, _, _, _, _, _, equipLoc, icon, _, classID, _, _, expansionID =
                    C_Item.GetItemInfo(containerInfo.hyperlink)

                if IsCandidate(link, quality, classID, equipLoc)
                    and not IsRefundable(bag, slot)
                    and not HasCannotDisenchantLine(bag, slot, containerInfo.itemID)
                    and not IsBlocked(containerInfo.itemID) then
                    local key = ItemKey(bag, slot)
                    candidates[#candidates + 1] = {
                        key = key,
                        bag = bag,
                        slot = slot,
                        itemID = containerInfo.itemID,
                        guid = GetBagItemGUID(bag, slot),
                        name = name or L.loading,
                        link = link,
                        quality = quality,
                        level = GetItemLevel(link),
                        upgrade = GetItemUpgrade(link),
                        icon = icon or containerInfo.iconFileID,
                        count = containerInfo.stackCount or 1,
                        expansionID = expansionID or 0,
                    }
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.quality ~= b.quality then
            return a.quality < b.quality
        end
        if a.level ~= b.level then
            return a.level < b.level
        end
        return a.name < b.name
    end)
end

local function MatchesFilters(item)
    if not DezHelperDB.quality[item.quality] then
        return false
    end
    return true
end

local function FindCandidate(key)
    for _, item in ipairs(candidates) do
        if item.key == key then
            return item
        end
    end
end

local function CountSelected()
    local count = 0
    for key in pairs(selected) do
        if FindCandidate(key) then
            count = count + 1
        else
            selected[key] = nil
        end
    end
    return count
end

local function PickNext()
    if InCombatLockdown() then
        Dez.actionButton:Disable()
        Dez.actionButton:SetText(L.unavailableCombat)
        currentKey = nil
        return
    end

    local nextItem
    for _, item in ipairs(candidates) do
        if selected[item.key] then
            nextItem = item
            break
        end
    end

    currentKey = nextItem and nextItem.key or nil
    local disenchantName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(13262)
        or (locale == "frFR" and "Désenchantement" or "Disenchant")
    Dez.actionButton:SetAttribute("type", "macro")
    Dez.actionButton:SetAttribute("macrotext", nextItem and
        ("/cast " .. disenchantName .. "\n/use " .. nextItem.bag .. " " .. nextItem.slot) or "")

    if nextItem then
        Dez.actionButton:Enable()
        Dez.actionButton:SetText(L.disenchant)
        Dez.actionButton.icon:SetTexture(nextItem.icon)
        Dez.actionButton.icon:Show()
    else
        Dez.actionButton:Disable()
        Dez.actionButton:SetText(L.selectItem)
        Dez.actionButton.icon:Hide()
    end
end

local function RefreshRows()
    wipe(visibleItems)
    for _, item in ipairs(candidates) do
        if MatchesFilters(item) then
            visibleItems[#visibleItems + 1] = item
        end
    end

    local maxOffset = math.max(0, #visibleItems - #rows)
    Dez.scrollBar:SetMinMaxValues(0, maxOffset)
    if Dez.scrollBar:GetValue() > maxOffset then
        Dez.scrollBar:SetValue(maxOffset)
    end

    local offset = math.floor(Dez.scrollBar:GetValue() + 0.5)
    for index, row in ipairs(rows) do
        local item = visibleItems[offset + index]
        row.item = item
        if item then
            row:Show()
            row.icon:SetTexture(item.icon)
            row.check:SetChecked(selected[item.key] == true)
            row.name:SetText("|c" .. (QUALITY_COLORS[item.quality] or "ffffffff") .. item.name .. "|r")
            if item.upgrade then
                row.details:SetText(string.format(L.itemDetailsUpgrade,
                    QUALITY_LABELS[item.quality] or "Item",
                    item.level,
                    item.upgrade.track,
                    item.upgrade.currentLevel,
                    item.upgrade.maxLevel))
            else
                row.details:SetText(string.format(L.itemDetails,
                    QUALITY_LABELS[item.quality] or "Item", item.level))
            end
        else
            row:Hide()
        end
    end

    local selectedCount = CountSelected()
    Dez.counter:SetText(string.format(L.displayed, #visibleItems, selectedCount))
    if Dez.selectAllCheck then
        local allSelected = #visibleItems > 0
        for _, item in ipairs(visibleItems) do
            if not selected[item.key] then
                allSelected = false
                break
            end
        end
        Dez.selectAllCheck:SetChecked(allSelected)
    end
    PickNext()
end

local function FullRefresh()
    ScanBags()
    RefreshRows()
end

local function ScheduleRefresh()
    if refreshPending then
        return
    end
    refreshPending = true
    C_Timer.After(0.15, function()
        refreshPending = false
        FullRefresh()
    end)
end

local function MakeButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetText(text)
    return button
end

local function MakeCheck(parent, label)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check.text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    check.text:SetPoint("LEFT", check, "RIGHT", 2, 0)
    check.text:SetText(label)
    check.text:SetTextColor(0.9, 0.9, 0.9, 1)
    return check
end

UpdateHistory = function()
    if not History then
        return
    end

    local history = DezHelperDB.history
    local maxOffset = math.max(0, #history - #historyRows)
    History.scrollBar:SetMinMaxValues(0, maxOffset)
    if History.scrollBar:GetValue() > maxOffset then
        History.scrollBar:SetValue(maxOffset)
    end

    local offset = math.floor(History.scrollBar:GetValue() + 0.5)
    for index, row in ipairs(historyRows) do
        local entry = history[offset + index]
        row.entry = entry
        if entry then
            row:Show()
            row.icon:SetTexture(entry.icon)
            row.name:SetText("|c" .. (QUALITY_COLORS[entry.quality] or "ffffffff")
                .. (entry.name or L.loading) .. "|r")
            local timestamp = entry.timestamp and date("%Y-%m-%d %H:%M", entry.timestamp) or "?"
            row.details:SetText(string.format(L.historyDetails, timestamp, entry.level or 0))
        else
            row:Hide()
        end
    end

    History.empty:SetShown(#history == 0)
    History.count:SetText(tostring(#history) .. "/" .. HISTORY_LIMIT)
end

local function CreateHistoryInterface()
    History = CreateFrame("Frame", "DezHelperHistoryFrame", UIParent, "BackdropTemplate")
    History:SetSize(400, 320)
    History:SetScale(DezHelperDB.scale)
    History:SetPoint("LEFT", Dez, "RIGHT", 8, 0)
    History:SetFrameStrata("DIALOG")
    History:SetClampedToScreen(true)
    History:SetMovable(true)
    History:EnableMouse(true)
    History:RegisterForDrag("LeftButton")
    History:SetScript("OnDragStart", History.StartMoving)
    History:SetScript("OnDragStop", History.StopMovingOrSizing)
    History:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 16,
    })
    History:SetBackdropColor(0.035, 0.025, 0.055, 0.98)
    History:SetBackdropBorderColor(0.55, 0.28, 0.8, 1)

    local title = History:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 20, -18)
    title:SetText("|cffc084fc" .. L.historyTitle .. "|r")

    History.count = History:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    History.count:SetPoint("TOPRIGHT", -44, -23)

    local close = CreateFrame("Button", nil, History, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local listBackground = History:CreateTexture(nil, "BORDER")
    listBackground:SetPoint("TOPLEFT", 14, -48)
    listBackground:SetPoint("BOTTOMRIGHT", -14, 48)
    listBackground:SetColorTexture(0.07, 0.055, 0.09, 0.9)

    History.empty = History:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    History.empty:SetPoint("CENTER", listBackground, "CENTER", 0, 0)
    History.empty:SetText(L.historyEmpty)

    for index = 1, 8 do
        local row = CreateFrame("Button", nil, History)
        row:SetHeight(28)
        row:SetPoint("LEFT", listBackground, "LEFT", 8, 0)
        row:SetPoint("RIGHT", listBackground, "RIGHT", -22, 0)
        if index == 1 then
            row:SetPoint("TOP", listBackground, "TOP", 0, -6)
        else
            row:SetPoint("TOP", historyRows[index - 1], "BOTTOM", 0, 0)
        end

        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(0.35, 0.18, 0.5, 0.3)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 1, 0)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 7, -1)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetJustifyH("LEFT")

        row.details = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.details:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 7, 1)
        row.details:SetJustifyH("LEFT")

        row:SetScript("OnEnter", function()
            if row.entry and row.entry.link then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(row.entry.link)
            end
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        historyRows[index] = row
    end

    History.scrollBar = CreateFrame("Slider", nil, History, "UIPanelScrollBarTemplate")
    History.scrollBar:SetPoint("TOPRIGHT", listBackground, "TOPRIGHT", -3, -16)
    History.scrollBar:SetPoint("BOTTOMRIGHT", listBackground, "BOTTOMRIGHT", -3, 16)
    History.scrollBar:SetValueStep(1)
    History.scrollBar:SetObeyStepOnDrag(true)
    History.scrollBar:SetScript("OnValueChanged", UpdateHistory)

    History:EnableMouseWheel(true)
    History:SetScript("OnMouseWheel", function(_, delta)
        History.scrollBar:SetValue(History.scrollBar:GetValue() - delta)
    end)

    StaticPopupDialogs.DEZHELPER_CLEAR_HISTORY = {
        text = L.clearHistoryConfirm,
        button1 = YES,
        button2 = NO,
        OnAccept = function()
            wipe(DezHelperDB.history)
            UpdateHistory()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    local clear = MakeButton(History, L.clearHistory, 90, 24)
    clear:SetPoint("BOTTOM", 0, 14)
    clear:SetScript("OnClick", function()
        StaticPopup_Show("DEZHELPER_CLEAR_HISTORY")
    end)

    History:Hide()
    UpdateHistory()
end

local function CreateInterface()
    Dez:SetSize(430, 390)
    Dez:SetScale(DezHelperDB.scale)
    Dez:SetPoint(DezHelperDB.point, UIParent, DezHelperDB.relativePoint, DezHelperDB.x, DezHelperDB.y)
    Dez:SetFrameStrata("DIALOG")
    Dez:SetClampedToScreen(true)
    Dez:SetMovable(true)
    Dez:EnableMouse(true)
    Dez:RegisterForDrag("LeftButton")
    Dez:SetScript("OnDragStart", Dez.StartMoving)
    Dez:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        DezHelperDB.point = point
        DezHelperDB.relativePoint = relativePoint
        DezHelperDB.x = x
        DezHelperDB.y = y
    end)
    Dez.background = Dez:CreateTexture(nil, "BACKGROUND")
    Dez.background:SetAllPoints()
    Dez.background:SetColorTexture(0.035, 0.025, 0.055, 0.97)

    Dez.border = CreateFrame("Frame", nil, Dez, "BackdropTemplate")
    Dez.border:SetAllPoints()
    Dez.border:SetBackdrop({
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 16,
    })
    Dez.border:SetBackdropBorderColor(0.55, 0.28, 0.8, 1)

    local title = Dez:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 24, -20)
    title:SetText("|cffc084fcDezHelper|r")

    local subtitle = Dez:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    subtitle:SetText(L.subtitle)

    local close = CreateFrame("Button", nil, Dez, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -7, -7)

    local version = C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
    local versionText = Dez:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionText:SetPoint("BOTTOMRIGHT", -9, 5)
    versionText:SetScale(0.75)
    versionText:SetText("v" .. version)
    versionText:SetTextColor(0.42, 0.42, 0.42, 0.8)

    local scaleLabel = Dez:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    scaleLabel:SetPoint("TOPRIGHT", -64, -24)
    scaleLabel:SetText(L.size)

    Dez.scaleSlider = CreateFrame("Slider", nil, Dez, "OptionsSliderTemplate")
    Dez.scaleSlider:SetSize(90, 14)
    Dez.scaleSlider:SetPoint("TOPRIGHT", -54, -43)
    Dez.scaleSlider:SetMinMaxValues(0.65, 1.20)
    Dez.scaleSlider:SetValueStep(0.05)
    Dez.scaleSlider:SetObeyStepOnDrag(true)
    Dez.scaleSlider:SetValue(DezHelperDB.scale)
    Dez.scaleSlider.Low:SetText("−")
    Dez.scaleSlider.High:SetText("+")
    Dez.scaleSlider.Text:SetText("")
    Dez.scaleSlider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value * 20 + 0.5) / 20
        DezHelperDB.scale = value
        scaleLabel:SetText(string.format("%s %d%%", L.size, value * 100))
    end)
    Dez.scaleSlider:SetScript("OnMouseUp", function()
        -- Redimensionner le parent pendant le glissement déplace aussi le
        -- curseur sous la souris et provoque une oscillation. On applique
        -- donc l'échelle uniquement lorsque le bouton est relâché.
        Dez:SetScale(DezHelperDB.scale)
        History:SetScale(DezHelperDB.scale)
    end)

    local filterLabel = Dez:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("TOPLEFT", 24, -76)
    filterLabel:SetText(L.quality)
    filterLabel:SetTextColor(0.72, 0.72, 0.72, 1)

    local previous
    for quality = 2, 4 do
        local qualityID = quality
        local check = MakeCheck(Dez, QUALITY_LABELS[qualityID])
        check:SetSize(24, 24)
        if previous then
            check:SetPoint("LEFT", previous.text, "RIGHT", 10, 0)
        else
            check:SetPoint("LEFT", filterLabel, "RIGHT", 8, 0)
        end
        check:SetChecked(DezHelperDB.quality[qualityID])
        check:SetScript("OnClick", function(self)
            DezHelperDB.quality[qualityID] = self:GetChecked() == true
            RefreshRows()
        end)
        previous = check
    end

    Dez.counter = Dez:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Dez.counter:SetPoint("TOPRIGHT", -28, -110)
    Dez.counter:SetTextColor(0.9, 0.9, 0.9, 1)

    Dez.selectAllCheck = MakeCheck(Dez, L.selectAll)
    Dez.selectAllCheck:SetSize(24, 24)
    Dez.selectAllCheck:SetPoint("TOPLEFT", 22, -99)
    Dez.selectAllCheck:SetScript("OnClick", function(self)
        local shouldSelect = self:GetChecked() == true
        for _, item in ipairs(visibleItems) do
            selected[item.key] = shouldSelect or nil
        end
        RefreshRows()
    end)

    local listBackground = Dez:CreateTexture(nil, "BORDER")
    listBackground:SetPoint("TOPLEFT", 18, -124)
    listBackground:SetPoint("BOTTOMRIGHT", -18, 70)
    listBackground:SetColorTexture(0.07, 0.055, 0.09, 0.9)

    for index = 1, 5 do
        local row = CreateFrame("Button", nil, Dez)
        row:SetHeight(36)
        row:SetPoint("LEFT", 24, 0)
        row:SetPoint("RIGHT", -36, 0)
        if index == 1 then
            row:SetPoint("TOP", listBackground, "TOP", 0, -8)
        else
            row:SetPoint("TOP", rows[index - 1], "BOTTOM", 0, -2)
        end

        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(0.35, 0.18, 0.5, 0.3)

        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(26, 26)
        row.check:SetPoint("LEFT", 2, 0)
        row.check:SetScript("OnClick", function(self)
            if row.item then
                selected[row.item.key] = self:GetChecked() == true or nil
                RefreshRows()
            end
        end)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(30, 30)
        row.icon:SetPoint("LEFT", row.check, "RIGHT", 5, 0)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 9, -2)
        row.name:SetPoint("RIGHT", -8, 0)
        row.name:SetJustifyH("LEFT")

        row.details = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.details:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 9, 2)
        row.details:SetJustifyH("LEFT")

        row:SetScript("OnClick", function()
            if row.item then
                selected[row.item.key] = not selected[row.item.key] or nil
                RefreshRows()
            end
        end)
        row:SetScript("OnEnter", function()
            if row.item then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:SetBagItem(row.item.bag, row.item.slot)
            end
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        rows[index] = row
    end

    Dez.scrollBar = CreateFrame("Slider", nil, Dez, "UIPanelScrollBarTemplate")
    Dez.scrollBar:SetPoint("TOPRIGHT", listBackground, "TOPRIGHT", -3, -18)
    Dez.scrollBar:SetPoint("BOTTOMRIGHT", listBackground, "BOTTOMRIGHT", -3, 18)
    Dez.scrollBar:SetValueStep(1)
    Dez.scrollBar:SetObeyStepOnDrag(true)
    Dez.scrollBar:SetScript("OnValueChanged", RefreshRows)

    Dez:EnableMouseWheel(true)
    Dez:SetScript("OnMouseWheel", function(_, delta)
        Dez.scrollBar:SetValue(Dez.scrollBar:GetValue() - delta)
    end)

    Dez.actionButton = CreateFrame("Button", "DezHelperActionButton", Dez, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    Dez.actionButton:SetSize(380, 38)
    Dez.actionButton:SetPoint("BOTTOM", 0, 20)
    Dez.actionButton:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
    Dez.actionButton:SetNormalFontObject("GameFontHighlight")
    Dez.actionButton:SetHighlightFontObject("GameFontHighlight")
    Dez.actionButton:SetDisabledFontObject("GameFontDisable")
    Dez.actionButton.icon = Dez.actionButton:CreateTexture(nil, "ARTWORK")
    Dez.actionButton.icon:SetSize(24, 24)
    Dez.actionButton.icon:SetPoint("LEFT", 12, 0)
    Dez.actionButton.icon:Hide()
    Dez.actionButton:SetScript("PostClick", function()
        local item = currentKey and FindCandidate(currentKey)
        if item then
            attemptSequence = attemptSequence + 1
            pendingAttempt = {
                sequence = attemptSequence,
                guid = item.guid,
                bag = item.bag,
                slot = item.slot,
                itemID = item.itemID,
                link = item.link,
                name = item.name,
                icon = item.icon,
                quality = item.quality,
                level = item.level,
            }
            local sequence = attemptSequence
            C_Timer.After(10, function()
                if pendingAttempt and pendingAttempt.sequence == sequence then
                    pendingAttempt = nil
                end
            end)
        end
        ScheduleRefresh()
    end)

    local historyButton = MakeButton(Dez, L.history, 86, 20)
    historyButton:SetPoint("TOP", 0, -99)
    historyButton:SetScript("OnClick", function()
        if History:IsShown() then
            History:Hide()
        else
            UpdateHistory()
            History:Show()
        end
    end)

    Dez:Hide()
    CreateHistoryInterface()
end

SLASH_DEZHELPER1 = "/dez"
SLASH_DEZHELPER2 = "/dezhelper"
SlashCmdList.DEZHELPER = function(message)
    if message and message:lower():match("^%s*history%s*$") then
        if History:IsShown() then
            History:Hide()
        else
            UpdateHistory()
            History:Show()
        end
        return
    end

    if message and message:lower():match("^%s*reset%s*$") then
        wipe(DezHelperDB.blockedItems)
        Print(L.blockedReset)
        if Dez:IsShown() then
            FullRefresh()
        end
        return
    end

    if Dez:IsShown() then
        Dez:Hide()
    else
        Dez:Show()
        FullRefresh()
    end
end

Dez:RegisterEvent("ADDON_LOADED")
Dez:RegisterEvent("BAG_UPDATE_DELAYED")
Dez:RegisterEvent("GET_ITEM_INFO_RECEIVED")
Dez:RegisterEvent("UI_ERROR_MESSAGE")
Dez:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
Dez:RegisterEvent("PLAYER_REGEN_DISABLED")
Dez:RegisterEvent("PLAYER_REGEN_ENABLED")
Dez:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= ADDON_NAME then
            return
        end
        DezHelperDB = DezHelperDB or {}
        CopyDefaults(defaults, DezHelperDB)
        CreateInterface()
        Print(L.loaded)
    elseif event == "BAG_UPDATE_DELAYED" then
        ConfirmPendingAttempt()
        if self:IsShown() then
            ScheduleRefresh()
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if self:IsShown() then
            ScheduleRefresh()
        end
    elseif event == "UI_ERROR_MESSAGE" then
        local messageType, message = ...
        if IsDisenchantFailure(messageType, message) and currentKey then
            pendingAttempt = nil
            local item = FindCandidate(currentKey)
            if item and item.itemID then
                DezHelperDB.blockedItems[tostring(item.itemID)] = true
                selected[currentKey] = nil
                currentKey = nil
                Print(string.format(L.blocked, item.name))
                FullRefresh()
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and spellID == 13262 and pendingAttempt then
            pendingAttempt.castSucceeded = true
            ConfirmPendingAttempt()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if self:IsShown() then
            PickNext()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if self:IsShown() then
            FullRefresh()
        end
    end
end)
