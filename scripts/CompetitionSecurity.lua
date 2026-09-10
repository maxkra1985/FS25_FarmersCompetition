--[[
    FS25 FarmersCompetition - Security Module
    Обеспечивает предстартовую защиту карты.
    Блокирует действия игроков, останавливает время и отключает обучение.
]]

CompetitionSecurity = {}
local CompetitionSecurity_mt = Class(CompetitionSecurity)

CompetitionSecurity.PRESTART_WARNING_COOLDOWN_MS = 1500
CompetitionSecurity.FORCE_EXIT_RETRY_MS = 750

function CompetitionSecurity.new(manager, customMt)
    local self = setmetatable({}, customMt or CompetitionSecurity_mt)
    self.manager = manager

    self.preStartWarningCooldown = 0
    self.forceExitTimer = 0
    
    self.preStartOriginalTimeScale = nil
    self.preStartTimeFrozen = false

    self.hooksInstalled = false
    self.tutorialHooksInstalled = false
    self.guidedTourHookInstalled = false

    return self
end

-------------------------------------------------------------------------------
-- ПРОВЕРКА БЛОКИРОВКИ
-------------------------------------------------------------------------------
-- Блокировка активна только до старта (состояния: Ожидание игроков, Ожидание готовности, Финальный скан)
function CompetitionSecurity:isPreStartLocked()
    local state = self.manager.state
    return state == CompetitionUtils.STATE.WAITING_FOR_PLAYERS 
        or state == CompetitionUtils.STATE.WAITING_FOR_READY 
        or state == CompetitionUtils.STATE.STARTING
end

function CompetitionSecurity:showPreStartBlockedWarning()
    if self.preStartWarningCooldown > 0 then return end
    self.preStartWarningCooldown = CompetitionSecurity.PRESTART_WARNING_COOLDOWN_MS

    if CompetitionUtils.getIsClient() and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning("Соревнование ещё не началось. Это действие заблокировано.", 2000)
    end
end

-------------------------------------------------------------------------------
-- ОТКЛЮЧЕНИЕ ОБУЧЕНИЯ И ТУТОРИАЛОВ
-------------------------------------------------------------------------------
function CompetitionSecurity:suppressTutorials()
    local function shouldSuppress() 
        return g_competitionManager ~= nil and g_competitionManager.mapLoaded == true 
    end

    if not self.tutorialHooksInstalled then
        if IntroductionHelpSystem ~= nil then
            for _, functionName in ipairs({"loadHelpElementsFromXML", "update", "draw"}) do
                local superFunc = IntroductionHelpSystem[functionName]
                if superFunc ~= nil then
                    IntroductionHelpSystem[functionName] = function(helpSystem, ...)
                        if shouldSuppress() then return end
                        return superFunc(helpSystem, ...)
                    end
                end
            end
            local superGetIsHelpVisible = IntroductionHelpSystem.getIsHelpVisible
            if superGetIsHelpVisible ~= nil then
                IntroductionHelpSystem.getIsHelpVisible = function(helpSystem, ...)
                    if shouldSuppress() then return false end
                    return superGetIsHelpVisible(helpSystem, ...)
                end
            end
        end

        if IntroductionHelpHUDUtil ~= nil then
            for _, functionName in ipairs({"drawMessage", "drawHelp"}) do
                local superFunc = IntroductionHelpHUDUtil[functionName]
                if superFunc ~= nil then
                    IntroductionHelpHUDUtil[functionName] = function(...)
                        if shouldSuppress() then return end
                        return superFunc(...)
                    end
                end
            end
        end
        self.tutorialHooksInstalled = true
        CompetitionUtils.info("Всплывающие окна обучения подавлены.")
    end

    -- Отключение специфического уведомления Riverbend Springs
    if not self.guidedTourHookInstalled then
        if HUD ~= nil and HUD.showInGameMessage ~= nil then
            local superShowInGameMessage = HUD.showInGameMessage
            HUD.showInGameMessage = function(hud, title, message, duration, controlGlyphs, callback, callbackTarget, ...)
                if shouldSuppress() and g_i18n ~= nil then
                    local stockText = g_i18n:getText("guidedTour_intro_notAvailable")
                    if stockText ~= nil and message == stockText then return end
                end
                return superShowInGameMessage(hud, title, message, duration, controlGlyphs, callback, callbackTarget, ...)
            end
            self.guidedTourHookInstalled = true
        end
    end
end

