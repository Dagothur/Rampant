if mapProcessorG then
    return mapProcessorG
end
local mapProcessor = {}

-- imports

local pheromoneUtils = require("PheromoneUtils")
local aiAttackWave = require("AIAttackWave")
local aiPredicates = require("AIPredicates")
local constants = require("Constants")
local mapUtils = require("MapUtils")
local playerUtils = require("PlayerUtils")
local chunkUtils = require("ChunkUtils")
local chunkPropertyUtils = require("ChunkPropertyUtils")
local baseUtils = require("BaseUtils")

-- constants

local DURATION_ACTIVE_NEST_DIVIDER = constants.DURATION_ACTIVE_NEST_DIVIDER
local DURATION_ACTIVE_NEST = constants.DURATION_ACTIVE_NEST

local PROCESS_QUEUE_SIZE = constants.PROCESS_QUEUE_SIZE
local RESOURCE_QUEUE_SIZE = constants.RESOURCE_QUEUE_SIZE
local ENEMY_QUEUE_SIZE = constants.ENEMY_QUEUE_SIZE
local PLAYER_QUEUE_SIZE = constants.PLAYER_QUEUE_SIZE

local CLEANUP_QUEUE_SIZE = constants.CLEANUP_QUEUE_SIZE

local CHUNK_SIZE = constants.CHUNK_SIZE

local PROCESS_PLAYER_BOUND = constants.PROCESS_PLAYER_BOUND
local CHUNK_TICK = constants.CHUNK_TICK

local PROCESS_STATIC_QUEUE_SIZE = constants.PROCESS_STATIC_QUEUE_SIZE

local AI_VENGENCE_SQUAD_COST = constants.AI_VENGENCE_SQUAD_COST
local AI_STATE_AGGRESSIVE = constants.AI_STATE_AGGRESSIVE

local AI_STATE_PEACEFUL = constants.AI_STATE_PEACEFUL
local AI_STATE_MIGRATING = constants.AI_STATE_MIGRATING
local AI_STATE_SIEGE = constants.AI_STATE_SIEGE

local COOLDOWN_RALLY = constants.COOLDOWN_RALLY
local COOLDOWN_RETREAT = constants.COOLDOWN_RETREAT

local BASE_PROCESS_INTERVAL = constants.BASE_PROCESS_INTERVAL

-- imported functions

local processStaticPheromone = pheromoneUtils.processStaticPheromone
local processPheromone = pheromoneUtils.processPheromone

local getDeathGenerator = chunkPropertyUtils.getDeathGenerator
local processBase = baseUtils.processBase

local processNestActiveness = chunkPropertyUtils.processNestActiveness
local getChunkBase = chunkPropertyUtils.getChunkBase

local formSquads = aiAttackWave.formSquads
local formVengenceSquad = aiAttackWave.formVengenceSquad
local formSettlers = aiAttackWave.formSettlers

local getChunkByPosition = mapUtils.getChunkByPosition
local getChunkByXY = mapUtils.getChunkByXY

local validPlayer = playerUtils.validPlayer

local addPlayerToChunk = chunkPropertyUtils.addPlayerToChunk

local mapScanEnemyChunk = chunkUtils.mapScanEnemyChunk
local mapScanPlayerChunk = chunkUtils.mapScanPlayerChunk
local mapScanResourceChunk = chunkUtils.mapScanResourceChunk

local getNestCount = chunkPropertyUtils.getNestCount
local getEnemyStructureCount = chunkPropertyUtils.getEnemyStructureCount
local getNestActiveness = chunkPropertyUtils.getNestActiveness
local getNestActiveTick = chunkPropertyUtils.getNestActiveTick
local setNestActiveTick = chunkPropertyUtils.setNestActiveTick

local getRaidNestActiveness = chunkPropertyUtils.getRaidNestActiveness

local canAttack = aiPredicates.canAttack
local canMigrate = aiPredicates.canMigrate

local tableSize = table_size

local mMin = math.min
local mMax = math.max

local next = next
local mRandom = math.random

-- module code

