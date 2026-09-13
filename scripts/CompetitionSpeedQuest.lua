--[[
    FS25 FarmersCompetition - Speed Boost Quest
    Первый квест на временный бонус транспортной и рабочей скорости.

    Стартовые триггеры определяются по UserAttribute:
        boostName = "speed"
        farmId = 1..4

    Квестовая зона определяется по узлам:
        boostSpeed -> spawnVehicle
        boostSpeed -> finishTrigger

    На spawnVehicle необходимо добавить UserAttribute:
        vehicleXml = "data/vehicles/.../...xml"
]]

CompetitionSpeedQuest = {}
local CompetitionSpeedQuest_mt = Class(CompetitionSpeedQuest)

CompetitionSpeedQuest.VERSION = "0.1.12"

CompetitionSpeedQuest.STATE = {
    AVAILABLE = 0,
    PREPARING = 1,
    RUNNING = 2,
    BOOST_ACTIVE = 3
}

-- Плавная шкала награды speed-квеста.
-- 25 секунд и быстрее дают максимальный буст.
-- На 40 секундах выдаётся минимальный буст, после 40 секунд награды нет.
CompetitionSpeedQuest.REWARD_BEST_TIME_SECONDS = 25
CompetitionSpeedQuest.REWARD_LIMIT_TIME_SECONDS = 40

CompetitionSpeedQuest.REWARD_MIN_TRANSPORT_MULTIPLIER = 1.5
CompetitionSpeedQuest.REWARD_MAX_TRANSPORT_MULTIPLIER = 3.0

CompetitionSpeedQuest.REWARD_MIN_WORK_MULTIPLIER = 1.2
CompetitionSpeedQuest.REWARD_MAX_WORK_MULTIPLIER = 2.0

CompetitionSpeedQuest.REWARD_MIN_DURATION_SECONDS = 180
CompetitionSpeedQuest.REWARD_MAX_DURATION_SECONDS = 600

CompetitionSpeedQuest.INIT_DELAY_MS = 1500
CompetitionSpeedQuest.VEHICLE_DELETE_DELAY_MS = 1500
CompetitionSpeedQuest.MOTOR_REFRESH_INTERVAL_MS = 500
CompetitionSpeedQuest.ENTER_VEHICLE_TIMEOUT_MS = 5000
-- Экспериментальный RPM boost: transport x3 -> RPM x1.5.
CompetitionSpeedQuest.RPM_BOOST_DIVISOR = 2.0
CompetitionSpeedQuest.START_ACTION_TEXT = "Начать испытание скорости"
CompetitionSpeedQuest.INPUT_ACTION_NAME = "FC_QUEST_ACTIVATE"

-------------------------------------------------------------------------------
-- СЕТЕВЫЕ СОБЫТИЯ
-------------------------------------------------------------------------------

-- Запрос старта квеста от клиента на сервер.
CompetitionSpeedQuestStartRequestEvent = {}
local CompetitionSpeedQuestStartRequestEvent_mt = Class(CompetitionSpeedQuestStartRequestEvent, Event)
InitEventClass(CompetitionSpeedQuestStartRequestEvent, "CompetitionSpeedQuestStartRequestEvent")

function CompetitionSpeedQuestStartRequestEvent.emptyNew()
    return Event.new(CompetitionSpeedQuestStartRequestEvent_mt)
end

function CompetitionSpeedQuestStartRequestEvent.new(farmId)
    local self = CompetitionSpeedQuestStartRequestEvent.emptyNew()
    self.farmId = farmId or 0
    return self
end

function CompetitionSpeedQuestStartRequestEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
end

function CompetitionSpeedQuestStartRequestEvent:readStream(streamId, connection)
    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self:run(connection)
end

-- Назначение: передаёт серверу намерение игрока начать квест.
function CompetitionSpeedQuestStartRequestEvent:run(connection)
    if connection:getIsServer() then
        return
    end

    print(string.format(
        "[FarmersCompetition][SpeedQuest] START REQUEST EVENT received farmId=%d",
        self.farmId or 0
    ))

    if g_competitionSpeedQuest ~= nil then
        g_competitionSpeedQuest:handleStartRequest(connection, self.farmId)
    end
end


-- Запрос полного состояния квеста новым клиентом.
CompetitionSpeedQuestSyncRequestEvent = {}
local CompetitionSpeedQuestSyncRequestEvent_mt = Class(CompetitionSpeedQuestSyncRequestEvent, Event)
InitEventClass(CompetitionSpeedQuestSyncRequestEvent, "CompetitionSpeedQuestSyncRequestEvent")

function CompetitionSpeedQuestSyncRequestEvent.emptyNew()
    return Event.new(CompetitionSpeedQuestSyncRequestEvent_mt)
end

function CompetitionSpeedQuestSyncRequestEvent.new()
    return CompetitionSpeedQuestSyncRequestEvent.emptyNew()
end

function CompetitionSpeedQuestSyncRequestEvent:writeStream(streamId, connection)
end

function CompetitionSpeedQuestSyncRequestEvent:readStream(streamId, connection)
    self:run(connection)
end

-- Назначение: запрашивает у сервера актуальное состояние квеста и буста.
function CompetitionSpeedQuestSyncRequestEvent:run(connection)
    if connection:getIsServer() then
        return
    end

    if g_competitionSpeedQuest ~= nil then
        g_competitionSpeedQuest:sendStateToConnection(connection)
    end
end


-- Полное состояние квеста и активного speed boost.
CompetitionSpeedQuestStateEvent = {}
local CompetitionSpeedQuestStateEvent_mt = Class(CompetitionSpeedQuestStateEvent, Event)
InitEventClass(CompetitionSpeedQuestStateEvent, "CompetitionSpeedQuestStateEvent")

function CompetitionSpeedQuestStateEvent.emptyNew()
    return Event.new(CompetitionSpeedQuestStateEvent_mt)
end

function CompetitionSpeedQuestStateEvent.new(state, activeFarmId, boostFarmId, transportMultiplier, workMultiplier, remainingMs)
    local self = CompetitionSpeedQuestStateEvent.emptyNew()
    self.state = state or CompetitionSpeedQuest.STATE.AVAILABLE
    self.activeFarmId = activeFarmId or 0
    self.boostFarmId = boostFarmId or 0
    self.transportMultiplier = transportMultiplier or 1
    self.workMultiplier = workMultiplier or 1
    self.remainingMs = math.max(remainingMs or 0, 0)
    return self
end

function CompetitionSpeedQuestStateEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.state, 2)
    streamWriteUIntN(streamId, self.activeFarmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.boostFarmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteFloat32(streamId, self.transportMultiplier)
    streamWriteFloat32(streamId, self.workMultiplier)
    streamWriteInt32(streamId, math.floor(self.remainingMs))
end

function CompetitionSpeedQuestStateEvent:readStream(streamId, connection)
    self.state = streamReadUIntN(streamId, 2)
    self.activeFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.boostFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.transportMultiplier = streamReadFloat32(streamId)
    self.workMultiplier = streamReadFloat32(streamId)
    self.remainingMs = streamReadInt32(streamId)
    self:run(connection)
end

-- Назначение: применяет на клиенте серверное состояние квеста и speed boost.
function CompetitionSpeedQuestStateEvent:run(connection)
    if not connection:getIsServer() then
        return
    end

    if g_competitionSpeedQuest ~= nil then
        g_competitionSpeedQuest:applyStateFromServer(
            self.state,
            self.activeFarmId,
            self.boostFarmId,
            self.transportMultiplier,
            self.workMultiplier,
            self.remainingMs
        )
    end
end


-- Серверная команда конкретному клиенту телепортировать локального игрока.
CompetitionSpeedQuestTeleportEvent = {}
local CompetitionSpeedQuestTeleportEvent_mt = Class(CompetitionSpeedQuestTeleportEvent, Event)
InitEventClass(CompetitionSpeedQuestTeleportEvent, "CompetitionSpeedQuestTeleportEvent")

function CompetitionSpeedQuestTeleportEvent.emptyNew()
    return Event.new(CompetitionSpeedQuestTeleportEvent_mt)
end

function CompetitionSpeedQuestTeleportEvent.new(x, y, z, yaw)
    local self = CompetitionSpeedQuestTeleportEvent.emptyNew()
    self.x = x or 0
    self.y = y or 0
    self.z = z or 0
    self.yaw = yaw or 0
    return self
end

function CompetitionSpeedQuestTeleportEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.y)
    streamWriteFloat32(streamId, self.z)
    streamWriteFloat32(streamId, self.yaw)
end

function CompetitionSpeedQuestTeleportEvent:readStream(streamId, connection)
    self.x = streamReadFloat32(streamId)
    self.y = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self.yaw = streamReadFloat32(streamId)
    self:run(connection)
end

-- Назначение: высаживает локального игрока из техники и переносит его в заданную точку.
function CompetitionSpeedQuestTeleportEvent:run(connection)
    if not connection:getIsServer() or g_localPlayer == nil then
        return
    end

    if g_localPlayer:getCurrentVehicle() ~= nil then
        g_localPlayer:leaveVehicle()
    end

    g_localPlayer:teleportTo(self.x, self.y, self.z, true, true)

    if g_localPlayer.mover ~= nil then
        g_localPlayer.mover:setMovementYaw(self.yaw)
    end
    if g_localPlayer.graphicsComponent ~= nil then
        g_localPlayer.graphicsComponent:setModelYaw(self.yaw)
    end