-------------------------------------------------------------------------------
-- ПЕРЕХВАТ ИГРОВЫХ ДЕЙСТВИЙ (HOOKS)
-------------------------------------------------------------------------------
function CompetitionSecurity:installPreStartHooks()
    if self.hooksInstalled then return end

    local function shouldBlock()
        return g_competitionManager ~= nil and g_competitionManager.security:isPreStartLocked()
    end

    local function warnLocal()
        if g_competitionManager ~= nil then g_competitionManager.security:showPreStartBlockedWarning() end
    end

    local installed = 0

    -- 1. Блокировка посадки в технику (Водитель и Пассажир)
    if VehicleEnterRequestEvent ~= nil and VehicleEnterRequestEvent.run ~= nil then
        local superFunc = VehicleEnterRequestEvent.run
        VehicleEnterRequestEvent.run = function(event, connection, ...)
            if shouldBlock() and connection ~= nil and not connection:getIsServer() then return end
            return superFunc(event, connection, ...)
        end
        installed = installed + 1
    end

    if EnterablePassengerEnterRequestEvent ~= nil and EnterablePassengerEnterRequestEvent.run ~= nil then
        local superFunc = EnterablePassengerEnterRequestEvent.run
        EnterablePassengerEnterRequestEvent.run = function(event, connection, ...)
            if shouldBlock() and connection ~= nil and not connection:getIsServer() then return end
            return superFunc(event, connection, ...)
        end
        installed = installed + 1
    end

    -- 2. Блокировка ручного переноса объектов
    if HandsPickUpObjectEvent ~= nil and HandsPickUpObjectEvent.run ~= nil then
        local superFunc = HandsPickUpObjectEvent.run
        HandsPickUpObjectEvent.run = function(event, connection, ...)
            if shouldBlock() and connection ~= nil and not connection:getIsServer() then return end
            return superFunc(event, connection, ...)
        end
        installed = installed + 1
    end

    -- 3. Блокировка ручной бензопилы
    if HandToolChainsaw ~= nil then
        for _, functionName in ipairs({"beginCutting", "beginDelimbing"}) do
            local superFunc = HandToolChainsaw[functionName]
            if superFunc ~= nil then
                HandToolChainsaw[functionName] = function(handTool, ...)
                    if shouldBlock() then warnLocal(); return end
                    return superFunc(handTool, ...)
                end
                installed = installed + 1
            end
        end
    end

    -- 4. Блокировка ландшафтного дизайна (Скульптуринг, покраска, стройка)
    if ConstructionScreen ~= nil then
        local handlers = {"onButtonPrimary", "onButtonPrimaryDrag", "onButtonSecondary", "onButtonSecondaryDrag"}
        for _, functionName in ipairs(handlers) do
            local superFunc = ConstructionScreen[functionName]
            if superFunc ~= nil then
                ConstructionScreen[functionName] = function(screen, ...)
                    if shouldBlock() then warnLocal(); return end
                    return superFunc(screen, ...)
                end
                installed = installed + 1
            end
        end
    end

    if Landscaping ~= nil and Landscaping.sculpt ~= nil then
        local superFunc = Landscaping.sculpt
        Landscaping.sculpt = function(landscaping, ...)
            if shouldBlock() then warnLocal(); return end
            return superFunc(landscaping, ...)
        end
        installed = installed + 1
    end

    if BuyPlaceableData ~= nil and BuyPlaceableData.buy ~= nil then
        local superFunc = BuyPlaceableData.buy
        BuyPlaceableData.buy = function(data, ...)
            if shouldBlock() then warnLocal(); return end
            return superFunc(data, ...)
        end
        installed = installed + 1
    end

    -- 5. Блокировка покупки и продажи техники
    if SellVehicleEvent ~= nil and SellVehicleEvent.run ~= nil and SellVehicleEvent.newServerToClient ~= nil then
        local superFunc = SellVehicleEvent.run
        SellVehicleEvent.run = function(event, connection, ...)
            if shouldBlock() and connection ~= nil and not connection:getIsServer() then
                local vehicle = event.vehicle; local ownerFarmId = 0; local isOwned = false
                if vehicle ~= nil then
                    if vehicle.getOwnerFarmId ~= nil then ownerFarmId = vehicle:getOwnerFarmId() or 0 end
                    if VehiclePropertyState ~= nil then isOwned = vehicle.propertyState == VehiclePropertyState.OWNED end
                end
                connection:sendEvent(SellVehicleEvent.newServerToClient(SellVehicleEvent.SELL_NO_PERMISSION, 0, event.isDirectSell == true, isOwned, ownerFarmId))
                return
            end
            return superFunc(event, connection, ...)
        end
        installed = installed + 1
    end

    if BuyVehicleEvent ~= nil and BuyVehicleEvent.run ~= nil and BuyVehicleEvent.newServerToClient ~= nil then
        local superFunc = BuyVehicleEvent.run
        BuyVehicleEvent.run = function(event, connection, ...)
            if shouldBlock() and connection ~= nil and not connection:getIsServer() then
                connection:sendEvent(BuyVehicleEvent.newServerToClient(BuyVehicleEvent.STATE_NO_PERMISSION, event.vehicleBuyData))
                return
            end
            return superFunc(event, connection, ...)
        end
        installed = installed + 1
    end

    self.hooksInstalled = true
    CompetitionUtils.info("Установлено хуков предстартовой защиты: %d", installed)
