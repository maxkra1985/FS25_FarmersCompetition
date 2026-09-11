--[[
	FS25 FarmersCompetition - Core Manager
	Version 0.2.7-Refactored
	Главный класс-контроллер соревнования. 
]]

local modDir = g_currentModDirectory
source(Utils.getFilename("scripts/CompetitionUtils.lua", modDir))
source(Utils.getFilename("scripts/CompetitionNetwork.lua", modDir))
source(Utils.getFilename("scripts/CompetitionSecurity.lua", modDir))
source(Utils.getFilename("scripts/CompetitionUI.lua", modDir))
source(Utils.getFilename("scripts/CompetitionProgress.lua", modDir))
source(Utils.getFilename("scripts/CompetitionScanner.lua", modDir))

CompetitionManager = {}
local CompetitionManager_mt = Class(CompetitionManager)

function CompetitionManager.new(customMt)
	local self = setmetatable({}, customMt or CompetitionManager_mt)
	
	self.initialized = false
	self.mapLoaded = false
	self.state = CompetitionUtils.STATE.WAITING_FOR_PLAYERS

	self.initTimer = 1500
	self.syncTimer = 3500
	self.reconcileTimer = 0

	self.activeTeams = {}
	self.readyByUserId = {}
	self.connectedUserIds = {}
	
	self.pendingTeleportFarmId = nil
	self.pendingTeleportTimer = nil
	self.lastTeleportedFarmId = nil

	self.baselineScanRequested = false
	self.baselineScanInProgress = false
	self.progressBaselineCaptured = false
	
	self.progressByFarmId = {}
	self.progressBaselineByFarmId = {}
	self.progressStorageByFarmId = {}
	self.expectedHarvestByFarmId = {}
	self.finalStandings = {}
	
	self.competitionElapsedMs = 0
	self.competitionClockSyncTimer = 0
	self.competitionTeamMask = 0

	self.welcomeShown = false
	self.welcomeClosed = false

	self.security = CompetitionSecurity.new(self)
	self.ui = CompetitionUI.new(self)
	self.progress = CompetitionProgress.new(self)

	-- Константы для UI и сканера
	self.PROGRESS_SCAN_INTERVAL_MS = 10000
	self.EXPECTED_HARVEST_BEE_TILE_SIZE = 24
	self.ROUND_BALE_125_DIAMETER = 1.25
	self.ROUND_BALE_125_TOLERANCE = 0.015
	self.COMPETITION_DURATION_SECONDS = nil

	self.PROGRESS_AREA_DEFS = {
		{key="OAT_WITHERED", fruitName="OAT", mode="withered"},
		{key="WHEAT",        fruitName="WHEAT", mode="harvestReady"},
		{key="POTATO",       fruitName="POTATO", mode="any"},
		{key="MAIZE",        fruitName="MAIZE", mode="harvestReady"},
		{key="GRASS",        fruitName="GRASS", mode="harvestReady"}
	}
	self.EXPECTED_HARVEST_TASK_FRUITS = {"GRASS", "WHEAT", "POTATO", "MAIZE"}

	self.TASKS = {
		{ id = "task1", title = "Задание 1", subtasks = { {id="1.1", title="Перепахать поле с засохшими растениями"}, {id="1.2", title="Посеять траву"} } },
		{ id = "task2", title = "Задание 2", subtasks = { {id="2.1", title="Убрать урожай пшеницы"}, {id="2.2", title="Отвезти пшеницу в зерновой элеватор"}, {id="2.3", title="Стюковать солому в круглые тюки диаметром 125"}, {id="2.4", title="Перевезти тюки на склад"} } },
		{ id = "task3", title = "Задание 3", subtasks = { {id="3.1", title="Скосить картофельную ботву"}, {id="3.2", title="Убрать урожай картофеля"}, {id="3.3", title="Перевезти собранный урожай в овощехранилище"} } },
		{ id = "task4", title = "Задание 4", subtasks = { {id="4.1", title="Собрать урожай кукурузы"}, {id="4.2", title="Перевезти собранный урожай в зерновой элеватор"} } },
		{ id = "task5", title = "Задание 5", subtasks = { {id="5.1", title="Скосить траву"}, {id="5.2", title="Стюковать траву в круглые тюки диаметром 125"}, {id="5.3", title="Обернуть тюки плёнкой"}, {id="5.4", title="Перевезти тюки на склад"} } },
		{ id = "task6", title = "Задание 6", subtasks = { {id="6.1", title="Перевезти мёд на склад"} } }
	}
	self.STARTING_TEXT = "Фиксируется стартовое состояние карты. Дождитесь начала соревнования."
	self.READY_TEXT_LINE1 = "Ознакомьтесь с правилами проведения соревнований и перечнем заданий."
	self.READY_TEXT_LINE2 = "По готовности нажмите ENTER."

	return self
end

function CompetitionManager:loadMap(mapName)
	self.mapLoaded = true
	g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self.onPlayerFarmChanged, self)
	if g_inputBinding ~= nil and InputAction ~= nil and InputAction.COMPETITION_READY ~= nil then
		local success, actionEventId = g_inputBinding:registerActionEvent(InputAction.COMPETITION_READY, self, self.actionEventReady, false, true, false, true)
		if success then
			self.readyActionEventId = actionEventId
			g_inputBinding:setActionEventTextVisibility(actionEventId, false)
		end
	end
	self.security:installPreStartHooks()
end

function CompetitionManager:deleteMap()
	self.mapLoaded = false
	self.security:restorePreStartTime(true)
	g_messageCenter:unsubscribeAll(self)
	if self.readyActionEventId ~= nil and g_inputBinding ~= nil then g_inputBinding:removeActionEvent(self.readyActionEventId) end
end

-------------------------------------------------------------------------------
-- ИНИЦИАЛИЗАЦИЯ И ЦВЕТА ФЕРМ
-------------------------------------------------------------------------------
function CompetitionManager:findClosestFarmColorIndex(targetColor)
	if Farm == nil or Farm.COLORS == nil or #Farm.COLORS == 0 then return 1 end
	local bestIndex = 1; local bestDistance = math.huge
	for index, color in ipairs(Farm.COLORS) do
		local dr = (color[1] or 0) - targetColor[1]
		local dg = (color[2] or 0) - targetColor[2]
		local db = (color[3] or 0) - targetColor[3]
		local distance = dr * dr + dg * dg + db * db
		if distance < bestDistance then bestDistance = distance; bestIndex = index end
	end
	return bestIndex
end

function CompetitionManager:setFarmBalanceZero(farm)
	if farm == nil then return end
	farm.money = 0; farm.lastMoneySent = 0; farm.lastMoneyPublished = 0
	if farm.raiseDirtyFlags ~= nil and farm.farmMoneyDirtyFlag ~= nil then farm:raiseDirtyFlags(farm.farmMoneyDirtyFlag) end
	if g_messageCenter ~= nil and MessageType.MONEY_CHANGED ~= nil then g_messageCenter:publish(MessageType.MONEY_CHANGED, farm.farmId, farm.money) end
end

