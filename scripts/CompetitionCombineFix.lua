--[[
    FS25 FarmersCompetition - Combine straw flow fix

    Исправляет две подтверждённые потери материала в штатной специализации Combine:
    1. При укладке валка Combine списывает запрошенный объём, а не фактически
       размещённый DensityMapHeightUtil.tipToGroundAroundLine().
    2. При переключении измельчителя/валка штатный код очищает processing buffer.

    Важно: недоложенная солома хранится только в processing input buffer.
    Временный workAreaParameters.litersToDrop не переносит тот же остаток второй раз,
    что исключает двойной учёт материала.

    Файлы игры не изменяются. Все исправления устанавливаются runtime-хуками.
]]

CompetitionCombineFix = CompetitionCombineFix or {}
CompetitionCombineFix.VERSION = "0.1.1"
CompetitionCombineFix.installed = CompetitionCombineFix.installed or false
CompetitionCombineFix.activeSwathContext = nil
CompetitionCombineFix.pendingSwathCarryRemovalByVehicle =
    CompetitionCombineFix.pendingSwathCarryRemovalByVehicle or setmetatable({}, {__mode = "k"})

-- Выводит информационное сообщение с единым префиксом мода.
local function logInfo(message, ...)
    local text = string.format(message, ...)
    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("[FarmersCompetition] %s", text)
    else
        print(string.format("[FarmersCompetition] %s", text))
    end
end

-- Выводит предупреждение с единым префиксом мода.
local function logWarning(message, ...)
    local text = string.format(message, ...)
    if Logging ~= nil and Logging.warning ~= nil then
        Logging.warning("[FarmersCompetition] %s", text)
    else
        print(string.format("[FarmersCompetition] WARNING: %s", text))
    end
end

-- Возвращает внутренний processing input buffer комбайна.
function CompetitionCombineFix:getInputBuffer(vehicle)
    if vehicle == nil
        or vehicle.spec_combine == nil
        or vehicle.spec_combine.processing == nil then
        return nil
    end

    return vehicle.spec_combine.processing.inputBuffer
end

-- Сохраняет только количество литров в слотах processing buffer.
-- Остальные служебные поля GIANTS намеренно не изменяются.
function CompetitionCombineFix:captureBufferLiters(vehicle)
    local inputBuffer = self:getInputBuffer(vehicle)
    if inputBuffer == nil or inputBuffer.buffer == nil then
        return nil, 0
    end

    local snapshot = {}
    local total = 0

    for index = 1, #inputBuffer.buffer do
        local liters = inputBuffer.buffer[index].liters or 0
        snapshot[index] = liters
        total = total + liters
    end

    return snapshot, total
end

