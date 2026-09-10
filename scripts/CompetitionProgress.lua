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
	self:installBalerPickupHook()
	return self
end

-- Runtime-only counters. The competition start code resets these immediately
-- before STATE.RUNNING, after all baseline scans have completed.
function CompetitionProgress:resetRuntimeCounters()
	self.strawPickedLitersByFarmId = {}
	for farmId = 1, 4 do
		self.strawPickedLitersByFarmId[farmId] = 0
	end
end

-- FS25 Baler:processBalerArea() returns the actual liters removed from the
-- density-map height layer. On the server spec_baler.fillEffectType is set to
-- the fill type that was picked up. Hook it once and accumulate only STRAW.
function CompetitionProgress:installBalerPickupHook()
	if CompetitionProgress.balerPickupHookInstalled == true then
		return
	end
	if Baler == nil or Baler.processBalerArea == nil then
		CompetitionUtils.warning("Baler.processBalerArea unavailable; straw pickup counter not installed")
		return
	end

	CompetitionProgress.balerPickupHookInstalled = true
	CompetitionProgress.originalProcessBalerArea = Baler.processBalerArea

	Baler.processBalerArea = function(vehicle, workArea, dt)
		local pickedUpLiters, processedLiters = CompetitionProgress.originalProcessBalerArea(vehicle, workArea, dt)

		if pickedUpLiters ~= nil and pickedUpLiters > 0
			and vehicle ~= nil
			and vehicle.isServer == true
			and vehicle.spec_baler ~= nil
			and vehicle.spec_baler.fillEffectType == FillType.STRAW
			and g_competitionManager ~= nil
			and g_competitionManager.progress ~= nil
			and g_competitionManager.state == CompetitionUtils.STATE.RUNNING then

			local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
			if farmId ~= nil and farmId >= 1 and farmId <= 4
				and g_competitionManager:isFarmInCompetitionMask(farmId) then
				g_competitionManager.progress:addPickedStrawLiters(farmId, pickedUpLiters)
			end
		end

		return pickedUpLiters, processedLiters
	end
end

function CompetitionProgress:addPickedStrawLiters(farmId, liters)
	if farmId == nil or farmId < 1 or farmId > 4 or liters == nil or liters <= 0 then
		return
	end
	self.strawPickedLitersByFarmId[farmId] = (self.strawPickedLitersByFarmId[farmId] or 0) + liters
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
				honeyStored = 0
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
				if farmId ~= nil and teamCounts[farmId] ~= nil and isRoundBale125(item) then
					local fillName = getFillName(item.fillType)
					CompetitionUtils.info(
						"BALE DEBUG physical farmId=%s fillType=%s fillLevel=%s xml=%s diameter=%s wrappingState=%s",
						tostring(farmId),
						tostring(fillName),
						tostring(item.fillLevel),
						tostring(item.xmlFilename),
						tostring(item.diameter),
						tostring(item.wrappingState)
					)
					if fillName == "STRAW" then
						teamCounts[farmId].strawTotal = teamCounts[farmId].strawTotal + 1
					elseif fillName == "DRYGRASS" or fillName == "GRASS" or fillName == "SILAGE" then
						teamCounts[farmId].grassTotal = teamCounts[farmId].grassTotal + 1

						if (item.wrappingState or 0) > 0 then
							teamCounts[farmId].grassWrapped = teamCounts[farmId].grassWrapped + 1
						end
					end
				end
			end
		end
	end

	-- B) ObjectStorage. FS25 хранит принятые объекты в placeable.spec_objectStorage.storedObjects 
	-- в виде абстрактных объектов типа Bale (тюк) или Vehicle (транспортное средство).
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
					local bale = abstractObject.baleObject
					local attrs = abstractObject.baleAttributes

					local fillTypeIndex = bale ~= nil and bale.fillType or (attrs ~= nil and attrs.fillType or nil)
					local fillName = getFillName(fillTypeIndex)
					CompetitionUtils.info(
						"BALE DEBUG stored farmId=%s fillType=%s fillLevel=%s xml=%s wrappingState=%s",
						tostring(farmId),
						tostring(fillName),
						tostring(attrs ~= nil and attrs.fillLevel or nil),
						tostring(attrs ~= nil and attrs.xmlFilename or nil),
						tostring(wrappingState)
					)
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
							-- Stored bale is no longer a physical ItemSystem bale,
							-- so include it in total produced and in stored count.
							teamCounts[farmId].strawTotal = teamCounts[farmId].strawTotal + 1
							teamCounts[farmId].strawStored = teamCounts[farmId].strawStored + 1
						elseif fillName == "DRYGRASS" or fillName == "GRASS" or fillName == "SILAGE" then
							teamCounts[farmId].grassTotal = teamCounts[farmId].grassTotal + 1
							teamCounts[farmId].grassStored = teamCounts[farmId].grassStored + 1

							if wrappingState > 0 then
								teamCounts[farmId].grassWrapped = teamCounts[farmId].grassWrapped + 1
							end
						end
					end

				elseif className == "Vehicle" then
					-- Pallets are stored as abstract Vehicle objects.
					local attrs = abstractObject.palletAttributes
					if attrs ~= nil and getFillName(attrs.fillType) == "HONEY" then
						teamCounts[farmId].honeyStored = teamCounts[farmId].honeyStored + 1
					end
				end
			end
		end
	end

	return teamCounts
