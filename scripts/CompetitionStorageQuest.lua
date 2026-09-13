--[[
    FS25 FarmersCompetition - Storage Unlock Quest

    Стартовые триггеры:
        UserAttribute boostName = "storage"
        UserAttribute farmId = 1..4

    Квестовая зона:
        boostStorage
          storageTrigger
          spawns
            spawnVehicle      UserAttribute vehicleXml
            baleStraw         UserAttribute fillType, size
            baleGrass         UserAttribute fillType, size
            palletHoney       UserAttribute fillType

    Разблокируемые объекты:
        UserAttribute boostName = "StorageUnlock"
        UserAttribute farmId = 1..4

    Квест сервер-авторитетный:
      * временная техника и груз создаются на сервере;
      * засчитываются только объекты, созданные текущей попыткой;
      * попытка длится 3 минуты;
      * при результате >= 5 объектов склад команды разблокируется на 10 минут;
      * разблокировка реализована переносом соответствующего map-node на 200 м вниз.
]]

CompetitionStorageQuest = {}
local CompetitionStorageQuest_mt = Class(CompetitionStorageQuest)

CompetitionStorageQuest.VERSION = "0.1.6"

CompetitionStorageQuest.STATE = {
    AVAILABLE = 0,
    PREPARING = 1,
    RUNNING = 2,
    BOOST_ACTIVE = 3
}

CompetitionStorageQuest.INIT_DELAY_MS = 1500
CompetitionStorageQuest.ATTEMPT_DURATION_MS = 180000
CompetitionStorageQuest.BOOST_DURATION_MS = 600000
CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS = 5
CompetitionStorageQuest.ASSET_DELETE_DELAY_MS = 1500
CompetitionStorageQuest.ACCEPTED_OBJECT_DELETE_DELAY_MS = 50
CompetitionStorageQuest.UNLOCK_Y_OFFSET = -200
CompetitionStorageQuest.ENTER_VEHICLE_TIMEOUT_MS = 5000
CompetitionStorageQuest.AVAILABILITY_DELAY_MIN_SECONDS = 20
CompetitionStorageQuest.AVAILABILITY_DELAY_MAX_SECONDS = 180

CompetitionStorageQuest.START_ACTION_TEXT = "Начать испытание склада"
CompetitionStorageQuest.INPUT_ACTION_NAME = "FC_QUEST_ACTIVATE"

-------------------------------------------------------------------------------
-- СЕТЕВЫЕ СОБЫТИЯ
-------------------------------------------------------------------------------

-- Запрос старта storage-квеста от клиента на сервер.
CompetitionStorageQuestStartRequestEvent = {}
local CompetitionStorageQuestStartRequestEvent_mt =
    Class(CompetitionStorageQuestStartRequestEvent, Event)
InitEventClass(
    CompetitionStorageQuestStartRequestEvent,
    "CompetitionStorageQuestStartRequestEvent"
)

function CompetitionStorageQuestStartRequestEvent.emptyNew()
    return Event.new(CompetitionStorageQuestStartRequestEvent_mt)
end

function CompetitionStorageQuestStartRequestEvent.new(farmId)
    local self = CompetitionStorageQuestStartRequestEvent.emptyNew()
    self.farmId = farmId or 0
    return self
end

function CompetitionStorageQuestStartRequestEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
end

function CompetitionStorageQuestStartRequestEvent:readStream(streamId, connection)
    self.farmId =
        streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self:run(connection)
end

-- Назначение: передаёт серверу намерение игрока начать storage-квест.
function CompetitionStorageQuestStartRequestEvent:run(connection)
    if connection:getIsServer() then
        return
    end

    if g_competitionStorageQuest ~= nil then
        g_competitionStorageQuest:handleStartRequest(connection, self.farmId)
    end
end


-- Запрос актуального состояния квеста новым клиентом.
CompetitionStorageQuestSyncRequestEvent = {}
local CompetitionStorageQuestSyncRequestEvent_mt =
    Class(CompetitionStorageQuestSyncRequestEvent, Event)
InitEventClass(
    CompetitionStorageQuestSyncRequestEvent,
    "CompetitionStorageQuestSyncRequestEvent"
)

function CompetitionStorageQuestSyncRequestEvent.emptyNew()
    return Event.new(CompetitionStorageQuestSyncRequestEvent_mt)
end

function CompetitionStorageQuestSyncRequestEvent.new()
    return CompetitionStorageQuestSyncRequestEvent.emptyNew()
end

function CompetitionStorageQuestSyncRequestEvent:writeStream(streamId, connection)
end

function CompetitionStorageQuestSyncRequestEvent:readStream(streamId, connection)
    self:run(connection)
end

-- Назначение: запрашивает у сервера состояние storage-квеста и активной разблокировки.
function CompetitionStorageQuestSyncRequestEvent:run(connection)
    if connection:getIsServer() then
        return
    end

    if g_competitionStorageQuest ~= nil then
        g_competitionStorageQuest:sendStateToConnection(connection)
    end
end


-- Snapshot общего состояния квеста.
CompetitionStorageQuestStateEvent = {}
local CompetitionStorageQuestStateEvent_mt =
    Class(CompetitionStorageQuestStateEvent, Event)
InitEventClass(
    CompetitionStorageQuestStateEvent,
    "CompetitionStorageQuestStateEvent"
)

function CompetitionStorageQuestStateEvent.emptyNew()
    return Event.new(CompetitionStorageQuestStateEvent_mt)
end

function CompetitionStorageQuestStateEvent.new(
    state,
    activeFarmId,
    boostFarmId,
    remainingBoostMs,
    availabilityPending
)
    local self = CompetitionStorageQuestStateEvent.emptyNew()
    self.state = state or CompetitionStorageQuest.STATE.AVAILABLE
    self.activeFarmId = activeFarmId or 0
    self.boostFarmId = boostFarmId or 0
    self.remainingBoostMs = math.max(remainingBoostMs or 0, 0)
    self.availabilityPending = availabilityPending == true
    return self
end

function CompetitionStorageQuestStateEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.state, 2)
    streamWriteUIntN(
        streamId,
        self.activeFarmId,
        FarmManager.FARM_ID_SEND_NUM_BITS
    )
    streamWriteUIntN(
        streamId,
        self.boostFarmId,
        FarmManager.FARM_ID_SEND_NUM_BITS
    )
    streamWriteInt32(streamId, math.floor(self.remainingBoostMs))
    streamWriteBool(streamId, self.availabilityPending)
end

function CompetitionStorageQuestStateEvent:readStream(streamId, connection)
    self.state = streamReadUIntN(streamId, 2)
    self.activeFarmId =
        streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.boostFarmId =
        streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.remainingBoostMs = streamReadInt32(streamId)
    self.availabilityPending = streamReadBool(streamId)
    self:run(connection)
end

-- Назначение: применяет серверное состояние и положение блокирующих объектов.
function CompetitionStorageQuestStateEvent:run(connection)
    if not connection:getIsServer() then
        return
    end

    if g_competitionStorageQuest ~= nil then
        g_competitionStorageQuest:applyStateFromServer(
            self.state,
            self.activeFarmId,
            self.boostFarmId,
            self.remainingBoostMs,
            self.availabilityPending
        )
    end
end


-- Серверная команда конкретному клиенту телепортировать локального игрока.
CompetitionStorageQuestTeleportEvent = {}
local CompetitionStorageQuestTeleportEvent_mt =
    Class(CompetitionStorageQuestTeleportEvent, Event)
InitEventClass(
    CompetitionStorageQuestTeleportEvent,
    "CompetitionStorageQuestTeleportEvent"
)

function CompetitionStorageQuestTeleportEvent.emptyNew()
    return Event.new(CompetitionStorageQuestTeleportEvent_mt)
end

function CompetitionStorageQuestTeleportEvent.new(x, y, z, yaw)
    local self = CompetitionStorageQuestTeleportEvent.emptyNew()
    self.x = x or 0
    self.y = y or 0
    self.z = z or 0
    self.yaw = yaw or 0
    return self
end

function CompetitionStorageQuestTeleportEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.y)
    streamWriteFloat32(streamId, self.z)
    streamWriteFloat32(streamId, self.yaw)
end

function CompetitionStorageQuestTeleportEvent:readStream(streamId, connection)
    self.x = streamReadFloat32(streamId)
    self.y = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self.yaw = streamReadFloat32(streamId)
    self:run(connection)
end

-- Назначение: высаживает локального игрока и переносит его в заданную точку.
function CompetitionStorageQuestTeleportEvent:run(connection)
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


-- Серверная команда посадить игрока в основную квестовую технику.
CompetitionStorageQuestEnterVehicleEvent = {}
local CompetitionStorageQuestEnterVehicleEvent_mt =
    Class(CompetitionStorageQuestEnterVehicleEvent, Event)
InitEventClass(
    CompetitionStorageQuestEnterVehicleEvent,
    "CompetitionStorageQuestEnterVehicleEvent"
)

function CompetitionStorageQuestEnterVehicleEvent.emptyNew()
    return Event.new(CompetitionStorageQuestEnterVehicleEvent_mt)
end

function CompetitionStorageQuestEnterVehicleEvent.new(vehicleUniqueId)
    local self = CompetitionStorageQuestEnterVehicleEvent.emptyNew()
    self.vehicleUniqueId = vehicleUniqueId or ""
    return self
end

function CompetitionStorageQuestEnterVehicleEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.vehicleUniqueId)
end

function CompetitionStorageQuestEnterVehicleEvent:readStream(streamId, connection)
    self.vehicleUniqueId = streamReadString(streamId)
    self:run(connection)
