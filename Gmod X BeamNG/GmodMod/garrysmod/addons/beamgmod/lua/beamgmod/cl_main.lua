-- BeamGMod client side: draws BeamNG's cars from their node positions, chase camera, HUD and the
-- car menu. Reads the relay's files directly (listen server / single player: same data folder).

if not CLIENT then return end

local U = BG.U
local IN = BG.IN

local C = {
    cars = {},          -- id -> { A, B (two newest vmesh messages), tris, xs, ys, zs ... }
    models = {},        -- BeamNG's car list (from the server)
    configs = {},       -- model -> configurations
    camMode = 1,        -- 1 chase, 2 orbit (mouse), 3 hood
    camYaw = nil,
    state = nil,
    vehicles = nil,
    vehModel = {},
    nextState = 0, nextVeh = 0, nextScan = 0,
    ids = {},
    msgUntil = 0, lastStage = "",
    gone = {},          -- id -> time until which a removed car is ignored (0 = until BeamNG lists it again)
}
BG.C = C

-- compiled car models (glb.bat mdl <car>): used instead of the low-poly mesh when they exist
local cvLow = CreateClientConVar("bg_lowpoly", "0", true, false, "1 = always draw BeamNG's low-poly mesh instead of the compiled model")
local cvMF = CreateClientConVar("bg_mdl_fwd", "0", true, false, "compiled model offset forward (metres)")
local cvMR = CreateClientConVar("bg_mdl_right", "0", true, false, "compiled model offset right (metres)")
local cvMU = CreateClientConVar("bg_mdl_up", "0", true, false, "compiled model offset up (metres)")
local cvMY = CreateClientConVar("bg_mdl_yaw", "0", true, false, "compiled model extra yaw (degrees, 180 if it faces backwards)")

local mdlCache = {}
local function ModelFor(model)
    if not model or model == "" then return nil end
    local name = string.lower((string.gsub(tostring(model), "[^%w_]", "_")))
    local e = mdlCache[name]
    local now = RealTime()
    if not e or (not e.ok and now - e.t > 5) then
        e = { ok = file.Exists("models/beamgmod/" .. name .. ".mdl", "GAME"), t = now }
        mdlCache[name] = e
    end
    return e.ok and ("models/beamgmod/" .. name .. ".mdl") or nil
end

concommand.Add("bg_mdl_rescan", function() mdlCache = {} end)

-- ------------------------------------------------------------------ BeamNG's own car model
-- The server asks BeamNG to export the car (vexport). The relay turns that glTF into
--   data/beamgmod/in/model_<id>.json -> models/<key>.json (+ <key>_<n>.dat triangles, tex/<key>_<i>.png)
-- Every flexbody part follows a frame of three of its BeamNG nodes, so the car dents and bends with the physics.
local cvNative = CreateClientConVar("bg_native", "1", true, false, "1 = draw BeamNG's own textured, damageable car model once the relay has converted it")
local cvUseMdl = CreateClientConVar("bg_use_mdl", "0", true, false, "1 = use compiled .mdl car models (static, wrong variant parts, no damage)")
local cvDbg = CreateClientConVar("bg_native_dbg", "0", false, false, "1 = flat colour per part (no textures), 2 = hide glass, 3 = glass only")

local nsx, nsy, nsz = 0.35, 0.25, 0.9
do
    local l = math.sqrt(nsx * nsx + nsy * nsy + nsz * nsz)
    nsx, nsy, nsz = nsx / l, nsy / l, nsz / l
end

local function NatFree(car)
    local nat = car.nat
    if not nat then return end
    for _, list in ipairs({ nat.opaque, nat.glass }) do
        for _, ch in ipairs(list) do
            if ch.mesh and ch.mesh.Destroy then pcall(ch.mesh.Destroy, ch.mesh) end
        end
    end
    car.nat = nil
end

local function NatMaterial(key, i, md)
    local m = CreateMaterial("bg_nat_" .. key .. "_" .. i, "UnlitGeneric", {
        ["$basetexture"] = "color/white",
        ["$vertexcolor"] = 1,
        ["$vertexalpha"] = 1,
        ["$nocull"] = 1,
        ["$translucent"] = md.glass and 1 or 0,
    })
    if md.tex and md.tex ~= "" then
        local src = Material("data/beamgmod/" .. md.tex, "smooth mips")
        if src and not src:IsError() then
            local t = src:GetTexture("$basetexture")
            if t and not t:IsError() then m:SetTexture("$basetexture", t) end
        end
    end
    return m
end