end

-- Получить предстартовое количество мёда из CompetitionScanner
function CompetitionProgress:getExpectedHoneyPallets(farmlandId)
	if g_competitionScanner == nil or g_competitionScanner.scan == nil then return 5 end -- Запасной фоллбэк
	local teamData = g_competitionScanner.scan.teamDataByFarmlandId[farmlandId]
	if teamData ~= nil and teamData.honeyPallets ~= nil then
		return math.max(1, #teamData.honeyPallets) -- Защита от деления на 0
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
				
				-- Task 2.3 has two INTERNAL stages but remains one real subtask:
				--   1) actual STRAW liters picked up from the ground by the baler;
				--   2) required number of 125 cm round bales actually formed.
				-- Each internal stage contributes 50% of the visible subtask.
				local reqStrawLiters = expW ~= nil and expW.expectedStrawLiters or 0
				local pickedStrawLiters = self.strawPickedLitersByFarmId[config.farmId] or 0
				local pickupPercent = reqStrawLiters > 0 and math.min(100, (pickedStrawLiters / reqStrawLiters) * 100) or 0

				local reqStrawBales = expW ~= nil and expW.fullRoundBales125 or 0
				local formedBalesPercent = reqStrawBales > 0
					and math.min(100, (teamCounts[config.farmId].strawTotal / reqStrawBales) * 100)
					or 0

				local p23 = (pickupPercent + formedBalesPercent) * 0.5
				local p24 = reqStrawBales > 0
					and (teamCounts[config.farmId].strawStored / reqStrawBales) * 100
					or 0

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
				
				local reqGrassBales = expG ~= nil and expG.expectedGrassBales125 or 1
				local p52 = (teamCounts[config.farmId].grassTotal / reqGrassBales) * 100
				local p53 = (teamCounts[config.farmId].grassWrapped / reqGrassBales) * 100
				local p54 = (teamCounts[config.farmId].grassStored / reqGrassBales) * 100
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

	-- Отправляем обновленный прогресс всем клиентам
	g_server:broadcastEvent(CompetitionProgressSyncEvent.new(self.manager.progressByFarmId))

	-- Триггерим финиш
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
			-- Проверяем с точностью до сотых, как требует ТЗ
			if percent < 99.99 then 
				return false 
			end
		end
	end
	
	CompetitionUtils.info("Команда farmId=%d достигла 100%% по всем заданиям!", farmId)
	return true
end