function CompetitionManager:initializeSession()
	if g_currentMission == nil or not g_currentMission.isLoaded then return false end
	if g_farmlandManager == nil or g_farmManager == nil then return false end
	local farmlandMap = g_farmlandManager:getLocalMap()
	if farmlandMap == nil or farmlandMap == 0 then return false end
	
	self.activeTeams = {}
	for _, config in ipairs(CompetitionUtils.TEAM_CONFIG) do
		if config.farmId >= 1 and config.farmId <= 4 and g_farmlandManager:getIsValidFarmlandId(config.farmlandId) then
			config.presentInInfoLayer = true
			
			-- Вычисляем цвета для UI и игры
			config.colorIndex = self:findClosestFarmColorIndex(config.desiredColor)
			local c = Farm.COLORS[config.colorIndex] or {1, 1, 1, 1}
			config.actualColor = {c[1], c[2], c[3], c[4]}

			-- Распределяем спавны по углам карты, чтобы игроки не застревали друг в друге
			if config.farmId == 1 then config.spawnX = -200 
			elseif config.farmId == 2 then config.spawnX = 200 
			elseif config.farmId == 3 then config.spawnX = -600 
			else config.spawnX = 600 end
			
			table.insert(self.activeTeams, config)
		end
	end

	CompetitionUtils.ADMIN_CONFIG.colorIndex = self:findClosestFarmColorIndex(CompetitionUtils.ADMIN_CONFIG.desiredColor)
	local ac = Farm.COLORS[CompetitionUtils.ADMIN_CONFIG.colorIndex] or {1, 1, 1, 1}
	CompetitionUtils.ADMIN_CONFIG.actualColor = {ac[1], ac[2], ac[3], ac[4]}

	if #self.activeTeams == 0 then return false end

	if CompetitionUtils.getIsServer() and CompetitionUtils.getIsMultiplayer() then
		for _, config in ipairs(self.activeTeams) do
			local farm = g_farmManager:getFarmById(config.farmId)
			if farm == nil then 
				farm = g_farmManager:createFarm(config.farmName, config.colorIndex, nil, config.farmId) 
			else
				farm.name = config.farmName
				farm.color = config.colorIndex
			end
			self:setFarmBalanceZero(farm)

			-- Участки соревнования принадлежат только соответствующим фермам 1-4.
			-- FarmlandManager:setLandOwnership() обновляет mapping, Farmland и hotspot.
			local ownershipApplied = g_farmlandManager:setLandOwnership(config.farmlandId, config.farmId, true)
			if not ownershipApplied then
				CompetitionUtils.error("Не удалось назначить farmland %d ферме %d", config.farmlandId, config.farmId)
			else
				CompetitionUtils.info("Farmland %d назначен ферме %d (%s)", config.farmlandId, config.farmId, config.farmName)
			end
		end
		local adminFarm = g_farmManager:getFarmById(CompetitionUtils.ADMIN_FARM_ID)
		if adminFarm == nil then
			adminFarm = g_farmManager:createFarm(CompetitionUtils.ADMIN_CONFIG.farmName, CompetitionUtils.ADMIN_CONFIG.colorIndex, nil, CompetitionUtils.ADMIN_FARM_ID)
		end
		self:setFarmBalanceZero(adminFarm)
	end

	self.initialized = true
	if CompetitionUtils.getIsServer() then 
		self:reconcileConnectedUsers()
		self:evaluateServerState() 
	end
	
	if g_localPlayer ~= nil then
		local currentFarm = g_localPlayer.farmId
		if CompetitionUtils.isCompetitionFarmId(currentFarm) then
			self.pendingTeleportFarmId = currentFarm
			self.pendingTeleportTimer = 250
		end
	end
	
	CompetitionUtils.info("Инициализация успешно завершена. Команд найдено: %d", #self.activeTeams)
	return true
end

-------------------------------------------------------------------------------
-- ПРАВА И ГЕТТЕРЫ ДЛЯ ИНТЕРФЕЙСА
-------------------------------------------------------------------------------
function CompetitionManager:ensureFarmManagerRights(userId, farmId)
	if not CompetitionUtils.getIsServer() or userId == nil or not CompetitionUtils.isCompetitionFarmId(farmId) then return false end
	local farm = g_farmManager:getFarmById(farmId)
	if farm == nil or farm.getUserByUserId == nil then return false end
	local playerData = farm:getUserByUserId(userId)
	if playerData == nil then return false end
	local changed = playerData.isFarmManager ~= true
	playerData.isFarmManager = true
	playerData.permissions = playerData.permissions or {}
	if Farm ~= nil and Farm.PERMISSIONS ~= nil then
		for _, permission in ipairs(Farm.PERMISSIONS) do
			if playerData.permissions[permission] ~= true then playerData.permissions[permission] = true; changed = true end
		end
	end
	if changed and PlayerPermissionsEvent ~= nil and PlayerPermissionsEvent.sendEvent ~= nil then
		PlayerPermissionsEvent.sendEvent(userId, playerData.permissions, true)
	end
	return true
end

function CompetitionManager:getCompetitionFarmConfig(farmId)
	if farmId == CompetitionUtils.ADMIN_FARM_ID then return CompetitionUtils.ADMIN_CONFIG end
	for _, config in ipairs(self.activeTeams) do
		if config.farmId == farmId then return config end
	end
	return nil
end

function CompetitionManager:isUserEligible(userId)
	return CompetitionUtils.isCompetitionFarmId(CompetitionUtils.getFarmIdForUserId(userId))
end

function CompetitionManager:getTeamPlayerRows(team)
	local rows = {}
	local farm = g_farmManager ~= nil and g_farmManager:getFarmById(team.farmId) or nil
	if farm ~= nil then
		for _, activeUser in ipairs(farm.activeUsers or {}) do
			table.insert(rows, {userId = activeUser.userId, name = CompetitionUtils.getUserNickname(activeUser.userId), ready = self.readyByUserId[activeUser.userId] == true})
		end
	end
	table.sort(rows, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return rows
end

function CompetitionManager:getAdminRows()
	local rows = {}
	local farm = g_farmManager ~= nil and g_farmManager:getFarmById(CompetitionUtils.ADMIN_FARM_ID) or nil
	if farm ~= nil then
		for _, activeUser in ipairs(farm.activeUsers or {}) do
			table.insert(rows, {userId = activeUser.userId, name = CompetitionUtils.getUserNickname(activeUser.userId), ready = self.readyByUserId[activeUser.userId] == true})
		end
	end
	table.sort(rows, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return rows
end

function CompetitionManager:getUnassignedRows()
	local rows = {}
	if g_farmManager ~= nil then
		for _, farm in ipairs(g_farmManager:getFarms() or {}) do
			if not CompetitionUtils.isCompetitionFarmId(farm.farmId) then
				for _, activeUser in ipairs(farm.activeUsers or {}) do
					table.insert(rows, {userId = activeUser.userId, name = CompetitionUtils.getUserNickname(activeUser.userId), ready = false, unassigned = true})
				end
			end
		end
	end
	table.sort(rows, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return rows
end

function CompetitionManager:getProgressTeams()
	local teams = {}
	for _, team in ipairs(self.activeTeams or {}) do
		local include = self:isFarmInCompetitionMask(team.farmId)
		if (self.competitionTeamMask or 0) == 0 then include = #self:getTeamPlayerRows(team) > 0 end
		if include then table.insert(teams, team) end
	end
	table.sort(teams, function(a, b) return a.farmId < b.farmId end)
	return teams
end

function CompetitionManager:getProgressPercent(farmId, taskId, subtaskId)
	local farmData = self.progressByFarmId[farmId]
	if farmData == nil then return 0 end
	if taskId == nil then return math.max(0, math.min(100, farmData.overall or 0)) end
	local taskData = farmData.tasks ~= nil and farmData.tasks[taskId] or nil
	if taskData == nil then return 0 end
	if subtaskId == nil then return math.max(0, math.min(100, taskData.overall or 0)) end
	local value = taskData.subtasks ~= nil and taskData.subtasks[subtaskId] or 0
	return math.max(0, math.min(100, value or 0))
end

function CompetitionManager:captureCompetitionTeamMask()
	local mask = 0
	for _, team in ipairs(self.activeTeams or {}) do
		if team.farmId >= 1 and team.farmId <= 4 and #self:getTeamPlayerRows(team) > 0 then mask = mask + 2 ^ (team.farmId - 1) end
	end
	return mask
end

function CompetitionManager:isFarmInCompetitionMask(farmId)
	local mask = self.competitionTeamMask or 0
	if farmId == nil or farmId < 1 or farmId > 4 or mask <= 0 then return false end
	local bitValue = 2 ^ (farmId - 1)
	return math.floor(mask / bitValue) % 2 == 1
end

-------------------------------------------------------------------------------
-- ИГРОВАЯ ЛОГИКА И СЕТЬ
-------------------------------------------------------------------------------
function CompetitionManager:onPlayerFarmChanged(player)
	if player == nil then return end
	local farmId = player.farmId

	if CompetitionUtils.getIsServer() then
		if self.state < CompetitionUtils.STATE.STARTING then self.readyByUserId[player.userId] = false end
		self:ensureFarmManagerRights(player.userId, farmId)
		self:evaluateServerState()
	end

	if g_localPlayer ~= nil and player == g_localPlayer then
		if CompetitionUtils.isCompetitionFarmId(farmId) and self.lastTeleportedFarmId ~= farmId then
			self.pendingTeleportFarmId = farmId
			self.pendingTeleportTimer = 150
		end
	end
end

function CompetitionManager:teleportLocalPlayerToTeam(farmId)
	if g_localPlayer == nil then return false end
	local config = self:getCompetitionFarmConfig(farmId)
	if config == nil or config.spawnX == nil then return false end
	
	local x, z = config.spawnX, -40
	local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
	local y = terrainY + 0.2
	
	if g_localPlayer.teleportTo ~= nil then g_localPlayer:teleportTo(x, y, z, true, false)
	elseif g_localPlayer.rootNode ~= nil and g_localPlayer.rootNode ~= 0 then setWorldTranslation(g_localPlayer.rootNode, x, y, z) end
	
	self.lastTeleportedFarmId = farmId
	self.pendingTeleportFarmId = nil
	return true
end

function CompetitionManager:handleLocalReady()
	local userId = CompetitionUtils.getLocalUserId()
	if userId == nil or not self:isUserEligible(userId) then return end
	if CompetitionUtils.getIsServer() then 
		self.readyByUserId[userId] = true
		self:evaluateServerState()
		g_server:broadcastEvent(CompetitionReadyStateEvent.new(userId, true, self.state))
	elseif g_client ~= nil then 
		g_client:getServerConnection():sendEvent(CompetitionReadyRequestEvent.new()) 
	end
end

function CompetitionManager:actionEventReady() self:handleLocalReady() end

function CompetitionManager:reconcileConnectedUsers()
	if not CompetitionUtils.getIsServer() then return end
	local current = {}
	if g_farmManager ~= nil then
		for _, farm in ipairs(g_farmManager:getFarms() or {}) do
			for _, activeUser in ipairs(farm.activeUsers or {}) do
				current[activeUser.userId] = true
				if self.readyByUserId[activeUser.userId] == nil then self.readyByUserId[activeUser.userId] = false end
				self:ensureFarmManagerRights(activeUser.userId, farm.farmId)
			end
		end
	end
	for userId, _ in pairs(self.readyByUserId) do
		if not current[userId] then self.readyByUserId[userId] = nil end
	end
end

function CompetitionManager:evaluateServerState()
	if not CompetitionUtils.getIsServer() or self.state >= CompetitionUtils.STATE.STARTING then return end
	local allReady = true; local hasPlayers = false
	for userId, isReady in pairs(self.readyByUserId) do
		local farmId = CompetitionUtils.getFarmIdForUserId(userId)
		if CompetitionUtils.isCompetitionFarmId(farmId) then
			hasPlayers = true; if not isReady then allReady = false end
		else allReady = false end
	end
	local newState = hasPlayers and CompetitionUtils.STATE.WAITING_FOR_READY or CompetitionUtils.STATE.WAITING_FOR_PLAYERS
	if newState ~= self.state then
		self.state = newState; g_server:broadcastEvent(CompetitionSyncStateEvent.new(self.state, self.readyByUserId))
	end
	if newState == CompetitionUtils.STATE.WAITING_FOR_READY and allReady and hasPlayers then self:startCompetition() end
end

function CompetitionManager:startCompetition()
	self.state = CompetitionUtils.STATE.STARTING
	g_server:broadcastEvent(CompetitionSyncStateEvent.new(self.state, self.readyByUserId))
	if g_competitionScanner ~= nil then
		self.baselineScanRequested = true; g_competitionScanner:startScan("competitionStart")
	end
end

function CompetitionManager:finishCompetitionStart()
	if not CompetitionUtils.getIsServer() then return end
	self.baselineScanRequested = false
	
	-- ЗАПУСКАЕМ СБОР БАЗОВЫХ ДАННЫХ ПЕРЕД СТАРТОМ
	if not self:captureCompetitionProgressBaseline() then return end
	if not self:captureExpectedHarvestBaseline() then return end
	self:captureProgressStorageBaseline()

	-- Runtime counters start exactly when the competition becomes RUNNING.
	-- Loose straw does not exist at baseline; it is produced by harvesting and
	-- counted from the actual liters picked up by Baler:processBalerArea().
	if self.progress ~= nil and self.progress.resetRuntimeCounters ~= nil then
		self.progress:resetRuntimeCounters()
	end

	self.competitionTeamMask = self:captureCompetitionTeamMask()
	self.state = CompetitionUtils.STATE.RUNNING
	self.competitionElapsedMs = 0
	self.security:restorePreStartTime(false)
	
	CompetitionUtils.info("БАЗОВЫЙ СКАН ЗАВЕРШЕН. СОРЕВНОВАНИЕ НАЧАЛОСЬ! Маска команд: %d", self.competitionTeamMask)
	g_server:broadcastEvent(CompetitionSyncStateEvent.new(self.state, self.readyByUserId))
	g_server:broadcastEvent(CompetitionClockStateEvent.new(0, self.competitionTeamMask))
end

function CompetitionManager:finishCompetition()
	if self.state == CompetitionUtils.STATE.FINISHED then return end
	self.state = CompetitionUtils.STATE.FINISHED
	self.finalStandings = {}
	for _, config in ipairs(self.activeTeams or {}) do
		if self:isFarmInCompetitionMask(config.farmId) then
			local p = self.progressByFarmId[config.farmId] and self.progressByFarmId[config.farmId].overall or 0
			table.insert(self.finalStandings, {name = config.hudName, percent = p, color = config.actualColor})
		end
	end
	table.sort(self.finalStandings, function(a, b) return a.percent > b.percent end)
	g_server:broadcastEvent(CompetitionSyncStateEvent.new(self.state, self.readyByUserId))
end

-------------------------------------------------------------------------------
-- ХЕЛПЕРЫ ДЛЯ СКАНИРОВАНИЯ И РАСЧЕТА (DENSITY MAPS)
-------------------------------------------------------------------------------
function CompetitionManager:getFruitPixelAreaSqm()
	if g_currentMission ~= nil and g_currentMission.getFruitPixelsToSqm ~= nil then
		local value = g_currentMission:getFruitPixelsToSqm(); if value ~= nil and value > 0 then return value end
	end
	return 1
end

function CompetitionManager:getFruitYieldScale(fruitDesc, growthState)
	if fruitDesc ~= nil and fruitDesc.getYieldScale ~= nil then
		local ok, value = pcall(fruitDesc.getYieldScale, fruitDesc, growthState); if ok and value ~= nil then return value end
	end
	if fruitDesc ~= nil and fruitDesc.yieldScales ~= nil then return fruitDesc.yieldScales[growthState] or 1 end
	return 1
end

function CompetitionManager:resolveRoundBale125Capacity(fillType)
	self.roundBale125CapacityByFillType = self.roundBale125CapacityByFillType or {}
	self.roundBale125CapacitySourceByFillType = self.roundBale125CapacitySourceByFillType or {}

	if self.roundBale125CapacityByFillType[fillType] ~= nil then
		return self.roundBale125CapacityByFillType[fillType],
			   self.roundBale125CapacitySourceByFillType[fillType]
	end
	
	if g_baleManager == nil or g_fillTypeManager == nil then return nil, "Manager unavailable" end
	if fillType == nil then
		return nil, "FillType missing"
	end

	for baleIndex, bale in ipairs(g_baleManager.bales or {}) do
		if bale ~= nil and bale.isAvailable ~= false and bale.isRoundbale == true and bale.diameter ~= nil and math.abs(bale.diameter - self.ROUND_BALE_125_DIAMETER) <= self.ROUND_BALE_125_TOLERANCE then
			local capacity = g_baleManager:getBaleCapacityByBaleIndex(baleIndex, fillType)
			if capacity ~= nil and capacity > 0 then
				CompetitionUtils.info(
					"ROUND BALE CAPACITY fillType=%s capacity=%s baleIndex=%s",
					tostring(fillType),
					tostring(capacity),
					tostring(baleIndex)
				)
				self.roundBale125CapacityByFillType[fillType] = capacity
				self.roundBale125CapacitySourceByFillType[fillType] = "BaleManager"
				return capacity, self.roundBale125CapacitySourceByFillType[fillType]
			end
		end
	end
	return nil, "No 1.25m bale found"
end

-- Возвращает конвертацию, которую штатная специализация Mower использует
-- для указанной культуры и фермы. Сначала проверяются реально загруженные
-- косилки команды, затем таблицы FruitTypeManager как резервный источник.
function CompetitionManager:resolveMowerConverterData(fruitTypeIndex, farmId)
	self.mowerConverterDataByFarmAndFruit = self.mowerConverterDataByFarmAndFruit or {}
	self.mowerConverterSourceByFarmAndFruit = self.mowerConverterSourceByFarmAndFruit or {}
	local cacheKey = tostring(farmId or "ANY") .. ":" .. tostring(fruitTypeIndex)

	if self.mowerConverterDataByFarmAndFruit[cacheKey] ~= nil then
		return self.mowerConverterDataByFarmAndFruit[cacheKey],
			self.mowerConverterSourceByFarmAndFruit[cacheKey]
	end
	if fruitTypeIndex == nil then return nil, "Fruit type missing" end

	local grassWindrowFillType = FillType ~= nil and FillType.GRASS_WINDROW or nil
	local vehicles = g_currentMission ~= nil
		and g_currentMission.vehicleSystem ~= nil
		and g_currentMission.vehicleSystem.vehicles
		or {}

	local matchedVehicleData = nil
	local matchedVehicleSources = {}
	for _, vehicle in ipairs(vehicles) do
		local converters = vehicle ~= nil
			and vehicle.spec_mower ~= nil
			and vehicle.spec_mower.fruitTypeConverters
			or nil
		local data = converters ~= nil and converters[fruitTypeIndex] or nil
		local ownerFarmId = vehicle ~= nil
			and vehicle.getOwnerFarmId ~= nil
			and vehicle:getOwnerFarmId()
			or vehicle ~= nil and vehicle.ownerFarmId or nil
		if data ~= nil
			and data.conversionFactor ~= nil
			and data.conversionFactor > 0
			and (farmId == nil or ownerFarmId == farmId)
			and (grassWindrowFillType == nil or data.fillTypeIndex == grassWindrowFillType) then

			if matchedVehicleData ~= nil
				and math.abs(matchedVehicleData.conversionFactor - data.conversionFactor) > 0.000001 then
				return nil, "Team mowers use different conversion factors"
			end
			matchedVehicleData = data
			table.insert(matchedVehicleSources, tostring(vehicle.configFileName or "loaded mower"))
		end
	end

	if matchedVehicleData ~= nil then
		table.sort(matchedVehicleSources)
		local source = table.concat(matchedVehicleSources, ",")
		self.mowerConverterDataByFarmAndFruit[cacheKey] = matchedVehicleData
		self.mowerConverterSourceByFarmAndFruit[cacheKey] = source
		CompetitionUtils.info(
			"MOWER CONVERTER RESOLVED farmId=%s fruitType=%s outputFillType=%s conversionFactor=%.6f source=%s",
			tostring(farmId),
			tostring(fruitTypeIndex),
			tostring(matchedVehicleData.fillTypeIndex),
			matchedVehicleData.conversionFactor,
			tostring(source)
		)
		return matchedVehicleData, source
	end

	-- Если подходящая косилка ещё не найдена, используем только однозначную
	-- конвертацию GRASS -> GRASS_WINDROW из FruitTypeManager.
	local matchedData = nil
	local matchedNames = {}
	for converterName, converter in pairs(g_fruitTypeManager ~= nil and g_fruitTypeManager.nameToConverter or {}) do
		local data = converter ~= nil and converter[fruitTypeIndex] or nil
		if data ~= nil
			and data.conversionFactor ~= nil
			and data.conversionFactor > 0
			and (grassWindrowFillType == nil or data.fillTypeIndex == grassWindrowFillType) then

			if matchedData ~= nil and math.abs(matchedData.conversionFactor - data.conversionFactor) > 0.000001 then
				return nil, "Ambiguous mower converters"
			end
			matchedData = data
			table.insert(matchedNames, tostring(converterName))
		end
	end

	if matchedData ~= nil then
		table.sort(matchedNames)
		local source = "FruitTypeManager:" .. table.concat(matchedNames, ",")
		self.mowerConverterDataByFarmAndFruit[cacheKey] = matchedData
		self.mowerConverterSourceByFarmAndFruit[cacheKey] = source
		CompetitionUtils.info(
			"MOWER CONVERTER RESOLVED farmId=%s fruitType=%s outputFillType=%s conversionFactor=%.6f source=%s",
			tostring(farmId),
			tostring(fruitTypeIndex),
			tostring(matchedData.fillTypeIndex),
			matchedData.conversionFactor,
			tostring(source)
		)
		return matchedData, source
	end

	return nil, "GRASS to GRASS_WINDROW converter not found"
end

function CompetitionManager:getFruitDescByName(fruitName)
	local wanted = string.upper(tostring(fruitName or ""))
	for _, desc in ipairs(g_fruitTypeManager ~= nil and g_fruitTypeManager:getFruitTypes() or {}) do
		if string.upper(tostring(desc.name or "")) == wanted then return desc end
	end
	return nil
end

function CompetitionManager:getScannerTeamData(farmlandId)
	if g_competitionScanner == nil or g_competitionScanner.scan == nil or g_competitionScanner.scan.running then return nil end
	return g_competitionScanner.scan.teamDataByFarmlandId ~= nil and g_competitionScanner.scan.teamDataByFarmlandId[farmlandId] or nil
end

function CompetitionManager:selectProgressBaselineEntry(teamData, fruitName, mode)
	if teamData == nil then return nil end
	local wanted = string.upper(tostring(fruitName)); local desc = self:getFruitDescByName(wanted)
	local best = nil; local bestScore = -1
	for _, entry in pairs(teamData.fruitStates or {}) do
		if string.upper(tostring(entry.fruitName or "")) == wanted and (entry.cells or 0) > 0 then
			local preferred = false
			if mode == "withered" and desc ~= nil and desc.witheredState ~= nil then preferred = entry.growthState == desc.witheredState
			elseif mode == "harvestReady" and desc ~= nil then
				local minState = desc.minHarvestingGrowthState or 0; local maxState = desc.maxHarvestingGrowthState or -1
				preferred = entry.growthState >= minState and entry.growthState <= maxState
			elseif mode == "any" then preferred = true end
			local score = (preferred and 1000000000 or 0) + (entry.cells or 0)
			if score > bestScore then bestScore = score; best = entry end
		end
	end
	return best
end

function CompetitionManager:copyProgressSamplePoints(source)
	local result = {}
	for i = 1, #(source or {}) do result[i] = source[i] end
	return result
end

function CompetitionManager:getHaulmStateAtWorldPosition(fruitDesc, x, z)
	if fruitDesc == nil or fruitDesc.terrainDataPlaneIdHaulm == nil then return nil end
	local y = 0
	if g_terrainNode ~= nil and getTerrainHeightAtWorldPos ~= nil then y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) end
	local density = getDensityAtWorldPos(fruitDesc.terrainDataPlaneIdHaulm, x, y, z)
	if density == nil then return nil end
	local firstChannel = fruitDesc.startStateChannelHaulm or 0
	local numChannels = fruitDesc.numStateChannelsHaulm or 1
	local mask = 2 ^ numChannels - 1
	return bit32.band(bit32.rshift(density, firstChannel), mask)
end

function CompetitionManager:countActiveHaulmSamples(area)
	if area == nil then return 0, 0 end
	local desc = g_fruitTypeManager:getFruitTypeByIndex(area.fruitTypeIndex)
	if desc == nil or desc.terrainDataPlaneIdHaulm == nil then return 0, 0 end
	local active = 0; local total = 0
	local samples = area.samplePoints or {}
	for i = 1, #samples, 2 do
		total = total + 1
		local state = self:getHaulmStateAtWorldPosition(desc, samples[i], samples[i + 1])
		if state ~= nil and state > 0 then active = active + 1 end
	end
	return active, total
end

function CompetitionManager:ensureProgressFarmData(farmId)
	local farmData = self.progressByFarmId[farmId]
	if farmData ~= nil then return farmData end
	farmData = {overall=0, tasks={}}
	for _, task in ipairs(self.TASKS) do
		local taskData = {overall=0, subtasks={}}
		for _, subtask in ipairs(task.subtasks) do taskData.subtasks[subtask.id] = 0 end
		farmData.tasks[task.id] = taskData
	end
	self.progressByFarmId[farmId] = farmData
	return farmData
end

function CompetitionManager:setSubtaskProgress(farmId, taskId, subtaskId, value, monotonic)
	local farmData = self:ensureProgressFarmData(farmId)
	local taskData = farmData.tasks[taskId]
	if taskData == nil then return end
	local newValue = CompetitionUtils.clampPercent(value)
	local oldValue = taskData.subtasks[subtaskId] or 0
	if monotonic ~= false then newValue = math.max(oldValue, newValue) end
	taskData.subtasks[subtaskId] = newValue
end

function CompetitionManager:recalculateProgressAggregates(farmId)
	local farmData = self:ensureProgressFarmData(farmId)
	local taskSum = 0; local taskCount = 0
	for _, task in ipairs(self.TASKS) do
		local taskData = farmData.tasks[task.id]
		local sum = 0; local count = 0
		for _, subtask in ipairs(task.subtasks) do
			sum = sum + (taskData.subtasks[subtask.id] or 0)
			count = count + 1
		end
		taskData.overall = count > 0 and sum / count or 0
		taskSum = taskSum + taskData.overall
		taskCount = taskCount + 1
	end
	farmData.overall = taskCount > 0 and taskSum / taskCount or 0
end

function CompetitionManager:captureCompetitionProgressBaseline()
	if not CompetitionUtils.getIsServer() then return false end
	if g_competitionScanner == nil or g_competitionScanner.scan == nil or g_competitionScanner.scan.running then return false end
	self.progressBaselineByFarmId = {}; self.progressByFarmId = {}
	local capturedFarms = 0
	for _, config in ipairs(self.activeTeams or {}) do
		if config.farmId >= 1 and config.farmId <= 4 and config.presentInInfoLayer == true then
			local teamData = self:getScannerTeamData(config.farmlandId)
			local farmBase = { farmId=config.farmId, farmlandId=config.farmlandId, teamCode=config.code, areas={} }
			for _, def in ipairs(self.PROGRESS_AREA_DEFS) do
				local entry = self:selectProgressBaselineEntry(teamData, def.fruitName, def.mode)
				if entry ~= nil then
					local area = {
						key=def.key, fruitName=def.fruitName, fruitTypeIndex=entry.fruitTypeIndex, growthState=entry.growthState,
						baselineCells=entry.cells or 0, baselineAreaM2=entry.areaM2 or 0, minX=entry.minX, maxX=entry.maxX,
						minZ=entry.minZ, maxZ=entry.maxZ, samplePoints=self:copyProgressSamplePoints(entry.samplePoints)
					}
					farmBase.areas[def.key] = area
				end
			end
			self.progressBaselineByFarmId[config.farmId] = farmBase
			self:ensureProgressFarmData(config.farmId)
			capturedFarms = capturedFarms + 1
		end
	end
	self.progressBaselineCaptured = capturedFarms > 0
	return self.progressBaselineCaptured
end

function CompetitionManager:isHarvestedFruitState(fruitDesc, growthState)
	if fruitDesc == nil or growthState == nil then return false end
	if fruitDesc.cutState ~= nil and growthState == fruitDesc.cutState then return true end
	for _, targetState in pairs(fruitDesc.harvestTransitions or {}) do if growthState == targetState then return true end end
	return false
end

function CompetitionManager:scanSavedArea(area, mode)
	if area == nil or area.baselineCells == nil or area.baselineCells <= 0 then return 0, 0, 0 end
	local matching = 0; local total = 0
	local desc = g_fruitTypeManager:getFruitTypeByIndex(area.fruitTypeIndex)
	local grassDesc = mode == "grassPlanted" and self:getFruitDescByName("GRASS") or nil
	local samples = area.samplePoints or {}

	for i = 1, #samples, 2 do
		total = total + 1
		local fruitIndex, growthState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(samples[i], samples[i + 1])
		if mode == "baselineGone" then
			if fruitIndex ~= area.fruitTypeIndex or growthState ~= area.growthState then matching = matching + 1 end
		elseif mode == "grassPlanted" then
			if grassDesc ~= nil and fruitIndex == grassDesc.index then matching = matching + 1 end
		elseif mode == "potatoTopped" then
			-- FS25 FruitPreparer changes the fruit to fruitDesc.preparedGrowthState.
			-- If the potato has already been harvested/removed, topping is also necessarily complete.
			if fruitIndex ~= area.fruitTypeIndex
				or (desc ~= nil and desc.preparedGrowthState ~= nil and growthState == desc.preparedGrowthState)
				or self:isHarvestedFruitState(desc, growthState) then
				matching = matching + 1
			end
		elseif mode == "harvested" or mode == "cut" then
			if fruitIndex ~= area.fruitTypeIndex or self:isHarvestedFruitState(desc, growthState) then matching = matching + 1 end
		end
	end
	local percent = total > 0 and matching / total * 100 or 0
	return matching, total, percent
end

function CompetitionManager:getPlaceableConfigFilename(placeable)
	if placeable == nil then return "" end
	if placeable.configFileName ~= nil then return tostring(placeable.configFileName) end
	if placeable.xmlFilename ~= nil then return tostring(placeable.xmlFilename) end
	if placeable.xmlFile ~= nil and placeable.xmlFile.filename ~= nil then return tostring(placeable.xmlFile.filename) end
	return ""
end

function CompetitionManager:getPlaceableRootNode(placeable)
	if placeable == nil then return nil end
	if placeable.rootNode ~= nil and placeable.rootNode ~= 0 then return placeable.rootNode end
	if placeable.components ~= nil and placeable.components[1] ~= nil then return placeable.components[1].node end
	return nil
end

function CompetitionManager:getTeamConfigAtWorldPosition(x, z)
	local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
	for _, config in ipairs(self.activeTeams or {}) do
		if config.farmId >= 1 and config.farmId <= 4 and config.farmlandId == farmlandId then return config, farmlandId end
	end
	return nil, farmlandId
end

function CompetitionManager:getStorageFillLevelForFarm(placeable, fillTypeIndex, farmId)
	if placeable == nil or fillTypeIndex == nil or fillTypeIndex == 0 then return 0 end
	local spec = placeable.spec_silo
	if spec == nil or spec.storages == nil then
		if placeable.getFillLevels ~= nil then
			local levels = placeable:getFillLevels() or {}
			return levels[fillTypeIndex] or 0
		end
		return 0
	end
	local total = 0
	for _, storage in ipairs(spec.storages) do
		if not spec.storagePerFarm or storage.ownerFarmId == farmId then
			local levels = storage.getFillLevels ~= nil and storage:getFillLevels() or storage.fillLevels or {}
			total = total + (levels[fillTypeIndex] or 0)
		end
	end
	return total
end

function CompetitionManager:findCompetitionStorageTargets()
	local result = {}
	local placeables = g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables or g_currentMission.placeables or {}
	for _, placeable in pairs(placeables or {}) do
		if placeable ~= nil and placeable.spec_silo ~= nil then
			local filename = self:getPlaceableConfigFilename(placeable)
			local lower = string.lower(filename)
			local kind = nil
			if string.find(lower, "grainsilosmall", 1, true) ~= nil then kind = "grain"
			elseif string.find(lower, "rootcropsstorage", 1, true) ~= nil then kind = "rootCrop" end
			if kind ~= nil then
				local node = self:getPlaceableRootNode(placeable)
				if node ~= nil and node ~= 0 then
					local x, _, z = getWorldTranslation(node)
					local config, _ = self:getTeamConfigAtWorldPosition(x, z)
					if config ~= nil then
						result[config.farmId] = result[config.farmId] or {}
						if result[config.farmId][kind] == nil then result[config.farmId][kind] = placeable end
					end
				end
			end
		end
	end
	return result
end

function CompetitionManager:getExpectedHarvestRowByName(farmId, fruitName)
	local data = self.expectedHarvestByFarmId[farmId]
	local wanted = string.upper(tostring(fruitName))
	for _, row in ipairs(data ~= nil and data.rows or {}) do
		if string.upper(tostring(row.fruitName or "")) == wanted then return row end
	end
	return nil
end

function CompetitionManager:captureProgressStorageBaseline()
	if not CompetitionUtils.getIsServer() then return end
	local targets = self:findCompetitionStorageTargets()
	self.progressStorageByFarmId = {}
	local fillNames = {"WHEAT", "MAIZE", "POTATO"}
	for _, config in ipairs(self.activeTeams or {}) do
		if config.farmId >= 1 and config.farmId <= 4 then
			local farmTargets = targets[config.farmId] or {}
			local data = { grain=farmTargets.grain, rootCrop=farmTargets.rootCrop, initial={}, maxDelivered={} }
			for _, fillName in ipairs(fillNames) do
				local desc = self:getFruitDescByName(fillName)
				local fillTypeIndex = desc ~= nil and desc.fillType ~= nil and desc.fillType.index or nil
				if fillTypeIndex == nil and g_fillTypeManager.getFillTypeIndexByName ~= nil then fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillName) end
				local target = fillName == "POTATO" and data.rootCrop or data.grain
				local level = self:getStorageFillLevelForFarm(target, fillTypeIndex, config.farmId)
				data.initial[fillName] = level; data.maxDelivered[fillName] = 0
			end
			self.progressStorageByFarmId[config.farmId] = data
		end
	end
end

function CompetitionManager:updateDeliveryProgress(config, fillName, taskId, subtaskId)
	local storageData = self.progressStorageByFarmId[config.farmId]
	if storageData == nil then return nil end
	local target = fillName == "POTATO" and storageData.rootCrop or storageData.grain
	if target == nil then return nil end
	local desc = self:getFruitDescByName(fillName)
	local fillTypeIndex = desc ~= nil and desc.fillType ~= nil and desc.fillType.index or nil
	if fillTypeIndex == nil and g_fillTypeManager.getFillTypeIndexByName ~= nil then fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillName) end
	if fillTypeIndex == nil or fillTypeIndex == 0 then return nil end

	local current = self:getStorageFillLevelForFarm(target, fillTypeIndex, config.farmId)
	local initial = storageData.initial[fillName] or 0
	local delivered = math.max(0, current - initial)
	storageData.maxDelivered[fillName] = math.max(storageData.maxDelivered[fillName] or 0, delivered)

	local expectedRow = self:getExpectedHarvestRowByName(config.farmId, fillName)
	local expected = expectedRow ~= nil and expectedRow.expectedLiters or 0
	local percent = expected > 0 and storageData.maxDelivered[fillName] / expected * 100 or 0
	self:setSubtaskProgress(config.farmId, taskId, subtaskId, percent, true)
	return { current=current, initial=initial, delivered=storageData.maxDelivered[fillName], expected=expected, percent=CompetitionUtils.clampPercent(percent) }
end

function CompetitionManager:createExpectedHarvestScanContext()
	if g_currentMission == nil or g_farmlandManager == nil or g_fruitTypeManager == nil then return nil, "mission/farmland/fruit manager unavailable" end
	local farmlandMap = g_farmlandManager:getLocalMap()
	if farmlandMap == nil or farmlandMap == 0 then return nil, "farmland info layer unavailable" end
	local terrainSize = g_currentMission.terrainSize or getTerrainSize(g_terrainNode)
	if terrainSize == nil or terrainSize <= 0 then return nil, "invalid terrain size" end
	local fieldGroundSystem = g_currentMission.fieldGroundSystem
	if fieldGroundSystem == nil then return nil, "fieldGroundSystem unavailable" end
	local half = terrainSize * 0.5
	local ctx = {
		terrainSize = terrainSize, minX = -half, minZ = -half, maxX = half, maxZ = half, pixelSqm = self:getFruitPixelAreaSqm(),
		farmlandModifier = DensityMapModifier.new(farmlandMap, 0, g_farmlandManager.numberOfBits, g_terrainNode),
		farmlandFilter = nil, fruitModifiers = {}, fruitFilters = {}
	}
	ctx.farmlandFilter = DensityMapFilter.new(ctx.farmlandModifier)

	local sprayMapId, sprayFirstChannel, sprayNumChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.SPRAY_LEVEL)
	ctx.sprayMaxValue = fieldGroundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL) or 0
	if sprayMapId ~= nil then ctx.sprayModifier = DensityMapModifier.new(sprayMapId, sprayFirstChannel, sprayNumChannels, g_terrainNode) end
	if Platform.gameplay.usePlowCounter then
		local mapId, firstChannel, numChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.PLOW_LEVEL)
		if mapId ~= nil then
			ctx.plowModifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
			ctx.plowPositiveFilter = DensityMapFilter.new(mapId, firstChannel, numChannels)
			ctx.plowPositiveFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
		end
	end
	if Platform.gameplay.useLimeCounter then
		local mapId, firstChannel, numChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.LIME_LEVEL)
		if mapId ~= nil then
			ctx.limeModifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
			ctx.limePositiveFilter = DensityMapFilter.new(mapId, firstChannel, numChannels)
			ctx.limePositiveFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
		end
	end
	if Platform.gameplay.useRolling then
		local mapId, firstChannel, numChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.ROLLER_LEVEL)
		if mapId ~= nil then
			ctx.rollerModifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
			ctx.rollerZeroFilter = DensityMapFilter.new(mapId, firstChannel, numChannels)
			ctx.rollerZeroFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 0)
		end
	end
	if Platform.gameplay.useStubbleShred then
		local mapId, firstChannel, numChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.STUBBLE_SHRED_LEVEL)
		if mapId ~= nil then
			ctx.stubbleModifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
			ctx.stubbleOneFilter = DensityMapFilter.new(mapId, firstChannel, numChannels)
			ctx.stubbleOneFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
		end
	end
	local weedSystem = g_currentMission.weedSystem
	if weedSystem ~= nil and weedSystem.getMapHasWeed ~= nil and weedSystem:getMapHasWeed() then
		local mapId, firstChannel, numChannels = weedSystem:getDensityMapData()
		if mapId ~= nil then
			ctx.weedModifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
			ctx.weedStateFilters = {}
			for state, factor in pairs(weedSystem:getFactors() or {}) do
				local filter = DensityMapFilter.new(mapId, firstChannel, numChannels)
				filter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
				table.insert(ctx.weedStateFilters, {filter=filter, factor=factor or 0, state=state})
			end
		end
	end
	ctx.areaMinX = ctx.minX; ctx.areaMinZ = ctx.minZ; ctx.areaMaxX = ctx.maxX; ctx.areaMaxZ = ctx.maxZ
	return ctx