--[[
    processing is not consistant as it depends on the number of chunks that have been generated
    so if we process 400 chunks an iteration and 200 chunks have been generated than these are
    processed 3 times a second and 1200 generated chunks would be processed once a second
    In theory, this might be fine as smaller bases have less surface to attack and need to have
    pheromone dissipate at a faster rate.
--]]
function mapProcessor.processMap(map, tick)
    local index = map.processIndex

    local outgoingWave = map.outgoingScanWave
    local processQueue = map.processQueue
    local processQueueLength = #processQueue

    local step
    local endIndex
    if outgoingWave then
        step = 1
        endIndex = mMin(index + PROCESS_QUEUE_SIZE, processQueueLength)
    else
        step = -1
        endIndex = mMax(index - PROCESS_QUEUE_SIZE, 1)
    end

    if (processQueueLength == 0) then
        return
    end

    for x=index,endIndex,step do
        local chunk = processQueue[x]
        if chunk[CHUNK_TICK] ~= tick then
            chunk[CHUNK_TICK] = tick
            processPheromone(map, chunk)
        end
    end

    if (endIndex == processQueueLength) then
        map.outgoingScanWave = false
    elseif (endIndex == 1) then
        map.outgoingScanWave = true
    elseif outgoingWave then
        map.processIndex = endIndex + 1
    else
        map.processIndex = endIndex - 1
    end
    map.universe.processedChunks = map.universe.processedChunks + PROCESS_QUEUE_SIZE
end

function mapProcessor.processStaticMap(map)
    local index = map.processStaticIndex

    local outgoingWave = map.outgoingStaticScanWave
    local processQueue = map.processQueue
    local processQueueLength = #processQueue

    local step
    local endIndex
    if outgoingWave then
        step = 1
        endIndex = mMin(index + PROCESS_STATIC_QUEUE_SIZE, processQueueLength)
    else
        step = -1
        endIndex = mMax(index - PROCESS_STATIC_QUEUE_SIZE, 1)
    end

    if (processQueueLength == 0) then
        return
    end

    for x=index,endIndex,step do
        local chunk = processQueue[x]
        processStaticPheromone(map, chunk)
    end

    if (endIndex == processQueueLength) then
        map.outgoingStaticScanWave = false
    elseif (endIndex == 1) then
        map.outgoingStaticScanWave = true
    elseif outgoingWave then
        map.processStaticIndex = endIndex + 1
    else
        map.processStaticIndex = endIndex - 1
    end
end

