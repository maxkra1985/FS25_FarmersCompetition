--[[
    FS25 Competition Scanner
    Stage 1: diagnostic map-balance scan
    Version: 0.1.2.0

    FarmersCompetition map territory layout:
      farmland 1 -> BLUE team
      farmland 2 -> RED team
      farmland 3 -> GREEN team
      farmland 4 -> YELLOW team
      farmland 5 -> ADMIN territory (not included in team balance)

    Purpose:
      * scan configured competition farmlands directly, regardless of current farm ownership;
      * gracefully skip team farmlands that are not yet painted in the farmland info layer;
      * aggregate every detected fruitType + growthState combination;
      * estimate area from the farmland info-layer raster (runtime-derived, no field-area constants);
      * count HONEY pallet objects by their current world position / farmland id;
      * print a detailed report and a cross-team balance comparison to log.txt.

    This version is deliberately read-only. It does not alter density maps,
    vehicle state, farm ownership, or savegame data.
--]]

CompetitionScanner = {}
local CompetitionScanner_mt = Class(CompetitionScanner)

CompetitionScanner.VERSION = "0.1.2.0"
CompetitionScanner.LOG_PREFIX = "[CompetitionScanner]"

-- These are map structure identifiers, not field/crop/honey target constants.
CompetitionScanner.TEAM_FARMLANDS = {
    { farmlandId = 1, code = "BLUE",   name = "Blue"   },
    { farmlandId = 2, code = "RED",    name = "Red"    },
    { farmlandId = 3, code = "GREEN",  name = "Green"  },
    { farmlandId = 4, code = "YELLOW", name = "Yellow" }
}
CompetitionScanner.ADMIN_FARMLAND_ID = 5

-- Performance-only values. These are not competition/map data constants.
CompetitionScanner.AUTO_START_DELAY_MS = 5000
CompetitionScanner.CELLS_PER_UPDATE = 20000
CompetitionScanner.PROGRESS_STEP = 10

local function safeTostring(value, fallback)
    if value == nil then
        return fallback or "nil"
    end
    return tostring(value)
end

local function getVehicleRootNode(vehicle)
    if vehicle == nil then
        return nil
    end

    if vehicle.rootNode ~= nil and vehicle.rootNode ~= 0 then
        return vehicle.rootNode
    end

    if vehicle.components ~= nil and vehicle.components[1] ~= nil then
        local node = vehicle.components[1].node
        if node ~= nil and node ~= 0 then
            return node
        end
    end

    return nil
end

function CompetitionScanner.new(customMt)
    local self = setmetatable({}, customMt or CompetitionScanner_mt)

    self.autoStartTimer = nil
    self.autoStartDone = false
    self.consoleCommandRegistered = false
    self.scan = nil

    return self
end

function CompetitionScanner:info(formatString, ...)
    Logging.info("%s %s", CompetitionScanner.LOG_PREFIX, string.format(formatString, ...))
end

function CompetitionScanner:warning(formatString, ...)
    Logging.warning("%s %s", CompetitionScanner.LOG_PREFIX, string.format(formatString, ...))
end

function CompetitionScanner:error(formatString, ...)
    Logging.error("%s %s", CompetitionScanner.LOG_PREFIX, string.format(formatString, ...))
end

function CompetitionScanner:loadMap(mapName)
    self.scan = nil
    self.autoStartDone = false
    self.autoStartTimer = CompetitionScanner.AUTO_START_DELAY_MS

    if not self.consoleCommandRegistered then
        addConsoleCommand(
            "competitionScan",
            "Run CompetitionScanner balance scan again",
            "consoleCommandScan",
            self
        )
        self.consoleCommandRegistered = true
    end

    self:info("SCRIPT LOADED version=%s", CompetitionScanner.VERSION)
    self:info("Automatic server-side balance scan scheduled in %.1f s", CompetitionScanner.AUTO_START_DELAY_MS / 1000)
    self:info("Manual rescan command: competitionScan")
end

function CompetitionScanner:deleteMap()
    if self.consoleCommandRegistered then
        removeConsoleCommand("competitionScan")
        self.consoleCommandRegistered = false
    end

    self.scan = nil
    self.autoStartTimer = nil