end

function CompetitionManager:setExpectedHarvestScanArea(ctx, minX, minZ, maxX, maxZ)
	ctx.areaMinX = math.max(ctx.minX, minX); ctx.areaMinZ = math.max(ctx.minZ, minZ); ctx.areaMaxX = math.min(ctx.maxX, maxX); ctx.areaMaxZ = math.min(ctx.maxZ, maxZ)
	local function setArea(modifier)
		if modifier ~= nil then modifier:setParallelogramWorldCoords(ctx.areaMinX, ctx.areaMinZ, ctx.areaMaxX, ctx.areaMinZ, ctx.areaMinX, ctx.areaMaxZ, DensityCoordType.POINT_POINT_POINT) end
	end
	setArea(ctx.farmlandModifier); setArea(ctx.sprayModifier); setArea(ctx.plowModifier); setArea(ctx.limeModifier)
	setArea(ctx.rollerModifier); setArea(ctx.stubbleModifier); setArea(ctx.weedModifier)
	for _, modifier in pairs(ctx.fruitModifiers or {}) do setArea(modifier) end
end

function CompetitionManager:getExpectedHarvestFruitModifier(ctx, fruitDesc)
	local fruitIndex = fruitDesc.index; local modifier = ctx.fruitModifiers[fruitIndex]; local filter = ctx.fruitFilters[fruitIndex]
	if modifier == nil then
		modifier = DensityMapModifier.new(fruitDesc.terrainDataPlaneId, fruitDesc.startStateChannel, fruitDesc.numStateChannels, g_terrainNode)
		modifier:setReturnValueShift(-1); filter = DensityMapFilter.new(modifier)
		ctx.fruitModifiers[fruitIndex] = modifier; ctx.fruitFilters[fruitIndex] = filter
	end
	modifier:setParallelogramWorldCoords(ctx.areaMinX, ctx.areaMinZ, ctx.areaMaxX, ctx.areaMinZ, ctx.areaMinX, ctx.areaMaxZ, DensityCoordType.POINT_POINT_POINT)
	return modifier, filter
