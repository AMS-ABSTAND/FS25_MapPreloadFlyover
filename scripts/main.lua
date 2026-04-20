MapPreloadFlyover = {}

MapPreloadFlyover.MOD_NAME = g_currentModName or "FS25_MapPreloadFlyover"
MapPreloadFlyover.MOD_DIR = g_currentModDirectory or ""
MapPreloadFlyover.START_COMMAND = "preloadMapShaders"
MapPreloadFlyover.STOP_COMMAND = "preloadMapShadersStop"

MapPreloadFlyover.isActive = false
MapPreloadFlyover.drawOverlay = true
MapPreloadFlyover.savedState = nil
MapPreloadFlyover.routePoints = {}
MapPreloadFlyover.routeSegments = {}
MapPreloadFlyover.settings = {}
MapPreloadFlyover.travelledDistance = 0
MapPreloadFlyover.totalDistance = 0
MapPreloadFlyover.lastProgressStep = -1
MapPreloadFlyover.statusText = ""
MapPreloadFlyover.coverage = nil
MapPreloadFlyover.terrainSize = 0
MapPreloadFlyover.mapMetrics = nil

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end

    if value > maxValue then
        return maxValue
    end

    return value
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function distance2D(x1, z1, x2, z2)
    local dx = x2 - x1
    local dz = z2 - z1
    return math.sqrt(dx * dx + dz * dz)
end