end


-- Серверная команда клиенту войти водителем в квестовую технику.
CompetitionSpeedQuestEnterVehicleEvent = {}
local CompetitionSpeedQuestEnterVehicleEvent_mt = Class(CompetitionSpeedQuestEnterVehicleEvent, Event)
InitEventClass(CompetitionSpeedQuestEnterVehicleEvent, "CompetitionSpeedQuestEnterVehicleEvent")

function CompetitionSpeedQuestEnterVehicleEvent.emptyNew()
    return Event.new(CompetitionSpeedQuestEnterVehicleEvent_mt)
end

function CompetitionSpeedQuestEnterVehicleEvent.new(vehicleUniqueId)
    local self = CompetitionSpeedQuestEnterVehicleEvent.emptyNew()
    self.vehicleUniqueId = vehicleUniqueId or ""
    return self
end

function CompetitionSpeedQuestEnterVehicleEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.vehicleUniqueId)
end

function CompetitionSpeedQuestEnterVehicleEvent:readStream(streamId, connection)
    self.vehicleUniqueId = streamReadString(streamId)
    self:run(connection)
end

-- Назначение: ставит удалённому клиенту отложенную посадку в квестовую технику.
-- Сервер может завершить VehicleLoadingData раньше, чем этот Vehicle уже существует
-- в локальном VehicleSystem клиента, поэтому передаём stable uniqueId.
function CompetitionSpeedQuestEnterVehicleEvent:run(connection)
    if not connection:getIsServer()
        or g_competitionSpeedQuest == nil
        or self.vehicleUniqueId == nil
        or self.vehicleUniqueId == "" then
        return
    end

    g_competitionSpeedQuest:setPendingEnterVehicle(
        self.vehicleUniqueId
    )
end


-- Результат попытки для игрока, который проходил квест.
CompetitionSpeedQuestResultEvent = {}
local CompetitionSpeedQuestResultEvent_mt = Class(CompetitionSpeedQuestResultEvent, Event)
InitEventClass(CompetitionSpeedQuestResultEvent, "CompetitionSpeedQuestResultEvent")

function CompetitionSpeedQuestResultEvent.emptyNew()
    return Event.new(CompetitionSpeedQuestResultEvent_mt)
end

function CompetitionSpeedQuestResultEvent.new(elapsedSeconds, transportMultiplier, workMultiplier, durationSeconds)
    local self = CompetitionSpeedQuestResultEvent.emptyNew()
    self.elapsedSeconds = elapsedSeconds or 0
    self.transportMultiplier = transportMultiplier or 1
    self.workMultiplier = workMultiplier or 1
    self.durationSeconds = durationSeconds or 0
    return self
end

function CompetitionSpeedQuestResultEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.elapsedSeconds)
    streamWriteFloat32(streamId, self.transportMultiplier)
    streamWriteFloat32(streamId, self.workMultiplier)
    streamWriteUInt16(streamId, math.floor(self.durationSeconds))
end

function CompetitionSpeedQuestResultEvent:readStream(streamId, connection)
    self.elapsedSeconds = streamReadFloat32(streamId)
    self.transportMultiplier = streamReadFloat32(streamId)
    self.workMultiplier = streamReadFloat32(streamId)
    self.durationSeconds = streamReadUInt16(streamId)
    self:run(connection)
end

-- Назначение: показывает прошедшему игроку время и полученную награду.
function CompetitionSpeedQuestResultEvent:run(connection)
    if not connection:getIsServer() or g_currentMission == nil then
        return
    end

    local text
    if self.durationSeconds > 0 then
        text = string.format(
            "Испытание: %.2f с. Буст: скорость x%.2f, работа x%.2f, %d с.",
            self.elapsedSeconds,
            self.transportMultiplier,
            self.workMultiplier,
            self.durationSeconds
        )
    else
        text = string.format("Испытание: %.2f с. Буст не получен.", self.elapsedSeconds)
    end

    if g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(text, 6000)
    else
        print("[FarmersCompetition][SpeedQuest] " .. text)
    end
end


-------------------------------------------------------------------------------
-- ACTIVATABLE ДЛЯ F1 / E
-------------------------------------------------------------------------------

CompetitionSpeedQuestActivatable = {}
local CompetitionSpeedQuestActivatable_mt = Class(CompetitionSpeedQuestActivatable)

function CompetitionSpeedQuestActivatable.new(quest, triggerData)
    local self = setmetatable({}, CompetitionSpeedQuestActivatable_mt)
    self.quest = quest
    self.triggerData = triggerData
    self.activateText = CompetitionSpeedQuest.START_ACTION_TEXT
    return self
end

-- Назначение: разрешает E только игроку своей фермы при доступном квесте.
function CompetitionSpeedQuestActivatable:getIsActivatable()
    if self.quest == nil or self.triggerData == nil or g_localPlayer == nil then
        return false
    end

    if g_localPlayer:getCurrentVehicle() ~= nil then
        return false
    end

    if g_localPlayer.farmId ~= self.triggerData.farmId then
        return false
    end

    return self.quest:getCanStartQuest(self.triggerData.farmId)
end

-- Назначение: регистрирует отдельное действие квеста.
-- Общее действие FC_QUEST_ACTIVATE задаётся в modDesc.xml и используется всеми квестами.
-- Текст F1 задаётся конкретным Activatable, поэтому для разных испытаний он может отличаться.
function CompetitionSpeedQuestActivatable:registerCustomInput(inputContext)
    local action = InputAction[CompetitionSpeedQuest.INPUT_ACTION_NAME]
    if action == nil then
        print(string.format(
            "[FarmersCompetition][SpeedQuest] ERROR: InputAction '%s' не зарегистрирован в modDesc.xml",
            CompetitionSpeedQuest.INPUT_ACTION_NAME
        ))
        return
    end

    local _, actionEventId = g_inputBinding:registerActionEvent(
        action,
        self,
        self.onStartInput,
        false,
        true,
        false,
        true
    )

    self.actionEventId = actionEventId

    if actionEventId ~= nil then
        g_inputBinding:setActionEventText(actionEventId, CompetitionSpeedQuest.START_ACTION_TEXT)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    end
end

-- Назначение: снимает отдельное действие квеста при выходе из зоны или блокировке.
function CompetitionSpeedQuestActivatable:removeCustomInput(inputContext)
    g_inputBinding:removeActionEventsByTarget(self)
    self.actionEventId = nil
end

-- Назначение: обрабатывает нажатие отдельной клавиши старта квеста.
function CompetitionSpeedQuestActivatable:onStartInput(actionName, inputValue, callbackState, isAnalog)
    self:run()
end

-- Назначение: отправляет серверу запрос на атомарный старт квеста.
function CompetitionSpeedQuestActivatable:run()
    if self.quest ~= nil and self.triggerData ~= nil then
        print(string.format(
            "[FarmersCompetition][SpeedQuest] ACTIVATABLE RUN farmId=%d",
            self.triggerData.farmId or 0
        ))
        self.quest:requestStart(self.triggerData.farmId)
    end
end


-------------------------------------------------------------------------------
-- ОСНОВНОЙ КЛАСС КВЕСТА
-------------------------------------------------------------------------------

function CompetitionSpeedQuest.new(customMt)
    local self = setmetatable({}, customMt or CompetitionSpeedQuest_mt)

    self.state = CompetitionSpeedQuest.STATE.AVAILABLE
    self.activeFarmId = 0
    self.activeUserId = nil
    self.activeConnection = nil
    self.startTimeMs = nil

    self.startTriggers = {}
    self.spawnVehicleNode = nil
    self.finishTriggerNode = nil
    self.questVehicleXml = nil
    self.questVehicle = nil
    self.pendingVehicleLoadingData = nil

    -- Удалённый клиент ждёт появления сервером созданного Vehicle по uniqueId,
    -- после чего отправляет штатный VehicleEnterRequestEvent через Player API.
    self.pendingEnterVehicleUniqueId = nil
    self.pendingEnterVehicleTimeoutMs = 0

    self.activeBoost = nil
    self.touchedMotors = setmetatable({}, {__mode = "k"})
    self.workSpeedWrappedVehicles = setmetatable({}, {__mode = "k"})

    self.initialized = false
    self.initTimer = CompetitionSpeedQuest.INIT_DELAY_MS
    self.syncRequested = false
    self.vehicleDeleteTimer = nil
    self.motorRefreshTimer = 0

    -- Последнее известное состояние основного соревнования.
    -- Нужно для обновления маркеров/F1, когда игрок уже стоит внутри триггера.
    self.lastCompetitionRunning = nil

    return self
end

-- Назначение: рекурсивно ищет дочерний узел по имени.
function CompetitionSpeedQuest:findChildRecursiveByName(node, targetName)
    if node == nil or node == 0 then
        return nil
    end

    local count = getNumOfChildren(node)
    for index = 0, count - 1 do
        local child = getChildAt(node, index)
        if getName(child) == targetName then
            return child
        end

        local nested = self:findChildRecursiveByName(child, targetName)
        if nested ~= nil then
            return nested
        end
    end

    return nil
end

