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
	self:installBalerPickupHook()
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

	-- A) Физические тюки, которые всё ещё существуют как объекты ItemSystem.
	-- FarmManager в FS25 использует itemSystem.itemsToSave и entry.item.
	if g_currentMission.itemSystem ~= nil then
		for _, entry in pairs(g_currentMission.itemSystem.itemsToSave or {}) do
			local item = entry ~= nil and entry.item or nil
			if item ~= nil and (item.className == "Bale" or (item.isa ~= nil and item:isa(Bale))) then
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
						elseif fillName == "GRASS_WINDROW"
							or fillName == "DRYGRASS_WINDROW"
							or fillName == "DRYGRASS"
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

	-- B) ObjectStorage. После помещения тюка на склад физический объект ItemSystem
	-- исчезает, поэтому storedObjects должен участвовать и в общем количестве
	-- произведённых тюков, и в количестве доставленных тюков.
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
						elseif fillName == "GRASS_WINDROW"
							or fillName == "DRYGRASS_WINDROW"
							or fillName == "DRYGRASS"
							or fillName == "GRASS"
							or fillName == "SILAGE" then

							-- Аналогично соломе: после складирования тюк исчезает из ItemSystem,
							-- поэтому сохраняем его в общем количестве произведённых тюков.
							teamCounts[farmId].grassTotal = teamCounts[farmId].grassTotal + 1
							teamCounts[farmId].grassStored = teamCounts[farmId].grassStored + 1

							if wrappingState >= 1 then
								teamCounts[farmId].grassWrapped = teamCounts[farmId].grassWrapped + 1
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

-- Получить предстартовое количество мёда из CompetitionScanner.
function CompetitionProgress:getExpectedHoneyPallets(farmlandId)
	if g_competitionScanner == nil or g_competitionScanner.scan == nil then return 5 end
	local teamData = g_competitionScanner.scan.teamDataByFarmlandId[farmlandId]
	if teamData ~= nil and teamData.honeyPallets ~= nil then
		return math.max(1, #teamData.honeyPallets)
	end
	return 1
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
				local reqHoney = self:getExpectedHoneyPallets(config.farmlandId)
				local p61 = (teamCounts[config.farmId].honeyStored / reqHoney) * 100
				self.manager:setSubtaskProgress(config.farmId, "task6", "6.1", p61, true)

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
