--[[
	FS25 FarmersCompetition - Progress Engine
	Выполняет периодическое сканирование карты (раз в 10 секунд).
	Анализирует поля (Density Maps), подсчитывает тюки и поддоны мёда.
	Вычисляет проценты выполнения заданий и проверяет условие победы.
]]

CompetitionProgress = {}
local CompetitionProgress_mt = Class(CompetitionProgress)

function CompetitionProgress.new(manager, customMt)
	local self = setmetatable({}, customMt or CompetitionProgress_mt)
	self.manager = manager
	self.scanTimer = 0
	self.scanCount = 0
	self.strawPickedLitersByFarmId = {}
	self.grassPickedLitersByFarmId = {}
	self.lastStrawPickupLogLitersByFarmId = {}
	self.lastGrassPickupLogLitersByFarmId = {}
	self.ignoredBalerFillTypesLogged = {}
	self.lastBaleScanSignatureByFarmId = {}
	self.invalidGrassTargetsLoggedByFarmId = {}

	-- Диагностика прохождения соломы через комбайн:
	-- от начисления во внутренний буфер до фактической укладки на землю.
	self.strawGroundDiagnosticsByVehicle = {}
	self.nextStrawGroundDiagnosticVehicleId = 1

	-- Диагностика травы ведётся отдельно для косилок и валкователей.
	-- Для покоса сравниваем произведённый объём с фактически уложенным на карту.
	-- Для валкования сравниваем снятый с карты объём с новым сформированным валком.
	self.grassMowerDiagnosticsByVehicle = {}
	self.nextGrassMowerDiagnosticVehicleId = 1
	self.grassWindrowerDiagnosticsByVehicle = {}
	self.nextGrassWindrowerDiagnosticVehicleId = 1

	self:installBalerPickupHook()
	self:installStrawGroundDiagnosticsHooks()
	self:installGrassGroundDiagnosticsHooks()
	return self
end

-- Сбрасывает runtime-счётчики непосредственно перед началом соревнования.
function CompetitionProgress:resetRuntimeCounters()
	self.strawPickedLitersByFarmId = {}
	self.grassPickedLitersByFarmId = {}
	self.lastStrawPickupLogLitersByFarmId = {}
	self.lastGrassPickupLogLitersByFarmId = {}
	self.ignoredBalerFillTypesLogged = {}
	self.lastBaleScanSignatureByFarmId = {}
	self.invalidGrassTargetsLoggedByFarmId = {}

	-- Диагностические суммы относятся только к текущему запуску соревнования.
	self.strawGroundDiagnosticsByVehicle = {}
	self.nextStrawGroundDiagnosticVehicleId = 1
	self.grassMowerDiagnosticsByVehicle = {}
	self.nextGrassMowerDiagnosticVehicleId = 1
	self.grassWindrowerDiagnosticsByVehicle = {}
	self.nextGrassWindrowerDiagnosticVehicleId = 1

	for farmId = 1, 4 do
		self.strawPickedLitersByFarmId[farmId] = 0
		self.grassPickedLitersByFarmId[farmId] = 0
		self.lastStrawPickupLogLitersByFarmId[farmId] = 0
		self.lastGrassPickupLogLitersByFarmId[farmId] = 0
	end
	CompetitionUtils.info("BALER PICKUP DEBUG runtime counters reset")
end

-- Устанавливает перехват Baler:processBalerArea().
-- Считаем фактические литры STRAW и GRASS_WINDROW, которые пресс реально снял с карты.
function CompetitionProgress:installBalerPickupHook()
	if CompetitionProgress.balerPickupHookInstalled == true then
		return
	end
	if Baler == nil or Baler.processBalerArea == nil then
		CompetitionUtils.warning("Baler.processBalerArea unavailable; baler pickup counter not installed")
		return
	end

	CompetitionProgress.balerPickupHookInstalled = true
	CompetitionProgress.originalProcessBalerArea = Baler.processBalerArea

	Baler.processBalerArea = function(vehicle, workArea, dt)
		-- Baler добавляет до 5% к возвращаемому объёму при расходовании присадки.
		-- Запоминаем уровень присадки, чтобы после штатного вызова восстановить
		-- именно объём материала, удалённый с карты.
		local balerSpec = vehicle ~= nil and vehicle.spec_baler or nil
		local additiveData = balerSpec ~= nil and balerSpec.additives or nil
		local additiveFillLevelBefore = nil
		if vehicle ~= nil
			and vehicle.isServer == true
			and additiveData ~= nil
			and additiveData.available == true
			and additiveData.appliedByBufferOverloading ~= true
			and additiveData.fillUnitIndex ~= nil
			and vehicle.getFillUnitFillLevel ~= nil then

			additiveFillLevelBefore = vehicle:getFillUnitFillLevel(additiveData.fillUnitIndex)
		end

		local pickedUpLiters, processedLiters = CompetitionProgress.originalProcessBalerArea(vehicle, workArea, dt)

		if pickedUpLiters ~= nil and pickedUpLiters > 0
			and vehicle ~= nil
			and vehicle.isServer == true
			and vehicle.spec_baler ~= nil
			and g_competitionManager ~= nil
			and g_competitionManager.progress ~= nil
			and g_competitionManager.state == CompetitionUtils.STATE.RUNNING then

			local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
			if farmId ~= nil and farmId >= 1 and farmId <= 4
				and g_competitionManager:isFarmInCompetitionMask(farmId) then

				local progress = g_competitionManager.progress
				local fillType = vehicle.spec_baler.fillEffectType
				local groundLiters = pickedUpLiters
				local additiveUsed = 0

				if additiveFillLevelBefore ~= nil
					and additiveData ~= nil
					and additiveData.usage ~= nil
					and additiveData.usage > 0
					and vehicle.getFillUnitFillLevel ~= nil then

					local additiveFillLevelAfter = vehicle:getFillUnitFillLevel(additiveData.fillUnitIndex) or 0
					additiveUsed = math.max(0, additiveFillLevelBefore - additiveFillLevelAfter)
					groundLiters = math.max(0, pickedUpLiters - 0.05 * additiveUsed / additiveData.usage)
				end

				if fillType == FillType.STRAW then
					progress:addPickedStrawLiters(
						farmId,
						groundLiters,
						pickedUpLiters,
						additiveUsed,
						vehicle.spec_baler.fillScale
					)
				elseif fillType == FillType.GRASS_WINDROW then
					progress:addPickedGrassLiters(
						farmId,
						groundLiters,
						pickedUpLiters,
						additiveUsed,
						vehicle.spec_baler.fillScale
					)
				else
					-- Неизвестный тип логируем только один раз на ферму/тип, чтобы не засорять лог.
					local ignoredKey = tostring(farmId) .. ":" .. tostring(fillType)
					if progress.ignoredBalerFillTypesLogged[ignoredKey] ~= true then
						progress.ignoredBalerFillTypesLogged[ignoredKey] = true
						local fillName = nil
						if fillType ~= nil and g_fillTypeManager ~= nil then
							fillName = g_fillTypeManager:getFillTypeNameByIndex(fillType)
						end
						CompetitionUtils.info(
							"BALER PICKUP IGNORED DEBUG farmId=%s fillType=%s fillName=%s pickedLiters=%.2f processedLiters=%s",
							tostring(farmId),
							tostring(fillType),
							tostring(fillName),
							pickedUpLiters,
							tostring(processedLiters)
						)
					end
				end
			end
		end

		return pickedUpLiters, processedLiters
	end
end


-------------------------------------------------------------------------------
-- ДИАГНОСТИКА ЦЕПОЧКИ СОЛОМЫ В КОМБАЙНЕ
-------------------------------------------------------------------------------

-- Возвращает суммарный объём материала, который сейчас остаётся
-- во внутренних слотах буфера обработки комбайна.
function CompetitionProgress:getCombineProcessingBufferLiters(vehicle)
	if vehicle == nil or vehicle.spec_combine == nil then return 0 end
	local processing = vehicle.spec_combine.processing
	local inputBuffer = processing ~= nil and processing.inputBuffer or nil
	local total = 0

	for _, slot in ipairs(inputBuffer ~= nil and inputBuffer.buffer or {}) do
		total = total + math.max(0, slot.liters or 0)
	end

	return total
end