-- Назначение: обходит сцену и собирает стартовые триггеры и узлы квестовой зоны.
function CompetitionSpeedQuest:scanScene(node)
    if node == nil or node == 0 then
        return
    end

    local boostName = getUserAttribute(node, "boostName")
    local farmId = tonumber(getUserAttribute(node, "farmId"))

    if boostName == "speed" and farmId ~= nil and farmId >= 1 and farmId <= 4 then
        local markerNode = self:findChildRecursiveByName(node, "markerIconSpeedBoost")
        table.insert(self.startTriggers, {
            node = node,
            farmId = farmId,
            markerNode = markerNode,
            isLocalPlayerInside = false,
            activatableRegistered = false
        })
    end

    if getName(node) == "spawnVehicle" then
        local parent = getParent(node)
        if parent ~= nil and parent ~= 0 and getName(parent) == "boostSpeed" then
            local finishTrigger = nil
            local childCount = getNumOfChildren(parent)
            for index = 0, childCount - 1 do
                local child = getChildAt(parent, index)
                if getName(child) == "finishTrigger" then
                    finishTrigger = child
                    break
                end
            end

            if finishTrigger ~= nil then
                self.spawnVehicleNode = node
                self.finishTriggerNode = finishTrigger
                self.questVehicleXml = getUserAttribute(node, "vehicleXml")
            end
        end
    end

    local count = getNumOfChildren(node)
    for index = 0, count - 1 do
        self:scanScene(getChildAt(node, index))
    end
end

-- Назначение: регистрирует карту квеста после полной загрузки миссии.
function CompetitionSpeedQuest:initialize()
    if self.initialized or g_currentMission == nil or not g_currentMission.isLoaded then
        return false
    end

    self.startTriggers = {}
    self:scanScene(getRootNode())

    if #self.startTriggers == 0 then
        print("[FarmersCompetition][SpeedQuest] ERROR: не найден ни один boostName='speed' trigger")
        return false
    end

    if self.spawnVehicleNode == nil or self.finishTriggerNode == nil then
        print("[FarmersCompetition][SpeedQuest] ERROR: не найдены boostSpeed/spawnVehicle/finishTrigger")
        return false
    end

    if self.questVehicleXml == nil or self.questVehicleXml == "" then
        print("[FarmersCompetition][SpeedQuest] ERROR: на spawnVehicle отсутствует UserAttribute vehicleXml")
    end

    if g_currentMission:getIsClient() then
        for _, triggerData in ipairs(self.startTriggers) do
            triggerData.activatable = CompetitionSpeedQuestActivatable.new(self, triggerData)
            addTrigger(triggerData.node, "onStartTriggerCallback", self)
        end
    end

    if g_currentMission:getIsServer() then
        addTrigger(self.finishTriggerNode, "onFinishTriggerCallback", self)
    end

    self.initialized = true
    self.lastCompetitionRunning = self:getIsCompetitionRunning()
    self:refreshTriggerPresentation()

    print(string.format(
        "[FarmersCompetition][SpeedQuest] Инициализация version=%s startTriggers=%d vehicleXml=%s competitionRunning=%s",
        CompetitionSpeedQuest.VERSION,
        #self.startTriggers,
        tostring(self.questVehicleXml),
        tostring(self.lastCompetitionRunning)
    ))

    return true
end

-- Назначение: проверяет, находится ли основное соревнование в RUNNING.
function CompetitionSpeedQuest:getIsCompetitionRunning()
    return g_competitionManager ~= nil
        and CompetitionUtils ~= nil
        and g_competitionManager.state == CompetitionUtils.STATE.RUNNING
end

-- Назначение: проверяет доступность квеста для указанной фермы.
function CompetitionSpeedQuest:getCanStartQuest(farmId)
    if not self.initialized
        or self.state ~= CompetitionSpeedQuest.STATE.AVAILABLE
        or not self:getIsCompetitionRunning()
        or farmId == nil
        or farmId < 1
        or farmId > 4 then
        return false
    end

    if self.questVehicleXml == nil or self.questVehicleXml == "" then
        return false
    end

    for _, triggerData in ipairs(self.startTriggers) do
        if triggerData.farmId == farmId then
            return true
        end
    end

    return false
end

-- Назначение: локальный callback входа/выхода игрока в командный стартовый триггер.
function CompetitionSpeedQuest:onStartTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then
        return
    end

    local triggerData = nil
    for _, data in ipairs(self.startTriggers) do
        if data.node == triggerId then
            triggerData = data
            break
        end
    end

    if triggerData == nil then
        return
    end

    -- onStay также считаем подтверждением нахождения внутри. Это важно после загрузки:
    -- trigger может зарегистрироваться уже тогда, когда игрок физически стоит в зоне.
    if onEnter or onStay then
        triggerData.isLocalPlayerInside = true
        self:refreshSingleTriggerActivatable(triggerData)
    elseif onLeave then
        triggerData.isLocalPlayerInside = false
        self:removeTriggerActivatable(triggerData)
    end
end

-- Назначение: добавляет/убирает F1-действие текущего стартового триггера.
function CompetitionSpeedQuest:refreshSingleTriggerActivatable(triggerData)
    if g_currentMission == nil or g_currentMission.activatableObjectsSystem == nil then
        return
    end

    local shouldRegister = triggerData.isLocalPlayerInside == true
        and g_localPlayer ~= nil
        and g_localPlayer.farmId == triggerData.farmId
        and self:getCanStartQuest(triggerData.farmId)

    if shouldRegister and not triggerData.activatableRegistered then
        g_currentMission.activatableObjectsSystem:addActivatable(triggerData.activatable)
        triggerData.activatableRegistered = true
        print(string.format(
            "[FarmersCompetition][SpeedQuest] F1 activatable ON farmId=%d",
            triggerData.farmId
        ))
    elseif not shouldRegister and triggerData.activatableRegistered then
        self:removeTriggerActivatable(triggerData)
    end
end

-- Назначение: снимает F1-действие стартового триггера.
function CompetitionSpeedQuest:removeTriggerActivatable(triggerData)
    if triggerData.activatableRegistered
        and g_currentMission ~= nil
        and g_currentMission.activatableObjectsSystem ~= nil then

        g_currentMission.activatableObjectsSystem:removeActivatable(triggerData.activatable)
    end

    triggerData.activatableRegistered = false
end

-- Назначение: обновляет видимость маркеров и F1-действия на всех командных стартах.
-- Маркер доступного квеста показывается только во время реально запущенного соревнования.
function CompetitionSpeedQuest:refreshTriggerPresentation()
    local isAvailable = self.state == CompetitionSpeedQuest.STATE.AVAILABLE
        and self:getIsCompetitionRunning()

    for _, triggerData in ipairs(self.startTriggers) do
        if triggerData.markerNode ~= nil and triggerData.markerNode ~= 0 then
            setVisibility(triggerData.markerNode, isAvailable)
        end

        if g_currentMission ~= nil and g_currentMission:getIsClient() then
            self:refreshSingleTriggerActivatable(triggerData)
        end
    end
end

-- Назначение: отправляет запрос старта квеста серверу.
function CompetitionSpeedQuest:requestStart(farmId)
    local canStart = self:getCanStartQuest(farmId)

    print(string.format(
        "[FarmersCompetition][SpeedQuest] requestStart farmId=%s canStart=%s hasClient=%s hasServer=%s",
        tostring(farmId),
        tostring(canStart),
        tostring(g_client ~= nil),
        tostring(g_server ~= nil)
    ))

    if not canStart then
        return
    end

    if g_client ~= nil then
        local serverConnection = g_client:getServerConnection()
        if serverConnection ~= nil then
            print("[FarmersCompetition][SpeedQuest] START REQUEST sending to server")
            serverConnection:sendEvent(CompetitionSpeedQuestStartRequestEvent.new(farmId))
        else
            print("[FarmersCompetition][SpeedQuest] ERROR: serverConnection отсутствует")
        end
    elseif g_server ~= nil then
        print("[FarmersCompetition][SpeedQuest] START REQUEST local server")
        self:handleStartRequest(nil, farmId)
    end
end

-- Назначение: получает реальный farmId игрока из серверного connection.
function CompetitionSpeedQuest:getFarmIdFromConnection(connection, fallbackFarmId)
    if connection ~= nil
        and g_currentMission ~= nil
        and g_currentMission.userManager ~= nil
        and g_farmManager ~= nil then

        local userId = g_currentMission.userManager:getUserIdByConnection(connection)
        if userId ~= nil then
            local farm = g_farmManager:getFarmByUserId(userId)
            if farm ~= nil then
                return farm.farmId, userId
            end
        end
    end

    if connection == nil and g_localPlayer ~= nil then
        return g_localPlayer.farmId, g_localPlayer.userId
    end

    return fallbackFarmId, nil
end

