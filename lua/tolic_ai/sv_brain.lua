if not SERVER then return end

TolicAI = TolicAI or {}
TolicAI.Brain = TolicAI.Brain or {}

local Brain = TolicAI.Brain

local ALLOWED_INTENTS = {
    observe = true,
    stay_near_player = true,
    follow_player = true,
    assist_player = true
}

local ALLOWED_RISK_LEVELS = {
    none = true,
    low = true,
    moderate = true,
    high = true,
    critical = true
}

local RESPONSE_KEYS = {
    schema_version = true,
    model = true,
    decision = true
}

local DECISION_KEYS = {
    intent = true,
    risk_level = true,
    confidence = true,
    summary = true
}

local function onlyAllowedKeys(value, allowed)
    for key in pairs(value) do
        if not allowed[key] then
            return false
        end
    end
    return true
end

local function validateResponse(data)
    if not istable(data) or not onlyAllowedKeys(data, RESPONSE_KEYS) then
        return nil, "response must contain only schema_version, model and decision"
    end

    if data.schema_version ~= 1 then
        return nil, "unsupported response schema_version"
    end

    if not isstring(data.model) or string.Trim(data.model) == "" then
        return nil, "response model name is missing"
    end

    local decision = data.decision
    if not istable(decision) or not onlyAllowedKeys(decision, DECISION_KEYS) then
        return nil, "decision must be an object with the documented fields only"
    end

    if not isstring(decision.intent) or not ALLOWED_INTENTS[decision.intent] then
        return nil, "unsupported decision intent"
    end

    if not isstring(decision.risk_level) or not ALLOWED_RISK_LEVELS[decision.risk_level] then
        return nil, "unsupported risk level"
    end

    local confidence = decision.confidence
    if not isnumber(confidence)
        or confidence ~= confidence
        or confidence == math.huge
        or confidence == -math.huge
        or confidence < 0
        or confidence > 1 then
        return nil, "confidence must be a finite number between 0 and 1"
    end

    if not isstring(decision.summary)
        or string.Trim(decision.summary) == ""
        or #decision.summary > 280 then
        return nil, "summary must contain between 1 and 280 characters"
    end

    return {
        intent = decision.intent,
        risk_level = decision.risk_level,
        confidence = confidence,
        summary = string.Trim(decision.summary)
    }, data.model
end

local function toVector(value)
    if not istable(value)
        or not isnumber(value.x)
        or not isnumber(value.y)
        or not isnumber(value.z) then
        return nil
    end

    return Vector(value.x, value.y, value.z)
end

local function nearestPlayer(origin)
    local nearest
    local nearestDistance

    for _, candidate in ipairs(player.GetAll()) do
        if IsValid(candidate) then
            local distance = origin:Distance(candidate:GetPos())
            if not nearestDistance or distance < nearestDistance then
                nearest = candidate
                nearestDistance = distance
            end
        end
    end

    return nearest, nearestDistance
end

local function nearestLivingPlayer(origin)
    local nearest
    local nearestDistance

    for _, candidate in ipairs(player.GetAll()) do
        if IsValid(candidate) and candidate:Alive() then
            local distance = origin:Distance(candidate:GetPos())
            if not nearestDistance or distance < nearestDistance then
                nearest = candidate
                nearestDistance = distance
            end
        end
    end

    return nearest, nearestDistance
end

local function stateFor(npc)
    npc.TolicAIBrainState = npc.TolicAIBrainState or {
        request_id = 0,
        in_flight = false,
        next_request_at = CurTime(),
        last_intent = "none",
        last_result = "waiting_for_first_decision",
        last_summary = "",
        last_model = "unknown"
    }

    return npc.TolicAIBrainState
end

local function report(message)
    MsgN("[Tolic AI] " .. tostring(message))
end

local function reportFailure(npc, state, message)
    state.last_result = "request_failed"
    state.next_request_at = CurTime() + (TolicAI.Config.FailureRetryInterval or 10)

    if IsValid(npc) then
        npc:SetNW2Bool("TolicAI.BrainConnected", false)
    end

    report("Brain request failed: " .. string.sub(tostring(message), 1, 240))
end

local function snapshotStillCurrent(npc, request)
    if not IsValid(npc) or TolicAI.ActiveNPC ~= npc then
        return false, "active_npc_changed"
    end

    local config = TolicAI.Config or {}
    local age = CurTime() - request.created_at
    if age > (config.MaxDecisionAge or 35) then
        return false, "response_too_old"
    end

    local observation = request.observation
    local npcFacts = observation.npc or {}
    local oldNPCPosition = toVector(npcFacts.position)

    if not oldNPCPosition then
        return false, "snapshot_missing_npc_position"
    end

    if npc:GetPos():Distance(oldNPCPosition) > (config.MaxNPCDrift or 200) then
        return false, "npc_moved_since_observation"
    end

    if isnumber(npcFacts.health) and npc:Health() ~= npcFacts.health then
        return false, "npc_health_changed_since_observation"
    end

    local playerFacts = observation.player or {}
    local targetPlayer = nearestPlayer(npc:GetPos())
    local playerPresent = IsValid(targetPlayer)

    if (playerFacts.present == true) ~= playerPresent then
        return false, "player_presence_changed"
    end

    if playerPresent then
        if playerFacts.alive ~= nil and targetPlayer:Alive() ~= playerFacts.alive then
            return false, "player_life_state_changed"
        end

        local oldPlayerPosition = toVector(playerFacts.position)
        if not oldPlayerPosition then
            return false, "snapshot_missing_player_position"
        end

        if targetPlayer:GetPos():Distance(oldPlayerPosition) > (config.MaxPlayerDrift or 400) then
            return false, "player_moved_since_observation"
        end
    end

    return true
