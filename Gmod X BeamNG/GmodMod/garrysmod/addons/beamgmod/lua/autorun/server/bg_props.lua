-- Spawns the compiled BeamNG car models (garrysmod/models/beamgmod/*.mdl) as normal GMod props.
--   bg_prop            list the available models
--   bg_prop <name>     spawn one where you are looking, e.g. bg_prop etk800
-- Make the models first with:  glb.bat mdl <car>   or   glb.bat all

local function Available()
    local out = {}
    for _, f in ipairs(file.Find("models/beamgmod/*.mdl", "GAME")) do
        out[#out + 1] = string.StripExtension(f)
    end
    table.sort(out)
    return out
end

concommand.Add("bg_prop", function(ply, cmd, args)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local name = args[1] and string.lower(args[1]) or nil
    if not name then
        local list = Available()
        ply:ChatPrint("[BeamGMod] " .. #list .. " car models: " .. (#list > 0 and table.concat(list, ", ") or "none yet, run glb.bat all"))
        return
    end
    local mdl = "models/beamgmod/" .. name .. ".mdl"
    if not file.Exists(mdl, "GAME") then
        ply:ChatPrint("[BeamGMod] no model " .. mdl .. " (run glb.bat mdl " .. name .. ")")
        return
    end
    util.PrecacheModel(mdl)
    local tr = ply:GetEyeTrace()
    local e = ents.Create("prop_physics")
    if not IsValid(e) then return end
    e:SetModel(mdl)
    e:SetPos(tr.HitPos + Vector(0, 0, 40))
    e:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    e:Spawn()
    e:Activate()
    undo.Create("BeamNG " .. name)
    undo.AddEntity(e)
    undo.SetPlayer(ply)
    undo.Finish()
end, function(cmd, arg)
    local out = {}
    for _, n in ipairs(Available()) do
        if string.find(n, string.lower(string.Trim(arg)), 1, true) then out[#out + 1] = cmd .. " " .. n end
    end
    return out
end)