-- Назначение: сервер атомарно валидирует старт и блокирует все стартовые триггеры.
function CompetitionSpeedQuest:handleStartRequest(connection, requestedFarmId)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        print("[FarmersCompetition][SpeedQuest] START REJECT: обработчик вызван не на сервере")
        return
    end

    if self.state ~= CompetitionSpeedQuest.STATE.AVAILABLE then
        print(string.format(
            "[FarmersCompetition][SpeedQuest] START REJECT: questState=%s",
            tostring(self.state)
        ))
        return
    end

    if not self:getIsCompetitionRunning() then
        print("[FarmersCompetition][SpeedQuest] START REJECT: соревнование не RUNNING")
        return
    end

    local farmId, userId = self:getFarmIdFromConnection(connection, requestedFarmId)

    print(string.format(
        "[FarmersCompetition][SpeedQuest] START VALIDATE requestedFarmId=%s actualFarmId=%s userId=%s",
        tostring(requestedFarmId),
        tostring(farmId),
        tostring(userId)
    ))

    if farmId ~= requestedFarmId then
        print("[FarmersCompetition][SpeedQuest] START REJECT: farmId запроса не совпадает с фермой игрока")
        return
    end

    if not self:getCanStartQuest(farmId) then
        print("[FarmersCompetition][SpeedQuest] START REJECT: getCanStartQuest=false")
        return
    end

    self.state = CompetitionSpeedQuest.STATE.PREPARING
    self.activeFarmId = farmId
    self.activeUserId = userId
    self.activeConnection = connection
    self.startTimeMs = nil

    print(string.format(
        "[FarmersCompetition][SpeedQuest] START ACCEPT farmId=%d userId=%s",
        farmId,
        tostring(userId)
    ))

    self:broadcastState()

    if self.questVehicle ~= nil and self.questVehicle.rootNode ~= nil and self.questVehicle.rootNode ~= 0 then
        self:prepareExistingQuestVehicle(farmId)
        self:startRunningAttempt()
    else
        self:spawnQuestVehicle(farmId)
    end
end

-- Назначение: находит зарегистрированный StoreItem по атрибуту vehicleXml.
-- Поддерживает как стандартные пути "$data/...", так и относительные пути карты "maps/...".
function CompetitionSpeedQuest:resolveQuestVehicleStoreItem()
    if self.questVehicleXml == nil or self.questVehicleXml == "" or g_storeManager == nil then
        return nil, nil
    end

    local candidates = {}
    local seen = {}

    local function addCandidate(filename)
        if filename ~= nil and filename ~= "" then
            local key = string.lower(filename)
            if not seen[key] then
                seen[key] = true
                table.insert(candidates, filename)
            end
        end
    end

    -- Сначала оставляем исходное значение: оно может уже совпадать с ключом StoreManager.
    addCandidate(self.questVehicleXml)

    -- StoreManager при регистрации техники сохраняет путь после Utils.getFilename().
    -- Для файлов карты базовой директорией является директория текущего мода.
    if Utils ~= nil and Utils.getFilename ~= nil then
        addCandidate(Utils.getFilename(self.questVehicleXml, g_currentModDirectory or ""))
        addCandidate(Utils.getFilename(self.questVehicleXml, ""))
    end

    for _, filename in ipairs(candidates) do
        local storeItem = g_storeManager:getItemByXMLFilename(filename)
        if storeItem ~= nil then
            return storeItem, filename
        end
    end

    print(string.format(
        "[FarmersCompetition][SpeedQuest] ERROR: StoreItem не найден для vehicleXml='%s'; checked=%s",
        tostring(self.questVehicleXml),
        table.concat(candidates, " | ")
    ))

    return nil, nil
end

-- Назначение: создаёт квестовый трактор в spawnVehicle штатным VehicleLoadingData.
function CompetitionSpeedQuest:spawnQuestVehicle(farmId)
    if self.questVehicleXml == nil or self.questVehicleXml == "" then
        self:cancelPreparingAttempt("vehicleXml не задан")
        return
    end

    local storeItem, resolvedFilename = self:resolveQuestVehicleStoreItem()
    if storeItem == nil then
        self:cancelPreparingAttempt("не найден storeItem квестовой техники")
        return
    end

    print(string.format(
        "[FarmersCompetition][SpeedQuest] VEHICLE STOREITEM resolved raw=%s resolved=%s",
        tostring(self.questVehicleXml),
        tostring(resolvedFilename)
    ))

    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)

    if not loadingData.isValid then
        self:cancelPreparingAttempt("StoreItem найден, но VehicleLoadingData невалиден")
        return
    end

    loadingData:setSpawnNode(self.spawnVehicleNode)
    loadingData:setIgnoreShopOffset(true)
    loadingData:setOwnerFarmId(farmId)
    loadingData:setIsSaved(false)

    self.pendingVehicleLoadingData = loadingData

    print(string.format(
        "[FarmersCompetition][SpeedQuest] VEHICLE LOAD start farmId=%d",
        farmId
    ))

    loadingData:load(self.onQuestVehicleLoaded, self, nil)
end

-- Назначение: завершает асинхронный спавн квестовой техники.
function CompetitionSpeedQuest:onQuestVehicleLoaded(vehicles, loadingState, arguments)
    self.pendingVehicleLoadingData = nil

    print(string.format(
        "[FarmersCompetition][SpeedQuest] VEHICLE LOAD callback state=%s count=%d",
        tostring(loadingState),
        vehicles ~= nil and #vehicles or 0
    ))

    if loadingState ~= VehicleLoadingState.OK or vehicles == nil or vehicles[1] == nil then
        self:cancelPreparingAttempt("ошибка загрузки квестовой техники")
        return
    end

    self.questVehicle = vehicles[1]
    self:prepareExistingQuestVehicle(self.activeFarmId)
    self:startRunningAttempt()
end

-- Назначение: возвращает существующий квестовый трактор в стартовую точку и передаёт его активной ферме.
function CompetitionSpeedQuest:prepareExistingQuestVehicle(farmId)
    local vehicle = self.questVehicle
    if vehicle == nil then
        return
    end

    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end

    if vehicle.setOwnerFarmId ~= nil then
        vehicle:setOwnerFarmId(farmId)
    end

    self:resetQuestVehiclePosition()
end

-- Назначение: начинает серверный отсчёт и переносит игрока к старту трассы.
function CompetitionSpeedQuest:startRunningAttempt()
    if self.state ~= CompetitionSpeedQuest.STATE.PREPARING or self.questVehicle == nil then
        return
    end

    self.state = CompetitionSpeedQuest.STATE.RUNNING
    self.startTimeMs = g_currentMission.time or g_time or 0

    local x, y, z = localToWorld(self.spawnVehicleNode, 0, 0, 4)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.2
    y = math.max(y, terrainY)

    local _, yaw, _ = getWorldRotation(self.spawnVehicleNode)

    -- Сначала переносим игрока к технике как fallback, затем штатно сажаем водителем.
    self:sendTeleport(self.activeConnection, x, y, z, yaw)
    self:sendEnterQuestVehicle(self.activeConnection, self.questVehicle)
    self:broadcastState()

    print(string.format(
        "[FarmersCompetition][SpeedQuest] START farmId=%d userId=%s autoEnterVehicle=true",
        self.activeFarmId,
        tostring(self.activeUserId)
    ))
end

-- Назначение: откатывает неудавшуюся подготовку и снова открывает стартовые триггеры.
function CompetitionSpeedQuest:cancelPreparingAttempt(reason)
    print("[FarmersCompetition][SpeedQuest] ERROR start: " .. tostring(reason))

    self.state = CompetitionSpeedQuest.STATE.AVAILABLE
    self.activeFarmId = 0
    self.activeUserId = nil
    self.activeConnection = nil
    self.startTimeMs = nil

    self:broadcastState()
end

-- Назначение: серверный callback финишной зоны; принимает только активный квестовый трактор.
function CompetitionSpeedQuest:onFinishTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    if not onEnter
        or g_currentMission == nil
        or not g_currentMission:getIsServer()
        or self.state ~= CompetitionSpeedQuest.STATE.RUNNING
        or self.questVehicle == nil then
        return
    end

    local object = g_currentMission.nodeToObject[otherId]
    if object == nil then
        return
    end

    local rootVehicle = object
    if object.getRootVehicle ~= nil then
        rootVehicle = object:getRootVehicle()
    end

    local questRootVehicle = self.questVehicle
    if self.questVehicle.getRootVehicle ~= nil then
        questRootVehicle = self.questVehicle:getRootVehicle()
    end

    if rootVehicle ~= questRootVehicle then
        return
    end

    self:finishAttempt()
end

-- Назначение: рассчитывает плавную награду по серверному времени прохождения.
-- Между 25 и 40 секундами все параметры линейно меняются от максимума к минимуму.
function CompetitionSpeedQuest:getRewardForTime(elapsedSeconds)
    elapsedSeconds = math.max(0, elapsedSeconds or 0)

    if elapsedSeconds > CompetitionSpeedQuest.REWARD_LIMIT_TIME_SECONDS then
        return {
            transportMultiplier = 1,
            workMultiplier = 1,
            durationSeconds = 0
        }
    end

    local timeRange =
        CompetitionSpeedQuest.REWARD_LIMIT_TIME_SECONDS
        - CompetitionSpeedQuest.REWARD_BEST_TIME_SECONDS

    local quality = math.clamp(
        (CompetitionSpeedQuest.REWARD_LIMIT_TIME_SECONDS - elapsedSeconds) / timeRange,
        0,
        1
    )

    local transportMultiplier =
        CompetitionSpeedQuest.REWARD_MIN_TRANSPORT_MULTIPLIER
        + (
            CompetitionSpeedQuest.REWARD_MAX_TRANSPORT_MULTIPLIER
            - CompetitionSpeedQuest.REWARD_MIN_TRANSPORT_MULTIPLIER
        ) * quality

    local workMultiplier =
        CompetitionSpeedQuest.REWARD_MIN_WORK_MULTIPLIER
        + (
            CompetitionSpeedQuest.REWARD_MAX_WORK_MULTIPLIER
            - CompetitionSpeedQuest.REWARD_MIN_WORK_MULTIPLIER
        ) * quality

    local durationSeconds =
        CompetitionSpeedQuest.REWARD_MIN_DURATION_SECONDS
        + (
            CompetitionSpeedQuest.REWARD_MAX_DURATION_SECONDS
            - CompetitionSpeedQuest.REWARD_MIN_DURATION_SECONDS
        ) * quality

    return {
        transportMultiplier = transportMultiplier,
        workMultiplier = workMultiplier,
        durationSeconds = math.floor(durationSeconds + 0.5)
    }