local function appendUniqueNumber(list, value)
    local lastValue = list[#list]
    if lastValue == nil or math.abs(lastValue - value) > 0.01 then
        table.insert(list, value)
    end
end

local function parseBoolean(value, defaultValue)
    if value == nil or value == "" then
        return defaultValue
    end

    local normalized = string.lower(tostring(value))
    if normalized == "1" or normalized == "true" or normalized == "yes" or normalized == "y" or normalized == "on" then
        return true
    end

    if normalized == "0" or normalized == "false" or normalized == "no" or normalized == "n" or normalized == "off" then
        return false
    end

    return defaultValue
end

local function formatMeters(value)
    return string.format("%.0f", value or 0)
end

local function formatSeconds(value)
    local totalSeconds = math.max(0, math.floor((value or 0) + 0.5))
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds % 60
    return string.format("%02d:%02d", minutes, seconds)
end

function MapPreloadFlyover:log(message)
    print(string.format("[%s] %s", self.MOD_NAME, message))
end

function MapPreloadFlyover:getTerrainRootNode()
    local mission = g_currentMission
    if mission ~= nil and mission.terrainRootNode ~= nil and mission.terrainRootNode ~= 0 then
        return mission.terrainRootNode
    end

    if g_terrainNode ~= nil and g_terrainNode ~= 0 then
        return g_terrainNode
    end

    return nil
end

function MapPreloadFlyover:getTerrainSize()
    local mission = g_currentMission
    if mission ~= nil and mission.terrainSize ~= nil and mission.terrainSize > 0 then
        return mission.terrainSize
    end

    local terrainRootNode = self:getTerrainRootNode()
    if terrainRootNode ~= nil then
        return getTerrainSize(terrainRootNode)
    end

    return 0
end

function MapPreloadFlyover:getMapMetrics(terrainSize)
    local resolvedTerrainSize = terrainSize or self:getTerrainSize()
    if resolvedTerrainSize <= 0 then
        return nil
    end

    local heightmapSize = resolvedTerrainSize * 0.5
    local sideFactor = resolvedTerrainSize / 1024
    local mapFactor = math.max(1, math.floor(sideFactor * sideFactor + 0.5))

    return {
        terrainSize = resolvedTerrainSize,
        heightmapSize = heightmapSize,
        kilometerSize = resolvedTerrainSize / 1000,
        sideFactor = sideFactor,
        mapFactor = mapFactor,
        densityMapSize = heightmapSize * 4
    }
end

function MapPreloadFlyover:getLocalPlayer()
    return g_localPlayer
end

function MapPreloadFlyover:getTerrainHeight(x, z)
    local terrainRootNode = self:getTerrainRootNode()
    if terrainRootNode == nil then
        return 0
    end

    local worldX, worldZ = self:mapToWorldPosition(x, z)
    return getTerrainHeightAtWorldPos(terrainRootNode, worldX, 0, worldZ)
end

function MapPreloadFlyover:getTerrainWorldBounds()
    local terrainSize = self.terrainSize
    if terrainSize <= 0 then
        terrainSize = self:getTerrainSize()
    end

    local terrainRootNode = self:getTerrainRootNode()
    local centerX = 0
    local centerZ = 0

    if terrainRootNode ~= nil then
        centerX, _, centerZ = getWorldTranslation(terrainRootNode)
    end

    local halfSize = terrainSize * 0.5
    return centerX - halfSize, centerX + halfSize, centerZ - halfSize, centerZ + halfSize
end

function MapPreloadFlyover:mapToWorldPosition(x, z)
    local terrainSize = self.terrainSize
    if terrainSize <= 0 then
        terrainSize = self:getTerrainSize()
    end

    local mapX = clamp(x or 0, 0, terrainSize)
    local mapZ = clamp(z or 0, 0, terrainSize)
    local minWorldX, maxWorldX, minWorldZ, maxWorldZ = self:getTerrainWorldBounds()

    return clamp(minWorldX + mapX, minWorldX, maxWorldX), clamp(minWorldZ + mapZ, minWorldZ, maxWorldZ)
end

function MapPreloadFlyover:limitPositionToTerrain(x, z)
    local terrainSize = self.terrainSize
    if terrainSize <= 0 then
        terrainSize = self:getTerrainSize()
    end

    return clamp(x, 0, terrainSize), clamp(z, 0, terrainSize)
end

function MapPreloadFlyover:addRoutePoint(routePoints, x, z)
    if x == nil or z == nil then
        return
    end

    x, z = self:limitPositionToTerrain(x, z)

    local lastPoint = routePoints[#routePoints]
    if lastPoint ~= nil then
        if math.abs(lastPoint.x - x) < 0.01 and math.abs(lastPoint.z - z) < 0.01 then
            return
        end
    end

    table.insert(routePoints, {x = x, z = z})
end

function MapPreloadFlyover:getLaneSpacing(spacing, terrainSize)
    local metrics = self.mapMetrics or self:getMapMetrics(terrainSize)
    local sideFactor = metrics ~= nil and metrics.sideFactor or 1
    local multiplier = clamp(0.75 + (sideFactor - 1) * 0.02, 0.75, 1.0)
    return clamp(spacing * multiplier, 64, math.max(64, terrainSize or spacing))
end

function MapPreloadFlyover:buildSweepCoordinates(maxCoord, step)
    local coordinates = {}
    local current = 0

    appendUniqueNumber(coordinates, 0)

    while current < maxCoord do
        current = current + step
        if current < maxCoord then
            appendUniqueNumber(coordinates, current)
        end
    end

    appendUniqueNumber(coordinates, maxCoord)
    return coordinates
end

function MapPreloadFlyover:addPerimeterPass(routePoints, maxCoord)
    self:addRoutePoint(routePoints, 0, 0)
    self:addRoutePoint(routePoints, 0, maxCoord)
    self:addRoutePoint(routePoints, maxCoord, maxCoord)
    self:addRoutePoint(routePoints, maxCoord, 0)
    self:addRoutePoint(routePoints, 0, 0)
end

function MapPreloadFlyover:addVerticalSweepPass(routePoints, xCoordinates, maxCoord)
    for index, x in ipairs(xCoordinates) do
        if index % 2 == 1 then
            self:addRoutePoint(routePoints, x, 0)
            self:addRoutePoint(routePoints, x, maxCoord)
        else
            self:addRoutePoint(routePoints, x, maxCoord)
            self:addRoutePoint(routePoints, x, 0)
        end
    end
end

function MapPreloadFlyover:addHorizontalSweepPass(routePoints, zCoordinates, maxCoord)
    for index, z in ipairs(zCoordinates) do
        if index % 2 == 1 then
            self:addRoutePoint(routePoints, 0, z)
            self:addRoutePoint(routePoints, maxCoord, z)
        else
            self:addRoutePoint(routePoints, maxCoord, z)
            self:addRoutePoint(routePoints, 0, z)
        end
    end
end

function MapPreloadFlyover:buildRoute(laneSpacing)
    local terrainSize = self.terrainSize
    local routePoints = {}

    if terrainSize <= 0 then
        return routePoints
    end

    local xCoordinates = self:buildSweepCoordinates(terrainSize, laneSpacing)
    self:addVerticalSweepPass(routePoints, xCoordinates, terrainSize)

    return routePoints
end

function MapPreloadFlyover:buildSegments(routePoints)
    local routeSegments = {}
    local totalDistance = 0

    for i = 2, #routePoints do
        local from = routePoints[i - 1]
        local to = routePoints[i]
        local length = distance2D(from.x, from.z, to.x, to.z)

        table.insert(routeSegments, {
            from = from,
            to = to,
            length = length,
            startDistance = totalDistance,
            endDistance = totalDistance + length
        })

        totalDistance = totalDistance + length
    end

    return routeSegments, totalDistance
end

function MapPreloadFlyover:getRouteSample(distanceAlongRoute)
    local sampleDistance = clamp(distanceAlongRoute or 0, 0, self.totalDistance)

    if #self.routeSegments == 0 then
        local point = self.routePoints[1]
        if point ~= nil then
            return point.x, point.z
        end

        return nil, nil
    end

    for _, segment in ipairs(self.routeSegments) do
        if sampleDistance <= segment.endDistance or segment == self.routeSegments[#self.routeSegments] then
            local localDistance = sampleDistance - segment.startDistance
            local t = 1

            if segment.length > 0.0001 then
                t = clamp(localDistance / segment.length, 0, 1)
            end

            return lerp(segment.from.x, segment.to.x, t), lerp(segment.from.z, segment.to.z, t)
        end
    end

    local lastPoint = self.routePoints[#self.routePoints]
    if lastPoint ~= nil then
        return lastPoint.x, lastPoint.z
    end

    return nil, nil
end

function MapPreloadFlyover:createCoverageData(terrainSize, laneSpacing, height)
    local baseCellSize = clamp(laneSpacing * 0.6, 48, 160)
    local resolution = clamp(math.ceil(terrainSize / baseCellSize), 16, 32)
    local cellSize = terrainSize / resolution
    local coverageRadius = math.max(laneSpacing * 0.9, height * 0.55)

    return {
        terrainSize = terrainSize,
        resolution = resolution,
        cellSize = cellSize,
        coverageRadius = coverageRadius,
        planned = {},
        visited = {},
        plannedCount = 0,
        visitedCount = 0,
        currentIndex = nil
    }
end

function MapPreloadFlyover:getCoverageIndex(coverage, cellX, cellZ)
    return (cellZ - 1) * coverage.resolution + cellX
end

function MapPreloadFlyover:markCoverageMask(mask, coverage, x, z, radius)
    local minCellX = clamp(math.floor((x - radius) / coverage.cellSize) + 1, 1, coverage.resolution)
    local maxCellX = clamp(math.floor((x + radius) / coverage.cellSize) + 1, 1, coverage.resolution)
    local minCellZ = clamp(math.floor((z - radius) / coverage.cellSize) + 1, 1, coverage.resolution)
    local maxCellZ = clamp(math.floor((z + radius) / coverage.cellSize) + 1, 1, coverage.resolution)
    local radiusSquared = radius * radius
    local addedCells = 0

    for cellZ = minCellZ, maxCellZ do
        local centerZ = (cellZ - 0.5) * coverage.cellSize

        for cellX = minCellX, maxCellX do
            local centerX = (cellX - 0.5) * coverage.cellSize
            local dx = centerX - x
            local dz = centerZ - z

            if dx * dx + dz * dz <= radiusSquared then
                local index = self:getCoverageIndex(coverage, cellX, cellZ)
                if not mask[index] then
                    mask[index] = true
                    addedCells = addedCells + 1
                end
            end
        end
    end

    return addedCells
end

function MapPreloadFlyover:buildPlannedCoverage(coverage)
    local sampleStep = math.max(coverage.cellSize * 0.5, 12)

    for _, segment in ipairs(self.routeSegments) do
        local steps = math.max(1, math.ceil(segment.length / sampleStep))

        for stepIndex = 0, steps do
            local t = stepIndex / steps
            local x = lerp(segment.from.x, segment.to.x, t)
            local z = lerp(segment.from.z, segment.to.z, t)
            coverage.plannedCount = coverage.plannedCount + self:markCoverageMask(coverage.planned, coverage, x, z, coverage.coverageRadius)
        end
    end
end

function MapPreloadFlyover:updateVisitedCoverage(x, z)
    local coverage = self.coverage
    if coverage == nil then
        return
    end

    coverage.visitedCount = coverage.visitedCount + self:markCoverageMask(coverage.visited, coverage, x, z, coverage.coverageRadius)

    local cellX = clamp(math.floor(x / coverage.cellSize) + 1, 1, coverage.resolution)
    local cellZ = clamp(math.floor(z / coverage.cellSize) + 1, 1, coverage.resolution)
    coverage.currentIndex = self:getCoverageIndex(coverage, cellX, cellZ)
end

function MapPreloadFlyover:getCoveragePercent()
    local coverage = self.coverage
    if coverage == nil or coverage.plannedCount <= 0 then
        return 0
    end

    return (coverage.visitedCount / coverage.plannedCount) * 100
end

function MapPreloadFlyover:getLookRotation(x, y, z, aheadDistance)
    local lookX, lookZ = self:getRouteSample(math.min(self.totalDistance, self.travelledDistance + aheadDistance))
    if lookX == nil or lookZ == nil then
        return -0.6, 0
    end

    local lookY = self:getTerrainHeight(lookX, lookZ) + self.settings.lookTargetHeight
    local dirX = lookX - x
    local dirY = lookY - y
    local dirZ = lookZ - z

    local dirLength = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)
    if dirLength < 0.0001 then
        return -0.6, 0
    end

    dirX = dirX / dirLength
    dirY = dirY / dirLength
    dirZ = dirZ / dirLength

    return MathUtil.directionToPitchYaw(dirX, dirY, dirZ)
end

function MapPreloadFlyover:applyFlyoverState(player, x, y, z, pitch, yaw)
    local worldX, worldZ = self:mapToWorldPosition(x, z)
    player.mover:setPosition(worldX, y, worldZ, true)

    if player.camera ~= nil then
        player.camera:focusOnPosition(worldX, y, worldZ)
        player.camera:setRotation(pitch, yaw, 0)
    end
end

function MapPreloadFlyover:restorePlayerState()
    local player = self:getLocalPlayer()
    local savedState = self.savedState

    if player == nil or savedState == nil then
        return
    end

    if savedState.restorePosition then
        player.mover:teleportTo(savedState.x, savedState.y, savedState.z, true, true)

        if player.camera ~= nil then
            player.camera:focusOnPosition(savedState.x, savedState.y, savedState.z)
            player.camera:setRotation(savedState.pitch, savedState.yaw, savedState.roll)
        end
    end

    if player.inputComponent ~= nil and savedState.inputLocked ~= nil then
        player.inputComponent.locked = savedState.inputLocked
    end
end

function MapPreloadFlyover:clearRunState()
    self.isActive = false
    self.routePoints = {}
    self.routeSegments = {}
    self.settings = {}
    self.coverage = nil
    self.savedState = nil
    self.travelledDistance = 0
    self.totalDistance = 0
    self.terrainSize = 0
    self.mapMetrics = nil
    self.lastProgressStep = -1
    self.statusText = ""
    self.coverageAccumMs = 0
    self:removePathHotspots()
end

function MapPreloadFlyover:createPathHotspots()
    self.pathHotspots = {}

    if MapHotspot == nil then
        return
    end

    local mission = g_currentMission
    local ingameMap = mission ~= nil and mission.hud ~= nil and mission.hud.ingameMap or nil
    if ingameMap == nil or ingameMap.addMapHotspot == nil and ingameMap.addHotspot == nil then
        return
    end

    local addFn = ingameMap.addMapHotspot or ingameMap.addHotspot

    local stepDistance = math.max(60, self.settings.laneSpacing * 0.25)
    local steps = math.max(2, math.ceil(self.totalDistance / stepDistance))
    local category = MapHotspot.CATEGORY_DEFAULT or 1

    for i = 0, steps do
        local dist = (i / steps) * self.totalDistance
        local mapX, mapZ = self:getRouteSample(dist)
        if mapX ~= nil then
            local worldX, worldZ = self:mapToWorldPosition(mapX, mapZ)
            local ok, hotspot = pcall(function()
                local h = MapHotspot.new("flyoverPath_" .. i, category)
                if h.setWorldPosition ~= nil then
                    h:setWorldPosition(worldX, worldZ)
                end
                if h.setColor ~= nil then
                    h:setColor(1, 0.6, 0.1, 1)
                end
                if h.setScale ~= nil then
                    h:setScale(0.6, 0.6)
                end
                return h
            end)

            if ok and hotspot ~= nil then
                pcall(addFn, ingameMap, hotspot)
                table.insert(self.pathHotspots, hotspot)
            end
        end
    end

    self:log(string.format("Added %d path hotspots", #self.pathHotspots))
end

function MapPreloadFlyover:removePathHotspots()
    if self.pathHotspots == nil then
        return
    end

    local mission = g_currentMission
    local ingameMap = mission ~= nil and mission.hud ~= nil and mission.hud.ingameMap or nil
    local removeFn = ingameMap ~= nil and (ingameMap.removeMapHotspot or ingameMap.removeHotspot) or nil

    for _, h in ipairs(self.pathHotspots) do
        if removeFn ~= nil and ingameMap ~= nil then
            pcall(removeFn, ingameMap, h)
        end
        if h.delete ~= nil then
            pcall(h.delete, h)
        end
    end

    self.pathHotspots = {}
end

function MapPreloadFlyover:finishFlyover(reason, shouldRestore)
    local restoreState = shouldRestore
    if restoreState == nil then
        restoreState = self.savedState ~= nil and self.savedState.restorePosition or false
    end

    if restoreState then
        self:restorePlayerState()
    else
        local player = self:getLocalPlayer()
        if player ~= nil and player.inputComponent ~= nil and self.savedState ~= nil and self.savedState.inputLocked ~= nil then
            player.inputComponent.locked = self.savedState.inputLocked
        end
    end

    self:log(reason)
    self:clearRunState()
end

function MapPreloadFlyover:getDefaultSpacing(terrainSize)
    local metrics = self.mapMetrics or self:getMapMetrics(terrainSize)
    local sideFactor = metrics ~= nil and metrics.sideFactor or 1
    return clamp(math.floor(180 * sideFactor + 0.5), 180, 4096)
end

function MapPreloadFlyover:getDefaultHeight(terrainSize, spacing)
    local metrics = self.mapMetrics or self:getMapMetrics(terrainSize)
    local sideFactor = metrics ~= nil and metrics.sideFactor or 1
    return clamp(math.floor(math.max(spacing * 0.75, 140 * sideFactor) + 0.5), 140, 5000)
end

function MapPreloadFlyover:getDefaultSpeed(terrainSize, spacing)
    local metrics = self.mapMetrics or self:getMapMetrics(terrainSize)
    local sideFactor = metrics ~= nil and metrics.sideFactor or 1
    return clamp(math.floor(math.max(spacing * 1.65, 300 * sideFactor) + 0.5), 300, 9000)
end

function MapPreloadFlyover:startFlyover(spacingArg, heightArg, speedArg, restoreArg)
    if self.isActive then
        return string.format("%s is already running. Use %s to cancel it.", self.START_COMMAND, self.STOP_COMMAND)
    end

    local mission = g_currentMission
    if mission == nil then
        return "No active mission found"
    end

    local player = self:getLocalPlayer()
    if player == nil or player.camera == nil or player.mover == nil then
        return "No local player camera available"
    end

    if player.getCurrentVehicle ~= nil and player:getCurrentVehicle() ~= nil then
        return "Please leave the vehicle before starting the flyover"
    end

    local terrainSize = self:getTerrainSize()
    if terrainSize <= 0 then
        return "Could not determine the map size"
    end

    self.terrainSize = terrainSize
    self.mapMetrics = self:getMapMetrics(terrainSize)

    local spacing = tonumber(spacingArg) or self:getDefaultSpacing(terrainSize)
    spacing = clamp(spacing, 64, math.max(96, terrainSize))
    local laneSpacing = self:getLaneSpacing(spacing, terrainSize)

    local height = tonumber(heightArg) or self:getDefaultHeight(terrainSize, spacing)
    height = clamp(height, 60, 12000)

    local speed = tonumber(speedArg) or self:getDefaultSpeed(terrainSize, spacing)
    speed = clamp(speed, 40, 12000)

    local restorePosition = parseBoolean(restoreArg, true)

    local routePoints = self:buildRoute(laneSpacing)
    if #routePoints < 2 then
        return "Could not build a valid flyover route"
    end

    local routeSegments, totalDistance = self:buildSegments(routePoints)
    if totalDistance <= 0 then
        return "Generated route is too short"
    end

    local currentX, currentY, currentZ = player:getPosition()
    local pitch, yaw, roll = player.camera:getRotation()

    self.routePoints = routePoints
    self.routeSegments = routeSegments
    self.totalDistance = totalDistance
    self.travelledDistance = 0
    self.lastProgressStep = -1
    self.savedState = {
        x = currentX,
        y = currentY,
        z = currentZ,
        pitch = pitch,
        yaw = yaw,
        roll = roll,
        restorePosition = restorePosition,
        inputLocked = player.inputComponent ~= nil and player.inputComponent.locked or false
    }

    self.settings = {
        spacing = spacing,
        laneSpacing = laneSpacing,
        height = height,
        speed = speed,
        lookAhead = math.max(120, spacing * 1.1),
        lookTargetHeight = 2,
        estimatedTime = totalDistance / speed
    }

    self.coverage = self:createCoverageData(terrainSize, laneSpacing, height)
    self:buildPlannedCoverage(self.coverage)

    if player.inputComponent ~= nil then
        player.inputComponent.locked = true
    end

    if player.camera.makeCurrent ~= nil then
        player.camera:makeCurrent()
    end

    self.isActive = true
    self.statusText = "Running"

    self:createPathHotspots()

    local startX, startZ = self:getRouteSample(0)
    local startY = self:getTerrainHeight(startX, startZ) + self.settings.height
    local startPitch, startYaw = self:getLookRotation(startX, startY, startZ, self.settings.lookAhead)
    self:applyFlyoverState(player, startX, startY, startZ, startPitch, startYaw)
    self:updateVisitedCoverage(startX, startZ)

    local startWorldX, startWorldZ = self:mapToWorldPosition(startX, startZ)
    local minWorldX, maxWorldX, minWorldZ, maxWorldZ = self:getTerrainWorldBounds()

    self:log(string.format(
        "Starting map preload flyover | map=%sx | terrain=%.0fm | heightmap=%.0f | density=%.0f | size=%.1fkm | spacing=%sm lane=%sm height=%sm speed=%sm/s restore=%s route=%.0fm ETA=%s",
        self.mapMetrics.mapFactor,
        self.mapMetrics.terrainSize,
        self.mapMetrics.heightmapSize,
        self.mapMetrics.densityMapSize,
        self.mapMetrics.kilometerSize,
        formatMeters(spacing),
        formatMeters(laneSpacing),
        formatMeters(height),
        formatMeters(speed),
        tostring(restorePosition),
        totalDistance,
        formatSeconds(self.settings.estimatedTime)
    ))
    self:log(string.format(
        "Debug bounds | mapMin=(0,0) mapMax=(%.0f,%.0f) worldMin=(%.1f,%.1f) worldMax=(%.1f,%.1f)",
        terrainSize,
        terrainSize,
        minWorldX,
        minWorldZ,
        maxWorldX,
        maxWorldZ
    ))
    self:log(string.format(
        "Debug route start | mapStart=(%.1f,%.1f) worldStart=(%.1f,%.1f) points=%d segments=%d",
        startX,
        startZ,
        startWorldX,
        startWorldZ,
        #routePoints,
        #routeSegments
    ))

    return string.format("Started flyover over %.0fm route. ETA %s.", totalDistance, formatSeconds(self.settings.estimatedTime))
end

function MapPreloadFlyover:stopFlyover()
    if not self.isActive then
        return "No flyover is currently running"
    end

    self:finishFlyover("Flyover cancelled", nil)
    return "Flyover stopped"
end

function MapPreloadFlyover:loadMap()
    addConsoleCommand(
        self.START_COMMAND,
        "Start automatic map preload flyover: preloadMapShaders [spacing] [height] [speed] [restore]",
        "startFlyover",
        self,
        "[spacing]; [height]; [speed]; [restore]"
    )
    addConsoleCommand(
        self.STOP_COMMAND,
        "Stop the active map preload flyover",
        "stopFlyover",
        self
    )

    self:log(string.format("Loaded. Use %s to start the flyover.", self.START_COMMAND))
end

function MapPreloadFlyover:deleteMap()
    removeConsoleCommand(self.START_COMMAND)
    removeConsoleCommand(self.STOP_COMMAND)

    if self.isActive then
        self:finishFlyover("Map unloaded while flyover was active", false)
    else
        self:clearRunState()
    end
end

function MapPreloadFlyover:update(dt)
    if not self.isActive then
        return
    end

    local player = self:getLocalPlayer()
    if player == nil or player.camera == nil or player.mover == nil then
        self:finishFlyover("Flyover stopped because the local player is no longer available", false)
        return
    end

    local travelDelta = self.settings.speed * (dt * 0.001)
    self.travelledDistance = clamp(self.travelledDistance + travelDelta, 0, self.totalDistance)

    local x, z = self:getRouteSample(self.travelledDistance)
    if x == nil or z == nil then
        self:finishFlyover("Flyover stopped because the route sampling failed", nil)
        return
    end

    local terrainY = self:getTerrainHeight(x, z)
    local y = terrainY + self.settings.height
    local pitch, yaw = self:getLookRotation(x, y, z, self.settings.lookAhead)

    self:applyFlyoverState(player, x, y, z, pitch, yaw)

    self.coverageAccumMs = (self.coverageAccumMs or 0) + dt
    if self.coverageAccumMs >= 150 then
        self.coverageAccumMs = 0
        self:updateVisitedCoverage(x, z)
    end

    local progress = 0
    if self.totalDistance > 0 then
        progress = self.travelledDistance / self.totalDistance
    end

    local progressStep = math.floor(progress * 10)
    if progressStep > self.lastProgressStep then
        self.lastProgressStep = progressStep
        local worldX, worldZ = self:mapToWorldPosition(x, z)
        self:log(string.format(
            "Flyover progress: %.0f%% | map=(%.1f,%.1f) world=(%.1f,%.1f)",
            clamp(progress * 100, 0, 100),
            x,
            z,
            worldX,
            worldZ
        ))
    end

    local remainingDistance = math.max(0, self.totalDistance - self.travelledDistance)
    local remainingTime = remainingDistance / self.settings.speed
    local coveragePercent = self:getCoveragePercent()
    self.statusText = string.format(
        "Progress %.0f%% | Coverage %.0f%% | %sm / %sm | ETA %s",
        clamp(progress * 100, 0, 100),
        clamp(coveragePercent, 0, 100),
        formatMeters(self.travelledDistance),
        formatMeters(self.totalDistance),
        formatSeconds(remainingTime)
    )

    if self.travelledDistance >= self.totalDistance - 0.001 then
        self:finishFlyover("Flyover completed successfully", nil)
    end
end

function MapPreloadFlyover:draw()
    if not self.isActive or not self.drawOverlay then
        return
    end

    local baseX = 0.02
    local baseY = 0.955
    local lineHeight = 0.022
    local textSize = 0.018
    local coverage = self.coverage

    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    renderText(baseX, baseY, textSize, "Map Preload Flyover")
    setTextBold(false)
    renderText(baseX, baseY - lineHeight, textSize, self.statusText)
    if self.mapMetrics ~= nil then
        renderText(
            baseX,
            baseY - lineHeight * 2,
            textSize,
            string.format("Map %sx | %.1f km | terrain %.0f", self.mapMetrics.mapFactor, self.mapMetrics.kilometerSize, self.mapMetrics.terrainSize)
        )
        renderText(baseX, baseY - lineHeight * 3, textSize, string.format("Stop: %s", self.STOP_COMMAND))
    else
        renderText(baseX, baseY - lineHeight * 2, textSize, string.format("Stop: %s", self.STOP_COMMAND))
    end

    if coverage ~= nil then
        local panelSize = 0.22
        local panelX = 0.5 - panelSize * 0.5
        local panelY = 0.5 - panelSize * 0.5
        local border = 0.004
        local cellSize = panelSize / coverage.resolution
        local coveragePercent = self:getCoveragePercent()

        drawFilledRect(panelX - border, panelY - border, panelSize + border * 2, panelSize + border * 2, 0, 0, 0, 0.75)

        for cellZ = 1, coverage.resolution do
            for cellX = 1, coverage.resolution do
                local index = self:getCoverageIndex(coverage, cellX, cellZ)
                local r, g, b, a = 0.08, 0.08, 0.08, 0.85

                if coverage.planned[index] then
                    r, g, b, a = 0.72, 0.32, 0.10, 0.9
                end

                if coverage.visited[index] then
                    r, g, b, a = 0.12, 0.74, 0.24, 0.95
                end

                if coverage.currentIndex == index then
                    r, g, b, a = 1, 1, 1, 1
                end

                local drawX = panelX + (cellX - 1) * cellSize
                local drawY = panelY + panelSize - cellZ * cellSize
                drawFilledRect(drawX, drawY, cellSize, cellSize, r, g, b, a)
            end
        end

        setTextColor(1, 1, 1, 1)
        setTextBold(true)
        renderText(panelX, panelY + panelSize + 0.01, 0.015, "Coverage Map")
        setTextBold(false)
        renderText(panelX, panelY - 0.02, 0.014, string.format("Covered %.0f%%", clamp(coveragePercent, 0, 100)))
    end
end

addModEventListener(MapPreloadFlyover)