end

local function moveToPosition(npc, targetPlayer, destination)
    local config = TolicAI.Config or {}
    local timeout = config.MoveTimeout or 15
    local goalTolerance = config.MoveGoalTolerance or 60
    local arrivalTolerance = config.MoveArrivalTolerance or 85
    local maxPlayerDrift = config.MaxPlayerDrift or 400

    if not navmesh.IsLoaded() or navmesh.GetNavAreaCount() <= 0 then
        return "blocked_navmesh_unavailable"
    end

    local path = Path("Follow")
    path:SetMinLookAheadDistance(100)
    path:SetGoalTolerance(goalTolerance)
    local computed = path:Compute(npc, destination)

    -- Compute can leave a valid partial path when the goal itself was not reached.
    -- Do not treat that as a successful route for this bounded action.
    if not computed or not path:IsValid() then
        return "blocked_no_path"
    end

    local startedAt = CurTime()
    local initialHealth = npc:Health()
    local initialPlayerPosition = targetPlayer:GetPos()

    while IsValid(npc) and CurTime() - startedAt < timeout do
        if not IsValid(targetPlayer) or not targetPlayer:Alive() then
            return "cancelled_target_unavailable"
        end

        if targetPlayer:GetPos():Distance(initialPlayerPosition) > maxPlayerDrift then
            return "cancelled_target_moved"
        end

        if npc:Health() ~= initialHealth then
            return "cancelled_npc_health_changed"
        end

        if npc:GetPos():Distance(destination) <= arrivalTolerance then
            return "arrived"
        end

        if not path:IsValid() then
            return "path_ended_before_arrival"
        end

        path:Update(npc)

        if not IsValid(npc) then
            return "entity_removed"
        end

        if npc.loco and npc.loco:IsStuck() then
            npc.loco:ClearStuck()
            return "stuck"
        end

        coroutine.yield()
    end

    if not IsValid(npc) then
        return "entity_removed"
    end

    return "movement_timeout"
end

local function executePlayerApproach(npc, intent)
    local targetPlayer = nearestLivingPlayer(npc:GetPos())
    if not IsValid(targetPlayer) then
        return "no_living_player_to_approach"
    end

    local config = TolicAI.Config or {}
    local triggerDistance
    local stopDistance

    if intent == "stay_near_player" then
        triggerDistance = config.StayNearMoveThreshold or 350
        stopDistance = config.StayNearStopDistance or 220
    elseif intent == "follow_player" then
        triggerDistance = config.FollowMoveThreshold or 230
        stopDistance = config.FollowStopDistance or 125
    elseif intent == "assist_player" then
        -- "Assist" currently means approach the player. It does not trigger combat,
        -- use weapons, or imply any other interaction.
        triggerDistance = config.AssistMoveThreshold or 180
        stopDistance = config.AssistStopDistance or 110
    else
        return "unsupported_movement_intent"
    end

    local playerPosition = targetPlayer:GetPos()
    local distance = npc:GetPos():Distance(playerPosition)
    if distance <= triggerDistance then
        return "no_movement_needed"
    end

    local direction = npc:GetPos() - playerPosition
    direction = Vector(direction.x, direction.y, 0)

    if direction:LengthSqr() < 1 then
        direction = Vector(1, 0, 0)
    else
        direction:Normalize()
    end

    local destination = Vector(
        playerPosition.x + direction.x * stopDistance,
        playerPosition.y + direction.y * stopDistance,
        playerPosition.z
    )

    return moveToPosition(npc, targetPlayer, destination)
end

function Brain.Execute(npc, decision)
    if not IsValid(npc) or TolicAI.ActiveNPC ~= npc then
        return "active_npc_changed"
    end

    if not istable(decision) or not ALLOWED_INTENTS[decision.intent] then
        return "blocked_invalid_decision"
    end

    if decision.intent == "observe" then
        return "observed_without_movement"
    end

    if decision.intent == "stay_near_player"
        or decision.intent == "follow_player"
        or decision.intent == "assist_player" then
        return executePlayerApproach(npc, decision.intent)
    end

    return "blocked_unsupported_intent"
end