end

-- Назначение: завершает попытку, выдаёт командный boost и запускает его таймер.
function CompetitionSpeedQuest:finishAttempt()
    if self.state ~= CompetitionSpeedQuest.STATE.RUNNING or self.startTimeMs == nil then
        return
    end

    local now = g_currentMission.time or g_time or 0
    local elapsedSeconds = math.max(0, now - self.startTimeMs) * 0.001
    local reward = self:getRewardForTime(elapsedSeconds)

    local finishedFarmId = self.activeFarmId
    local finishedConnection = self.activeConnection

    self:sendPlayerBackToFarm(finishedConnection, finishedFarmId)
    self:sendResult(
        finishedConnection,
        elapsedSeconds,
        reward.transportMultiplier,
        reward.workMultiplier,
        reward.durationSeconds
    )

    self.vehicleDeleteTimer = CompetitionSpeedQuest.VEHICLE_DELETE_DELAY_MS

    if reward.durationSeconds > 0 then
        self.activeBoost = {
            farmId = finishedFarmId,
            transportMultiplier = reward.transportMultiplier,
            workMultiplier = reward.workMultiplier,
            expiresAtMs = now + reward.durationSeconds * 1000
        }

        self.state = CompetitionSpeedQuest.STATE.BOOST_ACTIVE
        self.activeFarmId = finishedFarmId
        self:refreshTransportBoostOnVehicles()
    else
        self.activeBoost = nil
        self.state = CompetitionSpeedQuest.STATE.AVAILABLE
        self.activeFarmId = 0
    end

    print(string.format(
        "[FarmersCompetition][SpeedQuest] FINISH farmId=%d time=%.3f transport=%.2f work=%.2f duration=%d",
        finishedFarmId,
        elapsedSeconds,
        reward.transportMultiplier,
        reward.workMultiplier,
        reward.durationSeconds
    ))

    self.activeUserId = nil
    self.activeConnection = nil
    self.startTimeMs = nil

    self:broadcastState()
end

-- Назначение: вычисляет командную точку возврата по тем же координатам, что использует CompetitionManager.
function CompetitionSpeedQuest:getFarmReturnPosition(farmId)
    if g_competitionManager ~= nil and g_competitionManager.getCompetitionFarmConfig ~= nil then
        local config = g_competitionManager:getCompetitionFarmConfig(farmId)
        if config ~= nil and config.spawnX ~= nil then
            local x = config.spawnX
            local z = -40
            local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.2
            return x, y, z, 0
        end
    end

    return nil
end

-- Назначение: возвращает прошедшего игрока на старт его команды.
function CompetitionSpeedQuest:sendPlayerBackToFarm(connection, farmId)
    local x, y, z, yaw = self:getFarmReturnPosition(farmId)
    if x ~= nil then
        self:sendTeleport(connection, x, y, z, yaw)
    end
end

-- Назначение: сервер-авторитетно переносит только игрока, который проходит квест.
-- Для удалённого клиента изменяется серверный Player, а его dirty state штатно
-- синхронизирует позицию владельцу и остальным клиентам.
function CompetitionSpeedQuest:sendTeleport(connection, x, y, z, yaw)
    local player = nil

    if connection ~= nil
        and g_currentMission ~= nil
        and g_currentMission.connectionsToPlayer ~= nil then
        player = g_currentMission.connectionsToPlayer[connection]
    elseif g_localPlayer ~= nil then
        player = g_localPlayer
    end

    if player == nil then
        print(
            "[FarmersCompetition][SpeedQuest] ERROR: Player для телепорта не найден"
        )
        return
    end

    local currentVehicle =
        player.getCurrentVehicle ~= nil
        and player:getCurrentVehicle()
        or nil

    if currentVehicle ~= nil and player.leaveVehicle ~= nil then
        -- Сервер штатно рассылает VehicleLeaveEvent всем клиентам.
        player:leaveVehicle(currentVehicle, false)
    end

    player:teleportTo(x, y, z, true, true)

    if player.mover ~= nil then
        player.mover:setMovementYaw(yaw)
    end
    if player.graphicsComponent ~= nil then
        player.graphicsComponent:setModelYaw(yaw)
    end

    print(string.format(
        "[FarmersCompetition][SpeedQuest] PLAYER TELEPORT userId=%s remote=%s x=%.2f y=%.2f z=%.2f",
        tostring(player.userId),
        tostring(connection ~= nil),
        x,
        y,
        z
    ))
end

-- Назначение: запускает посадку игрока в квестовую технику.
-- Для удалённого клиента передаётся uniqueId и ожидается локальная синхронизация Vehicle.
function CompetitionSpeedQuest:sendEnterQuestVehicle(connection, vehicle)
    if vehicle == nil then
        return
    end

    if connection ~= nil then
        local vehicleUniqueId =
            vehicle.getUniqueId ~= nil
            and vehicle:getUniqueId()
            or vehicle.uniqueId

        if vehicleUniqueId == nil or vehicleUniqueId == "" then
            print(
                "[FarmersCompetition][SpeedQuest] ERROR: у квестовой техники отсутствует uniqueId"
            )
            return
        end

        connection:sendEvent(
            CompetitionSpeedQuestEnterVehicleEvent.new(
                vehicleUniqueId
            )
        )
    elseif g_localPlayer ~= nil then
        local currentVehicle = g_localPlayer:getCurrentVehicle()

        if currentVehicle ~= nil and currentVehicle ~= vehicle then
            g_localPlayer:leaveVehicle()
        end

        if g_localPlayer:getCurrentVehicle() ~= vehicle then
            print(string.format(
                "[FarmersCompetition][SpeedQuest] ENTER QUEST VEHICLE local request config=%s",
                tostring(vehicle.configFileName)
            ))
            g_localPlayer:requestToEnterVehicle(vehicle, true)
        end
    end
end

-- Назначение: начинает на клиенте ожидание синхронизации квестовой техники.
function CompetitionSpeedQuest:setPendingEnterVehicle(vehicleUniqueId)
    self.pendingEnterVehicleUniqueId = vehicleUniqueId
    self.pendingEnterVehicleTimeoutMs =
        CompetitionSpeedQuest.ENTER_VEHICLE_TIMEOUT_MS

    print(string.format(
        "[FarmersCompetition][SpeedQuest] ENTER PENDING vehicleUniqueId=%s",
        tostring(vehicleUniqueId)
    ))
end

-- Назначение: после появления Vehicle по uniqueId отправляет штатный запрос посадки серверу.
function CompetitionSpeedQuest:updatePendingEnterVehicle(dt)
    if self.pendingEnterVehicleUniqueId == nil
        or g_localPlayer == nil
        or g_currentMission == nil
        or g_currentMission.vehicleSystem == nil then
        return
    end

    self.pendingEnterVehicleTimeoutMs =
        self.pendingEnterVehicleTimeoutMs - dt

    local vehicle =
        g_currentMission.vehicleSystem:getVehicleByUniqueId(
            self.pendingEnterVehicleUniqueId
        )

    if vehicle ~= nil then
        local currentVehicle =
            g_localPlayer:getCurrentVehicle()

        if currentVehicle ~= nil and currentVehicle ~= vehicle then
            g_localPlayer:leaveVehicle()
        end

        if g_localPlayer:getCurrentVehicle() ~= vehicle then
            g_localPlayer:requestToEnterVehicle(vehicle, true)
        end

        print(string.format(
            "[FarmersCompetition][SpeedQuest] ENTER REQUEST vehicleUniqueId=%s config=%s",
            tostring(self.pendingEnterVehicleUniqueId),
            tostring(vehicle.configFileName)
        ))

        self.pendingEnterVehicleUniqueId = nil
        self.pendingEnterVehicleTimeoutMs = 0
        return
    end

    if self.pendingEnterVehicleTimeoutMs <= 0 then
        print(string.format(
            "[FarmersCompetition][SpeedQuest] ERROR: ENTER timeout vehicleUniqueId=%s",
            tostring(self.pendingEnterVehicleUniqueId)
        ))
        self.pendingEnterVehicleUniqueId = nil
        self.pendingEnterVehicleTimeoutMs = 0
    end
end

-- Назначение: сообщает результат только прошедшему игроку.
function CompetitionSpeedQuest:sendResult(connection, elapsedSeconds, transportMultiplier, workMultiplier, durationSeconds)
    local event = CompetitionSpeedQuestResultEvent.new(
        elapsedSeconds,
        transportMultiplier,
        workMultiplier,
        durationSeconds
    )

    if connection ~= nil then
        connection:sendEvent(event)
    else
        event:run({
            getIsServer = function()
                return true
            end
        })
    end
end