end

function CompetitionManager:calculateExpectedFruitOnFarmland(ctx, config, fruitDesc, forcedGrowthState)
	if fruitDesc == nil or fruitDesc.terrainDataPlaneId == nil or fruitDesc.cutState == nil or fruitDesc.cutState == 0 then return nil end
	local minState; local maxState
	if forcedGrowthState ~= nil then minState = forcedGrowthState; maxState = forcedGrowthState
	else minState = fruitDesc.minHarvestingGrowthState or 0; maxState = fruitDesc.maxHarvestingGrowthState or 0 end
	if minState == nil or maxState == nil or minState < 0 or maxState < minState then return nil end

	ctx.farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, config.farmlandId)
	local fruitModifier, fruitFilter = self:getExpectedHarvestFruitModifier(ctx, fruitDesc)
	local rawPixels = 0; local weightedPixels = 0; local stateRows = {}

	for state = minState, maxState do
		fruitFilter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
		local _, pixels, _ = fruitModifier:executeGet(fruitFilter, ctx.farmlandFilter)
		pixels = pixels or 0
		if pixels > 0 then
			local yieldScale = self:getFruitYieldScale(fruitDesc, state)
			rawPixels = rawPixels + pixels; weightedPixels = weightedPixels + pixels * yieldScale
			table.insert(stateRows, {state = state, pixels = pixels, yieldScale = yieldScale})
		end
	end

	if rawPixels <= 0 then return nil end
	fruitFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, minState, maxState)
	local _, bonusPixels, _ = fruitModifier:executeGet(fruitFilter, ctx.farmlandFilter)
	bonusPixels = math.max(1, bonusPixels or rawPixels)
	local function ratio01(value) return math.max(0, math.min(1, (value or 0) / bonusPixels)) end

	local missionInfo = g_currentMission.missionInfo
	local sprayFactor = 0
	if ctx.sprayModifier ~= nil and ctx.sprayMaxValue > 0 then
		local spraySum = ctx.sprayModifier:executeGet(fruitFilter, ctx.farmlandFilter)
		sprayFactor = math.max(0, math.min(1, (spraySum or 0) / (bonusPixels * ctx.sprayMaxValue)))
	end
	local plowFactor = 1
	if fruitDesc.lowSoilDensityRequired and missionInfo.plowingRequiredEnabled and ctx.plowModifier ~= nil and ctx.plowPositiveFilter ~= nil then
		local _, pixels, _ = ctx.plowModifier:executeGet(fruitFilter, ctx.farmlandFilter, ctx.plowPositiveFilter); plowFactor = ratio01(math.abs(pixels or 0))
	end
	local limeChangedPixels = 0
	if fruitDesc.consumesLime and missionInfo.limeRequired and ctx.limeModifier ~= nil and ctx.limePositiveFilter ~= nil then
		local _, pixels, _ = ctx.limeModifier:executeGet(fruitFilter, ctx.farmlandFilter, ctx.limePositiveFilter); limeChangedPixels = math.abs(pixels or 0)
	end
	local limeFactor = 1
	if fruitDesc.growthRequiresLime and missionInfo.limeRequired and Platform.gameplay.useLimeCounter then limeFactor = ratio01(limeChangedPixels) end
	local rollerFactor = 1
	if fruitDesc.needsRolling and ctx.rollerModifier ~= nil and ctx.rollerZeroFilter ~= nil then
		local _, pixels, _ = ctx.rollerModifier:executeGet(fruitFilter, ctx.farmlandFilter, ctx.rollerZeroFilter); rollerFactor = ratio01(math.abs(pixels or 0))
	end
	local stubbleFactor = 1
	if Platform.gameplay.useStubbleShred and ctx.stubbleModifier ~= nil and ctx.stubbleOneFilter ~= nil then
		local _, pixels, _ = ctx.stubbleModifier:executeGet(fruitFilter, ctx.farmlandFilter, ctx.stubbleOneFilter); stubbleFactor = ratio01(math.abs(pixels or 0))
	end
	local weedFactor = 1
	if missionInfo.weedsEnabled and fruitDesc.plantsWeed and ctx.weedModifier ~= nil and ctx.weedStateFilters ~= nil then
		local weedPenalty = 0
		for _, weedData in ipairs(ctx.weedStateFilters) do
			local _, pixels, _ = ctx.weedModifier:executeGet(weedData.filter, fruitFilter, ctx.farmlandFilter)
			weedPenalty = weedPenalty + ratio01(pixels or 0) * weedData.factor
		end
		weedFactor = math.max(0, math.min(1, 1 - weedPenalty))
	end
	local beeFactor = 0; local beeBonusPercentage = fruitDesc.beeYieldBonusPercentage or 0
	local beehiveSystem = g_currentMission.beehiveSystem
	if beeBonusPercentage ~= 0 and beehiveSystem ~= nil and beehiveSystem.getBeehiveInfluenceFactorAt ~= nil then
		local minX = ctx.areaMinX; local maxX = ctx.areaMaxX; local minZ = ctx.areaMinZ; local maxZ = ctx.areaMaxZ
		local tileSize = math.max(4, self.EXPECTED_HARVEST_BEE_TILE_SIZE)
		local weightedInfluencePixels = 0; local sampledPixels = 0
		local z0 = minZ
		while z0 < maxZ do
			local z1 = math.min(z0 + tileSize, maxZ); local x0 = minX
			while x0 < maxX do
				local x1 = math.min(x0 + tileSize, maxX)
				fruitModifier:setParallelogramWorldCoords(x0, z0, x1, z0, x0, z1, DensityCoordType.POINT_POINT_POINT)
				local _, pixels, _ = fruitModifier:executeGet(fruitFilter, ctx.farmlandFilter)
				pixels = pixels or 0
				if pixels > 0 then
					local centerX = (x0 + x1) * 0.5; local centerZ = (z0 + z1) * 0.5
					local influence = beehiveSystem:getBeehiveInfluenceFactorAt(centerX, centerZ) or 0
					weightedInfluencePixels = weightedInfluencePixels + pixels * influence; sampledPixels = sampledPixels + pixels
				end
				x0 = x1
			end
			z0 = z1
		end
		fruitModifier:setParallelogramWorldCoords(ctx.areaMinX, ctx.areaMinZ, ctx.areaMaxX, ctx.areaMinZ, ctx.areaMinX, ctx.areaMaxZ, DensityCoordType.POINT_POINT_POINT)
		if sampledPixels > 0 then beeFactor = (weightedInfluencePixels / sampledPixels) * beeBonusPercentage end
	end

	local harvestMultiplier = g_currentMission:getHarvestScaleMultiplier(fruitDesc.index, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeFactor)
	local rawAreaSqm = rawPixels * ctx.pixelSqm; local weightedAreaSqm = weightedPixels * ctx.pixelSqm
	local baseLiters = weightedAreaSqm * (fruitDesc.literPerSqm or 0)
	local expectedLiters = baseLiters * harvestMultiplier

	local result = {
		fruitTypeIndex = fruitDesc.index, fruitName = fruitDesc.name or tostring(fruitDesc.index),
		minGrowthState = minState, maxGrowthState = maxState, rawPixels = rawPixels, weightedPixels = weightedPixels,
		rawAreaSqm = rawAreaSqm, rawAreaHa = rawAreaSqm / 10000, weightedAreaSqm = weightedAreaSqm,
		literPerSqm = fruitDesc.literPerSqm or 0, baseLiters = baseLiters, expectedLiters = expectedLiters,
		harvestMultiplier = harvestMultiplier, sprayFactor = sprayFactor, plowFactor = plowFactor,
		limeFactor = limeFactor, weedFactor = weedFactor, stubbleFactor = stubbleFactor, rollerFactor = rollerFactor,
		beeFactor = beeFactor, stateRows = stateRows
	}

	if string.upper(result.fruitName) == "WHEAT" and fruitDesc.windrowLiterPerSqm ~= nil then
		result.strawLiterPerSqm = fruitDesc.windrowLiterPerSqm
		result.expectedStrawLiters = expectedLiters / (fruitDesc.literPerSqm or 1) * fruitDesc.windrowLiterPerSqm
		local baleCapacity, baleSource = self:resolveRoundBale125Capacity(FillType.STRAW)
		result.roundBale125Capacity = baleCapacity
		if baleCapacity ~= nil and baleCapacity > 0 then
			result.fullRoundBales125 = math.floor(result.expectedStrawLiters / baleCapacity)
		end
		CompetitionUtils.info(
			"EXPECTED STRAW DEBUG farmId=%s fruitLiters=%.2f strawLiters=%.2f capacity=%s capacitySource=%s fullBales=%s remainder=%s",
			tostring(config.farmId),
			expectedLiters,
			result.expectedStrawLiters,
			tostring(baleCapacity),
			tostring(baleSource),
			tostring(result.fullRoundBales125),
			tostring(baleCapacity ~= nil and baleCapacity > 0 and result.expectedStrawLiters % baleCapacity or nil)
		)
	end

	if string.upper(result.fruitName) == "GRASS" then
		local converterData, converterSource = self:resolveMowerConverterData(fruitDesc.index, config.farmId)
		if converterData ~= nil then
			-- Точная цепочка Mower: литры исходного типа по изменённой площади,
			-- бонусы урожайности и коэффициент конвертера конкретной косилки.
			local mowerInputLiters = g_fruitTypeManager:getFruitTypeAreaLiters(
				fruitDesc.index,
				weightedPixels,
				true
			)
			local conversionFactor = converterData.conversionFactor
			result.mowerInputLiters = mowerInputLiters
			result.mowerConversionFactor = conversionFactor
			result.mowerConverterSource = converterSource
			result.expectedGrassLiters = mowerInputLiters * harvestMultiplier * conversionFactor

			local baleCapacity, baleSource = self:resolveRoundBale125Capacity(FillType.GRASS_WINDROW)
			result.grassRoundBale125Capacity = baleCapacity
			if baleCapacity ~= nil and baleCapacity > 0 then
				result.expectedGrassBales125 = math.floor(result.expectedGrassLiters / baleCapacity)
			end

			CompetitionUtils.info(
				"EXPECTED GRASS DEBUG farmId=%s weightedPixels=%.2f mowerInputLiters=%.2f harvestMultiplier=%.6f conversionFactor=%.6f expectedLiters=%.2f capacity=%s capacitySource=%s fullBales=%s converterSource=%s",
				tostring(config.farmId),
				weightedPixels,
				mowerInputLiters,
				harvestMultiplier,
				conversionFactor,
				result.expectedGrassLiters,
				tostring(baleCapacity),
				tostring(baleSource),
				tostring(result.expectedGrassBales125),
				tostring(converterSource)
			)
		else
			CompetitionUtils.error(
				"EXPECTED GRASS FAILED farmId=%s fruitType=%s reason=%s",
				tostring(config.farmId),
				tostring(fruitDesc.index),
				tostring(converterSource)
			)
		end
	end

	return result
