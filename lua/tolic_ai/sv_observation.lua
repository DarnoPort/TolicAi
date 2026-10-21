if not SERVER then return end

TolicAI = TolicAI or {}
TolicAI.Observation = TolicAI.Observation or {}

local Observation = TolicAI.Observation
local SCAN_RADIUS = 1000
local MAX_NEARBY_ACTORS = 8

local function roundTenth(value)
    if value >= 0 then
        return math.floor(value * 10 + 0.5) / 10
    end
    return math.ceil(value * 10 - 0.5) / 10
end

local function positionToTable(position)
    return {
        x = roundTenth(position.x),
        y = roundTenth(position.y),
        z = roundTenth(position.z)
    }
end

local function actorKind(entity)
    if entity:IsPlayer() then return "player" end
    if entity:IsNPC() then return "npc" end
    if entity:IsNextBot() then return "nextbot" end
    return nil
end

local function addHealthFacts(target, entity)
    local health = entity:Health()
    target.health = health

    local maximum = entity:GetMaxHealth()
    if isnumber(maximum) and maximum > 0 then
        target.max_health = maximum
        target.health_fraction = math.Clamp(health / maximum, 0, 1)
    end
end

function Observation.Collect(npc)
    if not IsValid(npc) then
        return nil, "The active NPC is not valid."
    end

    local position = npc:GetPos()
    local npcFacts = {
        class = npc:GetClass(),
        position = positionToTable(position)
    }
    addHealthFacts(npcFacts, npc)

    local observation = {
        npc = npcFacts,
        player = { present = false },
        environment = {
            map = game.GetMap(),
            actor_scan_radius = SCAN_RADIUS,
            nearby_actor_limit = MAX_NEARBY_ACTORS,
            nearby_actor_count = 0,
            nearby_actors = {},
            nearby_actors_truncated = false,
            navmesh_loaded = navmesh.IsLoaded(),
            navmesh_area_count = navmesh.GetNavAreaCount()
        }
    }

    local nearestPlayer
    local nearestPlayerDistance
    for _, candidate in ipairs(player.GetAll()) do
        if IsValid(candidate) then
            local distance = position:Distance(candidate:GetPos())
            if not nearestPlayerDistance or distance < nearestPlayerDistance then
                nearestPlayer = candidate
                nearestPlayerDistance = distance
            end
        end
    end

    if IsValid(nearestPlayer) then
        local playerFacts = {
            present = true,
            alive = nearestPlayer:Alive(),
            distance_to_player = roundTenth(nearestPlayerDistance),
            position = positionToTable(nearestPlayer:GetPos())
        }
        addHealthFacts(playerFacts, nearestPlayer)
        observation.player = playerFacts
    end

    local actors = {}
    for _, candidate in ipairs(ents.FindInSphere(position, SCAN_RADIUS)) do
        if IsValid(candidate) and candidate ~= npc then
            local kind = actorKind(candidate)
            if kind then
                local actorPosition = candidate:GetPos()
                local actorFacts = {
                    kind = kind,
                    class = candidate:GetClass(),
                    distance = roundTenth(position:Distance(actorPosition)),
                    position = positionToTable(actorPosition)
                }
                addHealthFacts(actorFacts, candidate)
                if candidate:IsPlayer() then
                    actorFacts.alive = candidate:Alive()
                end
                actors[#actors + 1] = actorFacts
            end
        end
    end

    table.sort(actors, function(left, right)
        if left.distance == right.distance then
            return left.class < right.class
        end
        return left.distance < right.distance
    end)

    observation.environment.nearby_actor_count = #actors
    observation.environment.nearby_actors_truncated = #actors > MAX_NEARBY_ACTORS
    for index = 1, math.min(#actors, MAX_NEARBY_ACTORS) do
        observation.environment.nearby_actors[index] = actors[index]
    end

    return observation
end

local function mayRun(playerEntity)
    if not IsValid(playerEntity) then return true end
    return playerEntity:IsAdmin()
end

local function report(playerEntity, message)
    if IsValid(playerEntity) then
        playerEntity:ChatPrint("[Tolic AI] " .. message)
    else
        MsgN("[Tolic AI] " .. message)
    end
end

concommand.Add("tolic_ai_observe", function(playerEntity)
    if not mayRun(playerEntity) then
        report(playerEntity, "Only an administrator can run this diagnostic.")
        return
    end

    local npc = TolicAI.ActiveNPC
    if not IsValid(npc) then
        report(playerEntity, "No active Tolik found. Spawn one before collecting an observation.")
        return
    end

    local observation, err = Observation.Collect(npc)
    if not observation then
        report(playerEntity, "Observation failed: " .. tostring(err))
        return
    end

    local payload = {
        schema_version = 1,
        observation = observation
    }
    local encoded = util.TableToJSON(payload, true)
    if not encoded then
        report(playerEntity, "Could not encode observation as JSON.")
        return
    end

    MsgN("[Tolic AI] Observation snapshot JSON:\n" .. encoded)
    report(playerEntity, "Observation snapshot collected; full JSON is in the dedicated server console. NPC control remains disabled.")
end)
