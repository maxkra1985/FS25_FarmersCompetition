--[[
    FS25 FarmersCompetition - Boost HUD
    Общий вывод активных командных бустов под таблицей прогресса.

    Квесты/системы наград регистрируются как providers и возвращают строки через:
        provider:getHudBoostRows()

    Формат строки:
        {
            farmId = 1,
            id = "speed",
            text = "СКОРОСТЬ ×3.0  РАБОТА ×2.0",
            remainingMs = 600000,
            sortOrder = 10
        }
]]

CompetitionBoostHUD = {}
CompetitionBoostHUD.VERSION = "0.1.0"

CompetitionBoostHUD.providers = {}

-- Отступ от нижней границы таблицы прогресса.
CompetitionBoostHUD.DETAILED_TOP_GAP = 0.017
CompetitionBoostHUD.COLLAPSED_TOP_GAP = 0.015
CompetitionBoostHUD.ROW_STEP = 0.017
CompetitionBoostHUD.TEXT_SIZE = 0.0094
CompetitionBoostHUD.COLUMN_GAP = 0.007

-- Назначение: регистрирует источник строк активных бустов.
function CompetitionBoostHUD.registerProvider(provider)
    if provider == nil then
        return
    end

    for _, current in ipairs(CompetitionBoostHUD.providers) do
        if current == provider then
            return
        end
    end

    table.insert(CompetitionBoostHUD.providers, provider)
end

-- Назначение: удаляет источник строк активных бустов.
function CompetitionBoostHUD.unregisterProvider(provider)
    if provider == nil then
        return
    end

    for index = #CompetitionBoostHUD.providers, 1, -1 do
        if CompetitionBoostHUD.providers[index] == provider then
            table.remove(CompetitionBoostHUD.providers, index)
        end
    end
end

-- Назначение: собирает только реально активные строки от всех зарегистрированных систем.
function CompetitionBoostHUD.collectRows()
    local rows = {}

    for _, provider in ipairs(CompetitionBoostHUD.providers) do
        if provider ~= nil and provider.getHudBoostRows ~= nil then
            local ok, providerRows = pcall(provider.getHudBoostRows, provider)

            if ok and providerRows ~= nil then
                for _, row in ipairs(providerRows) do
                    if row ~= nil
                        and row.farmId ~= nil
                        and row.text ~= nil
                        and row.text ~= ""
                        and (row.remainingMs == nil or row.remainingMs > 0) then

                        table.insert(rows, row)
                    end
                end
            elseif not ok then
                print(string.format(
                    "[FarmersCompetition][BoostHUD] ERROR provider=%s error=%s",
                    tostring(provider),
                    tostring(providerRows)
                ))
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.farmId ~= b.farmId then
            return a.farmId < b.farmId
        end

        local orderA = a.sortOrder or 100
        local orderB = b.sortOrder or 100
        if orderA ~= orderB then
            return orderA < orderB
        end

        return tostring(a.id or a.text) < tostring(b.id or b.text)
    end)

    return rows
end

-- Назначение: форматирует оставшееся время действия буста.
function CompetitionBoostHUD.formatRemainingTime(remainingMs)
    if remainingMs == nil then
        return ""
    end

    local totalSeconds = math.max(0, math.ceil(remainingMs * 0.001))
    local hours = math.floor(totalSeconds / 3600)
    local minutes = math.floor((totalSeconds % 3600) / 60)
    local seconds = totalSeconds % 60

    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds)
    end

    return string.format("%02d:%02d", minutes, seconds)
end

-- Назначение: находит HUD-описание команды по farmId.
function CompetitionBoostHUD.getTeamByFarmId(ui, farmId)
    if ui == nil or ui.manager == nil then
        return nil
    end

    local teams = ui.manager:getProgressTeams()
    for _, team in ipairs(teams) do
        if team.farmId == farmId then
            return team
        end
    end

    return nil
end