local function startRequest(npc, state)
    if not TolicAI.Observation or not TolicAI.Bridge then
        reportFailure(npc, state, "observation or bridge module is not loaded")
        return
    end

    local observation, err = TolicAI.Observation.Collect(npc)
    if not observation then
        reportFailure(npc, state, err or "could not collect observation")
        return
    end

    state.request_id = state.request_id + 1
    local request = {
        id = state.request_id,
        created_at = CurTime(),
        observation = observation
    }

    state.current_request = request
    state.in_flight = true
    state.last_result = "waiting_for_model"

    TolicAI.Bridge.Decide(observation, function(data)
        if not IsValid(npc) or TolicAI.ActiveNPC ~= npc then return end
        if state.request_id ~= request.id or state.current_request ~= request then return end

        state.in_flight = false
        state.current_request = nil

        local decision, modelOrError = validateResponse(data)
        if not decision then
            reportFailure(npc, state, modelOrError)
            return
        end

        local fresh, reason = snapshotStillCurrent(npc, request)
        if not fresh then
            state.last_result = "stale_response_discarded"
            state.next_request_at = CurTime() + (TolicAI.Config.FailureRetryInterval or 10)
            report("Discarded stale decision: " .. tostring(reason))
            return
        end

        state.pending_decision = {
            decision = decision,
            model = modelOrError,
            request = request
        }

        state.last_model = modelOrError
        npc:SetNW2Bool("TolicAI.BrainConnected", true)

        report("Decision ready: intent=" .. decision.intent
            .. " risk=" .. decision.risk_level
            .. " confidence=" .. string.format("%.2f", decision.confidence)
            .. " model=" .. modelOrError)
    end, function(requestError)
        if not IsValid(npc) or TolicAI.ActiveNPC ~= npc then return end
        if state.request_id ~= request.id or state.current_request ~= request then return end

        state.in_flight = false
        state.current_request = nil
        state.pending_decision = nil
        reportFailure(npc, state, requestError)
    end)
end

function Brain.Tick(npc)
    if not IsValid(npc) or TolicAI.ActiveNPC ~= npc then return end

    local state = stateFor(npc)

    if state.pending_decision then
        local pending = state.pending_decision
        state.pending_decision = nil

        local fresh, reason = snapshotStillCurrent(npc, pending.request)
        if not fresh then
            state.last_result = "stale_before_execution"
            state.next_request_at = CurTime() + (TolicAI.Config.FailureRetryInterval or 10)
            report("Decision expired before execution: " .. tostring(reason))
            return
        end

        local decision = pending.decision
        local result = Brain.Execute(npc, decision)

        state.last_intent = decision.intent
        state.last_summary = decision.summary
        state.last_model = pending.model
        state.last_result = result
        state.next_request_at = CurTime() + (TolicAI.Config.DecisionInterval or 8)

        report("Intent executed: intent=" .. decision.intent
            .. " result=" .. tostring(result)
            .. " summary=" .. string.sub(decision.summary, 1, 180))
        return
    end

    if state.in_flight then
        local request = state.current_request
        local requestTimeout = (TolicAI.Config.RequestTimeout or 45) + 2
        if request and CurTime() - request.created_at > requestTimeout then
            -- Invalidate this request so any later callback cannot execute an old result.
            state.request_id = state.request_id + 1
            state.current_request = nil
            state.in_flight = false
            state.pending_decision = nil
            state.last_result = "request_timed_out"
            state.next_request_at = CurTime() + (TolicAI.Config.FailureRetryInterval or 10)
            npc:SetNW2Bool("TolicAI.BrainConnected", false)
            report("Brain request timed out; late callbacks will be ignored.")
        end
        return
    end

    if CurTime() >= (state.next_request_at or 0) then
        startRequest(npc, state)
    end
end

local function mayRun(ply)
    if not IsValid(ply) then return true end
    return ply:IsAdmin()
end

local function reportToPlayer(ply, message)
    if IsValid(ply) then
        ply:ChatPrint("[Tolic AI] " .. message)
    else
        MsgN("[Tolic AI] " .. message)
    end
end

concommand.Add("tolic_ai_brain_status", function(ply)
    if not mayRun(ply) then
        reportToPlayer(ply, "Only an administrator can run this diagnostic.")
        return
    end

    local npc = TolicAI.ActiveNPC
    if not IsValid(npc) then
        reportToPlayer(ply, "No active Tolik found.")
        return
    end

    local state = stateFor(npc)
    local pending = state.pending_decision and state.pending_decision.decision.intent or "none"
    reportToPlayer(ply, "in_flight=" .. tostring(state.in_flight)
        .. "; pending_intent=" .. tostring(pending)
        .. "; last_intent=" .. tostring(state.last_intent)
        .. "; last_result=" .. tostring(state.last_result)
        .. "; model=" .. tostring(state.last_model)
        .. "; next_request_in=" .. string.format("%.1f", math.max(0, (state.next_request_at or 0) - CurTime())))
end)