end

-- Назначение: ставит клиенту отложенный запрос посадки.
-- VehicleLoadingData завершает загрузку на сервере раньше, чем новая техника
-- обязательно появится в VehicleSystem удалённого клиента, поэтому NodeObject
-- в этот момент может ещё не разрешаться.
function CompetitionStorageQuestEnterVehicleEvent:run(connection)
    if not connection:getIsServer()
        or g_competitionStorageQuest == nil
        or self.vehicleUniqueId == nil
        or self.vehicleUniqueId == "" then
        return
    end

    g_competitionStorageQuest:setPendingEnterVehicle(
        self.vehicleUniqueId
    )
end


-- Персональный HUD попытки: таймер и число принятых объектов.
CompetitionStorageQuestAttemptUiEvent = {}
local CompetitionStorageQuestAttemptUiEvent_mt =
    Class(CompetitionStorageQuestAttemptUiEvent, Event)
InitEventClass(
    CompetitionStorageQuestAttemptUiEvent,
    "CompetitionStorageQuestAttemptUiEvent"
)

function CompetitionStorageQuestAttemptUiEvent.emptyNew()
    return Event.new(CompetitionStorageQuestAttemptUiEvent_mt)
end

function CompetitionStorageQuestAttemptUiEvent.new(
    isActive,
    remainingMs,
    acceptedCount,
    requiredCount
)
    local self = CompetitionStorageQuestAttemptUiEvent.emptyNew()
    self.isActive = isActive == true
    self.remainingMs = math.max(remainingMs or 0, 0)
    self.acceptedCount = math.max(acceptedCount or 0, 0)
    self.requiredCount = math.max(requiredCount or 0, 0)
    return self
end

function CompetitionStorageQuestAttemptUiEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isActive)
    streamWriteInt32(streamId, math.floor(self.remainingMs))
    streamWriteUInt16(streamId, math.min(self.acceptedCount, 65535))
    streamWriteUInt16(streamId, math.min(self.requiredCount, 65535))
end

function CompetitionStorageQuestAttemptUiEvent:readStream(streamId, connection)
    self.isActive = streamReadBool(streamId)
    self.remainingMs = streamReadInt32(streamId)
    self.acceptedCount = streamReadUInt16(streamId)
    self.requiredCount = streamReadUInt16(streamId)
    self:run(connection)
end

-- Назначение: обновляет HUD только у игрока, который проходит текущую попытку.
function CompetitionStorageQuestAttemptUiEvent:run(connection)
    if not connection:getIsServer() then
        return
    end

    if g_competitionStorageQuest ~= nil then
        g_competitionStorageQuest:applyAttemptUi(
            self.isActive,
            self.remainingMs,
            self.acceptedCount,
            self.requiredCount
        )
    end
end


-- Итог storage-квеста для проходившего игрока.
CompetitionStorageQuestResultEvent = {}
local CompetitionStorageQuestResultEvent_mt =
    Class(CompetitionStorageQuestResultEvent, Event)
InitEventClass(
    CompetitionStorageQuestResultEvent,
    "CompetitionStorageQuestResultEvent"
)

function CompetitionStorageQuestResultEvent.emptyNew()
    return Event.new(CompetitionStorageQuestResultEvent_mt)
end

function CompetitionStorageQuestResultEvent.new(
    acceptedCount,
    requiredCount,
    boostDurationSeconds
)
    local self = CompetitionStorageQuestResultEvent.emptyNew()
    self.acceptedCount = acceptedCount or 0
    self.requiredCount = requiredCount or 0
    self.boostDurationSeconds = boostDurationSeconds or 0
    return self
end

function CompetitionStorageQuestResultEvent:writeStream(streamId, connection)
    streamWriteUInt16(streamId, math.min(self.acceptedCount, 65535))
    streamWriteUInt16(streamId, math.min(self.requiredCount, 65535))
    streamWriteUInt16(streamId, math.min(self.boostDurationSeconds, 65535))
end

function CompetitionStorageQuestResultEvent:readStream(streamId, connection)
    self.acceptedCount = streamReadUInt16(streamId)
    self.requiredCount = streamReadUInt16(streamId)
    self.boostDurationSeconds = streamReadUInt16(streamId)
    self:run(connection)
end

-- Назначение: показывает игроку результат попытки и факт разблокировки склада.
function CompetitionStorageQuestResultEvent:run(connection)
    if not connection:getIsServer() or g_currentMission == nil then
        return
    end

    local text
    if self.boostDurationSeconds > 0 then
        text = string.format(
            "Испытание склада: принято %d объектов. Склад разблокирован на %d мин.",
            self.acceptedCount,
            math.floor(self.boostDurationSeconds / 60)
        )
    else
        text = string.format(
            "Испытание склада: принято %d/%d объектов. Буст не получен.",
            self.acceptedCount,
            self.requiredCount
        )
    end

    if g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(text, 7000)
    else
        print("[FarmersCompetition][StorageQuest] " .. text)
    end
end


-------------------------------------------------------------------------------
-- ACTIVATABLE ДЛЯ F1 / E
-------------------------------------------------------------------------------

CompetitionStorageQuestActivatable = {}
local CompetitionStorageQuestActivatable_mt =
    Class(CompetitionStorageQuestActivatable)

function CompetitionStorageQuestActivatable.new(quest, triggerData)
    local self = setmetatable({}, CompetitionStorageQuestActivatable_mt)
    self.quest = quest
    self.triggerData = triggerData
    self.activateText = CompetitionStorageQuest.START_ACTION_TEXT
    return self
end

-- Назначение: разрешает E только игроку своей фермы при доступном storage-квесте.
function CompetitionStorageQuestActivatable:getIsActivatable()
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