-- Проверяет, относится ли культура к типам, из которых штатный Combine
-- формирует валок STRAW.
function CompetitionProgress:isStrawFruitType(fruitTypeIndex)
	if fruitTypeIndex == nil
		or g_fruitTypeManager == nil
		or g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex == nil then
		return false
	end

	return g_fruitTypeManager:getWindrowFillTypeIndexByFruitTypeIndex(fruitTypeIndex) == FillType.STRAW
end

-- Проверяет текущий output fill type комбайна и определяет, относится ли
-- обрабатываемый материал к культуре, которая даёт STRAW.
function CompetitionProgress:isCombineCurrentlyProcessingStraw(vehicle)
	if vehicle == nil or vehicle.spec_combine == nil or g_fruitTypeManager == nil then
		return false
	end

	local fillType = vehicle.spec_combine.workAreaParameters ~= nil
		and vehicle.spec_combine.workAreaParameters.dropFillType
		or nil

	if fillType == nil or fillType == FillType.UNKNOWN then return false end

	local fruitTypeIndex = g_fruitTypeManager:getFruitTypeIndexByFillTypeIndex(fillType)
	return self:isStrawFruitType(fruitTypeIndex)
end

-- Возвращает диагностическую запись конкретного комбайна.
-- Диагностика намеренно не зависит от teamMask и состояния соревнования:
-- при сравнительных тестах оператор может перейти на другую ферму.
function CompetitionProgress:getStrawGroundDiagnosticData(vehicle)
	if vehicle == nil
		or vehicle.isServer ~= true
		or vehicle.spec_combine == nil then
		return nil
	end

	local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or 0
	farmId = farmId or 0

	local data = self.strawGroundDiagnosticsByVehicle[vehicle]
	if data == nil then
		local vehicleId = self.nextStrawGroundDiagnosticVehicleId or 1
		self.nextStrawGroundDiagnosticVehicleId = vehicleId + 1

		local name = nil
		if vehicle.getName ~= nil then
			local ok, value = pcall(vehicle.getName, vehicle)
			if ok then name = value end
		end

		data = {
			id = vehicleId,
			farmId = farmId,
			name = tostring(name or vehicle.typeName or vehicle.className or "Combine"),
			configFileName = tostring(vehicle.configFileName or vehicle.xmlFilename or ""),
			bufferGeneratedLiters = 0,
			tipRequestedLiters = 0,
			groundPlacedLiters = 0,
			combineAccountedDroppedLiters = 0,
			choppedLiters = 0,
			toggleDiscardedBufferLiters = 0,
			harvestInputLiters = 0,
			cutAreaPixels = 0,
			tipCalls = 0,
			lastBufferLogLiters = 0,
			lastGroundLogLiters = 0,
			lastTipShortfallLogLiters = 0,
			lastChoppedLogLiters = 0
		}
		self.strawGroundDiagnosticsByVehicle[vehicle] = data

		CompetitionUtils.info(
			"STRAW FLOW VEHICLE DEBUG id=%d farmId=%d swathActive=%s name=%s config=%s",
			data.id,
			data.farmId,
			tostring(vehicle.spec_combine.isSwathActive == true),
			data.name,
			data.configFileName
		)
	end

	return data
end

-- Учитывает солому, которую штатный Combine:addCutterArea() реально
-- добавил во внутренний processing buffer после прохода жатки.
function CompetitionProgress:recordStrawBufferGenerated(vehicle, addedLiters, harvestInputLiters, areaPixels)
	if addedLiters == nil or addedLiters <= 0 then return end
	local data = self:getStrawGroundDiagnosticData(vehicle)
	if data == nil then return end

	data.bufferGeneratedLiters = data.bufferGeneratedLiters + addedLiters
	data.harvestInputLiters = data.harvestInputLiters + math.max(0, harvestInputLiters or 0)
	data.cutAreaPixels = data.cutAreaPixels + math.max(0, areaPixels or 0)

	local shouldLog = data.bufferGeneratedLiters - data.lastBufferLogLiters >= 5000
	if data.lastBufferLogLiters == 0 or shouldLog then
		data.lastBufferLogLiters = data.bufferGeneratedLiters

		local cutHa = 0
		if MathUtil ~= nil
			and MathUtil.areaToHa ~= nil
			and g_currentMission ~= nil
			and g_currentMission.getFruitPixelsToSqm ~= nil then
			cutHa = MathUtil.areaToHa(data.cutAreaPixels, g_currentMission:getFruitPixelsToSqm())
		end

		CompetitionUtils.info(
			"STRAW BUFFER DEBUG id=%d farmId=%d added=%.2f totalGenerated=%.2f harvestInputTotal=%.2f cutHa=%.4f currentBuffer=%.2f",
			data.id,
			data.farmId,
			addedLiters,
			data.bufferGeneratedLiters,
			data.harvestInputLiters,
			cutHa,
			self:getCombineProcessingBufferLiters(vehicle)
		)
	end
end

-- Учитывает вызов DensityMapHeightUtil.tipToGroundAroundLine() для STRAW.
-- requestedLiters — сколько валка запросил Combine, placedLiters —
-- сколько функция фактически вернула как уложенное на density height map.
function CompetitionProgress:recordStrawGroundTip(vehicle, requestedLiters, placedLiters)
	if requestedLiters == nil or requestedLiters <= 0 then return end
	local data = self:getStrawGroundDiagnosticData(vehicle)
	if data == nil then return end

	local actual = math.max(0, placedLiters or 0)
	local callShortfall = math.max(0, requestedLiters - actual)

	data.tipCalls = data.tipCalls + 1
	data.tipRequestedLiters = data.tipRequestedLiters + requestedLiters
	data.groundPlacedLiters = data.groundPlacedLiters + actual

	local totalShortfall = data.tipRequestedLiters - data.groundPlacedLiters
	local logByGround = data.groundPlacedLiters - data.lastGroundLogLiters >= 5000
	local logByShortfall = totalShortfall - data.lastTipShortfallLogLiters >= 250
	local firstCall = data.tipCalls == 1

	if firstCall or logByGround or logByShortfall then
		data.lastGroundLogLiters = data.groundPlacedLiters
		data.lastTipShortfallLogLiters = totalShortfall

		CompetitionUtils.info(
			"STRAW GROUND TIP DEBUG id=%d farmId=%d call=%d requested=%.2f placed=%.2f callShortfall=%.2f totalRequested=%.2f totalPlaced=%.2f totalShortfall=%.2f",
			data.id,
			data.farmId,
			data.tipCalls,
			requestedLiters,
			actual,
			callShortfall,
			data.tipRequestedLiters,
			data.groundPlacedLiters,
			totalShortfall
		)
	end
end

-- Учитывает объём, который сам Combine после processCombineSwathArea()
-- записал в workAreaParameters.droppedLiters как выгруженный.
function CompetitionProgress:recordStrawCombineAccounting(vehicle, accountedLiters)
	if accountedLiters == nil or accountedLiters <= 0 then return end
	local data = self:getStrawGroundDiagnosticData(vehicle)
	if data == nil then return end

	data.combineAccountedDroppedLiters = data.combineAccountedDroppedLiters + accountedLiters
end

-- Учитывает солому, которая была обработана измельчителем вместо укладки
-- валка на землю.
function CompetitionProgress:recordStrawChopped(vehicle, choppedLiters)
	if choppedLiters == nil or choppedLiters <= 0 then return end
	local data = self:getStrawGroundDiagnosticData(vehicle)
	if data == nil then return end

	data.choppedLiters = data.choppedLiters + choppedLiters
	if data.lastChoppedLogLiters == 0
		or data.choppedLiters - data.lastChoppedLogLiters >= 5000 then

		data.lastChoppedLogLiters = data.choppedLiters
		CompetitionUtils.info(
			"STRAW CHOPPER DEBUG id=%d farmId=%d chopped=%.2f totalChopped=%.2f currentBuffer=%.2f",
			data.id,
			data.farmId,
			choppedLiters,
			data.choppedLiters,
			self:getCombineProcessingBufferLiters(vehicle)
		)
	end
end