end

-------------------------------------------------------------------------------
-- ПРИНУДИТЕЛЬНЫЙ ВЫХОД ИЗ ТЕХНИКИ
-------------------------------------------------------------------------------
function CompetitionSecurity:enforceLocalVehicleLock(dt)
    if self.preStartWarningCooldown > 0 then 
        self.preStartWarningCooldown = math.max(0, self.preStartWarningCooldown - dt) 
    end
    
    if not self:isPreStartLocked() or not CompetitionUtils.getIsClient() or g_localPlayer == nil or g_localPlayer.getCurrentVehicle == nil then
        self.forceExitTimer = 0
        return
    end

    self.forceExitTimer = math.max(0, self.forceExitTimer - dt)
    local vehicle = g_localPlayer:getCurrentVehicle()
    if vehicle == nil or self.forceExitTimer > 0 then return end

    self.forceExitTimer = CompetitionSecurity.FORCE_EXIT_RETRY_MS
    self:showPreStartBlockedWarning()

    local userId = g_localPlayer.userId
    if VehicleLeaveEvent ~= nil and userId ~= nil and g_client ~= nil and g_client.getServerConnection ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil then connection:sendEvent(VehicleLeaveEvent.new(vehicle, userId)); return end
    end

    -- Серверный fallback
    if CompetitionUtils.getIsServer() and userId ~= nil and g_localPlayer.leaveVehicle ~= nil then
        if vehicle.getOwnerConnection ~= nil and vehicle:getOwnerConnection() ~= nil then
            vehicle:setOwnerConnection(nil)
            vehicle.controllerFarmId = nil
        end
        if g_server ~= nil and VehicleLeaveEvent ~= nil then 
            g_server:broadcastEvent(VehicleLeaveEvent.new(vehicle, userId), nil, nil, vehicle) 
        end
        g_localPlayer:leaveVehicle(vehicle, true)
    end
end

-------------------------------------------------------------------------------
-- УПРАВЛЕНИЕ ИГРОВЫМ ВРЕМЕНЕМ
-------------------------------------------------------------------------------
function CompetitionSecurity:freezePreStartTime()
    if not CompetitionUtils.getIsServer() or not self:isPreStartLocked() then return end
    if g_currentMission.missionInfo == nil or g_currentMission.setTimeScale == nil then return end
    
    if self.preStartOriginalTimeScale == nil then 
        self.preStartOriginalTimeScale = g_currentMission.missionInfo.timeScale or 1 
    end
    
    if g_currentMission.missionInfo.timeScale ~= 0 then
        g_currentMission:setTimeScale(0, false)
        CompetitionUtils.info("Время остановлено до старта соревнования.")
        self.preStartTimeFrozen = true
    else
        self.preStartTimeFrozen = true
    end
end

function CompetitionSecurity:restorePreStartTime(noEventSend)
    if not self.preStartTimeFrozen or self.preStartOriginalTimeScale == nil then return end
    if not CompetitionUtils.getIsServer() or g_currentMission.setTimeScale == nil then return end
    
    local restoreValue = self.preStartOriginalTimeScale
    g_currentMission:setTimeScale(restoreValue, noEventSend == true)
    self.preStartTimeFrozen = false
    CompetitionUtils.info("Ограничение времени снято. timeScale восстановлен: %s", tostring(restoreValue))
end

-------------------------------------------------------------------------------
-- ГЛАВНЫЙ МЕТОД ОБНОВЛЕНИЯ ЗАЩИТЫ
-------------------------------------------------------------------------------
function CompetitionSecurity:update(dt)
    -- Попытка отключить обучение, если элементы GUI загрузились с задержкой
    if not self.tutorialHooksInstalled or not self.guidedTourHookInstalled then 
        self:suppressTutorials() 
    end
    
    self:enforceLocalVehicleLock(dt)
    
    if self:isPreStartLocked() then 
        self:freezePreStartTime() 
    end
end