end

function CompetitionScanner:consoleCommandScan()
    if g_currentMission == nil then
        return "CompetitionScanner: no current mission"
    end

    if not g_currentMission:getIsServer() then
        return "CompetitionScanner: command must be executed on the server/host"
    end

    if self.scan ~= nil and self.scan.running then
        return string.format(
            "CompetitionScanner: scan already running (%d%%)",
            math.floor((self.scan.nextCell / math.max(self.scan.totalCells, 1)) * 100)
        )
    end

    local ok, message = self:startScan("console")
    if ok then
        return "CompetitionScanner: balance scan started; see log.txt"
    end

    return "CompetitionScanner: scan not started - " .. safeTostring(message, "unknown error")
end

function CompetitionScanner:update(dt)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end

    if not self.autoStartDone and self.autoStartTimer ~= nil then
        self.autoStartTimer = self.autoStartTimer - dt
        if self.autoStartTimer <= 0 then
            self.autoStartTimer = nil
            self.autoStartDone = true

            if self.scan == nil or not self.scan.running then
                local ok, message = self:startScan("automatic")
                if not ok then
                    self:warning("Automatic scan was not started: %s", safeTostring(message, "unknown error"))
                end
            end
        end
    end

    if self.scan == nil or not self.scan.running then
        return
    end

    if self.scan.phase == "vegetation" then
        self:scanVegetationChunk(CompetitionScanner.CELLS_PER_UPDATE)
    elseif self.scan.phase == "honey" then
        self:scanHoneyPallets()
        self.scan.phase = "report"
    elseif self.scan.phase == "report" then
        self:printReport()
        self.scan.phase = "done"
        self.scan.running = false
        self:info("SCAN FINISHED")
    end
end

function CompetitionScanner:checkPrerequisites()
    if g_currentMission == nil then
        return false, "g_currentMission is nil"
    end
    if g_farmlandManager == nil then
        return false, "g_farmlandManager is nil"
    end
    if g_fruitTypeManager == nil then
        return false, "g_fruitTypeManager is nil"
    end
    if g_fillTypeManager == nil then
        return false, "g_fillTypeManager is nil"
    end
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return false, "FSDensityMapUtil.getFruitTypeIndexAtWorldPos is unavailable"
    end

    local farmlandMap = g_farmlandManager:getLocalMap()
    if farmlandMap == nil or farmlandMap == 0 then
        return false, "farmland info layer is unavailable"
    end

    if g_farmlandManager.localMapWidth == nil or g_farmlandManager.localMapWidth <= 0
        or g_farmlandManager.localMapHeight == nil or g_farmlandManager.localMapHeight <= 0 then
        return false, "invalid farmland info-layer dimensions"
    end

    return true
end

function CompetitionScanner:collectConfiguredTeams()
    local teams = {}
    local teamDataByFarmlandId = {}

    for _, config in ipairs(CompetitionScanner.TEAM_FARMLANDS) do
        local data = {
            farmlandId = config.farmlandId,
            code = config.code,
            name = config.name,
            presentInInfoLayer = false,
            fruitStates = {},
            honeyPallets = {},
            scannedLandCells = 0
        }

        table.insert(teams, data)
        teamDataByFarmlandId[data.farmlandId] = data
    end

    table.sort(teams, function(a, b)
        return a.farmlandId < b.farmlandId
    end)

    return teams, teamDataByFarmlandId
end

function CompetitionScanner:getActiveTeams()
    local activeTeams = {}

    if self.scan == nil then
        return activeTeams
    end

    for _, teamData in ipairs(self.scan.teams) do
        if teamData.presentInInfoLayer and teamData.scannedLandCells > 0 then
            table.insert(activeTeams, teamData)
        end
    end

    table.sort(activeTeams, function(a, b)
        return a.farmlandId < b.farmlandId
    end)

    return activeTeams
end

