local mapProcessor = {}

-- imports

local pheromoneUtils = require("PheromoneUtils")
local aiBuilding = require("AIBuilding")
local aiPredicates = require("AIPredicates")
local constants = require("Constants")
local mapUtils = require("MapUtils")
local playerUtils = require("PlayerUtils")

-- constants

local PROCESS_QUEUE_SIZE = constants.PROCESS_QUEUE_SIZE

local RETREAT_MOVEMENT_PHEROMONE_LEVEL = constants.RETREAT_MOVEMENT_PHEROMONE_LEVEL

local SCAN_QUEUE_SIZE = constants.SCAN_QUEUE_SIZE

local AI_UNIT_REFUND = constants.AI_UNIT_REFUND
local CHUNK_SIZE = constants.CHUNK_SIZE

local PROCESS_PLAYER_BOUND = constants.PROCESS_PLAYER_BOUND
local CHUNK_TICK = constants.CHUNK_TICK

local NEST_BASE = constants.NEST_BASE

local AI_MAX_POINTS = constants.AI_MAX_POINTS
local AI_SQUAD_COST = constants.AI_SQUAD_COST
local AI_VENGENCE_SQUAD_COST = constants.AI_VENGENCE_SQUAD_COST

local MOVEMENT_PHEROMONE = constants.MOVEMENT_PHEROMONE
local PLAYER_BASE_GENERATOR = constants.PLAYER_BASE_GENERATOR
local BUILDING_PHEROMONES = constants.BUILDING_PHEROMONES

-- imported functions

local scents = pheromoneUtils.scents
local processPheromone = pheromoneUtils.processPheromone

local formSquads = aiBuilding.formSquads

local getChunkByIndex = mapUtils.getChunkByIndex
local getChunkByPosition = mapUtils.getChunkByPosition

local playerScent = pheromoneUtils.playerScent

local canAttack = aiPredicates.canAttack

local mMin = math.min

local validPlayer = playerUtils.validPlayer

-- module code