-- Печатает накопленный баланс соломы конкретного комбайна.
-- По нему можно отдельно увидеть потери до tipToGround и потери уже при укладке.
function CompetitionProgress:logStrawGroundSummary(vehicle, reason)
	local data = self.strawGroundDiagnosticsByVehicle[vehicle]
	if data == nil then return end

	local remainingBuffer = self:getCombineProcessingBufferLiters(vehicle)
	local routedLiters = data.tipRequestedLiters + data.choppedLiters
	local flowGap = data.bufferGeneratedLiters - routedLiters - remainingBuffer
	local groundShortfall = data.tipRequestedLiters - data.groundPlacedLiters
	local accountingOverActual = data.combineAccountedDroppedLiters - data.groundPlacedLiters

	CompetitionUtils.info(
		"STRAW FLOW SUMMARY id=%d farmId=%d reason=%s generated=%.2f tipRequested=%.2f groundPlaced=%.2f combineAccounted=%.2f chopped=%.2f toggleDiscarded=%.2f remainingBuffer=%.2f flowGap=%.2f groundShortfall=%.2f accountingOverActual=%.2f tipCalls=%d name=%s config=%s",
		data.id,
		data.farmId,
		tostring(reason or "summary"),
		data.bufferGeneratedLiters,
		data.tipRequestedLiters,
		data.groundPlacedLiters,
		data.combineAccountedDroppedLiters,
		data.choppedLiters,
		data.toggleDiscardedBufferLiters,
		remainingBuffer,
		flowGap,
		groundShortfall,
		accountingOverActual,
		data.tipCalls,
		data.name,
		data.configFileName
	)
end

-- Устанавливает диагностические перехваты штатной цепочки Combine.
-- Хуки только читают аргументы/результаты и накапливают лог; игровую логику
-- и возвращаемые штатными функциями значения они не изменяют.
function CompetitionProgress:installStrawGroundDiagnosticsHooks()
	if CompetitionProgress.strawGroundDiagnosticsHooksInstalled == true then
		return
	end

	if Combine == nil or DensityMapHeightUtil == nil then
		CompetitionUtils.warning("STRAW FLOW DEBUG hooks unavailable: Combine or DensityMapHeightUtil missing")
		return
	end

	CompetitionProgress.strawGroundDiagnosticsHooksInstalled = true

	-- 1. Сколько соломы реально попало во внутренний буфер Combine.
	if Combine.addCutterArea ~= nil then
		CompetitionProgress.originalCombineAddCutterArea = Combine.addCutterArea

		Combine.addCutterArea = function(vehicle, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)
			local progress = g_competitionManager ~= nil and g_competitionManager.progress or nil
			local beforeBuffer = progress ~= nil and progress:getCombineProcessingBufferLiters(vehicle) or 0

			local result = CompetitionProgress.originalCombineAddCutterArea(
				vehicle,
				area,
				liters,
				inputFruitType,
				outputFillType,
				strawRatio,
				farmId,
				cutterLoad
			)

			if progress ~= nil
				and progress:isStrawFruitType(inputFruitType)
				and vehicle ~= nil
				and vehicle.isServer == true then

				local afterBuffer = progress:getCombineProcessingBufferLiters(vehicle)
				local added = math.max(0, afterBuffer - beforeBuffer)
				if added > 0 then
					progress:recordStrawBufferGenerated(vehicle, added, liters, area)
				end
			end

			return result
		end
	else
		CompetitionUtils.warning("STRAW FLOW DEBUG Combine.addCutterArea hook unavailable")
	end

	-- 2. Сколько STRAW запросили положить на землю и сколько реально положено.
	if DensityMapHeightUtil.tipToGroundAroundLine ~= nil then
		CompetitionProgress.originalTipToGroundAroundLine = DensityMapHeightUtil.tipToGroundAroundLine

		DensityMapHeightUtil.tipToGroundAroundLine = function(vehicle, delta, fillTypeIndex, ...)
			local dropped, lineOffset = CompetitionProgress.originalTipToGroundAroundLine(
				vehicle,
				delta,
				fillTypeIndex,
				...
			)

			if delta ~= nil
				and delta > 0
				and fillTypeIndex == FillType.STRAW
				and vehicle ~= nil
				and vehicle.spec_combine ~= nil
				and vehicle.isServer == true
				and g_competitionManager ~= nil
				and g_competitionManager.progress ~= nil then

				g_competitionManager.progress:recordStrawGroundTip(vehicle, delta, dropped)
			end

			return dropped, lineOffset
		end
	else
		CompetitionUtils.warning("STRAW FLOW DEBUG DensityMapHeightUtil.tipToGroundAroundLine hook unavailable")
	end

	-- 3. Сколько Combine сам считает выгруженным после прохода swath work area.
	if Combine.processCombineSwathArea ~= nil then
		CompetitionProgress.originalProcessCombineSwathArea = Combine.processCombineSwathArea

		Combine.processCombineSwathArea = function(vehicle, workArea)
			local progress = g_competitionManager ~= nil and g_competitionManager.progress or nil
			local isStraw = progress ~= nil and progress:isCombineCurrentlyProcessingStraw(vehicle)
			local spec = vehicle ~= nil and vehicle.spec_combine or nil
			local beforeDropped = spec ~= nil and spec.workAreaParameters ~= nil
				and (spec.workAreaParameters.droppedLiters or 0)
				or 0

			local area, totalArea = CompetitionProgress.originalProcessCombineSwathArea(vehicle, workArea)

			if isStraw and progress ~= nil and spec ~= nil and spec.workAreaParameters ~= nil then
				local afterDropped = spec.workAreaParameters.droppedLiters or 0
				progress:recordStrawCombineAccounting(vehicle, math.max(0, afterDropped - beforeDropped))
			end

			return area, totalArea
		end
	else
		CompetitionUtils.warning("STRAW FLOW DEBUG Combine.processCombineSwathArea hook unavailable")
	end

	-- 4. Сколько соломы ушло в измельчитель вместо валка.
	if Combine.processCombineChopperArea ~= nil then
		CompetitionProgress.originalProcessCombineChopperArea = Combine.processCombineChopperArea

		Combine.processCombineChopperArea = function(vehicle, workArea)
			local progress = g_competitionManager ~= nil and g_competitionManager.progress or nil
			local isStraw = progress ~= nil and progress:isCombineCurrentlyProcessingStraw(vehicle)
			local spec = vehicle ~= nil and vehicle.spec_combine or nil
			local beforeDropped = spec ~= nil and spec.workAreaParameters ~= nil
				and (spec.workAreaParameters.droppedLiters or 0)
				or 0

			local area, totalArea = CompetitionProgress.originalProcessCombineChopperArea(vehicle, workArea)

			if isStraw and progress ~= nil and spec ~= nil and spec.workAreaParameters ~= nil then
				local afterDropped = spec.workAreaParameters.droppedLiters or 0
				progress:recordStrawChopped(vehicle, math.max(0, afterDropped - beforeDropped))
			end

			return area, totalArea
		end
	else
		CompetitionUtils.warning("STRAW FLOW DEBUG Combine.processCombineChopperArea hook unavailable")
	end

	-- 5. Переключение режима валка может очистить processing buffer.
	if Combine.setIsSwathActive ~= nil then
		CompetitionProgress.originalSetIsSwathActive = Combine.setIsSwathActive

		Combine.setIsSwathActive = function(vehicle, isSwathActive, noEventSend, force)
			local progress = g_competitionManager ~= nil and g_competitionManager.progress or nil
			local oldState = vehicle ~= nil and vehicle.spec_combine ~= nil
				and vehicle.spec_combine.isSwathActive
				or nil
			local beforeBuffer = progress ~= nil and progress:getCombineProcessingBufferLiters(vehicle) or 0

			CompetitionProgress.originalSetIsSwathActive(vehicle, isSwathActive, noEventSend, force)

			local relevantToStraw = progress ~= nil
				and vehicle ~= nil
				and (
					progress.strawGroundDiagnosticsByVehicle[vehicle] ~= nil
					or beforeBuffer > 0
					or progress:isCombineCurrentlyProcessingStraw(vehicle)
				)

			if relevantToStraw
				and vehicle.isServer == true
				and (oldState ~= isSwathActive or force == true) then

				local data = progress:getStrawGroundDiagnosticData(vehicle)
				if data ~= nil then
					local afterBuffer = progress:getCombineProcessingBufferLiters(vehicle)
					local discarded = math.max(0, beforeBuffer - afterBuffer)
					data.toggleDiscardedBufferLiters = data.toggleDiscardedBufferLiters + discarded

					CompetitionUtils.info(
						"STRAW SWATH MODE DEBUG id=%d farmId=%d old=%s new=%s force=%s bufferBefore=%.2f bufferAfter=%.2f discarded=%.2f totalDiscarded=%.2f",
						data.id,
						data.farmId,
						tostring(oldState),
						tostring(isSwathActive),
						tostring(force == true),
						beforeBuffer,
						afterBuffer,
						discarded,
						data.toggleDiscardedBufferLiters
					)
				end
			end
		end
	else
		CompetitionUtils.warning("STRAW FLOW DEBUG Combine.setIsSwathActive hook unavailable")
	end

	-- 6. При каждой остановке молотилки печатаем накопленный баланс.
	if Combine.stopThreshing ~= nil then
		CompetitionProgress.originalStopThreshing = Combine.stopThreshing

		Combine.stopThreshing = function(vehicle)
			CompetitionProgress.originalStopThreshing(vehicle)

			if g_competitionManager ~= nil and g_competitionManager.progress ~= nil then
				g_competitionManager.progress:logStrawGroundSummary(vehicle, "stopThreshing")
			end
		end
	else
		CompetitionUtils.warning("STRAW FLOW DEBUG Combine.stopThreshing hook unavailable")
	end


	CompetitionUtils.info("STRAW FLOW DEBUG hooks installed")