-- Назначение: вычисляет правую и нижнюю границы текущего вида таблицы прогресса.
function CompetitionBoostHUD.getProgressTableAnchor(ui)
    local teams = ui.manager:getProgressTeams()
    if #teams == 0 then
        return nil, nil
    end

    local padX = CompetitionUI.HUD_HORIZONTAL_PADDING
    local panelWidth =
        padX * 2
        + CompetitionUI.HUD_LABEL_WIDTH
        + #teams * CompetitionUI.HUD_TEAM_COLUMN_WIDTH

    local panelX = 1 - CompetitionUI.HUD_RIGHT_MARGIN - panelWidth
    local rightX = panelX + panelWidth

    local fullHeight =
        ui.progressDetailsVisible
        and CompetitionUI.HUD_DETAILED_HEIGHT
        or CompetitionUI.HUD_COLLAPSED_HEIGHT

    local tableHeight =
        fullHeight
        - CompetitionUI.HUD_TIMER_HEIGHT
        - CompetitionUI.HUD_BLOCK_GAP

    local tableTop =
        CompetitionUI.HUD_TOP
        - CompetitionUI.HUD_TIMER_HEIGHT
        - CompetitionUI.HUD_BLOCK_GAP

    local tableY = tableTop - tableHeight

    return rightX, tableY
end

-- Назначение: рисует активные командные бусты без дополнительного фона.
function CompetitionBoostHUD.draw(ui)
    if ui == nil
        or ui.manager == nil
        or not ui:isHudVisible() then
        return
    end

    local rows = CompetitionBoostHUD.collectRows()
    if #rows == 0 then
        return
    end

    local rightX, tableY = CompetitionBoostHUD.getProgressTableAnchor(ui)
    if rightX == nil then
        return
    end

    local fontScale = ui:getProgressFontScale()
    local textSize =
        CompetitionBoostHUD.TEXT_SIZE
        * math.min(fontScale or 1, 1.16)

    local topGap =
        ui.progressDetailsVisible
        and CompetitionBoostHUD.DETAILED_TOP_GAP
        or CompetitionBoostHUD.COLLAPSED_TOP_GAP

    local cursorY = tableY - topGap

    for _, row in ipairs(rows) do
        local team = CompetitionBoostHUD.getTeamByFarmId(ui, row.farmId)
        local teamName = team ~= nil and team.hudName or string.format("ФЕРМА %d", row.farmId)
        local teamColor = team ~= nil and team.actualColor or {1, 1, 1, 1}

        local timeText = CompetitionBoostHUD.formatRemainingTime(row.remainingMs)

        -- Таймер расположен максимально близко к правому краю.
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextBold(true)
        setTextColor(1, 1, 1, 1)
        renderText(rightX, cursorY, textSize, timeText)

        local timeWidth = timeText ~= "" and getTextWidth(textSize, timeText) or 0
        local boostRightX = rightX - timeWidth
        if timeWidth > 0 then
            boostRightX = boostRightX - CompetitionBoostHUD.COLUMN_GAP
        end

        -- Параметры буста.
        setTextBold(false)
        setTextColor(1, 1, 1, 0.96)
        renderText(boostRightX, cursorY, textSize, row.text)

        local boostWidth = getTextWidth(textSize, row.text)
        local teamRightX = boostRightX - boostWidth - CompetitionBoostHUD.COLUMN_GAP

        -- Имя команды окрашивается цветом её колонки в таблице прогресса.
        setTextBold(true)
        setTextColor(teamColor[1], teamColor[2], teamColor[3], 1)
        renderText(teamRightX, cursorY, textSize, teamName)

        cursorY = cursorY - CompetitionBoostHUD.ROW_STEP
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

-- Подключаем отрисовку бустов после основной таблицы прогресса.
if CompetitionUI ~= nil
    and CompetitionUI.drawCompetitionHud ~= nil
    and not CompetitionBoostHUD.drawHookInstalled then

    CompetitionBoostHUD.drawHookInstalled = true
    CompetitionBoostHUD.originalDrawCompetitionHud = CompetitionUI.drawCompetitionHud

    CompetitionUI.drawCompetitionHud = function(ui, ...)
        CompetitionBoostHUD.originalDrawCompetitionHud(ui, ...)
        CompetitionBoostHUD.draw(ui)
    end

    print(string.format(
        "[FarmersCompetition][BoostHUD] Установлен общий HUD бустов, version=%s",
        CompetitionBoostHUD.VERSION
    ))
end