-- Восстанавливает сохранённые литры processing buffer.
-- Используется только для отмены штатной очистки буфера при смене режима.
function CompetitionCombineFix:restoreBufferLiters(vehicle, snapshot)
    if snapshot == nil then return 0 end

    local inputBuffer = self:getInputBuffer(vehicle)
    if inputBuffer == nil or inputBuffer.buffer == nil then
        return 0
    end

    local restored = 0
    local count = math.min(#inputBuffer.buffer, #snapshot)

    for index = 1, count do
        local liters = snapshot[index] or 0
        inputBuffer.buffer[index].liters = liters
        restored = restored + liters
    end

    return restored
end

-- Возвращает суммарное количество литров, находящихся в processing buffer.
function CompetitionCombineFix:getBufferLiters(vehicle)
    local inputBuffer = self:getInputBuffer(vehicle)
    if inputBuffer == nil or inputBuffer.buffer == nil then
        return 0
    end

    local total = 0
    for index = 1, #inputBuffer.buffer do
        total = total + (inputBuffer.buffer[index].liters or 0)
    end

    return total
end

-- Накапливает часть запрошенного валка, которую GIANTS счёл обработанной,
-- но density height map фактически не приняла. Этот объём нужно убрать только
-- из временного litersToDrop; в processing buffer он уже остаётся сам.
function CompetitionCombineFix:addPendingSwathCarryRemoval(vehicle, liters)
    if vehicle == nil or liters == nil or liters <= 0 then return end

    local current = self.pendingSwathCarryRemovalByVehicle[vehicle] or 0
    self.pendingSwathCarryRemovalByVehicle[vehicle] = current + liters
end

-- Забирает накопленную корректировку litersToDrop для текущего цикла обработки.
function CompetitionCombineFix:takePendingSwathCarryRemoval(vehicle)
    if vehicle == nil then return 0 end

    local liters = self.pendingSwathCarryRemovalByVehicle[vehicle] or 0
    self.pendingSwathCarryRemovalByVehicle[vehicle] = nil
    return liters
end

-- Устанавливает runtime-исправления штатной специализации Combine.
function CompetitionCombineFix:install()
    if self.installed then return true end

    if Combine == nil
        or DensityMapHeightUtil == nil
        or DensityMapHeightUtil.tipToGroundAroundLine == nil then
        logWarning("COMBINE FIX не установлен: штатные специализации ещё недоступны")
        return false
    end

    if Combine.processCombineSwathArea == nil
        or Combine.onEndWorkAreaProcessing == nil
        or Combine.setIsSwathActive == nil
        or Combine.onUpdate == nil then
        logWarning("COMBINE FIX не установлен: отсутствуют требуемые функции Combine")
        return false
    end

    ---------------------------------------------------------------------------
    -- 1. Фикс учёта фактически уложенного валка.
    --
    -- Штатный Combine.processCombineSwathArea() получает от
    -- tipToGroundAroundLine() реальный объём, но прибавляет к droppedLiters
    -- весь запрошенный объём. Мы заменяем прирост droppedLiters на фактически
    -- размещённый объём и отдельно запоминаем недоложенную разницу.
    ---------------------------------------------------------------------------
    self.originalTipToGroundAroundLine = DensityMapHeightUtil.tipToGroundAroundLine

    DensityMapHeightUtil.tipToGroundAroundLine = function(vehicle, delta, fillTypeIndex, ...)
        local dropped, lineOffset = CompetitionCombineFix.originalTipToGroundAroundLine(
            vehicle,
            delta,
            fillTypeIndex,
            ...
        )

        local context = CompetitionCombineFix.activeSwathContext
        if context ~= nil
            and context.vehicle == vehicle
            and delta ~= nil
            and delta > 0 then
            context.actualPlacedLiters = context.actualPlacedLiters + math.max(0, dropped or 0)
        end

        return dropped, lineOffset
    end

    self.originalProcessCombineSwathArea = Combine.processCombineSwathArea

    Combine.processCombineSwathArea = function(vehicle, workArea)
        local spec = vehicle ~= nil and vehicle.spec_combine or nil

        -- На клиенте оставляем штатное поведение. Количество материала
        -- авторитетно изменяется только на сервере.
        if vehicle == nil
            or vehicle.isServer ~= true
            or spec == nil
            or spec.workAreaParameters == nil then
            return CompetitionCombineFix.originalProcessCombineSwathArea(vehicle, workArea)
        end

        local parameters = spec.workAreaParameters
        local droppedBefore = parameters.droppedLiters or 0
        local previousContext = CompetitionCombineFix.activeSwathContext
        local context = {
            vehicle = vehicle,
            actualPlacedLiters = 0
        }

        CompetitionCombineFix.activeSwathContext = context
        local area, totalArea = CompetitionCombineFix.originalProcessCombineSwathArea(vehicle, workArea)
        CompetitionCombineFix.activeSwathContext = previousContext

        local droppedAfter = parameters.droppedLiters or 0
        local accountedByGame = math.max(0, droppedAfter - droppedBefore)
        local actualPlaced = math.max(0, context.actualPlacedLiters)

        -- В droppedLiters оставляем только реально уложенный объём. Поэтому
        -- onEndWorkAreaProcessing() вычтет из processing slot ровно то, что
        -- действительно оказалось на земле.
        parameters.droppedLiters = droppedBefore + actualPlaced

        -- Если GIANTS собирался списать больше, чем реально легло на карту,
        -- разницу нельзя оставлять ещё и в litersToDrop: она уже остаётся
        -- в slot.liters. Иначе следующий цикл прибавит её повторно.
        local unplacedAccounted = math.max(0, accountedByGame - actualPlaced)
        CompetitionCombineFix:addPendingSwathCarryRemoval(vehicle, unplacedAccounted)

        return area, totalArea
    end

    ---------------------------------------------------------------------------
    -- 2. Убирает двойной перенос недоложенной соломы.
    --
    -- После пункта 1 штатный onEndWorkAreaProcessing() вычитает actualPlaced
    -- и из slot.liters, и из litersToDrop. Недоложенная часть корректно остаётся
    -- в slot.liters. Здесь мы дополнительно удаляем эту же часть только из
    -- временного litersToDrop, чтобы она не была прибавлена второй раз в
    -- следующем onStartWorkAreaProcessing().
    ---------------------------------------------------------------------------
    self.originalOnEndWorkAreaProcessing = Combine.onEndWorkAreaProcessing

    Combine.onEndWorkAreaProcessing = function(vehicle, dt, hasProcessed)
        CompetitionCombineFix.originalOnEndWorkAreaProcessing(vehicle, dt, hasProcessed)

        if vehicle == nil or vehicle.isServer ~= true or vehicle.spec_combine == nil then
            CompetitionCombineFix:takePendingSwathCarryRemoval(vehicle)
            return
        end

        local pendingRemoval = CompetitionCombineFix:takePendingSwathCarryRemoval(vehicle)
        if pendingRemoval <= 0 then return end

        local parameters = vehicle.spec_combine.workAreaParameters
        if parameters == nil then return end

        parameters.litersToDrop = math.max(
            0,
            (parameters.litersToDrop or 0) - pendingRemoval
        )
    end

    ---------------------------------------------------------------------------
    -- 3. Фикс очистки processing buffer при ручном/сетевом переключении
    -- измельчителя и валка.
    --
    -- Штатный setIsSwathActive() обнуляет slot.liters. Мы даём функции
    -- выполнить все события, анимации и сетевую синхронизацию, после чего
    -- восстанавливаем только литры.
    ---------------------------------------------------------------------------
    self.originalSetIsSwathActive = Combine.setIsSwathActive

    Combine.setIsSwathActive = function(vehicle, isSwathActive, noEventSend, force)
        local spec = vehicle ~= nil and vehicle.spec_combine or nil
        local oldState = nil
        if spec ~= nil then
            oldState = spec.isSwathActive
        end
        local shouldPreserve = vehicle ~= nil
            and vehicle.isServer == true
            and spec ~= nil
            and (oldState ~= isSwathActive or force == true)

        local snapshot = nil
        local bufferBefore = 0
        if shouldPreserve then
            snapshot, bufferBefore = CompetitionCombineFix:captureBufferLiters(vehicle)
        end

        CompetitionCombineFix.originalSetIsSwathActive(vehicle, isSwathActive, noEventSend, force)

        if shouldPreserve and snapshot ~= nil and bufferBefore > 0 then
            local bufferAfter = CompetitionCombineFix:getBufferLiters(vehicle)
            if bufferAfter + 0.001 < bufferBefore then
                CompetitionCombineFix:restoreBufferLiters(vehicle, snapshot)
                logInfo(
                    "COMBINE FIX сохранён буфер при переключении режима: farmId=%s old=%s new=%s liters=%.2f",
                    tostring(vehicle:getOwnerFarmId()),
                    tostring(oldState),
                    tostring(isSwathActive),
                    bufferBefore
                )
            end
        end
    end

    ---------------------------------------------------------------------------
    -- 4. Штатный Combine:onUpdate() имеет отдельную автоматическую ветку:
    -- после setIsSwathActive(true) он ещё раз очищает area/liters/inputLiters.
    -- Служебные area/inputLiters оставляем сбрасываться как задумано GIANTS,
    -- но количество материала (liters) восстанавливаем.
    ---------------------------------------------------------------------------
    self.originalOnUpdate = Combine.onUpdate

    Combine.onUpdate = function(vehicle, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
        local spec = vehicle ~= nil and vehicle.spec_combine or nil
        local oldState = nil
        if spec ~= nil then
            oldState = spec.isSwathActive
        end
        local snapshot = nil
        local bufferBefore = 0

        if vehicle ~= nil and vehicle.isServer == true and oldState == false then
            snapshot, bufferBefore = CompetitionCombineFix:captureBufferLiters(vehicle)
        end

        CompetitionCombineFix.originalOnUpdate(
            vehicle,
            dt,
            isActiveForInput,
            isActiveForInputIgnoreSelection,
            isSelected
        )

        -- false -> true внутри onUpdate означает штатное автоматическое
        -- включение валка. Только в этой ветке GIANTS выполняет вторую очистку.
        if snapshot ~= nil
            and bufferBefore > 0
            and spec ~= nil
            and oldState == false
            and spec.isSwathActive == true then

            local bufferAfter = CompetitionCombineFix:getBufferLiters(vehicle)
            if bufferAfter + 0.001 < bufferBefore then
                CompetitionCombineFix:restoreBufferLiters(vehicle, snapshot)
                logInfo(
                    "COMBINE FIX сохранён буфер после автоматического включения валка: farmId=%s liters=%.2f",
                    tostring(vehicle:getOwnerFarmId()),
                    bufferBefore
                )
            end
        end
    end

    self.installed = true
    logInfo("COMBINE FIX установлен, version=%s", self.VERSION)
    return true
end

CompetitionCombineFix:install()
