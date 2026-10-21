AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

TolicAI = TolicAI or {}

function ENT:Initialize()
    local active = TolicAI.ActiveNPC
    if IsValid(active) and active ~= self then
        MsgN("[Tolic AI] Duplicate spawn rejected; active NPC entity #" .. active:EntIndex() .. " remains.")
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

    MsgN("[Tolic AI] Prototype NPC spawned. Stage 3 decision loop enabled; autonomous decisions remain experimental until verified in-game.")
end

-- The neural model chooses a high-level intent. Brain.Tick validates the response
-- and runs only a small, bounded set of movement actions; it never executes model code.
function ENT:RunBehaviour()
    while IsValid(self) do
        if TolicAI and TolicAI.Brain then
            TolicAI.Brain.Tick(self)
        elseif not self.TolicAIBrainMissingLogged then
            self.TolicAIBrainMissingLogged = true
            MsgN("[Tolic AI] Brain module is missing; NPC remains passive.")
        end

        coroutine.wait(0.25)
    end
end

function ENT:OnRemove()
    if TolicAI and TolicAI.ActiveNPC == self then
        TolicAI.ActiveNPC = nil
        MsgN("[Tolic AI] Active NPC removed; registry cleared.")
    end
end