end

-- Возвращает сумму травы, ожидающей укладки в drop-area косилки.
-- Это внутренний буфер между processMowerArea() и processDropArea().
function CompetitionProgress:getMowerGrassDropBufferLiters(vehicle)
	local spec = vehicle ~= nil and vehicle.spec_mower or nil
	if spec == nil or spec.dropAreas == nil then return 0 end

	local total = 0
	for _, dropArea in ipairs(spec.dropAreas) do
		if dropArea ~= nil and dropArea.fillType == FillType.GRASS_WINDROW then
			total = total + math.max(0, dropArea.litersToDrop or 0)
		end
	end
	return total
end

-- Возвращает диагностическую запись косилки.
-- В отличие от логики соревнования диагностика не фильтруется по farmId/teamMask.
function CompetitionProgress:getGrassMowerDiagnosticData(vehicle)
	if vehicle == nil or vehicle.isServer ~= true or vehicle.spec_mower == nil then
		return nil
	end

	local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or 0
	farmId = farmId or 0
	local data = self.grassMowerDiagnosticsByVehicle[vehicle]
	if data == nil then
		local vehicleId = self.nextGrassMowerDiagnosticVehicleId or 1
		self.nextGrassMowerDiagnosticVehicleId = vehicleId + 1

		local name = nil
		if vehicle.getName ~= nil then
			local ok, value = pcall(vehicle.getName, vehicle)
			if ok then name = value end
		end

		data = {
			id = vehicleId,
			farmId = farmId,
			name = tostring(name or vehicle.typeName or vehicle.className or "Mower"),
			configFileName = tostring(vehicle.configFileName or vehicle.xmlFilename or ""),
			generatedLiters = 0,
			cutAreaPixels = 0,
			tipAttemptRequestedLiters = 0,
			groundPlacedLiters = 0,
			tipCalls = 0,
			lastGeneratedLogLiters = 0,
			lastGroundLogLiters = 0,
			lastShortfallLogLiters = 0
		}
		self.grassMowerDiagnosticsByVehicle[vehicle] = data

		CompetitionUtils.info(
			"GRASS MOWER VEHICLE DEBUG id=%d farmId=%d name=%s config=%s",
			data.id,
			data.farmId,
			data.name,
			data.configFileName
		)
	end

	return data
end

-- Учитывает объём GRASS_WINDROW, который штатная косилка рассчитала
-- из реально срезанной площади после применения урожайности и converter factor.
function CompetitionProgress:recordGrassMowerGenerated(vehicle, liters, areaPixels, inputFruitType)
	if liters == nil or liters <= 0 then return end
	local data = self:getGrassMowerDiagnosticData(vehicle)
	if data == nil then return end

	data.generatedLiters = data.generatedLiters + liters
	data.cutAreaPixels = data.cutAreaPixels + math.max(0, areaPixels or 0)

	if data.lastGeneratedLogLiters == 0
		or data.generatedLiters - data.lastGeneratedLogLiters >= 5000 then

		data.lastGeneratedLogLiters = data.generatedLiters
		local fruitName = nil
		if inputFruitType ~= nil and g_fruitTypeManager ~= nil then
			local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(inputFruitType)
			fruitName = fruitDesc ~= nil and fruitDesc.name or nil
		end

		local cutHa = 0
		if MathUtil ~= nil
			and MathUtil.areaToHa ~= nil
			and g_currentMission ~= nil
			and g_currentMission.getFruitPixelsToSqm ~= nil then
			cutHa = MathUtil.areaToHa(data.cutAreaPixels, g_currentMission:getFruitPixelsToSqm())
		end

		CompetitionUtils.info(
			"GRASS MOWER CUT DEBUG id=%d farmId=%d generated=%.2f totalGenerated=%.2f cutHa=%.4f inputFruit=%s dropBuffer=%.2f",
			data.id,
			data.farmId,
			liters,
			data.generatedLiters,
			cutHa,
			tostring(fruitName or inputFruitType),
			self:getMowerGrassDropBufferLiters(vehicle)
		)
	end
end

-- Учитывает попытку косилки положить GRASS_WINDROW на density height map.
-- attemptRequested может повторно включать остаток предыдущего вызова, поэтому
-- для итогового баланса используем generated/groundPlaced/remainingDropBuffer.
function CompetitionProgress:recordGrassMowerGroundTip(vehicle, attemptRequested, placedLiters)
	if attemptRequested == nil or attemptRequested <= 0 then return end
	local data = self:getGrassMowerDiagnosticData(vehicle)
	if data == nil then return end

	local actual = math.max(0, placedLiters or 0)
	local callShortfall = math.max(0, attemptRequested - actual)
	data.tipCalls = data.tipCalls + 1
	data.tipAttemptRequestedLiters = data.tipAttemptRequestedLiters + attemptRequested
	data.groundPlacedLiters = data.groundPlacedLiters + actual

	local cumulativeAttemptShortfall = data.tipAttemptRequestedLiters - data.groundPlacedLiters
	local firstCall = data.tipCalls == 1
	local logByGround = data.groundPlacedLiters - data.lastGroundLogLiters >= 5000
	local logByShortfall = cumulativeAttemptShortfall - data.lastShortfallLogLiters >= 250

	if firstCall or logByGround or logByShortfall then
		data.lastGroundLogLiters = data.groundPlacedLiters
		data.lastShortfallLogLiters = cumulativeAttemptShortfall
		CompetitionUtils.info(
			"GRASS MOWER GROUND DEBUG id=%d farmId=%d call=%d requested=%.2f placed=%.2f callShortfall=%.2f totalAttemptRequested=%.2f totalPlaced=%.2f dropBuffer=%.2f",
			data.id,
			data.farmId,
			data.tipCalls,
			attemptRequested,
			actual,
			callShortfall,
			data.tipAttemptRequestedLiters,
			data.groundPlacedLiters,
			self:getMowerGrassDropBufferLiters(vehicle)
		)
	end
end

-- Печатает итоговый баланс покоса: сколько травы рассчитано косилкой,
-- сколько реально записано на землю и сколько осталось ждать укладки.
function CompetitionProgress:logGrassMowerSummary(vehicle, reason)
	local data = self.grassMowerDiagnosticsByVehicle[vehicle]
	if data == nil then return end

	local remainingBuffer = self:getMowerGrassDropBufferLiters(vehicle)
	local flowGap = data.generatedLiters - data.groundPlacedLiters - remainingBuffer

	CompetitionUtils.info(
		"GRASS MOWER FLOW SUMMARY id=%d farmId=%d reason=%s generated=%.2f groundPlaced=%.2f remainingDropBuffer=%.2f flowGap=%.2f tipAttemptRequested=%.2f tipCalls=%d name=%s config=%s",
		data.id,
		data.farmId,
		tostring(reason or "summary"),
		data.generatedLiters,
		data.groundPlacedLiters,
		remainingBuffer,
		flowGap,
		data.tipAttemptRequestedLiters,
		data.tipCalls,
		data.name,
		data.configFileName
	)
end

-- Возвращает сумму материала, который валкователь уже снял с карты,
-- но пока не смог вернуть в сформированный валок.
function CompetitionProgress:getWindrowerGrassBufferLiters(vehicle)
	if vehicle == nil or vehicle.spec_windrower == nil then return 0 end

	local workAreas = vehicle.getTypedWorkAreas ~= nil
		and vehicle:getTypedWorkAreas(WorkAreaType.WINDROWER)
		or {}
	local total = 0
	for _, workArea in ipairs(workAreas) do
		if workArea ~= nil and workArea.lastValidPickupFillType == FillType.GRASS_WINDROW then
			total = total + math.max(0, workArea.litersToDrop or 0)
		end
	end
	return total