end

function CompetitionManager:captureExpectedHarvestBaseline()
	if g_currentMission == nil or not CompetitionUtils.getIsServer() then return false end
	self.expectedHarvestCaptured = false; self.expectedHarvestByFarmId = {}
	local ctx, reason = self:createExpectedHarvestScanContext()
	if ctx == nil then return false end

	local scannedFarms = 0; local totalExpectedLiters = 0
	for _, config in ipairs(self.activeTeams or {}) do
		-- Упрощенные границы для расчетов
		local bounds = {minX = -1024, maxX = 1024, minZ = -1024, maxZ = 1024} 
		
		local mapWidth = math.max(g_farmlandManager.localMapWidth or 1, 1); local mapHeight = math.max(g_farmlandManager.localMapHeight or 1, 1)
		local cellX = ctx.terrainSize / mapWidth; local cellZ = ctx.terrainSize / mapHeight
		self:setExpectedHarvestScanArea(ctx, bounds.minX - cellX * 0.5, bounds.minZ - cellZ * 0.5, bounds.maxX + cellX * 0.5, bounds.maxZ + cellZ * 0.5)

		local farmData = { farmId = config.farmId, farmlandId = config.farmlandId, teamCode = config.code, rows = {}, byFruitTypeIndex = {} }
		local progressBase = self.progressBaselineByFarmId[config.farmId]
		for _, fruitName in ipairs(self.EXPECTED_HARVEST_TASK_FRUITS) do
			local fruitDesc = self:getFruitDescByName(fruitName)
			local area = progressBase ~= nil and progressBase.areas[fruitName] or nil
			local forcedState = area ~= nil and area.growthState or nil
			if fruitDesc ~= nil and forcedState ~= nil and area ~= nil then
				self:setExpectedHarvestScanArea(ctx, area.minX - cellX * 0.5, area.minZ - cellZ * 0.5, area.maxX + cellX * 0.5, area.maxZ + cellZ * 0.5)
				local row = self:calculateExpectedFruitOnFarmland(ctx, config, fruitDesc, forcedState)
				if row ~= nil and row.expectedLiters ~= nil and row.expectedLiters > 0 then
					table.insert(farmData.rows, row); farmData.byFruitTypeIndex[row.fruitTypeIndex] = row; totalExpectedLiters = totalExpectedLiters + row.expectedLiters
				end
			end
		end
		table.sort(farmData.rows, function(a, b) return string.upper(tostring(a.fruitName)) < string.upper(tostring(b.fruitName)) end)
		self.expectedHarvestByFarmId[config.farmId] = farmData
		scannedFarms = scannedFarms + 1
	end
	self.expectedHarvestCaptured = true
	return true
