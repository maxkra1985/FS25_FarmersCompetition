--[[
    FS25 FarmersCompetition - Network Layer
    Содержит классы сетевых событий (Events) для синхронизации состояния между сервером и клиентами.
]]

-------------------------------------------------------------------------------
-- 1. ЗАПРОС ГОТОВНОСТИ (Клиент -> Сервер)
-- Отправляется, когда игрок нажимает ENTER.
-------------------------------------------------------------------------------
CompetitionReadyRequestEvent = {}
local CompetitionReadyRequestEvent_mt = Class(CompetitionReadyRequestEvent, Event)
InitEventClass(CompetitionReadyRequestEvent, "CompetitionReadyRequestEvent")

function CompetitionReadyRequestEvent.emptyNew() return Event.new(CompetitionReadyRequestEvent_mt) end
function CompetitionReadyRequestEvent.new() return CompetitionReadyRequestEvent.emptyNew() end
function CompetitionReadyRequestEvent:writeStream(streamId, connection) end
function CompetitionReadyRequestEvent:readStream(streamId, connection) self:run(connection) end

function CompetitionReadyRequestEvent:run(connection)
    if connection:getIsServer() then return end
    if g_competitionManager ~= nil then 
        g_competitionManager:handleReadyRequest(connection) 
    end
end


-------------------------------------------------------------------------------
-- 2. СИНХРОНИЗАЦИЯ ГОТОВНОСТИ ИГРОКА (Сервер -> Клиенты)
-- Сервер сообщает всем, что конкретный игрок готов/не готов.
-------------------------------------------------------------------------------
CompetitionReadyStateEvent = {}
local CompetitionReadyStateEvent_mt = Class(CompetitionReadyStateEvent, Event)
InitEventClass(CompetitionReadyStateEvent, "CompetitionReadyStateEvent")

function CompetitionReadyStateEvent.emptyNew() return Event.new(CompetitionReadyStateEvent_mt) end
function CompetitionReadyStateEvent.new(userId, isReady, competitionState)
    local event = CompetitionReadyStateEvent.emptyNew()
    event.userId = userId
    event.isReady = isReady == true
    event.competitionState = competitionState or 0
    return event
end

function CompetitionReadyStateEvent:writeStream(streamId, connection)
    User.streamWriteUserId(streamId, self.userId)
    streamWriteBool(streamId, self.isReady)
    streamWriteUIntN(streamId, self.competitionState, 3) -- 3 бита хватает для состояний 0-4
end

function CompetitionReadyStateEvent:readStream(streamId, connection)
    self.userId = User.streamReadUserId(streamId)
    self.isReady = streamReadBool(streamId)
    self.competitionState = streamReadUIntN(streamId, 3)
    self:run(connection)
end

function CompetitionReadyStateEvent:run(connection)
    if not connection:getIsServer() then return end
    if g_competitionManager ~= nil then
        g_competitionManager:applyReadyStateFromServer(self.userId, self.isReady, self.competitionState)
    end
end


-------------------------------------------------------------------------------
-- 3. ЗАПРОС ПОЛНОГО СРЕЗА СОСТОЯНИЯ (Клиент -> Сервер)
-- Отправляется при входе нового игрока на сервер.
-------------------------------------------------------------------------------
CompetitionSyncRequestEvent = {}
local CompetitionSyncRequestEvent_mt = Class(CompetitionSyncRequestEvent, Event)
InitEventClass(CompetitionSyncRequestEvent, "CompetitionSyncRequestEvent")

function CompetitionSyncRequestEvent.emptyNew() return Event.new(CompetitionSyncRequestEvent_mt) end
function CompetitionSyncRequestEvent.new() return CompetitionSyncRequestEvent.emptyNew() end
function CompetitionSyncRequestEvent:writeStream(streamId, connection) end
function CompetitionSyncRequestEvent:readStream(streamId, connection) self:run(connection) end

function CompetitionSyncRequestEvent:run(connection)
    if connection:getIsServer() then return end
    if g_competitionManager ~= nil then 
        g_competitionManager:sendStateSnapshot(connection) 
    end
end


-------------------------------------------------------------------------------
-- 4. ПОЛНЫЙ СРЕЗ СОСТОЯНИЯ (Сервер -> Клиент)
-- Содержит всех готовых игроков и текущую стадию (Ожидание, Старт, Финиш).
-------------------------------------------------------------------------------
CompetitionSyncStateEvent = {}
local CompetitionSyncStateEvent_mt = Class(CompetitionSyncStateEvent, Event)
InitEventClass(CompetitionSyncStateEvent, "CompetitionSyncStateEvent")

function CompetitionSyncStateEvent.emptyNew() return Event.new(CompetitionSyncStateEvent_mt) end
function CompetitionSyncStateEvent.new(competitionState, readyByUserId)
    local event = CompetitionSyncStateEvent.emptyNew()
    event.competitionState = competitionState or 0
    event.readyUserIds = {}
    for userId, isReady in pairs(readyByUserId or {}) do
        if isReady == true then table.insert(event.readyUserIds, userId) end
    end
    return event
end

function CompetitionSyncStateEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.competitionState, 3)
    local count = math.min(#self.readyUserIds, 255)
    streamWriteUInt8(streamId, count)
    for index = 1, count do 
        User.streamWriteUserId(streamId, self.readyUserIds[index]) 
    end
end

function CompetitionSyncStateEvent:readStream(streamId, connection)
    self.competitionState = streamReadUIntN(streamId, 3)
    self.readyUserIds = {}
    local count = streamReadUInt8(streamId)
    for _ = 1, count do 
        table.insert(self.readyUserIds, User.streamReadUserId(streamId)) 
    end
    self:run(connection)
end

function CompetitionSyncStateEvent:run(connection)
    if not connection:getIsServer() then return end
    if g_competitionManager ~= nil then
        g_competitionManager:applyStateSnapshotFromServer(self.competitionState, self.readyUserIds)
    end
end


-------------------------------------------------------------------------------
-- 5. СИНХРОНИЗАЦИЯ ЧАСОВ И КОМАНД (Сервер -> Клиенты)
-- Синхронизирует время соревнования.
-------------------------------------------------------------------------------
CompetitionClockStateEvent = {}
local CompetitionClockStateEvent_mt = Class(CompetitionClockStateEvent, Event)
InitEventClass(CompetitionClockStateEvent, "CompetitionClockStateEvent")

function CompetitionClockStateEvent.emptyNew() return Event.new(CompetitionClockStateEvent_mt) end
function CompetitionClockStateEvent.new(elapsedSeconds, teamMask)
    local event = CompetitionClockStateEvent.emptyNew()
    event.elapsedSeconds = elapsedSeconds or 0
    event.teamMask = teamMask or 0
    return event
end

function CompetitionClockStateEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.elapsedSeconds)
    streamWriteUIntN(streamId, self.teamMask, 4)
end

function CompetitionClockStateEvent:readStream(streamId, connection)
    self.elapsedSeconds = streamReadFloat32(streamId)
    self.teamMask = streamReadUIntN(streamId, 4)
    self:run(connection)
end

function CompetitionClockStateEvent:run(connection)
    if not connection:getIsServer() then return end
    if g_competitionManager ~= nil then
        g_competitionManager:applyClockStateFromServer(self.elapsedSeconds, self.teamMask)
    end
end


-------------------------------------------------------------------------------
-- 6. СИНХРОНИЗАЦИЯ ПРОГРЕССА ЗАДАНИЙ (Сервер -> Клиенты)
-- НОВОЕ СОБЫТИЕ: Передает проценты по всем заданиям (0-100%).
-------------------------------------------------------------------------------
CompetitionProgressSyncEvent = {}
local CompetitionProgressSyncEvent_mt = Class(CompetitionProgressSyncEvent, Event)
InitEventClass(CompetitionProgressSyncEvent, "CompetitionProgressSyncEvent")

function CompetitionProgressSyncEvent.emptyNew() return Event.new(CompetitionProgressSyncEvent_mt) end
function CompetitionProgressSyncEvent.new(progressByFarmId)
    local event = CompetitionProgressSyncEvent.emptyNew()
    event.progressByFarmId = progressByFarmId
    return event
end

function CompetitionProgressSyncEvent:writeStream(streamId, connection)
    local count = 0
    for farmId, _ in pairs(self.progressByFarmId or {}) do count = count + 1 end
    streamWriteUInt8(streamId, count)
    
    for farmId, farmData in pairs(self.progressByFarmId) do
        streamWriteUInt8(streamId, farmId)
        streamWriteFloat32(streamId, farmData.overall or 0)
        
        -- Передаем подзадачи динамически
        for taskId, taskData in pairs(farmData.tasks) do
            for subtaskId, percent in pairs(taskData.subtasks) do
                streamWriteString(streamId, taskId)
                streamWriteString(streamId, subtaskId)
                streamWriteFloat32(streamId, percent)
            end
        end
        streamWriteString(streamId, "END_TASKS") -- Маркер конца списка задач для фермы
    end
end

function CompetitionProgressSyncEvent:readStream(streamId, connection)
    self.progressByFarmId = {}
    local count = streamReadUInt8(streamId)
    
    for i = 1, count do
        local farmId = streamReadUInt8(streamId)
        local farmData = {overall = streamReadFloat32(streamId), tasks = {}}
        
        -- Инициализируем пустую структуру задач, чтобы не было nil-ошибок в HUD
        if g_competitionManager ~= nil and g_competitionManager.TASKS ~= nil then
            for _, task in ipairs(g_competitionManager.TASKS) do
                farmData.tasks[task.id] = {overall = 0, subtasks = {}}
            end
        end
        
        -- Читаем подзадачи до маркера
        while true do
            local taskId = streamReadString(streamId)
            if taskId == "END_TASKS" then break end
            
            local subtaskId = streamReadString(streamId)
            local percent = streamReadFloat32(streamId)
            
            if farmData.tasks[taskId] ~= nil then
                farmData.tasks[taskId].subtasks[subtaskId] = percent
            end
        end
        
        self.progressByFarmId[farmId] = farmData
    end
    self:run(connection)
end

function CompetitionProgressSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    -- Применяем полученные данные на клиенте
    if g_competitionManager ~= nil then
        g_competitionManager.progressByFarmId = self.progressByFarmId
        
        -- Пересчитываем средние значения задач
        for farmId, _ in pairs(self.progressByFarmId) do
            g_competitionManager:recalculateProgressAggregates(farmId)
        end
    end
end