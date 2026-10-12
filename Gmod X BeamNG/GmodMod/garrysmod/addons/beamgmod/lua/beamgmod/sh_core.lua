-- Shared helpers.
--
-- Coordinates: BeamNG's world is metres, Z up, X east, Y north, right-handed. Source is the same
-- handedness and axes in inches-ish units, so BeamNG -> GMod is only a scale and a translation:
--   gmod = origin + bng * BG.U
-- "origin" is the ground point under the player when the session starts (BeamNG 0,0,0 = there).

BG = BG or {}

BG.U = 39.37                 -- GMod units per metre (1 unit = 1 inch)
BG.IN = "beamgmod/in/"       -- written by the relay (garrysmod/data/beamgmod/in)
BG.OUT = "beamgmod/out/"     -- read by the relay
BG.VERSION = "0.1.0"

function BG.Log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    MsgC(Color(255, 170, 60), "[BeamGMod] ", Color(255, 255, 255), msg, "\n")
end

-- Reads a JSON file from data/. Returns the table (or nil) and the raw text.
function BG.ReadJSON(path)
    local s = file.Read(path, "DATA")
    if not s or s == "" then return nil, s end
    local t = util.JSONToTable(s)
    return t, s
end
