-- BeamGMod server side: talks to BeamGmodRelay through files in data/beamgmod, builds the ground
-- BeamNG drives on (flat or a heightmap sampled from this map), spawns cars, drives them.
--
-- BeamNG is the physics engine here. GMod only draws the car (cl_main.lua) and feeds the inputs.
-- Single player / listen server only: the relay's files live on the host's disk.

if not SERVER then return end

local U = BG.U
local IN, OUT = BG.IN, BG.OUT

util.AddNetworkString("bg_msg")

file.CreateDir("beamgmod")
file.CreateDir("beamgmod/in")
file.CreateDir("beamgmod/in/ev")
file.CreateDir("beamgmod/out")

local cvSteerInvert = CreateConVar("bg_steer_invert", "0", FCVAR_ARCHIVE, "1 = flip the steering direction")
local cvRange = CreateConVar("bg_range", "400", FCVAR_ARCHIVE, "how far (m) BeamNG streams car shapes")
local cvTerrainSize = CreateConVar("bg_terrain_size", "512", FCVAR_ARCHIVE, "terrain mode: heightmap samples per side (256, 512 or 1024)")
local cvTerrainSquare = CreateConVar("bg_terrain_square", "1", FCVAR_ARCHIVE, "terrain mode: metres per heightmap sample")
local cvDebug = CreateConVar("bg_debug", "0", 0, "1 = log every BeamNG event")
local cvTerrainUp = CreateConVar("bg_terrain_up", "2400", FCVAR_ARCHIVE, "terrain mode: how high above you (units) the ground search starts")

local S = {
    mode = "flat",
    model = "pickup",
    config = nil,
    stage = "boot",
    outN = 0,
    relayAlive = false, conn = false, ready = false, sid = 0, level = "", rtt = -1, bng = "",
    initSid = nil,
    origin = nil,
    known = {},
    state = nil,
    vehicles = nil,
    carId = nil,
    want = nil,
    driver = nil,
    lastDrive = 0, lastKey = "",
    prevKeys = {},
    nextStatus = 0, nextEvents = 0, nextVeh = 0, nextMsg = 0,
    nextShot = 0, nextBoom = 0, nextUse = 0,
    spawnT = 0,
}
BG.S = S

-- ------------------------------------------------------------------ config written by play.ps1

local function LoadConfig()
    local m = file.Read("beamgmod/mode.txt", "DATA")
    if m then
        m = string.lower(string.Trim(m))
        if m == "terrain" or m == "flat" then S.mode = m end
    end
    local a = file.Read("beamgmod/autospawn.txt", "DATA")
    if a then
        local model, cfg = string.match(string.Trim(a), "^(%S+)%s*(%S*)")
        if model and model ~= "" then S.model = model end
        if cfg and cfg ~= "" then S.config = cfg end
    end
end
LoadConfig()

-- ------------------------------------------------------------------ helpers

local function Send(tbl)
    local json = util.TableToJSON(tbl)
    if not json then return end
    S.outN = S.outN + 1
    local base = OUT .. string.format("%09d", S.outN)
    file.Write(base .. ".json", json)
    -- written in place: the relay skips a file that is empty or unfinished and looks again
end

local function Say(msg, chat, problem)
    BG.Log("%s", msg)
    SetGlobalString("bg_stage", msg)
    SetGlobalBool("bg_problem", problem and true or false)
    if chat then
        for _, p in ipairs(player.GetAll()) do p:ChatPrint("[BeamNG] " .. msg) end
    end
end

local function Host()
    for _, p in ipairs(player.GetAll()) do
        if p:IsListenServerHost() then return p end
    end
    return player.GetAll()[1]
end

local function Allowed(ply)
    if not IsValid(ply) then return true end
    return ply:IsListenServerHost() or game.SinglePlayer()
end

local function ToBng(v)
    local o = S.origin
    return { (v.x - o.x) / U, (v.y - o.y) / U, (v.z - o.z) / U }
end

local function ToWorld(t)
    local o = S.origin
    return Vector(o.x + t[1] * U, o.y + t[2] * U, o.z + t[3] * U)
end

local function MakeOrigin(ply)
    local p = ply:GetPos()
    local tr = util.TraceLine({
        start = p + Vector(0, 0, 72),
        endpos = p - Vector(0, 0, 4096),
        mask = MASK_PLAYERSOLID_BRUSHONLY,
    })
    local o = tr.Hit and tr.HitPos or p
    S.origin = Vector(o.x, o.y, o.z)
    SetGlobalVector("bg_origin", S.origin)
    SetGlobalBool("bg_have_origin", true)
    BG.Log("origin (BeamNG 0,0,0) = %.0f %.0f %.0f", o.x, o.y, o.z)