end

-------------------------------------------------------------------------------
-- MAIN UPDATE
-------------------------------------------------------------------------------
function CompetitionManager:update(dt)
	if g_currentMission == nil then return end
	self.security:update(dt)

	if not self.initialized then
		self.initTimer = self.initTimer - dt
		if self.initTimer <= 0 then 
			if not self:initializeSession() then self.initTimer = 2000 end 
		end
		return
	end

	self.ui:showWelcomeIfPossible()

	if self.state == CompetitionUtils.STATE.RUNNING then
		self.competitionElapsedMs = self.competitionElapsedMs + dt
		if CompetitionUtils.getIsServer() then
			self.competitionClockSyncTimer = self.competitionClockSyncTimer - dt
			if self.competitionClockSyncTimer <= 0 then
				self.competitionClockSyncTimer = 2000
				g_server:broadcastEvent(CompetitionClockStateEvent.new(self.competitionElapsedMs / 1000, 0))
			end
		end
	end

	self.progress:update(dt)

	if not CompetitionUtils.getIsServer() and self.syncTimer ~= nil then
		self.syncTimer = self.syncTimer - dt
		if self.syncTimer <= 0 then self.syncTimer = nil; g_client:getServerConnection():sendEvent(CompetitionSyncRequestEvent.new()) end
	end

	if self.pendingTeleportFarmId ~= nil and self.pendingTeleportTimer ~= nil then
		self.pendingTeleportTimer = self.pendingTeleportTimer - dt
		if self.pendingTeleportTimer <= 0 then self:teleportLocalPlayerToTeam(self.pendingTeleportFarmId) end
	end

	if CompetitionUtils.getIsServer() and self.state < CompetitionUtils.STATE.STARTING then
		self.reconcileTimer = self.reconcileTimer - dt
		if self.reconcileTimer <= 0 then self.reconcileTimer = 500; self:reconcileConnectedUsers(); self:evaluateServerState() end
	end

	if CompetitionUtils.getIsServer() and self.state == CompetitionUtils.STATE.STARTING then
		if self.baselineScanRequested and g_competitionScanner ~= nil and not g_competitionScanner.scan.running then
			self:finishCompetitionStart()
		end
	end
end

function CompetitionManager:draw()
	self.ui:draw()
end

function CompetitionManager:keyEvent(unicode, sym, modifier, isDown)
	if self.ui:onKeyEvent(unicode, sym, modifier, isDown) then return end
	if (sym == 13 or sym == 271) and isDown then self:handleLocalReady() end
end

g_competitionManager = CompetitionManager.new()
addModEventListener(g_competitionManager)