function CompetitionScanner:startScan(reason)
    local prerequisitesOk, prerequisiteError = self:checkPrerequisites()
    if not prerequisitesOk then
        return false, prerequisiteError
    end

    local teams, teamDataByFarmlandId = self:collectConfiguredTeams()

    local farmlandMap = g_farmlandManager:getLocalMap()
    local mapWidth = g_farmlandManager.localMapWidth
    local mapHeight = g_farmlandManager.localMapHeight
    local terrainSize = g_currentMission.terrainSize or getTerrainSize(g_terrainNode)

    if terrainSize == nil or terrainSize <= 0 then
        return false, "invalid terrain size"
    end

    local cellSizeX = terrainSize / mapWidth
    local cellSizeZ = terrainSize / mapHeight
    local cellAreaM2 = cellSizeX * cellSizeZ

    self.scan = {
        running = true,
        phase = "vegetation",
        reason = reason or "unknown",
        teams = teams,
        teamDataByFarmlandId = teamDataByFarmlandId,
        farmlandMap = farmlandMap,
        mapWidth = mapWidth,
        mapHeight = mapHeight,
        terrainSize = terrainSize,
        terrainHalfSize = terrainSize * 0.5,
        cellSizeX = cellSizeX,
        cellSizeZ = cellSizeZ,
        cellAreaM2 = cellAreaM2,
        totalCells = mapWidth * mapHeight,
        nextCell = 0,
        nextProgressPercent = CompetitionScanner.PROGRESS_STEP,
        teamLandCells = 0,
        adminLandCells = 0,
        adminPresentInInfoLayer = false,
        adminHoneyPallets = {},
        unassignedHoneyPallets = {},
        startedAtGameTime = g_currentMission.time or 0
    }

    self:info("============================================================")
    self:info("START BALANCE SCAN version=%s reason=%s", CompetitionScanner.VERSION, safeTostring(reason, "unknown"))
    self:info("Configured team farmlands:")
    for _, teamData in ipairs(teams) do
        self:info("  farmlandId=%d team=%s", teamData.farmlandId, teamData.code)
    end
    self:info("  farmlandId=%d role=ADMIN (ignored in team balance)", CompetitionScanner.ADMIN_FARMLAND_ID)
    self:info("Current farm ownership is intentionally ignored by Stage 1 scanner.")
    self:info(
        "Farmland scan grid: %dx%d, terrain=%.2f m, cell=%.4f x %.4f m, cellArea=%.6f m2",
        mapWidth,
        mapHeight,
        terrainSize,
        cellSizeX,
        cellSizeZ,
        cellAreaM2
    )
    self:info("Area values in this diagnostic version are raster estimates derived from the farmland info-layer resolution.")
    self:info("No field areas, crop areas, growth states or honey counts are hard-coded.")

    return true
end