-- Назначение: возвращает квестовый трактор к spawnVehicle с нулевой скоростью.
function CompetitionSpeedQuest:resetQuestVehiclePosition()
    local vehicle = self.questVehicle
    if vehicle == nil or self.spawnVehicleNode == nil then
        return
    end

    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end

    if vehicle.components ~= nil then
        for _, component in ipairs(vehicle.components) do
            if component.node ~= nil and component.node ~= 0 then
                setLinearVelocity(component.node, 0, 0, 0)
                setAngularVelocity(component.node, 0, 0, 0)
            end
        end
    end

    local x, y, z = getWorldTranslation(self.spawnVehicleNode)
    local rx, ry, rz = getWorldRotation(self.spawnVehicleNode)

    if vehicle.setAbsolutePosition ~= nil then
        vehicle:setAbsolutePosition(x, y, z, rx, ry, rz)
    end
end


-- Назначение: полностью удаляет временную квестовую технику после окончания попытки.
function CompetitionSpeedQuest:deleteQuestVehicle()
    local vehicle = self.questVehicle
    if vehicle == nil then
        return
    end

    if vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil then
        self.touchedMotors[vehicle.spec_motorized.motor] = nil
    end

    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end

    print(string.format(
        "[FarmersCompetition][SpeedQuest] QUEST VEHICLE DELETE config=%s",
        tostring(vehicle.configFileName)
    ))

    self.questVehicle = nil
    vehicle:delete()
end


-------------------------------------------------------------------------------
-- SPEED BOOST
-------------------------------------------------------------------------------

-- Назначение: возвращает активный transport multiplier для конкретного motor.
function CompetitionSpeedQuest:getTransportMultiplierForMotor(motor)
    if self.activeBoost == nil or motor == nil or motor.vehicle == nil then
        return 1
    end

    local vehicle = motor.vehicle
    local rootVehicle = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if rootVehicle == nil or rootVehicle.getOwnerFarmId == nil then
        return 1
    end

    if rootVehicle:getOwnerFarmId() ~= self.activeBoost.farmId then
        return 1
    end

    return math.max(self.activeBoost.transportMultiplier or 1, 1)
end

-- Назначение: возвращает активный work multiplier для техники выигравшей фермы.
function CompetitionSpeedQuest:getWorkMultiplierForVehicle(vehicle)
    if self.activeBoost == nil or vehicle == nil then
        return 1
    end

    local rootVehicle = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if rootVehicle == nil or rootVehicle.getOwnerFarmId == nil then
        return 1
    end

    if rootVehicle:getOwnerFarmId() ~= self.activeBoost.farmId then
        return 1
    end

    return math.max(self.activeBoost.workMultiplier or 1, 1)
end

-- Назначение: возвращает множитель верхнего предела RPM для transport boost.
-- Значение никогда не опускается ниже 1, поэтому слабые бусты не уменьшают обороты.
function CompetitionSpeedQuest:getRpmMultiplierForMotor(motor)
    local transportMultiplier = self:getTransportMultiplierForMotor(motor)

    if transportMultiplier <= 1 then
        return 1
    end

    return math.max(
        1,
        transportMultiplier / CompetitionSpeedQuest.RPM_BOOST_DIVISOR
    )
end

-- Назначение: возвращает множитель реальной мощности двигателя для выигравшей фермы.
-- Используется максимум transport/work, чтобы коэффициенты не перемножались.
function CompetitionSpeedQuest:getPowerMultiplierForMotor(motor)
    if self.activeBoost == nil or motor == nil or motor.vehicle == nil then
        return 1
    end

    local vehicle = motor.vehicle
    local rootVehicle = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if rootVehicle == nil or rootVehicle.getOwnerFarmId == nil then
        return 1
    end

    if rootVehicle:getOwnerFarmId() ~= self.activeBoost.farmId then
        return 1
    end

    return math.max(
        self.activeBoost.transportMultiplier or 1,
        self.activeBoost.workMultiplier or 1,
        1
    )
end

-- Назначение: передаёт изменённую torque curve из Lua-объекта motor
-- в физический движок GIANTS через штатный Motorized:updateMotorProperties().
-- Без этого расчётные peakMotorPower/peakMotorTorque меняются, а реальная тяга колёс остаётся штатной.
function CompetitionSpeedQuest:refreshPhysicalMotorProperties(motor, reason)
    if motor == nil or motor.vehicle == nil then
        return
    end

    local vehicle = motor.vehicle
    if vehicle.updateMotorProperties == nil
        or vehicle.spec_motorized == nil
        or vehicle.spec_motorized.motorizedNode == nil then
        return
    end

    vehicle:updateMotorProperties()

    print(string.format(
        "[FarmersCompetition][SpeedQuest] MOTOR PHYSICS REFRESH reason=%s farmId=%s config=%s",
        tostring(reason),
        tostring(vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or "?"),
        tostring(vehicle.configFileName)
    ))
end

function CompetitionSpeedQuest:applyTransportBoostToMotor(motor)
    if motor == nil then
        return
    end

    local transportMultiplier = self:getTransportMultiplierForMotor(motor)
    local powerMultiplier = self:getPowerMultiplierForMotor(motor)
    local rpmMultiplier = self:getRpmMultiplierForMotor(motor)

    if transportMultiplier <= 1 and powerMultiplier <= 1 and rpmMultiplier <= 1 then
        local original = self.touchedMotors[motor]
        if original ~= nil then
            local physicalMotorWasBoosted =
                (original.appliedPowerMultiplier or 1) > 1
                or (original.appliedRpmMultiplier or 1) > 1

            motor.peakMotorTorque = original.peakMotorTorque
            motor.peakMotorPower = original.peakMotorPower
            motor.peakMotorPowerRotSpeed = original.peakMotorPowerRotSpeed
            motor.maxClutchTorque = original.maxClutchTorque
            motor.maxRpm = original.maxRpm
            motor.motorRotationAccelerationLimit = original.motorRotationAccelerationLimit

            -- Возвращаем штатные максимальные скорости и диапазоны коробки.
            if motor.setTransmissionDirection ~= nil then
                motor:setTransmissionDirection(motor.transmissionDirection or 1)
            else
                motor.maxForwardSpeed = motor.maxForwardSpeedOrigin or motor.maxForwardSpeed
                motor.maxBackwardSpeed = motor.maxBackwardSpeedOrigin or motor.maxBackwardSpeed
                motor.minForwardGearRatio = motor.minForwardGearRatioOrigin
                motor.maxForwardGearRatio = motor.maxForwardGearRatioOrigin
                motor.minBackwardGearRatio = motor.minBackwardGearRatioOrigin
                motor.maxBackwardGearRatio = motor.maxBackwardGearRatioOrigin
            end

            -- activeBoost уже снят: физический двигатель снова получает штатные RPM/torque.
            if physicalMotorWasBoosted then
                self:refreshPhysicalMotorProperties(motor, "boostRemoved")
            end

            self.touchedMotors[motor] = nil
        end
        return
    end

    local original = self.touchedMotors[motor]
    if original == nil then
        original = {
            peakMotorTorque = motor.peakMotorTorque,
            peakMotorPower = motor.peakMotorPower,
            peakMotorPowerRotSpeed = motor.peakMotorPowerRotSpeed,
            maxClutchTorque = motor.maxClutchTorque,
            maxRpm = motor.maxRpm,
            motorRotationAccelerationLimit = motor.motorRotationAccelerationLimit,
            appliedTransportMultiplier = 1,
            appliedPowerMultiplier = 1,
            appliedRpmMultiplier = 1
        }
        self.touchedMotors[motor] = original
    end

    local physicalMotorChanged =
        math.abs((original.appliedPowerMultiplier or 1) - powerMultiplier) > 0.0001
        or math.abs((original.appliedRpmMultiplier or 1) - rpmMultiplier) > 0.0001

    -- Lua-расчёты двигателя/PowerConsumer.
    motor.peakMotorTorque = original.peakMotorTorque * powerMultiplier
    motor.peakMotorPower = original.peakMotorPower * powerMultiplier * rpmMultiplier
    motor.peakMotorPowerRotSpeed = original.peakMotorPowerRotSpeed * rpmMultiplier
    motor.maxClutchTorque = original.maxClutchTorque * powerMultiplier

    -- Эксперимент 0.1.8: повышаем только верхний предел RPM.
    -- minRpm и PTO ratio остаются штатными.
    motor.maxRpm = original.maxRpm * rpmMultiplier

    -- VehicleMotor.new() рассчитывает этот предел из диапазона minRpm..maxRpm.
    motor.motorRotationAccelerationLimit =
        (motor.maxRpm - motor.minRpm) * math.pi / 30 / 2

    local direction = motor.transmissionDirection or 1

    if direction >= 0 then
        motor.maxForwardSpeed = (motor.maxForwardSpeedOrigin or motor.maxForwardSpeed) * transportMultiplier
        motor.maxBackwardSpeed = (motor.maxBackwardSpeedOrigin or motor.maxBackwardSpeed) * transportMultiplier

        if motor.minForwardGearRatioOrigin ~= nil then
            motor.minForwardGearRatio = motor.minForwardGearRatioOrigin / transportMultiplier
            motor.maxForwardGearRatio = motor.maxForwardGearRatioOrigin
        end
        if motor.minBackwardGearRatioOrigin ~= nil then
            motor.minBackwardGearRatio = motor.minBackwardGearRatioOrigin / transportMultiplier
            motor.maxBackwardGearRatio = motor.maxBackwardGearRatioOrigin
        end
    else
        motor.maxForwardSpeed = (motor.maxBackwardSpeedOrigin or motor.maxForwardSpeed) * transportMultiplier
        motor.maxBackwardSpeed = (motor.maxForwardSpeedOrigin or motor.maxBackwardSpeed) * transportMultiplier

        if motor.minBackwardGearRatioOrigin ~= nil then
            motor.minForwardGearRatio = motor.minBackwardGearRatioOrigin / transportMultiplier
            motor.maxForwardGearRatio = motor.maxBackwardGearRatioOrigin
        end
        if motor.minForwardGearRatioOrigin ~= nil then
            motor.minBackwardGearRatio = motor.minForwardGearRatioOrigin / transportMultiplier
            motor.maxBackwardGearRatio = motor.maxForwardGearRatioOrigin
        end
    end

    if physicalMotorChanged then
        original.appliedPowerMultiplier = powerMultiplier
        original.appliedRpmMultiplier = rpmMultiplier

        self:refreshPhysicalMotorProperties(
            motor,
            string.format(
                "boostApplied power=x%.2f rpm=x%.2f maxRpm=%.0f",
                powerMultiplier,
                rpmMultiplier,
                motor.maxRpm
            )
        )
    end

    original.appliedTransportMultiplier = transportMultiplier