end

-- Возвращает диагностическую запись валкователя без фильтра по teamMask.
function CompetitionProgress:getGrassWindrowerDiagnosticData(vehicle)
	if vehicle == nil or vehicle.isServer ~= true or vehicle.spec_windrower == nil then
		return nil
	end

	local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or 0
	farmId = farmId or 0
	local data = self.grassWindrowerDiagnosticsByVehicle[vehicle]
	if data == nil then
		local vehicleId = self.nextGrassWindrowerDiagnosticVehicleId or 1
		self.nextGrassWindrowerDiagnosticVehicleId = vehicleId + 1

		local name = nil
		if vehicle.getName ~= nil then
			local ok, value = pcall(vehicle.getName, vehicle)
			if ok then name = value end
		end

		data = {
			id = vehicleId,
			farmId = farmId,
			name = tostring(name or vehicle.typeName or vehicle.className or "Windrower"),
			configFileName = tostring(vehicle.configFileName or vehicle.xmlFilename or ""),
			pickedUpLiters = 0,
			dropRequestedLiters = 0,
			groundPlacedLiters = 0,
			calls = 0,
			lastPickupLogLiters = 0,
			lastGroundLogLiters = 0,
			lastShortfallLogLiters = 0
		}
		self.grassWindrowerDiagnosticsByVehicle[vehicle] = data

		CompetitionUtils.info(
			"GRASS WINDROWER VEHICLE DEBUG id=%d farmId=%d name=%s config=%s",
			data.id,
			data.farmId,
			data.name,
			data.configFileName
		)
	end

	return data
end

-- Учитывает один штатный цикл валкователя для GRASS_WINDROW:
-- pickedUp снято со старого валка, dropped реально записано в новый валок.
function CompetitionProgress:recordGrassWindrowerFlow(vehicle, pickedUpLiters, droppedLiters)
	if pickedUpLiters == nil or pickedUpLiters <= 0 then return end
	local data = self:getGrassWindrowerDiagnosticData(vehicle)
	if data == nil then return end

	local dropped = math.max(0, droppedLiters or 0)
	data.calls = data.calls + 1
	data.pickedUpLiters = data.pickedUpLiters + pickedUpLiters
	data.dropRequestedLiters = data.dropRequestedLiters + pickedUpLiters
	data.groundPlacedLiters = data.groundPlacedLiters + dropped

	local currentShortfall = data.pickedUpLiters - data.groundPlacedLiters
	local firstCall = data.calls == 1
	local logByPickup = data.pickedUpLiters - data.lastPickupLogLiters >= 5000
	local logByGround = data.groundPlacedLiters - data.lastGroundLogLiters >= 5000
	local logByShortfall = currentShortfall - data.lastShortfallLogLiters >= 250

	if firstCall or logByPickup or logByGround or logByShortfall then
		data.lastPickupLogLiters = data.pickedUpLiters
		data.lastGroundLogLiters = data.groundPlacedLiters
		data.lastShortfallLogLiters = currentShortfall

		CompetitionUtils.info(
			"GRASS WINDROWER FLOW DEBUG id=%d farmId=%d call=%d picked=%.2f dropped=%.2f callShortfall=%.2f totalPicked=%.2f totalDropped=%.2f buffer=%.2f",
			data.id,
			data.farmId,
			data.calls,
			pickedUpLiters,
			dropped,
			math.max(0, pickedUpLiters - dropped),
			data.pickedUpLiters,
			data.groundPlacedLiters,
			self:getWindrowerGrassBufferLiters(vehicle)
		)
	end
end

-- Печатает итоговый баланс валкования.
function CompetitionProgress:logGrassWindrowerSummary(vehicle, reason)
	local data = self.grassWindrowerDiagnosticsByVehicle[vehicle]
	if data == nil then return end

	local remainingBuffer = self:getWindrowerGrassBufferLiters(vehicle)
	local flowGap = data.pickedUpLiters - data.groundPlacedLiters - remainingBuffer

	CompetitionUtils.info(
		"GRASS WINDROWER FLOW SUMMARY id=%d farmId=%d reason=%s picked=%.2f groundPlaced=%.2f remainingBuffer=%.2f flowGap=%.2f calls=%d name=%s config=%s",
		data.id,
		data.farmId,
		tostring(reason or "summary"),
		data.pickedUpLiters,
		data.groundPlacedLiters,
		remainingBuffer,
		flowGap,
		data.calls,
		data.name,
		data.configFileName
	)
end

-- Устанавливает диагностические хуки покоса и валкования травы.
-- Обёртки не меняют аргументы, результаты или внутренние значения штатных функций.
function CompetitionProgress:installGrassGroundDiagnosticsHooks()
	if CompetitionProgress.grassGroundDiagnosticsHooksInstalled == true then
		return
	end

	if Mower == nil and Windrower == nil then
		CompetitionUtils.warning("GRASS FLOW DEBUG hooks unavailable: Mower and Windrower missing")
		return
	end

	CompetitionProgress.grassGroundDiagnosticsHooksInstalled = true

	-- 1. Покос: объём GRASS_WINDROW, рассчитанный из реально срезанной площади.
	if Mower ~= nil and Mower.processMowerArea ~= nil then
		CompetitionProgress.originalProcessMowerArea = Mower.processMowerArea
		Mower.processMowerArea = function(vehicle, workArea, dt)
			local changedArea, totalArea = CompetitionProgress.originalProcessMowerArea(vehicle, workArea, dt)
			local progress = g_competitionManager ~= nil and g_competitionManager.progress or nil

			if progress ~= nil
				and vehicle ~= nil
				and vehicle.isServer == true
				and changedArea ~= nil
				and changedArea > 0
				and vehicle.spec_mower ~= nil then

				local spec = vehicle.spec_mower
				local inputFruitType = spec.workAreaParameters ~= nil
					and spec.workAreaParameters.lastInputFruitType
					or nil
				local converter = inputFruitType ~= nil
					and spec.fruitTypeConverters ~= nil
					and spec.fruitTypeConverters[inputFruitType]
					or nil
				local outputFillType = converter ~= nil and converter.fillTypeIndex or nil
				local generatedLiters = workArea ~= nil and workArea.pickedUpLiters or 0

				if outputFillType == FillType.GRASS_WINDROW and generatedLiters > 0 then
					progress:recordGrassMowerGenerated(vehicle, generatedLiters, changedArea, inputFruitType)
				end
			end

			return changedArea, totalArea
		end
	else
		CompetitionUtils.warning("GRASS FLOW DEBUG Mower.processMowerArea hook unavailable")
	end

	-- 2. Покос: фактическая укладка накопленной травы на density height map.
	if Mower ~= nil and Mower.processDropArea ~= nil then
		CompetitionProgress.originalMowerProcessDropArea = Mower.processDropArea
		Mower.processDropArea = function(vehicle, dropArea, dt)
			local fillType = dropArea ~= nil and dropArea.fillType or nil
			local beforeLiters = dropArea ~= nil and (dropArea.litersToDrop or 0) or 0
			local minValid = 0
			if fillType ~= nil and g_densityMapHeightManager ~= nil then
				minValid = g_densityMapHeightManager:getMinValidLiterValue(fillType) or 0
			end
			local wasEligible = fillType == FillType.GRASS_WINDROW and beforeLiters > minValid

			CompetitionProgress.originalMowerProcessDropArea(vehicle, dropArea, dt)

			if wasEligible
				and vehicle ~= nil
				and vehicle.isServer == true
				and g_competitionManager ~= nil
				and g_competitionManager.progress ~= nil then

				local afterLiters = dropArea ~= nil and (dropArea.litersToDrop or 0) or 0
				local placed = math.max(0, beforeLiters - afterLiters)
				g_competitionManager.progress:recordGrassMowerGroundTip(vehicle, beforeLiters, placed)
			end
		end
	else
		CompetitionUtils.warning("GRASS FLOW DEBUG Mower.processDropArea hook unavailable")
	end

	-- 3. Валкование: сравниваем снятый со старого валка объём с фактической
	-- укладкой нового валка, которую штатная функция вернула после processDropArea().
	if Windrower ~= nil and Windrower.processWindrowerArea ~= nil then
		CompetitionProgress.originalProcessWindrowerArea = Windrower.processWindrowerArea
		Windrower.processWindrowerArea = function(vehicle, workArea, dt)
			local dropped, area = CompetitionProgress.originalProcessWindrowerArea(vehicle, workArea, dt)
			local progress = g_competitionManager ~= nil and g_competitionManager.progress or nil

			if progress ~= nil
				and vehicle ~= nil
				and vehicle.isServer == true
				and workArea ~= nil
				and workArea.lastValidPickupFillType == FillType.GRASS_WINDROW
				and (workArea.lastPickupLiters or 0) > 0 then

				progress:recordGrassWindrowerFlow(
					vehicle,
					workArea.lastPickupLiters or 0,
					workArea.lastDroppedLiters or dropped or 0
				)
			end

			return dropped, area
		end
	else
		CompetitionUtils.warning("GRASS FLOW DEBUG Windrower.processWindrowerArea hook unavailable")
	end

	-- 4. При выключении косилки печатаем накопленный баланс поля/прохода.
	if Mower ~= nil and Mower.onTurnedOff ~= nil then
		CompetitionProgress.originalMowerOnTurnedOff = Mower.onTurnedOff
		Mower.onTurnedOff = function(vehicle, ...)
			CompetitionProgress.originalMowerOnTurnedOff(vehicle, ...)
			if g_competitionManager ~= nil and g_competitionManager.progress ~= nil then
				g_competitionManager.progress:logGrassMowerSummary(vehicle, "turnedOff")
			end
		end
	else
		CompetitionUtils.warning("GRASS FLOW DEBUG Mower.onTurnedOff hook unavailable")
	end

	-- 5. При выключении валкователя печатаем его накопленный баланс.
	if Windrower ~= nil and Windrower.onTurnedOff ~= nil then
		CompetitionProgress.originalWindrowerOnTurnedOff = Windrower.onTurnedOff
		Windrower.onTurnedOff = function(vehicle, ...)
			CompetitionProgress.originalWindrowerOnTurnedOff(vehicle, ...)
			if g_competitionManager ~= nil and g_competitionManager.progress ~= nil then
				g_competitionManager.progress:logGrassWindrowerSummary(vehicle, "turnedOff")
			end
		end
	else
		CompetitionUtils.warning("GRASS FLOW DEBUG Windrower.onTurnedOff hook unavailable")
	end

	CompetitionUtils.info("GRASS FLOW DEBUG hooks installed")