function CompetitionScanner:addFruitSample(teamData, fruitTypeIndex, growthState, worldX, worldZ)
    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local fruitName

    if fruitDesc ~= nil and fruitDesc.name ~= nil then
        fruitName = tostring(fruitDesc.name)
    else
        fruitName = string.format("FRUIT_%d", fruitTypeIndex)
    end

    growthState = tonumber(growthState) or -1
    local key = string.format("%d:%d", fruitTypeIndex, growthState)
    local entry = teamData.fruitStates[key]

    if entry == nil then
        entry = {
            key = key,
            fruitTypeIndex = fruitTypeIndex,
            fruitName = fruitName,
            growthState = growthState,
            cells = 0,
            areaM2 = 0,
            sumX = 0,
            sumZ = 0,
            minX = worldX,
            maxX = worldX,
            minZ = worldZ,
            maxZ = worldZ,
            -- Flat x,z pairs. The competition manager copies the required
            -- task regions after the final pre-start scan, so later progress
            -- scans stay inside the exact raster cells that existed at start.
            samplePoints = {}
        }
        teamData.fruitStates[key] = entry
    end

    entry.cells = entry.cells + 1
    entry.areaM2 = entry.areaM2 + self.scan.cellAreaM2
    entry.sumX = entry.sumX + worldX
    entry.sumZ = entry.sumZ + worldZ
    entry.minX = math.min(entry.minX, worldX)
    entry.maxX = math.max(entry.maxX, worldX)
    entry.minZ = math.min(entry.minZ, worldZ)
    entry.maxZ = math.max(entry.maxZ, worldZ)
    local samples = entry.samplePoints
    samples[#samples + 1] = worldX
    samples[#samples + 1] = worldZ
end

function CompetitionScanner:scanVegetationChunk(maxCells)
    local scan = self.scan
    if scan == nil or scan.phase ~= "vegetation" then
        return
    end

    local lastCellExclusive = math.min(scan.nextCell + maxCells, scan.totalCells)
    local width = scan.mapWidth
    local terrainSize = scan.terrainSize
    local halfSize = scan.terrainHalfSize
    local noFruitIndex = FruitType.UNKNOWN or 0

    while scan.nextCell < lastCellExclusive do
        local linearIndex = scan.nextCell
        local localX = linearIndex % width
        local localZ = math.floor(linearIndex / width)

        local farmlandId = getBitVectorMapPoint(
            scan.farmlandMap,
            localX,
            localZ,
            0,
            g_farmlandManager.numberOfBits
        )

        local teamData = scan.teamDataByFarmlandId[farmlandId]

        if teamData ~= nil then
            teamData.presentInInfoLayer = true
            teamData.scannedLandCells = teamData.scannedLandCells + 1
            scan.teamLandCells = scan.teamLandCells + 1

            local worldX = ((localX + 0.5) / scan.mapWidth) * terrainSize - halfSize
            local worldZ = ((localZ + 0.5) / scan.mapHeight) * terrainSize - halfSize

            local fruitTypeIndex, growthState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(worldX, worldZ)
            if fruitTypeIndex ~= nil and fruitTypeIndex ~= noFruitIndex then
                self:addFruitSample(teamData, fruitTypeIndex, growthState, worldX, worldZ)
            end
        elseif farmlandId == CompetitionScanner.ADMIN_FARMLAND_ID then
            scan.adminPresentInInfoLayer = true
            scan.adminLandCells = scan.adminLandCells + 1
        end

        scan.nextCell = scan.nextCell + 1
    end

    local progress = math.floor((scan.nextCell / math.max(scan.totalCells, 1)) * 100)
    if progress >= scan.nextProgressPercent and scan.nextCell < scan.totalCells then
        self:info("Vegetation scan progress: %d%%", progress)
        while scan.nextProgressPercent <= progress do
            scan.nextProgressPercent = scan.nextProgressPercent + CompetitionScanner.PROGRESS_STEP
        end
    end

    if scan.nextCell >= scan.totalCells then
        self:info("Vegetation scan progress: 100%%")
        self:info("Vegetation raster pass complete; configured team cells sampled: %d", scan.teamLandCells)
        scan.phase = "honey"
    end
end

function CompetitionScanner:scanHoneyPallets()
    local scan = self.scan
    if scan == nil then
        return
    end

    local honeyFillTypeIndex = g_fillTypeManager:getFillTypeIndexByName("HONEY")
    if honeyFillTypeIndex == nil then
        self:warning("FillType HONEY was not found; honey pallet count will be zero")
        return
    end

    local vehicles = nil
    if g_currentMission.vehicleSystem ~= nil then
        vehicles = g_currentMission.vehicleSystem.vehicles
    end
    vehicles = vehicles or g_currentMission.vehicles or {}

    local totalHoneyPallets = 0
    local assignedTeamPallets = 0

    for _, vehicle in pairs(vehicles) do
        if vehicle ~= nil
            and vehicle.isPallet == true
            and vehicle.spec_pallet ~= nil
            and vehicle.getFillUnitFillType ~= nil then

            local fillUnitIndex = vehicle.spec_pallet.fillUnitIndex or 1
            local fillTypeIndex = vehicle:getFillUnitFillType(fillUnitIndex)

            if fillTypeIndex == honeyFillTypeIndex then
                totalHoneyPallets = totalHoneyPallets + 1

                local rootNode = getVehicleRootNode(vehicle)
                if rootNode ~= nil then
                    local worldX, worldY, worldZ = getWorldTranslation(rootNode)
                    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(worldX, worldZ)
                    local teamData = scan.teamDataByFarmlandId[farmlandId]

                    local palletInfo = {
                        object = vehicle,
                        x = worldX,
                        y = worldY,
                        z = worldZ,
                        farmlandId = farmlandId
                    }

                    if teamData ~= nil then
                        teamData.presentInInfoLayer = true
                        table.insert(teamData.honeyPallets, palletInfo)
                        assignedTeamPallets = assignedTeamPallets + 1
                    elseif farmlandId == CompetitionScanner.ADMIN_FARMLAND_ID then
                        table.insert(scan.adminHoneyPallets, palletInfo)
                    else
                        table.insert(scan.unassignedHoneyPallets, palletInfo)
                    end
                else
                    table.insert(scan.unassignedHoneyPallets, {
                        object = vehicle,
                        x = nil,
                        y = nil,
                        z = nil,
                        farmlandId = nil
                    })
                    self:warning("Found a HONEY pallet without a usable root node")
                end
            end
        end
    end

    self:info(
        "Honey pallet scan complete: total=%d assignedToTeams=%d admin=%d outsideConfiguredTeamTerritory=%d",
        totalHoneyPallets,
        assignedTeamPallets,
        #scan.adminHoneyPallets,
        #scan.unassignedHoneyPallets
    )
end

function CompetitionScanner:getSortedFruitStateRows(activeTeams)
    local rowsByKey = {}

    for _, teamData in ipairs(activeTeams or {}) do
        for key, entry in pairs(teamData.fruitStates) do
            if rowsByKey[key] == nil then
                rowsByKey[key] = {
                    key = key,
                    fruitTypeIndex = entry.fruitTypeIndex,
                    fruitName = entry.fruitName,
                    growthState = entry.growthState
                }
            end
        end
    end

    local rows = {}
    for _, row in pairs(rowsByKey) do
        table.insert(rows, row)
    end

    table.sort(rows, function(a, b)
        local aName = string.upper(a.fruitName or "")
        local bName = string.upper(b.fruitName or "")
        if aName ~= bName then
            return aName < bName
        end
        if a.growthState ~= b.growthState then
            return a.growthState < b.growthState
        end
        return a.fruitTypeIndex < b.fruitTypeIndex
    end)

    return rows
end

function CompetitionScanner:getAreaHa(teamData, key)
    local entry = teamData.fruitStates[key]
    if entry == nil then
        return 0
    end
    return entry.areaM2 / 10000
end

function CompetitionScanner:printTerritoryStatus()
    local scan = self.scan

    self:info("------------------------------------------------------------")
    self:info("CONFIGURED TERRITORIES")
    self:info("------------------------------------------------------------")

    for _, teamData in ipairs(scan.teams) do
        if teamData.presentInInfoLayer and teamData.scannedLandCells > 0 then
            self:info(
                "farmlandId=%d team=%-6s status=FOUND cells=%d area=%.3f m2 / %.6f ha",
                teamData.farmlandId,
                teamData.code,
                teamData.scannedLandCells,
                teamData.scannedLandCells * scan.cellAreaM2,
                (teamData.scannedLandCells * scan.cellAreaM2) / 10000
            )
        else
            self:info(
                "farmlandId=%d team=%-6s status=NOT MARKED - skipped from balance comparison",
                teamData.farmlandId,
                teamData.code
            )
        end
    end

    if scan.adminPresentInInfoLayer and scan.adminLandCells > 0 then
        self:info(
            "farmlandId=%d role=ADMIN status=FOUND cells=%d area=%.3f m2 / %.6f ha - ignored in team balance",
            CompetitionScanner.ADMIN_FARMLAND_ID,
            scan.adminLandCells,
            scan.adminLandCells * scan.cellAreaM2,
            (scan.adminLandCells * scan.cellAreaM2) / 10000
        )
    else
        self:info(
            "farmlandId=%d role=ADMIN status=NOT MARKED - ignored",
            CompetitionScanner.ADMIN_FARMLAND_ID
        )
    end
end

function CompetitionScanner:printSummary(rows, activeTeams)
    self:info("------------------------------------------------------------")
    self:info("BALANCE SUMMARY - vegetation area [ha]")
    self:info("------------------------------------------------------------")

    if #activeTeams == 0 then
        self:warning("No configured team farmland is currently marked in farmland info layer; balance table is empty")
        return
    end

    local header = string.format("%-30s", "FRUIT / GROWTH STATE")
    for _, teamData in ipairs(activeTeams) do
        header = header .. string.format(" | %-6s %9s", teamData.code, "ha")
    end
    header = header .. " | DELTA %"
    self:info("%s", header)

    if #rows == 0 then
        self:info("<no vegetation detected on active team territories>")
    end

    for _, row in ipairs(rows) do
        local label = string.format("%s / %d", row.fruitName, row.growthState)
        local line = string.format("%-30s", label)
        local minValue = math.huge
        local maxValue = -math.huge

        for _, teamData in ipairs(activeTeams) do
            local areaHa = self:getAreaHa(teamData, row.key)
            minValue = math.min(minValue, areaHa)
            maxValue = math.max(maxValue, areaHa)
            line = line .. string.format(" | %16.4f", areaHa)
        end

        if minValue == math.huge then
            minValue = 0
            maxValue = 0
        end

        local delta = maxValue - minValue
        local deltaPct = maxValue > 0 and (delta / maxValue) * 100 or 0
        line = line .. string.format(" | %7.3f", deltaPct)
        self:info("%s", line)
    end

    self:info("------------------------------------------------------------")
    self:info("BALANCE SUMMARY - honey pallets [count]")
    self:info("------------------------------------------------------------")

    local honeyLine = string.format("%-30s", "HONEY PALLETS")
    local minHoney = math.huge
    local maxHoney = -math.huge

    for _, teamData in ipairs(activeTeams) do
        local count = #teamData.honeyPallets
        minHoney = math.min(minHoney, count)
        maxHoney = math.max(maxHoney, count)
        honeyLine = honeyLine .. string.format(" | %16d", count)
    end

    if minHoney == math.huge then
        minHoney = 0
        maxHoney = 0
    end

    local honeyDelta = maxHoney - minHoney
    local honeyDeltaPct = maxHoney > 0 and (honeyDelta / maxHoney) * 100 or 0
    honeyLine = honeyLine .. string.format(" | %7.3f", honeyDeltaPct)
    self:info("%s", honeyLine)

    self:info("------------------------------------------------------------")
    self:info("BALANCE DIFFERENCES")
    self:info("------------------------------------------------------------")

    if #activeTeams < 2 then
        self:info("Only %d active team territory detected; cross-team differences are not meaningful yet", #activeTeams)
    end

    for _, row in ipairs(rows) do
        local minValue = math.huge
        local maxValue = -math.huge

        for _, teamData in ipairs(activeTeams) do
            local areaHa = self:getAreaHa(teamData, row.key)
            minValue = math.min(minValue, areaHa)
            maxValue = math.max(maxValue, areaHa)
        end

        if minValue == math.huge then
            minValue = 0
            maxValue = 0
        end

        local delta = maxValue - minValue
        local deltaPct = maxValue > 0 and (delta / maxValue) * 100 or 0
        self:info(
            "%-24s state=%-3d min=%.6f ha max=%.6f ha delta=%.6f ha delta=%.4f%%",
            row.fruitName,
            row.growthState,
            minValue,
            maxValue,
            delta,
            deltaPct
        )
    end

    self:info(
        "HONEY PALLETS min=%d max=%d delta=%d delta=%.4f%%",
        minHoney,
        maxHoney,
        honeyDelta,
        honeyDeltaPct
    )
end

function CompetitionScanner:printTeamDetails(teamData)
    self:info("------------------------------------------------------------")
    self:info("TEAM DETAILS farmlandId=%d team=%s", teamData.farmlandId, teamData.code)
    self:info(
        "Raster cells scanned: %d (%.2f m2 / %.6f ha total territory raster area)",
        teamData.scannedLandCells,
        teamData.scannedLandCells * self.scan.cellAreaM2,
        (teamData.scannedLandCells * self.scan.cellAreaM2) / 10000
    )

    local entries = {}
    for _, entry in pairs(teamData.fruitStates) do
        table.insert(entries, entry)
    end

    table.sort(entries, function(a, b)
        local aName = string.upper(a.fruitName or "")
        local bName = string.upper(b.fruitName or "")
        if aName ~= bName then
            return aName < bName
        end
        if a.growthState ~= b.growthState then
            return a.growthState < b.growthState
        end
        return a.fruitTypeIndex < b.fruitTypeIndex
    end)

    self:info("VEGETATION:")
    if #entries == 0 then
        self:info("  <none detected>")
    else
        for _, entry in ipairs(entries) do
            local centerX = entry.cells > 0 and entry.sumX / entry.cells or 0
            local centerZ = entry.cells > 0 and entry.sumZ / entry.cells or 0
            self:info(
                "  fruit=%-18s fruitIndex=%-3d growthState=%-3d cells=%-8d area=%.3f m2 area=%.6f ha center=(%.2f, %.2f) boundsX=[%.2f..%.2f] boundsZ=[%.2f..%.2f]",
                entry.fruitName,
                entry.fruitTypeIndex,
                entry.growthState,
                entry.cells,
                entry.areaM2,
                entry.areaM2 / 10000,
                centerX,
                centerZ,
                entry.minX,
                entry.maxX,
                entry.minZ,
                entry.maxZ
            )
        end
    end

    self:info("HONEY PALLETS: %d", #teamData.honeyPallets)
    for index, palletInfo in ipairs(teamData.honeyPallets) do
        self:info(
            "  #%d position=(%.2f, %.2f, %.2f) farmlandId=%s",
            index,
            palletInfo.x or 0,
            palletInfo.y or 0,
            palletInfo.z or 0,
            safeTostring(palletInfo.farmlandId, "nil")
        )
    end
end

function CompetitionScanner:printReport()
    local scan = self.scan
    if scan == nil then
        return
    end

    local activeTeams = self:getActiveTeams()
    local rows = self:getSortedFruitStateRows(activeTeams)

    self:info("============================================================")
    self:info("COMPETITION SCANNER - BALANCE REPORT")
    self:info("Version: %s", CompetitionScanner.VERSION)
    self:info("Active marked team territories: %d", #activeTeams)
    self:info(
        "Grid: %dx%d; cell %.4f x %.4f m; %.6f m2/sample",
        scan.mapWidth,
        scan.mapHeight,
        scan.cellSizeX,
        scan.cellSizeZ,
        scan.cellAreaM2
    )
    self:info("IMPORTANT: vegetation areas are diagnostic raster estimates on the farmland info-layer grid.")
    self:info("Growth-state numbers are raw FS25 values and are intentionally not interpreted yet.")
    self:info("Team assignment is based on farmlandId 1..4, NOT current farm ownership.")

    self:printTerritoryStatus()
    self:printSummary(rows, activeTeams)

    for _, teamData in ipairs(activeTeams) do
        self:printTeamDetails(teamData)
    end

    if #scan.adminHoneyPallets > 0 then
        self:info("------------------------------------------------------------")
        self:info("ADMIN HONEY PALLETS (ignored in team balance): %d", #scan.adminHoneyPallets)
        for index, palletInfo in ipairs(scan.adminHoneyPallets) do
            self:info(
                "  #%d position=(%.2f, %.2f, %.2f) farmlandId=%s",
                index,
                palletInfo.x or 0,
                palletInfo.y or 0,
                palletInfo.z or 0,
                safeTostring(palletInfo.farmlandId, "nil")
            )
        end
    end

    if #scan.unassignedHoneyPallets > 0 then
        self:info("------------------------------------------------------------")
        self:warning("HONEY PALLETS OUTSIDE CONFIGURED TEAM TERRITORY: %d", #scan.unassignedHoneyPallets)
        for index, palletInfo in ipairs(scan.unassignedHoneyPallets) do
            if palletInfo.x ~= nil then
                self:warning(
                    "  #%d position=(%.2f, %.2f, %.2f) farmlandId=%s",
                    index,
                    palletInfo.x,
                    palletInfo.y or 0,
                    palletInfo.z,
                    safeTostring(palletInfo.farmlandId, "nil")
                )
            else
                self:warning("  #%d position=<unavailable>", index)
            end
        end
    end

    self:info("============================================================")
end

g_competitionScanner = CompetitionScanner.new()
addModEventListener(g_competitionScanner)
