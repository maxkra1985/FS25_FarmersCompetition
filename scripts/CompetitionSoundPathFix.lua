--[[
    FS25 FarmersCompetition - Notification sound path fix

    g_currentModDirectory существует только во время загрузки Lua-файлов мода.
    После завершения загрузки GIANTS очищает эту глобальную переменную, поэтому
    отложенная загрузка звуков должна использовать каталог, сохранённый сейчас.
]]

local modDir = g_currentModDirectory

-- Назначение: лениво загружает локальный 2D sample по зарегистрированному soundId.
-- Переопределяет реализацию CompetitionManager, чтобы путь к файлу всегда
-- вычислялся относительно каталога мода, сохранённого во время загрузки скрипта.
function CompetitionManager:getNotificationSoundSample(soundId)
    if not CompetitionUtils.getIsClient() then return nil end

    local definition = self.notificationSounds ~= nil and self.notificationSounds[soundId] or nil
    if definition == nil then
        CompetitionUtils.warning("Неизвестный soundId уведомления: %s", tostring(soundId))
        return nil
    end

    if definition.sample ~= nil and definition.sample ~= 0 then
        return definition.sample
    end

    local filename = Utils.getFilename(definition.filename, modDir)
    local sample = createSample(definition.sampleName or ("FarmersCompetition_" .. tostring(soundId)))
    if sample == nil or sample == 0 then
        CompetitionUtils.error("Не удалось создать sample soundId=%s", tostring(soundId))
        return nil
    end

    if not loadSample(sample, filename, false) then
        delete(sample)
        CompetitionUtils.error(
            "Не удалось загрузить звук soundId=%s filename=%s",
            tostring(soundId),
            tostring(filename)
        )
        return nil
    end

    -- Уведомления являются непозиционными звуками интерфейса.
    if AudioGroup ~= nil and AudioGroup.GUI ~= nil and setSampleGroup ~= nil then
        setSampleGroup(sample, AudioGroup.GUI)
    end

    definition.sample = sample
    return sample
end

CompetitionUtils.info("Исправление путей уведомительных звуков установлено")