end

-- Добавляет объём соломы, фактически удалённый прессом с карты.
-- returnedLiters содержит штатный результат Baler с возможным бонусом присадки.
function CompetitionProgress:addPickedStrawLiters(farmId, liters, returnedLiters, additiveUsed, fillScale)
	if farmId == nil or farmId < 1 or farmId > 4 or liters == nil or liters <= 0 then
		return
	end

	local previous = self.strawPickedLitersByFarmId[farmId] or 0
	local total = previous + liters
	self.strawPickedLitersByFarmId[farmId] = total

	-- Логируем первый подбор и далее примерно каждые 5000 л, а не каждый вызов processBalerArea().
	local lastLogged = self.lastStrawPickupLogLitersByFarmId[farmId] or 0
	if previous == 0 or total - lastLogged >= 5000 then
		self.lastStrawPickupLogLitersByFarmId[farmId] = total
		CompetitionUtils.info(
			"BALER PICKUP DEBUG material=STRAW farmId=%s removedLiters=%.2f returnedLiters=%.2f additiveUsed=%.4f fillScale=%s totalRemovedLiters=%.2f",
			tostring(farmId),
			liters,
			returnedLiters or liters,
			additiveUsed or 0,
			tostring(fillScale),
			total
		)
	end
end

-- Добавляет объём скошенной травы, фактически удалённый прессом с карты.
-- returnedLiters содержит штатный результат Baler с возможным бонусом присадки.
function CompetitionProgress:addPickedGrassLiters(farmId, liters, returnedLiters, additiveUsed, fillScale)
	if farmId == nil or farmId < 1 or farmId > 4 or liters == nil or liters <= 0 then
		return
	end

	local previous = self.grassPickedLitersByFarmId[farmId] or 0
	local total = previous + liters
	self.grassPickedLitersByFarmId[farmId] = total

	-- Логируем первый подбор и далее примерно каждые 5000 л.
	local lastLogged = self.lastGrassPickupLogLitersByFarmId[farmId] or 0
	if previous == 0 or total - lastLogged >= 5000 then
		self.lastGrassPickupLogLitersByFarmId[farmId] = total
		CompetitionUtils.info(
			"BALER PICKUP DEBUG material=GRASS_WINDROW farmId=%s removedLiters=%.2f returnedLiters=%.2f additiveUsed=%.4f fillScale=%s totalRemovedLiters=%.2f",
			tostring(farmId),
			liters,
			returnedLiters or liters,
			additiveUsed or 0,
			tostring(fillScale),
			total
		)
	end
end

-------------------------------------------------------------------------------
-- 1. ГЛАВНЫЙ ЦИКЛ ОБНОВЛЕНИЯ
-------------------------------------------------------------------------------
function CompetitionProgress:update(dt)
	if not CompetitionUtils.getIsServer() or self.manager.state ~= CompetitionUtils.STATE.RUNNING then 
		return 
	end

	self.scanTimer = self.scanTimer - dt
	if self.scanTimer <= 0 then
		self.scanTimer = self.manager.PROGRESS_SCAN_INTERVAL_MS
		self:scanCompetitionProgress()
	end
end