-- Назначение: регистрирует общее действие FC_QUEST_ACTIVATE с текстом storage-квеста.
function CompetitionStorageQuestActivatable:registerCustomInput(inputContext)
    local action = InputAction[CompetitionStorageQuest.INPUT_ACTION_NAME]
    if action == nil then
        print(string.format(
            "[FarmersCompetition][StorageQuest] ERROR: InputAction '%s' не зарегистрирован",
            CompetitionStorageQuest.INPUT_ACTION_NAME
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
        g_inputBinding:setActionEventText(
            actionEventId,
            CompetitionStorageQuest.START_ACTION_TEXT
        )
        g_inputBinding:setActionEventTextPriority(
            actionEventId,
            GS_PRIO_VERY_HIGH
        )
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    end
end

-- Назначение: снимает custom input при выходе из зоны/блокировке квеста.
function CompetitionStorageQuestActivatable:removeCustomInput(inputContext)
    g_inputBinding:removeActionEventsByTarget(self)
    self.actionEventId = nil
end

-- Назначение: обрабатывает нажатие общего E-action.
function CompetitionStorageQuestActivatable:onStartInput(
    actionName,
    inputValue,
    callbackState,
    isAnalog
)
    self:run()
end

-- Назначение: запускает серверный запрос старта storage-квеста.
function CompetitionStorageQuestActivatable:run()
    if self.quest ~= nil and self.triggerData ~= nil then
        print(string.format(
            "[FarmersCompetition][StorageQuest] ACTIVATABLE RUN farmId=%d",
            self.triggerData.farmId or 0
        ))
        self.quest:requestStart(self.triggerData.farmId)
    end
end


-------------------------------------------------------------------------------
-- ОСНОВНОЙ КЛАСС
-------------------------------------------------------------------------------

function CompetitionStorageQuest.new(customMt)
    local self = setmetatable({}, customMt or CompetitionStorageQuest_mt)

    self.state = CompetitionStorageQuest.STATE.AVAILABLE
    self.activeFarmId = 0
    self.activeUserId = nil
    self.activeConnection = nil

    self.startTriggers = {}
    self.questRootNode = nil
    self.storageTriggerNode = nil
    self.spawnsNode = nil
    self.vehicleSpawns = {}
    self.cargoSpawns = {}
    self.unlockNodes = {}

    self.attemptSerial = 0
    self.pendingLoadCount = 0
    self.isSchedulingLoads = false
    self.attemptEndsAtMs = nil
    self.acceptedCount = 0

    self.temporaryVehicles = {}
    self.temporaryVehicleEntries = {}
    self.temporaryCargo = {}
    self.questObjects = {}
    self.acceptedObjects = {}
    self.pendingDeleteObjects = {}
    self.driverVehicle = nil
    self.driverSpawnNode = nil
    self.cleanupTimer = nil

    -- Клиент ждёт появления квестовой машины в локальном VehicleSystem,
    -- затем отправляет штатный VehicleEnterRequestEvent через Player API.
    self.pendingEnterVehicleUniqueId = nil
    self.pendingEnterVehicleTimeoutMs = 0

    self.activeBoost = nil

    -- AVAILABLE не обязательно означает немедленно доступный trigger:
    -- после старта/окончания буста сервер выдерживает случайную задержку.
    self.availabilityPending = false
    self.availabilityEndsAtMs = nil

    self.localAttemptUi = {
        active = false,
        endsAtMs = 0,
        acceptedCount = 0,
        requiredCount = CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS
    }

    self.initialized = false
    self.initTimer = CompetitionStorageQuest.INIT_DELAY_MS
    self.syncRequested = false
    self.consoleCommandRegistered = false
    self.lastCompetitionRunning = nil
    self.sceneConfigurationValid = false

    return self
end

-- Назначение: рекурсивно ищет дочерний узел по имени.
function CompetitionStorageQuest:findChildRecursiveByName(node, targetName)
    if node == nil or node == 0 then
        return nil
    end

    local childCount = getNumOfChildren(node)
    for index = 0, childCount - 1 do
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

-- Назначение: находит внутри стартового trigger любой markerIcon* для его видимости.
function CompetitionStorageQuest:findMarkerRecursive(node)
    if node == nil or node == 0 then
        return nil
    end

    local childCount = getNumOfChildren(node)
    for index = 0, childCount - 1 do
        local child = getChildAt(node, index)
        local name = string.lower(getName(child) or "")
        if string.sub(name, 1, 10) == "markericon" then
            return child
        end

        local nested = self:findMarkerRecursive(child)
        if nested ~= nil then
            return nested
        end
    end

    return nil
end

-- Назначение: рекурсивно собирает точки спавна техники внутри всей зоны boostStorage.
-- spawnVehicle не обязаны находиться внутри группы spawns: эта группа предназначена для груза.
function CompetitionStorageQuest:collectVehicleSpawnNodes(node)
    if node == nil or node == 0 then
        return
    end

    if getName(node) == "spawnVehicle" then
        local vehicleXml = getUserAttribute(node, "vehicleXml")
        if vehicleXml == nil or vehicleXml == "" then
            -- Для совместимости принимаем и стандартное имя UserAttribute xmlFilename.
            vehicleXml = getUserAttribute(node, "xmlFilename")
        end

        table.insert(self.vehicleSpawns, {
            node = node,
            vehicleXml = vehicleXml,
            enterVehicle = getUserAttribute(node, "enterVehicle") == true
        })
    end

    local childCount = getNumOfChildren(node)
    for index = 0, childCount - 1 do
        self:collectVehicleSpawnNodes(getChildAt(node, index))
    end
end

-- Назначение: рекурсивно собирает точки спавна тюков и палет только внутри boostStorage -> spawns.
function CompetitionStorageQuest:collectCargoSpawnNodes(node)
    if node == nil or node == 0 then
        return
    end

    local name = getName(node)

    if name == "baleStraw" or name == "baleGrass" then
        table.insert(self.cargoSpawns, {
            node = node,
            kind = "bale",
            name = name,
            fillTypeName = getUserAttribute(node, "fillType"),
            size = tonumber(getUserAttribute(node, "size"))
        })
    elseif name == "palletHoney" then
        table.insert(self.cargoSpawns, {
            node = node,
            kind = "pallet",
            name = name,
            fillTypeName = getUserAttribute(node, "fillType")
        })
    end

    local childCount = getNumOfChildren(node)
    for index = 0, childCount - 1 do
        self:collectCargoSpawnNodes(getChildAt(node, index))
    end
end

-- Назначение: обходит сцену и собирает стартовые trigger, квестовую зону и StorageUnlock.
function CompetitionStorageQuest:scanScene(node)
    if node == nil or node == 0 then
        return
    end

    local boostName = getUserAttribute(node, "boostName")
    local farmId = tonumber(getUserAttribute(node, "farmId"))

    if boostName == "storage"
        and farmId ~= nil
        and farmId >= 1
        and farmId <= 4 then

        table.insert(self.startTriggers, {
            node = node,
            farmId = farmId,
            markerNode = self:findMarkerRecursive(node),
            isLocalPlayerInside = false,
            activatableRegistered = false
        })
    elseif boostName == "StorageUnlock"
        and farmId ~= nil
        and farmId >= 1
        and farmId <= 4 then

        local x, y, z = getTranslation(node)
        self.unlockNodes[farmId] = {
            node = node,
            originalX = x,
            originalY = y,
            originalZ = z
        }
    end

    if getName(node) == "boostStorage" then
        local candidateStorageTrigger =
            self:findChildRecursiveByName(node, "storageTrigger")
        local candidateSpawns =
            self:findChildRecursiveByName(node, "spawns")

        -- Если в сцене случайно есть несколько групп с одинаковым именем,
        -- используем именно ту boostStorage, где присутствуют обе обязательные части.
        if candidateStorageTrigger ~= nil and candidateSpawns ~= nil then
            if self.questRootNode == nil then
                self.questRootNode = node
                self.storageTriggerNode = candidateStorageTrigger
                self.spawnsNode = candidateSpawns
            end
        else
            print(string.format(
                "[FarmersCompetition][StorageQuest] CONFIG candidate boostStorage node=%s storageTrigger=%s spawns=%s",
                tostring(node),
                tostring(candidateStorageTrigger ~= nil),
                tostring(candidateSpawns ~= nil)
            ))
        end
    end

    local childCount = getNumOfChildren(node)
    for index = 0, childCount - 1 do
        self:scanScene(getChildAt(node, index))
    end
end

-- Назначение: проверяет обязательные UserAttributes точек спавна.
function CompetitionStorageQuest:validateSpawnConfiguration()
    local valid = true

    if #self.vehicleSpawns == 0 then
        print("[FarmersCompetition][StorageQuest] ERROR: внутри boostStorage не найден spawnVehicle")
        valid = false
    end

    if #self.vehicleSpawns ~= 3 then
        print(string.format(
            "[FarmersCompetition][StorageQuest] WARNING: найдено spawnVehicle=%d, ожидалось 3",
            #self.vehicleSpawns
        ))
    end

    for index, spawnData in ipairs(self.vehicleSpawns) do
        if spawnData.vehicleXml == nil or spawnData.vehicleXml == "" then
            print(string.format(
                "[FarmersCompetition][StorageQuest] ERROR: spawnVehicle #%d без UserAttribute vehicleXml",
                index
            ))
            valid = false
        end
    end

    if #self.cargoSpawns == 0 then
        print("[FarmersCompetition][StorageQuest] ERROR: не найдены baleStraw/baleGrass/palletHoney")
        valid = false
    end

    for _, spawnData in ipairs(self.cargoSpawns) do
        if spawnData.fillTypeName == nil or spawnData.fillTypeName == "" then
            print(string.format(
                "[FarmersCompetition][StorageQuest] ERROR: %s без UserAttribute fillType",
                tostring(spawnData.name)
            ))
            valid = false
        end

        if spawnData.kind == "bale"
            and (spawnData.size == nil or spawnData.size <= 0) then
            print(string.format(
                "[FarmersCompetition][StorageQuest] ERROR: %s имеет некорректный UserAttribute size=%s",
                tostring(spawnData.name),
                tostring(spawnData.size)
            ))
            valid = false
        end
    end

    if #self.cargoSpawns < CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS then
        print(string.format(
            "[FarmersCompetition][StorageQuest] WARNING: cargoSpawns=%d меньше минимального результата %d",
            #self.cargoSpawns,
            CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS
        ))
    end

    for index, spawnData in ipairs(self.vehicleSpawns) do
        print(string.format(
            "[FarmersCompetition][StorageQuest] CONFIG vehicleSpawn[%d] node=%s vehicleXml=%s enterVehicle=%s",
            index,
            tostring(spawnData.node),
            tostring(spawnData.vehicleXml),
            tostring(spawnData.enterVehicle)
        ))
    end

    for index, spawnData in ipairs(self.cargoSpawns) do
        print(string.format(
            "[FarmersCompetition][StorageQuest] CONFIG cargoSpawn[%d] name=%s kind=%s fillType=%s size=%s",
            index,
            tostring(spawnData.name),
            tostring(spawnData.kind),
            tostring(spawnData.fillTypeName),
            tostring(spawnData.size)
        ))
    end

    return valid
end

-- Назначение: возвращает количество найденных StorageUnlock-объектов.
function CompetitionStorageQuest:getUnlockNodeCount()
    local count = 0
    for _ in pairs(self.unlockNodes) do
        count = count + 1
    end
    return count
end

-- Назначение: регистрирует стартовые trigger storage-квеста после полной загрузки миссии.
-- Стартовый Activatable регистрируется независимо от конфигурации награды/спавнов:
-- эти части проверяются отдельно при фактическом запросе старта.
function CompetitionStorageQuest:initialize()
    if self.initialized
        or g_currentMission == nil
        or not g_currentMission.isLoaded then
        return false
    end

    self.startTriggers = {}
    self.vehicleSpawns = {}
    self.cargoSpawns = {}
    self.unlockNodes = {}
    self.questRootNode = nil
    self.storageTriggerNode = nil
    self.spawnsNode = nil

    self:scanScene(getRootNode())

    -- Без стартового trigger сам Activatable создать невозможно — это единственная
    -- причина, по которой инициализацию целиком откладываем.
    if #self.startTriggers == 0 then
        print("[FarmersCompetition][StorageQuest] ERROR: не найден ни один boostName='storage' trigger")
        return false
    end

    self.sceneConfigurationValid =
        self.questRootNode ~= nil
        and self.storageTriggerNode ~= nil
        and self.spawnsNode ~= nil

    self.spawnConfigurationValid = false

    if not self.sceneConfigurationValid then
        print(string.format(
            "[FarmersCompetition][StorageQuest] ERROR CONFIG STRUCTURE: boostStorage=%s spawns=%s storageTrigger=%s",
            tostring(self.questRootNode ~= nil),
            tostring(self.spawnsNode ~= nil),
            tostring(self.storageTriggerNode ~= nil)
        ))
    else
        -- Техника находится в общей зоне boostStorage, а груз — в отдельной группе spawns.
        self:collectVehicleSpawnNodes(self.questRootNode)
        self:collectCargoSpawnNodes(self.spawnsNode)
        self.spawnConfigurationValid = self:validateSpawnConfiguration()
    end

    if g_currentMission:getIsClient() then
        for _, triggerData in ipairs(self.startTriggers) do
            triggerData.activatable =
                CompetitionStorageQuestActivatable.new(self, triggerData)
            addTrigger(triggerData.node, "onStartTriggerCallback", self)
        end
    end

    if g_currentMission:getIsServer() and self.storageTriggerNode ~= nil then
        addTrigger(
            self.storageTriggerNode,
            "onStorageTriggerCallback",
            self
        )
    end

    self.initialized = true
    self.lastCompetitionRunning = self:getIsCompetitionRunning()
    self:applyUnlockState(
        self.activeBoost ~= nil and self.activeBoost.farmId or 0
    )
    self:refreshTriggerPresentation()

    print(string.format(
        "[FarmersCompetition][StorageQuest] Инициализация version=%s startTriggers=%d vehicles=%d cargo=%d unlockNodes=%d structureValid=%s spawnValid=%s competitionRunning=%s",
        CompetitionStorageQuest.VERSION,
        #self.startTriggers,
        #self.vehicleSpawns,
        #self.cargoSpawns,
        self:getUnlockNodeCount(),
        tostring(self.sceneConfigurationValid),
        tostring(self.spawnConfigurationValid),
        tostring(self.lastCompetitionRunning)
    ))

    return true
end

-- Назначение: проверяет состояние RUNNING основного соревнования.
function CompetitionStorageQuest:getIsCompetitionRunning()
    return g_competitionManager ~= nil
        and CompetitionUtils ~= nil
        and g_competitionManager.state == CompetitionUtils.STATE.RUNNING
end

-- Назначение: сервер ставит storage-квест на случайную задержку 20..180 секунд.
-- Используется при старте/возобновлении соревнования и после окончания storage boost.
function CompetitionStorageQuest:scheduleAvailability(reason)
    if g_currentMission == nil
        or not g_currentMission:getIsServer()
        or self.state ~= CompetitionStorageQuest.STATE.AVAILABLE
        or self.activeBoost ~= nil then
        return false
    end

    local delaySeconds = math.random(
        CompetitionStorageQuest.AVAILABILITY_DELAY_MIN_SECONDS,
        CompetitionStorageQuest.AVAILABILITY_DELAY_MAX_SECONDS
    )
    local now = g_currentMission.time or g_time or 0

    self.availabilityPending = true
    self.availabilityEndsAtMs = now + delaySeconds * 1000
    self:broadcastState()

    print(string.format(
        "[FarmersCompetition][StorageQuest] AVAILABILITY SCHEDULED reason=%s delay=%ds",
        tostring(reason),
        delaySeconds
    ))

    return true
end

-- Назначение: завершает ожидание, открывает trigger/F1 и оповещает всех игроков gong.
function CompetitionStorageQuest:activateAvailability(reason)
    if g_currentMission == nil
        or not g_currentMission:getIsServer()
        or self.state ~= CompetitionStorageQuest.STATE.AVAILABLE then
        return false
    end

    self.availabilityPending = false
    self.availabilityEndsAtMs = nil
    self:broadcastState()

    if g_competitionManager ~= nil
        and g_competitionManager.broadcastNotificationSound ~= nil then
        g_competitionManager:broadcastNotificationSound("gong")
    end

    print(string.format(
        "[FarmersCompetition][StorageQuest] AVAILABLE reason=%s",
        tostring(reason)
    ))

    return true
end

-- Назначение: обслуживает серверный таймер отложенной доступности storage-квеста.
function CompetitionStorageQuest:updateAvailabilityTimer()
    if g_currentMission == nil
        or not g_currentMission:getIsServer()
        or self.availabilityPending ~= true
        or self.state ~= CompetitionStorageQuest.STATE.AVAILABLE
        or not self:getIsCompetitionRunning() then
        return
    end

    local now = g_currentMission.time or g_time or 0
    if self.availabilityEndsAtMs == nil or now >= self.availabilityEndsAtMs then
        self:activateAvailability("timerExpired")
    end
end

-- Назначение: проверяет, существует ли стартовый trigger указанной команды.
function CompetitionStorageQuest:hasStartTriggerForFarm(farmId)
    for _, triggerData in ipairs(self.startTriggers) do
        if triggerData.farmId == farmId then
            return true
        end
    end

    return false
end

-- Назначение: проверяет только условия показа/активации стартового E-action.
-- Конфигурация boostStorage и StorageUnlock не должна скрывать сам Activatable:
-- она валидируется сервером непосредственно при запросе старта.
function CompetitionStorageQuest:getCanStartQuest(farmId)
    return self.initialized
        and self.state == CompetitionStorageQuest.STATE.AVAILABLE
        and self.availabilityPending ~= true
        and self.cleanupTimer == nil
        and self:getIsCompetitionRunning()
        and farmId ~= nil
        and farmId >= 1
        and farmId <= 4
        and self:hasStartTriggerForFarm(farmId)
end

-- Назначение: callback входа/выхода локального игрока в стартовый trigger.
function CompetitionStorageQuest:onStartTriggerCallback(
    triggerId,
    otherId,
    onEnter,
    onLeave,
    onStay
)
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

    if onEnter or onStay then
        triggerData.isLocalPlayerInside = true
        self:refreshSingleTriggerActivatable(triggerData)
    elseif onLeave then
        triggerData.isLocalPlayerInside = false
        self:removeTriggerActivatable(triggerData)
    end
end

-- Назначение: добавляет или снимает F1-action для одного стартового trigger.
function CompetitionStorageQuest:refreshSingleTriggerActivatable(triggerData)
    if g_currentMission == nil
        or g_currentMission.activatableObjectsSystem == nil then
        return
    end

    local shouldRegister =
        triggerData.isLocalPlayerInside == true
        and g_localPlayer ~= nil
        and g_localPlayer.farmId == triggerData.farmId
        and self:getCanStartQuest(triggerData.farmId)

    if shouldRegister and not triggerData.activatableRegistered then
        g_currentMission.activatableObjectsSystem:addActivatable(
            triggerData.activatable
        )
        triggerData.activatableRegistered = true

        print(string.format(
            "[FarmersCompetition][StorageQuest] F1 activatable ON farmId=%d structureValid=%s spawnValid=%s unlockNode=%s",
            triggerData.farmId,
            tostring(self.sceneConfigurationValid),
            tostring(self.spawnConfigurationValid),
            tostring(self.unlockNodes[triggerData.farmId] ~= nil)
        ))
    elseif not shouldRegister and triggerData.activatableRegistered then
        self:removeTriggerActivatable(triggerData)
    end
end

-- Назначение: снимает F1-action стартового trigger.
function CompetitionStorageQuest:removeTriggerActivatable(triggerData)
    if triggerData.activatableRegistered
        and g_currentMission ~= nil
        and g_currentMission.activatableObjectsSystem ~= nil then

        g_currentMission.activatableObjectsSystem:removeActivatable(
            triggerData.activatable
        )
    end

    triggerData.activatableRegistered = false
end

-- Назначение: обновляет markerIcon* и F1-action всех стартов storage-квеста.
function CompetitionStorageQuest:refreshTriggerPresentation()
    local isAvailable =
        self.state == CompetitionStorageQuest.STATE.AVAILABLE
        and self.availabilityPending ~= true
        and self.cleanupTimer == nil
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

-- Назначение: отправляет серверу запрос старта storage-квеста.
function CompetitionStorageQuest:requestStart(farmId)
    if not self:getCanStartQuest(farmId) then
        return
    end

    if g_client ~= nil then
        local serverConnection = g_client:getServerConnection()
        if serverConnection ~= nil then
            serverConnection:sendEvent(
                CompetitionStorageQuestStartRequestEvent.new(farmId)
            )
        end
    elseif g_server ~= nil then
        self:handleStartRequest(nil, farmId)
    end
end

-- Назначение: получает реальный farmId и userId серверного connection.
function CompetitionStorageQuest:getFarmIdFromConnection(
    connection,
    fallbackFarmId
)
    if connection ~= nil
        and g_currentMission ~= nil
        and g_currentMission.userManager ~= nil
        and g_farmManager ~= nil then

        local userId =
            g_currentMission.userManager:getUserIdByConnection(connection)
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

-- Назначение: сервер валидирует старт и начинает подготовку временных объектов.
function CompetitionStorageQuest:handleStartRequest(
    connection,
    requestedFarmId
)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end

    if self.state ~= CompetitionStorageQuest.STATE.AVAILABLE
        or self.cleanupTimer ~= nil
        or not self:getIsCompetitionRunning() then
        return
    end

    local farmId, userId =
        self:getFarmIdFromConnection(connection, requestedFarmId)

    if farmId ~= requestedFarmId or not self:getCanStartQuest(farmId) then
        print(string.format(
            "[FarmersCompetition][StorageQuest] START REJECT requestedFarmId=%s actualFarmId=%s",
            tostring(requestedFarmId),
            tostring(farmId)
        ))
        return
    end

    -- Ошибки квестовой зоны/наград диагностируем здесь, а не через исчезновение E.
    if not self.sceneConfigurationValid then
        print(string.format(
            "[FarmersCompetition][StorageQuest] START REJECT CONFIG STRUCTURE farmId=%d boostStorage=%s spawns=%s storageTrigger=%s",
            farmId,
            tostring(self.questRootNode ~= nil),
            tostring(self.spawnsNode ~= nil),
            tostring(self.storageTriggerNode ~= nil)
        ))
        return
    end

    if not self.spawnConfigurationValid then
        print(string.format(
            "[FarmersCompetition][StorageQuest] START REJECT CONFIG SPAWNS farmId=%d vehicles=%d cargo=%d",
            farmId,
            #self.vehicleSpawns,
            #self.cargoSpawns
        ))
        return
    end

    if self.unlockNodes[farmId] == nil then
        print(string.format(
            "[FarmersCompetition][StorageQuest] START REJECT CONFIG farmId=%d: не найден boostName='StorageUnlock' с этим farmId",
            farmId
        ))
        return
    end

    self.attemptSerial = self.attemptSerial + 1
    self.state = CompetitionStorageQuest.STATE.PREPARING
    self.availabilityPending = false
    self.availabilityEndsAtMs = nil
    self.activeFarmId = farmId
    self.activeUserId = userId
    self.activeConnection = connection
    self.attemptEndsAtMs = nil
    self.acceptedCount = 0

    self:resetAttemptCollections()
    self:broadcastState()

    print(string.format(
        "[FarmersCompetition][StorageQuest] START ACCEPT farmId=%d userId=%s attempt=%d",
        farmId,
        tostring(userId),
        self.attemptSerial
    ))

    self:prepareAttemptAssets(self.attemptSerial)
end


-------------------------------------------------------------------------------
-- СОЗДАНИЕ ВРЕМЕННЫХ ОБЪЕКТОВ
-------------------------------------------------------------------------------

-- Назначение: очищает таблицы объектов новой попытки.
function CompetitionStorageQuest:resetAttemptCollections()
    self.pendingLoadCount = 0
    self.isSchedulingLoads = false
    self.temporaryVehicles = {}
    self.temporaryVehicleEntries = {}
    self.temporaryCargo = {}
    self.questObjects = {}
    self.acceptedObjects = {}
    self.pendingDeleteObjects = {}
    self.driverVehicle = nil
    self.driverSpawnNode = nil
end

-- Назначение: находит зарегистрированный StoreItem для vehicleXml.
function CompetitionStorageQuest:resolveVehicleStoreItem(vehicleXml)
    if vehicleXml == nil or vehicleXml == "" or g_storeManager == nil then
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

    addCandidate(vehicleXml)

    if Utils ~= nil and Utils.getFilename ~= nil then
        addCandidate(Utils.getFilename(
            vehicleXml,
            g_currentModDirectory or ""
        ))
        addCandidate(Utils.getFilename(vehicleXml, ""))
    end

    for _, filename in ipairs(candidates) do
        local storeItem = g_storeManager:getItemByXMLFilename(filename)
        if storeItem ~= nil then
            return storeItem, filename
        end
    end

    return nil, nil
end

-- Назначение: создаёт полностью заполненный круглый тюк указанного fillType/диаметра.
function CompetitionStorageQuest:spawnQuestBale(spawnData, farmId)
    local fillTypeIndex =
        g_fillTypeManager:getFillTypeIndexByName(spawnData.fillTypeName)

    if fillTypeIndex == nil then
        return nil, string.format(
            "неизвестный fillType '%s' для %s",
            tostring(spawnData.fillTypeName),
            tostring(spawnData.name)
        )
    end

    -- UserAttribute size на карте удобно задавать в сантиметрах (например 125),
    -- тогда как BaleManager хранит и сравнивает диаметр в метрах (1.25).
    -- Для совместимости сначала пробуем значение как есть, затем для size >= 10
    -- автоматически переводим сантиметры в метры.
    local requestedSize = spawnData.size
    local resolvedDiameter = requestedSize

    local baleXml =
        g_baleManager:getBaleXMLFilename(
            fillTypeIndex,
            true,
            nil,
            nil,
            nil,
            resolvedDiameter,
            nil
        )

    if baleXml == nil and requestedSize >= 10 then
        resolvedDiameter = requestedSize / 100

        baleXml =
            g_baleManager:getBaleXMLFilename(
                fillTypeIndex,
                true,
                nil,
                nil,
                nil,
                resolvedDiameter,
                nil
            )
    end

    if baleXml == nil then
        return nil, string.format(
            "не найден круглый тюк fillType=%s size=%s (проверен diameter=%.2f м)",
            tostring(spawnData.fillTypeName),
            tostring(requestedSize),
            resolvedDiameter
        )
    end

    local x, y, z = getWorldTranslation(spawnData.node)
    local rx, ry, rz = getWorldRotation(spawnData.node)

    local bale = Bale.new(
        g_currentMission:getIsServer(),
        g_currentMission:getIsClient()
    )

    if not bale:loadFromConfigXML(
        baleXml,
        x,
        y,
        z,
        rx,
        ry,
        rz
    ) then
        bale:delete()
        return nil, "Bale:loadFromConfigXML() вернул false"
    end

    -- Временный тюк принадлежит команде, поэтому остаётся доступным для вил.
    -- needsSaving=false одновременно не даёт сохранить его в savegame и исключает
    -- из текущего CompetitionProgress, который учитывает только getNeedsSaving()==true.
    bale.competitionQuestStorageObject = true
    bale:setFillType(fillTypeIndex, true)
    bale:setOwnerFarmId(farmId, true)
    if bale.setNeedsSaving ~= nil then
        bale:setNeedsSaving(false)
    end
    bale:register()

    self.questObjects[bale] = true
    table.insert(self.temporaryCargo, bale)

    print(string.format(
        "[FarmersCompetition][StorageQuest] BALE SPAWN name=%s fillType=%s size=%s diameter=%.2fm farmId=%d",
        tostring(spawnData.name),
        tostring(spawnData.fillTypeName),
        tostring(spawnData.size),
        resolvedDiameter,
        farmId
    ))

    return bale, nil
end

-- Назначение: запускает асинхронный спавн палеты по palletFilename нужного fillType.
function CompetitionStorageQuest:spawnQuestPallet(
    spawnData,
    farmId,
    attemptId
)
    local fillTypeIndex =
        g_fillTypeManager:getFillTypeIndexByName(spawnData.fillTypeName)

    if fillTypeIndex == nil then
        return false, string.format(
            "неизвестный fillType '%s' для %s",
            tostring(spawnData.fillTypeName),
            tostring(spawnData.name)
        )
    end

    local fillTypeDesc =
        g_fillTypeManager.indexToFillType[fillTypeIndex]

    if fillTypeDesc == nil
        or fillTypeDesc.palletFilename == nil
        or fillTypeDesc.palletFilename == "" then
        return false, string.format(
            "для fillType '%s' отсутствует palletFilename",
            tostring(spawnData.fillTypeName)
        )
    end

    local x, y, z = getWorldTranslation(spawnData.node)
    local rx, ry, rz = getWorldRotation(spawnData.node)

    local loadingData = VehicleLoadingData.new()
    loadingData:setFilename(fillTypeDesc.palletFilename)
    loadingData:setPosition(x, y, z)
    loadingData:setRotation(rx, ry, rz)
    loadingData:setPropertyState(VehiclePropertyState.OWNED)
    loadingData:setOwnerFarmId(farmId)
    loadingData:setIsSaved(false)

    self.pendingLoadCount = self.pendingLoadCount + 1
    loadingData:load(
        self.onTemporaryObjectLoaded,
        self,
        {
            attemptId = attemptId,
            kind = "pallet",
            spawnData = spawnData,
            fillTypeIndex = fillTypeIndex,
            farmId = farmId
        }
    )

    return true, nil
end

-- Назначение: запускает асинхронный спавн единицы квестовой техники/инструмента.
function CompetitionStorageQuest:spawnQuestVehicle(
    spawnData,
    farmId,
    attemptId
)
    local storeItem, resolvedFilename =
        self:resolveVehicleStoreItem(spawnData.vehicleXml)

    if storeItem == nil then
        return false, string.format(
            "StoreItem не найден для vehicleXml='%s'",
            tostring(spawnData.vehicleXml)
        )
    end

    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)

    if not loadingData.isValid then
        return false, string.format(
            "VehicleLoadingData невалиден для '%s'",
            tostring(resolvedFilename)
        )
    end

    loadingData:setSpawnNode(spawnData.node)
    loadingData:setIgnoreShopOffset(true)
    loadingData:setOwnerFarmId(farmId)
    loadingData:setIsSaved(false)

    self.pendingLoadCount = self.pendingLoadCount + 1
    loadingData:load(
        self.onTemporaryObjectLoaded,
        self,
        {
            attemptId = attemptId,
            kind = "vehicle",
            spawnData = spawnData
        }
    )

    print(string.format(
        "[FarmersCompetition][StorageQuest] VEHICLE LOAD raw=%s resolved=%s",
        tostring(spawnData.vehicleXml),
        tostring(resolvedFilename)
    ))

    return true, nil
end

-- Назначение: создаёт все тюки/палеты/технику до запуска трёхминутного таймера.
function CompetitionStorageQuest:prepareAttemptAssets(attemptId)
    if self.state ~= CompetitionStorageQuest.STATE.PREPARING
        or attemptId ~= self.attemptSerial then
        return
    end

    self.isSchedulingLoads = true

    for _, spawnData in ipairs(self.cargoSpawns) do
        if spawnData.kind == "bale" then
            local _, errorMessage =
                self:spawnQuestBale(spawnData, self.activeFarmId)

            if errorMessage ~= nil then
                self.isSchedulingLoads = false
                self:cancelPreparingAttempt(errorMessage)
                return
            end
        end
    end

    for _, spawnData in ipairs(self.cargoSpawns) do
        if spawnData.kind == "pallet" then
            local ok, errorMessage =
                self:spawnQuestPallet(
                    spawnData,
                    self.activeFarmId,
                    attemptId
                )

            if not ok then
                self.isSchedulingLoads = false
                self:cancelPreparingAttempt(errorMessage)
                return
            end
        end
    end

    for _, spawnData in ipairs(self.vehicleSpawns) do
        local ok, errorMessage =
            self:spawnQuestVehicle(
                spawnData,
                self.activeFarmId,
                attemptId
            )

        if not ok then
            self.isSchedulingLoads = false
            self:cancelPreparingAttempt(errorMessage)
            return
        end
    end

    self.isSchedulingLoads = false
    self:checkPreparationComplete()
end

-- Назначение: принимает результат VehicleLoadingData для палет и техники.
function CompetitionStorageQuest:onTemporaryObjectLoaded(
    vehicles,
    loadingState,
    arguments
)
    local object = vehicles ~= nil and vehicles[1] or nil
    local attemptId = arguments ~= nil and arguments.attemptId or -1

    if attemptId ~= self.attemptSerial
        or self.state ~= CompetitionStorageQuest.STATE.PREPARING then

        if vehicles ~= nil then
            for _, staleObject in ipairs(vehicles) do
                if staleObject ~= nil and staleObject.delete ~= nil then
                    staleObject:delete()
                end
            end
        end
        return
    end

    self.pendingLoadCount = math.max(0, self.pendingLoadCount - 1)

    if loadingState ~= VehicleLoadingState.OK or object == nil then
        self:cancelPreparingAttempt(
            "ошибка VehicleLoadingData для "
            .. tostring(arguments ~= nil and arguments.kind or "object")
        )
        return
    end

    if arguments.kind == "pallet" then
        -- PalletSpawner FS25 тоже создаёт палету пустой и заполняет её отдельным
        -- addFillUnitFillLevel(). Для квеста сразу доводим палету до полной ёмкости.
        local fillUnitIndex =
            object.spec_pallet ~= nil
            and object.spec_pallet.fillUnitIndex
            or 1
        local capacity =
            object.getFillUnitCapacity ~= nil
            and object:getFillUnitCapacity(fillUnitIndex)
            or 0

        if object.emptyAllFillUnits ~= nil then
            object:emptyAllFillUnits(true)
        end

        local appliedFillLevel = 0
        if capacity > 0 and object.addFillUnitFillLevel ~= nil then
            appliedFillLevel = object:addFillUnitFillLevel(
                arguments.farmId or self.activeFarmId,
                fillUnitIndex,
                capacity,
                arguments.fillTypeIndex,
                ToolType.UNDEFINED
            )
        end

        object.competitionQuestStorageObject = true
        self.questObjects[object] = true
        table.insert(self.temporaryCargo, object)

        print(string.format(
            "[FarmersCompetition][StorageQuest] PALLET SPAWN fillType=%s farmId=%d fillUnit=%d capacity=%.1f filled=%.1f",
            tostring(arguments.spawnData.fillTypeName),
            arguments.farmId or self.activeFarmId,
            fillUnitIndex,
            capacity,
            appliedFillLevel or 0
        ))
    else
        table.insert(self.temporaryVehicles, object)
        table.insert(self.temporaryVehicleEntries, {
            vehicle = object,
            spawnData = arguments.spawnData
        })
    end

    if not self.isSchedulingLoads then
        self:checkPreparationComplete()
    end
end

-- Назначение: выбирает водительскую технику после завершения всех загрузок.
function CompetitionStorageQuest:selectDriverVehicle()
    local fallback = nil

    for _, entry in ipairs(self.temporaryVehicleEntries) do
        local vehicle = entry.vehicle
        if vehicle ~= nil and vehicle.spec_enterable ~= nil then
            if fallback == nil then
                fallback = entry
            end

            if entry.spawnData.enterVehicle == true then
                return entry
            end
        end
    end

    return fallback
end

-- Назначение: запускает попытку только когда вся временная техника/палеты готовы.
function CompetitionStorageQuest:checkPreparationComplete()
    if self.state ~= CompetitionStorageQuest.STATE.PREPARING
        or self.isSchedulingLoads
        or self.pendingLoadCount > 0 then
        return
    end

    local driverEntry = self:selectDriverVehicle()
    if driverEntry == nil then
        self:cancelPreparingAttempt(
            "среди spawnVehicle не найдено техники со specialization Enterable"
        )
        return
    end

    self.driverVehicle = driverEntry.vehicle
    self.driverSpawnNode = driverEntry.spawnData.node
    self:startRunningAttempt()
end


-------------------------------------------------------------------------------
-- ПОПЫТКА И ПРИЁМ ОБЪЕКТОВ
-------------------------------------------------------------------------------

-- Назначение: запускает серверный таймер 3 минуты и переносит игрока в технику.
function CompetitionStorageQuest:startRunningAttempt()
    if self.state ~= CompetitionStorageQuest.STATE.PREPARING
        or self.driverVehicle == nil
        or self.driverSpawnNode == nil then
        return
    end

    local now = g_currentMission.time or g_time or 0

    self.state = CompetitionStorageQuest.STATE.RUNNING
    self.attemptEndsAtMs =
        now + CompetitionStorageQuest.ATTEMPT_DURATION_MS

    local x, y, z =
        localToWorld(self.driverSpawnNode, 0, 0, 4)
    local terrainY =
        getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.2
    y = math.max(y, terrainY)

    local _, yaw, _ = getWorldRotation(self.driverSpawnNode)

    self:sendTeleport(self.activeConnection, x, y, z, yaw)
    self:sendEnterQuestVehicle(
        self.activeConnection,
        self.driverVehicle
    )
    self:sendAttemptUi(
        self.activeConnection,
        true,
        CompetitionStorageQuest.ATTEMPT_DURATION_MS,
        self.acceptedCount
    )

    self:broadcastState()

    print(string.format(
        "[FarmersCompetition][StorageQuest] RUNNING farmId=%d attempt=%d duration=%.0fs",
        self.activeFarmId,
        self.attemptSerial,
        CompetitionStorageQuest.ATTEMPT_DURATION_MS / 1000
    ))
end

-- Назначение: ищет квестовый объект по collision-node, поднимаясь по родителям.
function CompetitionStorageQuest:getQuestObjectFromNode(node)
    local current = node

    while current ~= nil and current ~= 0 do
        local object = g_currentMission:getNodeObject(current)
        if object ~= nil and self.questObjects[object] == true then
            return object
        end

        current = getParent(current)
    end

    return nil
end

-- Назначение: сервер засчитывает один созданный квестом тюк/палету при входе в storageTrigger.
function CompetitionStorageQuest:onStorageTriggerCallback(
    triggerId,
    otherId,
    onEnter,
    onLeave,
    onStay
)
    if not onEnter
        or self.state ~= CompetitionStorageQuest.STATE.RUNNING
        or g_currentMission == nil
        or not g_currentMission:getIsServer() then
        return
    end

    local object = self:getQuestObjectFromNode(otherId)
    if object == nil or self.acceptedObjects[object] == true then
        return
    end

    self.acceptedObjects[object] = true
    self.questObjects[object] = nil
    self.acceptedCount = self.acceptedCount + 1

    table.insert(self.pendingDeleteObjects, {
        object = object,
        delayMs = CompetitionStorageQuest.ACCEPTED_OBJECT_DELETE_DELAY_MS
    })

    self:sendAttemptUi(
        self.activeConnection,
        true,
        self:getRemainingAttemptMs(),
        self.acceptedCount
    )

    print(string.format(
        "[FarmersCompetition][StorageQuest] ACCEPT farmId=%d count=%d/%d object=%s",
        self.activeFarmId,
        self.acceptedCount,
        CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS,
        tostring(object.configFileName or object.xmlFilename or object.className)
    ))
end

-- Назначение: возвращает оставшееся серверное время текущей попытки.
function CompetitionStorageQuest:getRemainingAttemptMs()
    if self.state ~= CompetitionStorageQuest.STATE.RUNNING
        or self.attemptEndsAtMs == nil then
        return 0
    end

    local now = g_currentMission ~= nil
        and (g_currentMission.time or g_time or 0)
        or 0

    return math.max(0, self.attemptEndsAtMs - now)
end

-- Назначение: завершает попытку строго по истечении трёх минут.
function CompetitionStorageQuest:finishAttemptByTimeout()
    if self.state ~= CompetitionStorageQuest.STATE.RUNNING then
        return
    end

    local now = g_currentMission.time or g_time or 0
    local finishedFarmId = self.activeFarmId
    local finishedConnection = self.activeConnection
    local acceptedCount = self.acceptedCount
    local success =
        acceptedCount >= CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS

    self:sendAttemptUi(
        finishedConnection,
        false,
        0,
        acceptedCount
    )
    self:sendPlayerBackToFarm(
        finishedConnection,
        finishedFarmId
    )
    self:sendResult(
        finishedConnection,
        acceptedCount,
        success and (CompetitionStorageQuest.BOOST_DURATION_MS / 1000) or 0
    )

    self.attemptEndsAtMs = nil
    self.cleanupTimer =
        CompetitionStorageQuest.ASSET_DELETE_DELAY_MS

    if success then
        self.activeBoost = {
            farmId = finishedFarmId,
            expiresAtMs =
                now + CompetitionStorageQuest.BOOST_DURATION_MS
        }
        self.state = CompetitionStorageQuest.STATE.BOOST_ACTIVE
        self.activeFarmId = finishedFarmId
        self:applyUnlockState(finishedFarmId)
    else
        self.activeBoost = nil
        self.state = CompetitionStorageQuest.STATE.AVAILABLE
        self.availabilityPending = false
        self.availabilityEndsAtMs = nil
        self.activeFarmId = 0
        self:applyUnlockState(0)
    end

    print(string.format(
        "[FarmersCompetition][StorageQuest] FINISH farmId=%d accepted=%d required=%d success=%s boostSeconds=%d",
        finishedFarmId,
        acceptedCount,
        CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS,
        tostring(success),
        success and (CompetitionStorageQuest.BOOST_DURATION_MS / 1000) or 0
    ))

    self.activeUserId = nil
    self.activeConnection = nil
    self:broadcastState()
end

-- Назначение: откатывает неудавшуюся подготовку до запуска таймера.
function CompetitionStorageQuest:cancelPreparingAttempt(reason)
    print(
        "[FarmersCompetition][StorageQuest] ERROR start: "
        .. tostring(reason)
    )

    self.attemptSerial = self.attemptSerial + 1
    self.state = CompetitionStorageQuest.STATE.AVAILABLE
    self.availabilityPending = false
    self.availabilityEndsAtMs = nil
    self.activeFarmId = 0
    self.activeUserId = nil
    self.activeConnection = nil
    self.attemptEndsAtMs = nil
    self.pendingLoadCount = 0
    self.isSchedulingLoads = false

    self:deleteAttemptAssets()
    self:broadcastState()
end


-------------------------------------------------------------------------------
-- РАЗБЛОКИРОВКА СКЛАДА
-------------------------------------------------------------------------------

-- Назначение: переносит StorageUnlock выбранной команды на 200 м вниз,
-- а все остальные блокирующие объекты возвращает в исходную позицию.
function CompetitionStorageQuest:applyUnlockState(unlockedFarmId)
    for farmId, data in pairs(self.unlockNodes) do
        if data.node ~= nil and data.node ~= 0 then
            local y = data.originalY
            if unlockedFarmId ~= nil and farmId == unlockedFarmId then
                y = y + CompetitionStorageQuest.UNLOCK_Y_OFFSET
            end

            setTranslation(
                data.node,
                data.originalX,
                y,
                data.originalZ
            )
        end
    end
end

-- Назначение: вычисляет оставшееся время активной разблокировки.
function CompetitionStorageQuest:getRemainingBoostMs()
    if self.activeBoost == nil then
        return 0
    end

    local now = g_currentMission ~= nil
        and (g_currentMission.time or g_time or 0)
        or 0

    return math.max(0, self.activeBoost.expiresAtMs - now)
end

-- Назначение: отдаёт строку активной разблокировки общему CompetitionBoostHUD.
function CompetitionStorageQuest:getHudBoostRows()
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
            id = "storage",
            sortOrder = 20,
            text = "СКЛАД РАЗБЛОКИРОВАН",
            remainingMs = remainingMs
        }
    }