local function queueNestSpawners(map, chunk, tick)
    local limitPerActiveChunkTick =
        (map.activeNests + map.activeRaidNests) * DURATION_ACTIVE_NEST_DIVIDER

    local processActiveNest = map.processActiveNest

    if ((getNestActiveness(map, chunk) > 0) or (getRaidNestActiveness(map, chunk) > 0)) and
        (getNestActiveTick(map, chunk) == 0)
    then
        local nextTick = tick + DURATION_ACTIVE_NEST
        local slot = processActiveNest[nextTick]
        if not slot then
            slot = {}
            processActiveNest[nextTick] = slot
            slot[#slot+1] = chunk
        else
            if (#slot > limitPerActiveChunkTick) then
                while (#slot > limitPerActiveChunkTick) do
                    nextTick = nextTick + 1
                    slot = processActiveNest[nextTick]
                    if not slot then
                        slot = {}
                        processActiveNest[nextTick] = slot
                        slot[#slot+1] = chunk
                        break
                    elseif (#slot < limitPerActiveChunkTick) then
                        slot[#slot+1] = chunk
                        break
                    end
                end
            else
                slot[#slot+1] = chunk
            end
        end
        setNestActiveTick(map, chunk, tick)
    end
end

--[[
    Localized player radius were processing takes place in realtime, doesn't store state
    between calls.
    vs
    the slower passive version processing the entire map in multiple passes.
--]]
function mapProcessor.processPlayers(players, map, tick)
    -- put down player pheromone for player hunters
    -- randomize player order to ensure a single player isn't singled out
    local allowingAttacks = canAttack(map)
    local universe = map.universe

    -- not looping everyone because the cost is high enough already in multiplayer
    if (#players > 0) then
        local player = players[mRandom(#players)]
        if validPlayer(player) then
            local playerChunk = getChunkByPosition(map, player.character.position)

            if (playerChunk ~= -1) then
                local vengence = allowingAttacks and
                    (map.points >= AI_VENGENCE_SQUAD_COST) and
                    ((getEnemyStructureCount(map, playerChunk) > 0) or
                        (-getDeathGenerator(map, playerChunk) < -universe.retreatThreshold))

                for x=playerChunk.x - PROCESS_PLAYER_BOUND, playerChunk.x + PROCESS_PLAYER_BOUND, 32 do
                    for y=playerChunk.y - PROCESS_PLAYER_BOUND, playerChunk.y + PROCESS_PLAYER_BOUND, 32 do
                        local chunk = getChunkByXY(map, x, y)

                        if (chunk ~= -1) and (chunk[CHUNK_TICK] ~= tick) then
                            chunk[CHUNK_TICK] = tick
                            processPheromone(map, chunk, true)

                            if (getNestCount(map, chunk) > 0) then
                                processNestActiveness(map, chunk)
                                queueNestSpawners(map, chunk, tick)

                                if vengence then
                                    map.vengenceQueue[chunk] = (map.vengenceQueue[chunk] or 0) + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    for i=1,#players do
        local player = players[i]
        if validPlayer(player) then
            local playerChunk = getChunkByPosition(map, player.character.position)

            if (playerChunk ~= -1) then
                addPlayerToChunk(map, playerChunk, player.name)
            end
        end
    end
end

function mapProcessor.cleanUpMapTables(map, tick)
    local index = map.cleanupIndex

    local retreats = map.chunkToRetreats
    local rallys = map.chunkToRallys
    local drained = map.chunkToDrained
    local processQueue = map.processQueue
    local processQueueLength = #processQueue

    local endIndex = mMin(index + CLEANUP_QUEUE_SIZE, processQueueLength)

    if (processQueueLength == 0) then
        return
    end

    for x=index,endIndex do
        local chunk = processQueue[x]

        local retreatTick = retreats[chunk]
        if retreatTick and ((tick - retreatTick) > COOLDOWN_RETREAT) then
            retreats[chunk] = nil
        end

        local rallyTick = rallys[chunk]
        if rallyTick and ((tick - rallyTick) > COOLDOWN_RALLY) then
            rallys[chunk] = nil
        end

        local drainTick = drained[chunk]
        if drainTick and ((tick - drainTick) > 0) then
            drained[chunk] = nil
        end
    end

    if (endIndex == processQueueLength) then
        map.cleanupIndex = 1
    else
        map.cleanupIndex = endIndex + 1
    end
end

--[[
    Passive scan to find entities that have been generated outside the factorio event system
--]]
function mapProcessor.scanPlayerMap(map, tick)
    if (map.nextProcessMap == tick) or (map.nextPlayerScan == tick) or
        (map.nextEnemyScan == tick) or (map.nextChunkProcess == tick)
    then
        return
    end
    local index = map.scanPlayerIndex

    local area = map.universe.area
    local offset = area[2]
    local chunkBox = area[1]
    local processQueue = map.processQueue
    local processQueueLength = #processQueue

    local endIndex = mMin(index + PLAYER_QUEUE_SIZE, processQueueLength)

    if (processQueueLength == 0) then
        return
    end

    for x=index,endIndex do
        local chunk = processQueue[x]

        chunkBox[1] = chunk.x
        chunkBox[2] = chunk.y

        offset[1] = chunk.x + CHUNK_SIZE
        offset[2] = chunk.y + CHUNK_SIZE

        mapScanPlayerChunk(chunk, map)
    end

    if (endIndex == processQueueLength) then
        map.scanPlayerIndex = 1
    else
        map.scanPlayerIndex = endIndex + 1
    end
end

function mapProcessor.scanEnemyMap(map, tick)
    if (map.nextProcessMap == tick) or (map.nextPlayerScan == tick) or (map.nextChunkProcess == tick) then
        return
    end

    local index = map.scanEnemyIndex

    local area = map.universe.area
    local offset = area[2]
    local chunkBox = area[1]
    local processQueue = map.processQueue
    local processQueueLength = #processQueue

    local endIndex = mMin(index + ENEMY_QUEUE_SIZE, #processQueue)

    if (processQueueLength == 0) then
        return
    end

    for x=index,endIndex do
        local chunk = processQueue[x]

        chunkBox[1] = chunk.x
        chunkBox[2] = chunk.y

        offset[1] = chunk.x + CHUNK_SIZE
        offset[2] = chunk.y + CHUNK_SIZE

        mapScanEnemyChunk(chunk, map, tick)
    end

    if (endIndex == processQueueLength) then
        map.scanEnemyIndex = 1
    else
        map.scanEnemyIndex = endIndex + 1
    end
end

function mapProcessor.scanResourceMap(map, tick)
    if (map.nextProcessMap == tick) or (map.nextPlayerScan == tick) or
        (map.nextEnemyScan == tick) or (map.nextChunkProcess == tick)
    then
        return
    end
    local index = map.scanResourceIndex

    local area = map.universe.area
    local offset = area[2]
    local chunkBox = area[1]
    local processQueue = map.processQueue
    local processQueueLength = #processQueue

    local endIndex = mMin(index + RESOURCE_QUEUE_SIZE, processQueueLength)

    if (processQueueLength == 0) then
        return
    end

    for x=index,endIndex do
        local chunk = processQueue[x]

        chunkBox[1] = chunk.x
        chunkBox[2] = chunk.y

        offset[1] = chunk.x + CHUNK_SIZE
        offset[2] = chunk.y + CHUNK_SIZE

        mapScanResourceChunk(chunk, map)
    end

    if (endIndex == processQueueLength) then
        map.scanResourceIndex = 1
    else
        map.scanResourceIndex = endIndex + 1
    end
end

function mapProcessor.processActiveNests(map, tick)
    local processActiveNest = map.processActiveNest
    local slot = processActiveNest[tick]
    if slot then
        for i=1,#slot do
            local chunk = slot[i]
            if (getNestActiveness(map, chunk) > 0) or (getRaidNestActiveness(map, chunk) > 0) then
                processNestActiveness(map, chunk)
                local nextTick = tick + DURATION_ACTIVE_NEST
                local nextSlot = processActiveNest[nextTick]
                if not nextSlot then
                    nextSlot = {}
                    processActiveNest[nextTick] = nextSlot
                end
                nextSlot[#nextSlot+1] = chunk
            else
                setNestActiveTick(map, chunk, 0)
            end
        end
        processActiveNest[tick] = nil
    end
end

function mapProcessor.processVengence(map)
    local ss = map.vengenceQueue
    local chunk = map.deployVengenceIterator
    if not chunk then
        chunk = next(ss, nil)
    end
    if not chunk then
        map.deployVengenceIterator = nil
        if (tableSize(ss) == 0) then
            map.vengenceQueue = {}
        end
    else
        map.deployVengenceIterator = next(ss, chunk)
        formVengenceSquad(map, chunk)
        ss[chunk] = nil
    end
end

function mapProcessor.processNests(map, tick)
    local chunk = next(map.chunkToNests, map.processNestIterator)
    map.processNestIterator = chunk
    if chunk then
        processNestActiveness(map, chunk)
        queueNestSpawners(map, chunk, tick)

        if map.universe.NEW_ENEMIES then
            local base = getChunkBase(map, chunk)
            if base and ((tick - base.tick) > BASE_PROCESS_INTERVAL) then
                processBase(chunk, map, tick, base)
            end
        end
    end
end

local function processSpawners(map, iterator, chunks)
    local chunk = next(chunks, map[iterator])
    map[iterator] = chunk
    if chunk then
        local migrate = canMigrate(map)
        local attack = canAttack(map)
        if migrate then
            formSettlers(map, chunk)
        elseif attack then
            formSquads(map, chunk)
        end
    end
end

function mapProcessor.processSpawners(map)

    if (map.state ~= AI_STATE_PEACEFUL) then
        if (map.state == AI_STATE_MIGRATING) then
            processSpawners(map,
                            "processMigrationIterator",
                            map.chunkToNests)
        elseif (map.state == AI_STATE_AGGRESSIVE) then
            processSpawners(map,
                            "processActiveSpawnerIterator",
                            map.chunkToActiveNest)
        elseif (map.state == AI_STATE_SIEGE) then
            processSpawners(map,
                            "processActiveSpawnerIterator",
                            map.chunkToActiveNest)
            processSpawners(map,
                            "processActiveRaidSpawnerIterator",
                            map.chunkToActiveRaidNest)
            processSpawners(map,
                            "processMigrationIterator",
                            map.chunkToNests)
        else
            processSpawners(map,
                            "processActiveSpawnerIterator",
                            map.chunkToActiveNest)
            processSpawners(map,
                            "processActiveRaidSpawnerIterator",
                            map.chunkToActiveRaidNest)
        end
    end
end

mapProcessorG = mapProcessor
return mapProcessor