-------------------------------------------------------------------------------
-- 2. ПОДСЧЕТ ТЮКОВ И ПОДДОНОВ (С УЧЕТОМ GIANTS API)
-------------------------------------------------------------------------------
function CompetitionProgress:scanBalesAndHoney()
	local teamCounts = {}
	for _, config in ipairs(self.manager.activeTeams or {}) do
		if config.farmId >= 1 and config.farmId <= 4 then
			teamCounts[config.farmId] = {
				strawTotal = 0, strawStored = 0,
				grassTotal = 0, grassWrapped = 0, grassStored = 0,
				honeyStored = 0,
				physicalBales = 0, storedBales = 0,
				wrongSizeBales = 0, unknownFillBales = 0,
				partialWrappedBales = 0
			}
		end
	end

	local function getFillName(fillTypeIndex)
		if fillTypeIndex == nil or g_fillTypeManager == nil then
			return nil
		end
		return g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
	end

	local function isRoundBale125(bale)
		return bale ~= nil
			and bale.isRoundbale == true
			and bale.diameter ~= nil
			and math.abs(bale.diameter - self.manager.ROUND_BALE_125_DIAMETER) <= self.manager.ROUND_BALE_125_TOLERANCE
	end

	local function getRegisteredBaleDefinition(xmlFilename)
		if xmlFilename == nil or g_baleManager == nil then
			return nil
		end
		local baleIndex = g_baleManager:getBaleTypeIndexByXMLFilename(xmlFilename)
		if baleIndex == nil then
			return nil
		end
		return g_baleManager.bales ~= nil and g_baleManager.bales[baleIndex] or nil
	end

	-- A) Физические тюки, которые существуют как самостоятельные объекты ItemSystem.
	-- ObjectStorage сохраняет ферментирующие обёрнутые тюки как скрытые Bale с
	-- getNeedsSaving() == false. Штатный ItemSystem:saveToXML() такие объекты
	-- пропускает, поэтому и здесь не считаем их второй раз как физические тюки.
	if g_currentMission.itemSystem ~= nil then
		for _, entry in pairs(g_currentMission.itemSystem.itemsToSave or {}) do
			local item = entry ~= nil and entry.item or nil
			if item ~= nil and (item.className == "Bale" or (item.isa ~= nil and item:isa(Bale))) then
				local shouldCountAsPhysical = item.getNeedsSaving == nil or item:getNeedsSaving()

				if shouldCountAsPhysical then
					local farmId = item.getOwnerFarmId ~= nil and item:getOwnerFarmId() or item.ownerFarmId
					if farmId ~= nil and teamCounts[farmId] ~= nil then
						local counts = teamCounts[farmId]
						counts.physicalBales = counts.physicalBales + 1

						if not isRoundBale125(item) then
							counts.wrongSizeBales = counts.wrongSizeBales + 1
						else
							local fillName = getFillName(item.fillType)
							if fillName == "STRAW" then
								counts.strawTotal = counts.strawTotal + 1
							-- В задании 5 учитываем только траву и полученный из неё силос.
							-- Сено (DRYGRASS_WINDROW/DRYGRASS) намеренно исключено.
							elseif fillName == "GRASS_WINDROW"
								or fillName == "GRASS"
								or fillName == "SILAGE" then

								local wrappingState = item.wrappingState or 0
								counts.grassTotal = counts.grassTotal + 1
								-- В FS25 ферментация и завершённая обёртка начинаются только при состоянии >= 1.
								if wrappingState >= 1 then
									counts.grassWrapped = counts.grassWrapped + 1
								elseif wrappingState > 0 then
									counts.partialWrappedBales = counts.partialWrappedBales + 1
								end
							else
								counts.unknownFillBales = counts.unknownFillBales + 1
							end
						end
					end
				end
			end
		end
	end

	-- B) ObjectStorage. Обычный складированный тюк удаляется из ItemSystem, а
	-- ферментирующий остаётся внутри ObjectStorage скрытым Bale с needsSaving=false.
	-- В обоих случаях storedObjects является единственным источником учёта тюка на складе.
	local placeables = g_currentMission.placeableSystem ~= nil
		and g_currentMission.placeableSystem.placeables
		or g_currentMission.placeables
		or {}

	for _, placeable in pairs(placeables) do
		local farmId = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or placeable.ownerFarmId
		local spec = placeable.spec_objectStorage

		if farmId ~= nil and teamCounts[farmId] ~= nil and spec ~= nil then
			for _, abstractObject in ipairs(spec.storedObjects or {}) do
				local className = abstractObject.REFERENCE_CLASS_NAME

				if className == "Bale" or className == "PackedBale" then
					teamCounts[farmId].storedBales = teamCounts[farmId].storedBales + 1
					local bale = abstractObject.baleObject
					local attrs = abstractObject.baleAttributes

					local fillTypeIndex = bale ~= nil and bale.fillType or (attrs ~= nil and attrs.fillType or nil)
					local fillName = getFillName(fillTypeIndex)
					local is125 = false
					local wrappingState = 0

					if bale ~= nil then
						is125 = isRoundBale125(bale)
						wrappingState = bale.wrappingState or 0
					elseif attrs ~= nil then
						local baleDef = getRegisteredBaleDefinition(attrs.xmlFilename)
						is125 = isRoundBale125(baleDef)
						wrappingState = attrs.wrappingState or 0
					end

					if is125 then
						if fillName == "STRAW" then
							-- Складированный тюк уже отсутствует в ItemSystem,
							-- поэтому он входит и в общее число произведённых, и в число доставленных.
							teamCounts[farmId].strawTotal = teamCounts[farmId].strawTotal + 1
							teamCounts[farmId].strawStored = teamCounts[farmId].strawStored + 1
						-- На складе применяем тот же фильтр: сено не является частью задания 5.
						elseif fillName == "GRASS_WINDROW"
							or fillName == "GRASS"
							or fillName == "SILAGE" then

							-- Любой корректный травяной тюк входит в общее число сформированных тюков.
							-- В прогресс доставки на склад (задание 5.4) засчитываем только
							-- полностью обёрнутые тюки, что подтверждается wrappingState >= 1.
							teamCounts[farmId].grassTotal = teamCounts[farmId].grassTotal + 1

							if wrappingState >= 1 then
								teamCounts[farmId].grassWrapped = teamCounts[farmId].grassWrapped + 1
								teamCounts[farmId].grassStored = teamCounts[farmId].grassStored + 1
							elseif wrappingState > 0 then
								teamCounts[farmId].partialWrappedBales = teamCounts[farmId].partialWrappedBales + 1
							end
						else
							teamCounts[farmId].unknownFillBales = teamCounts[farmId].unknownFillBales + 1
						end
					else
						teamCounts[farmId].wrongSizeBales = teamCounts[farmId].wrongSizeBales + 1
					end

				elseif className == "Vehicle" then
					-- Палеты хранятся как абстрактные объекты «Транспортное средство» (Vehicle).
					local attrs = abstractObject.palletAttributes
					if attrs ~= nil and getFillName(attrs.fillType) == "HONEY" then
						teamCounts[farmId].honeyStored = teamCounts[farmId].honeyStored + 1
					end
				end
			end
		end
	end

	-- Сводку пишем при изменении состава тюков и раз в минуту при отсутствии изменений.
	-- Это сохраняет диагностическую ценность и не повторяет строку каждые 10 секунд.
	for farmId, counts in pairs(teamCounts) do
		local signature = string.format(
			"%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d",
			counts.strawTotal,
			counts.strawStored,
			counts.grassTotal,
			counts.grassWrapped,
			counts.grassStored,
			counts.honeyStored,
			counts.physicalBales,
			counts.storedBales,
			counts.wrongSizeBales,
			counts.unknownFillBales,
			counts.partialWrappedBales
		)

		if self.lastBaleScanSignatureByFarmId[farmId] ~= signature or self.scanCount % 6 == 0 then
			self.lastBaleScanSignatureByFarmId[farmId] = signature
			CompetitionUtils.info(
				"BALE SCAN SUMMARY scan=%s farmId=%s strawRemoved=%.2f strawTotal=%s strawStored=%s grassRemoved=%.2f grassTotal=%s grassWrapped=%s grassStored=%s partialWrapped=%s physicalBales=%s storedBales=%s wrongSize=%s unknownFill=%s honeyStored=%s",
				tostring(self.scanCount),
				tostring(farmId),
				self.strawPickedLitersByFarmId[farmId] or 0,
				tostring(counts.strawTotal),
				tostring(counts.strawStored),
				self.grassPickedLitersByFarmId[farmId] or 0,
				tostring(counts.grassTotal),
				tostring(counts.grassWrapped),
				tostring(counts.grassStored),
				tostring(counts.partialWrappedBales),
				tostring(counts.physicalBales),
				tostring(counts.storedBales),
				tostring(counts.wrongSizeBales),
				tostring(counts.unknownFillBales),
				tostring(counts.honeyStored)
			)
		end
	end

	return teamCounts
end