end


-------------------------------------------------------------------------------
-- ТЕЛЕПОРТ, UI И РЕЗУЛЬТАТ
-------------------------------------------------------------------------------

-- Назначение: вычисляет командную точку возврата через CompetitionManager.
function CompetitionStorageQuest:getFarmReturnPosition(farmId)
    if g_competitionManager ~= nil
        and g_competitionManager.getCompetitionFarmConfig ~= nil then

        local config =
            g_competitionManager:getCompetitionFarmConfig(farmId)

        if config ~= nil and config.spawnX ~= nil then
            local x = config.spawnX
            local z = -40
            local y =
                getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.2
            return x, y, z, 0
        end
    end

    return nil
end

-- Назначение: возвращает игрока в стартовую точку его команды.
function CompetitionStorageQuest:sendPlayerBackToFarm(connection, farmId)
    local x, y, z, yaw =
        self:getFarmReturnPosition(farmId)

    if x ~= nil then
        self:sendTeleport(connection, x, y, z, yaw)
    end
end

-- Назначение: сервер-авторитетно переносит только проходящего квест игрока.
-- Для удалённого клиента меняем серверный Player: его dirty state штатно
-- синхронизирует позицию обратно владельцу и остальным клиентам.
function CompetitionStorageQuest:sendTeleport(
    connection,
    x,
    y,
    z,
    yaw
)
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
            "[FarmersCompetition][StorageQuest] ERROR: Player для телепорта не найден"
        )
        return
    end

    local currentVehicle =
        player.getCurrentVehicle ~= nil
        and player:getCurrentVehicle()
        or nil

    if currentVehicle ~= nil and player.leaveVehicle ~= nil then
        -- На сервере VehicleLeaveEvent рассылается штатно всем клиентам.
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
        "[FarmersCompetition][StorageQuest] PLAYER TELEPORT userId=%s remote=%s x=%.2f y=%.2f z=%.2f",
        tostring(player.userId),
        tostring(connection ~= nil),
        x,
        y,
        z
    ))