end

local function ToClient(kind, raw)
    if not raw or #raw > 60000 then return end
    net.Start("bg_msg")
    net.WriteString(kind)
    net.WriteString(raw)
    net.Broadcast()
end

-- ------------------------------------------------------------------ terrain (terrain mode)

-- BeamNG's own export of a car (glTF + node groups); the relay converts it into data/beamgmod/in/model_<id>.json
-- and models/*, which cl_main.lua loads. The first export of a model freezes BeamNG for 20-30 s (textures).
local function ExportCar(id)
    if not id then return end
    S.exportWant = id
    Send({ t = "vexport", id = id })
    BG.Log("asked BeamNG to export car %s as a model (BeamNG may freeze for up to 30 s the first time)", tostring(id))
end

local function StartTerrain()
    local want = cvTerrainSize:GetInt()
    local size = 512
    if want <= 256 then size = 256 elseif want > 512 then size = 1024 end
    local sq = math.max(0.25, cvTerrainSquare:GetFloat())
    S.T = {
        size = size, sq = sq, n = 0, total = size * size,
        x0 = -(size - 1) * sq / 2, y0 = -(size - 1) * sq / 2,
        h = {}, minh = 1e9, maxh = -1e9, last = 0,
        id = os.time(), enc = 0, chars = {}, pct = -1,
    }
    S.stage = "terrain_sample"
    Say(string.format("sampling the map for BeamNG's terrain (%dx%d samples, %.0f m around you)...", size, size, size * sq), true)
end

local trd = { start = Vector(), endpos = Vector(), mask = MASK_PLAYERSOLID_BRUSHONLY, output = {} }

-- Ground height (world units) under one column. A start point that is inside solid (outside the map,
-- in the sky shell, inside a roof) is moved down until it is in open air, so the sky and ceilings are
-- never taken for the ground (that buried the car in the terrain on most maps).
local function Ground(T, o, wx, wy, up)
    trd.start.x, trd.start.y = wx, wy
    trd.endpos.x, trd.endpos.y, trd.endpos.z = wx, wy, o.z - 3000
    local top = o.z + up
    local sz = T.sz or top
    local fromTop = sz >= top
    for _ = 1, 30 do
        trd.start.z = sz
        local res = util.TraceLine(trd)
        if res.StartSolid or res.AllSolid then
            if not fromTop then
                sz = top
                fromTop = true
            else
                sz = sz - 160
                if sz < o.z - 1500 then return nil end
            end
        else
            if res.Hit and not res.HitSky then
                T.sz = math.min(top, res.HitPos.z + 400)
                return res.HitPos.z
            end
            return nil
        end
    end
    return nil
end

local function TerrainStep()
    local T = S.T
    if not T then return end
    local o = S.origin
    local stop = SysTime() + 0.008
    local h = T.h
    local size, sq, x0, y0 = T.size, T.sq, T.x0, T.y0
    local up = math.max(300, cvTerrainUp:GetFloat())

    if T.n < T.total then
        while T.n < T.total do
            local i = T.n
            local gx = i % size
            local gy = (i - gx) / size
            local wx = o.x + (x0 + gx * sq) * U
            local wy = o.y + (y0 + gy * sq) * U
            local gz = Ground(T, o, wx, wy, up)
            local z
            if gz then
                z = (gz - o.z) / U
                T.last = z
            else
                z = T.last
            end
            h[i + 1] = z
            if z < T.minh then T.minh = z end
            if z > T.maxh then T.maxh = z end
            T.n = i + 1
            if i % 128 == 0 and SysTime() > stop then break end
        end
        local pct = math.floor(T.n * 100 / T.total / 10) * 10
        if pct ~= T.pct then
            T.pct = pct
            SetGlobalString("bg_stage", "sampling terrain " .. pct .. "%")
        end
        return
    end

    -- encode heights as uint16 little endian
    if not T.z0 then
        T.z0 = T.minh - 1.0
        T.height = math.max(20, T.maxh - T.minh + 4)
        T.inv = 65535 / T.height
    end
    local chars = T.chars
    local inv, z0 = T.inv, T.z0
    while T.enc < T.total do
        local i = T.enc + 1
        local v = math.floor((h[i] - z0) * inv + 0.5)
        if v < 0 then v = 0 elseif v > 65535 then v = 65535 end
        local lo = v % 256
        chars[i] = string.char(lo, (v - lo) / 256)
        T.enc = i
        if i % 512 == 0 and SysTime() > stop then return end
    end

    local bin = "hm_" .. T.id .. ".dat"
    file.Write(OUT .. bin, table.concat(chars))
    Send({
        t = "@terrain", id = T.id, size = T.size, square = T.sq,
        x0 = T.x0, y0 = T.y0, z0 = T.z0, height = T.height, bin = bin,
    })
    BG.Log("terrain heights %.1f..%.1f m, sent %s", T.minh, T.maxh, bin)
    S.terrId = T.id
    S.terrT = RealTime()
    -- kept so cars can be spawned on, and put back onto, the sampled ground
    S.HM = { h = T.h, size = T.size, sq = T.sq, x0 = T.x0, y0 = T.y0, minz = T.minh, maxz = T.maxh }
    S.T = nil
    S.stage = "terrain_wait"
    Say("BeamNG is building the terrain (can take 10-30 s)...")
end

-- ------------------------------------------------------------------ cars

-- highest sampled ground (BeamNG metres) around a point; nil outside the sampled square; 0 on the flat map
local function GroundAt(bx, by)
    local M = S.HM
    if not M then return 0 end
    local fx, fy = (bx - M.x0) / M.sq, (by - M.y0) / M.sq
    local gx, gy = math.floor(fx), math.floor(fy)
    local size = M.size
    if gx < 0 or gy < 0 or gx >= size - 1 or gy >= size - 1 then return nil end
    local h = M.h
    local i = gy * size + gx + 1
    local a, b, c, d = h[i], h[i + 1], h[i + size], h[i + size + 1]
    if not (a and b and c and d) then return nil end
    return math.max(a, b, c, d)
end

local function RequestSpawn(ply, model, config, enter)
    if not S.origin then return end
    local yaw = math.rad(ply:EyeAngles().y)
    local fx, fy = math.cos(yaw), math.sin(yaw)
    local p = ply:GetPos() + Vector(fx, fy, 0) * 240
    local pos = ToBng(p)
    local sz = pos[3] + 0.3
    local g = GroundAt(pos[1], pos[2])
    if g and g + 0.6 > sz then sz = g + 0.6 end   -- never spawn inside the terrain
    local msg = {
        t = "vehicle_spawn", model = model, mode = "new",
        pos = { pos[1], pos[2], sz }, fwd = { fx, fy, 0 },
    }
    if config and config ~= "" then msg.config = config end
    S.want = { enter = enter, t = RealTime(), model = model }
    Send(msg)
end

local function StartSpawn()
    local host = Host()
    if not IsValid(host) then return end
    S.stage = "spawn_wait"
    S.spawnT = RealTime()
    Say("spawning " .. S.model .. " (BeamNG freezes for a few seconds while it loads the car)...")
    RequestSpawn(host, S.model, S.config, true)
end

local function CleanOthers(keepId)
    local v = BG.ReadJSON(IN .. "vehicles.json")
    if v and v.list then
        for _, c in ipairs(v.list) do
            if c.id and not S.known[c.id] and c.id ~= keepId then
                Send({ t = "vehicle_remove", id = c.id })
            end
        end
    end
end

-- Removes a car from BeamNG and wipes its stream files so GMod stops drawing it (no low-poly ghost).
local function RemoveCar(id)
    if not id then return end
    Send({ t = "vehicle_remove", id = id })
    S.known[id] = nil
    if S.carId == id then S.carId = nil end
    for _, pre in ipairs({ "vmesh_", "vtris_", "model_" }) do
        local p = IN .. pre .. id .. ".json"
        if file.Exists(p, "DATA") then file.Delete(p) end
    end
    ToClient("gone", util.TableToJSON({ id = id }))
end

-- ------------------------------------------------------------------ driver handling

local function ReleaseFlags(ply)
    if IsValid(ply) then
        ply:SetNWBool("bg_drv", false)
        ply:SetMoveType(MOVETYPE_WALK)
        ply:SetNoDraw(false)
        ply:SetNotSolid(false)
        ply:DrawViewModel(true)
        ply:DrawWorldModel(true)
        if not ply.bg_god then ply:GodDisable() end
        if ply.bg_wep and ply.bg_wep ~= "" then
            local cls = ply.bg_wep
            pcall(function() ply:SelectWeapon(cls) end)
        end
    end
    S.driver = nil
end

local function EnterDrive(ply)
    if not IsValid(ply) or S.driver == ply then return end
    if S.driver then ReleaseFlags(S.driver) end
    S.driver = ply
    ply.bg_god = ply:HasGodMode()
    local w = ply:GetActiveWeapon()
    ply.bg_wep = IsValid(w) and w:GetClass() or ""
    ply:GodEnable()
    ply:Flashlight(false)
    ply:SetMoveType(MOVETYPE_NONE)
    ply:SetNoDraw(true)
    ply:SetNotSolid(true)
    ply:DrawViewModel(false)
    ply:DrawWorldModel(false)
    pcall(function() ply:SetActiveWeapon(NULL) end)
    ply:SetNWBool("bg_drv", true)
    S.lastKey = ""
    S.prevKeys = {}
end

local function ExitDrive(ply)
    if not IsValid(ply) then S.driver = nil return end
    local st = S.state
    local dest
    if st and st.veh and st.veh.pos and st.veh.fwd and st.veh.up and S.origin then
        local f, u = st.veh.fwd, st.veh.up
        -- right = fwd x up
        local rx = f[2] * u[3] - f[3] * u[2]
        local ry = f[3] * u[1] - f[1] * u[3]
        dest = ToWorld(st.veh.pos) - Vector(rx, ry, 0) * (3.2 * U) + Vector(0, 0, 40)
    end
    -- stop the car where it is
    Send({ t = "vehicle_drive", throttle = 0, brake = 0, steering = 0, parkingbrake = 1, filter = 0 })
    ReleaseFlags(ply)
    if dest then ply:SetPos(dest) end
    ply:SetVelocity(-ply:GetVelocity())
end

local function NearestCar(ply)
    local best, bestD = nil, (9 * U) * (9 * U)
    local list = S.vehicles and S.vehicles.list
    if list and S.origin then
        local pp = ply:GetPos()
        for _, c in ipairs(list) do
            local p = c.center or c.pos
            if p and c.id then
                local d = ToWorld(p):DistToSqr(pp)
                if d < bestD then best, bestD = c.id, d end
            end
        end
    end
    return best
end

local function TryEnter(ply, id)
    local cur = S.state and S.state.veh and S.state.veh.id
    if id ~= cur then
        Send({ t = "enter_vehicle", id = id })
    end
    S.carId = id
    EnterDrive(ply)
end

local function Edge(name, down)
    local prev = S.prevKeys[name] or false
    S.prevKeys[name] = down
    return (down and not prev), ((not down) and prev)
end

local function DriveStep(rt)
    local ply = S.driver
    if not ply then return end
    if not IsValid(ply) or not ply:Alive() then
        ReleaseFlags(ply)
        return
    end
    local st = S.state
    if st and st.veh and st.veh.pos and S.origin and (not S.carId or st.veh.id == S.carId) then
        ply:SetPos(ToWorld(st.veh.pos))
    end
    if S.stage ~= "run" or not S.conn then return end

    local thr = ply:KeyDown(IN_FORWARD) and 1 or 0
    local brk = ply:KeyDown(IN_BACK) and 1 or 0
    local steer = 0
    if ply:KeyDown(IN_MOVERIGHT) then steer = steer + 1 end
    if ply:KeyDown(IN_MOVELEFT) then steer = steer - 1 end
    if cvSteerInvert:GetBool() then steer = -steer end
    local pb = ply:KeyDown(IN_JUMP) and 1 or 0

    local key = thr .. "," .. brk .. "," .. steer .. "," .. pb
    local dt = rt - S.lastDrive
    if (key ~= S.lastKey and dt >= 0.03) or dt >= 0.15 then
        S.lastKey = key
        S.lastDrive = rt
        Send({ t = "vehicle_drive", throttle = thr, brake = brk, steering = steer, parkingbrake = pb, filter = 0, ttl = 0.6 })
    end

    local pressed, released = Edge("atk", ply:KeyDown(IN_ATTACK))
    if pressed then Send({ t = "vehicle_action", action = "horn", down = true }) end
    if released then Send({ t = "vehicle_action", action = "horn", down = false }) end

    if (Edge("atk2", ply:KeyDown(IN_ATTACK2))) then
        Send({ t = "vehicle_action", action = "lights", down = true })
        Send({ t = "vehicle_action", action = "lights", down = false })
    end

    if (Edge("rld", ply:KeyDown(IN_RELOAD))) then
        -- flip back onto the wheels and repair, right where it is
        if st and st.veh and st.veh.pos and st.veh.fwd then
            local f = st.veh.fwd
            local l = math.sqrt(f[1] * f[1] + f[2] * f[2])
            if l < 1e-3 then f = { 1, 0, 0 }; l = 1 end
            Send({
                t = "vehicle_place",
                pos = { st.veh.pos[1], st.veh.pos[2], st.veh.pos[3] + 0.8 },
                fwd = { f[1] / l, f[2] / l, 0 },
            })
        end
    end
end

-- ------------------------------------------------------------------ BeamNG events

-- A car that left the sampled terrain (fell out of the world, flew off, NaN physics) is put back on
-- the last good spot. Cars far outside the map were what crashed GMod.
local function CheckCar(rt)
    local v = S.state and S.state.veh
    if not (v and v.pos and S.origin) then return end
    local x, y, z = tonumber(v.pos[1]), tonumber(v.pos[2]), tonumber(v.pos[3])
    if not (x and y and z) then return end
    local ok = (x == x and y == y and z == z)
    local M = S.HM
    if ok then
        if M then
            local lim = -M.x0 - 6
            ok = math.abs(x) < lim and math.abs(y) < lim and z > M.minz - 25 and z < M.maxz + 400
        else
            ok = z > -40 and z < 3000
        end
    end
    if ok then
        if (tonumber(v.speed) or 0) < 150 then S.good = { x, y, z, v.fwd } end
        return
    end
    if rt < (S.nextRescue or 0) then return end
    S.nextRescue = rt + 3
    local px, py, pz, f = 0, 0, 1, { 1, 0, 0 }
    local gp = S.good
    if gp then
        px, py, pz, f = gp[1], gp[2], gp[3] + 1.0, gp[4] or f
    else
        pz = (GroundAt(0, 0) or 0) + 1
    end
    local l = math.sqrt(f[1] * f[1] + f[2] * f[2])
    if l < 1e-3 then f = { 1, 0, 0 }; l = 1 end
    Send({ t = "vehicle_place", pos = { px, py, pz }, fwd = { f[1] / l, f[2] / l, 0 } })
    Say("the car left the map terrain, put it back on the ground", false)
end

local function HandleEvent(ev, raw)
    local t = ev.t
    if cvDebug:GetBool() then BG.Log("event %s", tostring(raw):sub(1, 300)) end
    if t == "@connected" then
        BG.Log("relay connected to BeamNG (session %s)", tostring(ev.sid))
    elseif t == "@disconnected" then
        BG.Log("relay lost BeamNG (%s)", tostring(ev.why))
    elseif t == "@error" then
        BG.Log("relay error: %s %s", tostring(ev.code), tostring(ev.msg or ev["for"] or ""))
    elseif t == "error" then
        local code = tostring(ev.code)
        if code ~= "unknown_session" then
            Say("BeamNG error: " .. code .. " " .. tostring(ev.msg or ""), true, false)
        end
        if code == "spawn_failed" then
            S.want = nil
            if S.stage == "spawn_wait" then S.stage = "run" end
        elseif code == "busy" and S.exportWant then
            local id = S.exportWant
            timer.Simple(4, function() ExportCar(id) end)
        elseif code == "terrain_failed" and S.stage == "terrain_wait" then
            S.stage = "spawn_start"
        end
    elseif t == "vehicle_spawned" then
        local id = ev.id
        if not id then return end
        S.known[id] = true
        timer.Simple(1.5, function() ExportCar(id) end)
        if S.stage == "spawn_wait" or (S.want and S.want.enter) then
            S.carId = id
            Send({ t = "enter_vehicle", id = id })
            if S.stage == "spawn_wait" then
                CleanOthers(id)
                S.stage = "run"
                Say("ready: " .. tostring(ev.model) .. ". Press E to get in/out. Press C for the context menu, the BeamNG icon picks other cars.", true)
            else
                Say("spawned " .. tostring(ev.model), false)
            end
            local host = Host()
            if IsValid(host) then EnterDrive(host) end
        end
        S.want = nil
    elseif t == "terrain_loaded" then
        if S.stage == "terrain_wait" then
            Say("terrain ready (" .. tostring(ev.ms) .. " ms)", true)
            S.stage = "spawn_start"
        end
    elseif t == "vlist" or t == "vconfigs" then
        ToClient(t, raw)
    elseif t == "@model" then
        Say("car " .. tostring(ev.id) .. " (" .. tostring(ev.model) .. ") model converted in " .. tostring(ev.ms) .. " ms", true)
    elseif t == "@modelfail" then
        Say("car model conversion failed: " .. tostring(ev.msg), true, true)
    elseif t == "vehicle_rescued" then
        BG.Log("BeamNG put a car back on the ground (%s)", tostring(ev.why))
    end
end

local function PollEvents()
    local files = file.Find(IN .. "ev/*.json", "DATA")
    if not files then return end
    local n = math.min(#files, 60)
    for i = 1, n do
        local p = IN .. "ev/" .. files[i]
        local s = file.Read(p, "DATA")
        if s and s ~= "" then
            file.Delete(p)
            local ev = util.JSONToTable(s)
            if ev then
                local ok, err = pcall(HandleEvent, ev, s)
                if not ok then BG.Log("event handler error: %s", tostring(err)) end
            end
        end
    end
end

local function PollStatus()
    local st = BG.ReadJSON(IN .. "status.json")
    if not st then
        S.relayAlive = false
        return
    end
    S.relayAlive = math.abs(os.time() - (tonumber(st.time) or 0)) < 6
    S.conn = st.connected == true
    S.ready = st.ready == true
    S.sid = tonumber(st.sid) or 0
    S.level = tostring(st.level or "")
    S.rtt = tonumber(st.rtt) or -1
    S.bng = tostring(st.bng or "")
end

local function DoInit(host)
    S.initSid = S.sid
    S.known = {}
    S.carId = nil
    S.want = nil
    S.T = nil
    S.HM = nil
    S.good = nil
    if not S.origin then MakeOrigin(host) end
    Send({ t = "render_main", on = false })
    Send({ t = "vmesh_sub", on = true, range = cvRange:GetInt() })
    Send({ t = "vlist_req" })
    Say("connected to BeamNG " .. S.bng .. " (" .. S.mode .. " mode)", true)
    if S.mode == "terrain" then StartTerrain() else S.stage = "spawn_start" end
end

local function UpdateStage(rt)
    if not S.relayAlive then
        S.initSid = nil
        if rt >= S.nextMsg then
            S.nextMsg = rt + 8
            Say("the BeamNG relay is not running. Start the game with play.bat from the BeamGMod folder.", false, true)
        end
        return
    end
    if not (S.conn and S.ready) then
        if rt >= S.nextMsg then
            S.nextMsg = rt + 8
            Say(S.conn and "BeamNG is still loading its level..." or "waiting for BeamNG (is it running with the crossover mod?)", false, true)
        end
        return
    end
    if S.initSid ~= S.sid then
        local host = Host()
        if IsValid(host) and host:Alive() then DoInit(host) end
        return
    end
    if S.stage == "terrain_wait" and rt - S.terrT > 150 then
        Say("BeamNG did not answer the terrain request in time; continuing without it", true)
        S.stage = "spawn_start"
    elseif S.stage == "spawn_start" then
        StartSpawn()
    elseif S.stage == "spawn_wait" and rt - S.spawnT > 90 then
        Say("the car spawn timed out. Use the BeamNG icon in the context menu (C) to pick a car.", true)
        S.stage = "run"
    end
end

-- ------------------------------------------------------------------ main loop

hook.Add("Think", "BG_Think", function()
    local rt = RealTime()

    if rt >= S.nextStatus then
        S.nextStatus = rt + 0.25
        PollStatus()
        UpdateStage(rt)
    end
    if rt >= S.nextEvents then
        S.nextEvents = rt + 0.1
        PollEvents()
    end

    if S.conn then
        local st = BG.ReadJSON(IN .. "state.json")
        if st then S.state = st end
        if rt >= S.nextVeh then
            S.nextVeh = rt + 0.5
            local v = BG.ReadJSON(IN .. "vehicles.json")
            if v then S.vehicles = v end
        end
    end

    if S.stage == "terrain_sample" then TerrainStep() end
    DriveStep(rt)
    if S.stage == "run" and rt >= (S.nextCheck or 0) then
        S.nextCheck = rt + 0.5
        CheckCar(rt)
    end
end)

hook.Add("KeyPress", "BG_Use", function(ply, key)
    if key ~= IN_USE then return end
    if S.stage ~= "run" or not S.origin or ply ~= Host() then return end
    local rt = RealTime()
    if rt < S.nextUse then return end
    S.nextUse = rt + 0.5
    if S.driver == ply then
        ExitDrive(ply)
        return
    end
    local id = NearestCar(ply)
    if id then TryEnter(ply, id) end
end)

hook.Add("PlayerSwitchWeapon", "BG_NoWeapon", function(ply)
    if S.driver == ply then return true end
end)

hook.Add("PlayerNoClip", "BG_NoNoclip", function(ply)
    if S.driver == ply then return false end
end)

hook.Add("PlayerSwitchFlashlight", "BG_NoFlash", function(ply)
    if S.driver == ply then return false end
end)

hook.Add("PlayerSpawn", "BG_Respawn", function(ply)
    if S.driver == ply then ReleaseFlags(ply) end
end)

hook.Add("PlayerDisconnected", "BG_Leave", function(ply)
    if S.driver == ply then S.driver = nil end
end)

-- ------------------------------------------------------------------ damage into BeamNG

-- ray (BeamNG metres) against a car's oriented bounding box from the vehicles list
local function RayOBB(o, d, c)
    if not c.center or not c.axes then return nil end
    local tmin, tmax = 0, 400
    for i = 1, 3 do
        local a = c.axes[i]
        if not a then return nil end
        local h = math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
        if h < 1e-6 then return nil end
        local ux, uy, uz = a[1] / h, a[2] / h, a[3] / h
        local e = ux * (c.center[1] - o[1]) + uy * (c.center[2] - o[2]) + uz * (c.center[3] - o[3])
        local f = ux * d[1] + uy * d[2] + uz * d[3]
        if math.abs(f) > 1e-6 then
            local t1, t2 = (e - h) / f, (e + h) / f
            if t1 > t2 then t1, t2 = t2, t1 end
            if t1 > tmin then tmin = t1 end
            if t2 < tmax then tmax = t2 end
            if tmin > tmax then return nil end
        elseif e - h > 0 or e + h < 0 then
            return nil
        end
    end
    return tmin
end

hook.Add("EntityFireBullets", "BG_Bullets", function(ent, data)
    if S.stage ~= "run" or not S.origin or not S.conn then return end
    if S.driver == ent then return end
    local rt = RealTime()
    if rt < S.nextShot then return end
    local list = S.vehicles and S.vehicles.list
    if not list or not data.Src or not data.Dir then return end
    local o = ToBng(data.Src)
    local dir = data.Dir
    local d = { dir.x, dir.y, dir.z }
    for _, c in ipairs(list) do
        local t = c.id and RayOBB(o, d, c)
        if t then
            S.nextShot = rt + 0.05
            local dmg = data.Damage
            if not dmg or dmg <= 0 then dmg = 8 end
            Send({
                t = "vehicle_fx", id = c.id, kind = "dent",
                pos = { o[1] + d[1] * t, o[2] + d[2] * t, o[3] + d[3] * t },
                dir = d, damage = math.min(40, dmg),
            })
            return
        end
    end
end)

hook.Add("EntityTakeDamage", "BG_Boom", function(target, dmg)
    if S.stage ~= "run" or not S.origin or not S.conn then return end
    if not dmg:IsExplosionDamage() then return end
    local rt = RealTime()
    if rt < S.nextBoom then return end
    local p = dmg:GetReportedPosition()
    if p == vector_origin then p = target:GetPos() end
    local list = S.vehicles and S.vehicles.list
    if not list then return end
    local b = ToBng(p)
    local near = false
    for _, c in ipairs(list) do
        local cp = c.pos
        if cp then
            local dx, dy, dz = cp[1] - b[1], cp[2] - b[2], cp[3] - b[3]
            if dx * dx + dy * dy + dz * dz < 900 then near = true break end
        end
    end
    if not near then return end
    S.nextBoom = rt + 0.3
    Send({ t = "explosion", pos = b, power = math.Clamp(dmg:GetDamage() / 25, 1, 8) })
end)

-- ------------------------------------------------------------------ console commands

local function Cmd(name, fn)
    concommand.Add(name, function(ply, cmd, args)
        if not Allowed(ply) then return end
        local ok, err = pcall(fn, ply, args)
        if not ok then BG.Log("%s failed: %s", name, tostring(err)) end
    end)
end

local function PlayerCar()
    return S.state and S.state.veh and S.state.veh.id
end

Cmd("bg_spawn", function(ply, args)
    if S.stage ~= "run" and S.stage ~= "spawn_wait" then
        BG.Log("not ready yet (stage %s)", S.stage)
        return
    end
    local model = args[1]
    if not model or model == "" then BG.Log("usage: bg_spawn <model> [config]") return end
    local host = IsValid(ply) and ply or Host()
    Say("spawning " .. model .. (args[2] and (" " .. args[2]) or "") .. "...", false)
    RequestSpawn(host, model, args[2], true)
end)

Cmd("bg_remove", function()
    local id = PlayerCar()
    if not id then return end
    if S.driver then ExitDrive(S.driver) end
    RemoveCar(id)
end)

Cmd("bg_removeall", function()
    if S.driver then ExitDrive(S.driver) end
    local v = BG.ReadJSON(IN .. "vehicles.json")
    if v and v.list then
        for _, c in ipairs(v.list) do
            if c.id then RemoveCar(c.id) end
        end
    end
    local id = PlayerCar()
    if id then RemoveCar(id) end
end)

Cmd("bg_reset", function()
    Send({ t = "vehicle_action", action = "reset", down = true })
    Send({ t = "vehicle_action", action = "reset", down = false })
end)

Cmd("bg_here", function(ply)
    local host = IsValid(ply) and ply or Host()
    if not IsValid(host) or not S.origin then return end
    local yaw = math.rad(host:EyeAngles().y)
    local fx, fy = math.cos(yaw), math.sin(yaw)
    local pos = ToBng(host:GetPos() + Vector(fx, fy, 0) * 200)
    Send({ t = "vehicle_place", pos = { pos[1], pos[2], pos[3] + 0.8 }, fwd = { fx, fy, 0 } })
end)

Cmd("bg_ignite", function()
    local id = PlayerCar()
    if id then Send({ t = "vehicle_fx", id = id, kind = "ignite" }) end
end)

Cmd("bg_extinguish", function()
    local id = PlayerCar()
    if id then Send({ t = "vehicle_fx", id = id, kind = "extinguish" }) end
end)

Cmd("bg_boom", function()
    local st = S.state
    if st and st.veh and st.veh.pos then
        Send({ t = "explosion", pos = st.veh.pos, power = 8 })
    end
end)

Cmd("bg_launch", function()
    local id = PlayerCar()
    if id then Send({ t = "impulse", id = id, dv = { 0, 0, 12 } }) end
end)

Cmd("bg_enter", function(ply)
    local host = IsValid(ply) and ply or Host()
    if not IsValid(host) then return end
    local id = NearestCar(host) or PlayerCar()
    if id then TryEnter(host, id) end
end)

Cmd("bg_exit", function()
    if S.driver then ExitDrive(S.driver) end
end)

Cmd("bg_next", function()
    local list = S.vehicles and S.vehicles.list
    if not list or #list == 0 then return end
    local cur = PlayerCar()
    local idx = 0
    for i, c in ipairs(list) do if c.id == cur then idx = i end end
    local nxt = list[(idx % #list) + 1]
    if nxt and nxt.id then
        S.carId = nxt.id
        Send({ t = "enter_vehicle", id = nxt.id })
    end
end)

Cmd("bg_action", function(ply, args)
    if args[1] then
        Send({ t = "vehicle_action", action = args[1], down = true })
        Send({ t = "vehicle_action", action = args[1], down = false })
    end
end)

Cmd("bg_vlist", function() Send({ t = "vlist_req" }) end)

Cmd("bg_vconfigs", function(ply, args)
    if args[1] then Send({ t = "vconfigs_req", model = args[1] }) end
end)

Cmd("bg_vtris", function(ply, args)
    local id = tonumber(args[1])
    if id then Send({ t = "vtris_req", id = id }) end
end)

Cmd("bg_export", function(ply, args)
    local id = tonumber(args[1]) or PlayerCar()
    if id then ExportCar(id) else BG.Log("no car to export") end
end)

Cmd("bg_status", function()
    BG.Log("stage=%s mode=%s relay=%s connected=%s ready=%s level=%s sid=%s rtt=%.1f ms",
        S.stage, S.mode, tostring(S.relayAlive), tostring(S.conn), tostring(S.ready), S.level, tostring(S.sid), S.rtt)
    BG.Log("origin=%s car=%s driver=%s", tostring(S.origin), tostring(PlayerCar()), tostring(S.driver))
    local st = S.state
    if st and st.veh then
        BG.Log("car %s %s speed %.1f m/s at %s", tostring(st.veh.id), tostring(st.veh.model), tonumber(st.veh.speed) or 0, table.concat(st.veh.pos or {}, ", "))
    end
end)

Cmd("bg_restart", function()
    -- redo the whole startup (terrain, car) as if BeamNG had just connected
    S.initSid = nil
end)

BG.Log("BeamGMod %s loaded (mode %s, model %s)", BG.VERSION, S.mode, S.model)