end

-- Назначение: гарантирует рабочий speed-hook для уже созданного экземпляра техники.
-- Если экземпляр создан после обёртки vehicleType, его функция уже правильная и повторно не меняется.
function CompetitionSpeedQuest:ensureWorkSpeedHookOnVehicle(vehicle)
    if vehicle == nil
        or vehicle.getRawSpeedLimit == nil
        or self.workSpeedWrappedVehicles[vehicle] then
        return
    end

    local typeFunction = nil
    if vehicle.type ~= nil and vehicle.type.functions ~= nil then
        typeFunction = vehicle.type.functions.getRawSpeedLimit
    end

    -- Новый экземпляр уже получил обёрнутую функцию из vehicleType.
    if typeFunction ~= nil
        and vehicle.getRawSpeedLimit == typeFunction
        and CompetitionSpeedQuest.workSpeedWrappedTypes ~= nil
        and CompetitionSpeedQuest.workSpeedWrappedTypes[vehicle.type.name] then

        self.workSpeedWrappedVehicles[vehicle] = true
        return
    end

    local originalGetRawSpeedLimit = vehicle.getRawSpeedLimit

    vehicle.getRawSpeedLimit = function(target, ...)
        local limit = originalGetRawSpeedLimit(target, ...)
        local quest = g_competitionSpeedQuest

        if quest ~= nil then
            local multiplier = quest:getWorkMultiplierForVehicle(target)
            if multiplier > 1 and limit ~= math.huge then
                return limit * multiplier
            end
        end

        return limit
    end

    self.workSpeedWrappedVehicles[vehicle] = true
end

-- Назначение: применяет транспортный и силовой boost ко всей моторизованной технике и подхватывает новую.
function CompetitionSpeedQuest:refreshTransportBoostOnVehicles()
    if g_currentMission == nil
        or g_currentMission.vehicleSystem == nil
        or g_currentMission.vehicleSystem.vehicles == nil then
        return
    end

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        self:ensureWorkSpeedHookOnVehicle(vehicle)

        if vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil then
            self:applyTransportBoostToMotor(vehicle.spec_motorized.motor)
        end
    end

    if self.activeBoost == nil then
        for motor, _ in pairs(self.touchedMotors) do
            self:applyTransportBoostToMotor(motor)
        end
    end
end