end

-- Назначение: запускает посадку проходящего игрока в квестовую технику.
-- Удалённому клиенту передаём uniqueId и ждём локальной синхронизации Vehicle.
function CompetitionStorageQuest:sendEnterQuestVehicle(
    connection,
    vehicle
)
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
                "[FarmersCompetition][StorageQuest] ERROR: у квестовой техники отсутствует uniqueId"
            )
            return
        end

        connection:sendEvent(
            CompetitionStorageQuestEnterVehicleEvent.new(
                vehicleUniqueId
            )
        )
    elseif g_localPlayer ~= nil then
        local currentVehicle =
            g_localPlayer:getCurrentVehicle()

        if currentVehicle ~= nil and currentVehicle ~= vehicle then
            g_localPlayer:leaveVehicle()
        end

        if g_localPlayer:getCurrentVehicle() ~= vehicle then
            g_localPlayer:requestToEnterVehicle(vehicle, true)
        end
    end
end

-- Назначение: начинает на клиенте ожидание синхронизации квестовой техники.
function CompetitionStorageQuest:setPendingEnterVehicle(vehicleUniqueId)
    self.pendingEnterVehicleUniqueId = vehicleUniqueId
    self.pendingEnterVehicleTimeoutMs =
        CompetitionStorageQuest.ENTER_VEHICLE_TIMEOUT_MS

    print(string.format(
        "[FarmersCompetition][StorageQuest] ENTER PENDING vehicleUniqueId=%s",
        tostring(vehicleUniqueId)
    ))
