--[[
	FS25 FarmersCompetition - UI Module
	Отвечает за отрисовку всех элементов интерфейса (HUD):
	меню готовности, прогресс-бар соревнования, всплывающие окна и финальный подиум.
]]

CompetitionUI = {}
local CompetitionUI_mt = Class(CompetitionUI)

-- Константы для отрисовки бегущего соревнования (HUD)
CompetitionUI.HUD_RIGHT_MARGIN = 0.018
CompetitionUI.HUD_TOP = 0.885
CompetitionUI.HUD_LABEL_WIDTH = 0.245
CompetitionUI.HUD_TEAM_COLUMN_WIDTH = 0.064
CompetitionUI.HUD_HORIZONTAL_PADDING = 0.008
CompetitionUI.HUD_TIMER_HEIGHT = 0.050
CompetitionUI.HUD_BLOCK_GAP = 0.004
CompetitionUI.HUD_DETAILED_HEIGHT = 0.430
CompetitionUI.HUD_COLLAPSED_HEIGHT = 0.132

-- Масштабирование шрифта
CompetitionUI.HUD_FONT_SCALES = {1.05, 1.16, 1.27, 1.38, 1.49}
CompetitionUI.HUD_FONT_DEFAULT_INDEX = 2

function CompetitionUI.new(manager, customMt)
	local self = setmetatable({}, customMt or CompetitionUI_mt)
	
	self.manager = manager -- Ссылка на главный менеджер для получения данных
	
	-- Локальные состояния интерфейса
	self.progressDetailsVisible = true
	self.progressFontSizeIndex = CompetitionUI.HUD_FONT_DEFAULT_INDEX
	self.rawProgressToggleKeyDown = false
	self.rawProgressFontKeyDown = false

	return self
end
-------------------------------------------------------------------------------
-- ОКНО ПРИВЕТСТВИЯ
-------------------------------------------------------------------------------
function CompetitionUI:showWelcomeIfPossible()
	if self.manager.welcomeShown or not CompetitionUtils.getIsClient() then return end
	if g_localPlayer == nil or InfoDialog == nil or InfoDialog.INSTANCE == nil then return end
	if g_gui ~= nil and g_gui:getIsGuiVisible() then return end

	self.manager.welcomeShown = true
	
	local text = "СОРЕВНОВАНИЕ ФЕРМЕРОВ\n\nДобро пожаловать на соревнование!\n\nВступите в ферму своей команды. После вступления вы будете автоматически перемещены в стартовую зону команды."
	
	InfoDialog.show(
		text,
		function() self.manager.welcomeClosed = true end,
		self,
		DialogElement.TYPE_INFO,
		"OK"
	)
end

-------------------------------------------------------------------------------
-- ПРОВЕРКИ ВИДИМОСТИ
-------------------------------------------------------------------------------

-- Проверяет, можно ли вообще сейчас рисовать наш HUD
function CompetitionUI:isHudVisible()
	if not self.manager.initialized then return false end
	if not CompetitionUtils.getIsClient() then return false end
	-- Если открыто игровое меню (Esc, магазин и т.д.), скрываем наш HUD (стандарт Giants)
	if g_gui ~= nil and g_gui:getIsGuiVisible() then return false end
	
	return true
end

-------------------------------------------------------------------------------
-- РАБОТА СО ШРИФТАМИ И ИНПУТОМ (Горячие клавиши UI)
-------------------------------------------------------------------------------

