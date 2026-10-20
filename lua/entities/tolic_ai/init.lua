AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

TolicAI = TolicAI or {}

function ENT:Initialize()
    local active = TolicAI.ActiveNPC
    if IsValid(active) and active ~= self then
        self:Remove()
        return
    end

    TolicAI.ActiveNPC = self

    self:SetModel("models/Humans/Group03/male_07.mdl")
    self:SetHealth((TolicAI.Config and TolicAI.Config.MaxHealth) or 100)
    self:SetMaxHealth((TolicAI.Config and TolicAI.Config.MaxHealth) or 100)
    self:SetSolid(SOLID_BBOX)
    self:SetCollisionBounds(Vector(-13, -13, 0), Vector(13, 13, 72))
    self:SetCollisionGroup(COLLISION_GROUP_NPC)
    self:SetNW2Bool("TolicAI.BrainConnected", false)

    MsgN("[Tolic AI] Prototype NPC spawned. Autonomous behaviour is not implemented yet.")
end

-- Intentionally passive in the bootstrap version. Do not substitute a hard-coded
-- decision tree for the neural model; autonomous behaviour will be connected only
-- after observation, validation and action execution are implemented and tested.
function ENT:RunBehaviour()
    while IsValid(self) do
        coroutine.wait(1)
    end
end

function ENT:OnRemove()
    if TolicAI and TolicAI.ActiveNPC == self then
        TolicAI.ActiveNPC = nil
    end
end