end

-- Назначение: после появления Vehicle по uniqueId отправляет штатный запрос посадки серверу.
function CompetitionStorageQuest:updatePendingEnterVehicle(dt)
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
            "[FarmersCompetition][StorageQuest] ENTER REQUEST vehicleUniqueId=%s config=%s",
            tostring(self.pendingEnterVehicleUniqueId),
            tostring(vehicle.configFileName)
        ))

        self.pendingEnterVehicleUniqueId = nil
        self.pendingEnterVehicleTimeoutMs = 0
        return
    end

    if self.pendingEnterVehicleTimeoutMs <= 0 then
        print(string.format(
            "[FarmersCompetition][StorageQuest] ERROR: ENTER timeout vehicleUniqueId=%s",
            tostring(self.pendingEnterVehicleUniqueId)
        ))
        self.pendingEnterVehicleUniqueId = nil
        self.pendingEnterVehicleTimeoutMs = 0
    end
end

-- Назначение: отправляет персональное состояние трёхминутного HUD.
function CompetitionStorageQuest:sendAttemptUi(
    connection,
    isActive,
    remainingMs,
    acceptedCount
)
    local event = CompetitionStorageQuestAttemptUiEvent.new(
        isActive,
        remainingMs,
        acceptedCount,
        CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS
    )

    if connection ~= nil then
        connection:sendEvent(event)
    else
        self:applyAttemptUi(
            isActive,
            remainingMs,
            acceptedCount,
            CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS
        )
    end