-- Назначение: устанавливает глобальные, но условные хуки скорости один раз на процесс.
function CompetitionSpeedQuest.installSpeedHooks()
    if CompetitionSpeedQuest.speedHooksInstalled then
        return
    end

    CompetitionSpeedQuest.speedHooksInstalled = true

    -- Реальная мощность: масштабируем torque curve, не изменяя min/max RPM.
    -- При смене коэффициента applyTransportBoostToMotor() вызывает updateMotorProperties(),
    -- поэтому масштабированная кривая реально передаётся в физический движок.
    if VehicleMotor ~= nil and VehicleMotor.getTorqueCurveValue ~= nil then
        CompetitionSpeedQuest.originalGetTorqueCurveValue = VehicleMotor.getTorqueCurveValue

        VehicleMotor.getTorqueCurveValue = function(motor, rpm)
            local quest = g_competitionSpeedQuest
            local sampleRpm = rpm

            if quest ~= nil then
                local original = quest.touchedMotors[motor]
                local rpmMultiplier = quest:getRpmMultiplierForMotor(motor)

                -- Torque curve XML заканчивается штатным диапазоном.
                -- При RPM boost держим последний доступный момент до нового maxRpm.
                if original ~= nil and rpmMultiplier > 1 then
                    sampleRpm = math.min(sampleRpm, original.maxRpm)
                end
            end

            local torque =
                CompetitionSpeedQuest.originalGetTorqueCurveValue(motor, sampleRpm)

            if quest ~= nil then
                torque = torque * quest:getPowerMultiplierForMotor(motor)
            end

            return torque
        end
    end

    -- Motorized:updateMotorProperties() получает torque/speed arrays отсюда.
    -- При RPM boost добавляем конечную точку на повышенном maxRpm,
    -- сохраняя последний штатный момент, уже умноженный на powerMultiplier.
    if VehicleMotor ~= nil and VehicleMotor.getTorqueAndSpeedValues ~= nil then
        CompetitionSpeedQuest.originalGetTorqueAndSpeedValues =
            VehicleMotor.getTorqueAndSpeedValues

        VehicleMotor.getTorqueAndSpeedValues = function(motor, ...)
            local torques, rotationSpeeds =
                CompetitionSpeedQuest.originalGetTorqueAndSpeedValues(motor, ...)

            local quest = g_competitionSpeedQuest
            if quest == nil then
                return torques, rotationSpeeds
            end

            local original = quest.touchedMotors[motor]
            local rpmMultiplier = quest:getRpmMultiplierForMotor(motor)

            if original == nil or rpmMultiplier <= 1 then
                return torques, rotationSpeeds
            end

            local boostedMaxRotSpeed = motor.maxRpm * math.pi / 30
            local lastRotSpeed = rotationSpeeds[#rotationSpeeds] or 0

            if boostedMaxRotSpeed > lastRotSpeed + 0.001 then
                local endTorque =
                    CompetitionSpeedQuest.originalGetTorqueCurveValue(
                        motor,
                        original.maxRpm
                    ) * quest:getPowerMultiplierForMotor(motor)

                table.insert(rotationSpeeds, boostedMaxRotSpeed)
                table.insert(torques, endTorque)
            end

            return torques, rotationSpeeds
        end
    end

    -- Рабочая скорость: Vehicle.registerFunctions копирует getRawSpeedLimit
    -- в каждый vehicleType, поэтому поздняя подмена Vehicle.getRawSpeedLimit недостаточна.
    -- Оборачиваем финальную функцию каждого уже зарегистрированного типа: так сохраняются
    -- все штатные overwritten-функции (PowerConsumer и другие специализации).
    if g_vehicleTypeManager ~= nil and g_vehicleTypeManager.getTypes ~= nil then
        CompetitionSpeedQuest.workSpeedWrappedTypes = CompetitionSpeedQuest.workSpeedWrappedTypes or {}

        for typeName, vehicleType in pairs(g_vehicleTypeManager:getTypes()) do
            if not CompetitionSpeedQuest.workSpeedWrappedTypes[typeName]
                and vehicleType.functions ~= nil
                and vehicleType.functions.getRawSpeedLimit ~= nil then

                local originalGetRawSpeedLimit = vehicleType.functions.getRawSpeedLimit

                vehicleType.functions.getRawSpeedLimit = function(vehicle, ...)
                    local limit = originalGetRawSpeedLimit(vehicle, ...)
                    local quest = g_competitionSpeedQuest

                    if quest ~= nil then
                        local multiplier = quest:getWorkMultiplierForVehicle(vehicle)
                        if multiplier > 1 and limit ~= math.huge then
                            return limit * multiplier
                        end
                    end

                    return limit
                end

                CompetitionSpeedQuest.workSpeedWrappedTypes[typeName] = true
            end
        end
    end

    -- Для ступенчатых КПП minForwardGearRatioOrigin == nil.
    -- Их текущий физический gear ratio уменьшается динамически, расширяя диапазон скорости.
    if VehicleMotor ~= nil and VehicleMotor.getMinMaxGearRatio ~= nil then
        CompetitionSpeedQuest.originalGetMinMaxGearRatio = VehicleMotor.getMinMaxGearRatio

        VehicleMotor.getMinMaxGearRatio = function(motor, ...)
            local minRatio, maxRatio = CompetitionSpeedQuest.originalGetMinMaxGearRatio(motor, ...)
            local quest = g_competitionSpeedQuest

            if quest ~= nil then
                local multiplier = quest:getTransportMultiplierForMotor(motor)
                if multiplier > 1 then
                    local isForward = maxRatio >= 0
                    local hasVariableRatio

                    if isForward then
                        hasVariableRatio = motor.minForwardGearRatioOrigin ~= nil
                    else
                        hasVariableRatio = motor.minBackwardGearRatioOrigin ~= nil
                    end

                    if not hasVariableRatio then
                        if minRatio ~= 0 then
                            minRatio = minRatio / multiplier
                        end
                        if maxRatio ~= 0 then
                            maxRatio = maxRatio / multiplier
                        end
                    end
                end
            end

            return minRatio, maxRatio
        end
    end
end


-- Назначение: возвращает строку активного speed boost для общего HUD бустов.
function CompetitionSpeedQuest:getHudBoostRows()
    if self.activeBoost == nil then
        return {}
    end

    local remainingMs = self:getRemainingBoostMs()
    if remainingMs <= 0 then
        return {}
    end

    return {
        {
            farmId = self.activeBoost.farmId,
            id = "speed",
            sortOrder = 10,
            text = string.format(
                "СКОРОСТЬ ×%.1f  РАБОТА ×%.1f",
                self.activeBoost.transportMultiplier or 1,
                self.activeBoost.workMultiplier or 1
            ),
            remainingMs = remainingMs
        }
    }
end


-------------------------------------------------------------------------------
-- СИНХРОНИЗАЦИЯ СОСТОЯНИЯ
-------------------------------------------------------------------------------

-- Назначение: вычисляет оставшееся серверное время активного буста.
function CompetitionSpeedQuest:getRemainingBoostMs()
    if self.activeBoost == nil then
        return 0
    end

    local now = g_currentMission ~= nil and (g_currentMission.time or g_time or 0) or 0
    return math.max(0, self.activeBoost.expiresAtMs - now)
end

-- Назначение: создаёт сетевой snapshot текущего квеста.
function CompetitionSpeedQuest:createStateEvent()
    local boostFarmId = 0
    local transportMultiplier = 1
    local workMultiplier = 1
    local remainingMs = 0

    if self.activeBoost ~= nil then
        boostFarmId = self.activeBoost.farmId
        transportMultiplier = self.activeBoost.transportMultiplier
        workMultiplier = self.activeBoost.workMultiplier
        remainingMs = self:getRemainingBoostMs()
    end

    return CompetitionSpeedQuestStateEvent.new(
        self.state,
        self.activeFarmId or 0,
        boostFarmId,
        transportMultiplier,
        workMultiplier,
        remainingMs
    )
end

-- Назначение: рассылает всем клиентам новое серверное состояние.
function CompetitionSpeedQuest:broadcastState()
    self:refreshTriggerPresentation()

    if g_server ~= nil then
        g_server:broadcastEvent(self:createStateEvent(), false)
    end
end

-- Назначение: отправляет snapshot одному подключившемуся клиенту.
function CompetitionSpeedQuest:sendStateToConnection(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() or connection == nil then
        return
    end

    connection:sendEvent(self:createStateEvent())
end

-- Назначение: применяет snapshot сервера на клиенте.
function CompetitionSpeedQuest:applyStateFromServer(state, activeFarmId, boostFarmId, transportMultiplier, workMultiplier, remainingMs)
    self.state = state
    self.activeFarmId = activeFarmId or 0

    if boostFarmId ~= nil and boostFarmId > 0 and remainingMs > 0 then
        local now = g_currentMission ~= nil and (g_currentMission.time or g_time or 0) or 0
        self.activeBoost = {
            farmId = boostFarmId,
            transportMultiplier = transportMultiplier,
            workMultiplier = workMultiplier,
            expiresAtMs = now + remainingMs
        }
    else
        self.activeBoost = nil
    end

    self:refreshTriggerPresentation()
    self:refreshTransportBoostOnVehicles()
end


-------------------------------------------------------------------------------
-- MOD EVENT LISTENER
-------------------------------------------------------------------------------

-- Назначение: подготавливает runtime-хуки; узлы карты сканируются после загрузки миссии.
function CompetitionSpeedQuest:loadMap(mapName)
    self.initTimer = CompetitionSpeedQuest.INIT_DELAY_MS
    CompetitionSpeedQuest.installSpeedHooks()

    if CompetitionBoostHUD ~= nil and CompetitionBoostHUD.registerProvider ~= nil then
        CompetitionBoostHUD.registerProvider(self)
    end

    -- Диагностическая команда нужна только на сервере: во время настройки трассы
    -- позволяет разблокировать квест после незавершённой попытки.
    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        addConsoleCommand(
            "fcResetSpeedQuest",
            "Сбросить speed boost quest в состояние AVAILABLE",
            "consoleCommandResetQuest",
            self
        )
        self.consoleCommandRegistered = true
    end
end

-- Назначение: снимает trigger callbacks и возвращает изменённые параметры motor.
function CompetitionSpeedQuest:deleteMap()
    if CompetitionBoostHUD ~= nil and CompetitionBoostHUD.unregisterProvider ~= nil then
        CompetitionBoostHUD.unregisterProvider(self)
    end

    if self.consoleCommandRegistered then
        removeConsoleCommand("fcResetSpeedQuest")
        self.consoleCommandRegistered = false
    end

    if self.initialized then
        if g_currentMission ~= nil and g_currentMission:getIsClient() then
            for _, triggerData in ipairs(self.startTriggers) do
                self:removeTriggerActivatable(triggerData)
                removeTrigger(triggerData.node)
            end
        end

        if g_currentMission ~= nil and g_currentMission:getIsServer() and self.finishTriggerNode ~= nil then
            removeTrigger(self.finishTriggerNode)
        end
    end

    self.activeBoost = nil
    self:refreshTransportBoostOnVehicles()

    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        self:deleteQuestVehicle()
    end

    self.pendingEnterVehicleUniqueId = nil
    self.pendingEnterVehicleTimeoutMs = 0
    self.initialized = false
end


-- Назначение: диагностически сбрасывает попытку/буст без перезагрузки карты.
function CompetitionSpeedQuest:consoleCommandResetQuest()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "Команда доступна только серверу"
    end

    self.activeBoost = nil
    self.state = CompetitionSpeedQuest.STATE.AVAILABLE
    self.activeFarmId = 0
    self.activeUserId = nil
    self.activeConnection = nil
    self.startTimeMs = nil
    self.pendingEnterVehicleUniqueId = nil
    self.pendingEnterVehicleTimeoutMs = 0
    self.vehicleDeleteTimer = nil

    self:deleteQuestVehicle()
    self:refreshTransportBoostOnVehicles()
    self:broadcastState()

    return "Speed boost quest сброшен"
end

-- Назначение: обслуживает инициализацию, удаление квестовой техники и серверный таймер speed boost.
function CompetitionSpeedQuest:update(dt)
    if not self.initialized then
        self.initTimer = self.initTimer - dt
        if self.initTimer <= 0 then
            if not self:initialize() then
                self.initTimer = 1000
            end
        end
        return
    end

    if g_currentMission ~= nil and g_currentMission:getIsClient() and not self.syncRequested then
        self.syncRequested = true
        if g_client ~= nil then
            g_client:getServerConnection():sendEvent(CompetitionSpeedQuestSyncRequestEvent.new())
        end
    end

    if g_currentMission ~= nil
        and g_currentMission:getIsClient() then
        self:updatePendingEnterVehicle(dt)
    end

    -- Основной CompetitionManager меняет WAITING/RUNNING независимо от квеста.
    -- Если игрок вошёл в trigger ещё до старта и остался внутри, нового onEnter не будет.
    -- Поэтому при смене состояния соревнования принудительно пересобираем маркер и F1-action.
    local competitionRunning = self:getIsCompetitionRunning()
    if self.lastCompetitionRunning ~= competitionRunning then
        print(string.format(
            "[FarmersCompetition][SpeedQuest] competitionRunning %s -> %s",
            tostring(self.lastCompetitionRunning),
            tostring(competitionRunning)
        ))
        self.lastCompetitionRunning = competitionRunning
        self:refreshTriggerPresentation()
    end

    if self.vehicleDeleteTimer ~= nil then
        self.vehicleDeleteTimer = self.vehicleDeleteTimer - dt
        if self.vehicleDeleteTimer <= 0 then
            self.vehicleDeleteTimer = nil

            if g_currentMission ~= nil and g_currentMission:getIsServer() then
                self:deleteQuestVehicle()
            end
        end
    end

    self.motorRefreshTimer = self.motorRefreshTimer - dt
    if self.motorRefreshTimer <= 0 then
        self.motorRefreshTimer = CompetitionSpeedQuest.MOTOR_REFRESH_INTERVAL_MS
        self:refreshTransportBoostOnVehicles()
    end

    if g_currentMission ~= nil
        and g_currentMission:getIsServer()
        and self.state == CompetitionSpeedQuest.STATE.BOOST_ACTIVE
        and self.activeBoost ~= nil
        and self:getRemainingBoostMs() <= 0 then

        local expiredFarmId = self.activeBoost.farmId

        self.activeBoost = nil
        self.state = CompetitionSpeedQuest.STATE.AVAILABLE
        self.activeFarmId = 0

        self:refreshTransportBoostOnVehicles()
        self:broadcastState()

        print(string.format(
            "[FarmersCompetition][SpeedQuest] BOOST EXPIRED farmId=%d",
            expiredFarmId
        ))
    end
end

function CompetitionSpeedQuest:draw()
end

function CompetitionSpeedQuest:mouseEvent(posX, posY, isDown, isUp, button)
end

function CompetitionSpeedQuest:keyEvent(unicode, sym, modifier, isDown)
end


g_competitionSpeedQuest = CompetitionSpeedQuest.new()
addModEventListener(g_competitionSpeedQuest)