-- Возвращает зафиксированную при первом старте цель по поддонам мёда.
-- После загрузки сохранения новый CompetitionScanner не используется.
function CompetitionProgress:getExpectedHoneyPallets(farmId, farmlandId)
	local savedTarget = self.manager.expectedHoneyByFarmId ~= nil
		and self.manager.expectedHoneyByFarmId[farmId]
		or nil
	if savedTarget ~= nil and savedTarget > 0 then
		return savedTarget
	end

	-- Для загруженного старого savegame без сохранённой цели ничего не угадываем:
	-- уже восстановленный процент задания 6 должен остаться неизменным.
	if self.manager.loadedCompetitionSave then
		return nil
	end

	if g_competitionScanner == nil or g_competitionScanner.scan == nil then return nil end
	local teamData = g_competitionScanner.scan.teamDataByFarmlandId[farmlandId]
	if teamData ~= nil and teamData.honeyPallets ~= nil then
		local target = math.max(1, #teamData.honeyPallets)
		self.manager.expectedHoneyByFarmId = self.manager.expectedHoneyByFarmId or {}
		self.manager.expectedHoneyByFarmId[farmId] = target
		return target
	end
	return nil
end

-------------------------------------------------------------------------------
-- 3. ГЛАВНЫЙ МЕТОД РАСЧЕТА (ВЫПОЛНЯЕТСЯ ТОЛЬКО НА СЕРВЕРЕ)
-------------------------------------------------------------------------------
function CompetitionProgress:scanCompetitionProgress()
	if not self.manager.progressBaselineCaptured then return end
	self.scanCount = self.scanCount + 1

	local teamCounts = self:scanBalesAndHoney()
	local anyTeamFinished = false

	for _, config in ipairs(self.manager.activeTeams or {}) do
		if config.farmId >= 1 and config.farmId <= 4 and self.manager:isFarmInCompetitionMask(config.farmId) then
			local base = self.manager.progressBaselineByFarmId[config.farmId]
			local expW = self.manager:getExpectedHarvestRowByName(config.farmId, "WHEAT")
			local expG = self.manager:getExpectedHarvestRowByName(config.farmId, "GRASS")

			if base ~= nil then
				-- ЗАДАНИЕ 1 (Вспашка и посев)
				local _, _, p11 = self.manager:scanSavedArea(base.areas.OAT_WITHERED, "baselineGone")
				self.manager:setSubtaskProgress(config.farmId, "task1", "1.1", p11, true)
				local _, _, p12 = self.manager:scanSavedArea(base.areas.OAT_WITHERED, "grassPlanted")
				self.manager:setSubtaskProgress(config.farmId, "task1", "1.2", p12, true)

				-- ЗАДАНИЕ 2 (Пшеница и солома)
				local _, _, p21 = self.manager:scanSavedArea(base.areas.WHEAT, "harvested")
				self.manager:setSubtaskProgress(config.farmId, "task2", "2.1", p21, true)
				self.manager:updateDeliveryProgress(config, "WHEAT", "task2", "2.2")

				-- Подзадание 2.3 состоит из двух внутренних частей:
				-- 1) фактический объём STRAW, подобранный прессом;
				-- 2) фактическое число сформированных круглых тюков 125 см.
				local reqStrawLiters = expW ~= nil and expW.expectedStrawLiters or 0
				local pickedStrawLiters = self.strawPickedLitersByFarmId[config.farmId] or 0
				local pickupPercent = reqStrawLiters > 0 and math.min(100, (pickedStrawLiters / reqStrawLiters) * 100) or 0

				local reqStrawBales = expW ~= nil and expW.fullRoundBales125 or 0
				local formedBalesPercent = reqStrawBales > 0
					and math.min(100, (teamCounts[config.farmId].strawTotal / reqStrawBales) * 100)
					or 0

				local p23 = (pickupPercent + formedBalesPercent) * 0.5
				local p24 = reqStrawBales > 0
					and math.min(100, (teamCounts[config.farmId].strawStored / reqStrawBales) * 100)
					or 0

				-- Диагностика расхождения теоретического и фактически подобранного объёма соломы.
				CompetitionUtils.info(
					"STRAW PROGRESS DEBUG farmId=%s expectedLiters=%.2f pickedLiters=%.2f delta=%.2f expectedBales=%s totalBales=%s storedBales=%s pickupPct=%.2f formedPct=%.2f p23=%.2f p24=%.2f",
					tostring(config.farmId),
					reqStrawLiters,
					pickedStrawLiters,
					pickedStrawLiters - reqStrawLiters,
					tostring(reqStrawBales),
					tostring(teamCounts[config.farmId].strawTotal),
					tostring(teamCounts[config.farmId].strawStored),
					pickupPercent,
					formedBalesPercent,
					p23,
					p24
				)

				self.manager:setSubtaskProgress(config.farmId, "task2", "2.3", p23, true)
				self.manager:setSubtaskProgress(config.farmId, "task2", "2.4", p24, true)

				-- ЗАДАНИЕ 3 (Картофель)
				local _, _, p31 = self.manager:scanSavedArea(base.areas.POTATO, "potatoTopped")
				self.manager:setSubtaskProgress(config.farmId, "task3", "3.1", p31, true)
				local _, _, p32 = self.manager:scanSavedArea(base.areas.POTATO, "harvested")
				self.manager:setSubtaskProgress(config.farmId, "task3", "3.2", p32, true)
				self.manager:updateDeliveryProgress(config, "POTATO", "task3", "3.3")

				-- ЗАДАНИЕ 4 (Кукуруза)
				local _, _, p41 = self.manager:scanSavedArea(base.areas.MAIZE, "harvested")
				self.manager:setSubtaskProgress(config.farmId, "task4", "4.1", p41, true)
				self.manager:updateDeliveryProgress(config, "MAIZE", "task4", "4.2")

				-- ЗАДАНИЕ 5 (Трава и силос)
				local _, _, p51 = self.manager:scanSavedArea(base.areas.GRASS, "cut")
				self.manager:setSubtaskProgress(config.farmId, "task5", "5.1", p51, true)

				-- Подзадание 5.2 считаем так же, как 2.3 для соломы:
				-- 1) фактический объём GRASS_WINDROW, подобранный прессом;
				-- 2) фактическое число сформированных круглых тюков 125 см.
				local reqGrassLiters = expG ~= nil and expG.expectedGrassLiters or 0
				local pickedGrassLiters = self.grassPickedLitersByFarmId[config.farmId] or 0
				local grassPickupPercent = reqGrassLiters > 0
					and math.min(100, (pickedGrassLiters / reqGrassLiters) * 100)
					or 0

				local reqGrassBales = expG ~= nil and expG.expectedGrassBales125 or 0
				local grassFormedBalesPercent = reqGrassBales > 0
					and math.min(100, (teamCounts[config.farmId].grassTotal / reqGrassBales) * 100)
					or 0

				local p52 = (grassPickupPercent + grassFormedBalesPercent) * 0.5
				local p53 = reqGrassBales > 0
					and math.min(100, (teamCounts[config.farmId].grassWrapped / reqGrassBales) * 100)
					or 0
				local p54 = reqGrassBales > 0
					and math.min(100, (teamCounts[config.farmId].grassStored / reqGrassBales) * 100)
					or 0

				if (reqGrassLiters <= 0 or reqGrassBales <= 0)
					and self.invalidGrassTargetsLoggedByFarmId[config.farmId] ~= true then

					self.invalidGrassTargetsLoggedByFarmId[config.farmId] = true
					CompetitionUtils.warning(
						"GRASS TARGET INVALID farmId=%s expG=%s expectedHarvestLiters=%s expectedGrassLiters=%s expectedGrassBales125=%s; pickupPct=%.2f formedPct=%.2f",
						tostring(config.farmId),
						tostring(expG ~= nil),
						tostring(expG ~= nil and expG.expectedLiters or nil),
						tostring(expG ~= nil and expG.expectedGrassLiters or nil),
						tostring(expG ~= nil and expG.expectedGrassBales125 or nil),
						grassPickupPercent,
						grassFormedBalesPercent
					)
				end

				CompetitionUtils.info(
					"GRASS PROGRESS DEBUG farmId=%s expectedHarvestLiters=%s expectedGrassLiters=%.2f pickedGrassLiters=%.2f delta=%.2f expectedBales=%s totalBales=%s wrappedBales=%s storedBales=%s pickupPct=%.2f formedPct=%.2f p52=%.2f p53=%.2f p54=%.2f",
					tostring(config.farmId),
					tostring(expG ~= nil and expG.expectedLiters or nil),
					reqGrassLiters,
					pickedGrassLiters,
					pickedGrassLiters - reqGrassLiters,
					tostring(reqGrassBales),
					tostring(teamCounts[config.farmId].grassTotal),
					tostring(teamCounts[config.farmId].grassWrapped),
					tostring(teamCounts[config.farmId].grassStored),
					grassPickupPercent,
					grassFormedBalesPercent,
					p52,
					p53,
					p54
				)

				self.manager:setSubtaskProgress(config.farmId, "task5", "5.2", p52, false)
				self.manager:setSubtaskProgress(config.farmId, "task5", "5.3", p53, false)
				self.manager:setSubtaskProgress(config.farmId, "task5", "5.4", p54, false)

				-- ЗАДАНИЕ 6 (Мёд): требуется только доставка на склад.
				local reqHoney = self:getExpectedHoneyPallets(config.farmId, config.farmlandId)
				if reqHoney ~= nil and reqHoney > 0 then
					local p61 = (teamCounts[config.farmId].honeyStored / reqHoney) * 100
					self.manager:setSubtaskProgress(config.farmId, "task6", "6.1", p61, true)
				end

				-- Пересчет средних значений
				self.manager:recalculateProgressAggregates(config.farmId)

				-- Проверка на финиш (СТРОГАЯ - П.15 ТЗ: 100% по КАЖДОМУ подзаданию)
				if self:checkTeamFinishedStrict(config.farmId) then
					anyTeamFinished = true
				end
			end
		end
	end

	-- Отправляем обновленный прогресс всем клиентам.
	g_server:broadcastEvent(CompetitionProgressSyncEvent.new(self.manager.progressByFarmId))

	-- Триггерим финиш.
	if anyTeamFinished then 
		self.manager:finishCompetition() 
	end
end

-------------------------------------------------------------------------------
-- 4. ПРОВЕРКА УСЛОВИЯ ПОБЕДЫ (СТРОГО 100%)
-------------------------------------------------------------------------------
function CompetitionProgress:checkTeamFinishedStrict(farmId)
	local farmData = self.manager.progressByFarmId[farmId]
	if farmData == nil or farmData.tasks == nil then return false end

	for taskId, taskData in pairs(farmData.tasks) do
		for subtaskId, percent in pairs(taskData.subtasks) do
			-- Проверяем с точностью до сотых, как требует ТЗ.
			if percent < 99.99 then 
				return false 
			end
		end
	end

	CompetitionUtils.info("Команда farmId=%d достигла 100%% по всем заданиям!", farmId)
	return true
end
