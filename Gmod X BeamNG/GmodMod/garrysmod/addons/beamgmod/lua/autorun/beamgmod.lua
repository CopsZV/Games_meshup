-- BeamGMod: BeamNG.drive cars inside Garry's Mod. Entry point; the real code is in lua/beamgmod/.
-- Needs BeamNG running with BeamCraft's crossover mod plus BeamGmodRelay (play.bat in the BeamGMod folder starts both).

BG = BG or {}

if SERVER then
    AddCSLuaFile("beamgmod/sh_core.lua")
    AddCSLuaFile("beamgmod/cl_main.lua")
    AddCSLuaFile("beamgmod/cl_menu.lua")
end

include("beamgmod/sh_core.lua")

if SERVER then
    include("beamgmod/sv_main.lua")
else
    include("beamgmod/cl_main.lua")
    include("beamgmod/cl_menu.lua")
end