local function NatStart(car, id, rt)
    if rt < (car.natNext or 0) then return end
    car.natNext = rt + 1.5
    local raw = file.Read(IN .. "model_" .. id .. ".json", "DATA")
    if not raw or raw == "" then return end
    local m = util.JSONToTable(raw)
    if not m or not m.def or m.def == car.natDef then return end
    local defRaw = file.Read("beamgmod/" .. m.def, "DATA")
    if not defRaw or defRaw == "" then return end
    local d = util.JSONToTable(defRaw)
    if not d or not d.draws or not d.parts or not d.mats then return end
    NatFree(car)
    car.natDef = m.def
    local key = string.StripExtension(string.GetFileFromFilename(m.def))
    local nat = { d = d, key = key, di = 1, mats = {}, pm = {}, opaque = {}, glass = {}, done = false, nextChunk = 0 }
    for i, md in ipairs(d.mats) do nat.mats[i] = NatMaterial(key, i, md) end
    for i = 1, #d.parts do nat.pm[i] = Matrix() end
    car.nat = nat
    BG.Log("car %s: loading BeamNG's own model (%s triangles, %d parts)", tostring(id), tostring(d.tris), #d.parts)
end

local function NatChunk(car)
    local nat = car.nat
    local dr = nat.d.draws[nat.di]
    if not dr then
        nat.done = true
        BG.Log("BeamNG's own model is ready (%d draws)", #nat.opaque + #nat.glass)
        return
    end
    nat.di = nat.di + 1
    local md = nat.d.mats[dr.m + 1]
    local f = file.Open("beamgmod/" .. dr.f, "rb", "DATA")
    if not f then return end
    local count = f:ReadLong()
    if not count or count < 1 then f:Close() return end
    local glass = md and md.glass
    do   -- BeamNG's invisible helper meshes (collision / shadow shells) are never drawn
        local nm = string.lower(md and md.n or "")
        if nm == "invis" or string.find(nm, "invisible", 1, true) then f:Close() return end
    end
    local alpha = glass and 70 or 255
    local mt = nat.mats[dr.m + 1]
    local im = Mesh(mt)
    local v = Vector()
    mesh.Begin(im, MATERIAL_TRIANGLES, count)
    for _ = 1, count * 3 do
        local x, y, z = f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
        local nx, ny, nz = f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
        local u, w = f:ReadFloat(), f:ReadFloat()
        v.x, v.y, v.z = x, y, z
        mesh.Position(v)
        local d = nx * nsx + ny * nsy + nz * nsz
        if d < 0 then d = 0 end
        local s = (0.50 + 0.38 * d + 0.12 * (nz * 0.5 + 0.5)) * 255
        if s > 255 then s = 255 end
        mesh.Color(s, s, s, alpha)
        mesh.TexCoord(0, u, w)
        mesh.AdvanceVertex()
    end
    mesh.End()
    f:Close()
    local list = glass and nat.glass or nat.opaque
    list[#list + 1] = { mesh = im, mat = mt, p = dr.p + 1 }
end

local function NatStep(car, id, rt)
    if not cvNative:GetBool() then return end
    NatStart(car, id, rt)
    local nat = car.nat
    if nat and not nat.done and rt >= nat.nextChunk then
        nat.nextChunk = rt + 0.12
        local ok, err = pcall(NatChunk, car)
        if not ok then
            BG.Log("model chunk failed: %s", tostring(err))
            nat.done = true
        end
    end
end

-- world = O' + U * R * (v - o): the part's frame of three nodes now (O', t'1..3) against when it was exported (o, t1..3)
local function NatPart(m, p, xs, ys, zs)
    local f = p.f
    local n0, n1, n2 = f[1] + 1, f[2], f[3]
    local ox, oy, oz = xs[n0], ys[n0], zs[n0]
    if not ox then return end
    local r11, r12, r13, r21, r22, r23, r31, r32, r33 = 1, 0, 0, 0, 1, 0, 0, 0, 1
    if n1 >= 0 and xs[n1 + 1] and xs[n2 + 1] then
        n1, n2 = n1 + 1, n2 + 1
        local b = p.b
        local ax, ay, az = xs[n1] - ox, ys[n1] - oy, zs[n1] - oz
        local bx, by, bz = xs[n2] - ox, ys[n2] - oy, zs[n2] - oz
        local la = math.sqrt(ax * ax + ay * ay + az * az)
        if la < 1e-9 then la = 1e-9 end
        local t1x, t1y, t1z = ax / la, ay / la, az / la
        local cx, cy, cz = t1y * bz - t1z * by, t1z * bx - t1x * bz, t1x * by - t1y * bx
        local lc = math.sqrt(cx * cx + cy * cy + cz * cz)
        if lc < 1e-9 then lc = 1e-9 end
        local t3x, t3y, t3z = cx / lc, cy / lc, cz / lc
        local t2x, t2y, t2z = t3y * t1z - t3z * t1y, t3z * t1x - t3x * t1z, t3x * t1y - t3y * t1x
        r11 = t1x * b[1] + t2x * b[4] + t3x * b[7]
        r12 = t1x * b[2] + t2x * b[5] + t3x * b[8]
        r13 = t1x * b[3] + t2x * b[6] + t3x * b[9]
        r21 = t1y * b[1] + t2y * b[4] + t3y * b[7]
        r22 = t1y * b[2] + t2y * b[5] + t3y * b[8]
        r23 = t1y * b[3] + t2y * b[6] + t3y * b[9]
        r31 = t1z * b[1] + t2z * b[4] + t3z * b[7]
        r32 = t1z * b[2] + t2z * b[5] + t3z * b[8]
        r33 = t1z * b[3] + t2z * b[6] + t3z * b[9]
    end
    local o = p.o
    local tx = ox - U * (r11 * o[1] + r12 * o[2] + r13 * o[3])
    local ty = oy - U * (r21 * o[1] + r22 * o[2] + r23 * o[3])
    local tz = oz - U * (r31 * o[1] + r32 * o[2] + r33 * o[3])
    m:SetUnpacked(U * r11, U * r12, U * r13, tx, U * r21, U * r22, U * r23, ty, U * r31, U * r32, U * r33, tz, 0, 0, 0, 1)
end

local function DrawNativeOld(car, id)
    local nat = car.nat
    if not nat or not nat.done or (#nat.opaque + #nat.glass) == 0 then return false end
    local B = car.B
    if not B or B.n ~= nat.d.n then return false end   -- a different build of the car
    local xs, ys, zs = car.xs, car.ys, car.zs
    local parts, pm = nat.d.parts, nat.pm
    for i = 1, #parts do NatPart(pm[i], parts[i], xs, ys, zs) end
    for pass = 1, 2 do
        local list = pass == 1 and nat.opaque or nat.glass
        for j = 1, #list do
            local ch = list[j]
            render.SetMaterial(ch.mat)
            cam.PushModelMatrix(pm[ch.p])
            ch.mesh:Draw()
            cam.PopModelMatrix()
        end
    end
    return true
end

local function DrawNative(car, id)
    local nat = car.nat
    if not nat or not nat.done or (#nat.opaque + #nat.glass) == 0 then return false end
    local B = car.B
    if not B or B.n ~= nat.d.n then return false end   -- a different build of the car
    local xs, ys, zs = car.xs, car.ys, car.zs
    local parts, pm = nat.d.parts, nat.pm
    for i = 1, #parts do NatPart(pm[i], parts[i], xs, ys, zs) end
    local dbg = cvDbg:GetInt()
    for pass = 1, 2 do
        local list = pass == 1 and nat.opaque or nat.glass
        if not (pass == 2 and dbg == 2) and not (pass == 1 and dbg == 3) then
            -- opaque parts write depth so the body hides the inside; glass tests depth but doesn't write it
            render.OverrideDepthEnable(true, pass == 1)
            for j = 1, #list do
                local ch = list[j]
                if dbg == 1 then
                    render.SetColorMaterial()
                    local c = HSVToColor((ch.p * 47) % 360, 0.6, 1)
                    render.SetColorModulation(c.r / 255, c.g / 255, c.b / 255)
                else
                    render.SetMaterial(ch.mat)
                end
                cam.PushModelMatrix(pm[ch.p])
                ch.mesh:Draw()
                cam.PopModelMatrix()
            end
            render.OverrideDepthEnable(false)
        end
    end
    render.SetColorModulation(1, 1, 1)
    return true
end

concommand.Add("bg_native_reload", function()
    for _, car in pairs(C.cars) do NatFree(car) car.natDef = nil end
end)

local mat = CreateMaterial("beamgmod_flat_v1", "UnlitGeneric", {
    ["$basetexture"] = "color/white",
    ["$vertexcolor"] = 1,
    ["$vertexalpha"] = 1,
    ["$nocull"] = 1,
})

surface.CreateFont("BG_Big", { font = "Roboto", size = 56, weight = 800, antialias = true })
surface.CreateFont("BG_Mid", { font = "Roboto", size = 24, weight = 600, antialias = true })
surface.CreateFont("BG_Small", { font = "Roboto", size = 16, weight = 500, antialias = true })

-- ------------------------------------------------------------------ reading BeamNG's files

local function Fin(v)
    return type(v) == "number" and v == v and v > -1e5 and v < 1e5
end

local function ReadMesh(car, id)
    local raw = file.Read(IN .. "vmesh_" .. id .. ".json", "DATA")
    if not raw or raw == "" or raw == car.raw then return end
    local t = util.JSONToTable(raw)
    if not t or not t.p or not t.pos then return end
    local n = tonumber(t.n) or 0
    if n < 1 or #t.p < n * 3 then return end
    -- a car that blew up in BeamNG (NaN / absurd positions) must never reach the renderer
    if not (Fin(t.pos[1]) and Fin(t.pos[2]) and Fin(t.pos[3])) then return end
    if (tonumber(t.q) or 100) <= 0 then return end
    car.raw = raw
    car.rawT = RealTime()
    car.A = car.B
    car.B = {
        pos = t.pos, fwd = t.fwd or { 1, 0, 0 }, up = t.up or { 0, 0, 1 },
        p = t.p, q = tonumber(t.q) or 100, n = n, tv = tonumber(t.tv) or 0,
        ts = tonumber(t.ts) or 0, t = SysTime(),
    }
end

local function ReadTris(car, id, rt)
    local B = car.B
    if not B or B.tv == 0 or car.trisTv == B.tv then return end
    if rt < (car.nextTris or 0) then return end
    car.nextTris = rt + 0.4
    local raw = file.Read(IN .. "vtris_" .. id .. ".json", "DATA")
    if raw and raw ~= "" then
        local t = util.JSONToTable(raw)
        if t and t.tris and #t.tris >= 3 and tonumber(t.tv) == B.tv then
            local tris = t.tris
            local mx = 0
            for i = 1, #tris do
                local v = tris[i]
                if v > mx then mx = v end
            end
            if mx < B.n then
                car.tris = tris
                car.ntri = math.floor(#tris / 3)
                car.trisTv = B.tv
                return
            end
        end
    end
    if rt > (car.nextReq or 0) then
        car.nextReq = rt + 2.5
        RunConsoleCommand("bg_vtris", tostring(id))
    end
end

local function DropCar(id, car, untilT)
    if car then
        if IsValid(car.csm) then car.csm:Remove() end
        NatFree(car)
    end
    C.cars[id] = nil
    C.gone[id] = untilT
end

local function PollMeshes(rt, pid)
    if rt >= C.nextScan then
        C.nextScan = rt + 1
        local files = file.Find(IN .. "vmesh_*.json", "DATA")
        local ids = {}
        for _, f in ipairs(files or {}) do
            local id = tonumber(string.match(f, "^vmesh_(%-?%d+)%.json$"))
            if id then ids[#ids + 1] = id end
        end
        C.ids = ids
    end
    local inList = {}
    local list = C.vehicles and C.vehicles.list
    if list then
        for _, c in ipairs(list) do
            if c.id then
                inList[c.id] = true
                if c.model then C.vehModel[c.id] = c.model end
            end
        end
    end
    local haveList = list ~= nil
    for _, id in ipairs(C.ids) do
        local gu = C.gone[id]
        if gu and rt >= gu and inList[id] then
            C.gone[id] = nil
            gu = nil
        end
        local car = C.cars[id]
        if not car and not gu then
            -- a vmesh file nobody updates any more (removed car, older session) is not a car
            local fresh = file.Time(IN .. "vmesh_" .. id .. ".json", "DATA") >= os.time() - 4
            if inList[id] or fresh then
                car = { id = id, xs = {}, ys = {}, zs = {}, nextRead = 0 }
                C.cars[id] = car
            end
        end
        if car then
            if id == pid or rt >= car.nextRead then
                car.nextRead = rt + 0.066
                ReadMesh(car, id)
                ReadTris(car, id, rt)
                NatStep(car, id, rt)
            end
            if inList[id] then
                car.listed = true
                car.unlistedT = nil
            elseif haveList and car.listed then
                -- BeamNG listed this car and now does not: it was removed
                car.unlistedT = car.unlistedT or rt
                if rt - car.unlistedT > 1.5 then
                    DropCar(id, car, 0)
                    car = nil
                end
            end
            -- a car BeamNG no longer lists and no longer streams
            if car and car.rawT and rt - car.rawT > 3 and not inList[id] then
                DropCar(id, car, 0)
            end
        end
    end
end

hook.Add("Think", "BG_CL_Think", function()
    local rt = RealTime()
    if rt >= C.nextState then
        C.nextState = rt + 0.03
        local t = BG.ReadJSON(IN .. "state.json")
        if t then C.state = t end
    end
    if rt >= C.nextVeh then
        C.nextVeh = rt + 0.5
        local t = BG.ReadJSON(IN .. "vehicles.json")
        if t then C.vehicles = t end
    end
    local pid = C.state and C.state.veh and C.state.veh.id
    if GetGlobalBool("bg_have_origin", false) then PollMeshes(rt, pid) end
end)

-- ------------------------------------------------------------------ interpolation and drawing

-- Node positions in GMod space for this frame, blended between BeamNG's two newest messages.
local function Interp(car)
    local B = car.B
    if not B then return false end
    local fn = FrameNumber()
    if car.frame == fn then return car.ok end
    car.frame = fn
    car.ok = false

    local o = GetGlobalVector("bg_origin", vector_origin)
    local ox, oy, oz = o.x, o.y, o.z
    local n = B.n
    local bx, by, bz = B.pos[1], B.pos[2], B.pos[3]
    local bp, ib = B.p, 1 / B.q
    local xs, ys, zs = car.xs, car.ys, car.zs
    local sx, sy, sz = 0, 0, 0

    local A = car.A
    local a = 1
    if A and A.n == n and A.p and #A.p >= n * 3 then
        local dt = (B.ts - A.ts) / 1000
        if dt < 0.008 then dt = 0.008 elseif dt > 0.25 then dt = 0.25 end
        a = (SysTime() - B.t) / dt
        if a < 0 then a = 0 elseif a > 1 then a = 1 end
    else
        A = nil
    end

    if A then
        local ax, ay, az = A.pos[1], A.pos[2], A.pos[3]
        local ap, ia = A.p, 1 / A.q
        for i = 0, n - 1 do
            local k = i * 3
            local xb, yb, zb = bx + bp[k + 1] * ib, by + bp[k + 2] * ib, bz + bp[k + 3] * ib
            local xa, ya, za = ax + ap[k + 1] * ia, ay + ap[k + 2] * ia, az + ap[k + 3] * ia
            local x = ox + (xa + (xb - xa) * a) * U
            local y = oy + (ya + (yb - ya) * a) * U
            local z = oz + (za + (zb - za) * a) * U
            xs[i + 1], ys[i + 1], zs[i + 1] = x, y, z
            sx, sy, sz = sx + x, sy + y, sz + z
        end
    else
        for i = 0, n - 1 do
            local k = i * 3
            local x = ox + (bx + bp[k + 1] * ib) * U
            local y = oy + (by + bp[k + 2] * ib) * U
            local z = oz + (bz + bp[k + 3] * ib) * U
            xs[i + 1], ys[i + 1], zs[i + 1] = x, y, z
            sx, sy, sz = sx + x, sy + y, sz + z
        end
    end
    car.cx, car.cy, car.cz = sx / n, sy / n, sz / n
    do   -- the car's origin (where a compiled model is anchored), blended like the nodes
        local px, py, pz = bx, by, bz
        if A then
            px, py, pz = A.pos[1] + (bx - A.pos[1]) * a, A.pos[2] + (by - A.pos[2]) * a, A.pos[3] + (bz - A.pos[3]) * a
        end
        car.px, car.py, car.pz = ox + px * U, oy + py * U, oz + pz * U
    end

    local f, u = B.fwd, B.up
    local fx, fy, fz, ux, uy, uz = f[1], f[2], f[3], u[1], u[2], u[3]
    if A and A.fwd and A.up then
        fx, fy, fz = A.fwd[1] + (fx - A.fwd[1]) * a, A.fwd[2] + (fy - A.fwd[2]) * a, A.fwd[3] + (fz - A.fwd[3]) * a
        ux, uy, uz = A.up[1] + (ux - A.up[1]) * a, A.up[2] + (uy - A.up[2]) * a, A.up[3] + (uz - A.up[3]) * a
    end
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 1e-6 then fl = 1; fx = 1 end
    local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
    if ul < 1e-6 then ul = 1; uz = 1 end
    car.fx, car.fy, car.fz = fx / fl, fy / fl, fz / fl
    car.ux, car.uy, car.uz = ux / ul, uy / ul, uz / ul
    car.ok = true
    return true
end

local sunx, suny, sunz = 0.35, 0.25, 0.9
do
    local l = math.sqrt(sunx * sunx + suny * suny + sunz * sunz)
    sunx, suny, sunz = sunx / l, suny / l, sunz / l
end

local function ColorFor(model)
    if not model then return 150, 160, 175 end
    local h = 0
    for i = 1, #model do h = (h * 31 + string.byte(model, i)) % 360 end
    local c = HSVToColor(h, 0.55, 0.95)
    return c.r, c.g, c.b
end

local vp = Vector()

local function DrawModelCar(car, path)
    local e = car.csm
    if not IsValid(e) or car.csmPath ~= path then
        if IsValid(e) then e:Remove() end
        e = ClientsideModel(path, RENDERGROUP_OPAQUE)
        if not IsValid(e) then return false end
        e:SetNoDraw(true)
        car.csm, car.csmPath = e, path
    end
    local fwd = Vector(car.fx, car.fy, car.fz)
    local up = Vector(car.ux, car.uy, car.uz)
    local right = fwd:Cross(up)
    local pos = Vector(car.px, car.py, car.pz)
        + fwd * (cvMF:GetFloat() * U) + right * (cvMR:GetFloat() * U) + up * (cvMU:GetFloat() * U)
    local ang = fwd:AngleEx(up)
    local yaw = cvMY:GetFloat()
    if yaw ~= 0 then ang:RotateAroundAxis(up, yaw) end
    e:SetPos(pos)
    e:SetAngles(ang)
    e:SetupBones()
    e:DrawModel()
    return true
end

local function DrawCar(car, id, pid)
    if not Interp(car) then return end
    -- outside Source's coordinate range (or NaN) drawing can crash the game
    local cx, cy, cz = car.cx, car.cy, car.cz
    if cx ~= cx or cy ~= cy or cz ~= cz or math.abs(cx) > 15500 or math.abs(cy) > 15500 or math.abs(cz) > 15500 then return end
    if not cvLow:GetBool() and cvNative:GetBool() and DrawNative(car, id) then return end
    if not cvLow:GetBool() then
        local mdlName = (id == pid and C.state and C.state.veh and C.state.veh.model) or C.vehModel[id]
        local path = cvUseMdl:GetBool() and ModelFor(mdlName) or nil
        if path and DrawModelCar(car, path) then return end
    end
    if car.csm then
        if IsValid(car.csm) then car.csm:Remove() end
        car.csm, car.csmPath = nil, nil
    end
    if not car.tris then return end
    local tris, nt = car.tris, car.ntri
    local xs, ys, zs = car.xs, car.ys, car.zs
    local cx, cy, cz = car.cx, car.cy, car.cz
    local model = (id == pid and C.state and C.state.veh and C.state.veh.model) or C.vehModel[id]
    if car.colModel ~= model then
        car.colModel = model
        car.cr, car.cg, car.cb = ColorFor(model)
    end
    local br, bg, bb = car.cr, car.cg, car.cb

    render.SetMaterial(mat)
    local i = 0
    while i < nt do
        local count = math.min(1500, nt - i)
        mesh.Begin(MATERIAL_TRIANGLES, count)
        for j = 0, count - 1 do
            local k = (i + j) * 3
            local a, b, c = tris[k + 1] + 1, tris[k + 2] + 1, tris[k + 3] + 1
            local x1, y1, z1 = xs[a], ys[a], zs[a]
            local x2, y2, z2 = xs[b], ys[b], zs[b]
            local x3, y3, z3 = xs[c], ys[c], zs[c]
            local ux, uy, uz = x2 - x1, y2 - y1, z2 - z1
            local vx, vy, vz = x3 - x1, y3 - y1, z3 - z1
            local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            local l = math.sqrt(nx * nx + ny * ny + nz * nz)
            if l > 1e-9 then nx, ny, nz = nx / l, ny / l, nz / l end
            -- the winding of BeamNG's skin is unknown: point the normal away from the car's middle
            if nx * ((x1 + x2 + x3) / 3 - cx) + ny * ((y1 + y2 + y3) / 3 - cy) + nz * ((z1 + z2 + z3) / 3 - cz) < 0 then
                nx, ny, nz = -nx, -ny, -nz
            end
            local d = nx * sunx + ny * suny + nz * sunz
            if d < 0 then d = 0 end
            local s = 0.32 + 0.52 * d + 0.16 * (nz * 0.5 + 0.5)
            local r, g, bl = br * s, bg * s, bb * s
            if r > 255 then r = 255 end
            if g > 255 then g = 255 end
            if bl > 255 then bl = 255 end

            vp.x, vp.y, vp.z = x1, y1, z1
            mesh.Position(vp) mesh.Color(r, g, bl, 255) mesh.AdvanceVertex()
            vp.x, vp.y, vp.z = x2, y2, z2
            mesh.Position(vp) mesh.Color(r, g, bl, 255) mesh.AdvanceVertex()
            vp.x, vp.y, vp.z = x3, y3, z3
            mesh.Position(vp) mesh.Color(r, g, bl, 255) mesh.AdvanceVertex()
        end
        mesh.End()
        i = i + count
    end
end

concommand.Add("bg_native_info", function()
    local pid = C.state and C.state.veh and C.state.veh.id
    local car = pid and C.cars[pid]
    local nat = car and car.nat
    if not nat then BG.Log("no native model loaded for the car you drive (car %s)", tostring(pid)) return end
    BG.Log("native model: %d parts, %d opaque draws, %d glass draws, done=%s, nodes model/stream %s/%s",
        #nat.d.parts, #nat.opaque, #nat.glass, tostring(nat.done), tostring(nat.d.n), tostring(car.B and car.B.n))
    for i, md in ipairs(nat.d.mats) do
        local src = Material("data/beamgmod/" .. tostring(md.tex))
        BG.Log("  material %2d %-32s glass=%-5s texture=%s", i, tostring(md.n), tostring(md.glass), (src and not src:IsError()) and "ok" or "MISSING")
    end
end)

hook.Add("PostDrawOpaqueRenderables", "BG_Draw", function(depth, sky)
    if depth or sky then return end
    if not GetGlobalBool("bg_have_origin", false) then return end
    local pid = C.state and C.state.veh and C.state.veh.id
    for id, car in pairs(C.cars) do
        if car.B and not car.bad then
            local ok, err = pcall(DrawCar, car, id, pid)
            if not ok then
                car.bad = true
                BG.Log("drawing car %s failed: %s", tostring(id), tostring(err))
            end
        end
    end
end)

-- ------------------------------------------------------------------ camera

local function CycleCam()
    C.camMode = C.camMode % 3 + 1
    local names = { "chase", "orbit (mouse)", "hood" }
    chat.AddText(Color(255, 170, 60), "[BeamNG] ", color_white, "camera: " .. names[C.camMode])
end
concommand.Add("bg_cam", CycleCam)

hook.Add("PlayerButtonDown", "BG_CamKey", function(ply, btn)
    if btn ~= KEY_B or not IsFirstTimePredicted() then return end
    if not ply:GetNWBool("bg_drv") or ply:IsTyping() or vgui.CursorVisible() then return end
    CycleCam()
end)

hook.Add("CalcView", "BG_CalcView", function(ply, pos, ang, fov)
    if not ply:GetNWBool("bg_drv") then
        C.camYaw = nil
        return
    end
    local pid = C.state and C.state.veh and C.state.veh.id
    local car = pid and C.cars[pid]
    if not car or not car.B or car.bad or not Interp(car) then return end

    local fwd = Vector(car.fx, car.fy, car.fz)
    local up = Vector(car.ux, car.uy, car.uz)
    local cen = Vector(car.cx, car.cy, car.cz)
    local view = { drawviewer = false }

    if C.camMode == 3 then
        view.origin = cen + fwd * (0.1 * U) + up * (0.55 * U)
        view.angles = fwd:AngleEx(up)
        view.fov = 85
    elseif C.camMode == 2 then
        local a = ply:EyeAngles()
        view.origin = cen + Vector(0, 0, 1.0 * U) - a:Forward() * (6.5 * U)
        view.angles = a
        view.fov = 75
    else
        local target = fwd:Angle().y
        if C.camYaw then
            C.camYaw = C.camYaw + math.AngleDifference(target, C.camYaw) * math.min(1, 5 * FrameTime())
        else
            C.camYaw = target
        end
        local ay = Angle(0, C.camYaw, 0)
        view.origin = cen - ay:Forward() * (6.2 * U) + Vector(0, 0, 2.0 * U)
        view.angles = (cen + Vector(0, 0, 0.9 * U) - view.origin):Angle()
        view.fov = 75
    end
    return view
end)

hook.Add("HUDShouldDraw", "BG_HideHUD", function(name)
    local ply = LocalPlayer()
    if IsValid(ply) and ply:GetNWBool("bg_drv") then
        if name == "CHudWeaponSelection" or name == "CHudCrosshair" then return false end
    end
end)

-- ------------------------------------------------------------------ HUD

hook.Add("HUDPaint", "BG_HUD", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local sw, sh = ScrW(), ScrH()
    local rt = RealTime()

    local stage = GetGlobalString("bg_stage", "")
    if stage ~= C.lastStage then
        C.lastStage = stage
        C.msgUntil = rt + 9
    end
    if stage ~= "" and (rt < C.msgUntil or GetGlobalBool("bg_problem", false)) then
        draw.SimpleTextOutlined("BeamNG: " .. stage, "BG_Mid", 24, 24, Color(255, 200, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, Color(0, 0, 0, 220))
    end

    local st = C.state
    if ply:GetNWBool("bg_drv") and st and st.veh then
        local kmh = math.floor((tonumber(st.veh.speed) or 0) * 3.6 + 0.5)
        draw.SimpleTextOutlined(tostring(kmh), "BG_Big", sw / 2, sh - 150, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 2, Color(0, 0, 0, 220))
        draw.SimpleTextOutlined("km/h", "BG_Small", sw / 2, sh - 148, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, Color(0, 0, 0, 220))
        local d = st.dash
        if d then
            draw.SimpleTextOutlined(tostring(d.gear or "N"), "BG_Mid", sw / 2 + 120, sh - 160, Color(255, 200, 90), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, Color(0, 0, 0, 220))
            local frac = math.Clamp((tonumber(d.rpm) or 0) / math.max(1, tonumber(d.maxrpm) or 8000), 0, 1)
            local bw = 260
            surface.SetDrawColor(0, 0, 0, 170)
            surface.DrawRect(sw / 2 - bw / 2, sh - 122, bw, 10)
            surface.SetDrawColor(255 * frac + 60, 220 - 140 * frac, 60, 240)
            surface.DrawRect(sw / 2 - bw / 2, sh - 122, bw * frac, 10)
        end
        draw.SimpleTextOutlined("W/S gas/brake   A/D steer   SPACE handbrake   R flip+repair   LMB horn   RMB lights   B camera   E get out",
            "BG_Small", sw / 2, sh - 28, Color(230, 230, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, Color(0, 0, 0, 220))
    elseif GetGlobalBool("bg_have_origin", false) then
        local pp = ply:GetPos()
        local near = false
        for _, car in pairs(C.cars) do
            if car.cx and not car.bad then
                local dx, dy, dz = car.cx - pp.x, car.cy - pp.y, car.cz - pp.z
                if dx * dx + dy * dy + dz * dz < (8 * U) * (8 * U) then near = true break end
            end
        end
        if near then
            draw.SimpleTextOutlined("Press E to drive", "BG_Mid", sw / 2, sh * 0.62, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, Color(0, 0, 0, 220))
        end
    end
end)

-- ------------------------------------------------------------------ messages from the server

net.Receive("bg_msg", function()
    local kind = net.ReadString()
    local js = net.ReadString()
    local t = util.JSONToTable(js)
    if not t then return end
    if kind == "gone" then
        local id = tonumber(t.id)
        if id then
            DropCar(id, C.cars[id], RealTime() + 4)
        end
        return
    end
    if kind == "vlist" then
        if (tonumber(t.page) or 1) <= 1 then C.models = {} end
        for _, m in ipairs(t.models or {}) do C.models[#C.models + 1] = m end
        if C.onModels then C.onModels() end
    elseif kind == "vconfigs" then
        if t.model then
            if (tonumber(t.page) or 1) <= 1 or not C.configs[t.model] then C.configs[t.model] = {} end
            for _, c in ipairs(t.configs or {}) do table.insert(C.configs[t.model], c) end
            if C.onConfigs then C.onConfigs(t.model) end
        end
    end
end)

-- ------------------------------------------------------------------ car menu

local function BuildMenu(p)
    local selected, selectedCfg

    local status = vgui.Create("DLabel", p)
    status:Dock(TOP)
    status:SetTall(20)
    status:SetText("Pick a car on the left, a configuration on the right, then Spawn.")

    local search = vgui.Create("DTextEntry", p)
    search:Dock(TOP)
    search:SetTall(24)
    search:SetPlaceholderText("search cars...")

    local row2 = vgui.Create("DPanel", p)
    row2:Dock(BOTTOM)
    row2:SetTall(30)
    row2.Paint = function() end
    local row1 = vgui.Create("DPanel", p)
    row1:Dock(BOTTOM)
    row1:SetTall(30)
    row1.Paint = function() end

    local models = vgui.Create("DListView", p)
    models:Dock(LEFT)
    models:SetWide(340)
    models:SetMultiSelect(false)
    models:AddColumn("Car")
    models:AddColumn("Brand")
    models:AddColumn("Type")

    local configs = vgui.Create("DListView", p)
    configs:Dock(FILL)
    configs:SetMultiSelect(false)
    configs:AddColumn("Configuration")

    local function FillModels()
        if not IsValid(models) then return end
        models:Clear()
        local q = string.lower(search:GetValue() or "")
        for _, m in ipairs(C.models) do
            local name = tostring(m.name or m.k)
            local brand = tostring(m.brand or "")
            if q == "" or string.find(string.lower(name .. " " .. brand .. " " .. tostring(m.k)), q, 1, true) then
                local line = models:AddLine(name, brand, tostring(m.type or ""))
                line.k = m.k
            end
        end
        status:SetText(#C.models .. " cars from BeamNG")
    end
    C.onModels = FillModels
    search.OnChange = FillModels

    local function FillConfigs(model)
        if not IsValid(configs) or model ~= selected then return end
        configs:Clear()
        for _, c in ipairs(C.configs[model] or {}) do
            local line = configs:AddLine(tostring(c.name or c.k))
            line.k = c.k
        end
    end
    C.onConfigs = FillConfigs

    models.OnRowSelected = function(_, idx, line)
        selected = line.k
        selectedCfg = nil
        configs:Clear()
        if C.configs[selected] then
            FillConfigs(selected)
        else
            RunConsoleCommand("bg_vconfigs", tostring(selected))
        end
    end
    configs.OnRowSelected = function(_, idx, line) selectedCfg = line.k end

    local function Btn(parent, label, fn)
        local b = vgui.Create("DButton", parent)
        b:Dock(LEFT)
        b:SetWide(108)
        b:DockMargin(2, 2, 2, 2)
        b:SetText(label)
        b.DoClick = fn
        return b
    end
    Btn(row1, "Spawn selected", function()
        if selected then RunConsoleCommand("bg_spawn", tostring(selected), selectedCfg and tostring(selectedCfg) or "") end
    end)
    Btn(row1, "Spawn default", function()
        if selected then RunConsoleCommand("bg_spawn", tostring(selected)) end
    end)
    Btn(row1, "Remove car", function() RunConsoleCommand("bg_remove") end)
    Btn(row1, "Remove all", function() RunConsoleCommand("bg_removeall") end)
    Btn(row1, "Flip / repair", function() RunConsoleCommand("bg_here") end)
    Btn(row1, "Reset to start", function() RunConsoleCommand("bg_reset") end)
    Btn(row2, "Ignite", function() RunConsoleCommand("bg_ignite") end)
    Btn(row2, "Extinguish", function() RunConsoleCommand("bg_extinguish") end)
    Btn(row2, "Explode", function() RunConsoleCommand("bg_boom") end)
    Btn(row2, "Launch", function() RunConsoleCommand("bg_launch") end)
    Btn(row2, "Next car", function() RunConsoleCommand("bg_next") end)

    RunConsoleCommand("bg_vlist")
    FillModels()
end

concommand.Add("bg_menu", function()
    if IsValid(C.frame) then C.frame:Remove() end
    local f = vgui.Create("DFrame")
    f:SetSize(math.min(ScrW() - 40, 820), math.min(ScrH() - 40, 540))
    f:Center()
    f:SetTitle("BeamNG cars")
    f:MakePopup()
    C.frame = f
    BuildMenu(f)
end)

list.Set("DesktopWindows", "BeamGMod", {
    title = "BeamNG",
    icon = "icon16/car.png",
    width = 820,
    height = 540,
    onewindow = true,
    init = function(icon, window)
        window:SetTitle("BeamNG cars")
        BuildMenu(window)
    end,
})

concommand.Add("bg_help", function()
    BG.Log("E get in/out | W/S gas/brake | A/D steer | SPACE handbrake | R flip+repair | LMB horn | RMB lights | B camera")
    BG.Log("menu: C (context menu) -> BeamNG icon, or bg_menu. Console: bg_spawn <model> [config], bg_status, bg_steer_invert 1")
end)

BG.Log("client loaded; type bg_help in the console")
