TolicAI = TolicAI or {}

if SERVER then
    AddCSLuaFile("tolic_ai/sh_config.lua")
end

include("tolic_ai/sh_config.lua")

if SERVER then
    include("tolic_ai/sv_observation.lua")
    include("tolic_ai/sv_bridge.lua")
    include("tolic_ai/sv_brain.lua")
end

if SERVER then
    MsgN("[Tolic AI] Addon loaded. Asynchronous stage 3 decision loop registered; verify actions in-game before treating it as stable.")
end