end

-- Назначение: включает/обновляет локальный HUD попытки.
function CompetitionStorageQuest:applyAttemptUi(
    isActive,
    remainingMs,
    acceptedCount,
    requiredCount
)
    local now = g_currentMission ~= nil
        and (g_currentMission.time or g_time or 0)
        or 0

    self.localAttemptUi.active = isActive == true
    self.localAttemptUi.endsAtMs =
        now + math.max(remainingMs or 0, 0)
    self.localAttemptUi.acceptedCount =
        acceptedCount or 0
    self.localAttemptUi.requiredCount =
        requiredCount or CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS
end

-- Назначение: отправляет итог только игроку, который проходил storage-квест.
function CompetitionStorageQuest:sendResult(
    connection,
    acceptedCount,
    boostDurationSeconds
)
    local event = CompetitionStorageQuestResultEvent.new(
        acceptedCount,
        CompetitionStorageQuest.MIN_ACCEPTED_OBJECTS,
        boostDurationSeconds
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


-------------------------------------------------------------------------------
-- УДАЛЕНИЕ ВРЕМЕННЫХ ОБЪЕКТОВ
-------------------------------------------------------------------------------

-- Назначение: безопасно удаляет ещё существующий Bale/Vehicle.
function CompetitionStorageQuest:deleteTemporaryObject(object)
    if object == nil or object.delete == nil then
        return
    end

    local node = object.rootNode or object.nodeId
    if node ~= nil and node ~= 0 and entityExists(node) then
        object:delete()
    end
end

-- Назначение: удаляет временный груз и всю технику текущей попытки.
function CompetitionStorageQuest:deleteAttemptAssets()
    for _, object in ipairs(self.temporaryCargo) do
        self:deleteTemporaryObject(object)
    end

    for _, vehicle in ipairs(self.temporaryVehicles) do
        self:deleteTemporaryObject(vehicle)
    end

    self.temporaryCargo = {}
    self.temporaryVehicles = {}
    self.temporaryVehicleEntries = {}
    self.questObjects = {}
    self.acceptedObjects = {}
    self.pendingDeleteObjects = {}
    self.driverVehicle = nil
    self.driverSpawnNode = nil
    self.pendingLoadCount = 0
end

-- Назначение: удаляет принятые storageTrigger объекты после выхода из trigger callback.
function CompetitionStorageQuest:updatePendingObjectDeletes(dt)
    for index = #self.pendingDeleteObjects, 1, -1 do
        local entry = self.pendingDeleteObjects[index]
        entry.delayMs = entry.delayMs - dt

        if entry.delayMs <= 0 then
            self:deleteTemporaryObject(entry.object)
            table.remove(self.pendingDeleteObjects, index)
        end
    end
end


-------------------------------------------------------------------------------
-- СИНХРОНИЗАЦИЯ
-------------------------------------------------------------------------------

-- Назначение: создаёт snapshot состояния квеста/разблокировки.
function CompetitionStorageQuest:createStateEvent()
    local boostFarmId = 0
    local remainingBoostMs = 0

    if self.activeBoost ~= nil then
        boostFarmId = self.activeBoost.farmId
        remainingBoostMs = self:getRemainingBoostMs()
    end

    return CompetitionStorageQuestStateEvent.new(
        self.state,
        self.activeFarmId or 0,
        boostFarmId,
        remainingBoostMs,
        self.availabilityPending
    )
end

-- Назначение: рассылает состояние всем клиентам и обновляет локальные trigger.
function CompetitionStorageQuest:broadcastState()
    self:refreshTriggerPresentation()

    if g_server ~= nil then
        g_server:broadcastEvent(self:createStateEvent(), false)
    end
end

-- Назначение: отправляет snapshot одному подключившемуся клиенту.
function CompetitionStorageQuest:sendStateToConnection(connection)
    if g_currentMission == nil
        or not g_currentMission:getIsServer()
        or connection == nil then
        return
    end

    connection:sendEvent(self:createStateEvent())
end

-- Назначение: применяет snapshot сервера на клиенте.
function CompetitionStorageQuest:applyStateFromServer(
    state,
    activeFarmId,
    boostFarmId,
    remainingBoostMs,
    availabilityPending
)
    self.state = state
    self.activeFarmId = activeFarmId or 0
    self.availabilityPending = availabilityPending == true
    self.availabilityEndsAtMs = nil

    if boostFarmId ~= nil
        and boostFarmId > 0
        and remainingBoostMs > 0 then

        local now = g_currentMission ~= nil
            and (g_currentMission.time or g_time or 0)
            or 0

        self.activeBoost = {
            farmId = boostFarmId,
            expiresAtMs = now + remainingBoostMs
        }
    else
        self.activeBoost = nil
    end

    self:applyUnlockState(
        self.activeBoost ~= nil and self.activeBoost.farmId or 0
    )
    self:refreshTriggerPresentation()
end


-------------------------------------------------------------------------------
-- MOD EVENT LISTENER
-------------------------------------------------------------------------------

-- Назначение: подготавливает storage-квест и общий HUD бустов.
function CompetitionStorageQuest:loadMap(mapName)
    self.initTimer = CompetitionStorageQuest.INIT_DELAY_MS

    if CompetitionBoostHUD ~= nil
        and CompetitionBoostHUD.registerProvider ~= nil then
        CompetitionBoostHUD.registerProvider(self)
    end

    if g_currentMission ~= nil
        and g_currentMission:getIsServer() then

        addConsoleCommand(
            "fcResetStorageQuest",
            "Сбросить storage quest в AVAILABLE и вернуть блокировку склада",
            "consoleCommandResetQuest",
            self
        )
        self.consoleCommandRegistered = true
    end
end

-- Назначение: снимает trigger callbacks, возвращает StorageUnlock и удаляет временные объекты.
function CompetitionStorageQuest:deleteMap()
    if CompetitionBoostHUD ~= nil
        and CompetitionBoostHUD.unregisterProvider ~= nil then
        CompetitionBoostHUD.unregisterProvider(self)
    end

    if self.consoleCommandRegistered then
        removeConsoleCommand("fcResetStorageQuest")
        self.consoleCommandRegistered = false
    end

    if self.initialized then
        if g_currentMission ~= nil
            and g_currentMission:getIsClient() then

            for _, triggerData in ipairs(self.startTriggers) do
                self:removeTriggerActivatable(triggerData)
                removeTrigger(triggerData.node)
            end
        end

        if g_currentMission ~= nil
            and g_currentMission:getIsServer()
            and self.storageTriggerNode ~= nil then
            removeTrigger(self.storageTriggerNode)
        end
    end

    self.localAttemptUi.active = false
    self.pendingEnterVehicleUniqueId = nil
    self.pendingEnterVehicleTimeoutMs = 0
    self.availabilityPending = false
    self.availabilityEndsAtMs = nil
    self.activeBoost = nil
    self:applyUnlockState(0)

    if g_currentMission ~= nil
        and g_currentMission:getIsServer() then
        self.attemptSerial = self.attemptSerial + 1
        self:deleteAttemptAssets()
    end

    self.initialized = false
end

-- Назначение: диагностически сбрасывает попытку/буст без перезагрузки карты.
function CompetitionStorageQuest:consoleCommandResetQuest()
    if g_currentMission == nil
        or not g_currentMission:getIsServer() then
        return "Команда доступна только серверу"
    end

    if self.state == CompetitionStorageQuest.STATE.RUNNING then
        self:sendAttemptUi(
            self.activeConnection,
            false,
            0,
            self.acceptedCount
        )
        self:sendPlayerBackToFarm(
            self.activeConnection,
            self.activeFarmId
        )
    end

    self.attemptSerial = self.attemptSerial + 1
    self.activeBoost = nil
    self.state = CompetitionStorageQuest.STATE.AVAILABLE
    self.availabilityPending = false
    self.availabilityEndsAtMs = nil
    self.activeFarmId = 0
    self.activeUserId = nil
    self.activeConnection = nil
    self.attemptEndsAtMs = nil
    self.cleanupTimer = nil
    self.acceptedCount = 0
    self.pendingEnterVehicleUniqueId = nil
    self.pendingEnterVehicleTimeoutMs = 0

    self:applyUnlockState(0)
    self:deleteAttemptAssets()
    self:broadcastState()

    return "Storage quest сброшен"
end

-- Назначение: обслуживает подготовку, трёхминутную попытку, cleanup и 10-минутный boost.
function CompetitionStorageQuest:update(dt)
    if not self.initialized then
        self.initTimer = self.initTimer - dt
        if self.initTimer <= 0 then
            if not self:initialize() then
                self.initTimer = 1000
            end
        end
        return
    end

    if g_currentMission ~= nil
        and g_currentMission:getIsClient()
        and not self.syncRequested then

        self.syncRequested = true
        if g_client ~= nil then
            g_client:getServerConnection():sendEvent(
                CompetitionStorageQuestSyncRequestEvent.new()
            )
        end
    end

    if g_currentMission ~= nil
        and g_currentMission:getIsClient() then
        self:updatePendingEnterVehicle(dt)
    end

    local competitionRunning = self:getIsCompetitionRunning()
    if self.lastCompetitionRunning ~= competitionRunning then
        self.lastCompetitionRunning = competitionRunning
        self:refreshTriggerPresentation()
    end

    if g_currentMission ~= nil
        and g_currentMission:getIsServer() then

        self:updatePendingObjectDeletes(dt)
        self:updateAvailabilityTimer()

        if self.cleanupTimer ~= nil then
            self.cleanupTimer = self.cleanupTimer - dt
            if self.cleanupTimer <= 0 then
                self.cleanupTimer = nil
                self:deleteAttemptAssets()

                if self.state == CompetitionStorageQuest.STATE.AVAILABLE then
                    self:broadcastState()
                else
                    self:refreshTriggerPresentation()
                end
            end
        end

        if self.state == CompetitionStorageQuest.STATE.RUNNING
            and self:getRemainingAttemptMs() <= 0 then
            self:finishAttemptByTimeout()
        end

        if self.state == CompetitionStorageQuest.STATE.BOOST_ACTIVE
            and self.activeBoost ~= nil
            and self:getRemainingBoostMs() <= 0 then

            local expiredFarmId = self.activeBoost.farmId

            self.activeBoost = nil
            self.state = CompetitionStorageQuest.STATE.AVAILABLE
            self.activeFarmId = 0
            self:applyUnlockState(0)
            self:scheduleAvailability("boostExpired")

            print(string.format(
                "[FarmersCompetition][StorageQuest] BOOST EXPIRED farmId=%d",
                expiredFarmId
            ))
        end
    end
end

-- Назначение: рисует персональный таймер попытки и текущий счёт без фона.
function CompetitionStorageQuest:draw()
    if self.localAttemptUi.active ~= true
        or g_currentMission == nil then
        return
    end

    local now = g_currentMission.time or g_time or 0
    local remainingMs =
        math.max(0, self.localAttemptUi.endsAtMs - now)
    local totalSeconds =
        math.max(0, math.ceil(remainingMs * 0.001))
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds % 60

    local text = string.format(
        "СКЛАД  %02d:%02d    ПРИНЯТО: %d/%d",
        minutes,
        seconds,
        self.localAttemptUi.acceptedCount,
        self.localAttemptUi.requiredCount
    )

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    renderText(0.5, 0.89, 0.018, text)

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

function CompetitionStorageQuest:mouseEvent(
    posX,
    posY,
    isDown,
    isUp,
    button
)
end

function CompetitionStorageQuest:keyEvent(
    unicode,
    sym,
    modifier,
    isDown
)
end


g_competitionStorageQuest = CompetitionStorageQuest.new()
addModEventListener(g_competitionStorageQuest)