function CompetitionUI:getProgressFontScale()
	local scales = CompetitionUI.HUD_FONT_SCALES
	local index = self.progressFontSizeIndex
	index = math.max(1, math.min(#scales, index))
	return scales[index] or 1, index, #scales
end

function CompetitionUI:adjustProgressFontSize(delta)
	local scales = CompetitionUI.HUD_FONT_SCALES
	local current = self.progressFontSizeIndex
	local nextIndex = math.max(1, math.min(#scales, current + delta))
	
	if nextIndex ~= current then 
		self.progressFontSizeIndex = nextIndex 
		CompetitionUtils.info("Размер шрифта HUD изменен: уровень %d/%d", nextIndex, #scales)
	end
end

-- Обработка сырых нажатий клавиш для скрытия/раскрытия деталей и масштабирования
function CompetitionUI:onKeyEvent(unicode, sym, modifier, isDown)
	if Input == nil then return false end

	-- Проверка зажатого Ctrl
	local ctrlMask = Input.MOD_CTRL
	if ctrlMask == nil then 
		ctrlMask = 0
		if Input.MOD_LCTRL ~= nil then ctrlMask = ctrlMask + Input.MOD_LCTRL end
		if Input.MOD_RCTRL ~= nil then ctrlMask = ctrlMask + Input.MOD_RCTRL end 
	end
	
	local ctrlDown = false
	if ctrlMask ~= 0 and bit32 ~= nil and bit32.band ~= nil then 
		ctrlDown = bit32.band(modifier or 0, ctrlMask) ~= 0
	elseif Input.isKeyPressed ~= nil then 
		ctrlDown = (Input.KEY_lctrl ~= nil and Input.isKeyPressed(Input.KEY_lctrl)) or (Input.KEY_rctrl ~= nil and Input.isKeyPressed(Input.KEY_rctrl)) 
	end

	-- Обработка Ctrl+K (Детализация прогресса)
	local isK = (Input.KEY_k ~= nil and sym == Input.KEY_k) or (Input.KEY_K ~= nil and sym == Input.KEY_K)
	if isK then
		if not isDown then self.rawProgressToggleKeyDown = false return true end
		if ctrlDown and (self.manager.state == CompetitionUtils.STATE.RUNNING or self.manager.state == CompetitionUtils.STATE.FINISHED) and not self.rawProgressToggleKeyDown then
			self.rawProgressToggleKeyDown = true
			self.progressDetailsVisible = not self.progressDetailsVisible
		end
		return true
	end

	-- Обработка Ctrl+J / Ctrl+L (Размер шрифта)
	local isJ = (Input.KEY_j ~= nil and sym == Input.KEY_j) or (Input.KEY_J ~= nil and sym == Input.KEY_J) or sym == 106 or sym == 74
	local isL = (Input.KEY_l ~= nil and sym == Input.KEY_l) or (Input.KEY_L ~= nil and sym == Input.KEY_L) or sym == 108 or sym == 76
	
	if isJ or isL then
		if not isDown then self.rawProgressFontKeyDown = false return true end
		if ctrlDown and (self.manager.state == CompetitionUtils.STATE.RUNNING or self.manager.state == CompetitionUtils.STATE.FINISHED) and not self.rawProgressFontKeyDown then
			self.rawProgressFontKeyDown = true
			self:adjustProgressFontSize(isL and 1 or -1)
		end
		return true
	end

	return false -- Кнопка не обработана интерфейсом
end

-------------------------------------------------------------------------------
-- ОТРИСОВКА ЭКРАНА ГОТОВНОСТИ (До старта)
-------------------------------------------------------------------------------

function CompetitionUI:drawReadyRow(x, y, width, row, textSize)
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextColor(1, 1, 1, 1)
	renderText(x, y, textSize, row.name)

	if row.ready then
		setTextAlignment(RenderText.ALIGN_RIGHT)
		setTextColor(0.35, 1.0, 0.35, 1) -- Зеленый цвет готовности
		renderText(x + width, y, textSize * 0.82, "ГОТОВ")
	end
end

function CompetitionUI:drawReadinessHud()
	-- Размеры и позиционирование панелей
	local panelX = 0.705; local panelWidth = 0.275; local panelTop = 0.805
	local padX = 0.009; local padY = 0.010
	local titleSize = 0.0145; local headerSize = 0.0130; local rowSize = 0.0115
	local rowStep = 0.0160; local groupGap = 0.009; local columnGap = 0.012
	local columnWidth = (panelWidth - padX * 2 - columnGap) * 0.5

	-- Группируем команды попарно (для двух столбцов)
	local teamGroups = {}
	for index = 1, #self.manager.activeTeams, 2 do 
		table.insert(teamGroups, {self.manager.activeTeams[index], self.manager.activeTeams[index + 1]}) 
	end

	-- Расчет динамической высоты панели в зависимости от кол-ва игроков
	local contentRows = 0
	for _, pair in ipairs(teamGroups) do
		local leftRows = self.manager:getTeamPlayerRows(pair[1])
		local rightRows = pair[2] ~= nil and self.manager:getTeamPlayerRows(pair[2]) or {}
		contentRows = contentRows + 1 + math.max(#leftRows, #rightRows, 1)
	end
	
	local unassignedRows = self.manager:getUnassignedRows()
	if #unassignedRows > 0 then contentRows = contentRows + 1 + #unassignedRows end
	
	local adminRows = self.manager:getAdminRows()
	if #adminRows > 0 then contentRows = contentRows + 1 + #adminRows end

	local panelHeight = padY * 2 + titleSize * 1.5 + contentRows * rowStep + #teamGroups * groupGap
	if #unassignedRows > 0 then panelHeight = panelHeight + groupGap end
	if #adminRows > 0 then panelHeight = panelHeight + groupGap end

	local panelY = panelTop - panelHeight
	
	-- Отрисовка фона панели
	drawFilledRect(panelX, panelY, panelWidth, panelHeight, 0, 0, 0, 0.68)

	-- Отрисовка заголовка
	local cursorY = panelTop - padY - titleSize
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextBold(true)
	setTextColor(1, 1, 1, 1)
	renderText(panelX + padX, cursorY, titleSize, "ГОТОВНОСТЬ К СОРЕВНОВАНИЮ")
	setTextBold(false)
	cursorY = cursorY - titleSize * 1.45

	-- Отрисовка списков команд
	for _, pair in ipairs(teamGroups) do
		local leftTeam = pair[1]
		local rightTeam = pair[2]
		local leftX = panelX + padX
		local rightX = leftX + columnWidth + columnGap

		-- Заголовки команд
		local leftColor = leftTeam.actualColor or {1, 1, 1, 1}
		setTextBold(true)
		setTextColor(leftColor[1], leftColor[2], leftColor[3], 1)
		renderText(leftX, cursorY, headerSize, leftTeam.hudName)
		
		if rightTeam ~= nil then
			local rightColor = rightTeam.actualColor or {1, 1, 1, 1}
			setTextColor(rightColor[1], rightColor[2], rightColor[3], 1)
			renderText(rightX, cursorY, headerSize, rightTeam.hudName)
		end
		setTextBold(false)
		cursorY = cursorY - rowStep

		-- Игроки в командах
		local leftRows = self.manager:getTeamPlayerRows(leftTeam)
		local rightRows = rightTeam ~= nil and self.manager:getTeamPlayerRows(rightTeam) or {}
		local rowsCount = math.max(#leftRows, #rightRows, 1)
		
		if #leftRows == 0 then leftRows[1] = {name = "—", ready = false} end
		if rightTeam ~= nil and #rightRows == 0 then rightRows[1] = {name = "—", ready = false} end

		for rowIndex = 1, rowsCount do
			if leftRows[rowIndex] ~= nil then 
				self:drawReadyRow(leftX, cursorY, columnWidth, leftRows[rowIndex], rowSize) 
			end
			if rightTeam ~= nil and rightRows[rowIndex] ~= nil then 
				self:drawReadyRow(rightX, cursorY, columnWidth, rightRows[rowIndex], rowSize) 
			end
			cursorY = cursorY - rowStep
		end
		cursorY = cursorY - groupGap
	end

	-- Отрисовка игроков вне команды
	if #unassignedRows > 0 then
		setTextBold(true)
		setTextColor(1, 0.55, 0.30, 1) -- Оранжевый цвет предупреждения
		renderText(panelX + padX, cursorY, headerSize, "ИГРОКИ ВНЕ КОМАНДЫ")
		setTextBold(false)
		cursorY = cursorY - rowStep
		
		for _, row in ipairs(unassignedRows) do
			setTextAlignment(RenderText.ALIGN_LEFT)
			setTextColor(1, 1, 1, 1)
			renderText(panelX + padX, cursorY, rowSize, row.name)
			
			setTextAlignment(RenderText.ALIGN_RIGHT)
			setTextColor(1, 0.45, 0.30, 1)
			renderText(panelX + panelWidth - padX, cursorY, rowSize * 0.82, "НЕ В КОМАНДЕ")
			cursorY = cursorY - rowStep
		end
		cursorY = cursorY - groupGap
	end

	-- Отрисовка админов
	if #adminRows > 0 then
		setTextBold(true)
		setTextAlignment(RenderText.ALIGN_LEFT)
		setTextColor(1, 1, 1, 0.92)
		renderText(panelX + padX, cursorY, headerSize, "АДМИНИСТРАТОРЫ")
		setTextBold(false)
		cursorY = cursorY - rowStep
		
		for _, row in ipairs(adminRows) do
			self:drawReadyRow(panelX + padX, cursorY, panelWidth - padX * 2, row, rowSize)
			cursorY = cursorY - rowStep
		end
	end
	
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextColor(1, 1, 1, 1)
end

function CompetitionUI:drawBottomReadyMessage()
	if not self.manager.welcomeClosed then return end
	
	-- Если сервер захватывает стартовое состояние (сканирует карту)
	if self.manager.state == CompetitionUtils.STATE.STARTING then
		drawFilledRect(0.14, 0.045, 0.72, 0.050, 0, 0, 0, 0.68)
		setTextAlignment(RenderText.ALIGN_CENTER)
		setTextColor(1, 1, 1, 1)
		setTextBold(true)
		renderText(0.5, 0.045 + 0.017, 0.0130, self.manager.STARTING_TEXT)
		setTextBold(false)
		setTextAlignment(RenderText.ALIGN_LEFT)
		return
	end

	-- Подсказка "Нажмите ENTER", если игрок еще не готов
	local userId = CompetitionUtils.getLocalUserId()
	if userId == nil or not self.manager:isUserEligible(userId) or self.manager.readyByUserId[userId] == true then return end
	
	local localFarmId = CompetitionUtils.getFarmIdForUserId(userId)
	local localConfig = self.manager:getCompetitionFarmConfig(localFarmId)
	if localConfig ~= nil and localConfig.presentInInfoLayer == true and localConfig.spawnX ~= nil and self.manager.lastTeleportedFarmId ~= localFarmId then 
		return -- Игрок еще не телепортирован, не показываем подсказку
	end

	drawFilledRect(0.14, 0.045, 0.72, 0.066, 0, 0, 0, 0.68)
	setTextAlignment(RenderText.ALIGN_CENTER)
	setTextColor(1, 1, 1, 1)
	setTextBold(false)
	renderText(0.5, 0.045 + 0.038, 0.0125, self.manager.READY_TEXT_LINE1)
	setTextBold(true)
	renderText(0.5, 0.045 + 0.014, 0.0135, self.manager.READY_TEXT_LINE2)
	setTextBold(false)
	setTextAlignment(RenderText.ALIGN_LEFT)
end

-------------------------------------------------------------------------------
-- ОТРИСОВКА АКТИВНОГО СОРЕВНОВАНИЯ (RUNNING)
-------------------------------------------------------------------------------

function CompetitionUI:formatCompetitionClock()
	local elapsedSeconds = math.max(0, math.floor((self.manager.competitionElapsedMs or 0) / 1000))
	local seconds = elapsedSeconds
	local label = "ВРЕМЯ СОРЕВНОВАНИЯ"
	
	local duration = self.manager.COMPETITION_DURATION_SECONDS
	if duration ~= nil and duration > 0 then
		seconds = math.max(0, math.floor(duration - elapsedSeconds))
		label = "ОСТАЛОСЬ"
	end
	
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60
	return label, string.format("%02d:%02d:%02d", hours, minutes, secs)
end

function CompetitionUI:drawProgressCell(x, y, width, value, textSize, bold)
	setTextAlignment(RenderText.ALIGN_CENTER)
	setTextBold(bold == true)
	setTextColor(1, 1, 1, 1)
	renderText(x + width * 0.5, y, textSize, string.format("%d%%", math.floor((value or 0) + 0.5)))
	setTextBold(false)
end

function CompetitionUI:drawCompetitionHud()
	local teams = self.manager:getProgressTeams()
	if #teams == 0 then return end
	
	local fontScale, fontLevel, fontLevelCount = self:getProgressFontScale()
	local padX = CompetitionUI.HUD_HORIZONTAL_PADDING
	local labelWidth = CompetitionUI.HUD_LABEL_WIDTH
	local valueWidth = CompetitionUI.HUD_TEAM_COLUMN_WIDTH
	
	-- Динамическая ширина зависит от кол-ва команд
	local panelWidth = padX * 2 + labelWidth + #teams * valueWidth
	local panelX = 1 - CompetitionUI.HUD_RIGHT_MARGIN - panelWidth
	local panelTop = CompetitionUI.HUD_TOP
	local timerHeight = CompetitionUI.HUD_TIMER_HEIGHT
	local gap = CompetitionUI.HUD_BLOCK_GAP
	
	local fullHeight = self.progressDetailsVisible and CompetitionUI.HUD_DETAILED_HEIGHT or CompetitionUI.HUD_COLLAPSED_HEIGHT
	local tableHeight = fullHeight - timerHeight - gap
	local tableTop = panelTop - timerHeight - gap
	local tableY = tableTop - tableHeight

	-- Блок с часами
	drawFilledRect(panelX, panelTop - timerHeight, panelWidth, timerHeight, 0, 0, 0, 0.72)
	local clockLabel, clockText = self:formatCompetitionClock()
	local panelCenterX = panelX + panelWidth * 0.5
	setTextAlignment(RenderText.ALIGN_CENTER)
	setTextColor(1, 1, 1, 0.88)
	setTextBold(false)
	renderText(panelCenterX, panelTop - 0.018, 0.0105, clockLabel)
	setTextBold(true)
	setTextColor(1, 1, 1, 1)
	renderText(panelCenterX, panelTop - 0.041, 0.0205, clockText)
	setTextBold(false)

	-- Таблица прогресса
	drawFilledRect(panelX, tableY, panelWidth, tableHeight, 0, 0, 0, 0.72)
	local labelX = panelX + padX
	local valuesX = labelX + labelWidth
	local topPad = 0.010; local bottomPad = 0.009; local hintHeight = 0.014
	local availableRowsHeight = tableHeight - topPad - bottomPad - hintHeight

	-- Подсчет строк для динамического интервала по вертикали
	local detailRowCount = 2 
	if self.progressDetailsVisible then
		for _, task in ipairs(self.manager.TASKS) do 
			detailRowCount = detailRowCount + 1 + #task.subtasks 
		end
	end
	local rowStep = availableRowsHeight / math.max(detailRowCount, 1)
	local cursorY = tableY + tableHeight - topPad - rowStep * 0.68

	-- Заголовки (Названия команд)
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextBold(true)
	setTextColor(1, 1, 1, 1)
	renderText(labelX, cursorY, 0.0120 * fontScale, self.progressDetailsVisible and "ЗАДАНИЯ" or "ПРОГРЕСС")

	for index, team in ipairs(teams) do
		local color = team.actualColor or {1, 1, 1, 1}
		setTextAlignment(RenderText.ALIGN_CENTER)
		setTextColor(color[1], color[2], color[3], 1)
		renderText(valuesX + (index - 1) * valueWidth + valueWidth * 0.5, cursorY, 0.0105 * fontScale, team.hudName)
	end
	setTextBold(false)
	cursorY = cursorY - rowStep

	-- Детальный вывод задач
	if self.progressDetailsVisible then
		for _, task in ipairs(self.manager.TASKS) do
			setTextAlignment(RenderText.ALIGN_LEFT)
			setTextBold(true)
			setTextColor(1, 1, 1, 0.96)
			renderText(labelX, cursorY, 0.0102 * fontScale, task.title)
			
			for index, team in ipairs(teams) do
				self:drawProgressCell(valuesX + (index - 1) * valueWidth, cursorY, valueWidth, self.manager:getProgressPercent(team.farmId, task.id, nil), 0.0095 * fontScale, true)
			end
			cursorY = cursorY - rowStep
			
			for _, subtask in ipairs(task.subtasks) do
				setTextAlignment(RenderText.ALIGN_LEFT)
				setTextBold(false)
				setTextColor(0.92, 0.92, 0.92, 1)
				renderText(labelX + 0.007, cursorY, 0.0087 * fontScale, subtask.id .. "  " .. subtask.title)
				
				for index, team in ipairs(teams) do
					self:drawProgressCell(valuesX + (index - 1) * valueWidth, cursorY, valueWidth, self.manager:getProgressPercent(team.farmId, task.id, subtask.id), 0.0088 * fontScale, false)
				end
				cursorY = cursorY - rowStep
			end
		end
	end

	-- Строка "ИТОГО"
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextBold(true)
	setTextColor(1, 1, 1, 1)
	renderText(labelX, cursorY, 0.0108 * fontScale, "ИТОГО")
	for index, team in ipairs(teams) do
		self:drawProgressCell(valuesX + (index - 1) * valueWidth, cursorY, valueWidth, self.manager:getProgressPercent(team.farmId, nil, nil), 0.0105 * fontScale, true)
	end

	-- Подсказки по горячим клавишам (Футер)
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextBold(false)
	setTextColor(0.78, 0.78, 0.78, 0.92)
	local hint = self.progressDetailsVisible and "Ctrl+K — скрыть детали" or "Ctrl+K — показать детали"
	local hintSize = 0.0092 * math.min(fontScale, 1.10)
	renderText(labelX, tableY + bottomPad * 0.45, hintSize, hint)

	setTextAlignment(RenderText.ALIGN_RIGHT)
	renderText(panelX + panelWidth - padX, tableY + bottomPad * 0.45, hintSize, string.format("Ctrl+J/L — шрифт -/+  %d/%d", fontLevel, fontLevelCount))
	
	-- Сброс стилей
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextBold(false)
	setTextColor(1, 1, 1, 1)
end

-------------------------------------------------------------------------------
-- ОТРИСОВКА ПОБЕДИТЕЛЕЙ (ФИНИШ)
-------------------------------------------------------------------------------

function CompetitionUI:drawPodium()
	local boxX = 0.35
	local boxY = 0.40
	local boxWidth = 0.30
	local boxHeight = 0.20
	
	drawFilledRect(boxX, boxY, boxWidth, boxHeight, 0, 0, 0, 0.85)

	setTextAlignment(RenderText.ALIGN_CENTER)
	setTextColor(1, 0.85, 0, 1) -- Золотой цвет
	setTextBold(true)
	renderText(boxX + boxWidth * 0.5, boxY + boxHeight - 0.03, 0.02, "СОРЕВНОВАНИЕ ЗАВЕРШЕНО!")
	
	setTextColor(1, 1, 1, 1)
	renderText(boxX + boxWidth * 0.5, boxY + boxHeight - 0.06, 0.015, "ИТОГОВЫЕ РЕЗУЛЬТАТЫ:")
	setTextBold(false)

	local cursorY = boxY + boxHeight - 0.10
	setTextAlignment(RenderText.ALIGN_LEFT)
	
	-- manager.finalStandings заполняется в момент финиша
	for i, team in ipairs(self.manager.finalStandings or {}) do
		setTextColor(team.color[1], team.color[2], team.color[3], 1)
		renderText(boxX + 0.05, cursorY, 0.014, string.format("%d МЕСТО — %s — %.2f%%", i, team.name, team.percent))
		cursorY = cursorY - 0.025
	end
	
	setTextColor(1, 1, 1, 1)
end

-------------------------------------------------------------------------------
-- ГЛАВНЫЙ МЕТОД ОТРИСОВКИ (вызывается каждый кадр)
-------------------------------------------------------------------------------

function CompetitionUI:draw()
	if not self:isHudVisible() then return end

	if self.manager.state == CompetitionUtils.STATE.RUNNING or self.manager.state == CompetitionUtils.STATE.FINISHED then
		self:drawCompetitionHud()
		if self.manager.state == CompetitionUtils.STATE.FINISHED then
			self:drawPodium() -- Если финиш, рисуем поверх табличку победителей
		end
		return
	end

	-- До старта рисуем окна готовности
	self:drawReadinessHud()
	self:drawBottomReadyMessage()
end