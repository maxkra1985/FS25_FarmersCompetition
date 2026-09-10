--[[
    FS25 FarmersCompetition - Shared Utilities and Constants
    Содержит глобальные константы, конфигурации и вспомогательные методы API Giants.
]]

CompetitionUtils = {}

CompetitionUtils.LOG_PREFIX = "[FarmersCompetition]"

-- Состояния соревнования
CompetitionUtils.STATE = {
    WAITING_FOR_PLAYERS = 0,
    WAITING_FOR_READY = 1,
    STARTING = 2,
    RUNNING = 3,
    FINISHED = 4 -- Добавлено состояние финиша
}

-- Конфигурация команд
CompetitionUtils.TEAM_CONFIG = {
    { farmlandId = 1, farmId = 1, code = "BLUE",   farmName = "Синие",   hudName = "СИНИЕ",   desiredColor = {0.12, 0.25, 1.00} },
    { farmlandId = 2, farmId = 2, code = "RED",    farmName = "Красные", hudName = "КРАСНЫЕ", desiredColor = {1.00, 0.12, 0.00} },
    { farmlandId = 3, farmId = 3, code = "GREEN",  farmName = "Зелёные", hudName = "ЗЕЛЁНЫЕ", desiredColor = {0.23, 1.00, 0.22} },
    { farmlandId = 4, farmId = 4, code = "YELLOW", farmName = "Жёлтые",  hudName = "ЖЁЛТЫЕ",  desiredColor = {1.00, 0.85, 0.00} }
}

CompetitionUtils.ADMIN_CONFIG = {
    farmId = 5, code = "ADMIN", farmName = "Администраторы", hudName = "АДМИНИСТРАТОРЫ",
    desiredColor = {0.72, 0.72, 0.72}, alwaysCreate = true, isAdmin = true
}

-- У административной фермы нет отдельного farmland.
CompetitionUtils.ADMIN_FARMLAND_ID = nil
CompetitionUtils.ADMIN_FARM_ID = CompetitionUtils.ADMIN_CONFIG.farmId

-------------------------------------------------------------------------------
-- ЛОГИРОВАНИЕ (Обертки над стандартным Logging API Giants)
-------------------------------------------------------------------------------
function CompetitionUtils.info(formatString, ...)
    Logging.info("%s %s", CompetitionUtils.LOG_PREFIX, string.format(formatString, ...))
end

function CompetitionUtils.warning(formatString, ...)
    Logging.warning("%s %s", CompetitionUtils.LOG_PREFIX, string.format(formatString, ...))
end

function CompetitionUtils.error(formatString, ...)
    Logging.error("%s %s", CompetitionUtils.LOG_PREFIX, string.format(formatString, ...))
end

-------------------------------------------------------------------------------
-- СЕТЕВОЕ ОКРУЖЕНИЕ (Безопасные проверки статуса миссии)
-------------------------------------------------------------------------------
function CompetitionUtils.getIsServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

function CompetitionUtils.getIsClient()
    return g_currentMission ~= nil and g_currentMission:getIsClient()
end

function CompetitionUtils.getIsMultiplayer()
    return g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer
end

-------------------------------------------------------------------------------
-- РАБОТА С ИГРОКАМИ И ФЕРМАМИ (Giants API)
-------------------------------------------------------------------------------

-- Получить ID локального игрока (безопасно)
function CompetitionUtils.getLocalUserId()
    if g_localPlayer ~= nil then
        return g_localPlayer.userId
    end
    return nil
end

-- Получить объект пользователя по ID
function CompetitionUtils.getUserById(userId)
    if g_currentMission == nil or g_currentMission.userManager == nil or userId == nil then
        return nil
    end
    return g_currentMission.userManager:getUserByUserId(userId)
end

-- Получить никнейм или вернуть ID, если ник не найден
function CompetitionUtils.getUserNickname(userId)
    local user = CompetitionUtils.getUserById(userId)
    if user ~= nil and user.getNickname ~= nil then
        return user:getNickname()
    end
    return tostring(userId)
end

-- Поиск farmId игрока путем обхода активных пользователей ферм (стандартный паттерн FS)
function CompetitionUtils.getFarmIdForUserId(userId)
    if g_farmManager == nil then return nil end
    for _, farm in ipairs(g_farmManager:getFarms() or {}) do
        for _, activeUser in ipairs(farm.activeUsers or {}) do
            if activeUser.userId == userId then
                return farm.farmId
            end
        end
    end
    return nil
end

-- Является ли переданная ферма одной из команд соревнований (1-4) или Админом (5)
function CompetitionUtils.isCompetitionFarmId(farmId)
    if farmId == nil then return false end
    if farmId == CompetitionUtils.ADMIN_FARM_ID then return true end
    for _, config in ipairs(CompetitionUtils.TEAM_CONFIG) do
        if config.farmId == farmId then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- МАТЕМАТИКА
-------------------------------------------------------------------------------
function CompetitionUtils.clampPercent(value)
    return math.max(0, math.min(100, value or 0))
end