if not SERVER then return end

TolicAI = TolicAI or {}
TolicAI.Bridge = TolicAI.Bridge or {}

local Bridge = TolicAI.Bridge
local function baseURL()
    return string.Trim(TolicAI.Config.BridgeURL or "http://127.0.0.1:8765", "/")
end

local function report(ply, message)
    if IsValid(ply) then
        ply:ChatPrint("[Tolic AI] " .. message)
    else
        MsgN("[Tolic AI] " .. message)
    end
end

local function request(path, payload, onSuccess, onFailure)
    local body
    local headers = {}

    if payload ~= nil then
        body = util.TableToJSON(payload)
        if not body then
            onFailure("Could not encode request as JSON")
            return
        end
        headers["Content-Type"] = "application/json"
    end

    HTTP({
        url = baseURL() .. path,
        method = payload ~= nil and "POST" or "GET",
        headers = headers,
        body = body,
        timeout = TolicAI.Config.RequestTimeout or 45,
        success = function(code, responseBody)
            if code < 200 or code >= 300 then
                onFailure("HTTP " .. tostring(code) .. ": " .. string.sub(responseBody or "", 1, 300))
                return
            end

            local decoded = util.JSONToTable(responseBody or "")
            if not istable(decoded) then
                onFailure("Bridge returned invalid JSON")
                return
            end

            onSuccess(decoded)
        end,
        failed = function(reason)
            onFailure("HTTP request failed: " .. tostring(reason))
        end
    })
end

function Bridge.Check(onSuccess, onFailure)
    request("/health", nil, onSuccess or function(data)
        MsgN("[Tolic AI] Bridge health: " .. util.TableToJSON(data, true))
    end, onFailure or function(err)
        MsgN("[Tolic AI] Bridge health check failed: " .. tostring(err))
    end)
end

function Bridge.Decide(observation, onSuccess, onFailure)
    request("/api/decision", {
        schema_version = 1,
        observation = observation
    }, onSuccess or function(data)
        MsgN("[Tolic AI] Decision: " .. util.TableToJSON(data, true))
    end, onFailure or function(err)
        MsgN("[Tolic AI] Decision request failed: " .. tostring(err))
    end)
end

local function mayRun(ply)
    if not IsValid(ply) then return true end
    return ply:IsAdmin()
end

concommand.Add("tolic_ai_bridge_status", function(ply)
    if not mayRun(ply) then
        report(ply, "Only an administrator can run this diagnostic.")
        return
    end

    report(ply, "Checking local AI bridge...")
    Bridge.Check(function(data)
        report(ply, "Bridge replied. Ollama reachable: " .. tostring(data.ollama_reachable)
            .. "; configured model available: " .. tostring(data.model_available)
            .. "; model: " .. tostring(data.model))
    end, function(err)
        report(ply, "Bridge check failed: " .. tostring(err))
    end)
end)

concommand.Add("tolic_ai_test_decision", function(ply)
    if not mayRun(ply) then
        report(ply, "Only an administrator can run this diagnostic.")
        return
    end

    local observation = {
        npc = {
            health_fraction = 1.0,
            recent_damage = false,
            distance_to_player = 200
        },
        player = {
            present = true,
            under_threat = false,
            invulnerability_observed = false
        },
        environment = {
            visible_threat_count = 0,
            recent_danger = false,
            navmesh_available = true
        }
    }

    report(ply, "Sending a diagnostic observation to the neural model...")
    Bridge.Decide(observation, function(data)
        local decision = data.decision or {}
        report(ply, "Model: " .. tostring(data.model)
            .. "; intent: " .. tostring(decision.intent)
            .. "; risk: " .. tostring(decision.risk_level)
            .. "; confidence: " .. tostring(decision.confidence)
            .. "; summary: " .. tostring(decision.summary))
    end, function(err)
        report(ply, "Neural decision test failed: " .. tostring(err))
    end)
end)
