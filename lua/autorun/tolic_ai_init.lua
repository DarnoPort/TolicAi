TolicAI = TolicAI or {}

if SERVER then
    AddCSLuaFile("tolic_ai/sh_config.lua")
end

include("tolic_ai/sh_config.lua")

if SERVER then
    include("tolic_ai/sv_observation.lua")
    include("tolic_ai/sv_bridge.lua")
end

if SERVER then
    MsgN("[Tolic AI] Addon loaded. Neural decisions are not yet connected to NPC behaviour.")
end