local function nonRepeatingRandom(players)
    local ordering = {}
    for _,player in pairs(players) do
	ordering[#ordering+1] = player.index
    end
    for i=#ordering,1,-1 do
	local s = math.random(i)
	local t = ordering[i]
	ordering[i] = ordering[s]
	ordering[s] = t
    end
    return ordering
end

--[[
    processing is not consistant as it depends on the number of chunks that have been generated
    so if we process 400 chunks an iteration and 200 chunks have been generated than these are
    processed 3 times a second and 1200 generated chunks would be processed once a second
    In theory, this might be fine as smaller bases have less surface to attack and need to have 
    pheromone dissipate at a faster rate.
--]]
function mapProcessor.processMap(regionMap, surface, natives, evolution_factor)
    local roll = regionMap.processRoll
    local index = regionMap.processPointer
    
    if (index == 1) then
        roll = math.random()
        regionMap.processRoll = roll
    end
    
    local squads = canAttack(natives, surface) and (0.11 <= roll) and (roll <= 0.35)
    
    local processQueue = regionMap.processQueue
    local endIndex = mMin(index + PROCESS_QUEUE_SIZE, #processQueue)
    for x=index,endIndex do
        local chunk = processQueue[x]
	
	processPheromone(regionMap, chunk)

        if squads then
            formSquads(regionMap, surface, natives, chunk, evolution_factor, AI_SQUAD_COST)
        end        
	
        scents(chunk)
    end
    
    if (endIndex == #processQueue) then
        regionMap.processPointer = 1
    else
        regionMap.processPointer = endIndex + 1
    end
end

--[[
    Localized player radius were processing takes place in realtime, doesn't store state
    between calls.
    vs 
    the slower passive version processing the entire map in multiple passes.
--]]
function mapProcessor.processPlayers(players, regionMap, surface, natives, evolution_factor, tick)
    -- put down player pheromone for player hunters
    -- randomize player order to ensure a single player isn't singled out
    local playerOrdering = nonRepeatingRandom(players)

    local vengenceThreshold = -(evolution_factor * RETREAT_MOVEMENT_PHEROMONE_LEVEL)
    local roll = math.random() 

    local squads = canAttack(natives, surface) and (0.11 <= roll) and (roll <= 0.20)
    
    for i=1,#playerOrdering do
	local player = players[playerOrdering[i]]
	if validPlayer(player) then 
	    local playerPosition = player.character.position
	    local playerChunk = getChunkByPosition(regionMap, playerPosition.x, playerPosition.y)
	    
	    if (playerChunk ~= nil) then
		playerScent(playerChunk)
	    end
	end
    end
    for i=1,#playerOrdering do
	local player = players[playerOrdering[i]]
	if validPlayer(player) then 
	    local playerPosition = player.character.position
	    local playerChunk = getChunkByPosition(regionMap, playerPosition.x, playerPosition.y)
	    
	    if (playerChunk ~= nil) then
		local vengence = canAttack(natives, surface) and ((#playerChunk[NEST_BASE] ~= 0) or (playerChunk[MOVEMENT_PHEROMONE] < vengenceThreshold))
		
		for x=playerChunk.cX - PROCESS_PLAYER_BOUND, playerChunk.cX + PROCESS_PLAYER_BOUND do
		    for y=playerChunk.cY - PROCESS_PLAYER_BOUND, playerChunk.cY + PROCESS_PLAYER_BOUND do
			local chunk = getChunkByIndex(regionMap, x, y)
			
			if (chunk ~= nil) and (chunk[CHUNK_TICK] ~= tick) then
			    chunk[CHUNK_TICK] = tick

			    processPheromone(regionMap, chunk)
			    
			    if squads then
				formSquads(regionMap, surface, natives, chunk, evolution_factor, AI_SQUAD_COST)
			    end
			    if vengence then
				formSquads(regionMap, surface, natives, chunk, evolution_factor, AI_VENGENCE_SQUAD_COST)
			    end

			    scents(chunk)

			end
		    end
		end
	    end
	end
    end
end

--[[
    Passive scan to find entities that have been generated outside the factorio event system
--]]
function mapProcessor.scanMap(regionMap, surface, natives, evolution_factor)
    -- local index = regionMap.scanPointer
    
    -- local processQueue = regionMap.processQueue
    -- local endIndex = mMin(index + SCAN_QUEUE_SIZE, #processQueue)
    -- for x=index,endIndex do
    -- 	local chunk = processQueue[x]

    -- 	local entities = surface.find_entities_filtered({area = {{chunk.pX, chunk.pY},
    -- 							     {chunk.pX + CHUNK_SIZE, chunk.pY + CHUNK_SIZE}},
    -- 							 force = "player"})
	
    -- 	local spawners = surface.count_entities_filtered({area = {{chunk.pX, chunk.pY},
    -- 							      {chunk.pX + CHUNK_SIZE, chunk.pY + CHUNK_SIZE}},
    -- 							  type = "unit-spawner",
    -- 							  force = "enemy"})

    -- 	local worms = surface.count_entities_filtered({area = {{chunk.pX, chunk.pY},
    -- 							   {chunk.pX + CHUNK_SIZE, chunk.pY + CHUNK_SIZE}},
    -- 						       type = "turret",
    -- 						       force = "enemy"})
	
    -- 	local unitCount = surface.count_entities_filtered({area = {{chunk.pX, chunk.pY},
    -- 							       {chunk.pX + CHUNK_SIZE, chunk.pY + CHUNK_SIZE}},
    -- 							   type = "unit",
    -- 							   force = "enemy"})

    -- 	if (unitCount > 550) then
    -- 	    local weight = AI_UNIT_REFUND * evolution_factor
    -- 	    local units = surface.find_enemy_units({chunk.pX, chunk.pY},
    -- 		CHUNK_SIZE * 3)

    -- 	    for i=1,#units do
    -- 		units[i].destroy()
    -- 		natives.points = natives.points + weight
    -- 	    end

    -- 	    if (natives.points > (AI_MAX_POINTS * 3)) then
    -- 		natives.points = (AI_MAX_POINTS * 3)
    -- 	    end
    -- 	end

    -- 	local playerBaseGenerator = 0
    -- 	for i=1,#entities do
    -- 	    local entity = entities[i]
    -- 	    local value = BUILDING_PHEROMONES[entity.type]
    -- 	    if (value ~= nil) then
    -- 		playerBaseGenerator = playerBaseGenerator + value
    -- 	    end
    -- 	end

    -- 	--chunk[ENEMY_BASE_GENERATOR] = (spawners * ENEMY_BASE_PHEROMONE_GENERATOR_AMOUNT) + worms
    -- 	chunk[PLAYER_BASE_GENERATOR] = playerBaseGenerator
    -- end

    -- if (endIndex == #processQueue) then
    -- 	regionMap.scanPointer = 1
    -- else
    -- 	regionMap.scanPointer = endIndex + 1
    -- end
end

return mapProcessor
