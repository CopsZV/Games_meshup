-- BeamNG side of the Minecraft crossover: a Game Engine Lua extension (name "mccross_bridge").
--
-- Talks to Minecraft (and beamng/bridge/bngdiag.py) over UDP on 127.0.0.1, protocol v1, see
-- beamng/docs/protocol.md. Everything here runs on BeamNG's game-engine thread and never
-- blocks: the socket is non-blocking (settimeout 0), raycasts run under a per-frame time budget,
-- and a client that goes quiet is dropped after CLIENT_TIMEOUT.
--
-- Every BeamNG API used here is listed with its source call site in beamng/docs/beamng-api-notes.md.

local M = {}

local TAG = 'mccross'
local PROTOCOL = 1
local DEFAULT_PORT = 47020
local STATE_INTERVAL = 1 / 60      -- s between STATE messages (capped by the frame rate)
local VEHICLES_INTERVAL = 1 / 20   -- s between VEHICLES messages
local VEHICLE_RANGE = 400          -- m around the camera for VEHICLES
local MAX_VEHICLES = 64
local CLIENT_TIMEOUT = 3.0         -- s without any message before a client is dropped
local CAMERA_HOLD = 0.5            -- s a camera pose stays in force without a newer one
local MAX_DRAIN = 256              -- datagrams handled per poll
local RECV_MAX = 8192              -- LuaSocket's UDP receive limit
local PERF_LOG_INTERVAL = 30       -- s between perf log lines

local socket = require('socket.socket')
local rays = nil                   -- loaded in onExtensionLoaded (fresh copy on extension reload)
local collsched = nil              -- same; when to rebuild collision (collsched.lua)
local vmesh = nil                  -- same; car shapes for Minecraft's cutouts (vmesh.lua)
local meshes = nil                 -- vmesh state
local carexport = nil              -- same; native car exports (carexport.lua)
local exports = nil                -- carexport state
local carselect = nil              -- same; car selection (carselect.lua)
local ground = nil                 -- same; Minecraft's ground as collision (ground.lua)
local carfx = nil                  -- same; what Minecraft items do to cars (carfx.lua)
local triggers = nil               -- same; door handles and switches for Minecraft's eye (triggers.lua)
local latches = nil                -- same; doors, bonnets and boots by their latches (latches.lua)
local latchCache = {}              -- vid -> {vdata, targets}
local groundSt = nil               -- ground state
local postSt = nil                 -- thin posts as boxes, a second ground.lua state (post_chunk)
local groundBy = nil               -- the client whose ground is in place
local restoreGround                -- defined with the ground handlers; dropClient needs it
local terrainMod = nil             -- Minecraft's real terrain as a BeamNG terrain (terrain.lua)
local terrainSt = nil
local terrainBy = nil              -- the client whose terrain is in place
local removeTerrain                -- defined with the terrain handlers; dropClient needs it

local udp = nil
local port = DEFAULT_PORT
local clients = {}                 -- "ip:port" -> client
local nextSid = 0
local camOwner = nil               -- client whose camera poses drive BeamNG's camera
local camTest = nil                -- built-in camera test (no client needed)
local lastState, lastVehicles = 0, 0
local fpsAvg = 0
local luaMsAvg = 0                 -- smoothed cost of this extension's onUpdate, ms
local frame = 0
local cameraApplied = { cseq = 0, frame = -1 }
local stats = { rx = 0, tx = 0, rxBytes = 0, txBytes = 0, bad = 0, stale = 0, unknown = 0, sendErr = 0, recvErr = 0,
                updMs = 0, updMax = 0, updN = 0, lastPerf = 0 }
local logTimes = {}
local markers = nil                -- debug spheres {pts, r, untilT} (alignment tests)
local pendingReload = false

local tmpDir, tmpUp = vec3(), vec3()

local function now() return os.clockhp() end

local function logI(msg) log('I', TAG, '[MCCROSS] ' .. msg) end
local function logW(msg) log('W', TAG, '[MCCROSS] ' .. msg) end
-- At most one line per `key` every `interval` seconds.
local function logRL(level, key, interval, msg)
  local t = now()
  if logTimes[key] and t - logTimes[key] < interval then return end
  logTimes[key] = t
  log(level, TAG, '[MCCROSS] ' .. msg)
end

local function startingArg(name)
  local args = Engine.getStartingArgs()
  local idx = args and tableFindKey(args, name)
  return idx and args[idx + 1] or nil
end

-- -- sending ------------------------------------------------------------------------------------

local MAX_DATAGRAM = 65000          -- UDP's limit is 65 507 bytes; bigger sends fail
local function sendTo(ip, rport, payload)
  local data = jsonEncode(payload)
  if #data > MAX_DATAGRAM then
    stats.sendErr = stats.sendErr + 1
    logRL('W', 'toobig', 10, string.format('not sent: %s message is %d bytes', tostring(payload.t), #data))
    return false
  end
  local ok = udp:sendto(data, ip, rport)
  if ok then
    stats.tx = stats.tx + 1
    stats.txBytes = stats.txBytes + #data
  else
    stats.sendErr = stats.sendErr + 1
  end
  return ok
end

local function send(c, t, payload)
  payload = payload or {}
  c.seq = c.seq + 1
  payload.v = PROTOCOL
  payload.t = t
  payload.sid = c.sid
  payload.seq = c.seq
  payload.ts = now() * 1000
  return sendTo(c.ip, c.port, payload)
end
M.send = send

-- BeamNG drops to 30 fps when its window loses focus (settings/defaults.json: fpsLimitBackgroundEnabled
-- true, fpsLimitBackground 30), and Minecraft has the focus during the crossover. Turning the limit
-- off entirely (as tech/techCore.lua does) let BeamNG run at 700+ fps and starve Minecraft of GPU
-- time, so while a client is connected the background limit is raised to CROSSOVER_FPS instead
-- (-mccrossfps N overrides), and the player's two settings are put back when the last client leaves.
local CROSSOVER_FPS = 120
local saved = nil   -- {enabled, fps} while we hold the limit
local function holdBackgroundLimitOff()
  if saved ~= nil then return end
  saved = { enabled = settings.getValue('fpsLimitBackgroundEnabled'), fps = settings.getValue('fpsLimitBackground') }
  local fps = tonumber(startingArg('-mccrossfps')) or CROSSOVER_FPS
  settings.setValue('fpsLimitBackground', fps)
  settings.setValue('fpsLimitBackgroundEnabled', true)
  logI(string.format('background FPS limit set to %d while the crossover is connected (was %s, %s)', fps,
    tostring(saved.enabled), tostring(saved.fps)))
end

local function restoreBackgroundLimit()
  if saved == nil then return end
  if saved.fps ~= nil then settings.setValue('fpsLimitBackground', saved.fps) end
  if saved.enabled ~= nil then settings.setValue('fpsLimitBackgroundEnabled', saved.enabled) end
  logI('background FPS limit restored')
  saved = nil
end

-- When Minecraft draws the cars itself, BeamNG's own picture is unused: render_main {on} turns
-- BeamNG's main world render off or on (setRenderWorldMain, as editor/renderTest.lua:39 and
-- editor/sceneView.lua:168 do). It comes back on when that client leaves or the extension unloads.
local renderOffBy = nil
local function setMainRender(on, why)
  local ok, err = pcall(setRenderWorldMain, on)
  logI('main world render ' .. (on and 'on' or 'off') .. ' (' .. why .. ')' .. (ok and '' or (': failed: ' .. tostring(err))))
  return ok
end

local function dropClient(c, why)
  clients[c.key] = nil
  if camOwner == c then
    camOwner = nil
    logI('camera released (' .. why .. ')')
  end
  if rays then rays.cancel(c) end
  if meshes then vmesh.unsubscribe(meshes, c) end
  if exports then carexport.forget(exports, c) end
  if groundBy == c then restoreGround('client left') end
  -- the terrain stays when Minecraft goes: taken out, every car on it fell to the floor below and
  -- the next load lifted it onto whatever was over it there (seen: the car on a garage roof after
  -- each restart). The next terrain_load replaces it; a world without one sends terrain_reset
  if terrainBy == c then
    terrainBy = nil
    if terrainSt and terrainSt.info then terrainSt.info.id = nil end   -- the next Minecraft's first load is new
  end
  if renderOffBy == c then
    renderOffBy = nil
    setMainRender(true, 'client left')
  end
  logI(string.format('client %s (%s, session %d) left: %s', c.name, c.key, c.sid, why))
  if not next(clients) then restoreBackgroundLimit() end
end

-- -- message handlers ----------------------------------------------------------------------------

local function isVec(t)
  return type(t) == 'table' and type(t[1]) == 'number' and type(t[2]) == 'number' and type(t[3]) == 'number'
    and t[1] * 0 == 0 and t[2] * 0 == 0 and t[3] * 0 == 0
end

local handlers = {}

handlers.ping = function(c, msg)
  send(c, 'pong', { echo = msg.ts, bts = now() * 1000 })
end

handlers.debug = function(c, msg)
  local text = tostring(msg.text or '')
  logI('debug from ' .. c.name .. ': ' .. text)
  ui_message('[MCCROSS] ' .. text, 5, 'mccross')
end

handlers.camera = function(c, msg)
  if not (isVec(msg.pos) and isVec(msg.fwd) and isVec(msg.up)) then
    stats.bad = stats.bad + 1
    logRL('W', 'badcam', 10, 'ignoring malformed camera message from ' .. c.name)
    return
  end
  local cam = c.cam or {}
  cam.px, cam.py, cam.pz = msg.pos[1], msg.pos[2], msg.pos[3]
  cam.fx, cam.fy, cam.fz = msg.fwd[1], msg.fwd[2], msg.fwd[3]
  cam.ux, cam.uy, cam.uz = msg.up[1], msg.up[2], msg.up[3]
  cam.fov = (type(msg.fovV) == 'number' and msg.fovV > 1 and msg.fovV < 170) and msg.fovV or nil
  cam.cseq = msg.cseq or msg.seq
  cam.t = now()
  c.cam = cam
  if camOwner ~= c then
    camOwner = c
    camTest = nil
    logI('camera now driven by ' .. c.name)
  end
end

handlers.camera_release = function(c, msg)
  if camOwner == c then
    camOwner = nil
    logI('camera released by ' .. c.name)
  end
end

handlers.camera_test = function(c, msg)
  local veh = getPlayerVehicle(0)
  local cx, cy, cz = 0, 0, 0
  if veh then cx, cy, cz = veh:getPositionXYZ() end
  camTest = { t0 = now(), seconds = math.min(tonumber(msg.seconds) or 8, 60), cx = cx, cy = cy, cz = cz }
  logI(string.format('camera test: orbiting (%.1f, %.1f, %.1f) for %.0f s', cx, cy, cz, camTest.seconds))
end

handlers.raycols = function(c, msg)
  local ok, err = rays.submit(c, msg)
  if not ok then
    send(c, 'error', { code = 'bad_request', req = msg.req, msg = err })
  end
end

-- Debug: draw spheres at canonical points for a while (camera alignment tests, see debugging.md).
handlers.markers = function(c, msg)
  if type(msg.pts) ~= 'table' or #msg.pts % 3 ~= 0 then return end
  local pts = {}
  for i = 1, #msg.pts, 3 do
    if type(msg.pts[i]) == 'number' then pts[#pts + 1] = vec3(msg.pts[i], msg.pts[i + 1], msg.pts[i + 2]) end
  end
  markers = { pts = pts, r = tonumber(msg.r) or 0.5, untilT = now() + (tonumber(msg.ttl) or 30) }
  logI(string.format('drawing %d markers for %.0f s', #pts, tonumber(msg.ttl) or 30))
end

-- Test: release the player vehicle's parking brake and push it along its heading at `speed` m/s,
-- the way BeamNG's crash tester starts its cars (editor/vehicleEditor/liveEditor/veCrashTester.lua).
-- Used to check that Minecraft's vehicle proxies track a moving car. Also the future impulse path.
handlers.vehicle_test = function(c, msg)
  local veh = getPlayerVehicle(0)
  if not veh then return end
  local speed = math.max(-30, math.min(30, tonumber(msg.speed) or 8))
  local dx, dy, dz = veh:getDirectionVectorXYZ()
  veh:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 1, dx * speed, dy * speed, dz * speed)
  logI(string.format('vehicle test: pushed %d (%s) to %.1f m/s', veh:getID(), veh:getJBeamFilename(), speed))
end

-- Minecraft explosion -> BeamNG physics. Every vehicle within reach gets a short-lived repulsive
-- "planet" at the blast centre (vehicle Lua beamstate.addPlanet(center, radius, mass, dt), the
-- mechanism BeamNG's own "explode vehicle" uses in core/funstuff.lua), so the blast pushes on
-- every node: cars are shoved, flipped and crumpled by BeamNG's soft-body physics. A blast inside a
-- car's footprint also sets it off (fire.explodeVehicle()).
local BLAST_MASS_PER_POWER = -3.5e12   -- per Minecraft explosion power (TNT = 4). Measured: -1.8e12 moved a pickup
                                       -- 2 m from TNT to only 5 m/s, so doubled
local BLAST_SOFT_RADIUS = 3.0          -- m, planet radius (force stops growing inside it)
local BLAST_SECONDS = 0.15
-- A blast this close to a car's body (m per unit of Minecraft power: TNT 4 -> 3 m) blows it up the
-- way BeamNG's own "explode vehicle" does (core/funstuff.lua:113-140): fire.explodeVehicle() and
-- beamstate.breakAllBreakgroups(). Farther away it only gets the push.
local BLOW_UP_PER_POWER = 0.75

-- Distance from (x, y, z) to a car's oriented box, 0 inside it (half axes: be:getObjectOOBBHalfAxisXYZ,
-- core/camera.lua:765-768).
local function distToCar(id, x, y, z)
  local cx, cy, cz = be:getObjectOOBBCenterXYZ(id)
  local dx, dy, dz = x - cx, y - cy, z - cz
  local d2 = 0
  for i = 0, 2 do
    local ax, ay, az = be:getObjectOOBBHalfAxisXYZ(id, i)
    local len = math.sqrt(ax * ax + ay * ay + az * az)
    if len > 1e-6 then
      local over = math.abs((dx * ax + dy * ay + dz * az) / len) - len
      if over > 0 then d2 = d2 + over * over end
    end
  end
  return math.sqrt(d2)
end

handlers.explosion = function(c, msg)
  if not isVec(msg.pos) then return end
  local power = math.max(0.1, math.min(20, tonumber(msg.power) or 4))
  local x, y, z = msg.pos[1], msg.pos[2], msg.pos[3]
  local reach = power * 4
  local hit, blown = 0, 0
  for id, veh in activeVehiclesIterator() do
    local cx, cy, cz = be:getObjectOOBBCenterXYZ(id)
    local d = math.sqrt((cx - x) ^ 2 + (cy - y) ^ 2 + (cz - z) ^ 2)
    if d < reach then
      veh:queueLuaCommand(string.format('beamstate.addPlanet(vec3(%.3f, %.3f, %.3f), %.2f, %.6e, %.3f)', x, y, z,
        BLAST_SOFT_RADIUS, BLAST_MASS_PER_POWER * power, BLAST_SECONDS))
      if distToCar(id, x, y, z) < power * BLOW_UP_PER_POWER then
        veh:queueLuaCommand('fire.explodeVehicle() beamstate.breakAllBreakgroups()')
        blown = blown + 1
      end
      hit = hit + 1
    end
  end
  logI(string.format('explosion power %.1f at (%.1f, %.1f, %.1f) from %s: %d vehicle(s) in reach, %d blown up', power, x, y, z, c.name, hit, blown))
end

-- Diagnostics: BeamNG's own picture of the scene ({name} -> shot {file}), to set beside
-- Minecraft's drawing of the same car (the camera follows Minecraft's; render_main must be on).
-- The game image only, written to the user folder: screenshot.doScreenshot with a path and an
-- extension, as core/vehicle/partmgmt.lua:679 calls it. Written a few frames later.
handlers.shot = function(c, msg)
  local name = tostring(msg.name or 'shot'):gsub('[^%w_-]', '_'):sub(1, 40)
  FS:directoryCreate('/temp/mccross/shots')
  local path = '/temp/mccross/shots/' .. name
  screenshot.doScreenshot(nil, nil, path, 'png')
  send(c, 'shot', { file = FS:getUserPath() .. path:sub(2) .. '.png' })
end

-- Diagnostics: what BeamNG has loaded for a material, read-only ({name} -> material_info).
local MATERIAL_FIELDS = { 'baseColorMap', 'baseColorFactor', 'colorPaletteMap', 'colorPaletteMapUseUV', 'instanceDiffuse',
  'paletteBaseColor', 'opacityMap', 'diffuseMap', 'colorMap', 'diffuseColor', 'metallicFactor', 'clearCoatFactor', 'detailMap' }
handlers.material_info = function(c, msg)
  local name = tostring(msg.name or ''):sub(1, 120)
  local mat = scenetree.findObject(name)
  if not mat then
    send(c, 'material_info', { name = name, found = false })
    return
  end
  local layers = {}
  for l = 0, 3 do
    local f = {}
    for _, k in ipairs(MATERIAL_FIELDS) do f[k] = tostring(mat:getField(k, l) or '') end
    layers[l + 1] = f
  end
  send(c, 'material_info', { name = name, found = true, class = tostring(mat:getClassName()), version = tostring(mat:getField('version', 0)),
    activeLayers = tostring(mat:getField('activeLayers', 0)), mapTo = tostring(mat:getField('mapTo', 0)), layers = layers })
end

-- Minecraft's car remover stick: the car is deleted, as BeamNG's own "remove current vehicle" does
-- (core/vehicles.lua:1853-1863, vehicle:delete()).
handlers.vehicle_remove = function(c, msg)
  local veh = getObjectByID(tonumber(msg.id) or -1)
  if not veh or tostring(veh:getClassName()) ~= 'BeamNGVehicle' then return end
  local name = veh:getJBeamFilename()
  -- The camera follows player 0's car: hand it another car (or the free camera, as removeCurrent
  -- does when none is left) first; deleting it under the camera made cameraUpdate.lua:48 throw.
  local pv = getPlayerVehicle(0)
  if pv and pv:getID() == veh:getID() then
    local other
    for id, v in activeVehiclesIterator() do
      if id ~= veh:getID() then other = v break end
    end
    if other then be:enterVehicle(0, other) else commands.setFreeCamera() end
  end
  veh:delete()
  logI(string.format('vehicle %s (%s) removed by %s', tostring(msg.id), name, c.name))
end

-- {id, kind: ignite|extinguish|dent|tire, pos?, dir?, damage?, tire?}: an item's effect (carfx.lua).
handlers.vehicle_fx = function(c, msg)
  local veh = getObjectByID(tonumber(msg.id) or -1)
  if not veh or tostring(veh:getClassName()) ~= 'BeamNGVehicle' then return end
  local cmd, why = carfx.command(msg)
  if not cmd then
    send(c, 'error', { code = 'bad_request', msg = why })
    return
  end
  veh:queueLuaCommand(cmd)
  logRL('I', 'carfx', 1, string.format('%s on %s (%s) from %s', tostring(msg.kind), tostring(msg.id), veh:getJBeamFilename(), c.name))
end

-- A Minecraft hit on a car (punch, sword, arrow): add dv (m/s, canonical) to the whole car, the way
-- BeamNG's own boost does (core/funstuff.lua: veh:applyClusterVelocityScaleAdd(refNode, 1, ...)).
local MAX_IMPULSE = 20
handlers.impulse = function(c, msg)
  local veh = getObjectByID(tonumber(msg.id) or -1)
  if not veh or not isVec(msg.dv) then return end
  local dx, dy, dz = msg.dv[1], msg.dv[2], msg.dv[3]
  local n = math.sqrt(dx * dx + dy * dy + dz * dz)
  if n > MAX_IMPULSE then dx, dy, dz = dx / n * MAX_IMPULSE, dy / n * MAX_IMPULSE, dz / n * MAX_IMPULSE end
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 1, dx, dy, dz)
  logRL('I', 'impulse', 1, string.format('impulse %.2f m/s on %d (%s) from %s', math.min(n, MAX_IMPULSE), veh:getID(), veh:getJBeamFilename(), c.name))
end

-- Minecraft blocks become BeamNG obstacles: a 1 m collision cube (TSStatic with smallgrid's
-- gm_cube_1m.dae, which ships a .cdae collision mesh; spawned the way main.lua's own test does)
-- per block, keyed by its canonical cell. Vehicle collision is rebuilt with be:reloadCollision()
-- (as dynamicProps/assemblySpline do). That rebuilds the whole level and stalls the game thread
-- (~0.53 s on gridmap_v2), so collsched.lua decides when a rebuild is due.
local CUBE_SHAPE = '/levels/smallgrid/art/shapes/misc/gm_cube_1m.dae'
local MAX_CUBES = 4000
local MAX_PLAUSIBLE_SPEED = 150          -- m/s; a just-teleported car reports ~52 000 for one frame
local CUBE_OFFSET = { 0.5, 0.5, 0.0 }   -- cell min corner -> cube origin: the mesh origin is its bottom centre (measured)
local cubes = {}                         -- "x,y,z" -> object id
local cubeCount = 0
local collisionBatch = nil              -- collsched state: cells changed since the last rebuild

local function cubeKey(x, y, z) return string.format('%d,%d,%d', x, y, z) end

local cellSize = 1.0                     -- metres per Minecraft block (blocks {cell}; > 1 block per m makes cars bigger)

local function addCube(x, y, z)
  local k = cubeKey(x, y, z)
  if cubes[k] or cubeCount >= MAX_CUBES then return false end
  local obj = createObject('TSStatic')
  obj:setField('shapeName', 0, CUBE_SHAPE)
  obj:setPosition(vec3((x + CUBE_OFFSET[1]) * cellSize, (y + CUBE_OFFSET[2]) * cellSize, (z + CUBE_OFFSET[3]) * cellSize))
  if cellSize ~= 1 then obj:setScale(vec3(cellSize, cellSize, cellSize)) end
  obj.canSave = false
  obj:registerObject('mccross_blk_' .. k:gsub(',', '_'):gsub('-', 'm'))
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(obj.obj) end
  cubes[k] = obj:getID()
  cubeCount = cubeCount + 1
  return true
end

local function removeCube(x, y, z)
  local k = cubeKey(x, y, z)
  local id = cubes[k]
  if not id then return false end
  local obj = scenetree.findObjectById(id)
  if obj then obj:delete() end
  cubes[k] = nil
  cubeCount = cubeCount - 1
  return true
end

-- Returns whether there was anything to delete.
local function clearCubes()
  local had = cubeCount > 0
  for k, id in pairs(cubes) do
    local obj = scenetree.findObjectById(id)
    if obj then obj:delete() end
  end
  cubes, cubeCount = {}, 0
  return had
end
M.clearCubes = clearCubes

-- Minecraft's ground (ground.lua): boxes are smallgrid's collision cube scaled (TSStatic setScale,
-- as editor/api/object.lua:786 scales objects; collision scales with it, measured with rays).
local groundBoxes = 0
local groundEnv = {
  box = function(x0, y0, z0, x1, y1, z1)
    local obj = createObject('TSStatic')
    obj:setField('shapeName', 0, CUBE_SHAPE)
    obj:setPosition(vec3((x0 + x1) / 2, (y0 + y1) / 2, z0))   -- the cube's origin is its bottom centre
    obj:setScale(vec3(x1 - x0, y1 - y0, z1 - z0))
    obj.canSave = false
    groundBoxes = groundBoxes + 1
    obj:registerObject('mccross_gnd_' .. groundBoxes)
    if scenetree.MissionGroup then scenetree.MissionGroup:addObject(obj.obj) end
    return obj:getID()
  end,
  delete = function(id)
    local obj = scenetree.findObjectById(id)
    if obj then obj:delete() end
  end,
  cars = function()
    local out = {}
    for id, veh in activeVehiclesIterator() do
      local _, _, z = veh:getPositionXYZ()
      out[#out + 1] = { id = id, z = z }
    end
    return out
  end,
  -- Straight up or down, facing kept: setPosRot with the half turn spawn.safeTeleport applies
  -- (spawn.lua: rot = quat(0,0,1,0) * rot before veh:setPosRot). safeTeleport itself would look for
  -- the ground and put the car back on the floor.
  moveCar = function(id, dz)
    local veh = getObjectByID(id)
    if not veh then return end
    local x, y, z = veh:getPositionXYZ()
    local rot = quat(0, 0, 1, 0) * quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
    veh:setPosRot(x, y, z + dz, rot.x, rot.y, rot.z, rot.w)
  end,
}

restoreGround = function(why)
  groundBy = nil
  if groundSt and ground.restore(groundSt, groundEnv) then
    collsched.markAll(collisionBatch, now())
    logI('Minecraft ground taken out, cars back on the floor (' .. why .. ')')
  end
end

-- {cx, cz, boxes: [x0,y0,z0, x1,y1,z1, ...]}: one Minecraft chunk's ground, canonical whole metres.
handlers.ground_chunk = function(c, msg)
  local cx, cz = math.floor(tonumber(msg.cx) or 0), math.floor(tonumber(msg.cz) or 0)
  local changed = ground.setChunk(groundSt, groundEnv, cx, cz, msg.boxes)
  groundBy = c
  -- before ground_on, cars still stand on the floor inside the new boxes: no rebuild until they are lifted
  if groundSt.on and changed > 0 and type(msg.boxes) == 'table' and #msg.boxes >= 6 then
    local t = now()
    collsched.mark(collisionBatch, msg.boxes[1], msg.boxes[2], msg.boxes[6], t)
    collsched.mark(collisionBatch, msg.boxes[1] + 15, msg.boxes[2] + 15, msg.boxes[6], t)
  end
  logRL('I', 'ground', 2, string.format('ground: chunk %d,%d now %d boxes (%d in all)', cx, cz, #(groundSt.chunks[string.format('%d,%d', cx, cz)] or {}),
    groundSt.count))
end

-- {top, lift}: the ground boxes around the players are in. Cars still on the floor go up by lift
-- onto Minecraft's surface (top), then collision is rebuilt with the boxes.
handlers.ground_on = function(c, msg)
  local top, lift = tonumber(msg.top), tonumber(msg.lift)
  if not top or not lift or top ~= top or lift ~= lift or math.abs(top) > 100 or lift < 0 or lift > 100 then return end
  local lifted = ground.turnOn(groundSt, groundEnv, top, lift)
  groundBy = c
  collsched.markAll(collisionBatch, now())
  logI(string.format('Minecraft ground in for %s: %d boxes, surface %.1f m above the floor, %d car(s) lifted onto it', c.name, groundSt.count, top, lifted))
end

handlers.ground_reset = function(c, msg)
  restoreGround('asked by ' .. c.name)
end

-- Thin posts in a terrain world: a lamp post, a bollard, a fence post is far thinner than a block,
-- and in the heightfield it filled a block and sloped out a block each way (a 0.36 m post was 1.2 m
-- wide at bumper height). Minecraft leaves them out of the terrain and sends each one near a car as
-- a box of its own size. {cx, cz, boxes: [x0,y0,z0, x1,y1,z1, ...]}: one chunk's posts, canonical
-- metres; a new list replaces the chunk's old one, an empty one removes them (ground.lua).
handlers.post_chunk = function(c, msg)
  local cx, cz = math.floor(tonumber(msg.cx) or 0), math.floor(tonumber(msg.cz) or 0)
  local changed = ground.setChunk(postSt, groundEnv, cx, cz, msg.boxes)
  if changed > 0 then
    local t = now()
    if type(msg.boxes) == 'table' and #msg.boxes >= 6 then
      for i = 1, #msg.boxes - 5, 6 do
        local x0, y0, z0 = tonumber(msg.boxes[i]), tonumber(msg.boxes[i + 1]), tonumber(msg.boxes[i + 2])
        if x0 and y0 and z0 then collsched.mark(collisionBatch, x0, y0, z0, t) end
      end
    else
      collsched.markAll(collisionBatch, t)   -- posts gone: a rebuild takes them out
    end
  end
  logRL('I', 'posts', 5, string.format('posts: chunk %d,%d, %d in all', cx, cz, postSt.count))
end

-- Dev: our objects in the scene by name (scenetree.findClassObjects, core/celestial.lua:233), against
-- what the bridge thinks it has: answered as scene_counts.
handlers.scene_count = function(c, msg)
  local n = { blk = 0, gnd = 0, other = 0 }
  for _, name in ipairs(scenetree.findClassObjects('TSStatic') or {}) do
    if name:find('^mccross_blk_') then n.blk = n.blk + 1
    elseif name:find('^mccross_gnd_') then n.gnd = n.gnd + 1
    else n.other = n.other + 1 end
  end
  send(c, 'scene_counts', { blk = n.blk, gnd = n.gnd, other = n.other, cubes = cubeCount, posts = postSt and postSt.count or 0,
    ground = groundSt and groundSt.count or 0 })
end

handlers.post_reset = function(c, msg)
  if postSt and ground.restore(postSt, groundEnv) then collsched.markAll(collisionBatch, now()) end
end

-- Minecraft's real terrain (terrain.lua), built with BeamNG's own terrain generator.
local terrainGen = nil
local terrainEnv = {
  create = function(file, square, height, x0, y0, z0)
    extensions.load('util/terrainGenerator')                 -- util/terrainGenerator.lua:9-22
    terrainGen = util_terrainGenerator.new({ terrainScale = square, terrainHeight = height, name = 'mccross' })
    terrainGen.heightMap = file
    terrainGen:createTerrain()
    terrainGen:setTerrainOffset(vec3(x0, y0, z0))             -- setPosition + be:reloadCollision
    return core_terrain.getTerrain() ~= nil
  end,
  remove = function()
    if terrainGen then terrainGen:resetTerrain(true) else local tb = core_terrain.getTerrain() if tb then tb:delete() end end
    terrainGen = nil
    be:reloadCollision()
  end,
  -- A WaterPlane with the fields the editor gives a new one (editor/createObjectTool.lua:706-737),
  -- except the depth ramp: the editor's depthcolor_ramp_b.color.png is not in the game (BeamNG logs
  -- "Texture missing"), gameengine.zip has core/art/water/depthcolor_ramp_b.png. Vehicles find water
  -- through the engine (obj:inWater, vehicle/powertrain/combustionEngine.lua:337).
  water = function(z)
    local old = scenetree.findObject('mccross_water')   -- one left by a reload of this extension
    if old then old:delete() end
    local w = createObject('WaterPlane')
    w:setField('baseColor', 0, '45 108 171 255')
    w:setField('rippleTex', 0, '/core/art/water/ripple_nm.normal.dds')
    w:setField('depthGradientTex', 0, 'core/art/water/depthcolor_ramp_b.png')
    w:setField('foamTex', 0, '/core/art/water/foam_b.color.png')
    w:setField('cubemap', 0, 'DefaultSkyCubemap')
    w:setPosition(vec3(0, 0, z))
    w.canSave = false
    w:registerObject('mccross_water')
    if scenetree.MissionGroup then scenetree.MissionGroup:addObject(w.obj) end
  end,
  removeWater = function()
    local w = scenetree.findObject('mccross_water')
    if w then w:delete() end
  end,
  now = function() return os.clockhp() end,
  setHeight = function(x, y, z) core_terrain.getTerrain():setHeight(x, y, z) end,
  updateGrid = function(x0, y0, x1, y1) core_terrain.getTerrain():updateGrid(vec3(x0, y0), vec3(x1, y1)) end,
  heightAt = function(x, y) return core_terrain.getTerrainHeight(vec3(x, y, 0)) end,
  cars = function()
    local out = {}
    for id, veh in activeVehiclesIterator() do
      local x, y, z = veh:getPositionXYZ()
      out[#out + 1] = { id = id, x = x, y = y, z = z }
    end
    return out
  end,
  moveCar = function(id, dz) groundEnv.moveCar(id, dz) end,
  -- on the ground at (x, y), repaired and still, facing as it did (spawn.safeTeleport with reset:
  -- setClusterPosRelRot + zero velocity, spawn.lua:532-535)
  placeCar = function(id, x, y, z)
    local veh = getObjectByID(id)
    if not veh then return false end
    local d = veh:getDirectionVector()
    d = vec3(d.x, d.y, 0)
    if d:length() < 1e-3 then d = vec3(0, 1, 0) end
    spawn.safeTeleport(veh, vec3(x, y, z), quatFromDir(d:normalized(), vec3(0, 0, 1)), nil, nil, nil, nil, true)
    return true
  end,
  -- stands for parked cars the terrain moved away from (T.keepCars): the ground's scaled cube
  box = function(x0, y0, z0, x1, y1, z1) return groundEnv.box(x0, y0, z0, x1, y1, z1) end,
  deleteBox = function(id) groundEnv.delete(id) end,
}

-- Twice a second: cars inside the ground or fallen through the floor go back on top (terrain.lua
-- T.rescue), and the clients hear about it (vehicle_rescued).
local RESCUE_INTERVAL = 0.5
local lastRescue = 0
local function rescueCars(t)
  if t - lastRescue < RESCUE_INTERVAL then return end
  lastRescue = t
  local ok, done = pcall(terrainMod.rescue, terrainSt, terrainEnv)
  if not ok then
    logRL('E', 'rescue', 30, 'car rescue failed: ' .. tostring(done))
    return
  end
  for _, r in ipairs(done) do
    local veh = getObjectByID(r.id)
    local model = veh and veh:getJBeamFilename() or '?'
    logI(string.format('vehicle %d (%s) %s (z %.1f): put back on the ground at (%.1f, %.1f, %.1f)', r.id, model, r.why, r.from, r.x, r.y, r.z))
    for _, c in pairs(clients) do
      send(c, 'vehicle_rescued', { id = r.id, model = model, why = r.why, from = r.from, pos = { r.x, r.y, r.z } })
    end
  end
end

removeTerrain = function(why)
  terrainBy = nil
  if terrainSt and terrainMod.remove(terrainSt, terrainEnv) then
    logI('Minecraft terrain taken out (' .. why .. ')')
  end
end

-- {file, size, square, x0, y0, z0, height}: Minecraft's surface as a heightmap PNG in /temp/mccross/.
handlers.terrain_load = function(c, msg)
  local t0 = os.clockhp()
  local ok, err, same = pcall(terrainMod.load, terrainSt, terrainEnv, msg)
  if not ok or err then
    send(c, 'error', { code = 'terrain_failed', msg = tostring(err) })
    logW('terrain from ' .. c.name .. ' failed: ' .. tostring(err))
    return
  end
  if same then
    send(c, 'terrain_loaded', { size = msg.size, id = msg.id, same = true })
    logI('terrain load ' .. tostring(msg.id) .. ' from ' .. c.name .. ' again: already built')
    return
  end
  terrainBy = c
  local lifted = terrainMod.liftCars(terrainSt, terrainEnv)
  collsched.markAll(collisionBatch, now())
  local ms = (os.clockhp() - t0) * 1000
  send(c, 'terrain_loaded', { size = msg.size, ms = ms, lifted = lifted, id = msg.id })
  logI(string.format('Minecraft terrain in for %s: %d x %d samples, %.3f m apart, %.0f ms, %d car(s) lifted onto it', c.name, msg.size, msg.size,
    msg.square, ms, lifted))
end

-- {x, y, w, h, z}: a patch of samples changed (a block dug or placed).
handlers.terrain_cells = function(c, msg)
  local n, err = terrainMod.cells(terrainSt, terrainEnv, msg)
  -- every patch is acknowledged (applied or not): Minecraft sends a chunk again when its ack is missing
  if msg.pid ~= nil then send(c, 'terrain_ack', { pid = msg.pid, n = n or 0, err = err }) end
  if not n then
    logRL('W', 'terraincells', 5, 'terrain cells from ' .. c.name .. ': ' .. tostring(err))
  else
    logRL('I', 'terraincellsok', 5, string.format('terrain: %d samples set at %s,%s (%sx%s)', n, tostring(msg.x), tostring(msg.y),
      tostring(msg.w), tostring(msg.h)))
  end
end

handlers.terrain_reset = function(c, msg)
  removeTerrain('asked by ' .. c.name)
end

-- Diagnostics: the terrain's height at points ({points: [[x, y], ...]} -> terrain_heights {z}).
handlers.terrain_height = function(c, msg)
  local z = {}
  for i, pt in ipairs(type(msg.points) == 'table' and msg.points or {}) do
    if i > 64 then break end
    local h = type(pt) == 'table' and tonumber(pt[1]) and tonumber(pt[2]) and core_terrain.getTerrainHeight(vec3(pt[1], pt[2], 0))
    z[i] = h or false
  end
  send(c, 'terrain_heights', { z = z })
end

-- {add: [x,y,z, ...], remove: [x,y,z, ...], clear: bool}, integer canonical cells (min corner).
handlers.blocks = function(c, msg)
  local t = now()
  local cell = tonumber(msg.cell)
  if cell and cell == cell and cell > 0.05 and cell <= 4 and cell ~= cellSize then
    clearCubes()   -- a different block size: the cubes already placed are the wrong size
    cellSize = cell
  end
  local cleared = msg.clear and clearCubes()
  local changed = 0
  for _, list in ipairs({ { msg.add, addCube }, { msg.remove, removeCube } }) do
    local cells, fn = list[1], list[2]
    if type(cells) == 'table' then
      for i = 1, #cells - 2, 3 do
        local x, y, z = math.floor(cells[i]), math.floor(cells[i + 1]), math.floor(cells[i + 2])
        if fn(x, y, z) then
          changed = changed + 1
          collsched.mark(collisionBatch, x * cellSize, y * cellSize, z * cellSize, t)
        end
      end
    end
  end
  -- A clear starts a full re-send (new session or level): rebuild once, right away.
  if msg.clear and (cleared or changed > 0) then collsched.markAll(collisionBatch, t) end
  logRL('I', 'blocks', 2, string.format('blocks: %d changed, %d cubes in BeamNG', changed, cubeCount))
end

local lastCollisionReload = 0
local collisionCars = {}                 -- {x, y, z, speed} per active vehicle, reused every frame
local function updateCollision()
  if not (collisionBatch.dirty or collisionBatch.urgent or collisionBatch.terrain) then return end
  local n = 0
  for _, veh in activeVehiclesIterator() do
    local px, py, pz = veh:getPositionXYZ()
    local vx, vy, vz = veh:getVelocityXYZ()
    local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    n = n + 1
    local car = collisionCars[n] or {}
    car[1], car[2], car[3], car[4] = px, py, pz, speed <= MAX_PLAUSIBLE_SPEED and speed or 0
    collisionCars[n] = car
  end
  for i = n + 1, #collisionCars do collisionCars[i] = nil end
  local why = collsched.due(collisionBatch, collisionCars, now(), lastCollisionReload)
  if not why then return end
  local t0 = os.clockhp()
  be:reloadCollision()
  lastCollisionReload = now()
  collsched.done(collisionBatch)
  collsched.reloaded(collisionBatch, (os.clockhp() - t0) * 1000)
  logRL('I', 'reloadcoll', 5, string.format('vehicle collision rebuilt in %.1f ms (%d cubes, %s)', (os.clockhp() - t0) * 1000, cubeCount, why))
end

-- Minecraft player gets into a vehicle (right-click on its proxy): BeamNG makes it the player's
-- vehicle (be:enterVehicle, as career/modules/inventory.lua does), so BeamNG's controls drive it.
handlers.enter_vehicle = function(c, msg)
  local veh = getObjectByID(tonumber(msg.id) or -1)
  if not veh then
    send(c, 'error', { code = 'bad_request', msg = 'no vehicle ' .. tostring(msg.id) })
    return
  end
  be:enterVehicle(0, veh)
  logI(string.format('player entered vehicle %d (%s) from %s', veh:getID(), veh:getJBeamFilename(), c.name))
end

-- Test automation: switch BeamNG to another level in freeroam (freeroam/freeroam.lua,
-- startFreeroamByName). This extension is "manual", so it survives the level change.
handlers.load_level = function(c, msg)
  local name = tostring(msg.level or '')
  if not name:match('^[%w_%-]+$') then
    send(c, 'error', { code = 'bad_request', msg = 'level must be a folder name like gridmap_v2' })
    return
  end
  local fr = rawget(_G, 'freeroam_freeroam')
  if not (fr and type(fr.startFreeroamByName) == 'function') then
    send(c, 'error', { code = 'unavailable', msg = 'freeroam is not loaded' })
    return
  end
  local ok, res = pcall(fr.startFreeroamByName, name)
  logI(string.format('load_level %s requested by %s: %s', name, c.name, ok and tostring(res) or ('error ' .. tostring(res))))
  if not ok or not res then
    send(c, 'error', { code = 'bad_request', msg = 'unknown level ' .. name })
  end
end

-- Test/demo: put the player vehicle at pos facing fwd, repaired (spawn.safeTeleport with
-- resetVehicle, as career/modules/inventory.lua moves cars). quatFromDir(fwd) through
-- safeTeleport's own 180 degree turn gives the requested heading (measured in four directions).
handlers.vehicle_place = function(c, msg)
  local veh = getPlayerVehicle(0)
  if not veh or not isVec(msg.pos) or not isVec(msg.fwd) then return end
  local fwd = vec3(msg.fwd[1], msg.fwd[2], msg.fwd[3])
  if fwd:length() < 1e-6 then return end
  local rot = quatFromDir(fwd, vec3(0, 0, 1))
  local z = terrainMod.spawnZ(terrainSt, terrainEnv, msg.pos[1], msg.pos[2], msg.pos[3])   -- never under the terrain
  spawn.safeTeleport(veh, vec3(msg.pos[1], msg.pos[2], z), rot, nil, nil, nil, nil, true)
  logI(string.format('vehicle %d placed at (%.1f, %.1f, %.1f)', veh:getID(), msg.pos[1], msg.pos[2], z))
end

-- Test/demo: drive the player vehicle through its normal input channels, as BeamNG's own
-- tech/impactgen/crashOutput.lua does (input.event("throttle", x, 1)). Values are clamped
-- numbers formatted into the command, never strings from the message.
local function clampNum(v, lo, hi)
  v = tonumber(v)
  if not v or v ~= v then return nil end
  return math.max(lo, math.min(hi, v))
end

-- filter: BeamNG's input filter, 0 keyboard (its key ramping), 1 gamepad (default), 2 direct
-- (lua/common/inputFilters.lua:7-11, vehicle/input.lua:573-684). ttl: when given, the inputs are
-- released if no newer vehicle_drive arrives within ttl seconds. input.event keeps the last value
-- forever, and a client that stops sending must not leave the throttle down.
local driveHold = nil   -- {vid, filter, untilT} while a ttl is running
local function driveInputs(veh, values, filter)
  local cmds = {}
  for _, k in ipairs({ { 'throttle', 0, 1 }, { 'brake', 0, 1 }, { 'steering', -1, 1 },
                       { 'clutch', 0, 1 }, { 'parkingbrake', 0, 1 } }) do
    local v = clampNum(values[k[1]], k[2], k[3])
    if v then cmds[#cmds + 1] = string.format('input.event(%q, %.3f, %d)', k[1], v, filter) end
  end
  if #cmds > 0 then veh:queueLuaCommand(table.concat(cmds, ' ')) end
end

handlers.vehicle_drive = function(c, msg)
  local veh = getPlayerVehicle(0)
  if not veh then return end
  local filter = clampNum(msg.filter, 0, 2)
  filter = filter and math.floor(filter) or 1
  driveInputs(veh, msg, filter)
  local ttl = clampNum(msg.ttl, 0.05, 5)
  driveHold = ttl and { vid = veh:getID(), filter = filter, untilT = now() + ttl } or nil
end

local function updateDriveHold()
  if not driveHold or now() < driveHold.untilT then return end
  local veh = getObjectByID(driveHold.vid)
  if veh then driveInputs(veh, { throttle = 0, brake = 0, steering = 0, clutch = 0 }, driveHold.filter) end
  logRL('I', 'drivehold', 5, 'vehicle_drive stopped arriving: inputs released')
  driveHold = nil
end

-- Car shapes for Minecraft's cutouts: {on, range} (vmesh.lua).
handlers.vmesh_sub = function(c, msg)
  if msg.on == false then
    vmesh.unsubscribe(meshes, c)
  else
    vmesh.subscribe(meshes, c, clampNum(msg.range, 10, 1000) or 200)
  end
end

handlers.vtris_req = function(c, msg)
  local id = tonumber(msg.id)
  if id then vmesh.resendTris(meshes, c, id) end
end

-- Called from a car's vehicle Lua (vmesh.lua FETCH) with its skin triangles.
function M.vmeshTris(vid, nodeCount, text)
  local ok, list = pcall(json.decode, text)
  if ok and type(list) == 'table' and meshes then
    vmesh.onTris(meshes, vid, nodeCount, list)
    logRL('I', 'vtris', 2, string.format('car %d: %d skin triangles, %d nodes', vid, math.floor(#list / 3), nodeCount))
  end
end

-- Native car models for Minecraft (carexport.lua): vexport {id?} exports that car, or the
-- player's car without an id. Answer: vexported {id, model, file, side (absolute paths), ms, bytes,
-- cached}: cached when the car was exported before and hasn't changed, answered at once.
handlers.vexport = function(c, msg)
  local veh = msg.id and getObjectByID(tonumber(msg.id) or -1) or getPlayerVehicle(0)
  if not veh or tostring(veh:getClassName()) ~= 'BeamNGVehicle' then
    send(c, 'error', { code = 'bad_request', id = tonumber(msg.id), msg = 'no vehicle to export' })
    return
  end
  local shape = meshes and meshes.shapes[veh:getID()]
  local err, cached = carexport.start(exports, c, veh, now(), logI, shape and shape.tv)
  if cached then
    send(c, 'vexported', cached)
  elseif err then
    err.id = veh:getID()   -- so the client knows which export this was
    send(c, 'error', err)
  end
end

-- Car selection (carselect.lua). Lists are sent in pages so a big modded list stays under the
-- datagram limit: {page, pages, ...}.
local LIST_PAGE = 40
local function sendPaged(c, t, key, list, extra)
  local pages = math.max(1, math.ceil(#list / LIST_PAGE))
  for page = 1, pages do
    local body = { page = page, pages = pages }
    for k, v in pairs(extra or {}) do body[k] = v end
    local part = {}
    for i = (page - 1) * LIST_PAGE + 1, math.min(#list, page * LIST_PAGE) do part[#part + 1] = list[i] end
    body[key] = part
    send(c, t, body)
  end
end

local function selectEnv()
  return {
    vehicles = core_vehicles,
    exists = function(p) return FS:fileExists(p) end,
    read = function(p)
      local f = io.open(p, 'rb')
      if not f then return nil end
      local data = f:read('*all')
      f:close()
      return data
    end,
    write = function(p, data)
      local f = io.open(p, 'wb')
      if not f then return end
      f:write(data)
      f:close()
    end,
    userPath = FS:getUserPath(),
    -- on the ground at pos facing fwd, repaired (as vehicle_place; career moves new cars this way)
    place = function(veh, pos, fwd)
      local f = vec3(fwd[1], fwd[2], 0)
      if f:length() < 1e-6 then f = vec3(0, 1, 0) end
      local z = terrainMod.spawnZ(terrainSt, terrainEnv, pos[1], pos[2], pos[3])   -- never under the terrain
      spawn.safeTeleport(veh, vec3(pos[1], pos[2], z), quatFromDir(f:normalized(), vec3(0, 0, 1)), nil, nil, nil, nil, true)
    end,
  }
end

handlers.vlist_req = function(c, msg)
  local t0 = now()
  local list = carselect.models(selectEnv())
  sendPaged(c, 'vlist', 'models', list)
  logI(string.format('vehicle list for %s: %d models in %.0f ms', c.name, #list, (now() - t0) * 1000))
end

handlers.vconfigs_req = function(c, msg)
  local list = carselect.configs(selectEnv(), msg.model)
  if not list then
    send(c, 'error', { code = 'bad_request', msg = 'unknown model ' .. tostring(msg.model):sub(1, 40) })
    return
  end
  sendPaged(c, 'vconfigs', 'configs', list, { model = msg.model })
end

handlers.vehicle_spawn = function(c, msg)
  local veh, err = carselect.spawn(selectEnv(), msg)
  if not veh then
    send(c, 'error', { code = 'spawn_failed', msg = err })
    return
  end
  send(c, 'vehicle_spawned', { id = veh:getID(), model = msg.model, config = msg.config, mode = msg.mode == 'replace' and 'replace' or 'new' })
  logI(string.format('%s %s (%s) for %s: vehicle %d', msg.mode == 'replace' and 'replaced with' or 'spawned', tostring(msg.model),
    tostring(msg.config), c.name, veh:getID()))
end

handlers.render_main = function(c, msg)
  local on = msg.on ~= false
  if setMainRender(on, 'asked by ' .. c.name) then renderOffBy = (not on) and c or nil end
end

-- Dashboard for Minecraft's HUD: the player car's gear, rpm and gearbox mode from its electrics
-- (vehicle/controller/vehicleController.lua:549-569), asked for 20 times a second and added to
-- STATE as "dash". wet: the car's reference node is under water (obj:inWater, as the engine's own
-- flooding check, vehicle/powertrain/combustionEngine.lua:337); flooded: the engine hydrolocked
-- (damageTracker "engine"/"engineHydrolocked", the same file :353).
local DASH_INTERVAL = 0.05
local DASH_CMD = [[
local e = electrics.values
local ref = v.data.refNodes and v.data.refNodes[0] and v.data.refNodes[0].ref
local dm, escName = controller.getController('driveModes'), nil
if dm then local d = dm.getDriveModeData(dm.getCurrentDriveModeKey()) escName = d and d.name and ('Mode: ' .. d.name) end
if not escName then local ec = controller.getController('esc') local cfg = ec and ec.getCurrentConfigData and ec.getCurrentConfigData() escName = cfg and cfg.name and ('ESC: ' .. cfg.name) end
obj:queueGameEngineLua(string.format('mccross_bridge.onDash(%d, %q)', vid, jsonEncode({ gear = e.gear, rpm = e.rpm, maxrpm = e.maxrpm, esc = escName,
  mode = e.gearboxMode, ign = e.ignitionLevel, wet = ref ~= nil and obj:inWater(ref) or false,
  flooded = damageTracker.getDamage('engine', 'engineHydrolocked') == true })))
]]
local lastDashAsk = 0
local dash = nil
function M.onDash(vid, text)
  local ok, d = pcall(json.decode, text)
  if ok and type(d) == 'table' then dash = { id = vid, data = d } end
end
local function askDash(t)
  if t - lastDashAsk < DASH_INTERVAL then return end
  lastDashAsk = t
  local veh = getPlayerVehicle(0)
  if veh then veh:queueLuaCommand('local vid = ' .. veh:getID() .. '\n' .. DASH_CMD) end
end

-- Driver actions from Minecraft's keys and controller: the calls BeamNG's own bindings make
-- (core/input/actions/vehicle.json:14-52, gameplay.json:4-6). {action, down}: down false = released.
local VEHICLE_ACTIONS = {
  shift_up = { 'if controller.mainController.shiftUpOnDown then controller.mainController.shiftUpOnDown() else controller.mainController.shiftUp() end',
               'if controller.mainController.shiftUpOnUp then controller.mainController.shiftUpOnUp() end' },
  shift_down = { 'if controller.mainController.shiftDownOnDown then controller.mainController.shiftDownOnDown() else controller.mainController.shiftDown() end',
                 'if controller.mainController.shiftDownOnUp then controller.mainController.shiftDownOnUp() end' },
  gear_reverse = { 'controller.mainController.shiftToGearIndex(-1)', 'controller.mainController.shiftToGearIndex(0)' },
  gear_1 = { 'controller.mainController.shiftToGearIndex(1)', 'controller.mainController.shiftToGearIndex(0)' },
  gear_2 = { 'controller.mainController.shiftToGearIndex(2)', 'controller.mainController.shiftToGearIndex(0)' },
  gear_3 = { 'controller.mainController.shiftToGearIndex(3)', 'controller.mainController.shiftToGearIndex(0)' },
  gear_4 = { 'controller.mainController.shiftToGearIndex(4)', 'controller.mainController.shiftToGearIndex(0)' },
  gear_5 = { 'controller.mainController.shiftToGearIndex(5)', 'controller.mainController.shiftToGearIndex(0)' },
  gear_6 = { 'controller.mainController.shiftToGearIndex(6)', 'controller.mainController.shiftToGearIndex(0)' },
  gearbox_mode = { 'controller.mainController.cycleGearboxModes()' },
  starter = { 'electrics.toggleIgnitionLevelOnDown()', 'electrics.toggleIgnitionLevelOnUp()' },
  horn = { 'electrics.horn(true)', 'electrics.horn(false)' },
  lights = { 'electrics.toggle_lights()' },
  recover = { 'recovery.startRecovering()', 'recovery.stopRecovering(0)' },
  -- BeamNG's toggleESCMode (core/input/actions/vehicle.json, Ctrl+Q): the next drive mode on cars
  -- that have them (they set ESC and traction control too), else the next ESC/TCS setting
  esc_mode = { "if controller.getController('driveModes') then controller.getController('driveModes').nextDriveMode() else controller.getControllerSafe('esc').toggleESCMode() end" },
}
handlers.vehicle_action = function(c, msg)
  local name = tostring(msg.action or '')
  local down = msg.down ~= false
  if name == 'reset' then
    -- BeamNG's R key (reset_physics): back to the spawn point, repaired
    if down then
      extensions.hook('trackVehReset')
      resetGameplay(0)
    end
    return
  end
  local a = VEHICLE_ACTIONS[name]
  if not a then
    send(c, 'error', { code = 'bad_request', msg = 'unknown vehicle action ' .. name:sub(1, 40) })
    return
  end
  local veh = getPlayerVehicle(0)
  local cmd = down and a[1] or a[2]
  if veh and cmd then
    if name == 'recover' and down then extensions.hook('trackVehReset') end   -- as recover_vehicle does
    veh:queueLuaCommand(cmd)
  end
end

-- Door handles, the bonnet, the boot, switches (BeamNG's vehicle triggers) from Minecraft: the
-- player's eye ray finds one (trigger_aim -> trigger_hit), and a press fires its action as BeamNG's
-- own click on it does (core_vehicleTriggers.triggerEvent, from onActionEvent). Ids go out as vid
-- and tr: v and t are the envelope's.
local function vecList(p) return { p.x, p.y, p.z } end
local function translate(s) return _tr and _tr(s, s) or s end   -- _tr: core_locales (ge/main.lua:977)
-- Action titles per vehicle data (they don't change; a replaced car has new vdata): vdata -> t -> titles or false
local titleCache = setmetatable({}, { __mode = 'k' })
local function cachedTitles(vdata, t)
  local byT = titleCache[vdata]
  if not byT then byT = {} titleCache[vdata] = byT end
  local titles = byT[t]
  if titles == nil then
    titles = triggers.actionTitles(vdata, t, translate) or false
    byT[t] = titles
  end
  return titles or nil
end
-- each car's latches (latches.lua), worked out once per vehicle data
local function latchTargets(vid, vdata)
  local e = latchCache[vid]
  if not e or e.vdata ~= vdata then
    e = { vdata = vdata, targets = latches.targets(vdata) }
    latchCache[vid] = e
  end
  return e.targets
end

local triggerEnv = {
  vehicles = function(o, near)
    local ids = {}
    for id in activeVehiclesIterator() do
      if distToCar(id, o[1], o[2], o[3]) < near then ids[#ids + 1] = id end
    end
    return ids
  end,
  triggers = function(vid, o, d, reach)
    local out = {}
    local veh = getObjectByID(vid)
    local vd = extensions.core_vehicle_manager.getVehicleData(vid)
    local vdata = vd and vd.vdata
    if not (veh and vdata) then return out end
    if not core_vehicle_triggerLabelPlacement then extensions.load('core_vehicle_triggerLabelPlacement') end
    local place = core_vehicle_triggerLabelPlacement
    for t, trg in pairs(place and type(vdata.triggers) == 'table' and vdata.triggers or {}) do
      local titles = cachedTitles(vdata, t)
      local obj = titles and veh:getTrigger(t)
      local c = obj and obj:getCenter()
      if c and triggers.nearRay(o, d, { c.x, c.y, c.z }, triggers.radius(trg.size) + 0.05, reach) then
        local bx, by, bz, hx, hy, hz = place.computeTriggerBasisAndHalfExtents(veh, trg)
        out[#out + 1] = { t = t, c = vecList(c), a = { vecList(bx), vecList(by), vecList(bz) }, h = { hx, hy, hz },
          name = tostring(trg.name or trg.id or t), actions = titles }
      end
    end
    -- doors, bonnet and boot by their latches (most cars have no triggers for them)
    local function pos(cid)
      local ok, x, y, z = pcall(veh.getNodePositionXYZ, veh, cid)
      if not ok or not x then return nil end
      local px, py, pz = veh:getPositionXYZ()
      return px + x, py + y, pz + z
    end
    for _, target in ipairs(latchTargets(vid, vdata)) do
      local box = latches.box(target, pos)
      if box and triggers.nearRay(o, d, box.c, latches.HALF * 1.75, reach) then out[#out + 1] = box end
    end
    return out
  end,
}

handlers.trigger_aim = function(c, msg)
  if not isVec(msg.o) or not isVec(msg.d) then return end
  local d = msg.d
  local len = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
  if len < 1e-6 then return end
  d = { d[1] / len, d[2] / len, d[3] / len }
  local hit = triggers.aim(triggerEnv, msg.o, d, clampNum(msg.reach, 0.5, 8) or triggers.REACH)
  if not hit then
    send(c, 'trigger_hit', { found = false, n = tonumber(msg.n) })
    return
  end
  send(c, 'trigger_hit', { found = true, n = tonumber(msg.n), vid = hit.v, tr = hit.t, name = hit.name, actions = hit.actions,
    c = hit.c, a = hit.a, h = hit.h, dist = hit.dist })
end

-- Dev: what trigger data a car has (counts, and the first few with their boxes)
handlers.trigger_list = function(c, msg)
  local vid = tonumber(msg.vid) or be:getPlayerVehicleID(0)
  local vd = extensions.core_vehicle_manager.getVehicleData(vid)
  local vdata = vd and vd.vdata
  local out = { vid = vid, hasVdata = vdata ~= nil, total = 0, linked = 0, sample = {} }
  if vdata then
    out.hasTriggers = type(vdata.triggers)
    out.hasLinks = type(vdata.triggerEventLinksDict)
    out.hasInputActions = type(vdata.inputActions)
    local veh = getObjectByID(vid)
    for t, trg in pairs(type(vdata.triggers) == 'table' and vdata.triggers or {}) do
      out.total = out.total + 1
      local titles = triggers.actionTitles(vdata, t, translate)
      if titles then out.linked = out.linked + 1 end
      if #out.sample < 6 then
        local obj = veh and veh:getTrigger(t)
        local cen = obj and obj:getCenter()
        out.sample[#out.sample + 1] = { t = tostring(t), tt = type(t), name = tostring(trg.name or trg.id), titles = titles,
          c = cen and vecList(cen), size = tostring(trg.size) }
      end
    end
    if type(vdata.triggerEventLinksDict) == 'table' then
      local keys = {}
      for k in pairs(vdata.triggerEventLinksDict) do if #keys < 6 then keys[#keys + 1] = tostring(k) .. ':' .. type(k) end end
      out.linkKeys = keys
    end
  end
  send(c, 'trigger_list', out)
end

handlers.trigger_use = function(c, msg)
  local vid = tonumber(msg.vid)
  local tr = tonumber(msg.tr) or msg.tr
  local a = tonumber(msg.action) or 0
  if not vid or tr == nil or a ~= math.floor(a) or a < 0 or a >= triggers.ACTIONS then return end
  local vd = extensions.core_vehicle_manager.getVehicleData(vid)
  if type(tr) == 'string' and tr:sub(1, 6) == 'latch:' then
    -- a latch (latches.lua): on the press only, as a click
    if msg.down == false or not (vd and vd.vdata) then return end
    local cmd = latches.command(tr, latchTargets(vid, vd.vdata))
    local veh = getObjectByID(vid)
    if cmd and veh then
      veh:queueLuaCommand(cmd)
      logI(string.format('%s on vehicle %d (%s) from %s', tr, vid, veh:getJBeamFilename(), c.name))
    end
    return
  end
  if not (vd and vd.vdata and type(vd.vdata.triggers) == 'table' and vd.vdata.triggers[tr]) then return end
  if not core_vehicleTriggers then extensions.load('core_vehicleTriggers') end
  core_vehicleTriggers.triggerEvent('action' .. a, msg.down == false and 0 or 1, tr, vid, vd.vdata)
end

local meshCars = {}
local function tickMeshes()
  if next(meshes.subs) == nil then return end
  local n = 0
  for _, veh in activeVehiclesIterator() do
    n = n + 1
    meshCars[n] = veh
  end
  for i = n + 1, #meshCars do meshCars[i] = nil end
  local cx, cy, cz = core_camera.getPositionXYZ()
  vmesh.tick(meshes, meshCars, cx, cy, cz, send)
end

-- Development: reload this extension from disk (after scripts\install-beamng-mod.ps1). Deferred to
-- the end of onUpdate so no code of the old module runs after it has been unloaded.
handlers.reload = function(c, msg)
  logI('reload requested by ' .. c.name)
  pendingReload = true
end

handlers.bye = function(c, msg)
  dropClient(c, 'said bye')
end

local function handleDatagram(data, ip, rport)
  stats.rx = stats.rx + 1
  stats.rxBytes = stats.rxBytes + #data
  local ok, msg = pcall(json.decode, data)
  if not ok or type(msg) ~= 'table' then
    stats.bad = stats.bad + 1
    logRL('W', 'badjson', 10, 'ignoring a datagram that is not JSON from ' .. tostring(ip) .. ':' .. tostring(rport))
    return
  end
  if msg.v ~= PROTOCOL then
    stats.bad = stats.bad + 1
    logRL('W', 'badver', 10, 'ignoring protocol v' .. tostring(msg.v) .. ' (we speak v' .. PROTOCOL .. ')')
    return
  end
  local key = ip .. ':' .. rport
  if msg.t == 'hello' then
    local c = clients[key]
    if not c then
      nextSid = nextSid + 1
      c = { sid = nextSid, ip = ip, port = rport, key = key, seq = 0, name = tostring(msg.client or '?'), inSeq = -1, dropped = 0 }
      clients[key] = c
      logI(string.format('client %s connected from %s, session %d', c.name, key, c.sid))
      holdBackgroundLimitOff()
    end
    c.lastRx = now()
    c.inSeq = tonumber(msg.seq) or -1
    -- ready: BeamNG's worldReadyState (main.lua) is 2 once loading has finished and the loading
    -- screen is gone. scripts/run-beamng.ps1 -Wait waits for it (the log is written minutes late).
    -- user: BeamNG's user folder on disk, where files for BeamNG go (the terrain heightmap) and
    -- come from (car exports); this machine only, the link is 127.0.0.1
    send(c, 'welcome', { bngVersion = beamng_version, level = getCurrentLevelIdentifier(), protocol = PROTOCOL,
      stateHz = math.floor(1 / STATE_INTERVAL + 0.5), port = port, ready = worldReadyState == 2, user = FS:getUserPath() })
    return
  end
  local c = clients[key]
  if not c or msg.sid ~= c.sid then
    stats.stale = stats.stale + 1
    sendTo(ip, rport, { v = PROTOCOL, t = 'error', sid = msg.sid or 0, seq = 0, ts = now() * 1000, code = 'unknown_session' })
    return
  end
  c.lastRx = now()
  local seq = tonumber(msg.seq)
  if seq then
    if seq <= c.inSeq then
      stats.stale = stats.stale + 1
      return
    end
    if c.inSeq >= 0 and seq - c.inSeq > 1 then c.dropped = c.dropped + (seq - c.inSeq - 1) end
    c.inSeq = seq
  end
  local h = handlers[msg.t]
  if h then
    -- A failing handler must never break this extension's frame update.
    local ok, err = pcall(h, c, msg)
    if not ok then
      stats.bad = stats.bad + 1
      logRL('E', 'handler:' .. tostring(msg.t), 10, 'handler for ' .. tostring(msg.t) .. ' failed: ' .. tostring(err))
    end
  else
    stats.unknown = stats.unknown + 1
    logRL('W', 'unknown:' .. tostring(msg.t), 30, 'unknown message type ' .. tostring(msg.t) .. ' from ' .. c.name)
  end
end

-- Drains the socket. Cheap when there's nothing to read; called from onUpdate and, right before
-- the camera is computed, from the camera filter so the newest pose is used.
local function poll()
  if not udp then return end
  for _ = 1, MAX_DRAIN do
    local data, ip, rport = udp:receivefrom(RECV_MAX)
    if data then
      handleDatagram(data, ip, rport)
    elseif ip == 'timeout' then
      return
    else
      -- Windows reports ICMP "port unreachable" from an earlier send as a receive error.
      stats.recvErr = stats.recvErr + 1
    end
  end
end
M.poll = poll

-- -- camera override (read by core/cameraModes/mccrossCamera.lua) -------------------------------

local testPose = {}
-- The pose to render this frame, or nil to leave BeamNG's own camera alone.
function M.cameraOverride()
  poll()
  if camTest then
    local t = now() - camTest.t0
    if t > camTest.seconds then
      camTest = nil
      logI('camera test finished')
      return nil
    end
    local a = t * 0.8
    local p = testPose
    p.px, p.py, p.pz = camTest.cx + 8 * math.cos(a), camTest.cy + 8 * math.sin(a), camTest.cz + 3
    local fx, fy, fz = camTest.cx - p.px, camTest.cy - p.py, camTest.cz + 0.5 - p.pz
    local n = math.sqrt(fx * fx + fy * fy + fz * fz)
    p.fx, p.fy, p.fz = fx / n, fy / n, fz / n
    p.ux, p.uy, p.uz = 0, 0, 1
    p.fov = 60
    p.cseq = -1
    return p
  end
  local c = camOwner
  if not c or not c.cam then return nil end
  if now() - c.cam.t > CAMERA_HOLD then
    logRL('I', 'camstale', 5, 'no fresh camera pose from ' .. c.name .. ' for ' .. CAMERA_HOLD .. ' s: BeamNG camera back to normal')
    return nil
  end
  return c.cam
end

function M.noteCameraApplied(cseq)
  cameraApplied.cseq = cseq or cameraApplied.cseq
  cameraApplied.frame = cseq and frame or cameraApplied.frame
end

-- -- state ---------------------------------------------------------------------------------------

local function vehicleInfo(veh, full)
  local px, py, pz = veh:getPositionXYZ()
  local dx, dy, dz = veh:getDirectionVectorXYZ()
  local ux, uy, uz = veh:getDirectionVectorUpXYZ()
  local vx, vy, vz = veh:getVelocityXYZ()
  tmpDir:set(dx, dy, dz)
  tmpUp:set(ux, uy, uz)
  local q = quatFromDir(tmpDir, tmpUp)
  local id = veh:getID()
  local info = { id = id, model = veh:getJBeamFilename(), pos = { px, py, pz }, rot = { q.x, q.y, q.z, q.w },
    fwd = { dx, dy, dz }, up = { ux, uy, uz }, vel = { vx, vy, vz }, speed = math.sqrt(vx * vx + vy * vy + vz * vz) }
  if full then
    info.center = { be:getObjectOOBBCenterXYZ(id) }
    info.axes = { { be:getObjectOOBBHalfAxisXYZ(id, 0) }, { be:getObjectOOBBHalfAxisXYZ(id, 1) }, { be:getObjectOOBBHalfAxisXYZ(id, 2) } }
    info.active = veh:getActive()
  end
  return info
end

local function buildState()
  local st = { level = getCurrentLevelIdentifier() or '', paused = simTimeAuthority.getPause(), fps = fpsAvg, frame = frame,
    luaMs = luaMsAvg }
  local veh = getPlayerVehicle(0)
  if veh then st.veh = vehicleInfo(veh, false) end
  if veh and dash and dash.id == veh:getID() then st.dash = dash.data end
  local px, py, pz = core_camera.getPositionXYZ()
  local fx, fy, fz = core_camera.getForwardXYZ()
  local up = core_camera.getUp()
  local qx, qy, qz, qw = core_camera.getQuatXYZW()
  st.cam = { pos = { px, py, pz }, fwd = { fx, fy, fz }, up = { up.x, up.y, up.z }, rot = { qx, qy, qz, qw },
    fov = core_camera.getFovDeg(), mode = core_camera.getActiveCamName() or '',
    ovr = cameraApplied.frame >= frame - 1, cseq = cameraApplied.cseq }
  return st
end

local function buildVehicles()
  local cx, cy, cz = core_camera.getPositionXYZ()
  local list = {}
  local playerId = be:getPlayerVehicleID(0)
  for id, veh in activeVehiclesIterator() do
    local px, py, pz = veh:getPositionXYZ()
    local d2 = (px - cx) ^ 2 + (py - cy) ^ 2 + (pz - cz) ^ 2
    if d2 < VEHICLE_RANGE * VEHICLE_RANGE and #list < MAX_VEHICLES then
      local info = vehicleInfo(veh, true)
      info.player = (id == playerId)
      list[#list + 1] = info
    end
  end
  return list
end

local function broadcast(t, makePayload)
  local any = next(clients)
  if not any then return end
  for _, c in pairs(clients) do
    send(c, t, makePayload())   -- send() writes envelope fields into the table: one table per client
  end
end

-- -- self-test of BeamNG's quaternion conventions (logged once at load) ---------------------------

local function selfTest()
  local function fmt(v) return string.format('(%.3f, %.3f, %.3f)', v.x, v.y, v.z) end
  local q = quatFromAxisAngle(vec3(0, 0, 1), math.pi / 2)
  local r = q * vec3(1, 0, 0)
  local conv = 'UNKNOWN'
  if math.abs(r.x) < 1e-4 and math.abs(r.y - 1) < 1e-4 then conv = 'Hamilton (q v q*)' end
  if math.abs(r.x) < 1e-4 and math.abs(r.y + 1) < 1e-4 then conv = 'inverse/Torque3D (q* v q): canonical = conjugate' end
  local e = quatFromDir(vec3(1, 0, 0), vec3(0, 0, 1))
  local f, u, rt = e * vec3(0, 1, 0), e * vec3(0, 0, 1), e * vec3(1, 0, 0)
  local okDir = math.abs(f.x - 1) < 1e-4 and math.abs(u.z - 1) < 1e-4 and math.abs(rt.y + 1) < 1e-4
  logI(string.format('self-test: quat convention %s [rotZ(+90)*X = %s]; quatFromDir(east, up) = (%.4f, %.4f, %.4f, %.4f): fwd %s up %s right %s %s',
    conv, fmt(r), e.x, e.y, e.z, e.w, fmt(f), fmt(u), fmt(rt), okDir and 'OK (camera looks +Y, up +Z)' or 'UNEXPECTED'))
  return okDir and conv ~= 'UNKNOWN'
end

-- -- extension hooks ---------------------------------------------------------------------------------

local function openSocket()
  port = tonumber(startingArg('-mccrossport')) or DEFAULT_PORT
  local s = socket.udp()
  local ok, err = s:setsockname('127.0.0.1', port)
  if not ok then
    logW('cannot listen on 127.0.0.1:' .. port .. ' (' .. tostring(err) .. '); crossover disabled')
    s:close()
    return false
  end
  s:settimeout(0)
  udp = s
  logI(string.format('listening on 127.0.0.1:%d (UDP, protocol v%d)', port, PROTOCOL))
  return true
end

-- Our TSStatics (names starting with prefix) that nobody keeps: a new instance of the extension owns
-- no cubes yet, so any left are strays (seen: 2996 cubes from a Minecraft that sent its blocks while
-- the level was still loading, 2026-10-06, each one slowing every collision rebuild). keep: ids to spare.
-- Returns how many went.
local function deleteStrays(prefix, keep)
  local n = 0
  for _, name in ipairs(scenetree.findClassObjects('TSStatic') or {}) do
    if name:sub(1, #prefix) == prefix then
      local obj = scenetree.findObject(name)
      if obj and not (keep and keep[obj:getID()]) then
        obj:delete()
        n = n + 1
      end
    end
  end
  return n
end

-- The objects these states own that still exist (made while the level was loading) go; the states start over.
local function deleteOwned()
  for _, id in pairs(cubes) do
    local obj = scenetree.findObjectById(id)
    if obj then obj:delete() end
  end
  for _, st in ipairs({ groundSt, postSt }) do
    for _, ids in pairs(st and st.chunks or {}) do
      for _, id in ipairs(ids) do groundEnv.delete(id) end
    end
  end
end

local function onExtensionLoaded()
  logI('BeamNG crossover extension loaded')
  logI('BeamNG version: ' .. tostring(beamng_version))
  package.loaded['extensions/mccross/rays'] = nil
  rays = require('extensions/mccross/rays')
  rays.init(M, logI, logW)
  package.loaded['extensions/mccross/collsched'] = nil
  collsched = require('extensions/mccross/collsched')
  collisionBatch = collsched.new()
  package.loaded['extensions/mccross/vmesh'] = nil
  vmesh = require('extensions/mccross/vmesh')
  meshes = vmesh.new()
  package.loaded['extensions/mccross/carexport'] = nil
  carexport = require('extensions/mccross/carexport')
  exports = carexport.new()
  package.loaded['extensions/mccross/carselect'] = nil
  carselect = require('extensions/mccross/carselect')
  package.loaded['extensions/mccross/ground'] = nil
  ground = require('extensions/mccross/ground')
  package.loaded['extensions/mccross/carfx'] = nil
  carfx = require('extensions/mccross/carfx')
  package.loaded['extensions/mccross/triggers'] = nil
  triggers = require('extensions/mccross/triggers')
  package.loaded['extensions/mccross/latches'] = nil
  latches = require('extensions/mccross/latches')
  latchCache = {}
  package.loaded['extensions/mccross/terrain'] = nil
  terrainMod = require('extensions/mccross/terrain')
  terrainSt = terrainMod.new()
  local kept = rawget(_G, 'mccrossKeptTerrain')
  rawset(_G, 'mccrossKeptTerrain', nil)
  if kept and core_terrain and core_terrain.getTerrain() then
    terrainSt.info, terrainSt.water, terrainSt.stands = kept.info, kept.water, kept.stands or {}
    logI('the terrain from before the reload is still in place')
  end
  groundSt = ground.new()
  postSt = ground.new()
  local keep = {}
  for _, stand in pairs(terrainSt.stands or {}) do keep[stand.id] = true end
  local strays = deleteStrays('mccross_blk_') + deleteStrays('mccross_gnd_', keep)
  if strays > 0 then
    pcall(function() be:reloadCollision() end)
    logI(string.format('%d stray cubes and boxes from before taken out', strays))
  end
  nextSid = math.floor(os.time() % 100000) * 100   -- a restarted BeamNG never reuses a session id
  selfTest()
  if openSocket() then
    logI('waiting for bridge...')
  end
end

local function onExtensionUnloaded()
  for _, c in pairs(clients) do
    send(c, 'bye', { reason = 'extension unloaded' })
  end
  clients = {}
  camOwner, camTest = nil, nil
  local okClear, hadCubes = pcall(clearCubes)
  local okGround, hadGround = pcall(function() return groundSt and ground.restore(groundSt, groundEnv) end)
  local okPosts, hadPosts = pcall(function() return postSt and ground.restore(postSt, groundEnv) end)
  -- the terrain stays for the next instance (a reload): taken out, every car on it fell 62 m to
  -- smallgrid's floor (seen 2026-10-03, a Cadillac wrecked by a dev reload)
  rawset(_G, 'mccrossKeptTerrain', terrainSt and terrainSt.info and { info = terrainSt.info, water = terrainSt.water, stands = terrainSt.stands } or nil)
  if (okClear and hadCubes) or (okGround and hadGround) or (okPosts and hadPosts) or (collisionBatch and collisionBatch.dirty) then
    pcall(function() be:reloadCollision() end)
  end
  restoreBackgroundLimit()
  if renderOffBy then
    renderOffBy = nil
    setMainRender(true, 'extension unloaded')
  end
  if udp then udp:close() end
  udp = nil
  logI('extension unloaded, socket closed')
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not udp then return end
  local t0 = now()
  frame = frame + 1
  if dtRaw and dtRaw > 0 then
    fpsAvg = fpsAvg > 0 and (fpsAvg * 0.95 + (1 / dtRaw) * 0.05) or (1 / dtRaw)
  end
  poll()
  for _, c in pairs(clients) do
    if t0 - c.lastRx > CLIENT_TIMEOUT then dropClient(c, 'timed out') end
  end
  rays.process()
  if terrainSt and terrainSt.dirty then
    local tg = now()
    local d = terrainMod.flush(terrainSt, terrainEnv)
    if d then
      collsched.markTerrain(collisionBatch)   -- the physics takes it up with the next collision rebuild
      logRL('I', 'terraingrid', 5, string.format('terrain grid %d,%d-%d,%d updated in %.1f ms', d[1], d[2], d[3], d[4], (now() - tg) * 1000))
    end
  end
  updateCollision()
  updateDriveHold()
  rescueCars(t0)
  carexport.update(exports, t0, send, logI)
  if next(clients) then
    if t0 - lastState >= STATE_INTERVAL * 0.9 then
      lastState = t0
      broadcast('state', buildState)
    end
    tickMeshes()   -- every frame: Minecraft blends car poses between these (MeshTimeline.java)
    askDash(t0)
    if t0 - lastVehicles >= VEHICLES_INTERVAL then
      lastVehicles = t0
      local list = buildVehicles()
      broadcast('vehicles', function() return { list = list, n = #list } end)
    end
  end
  if pendingReload then
    pendingReload = false
    extensions.reload('mccross_bridge')
    return   -- this module is gone now; the fresh copy logged its own startup
  end
  local ms = (now() - t0) * 1000
  luaMsAvg = luaMsAvg * 0.98 + ms * 0.02
  stats.updMs = stats.updMs + ms
  stats.updN = stats.updN + 1
  if ms > stats.updMax then stats.updMax = ms end
  if t0 - stats.lastPerf > PERF_LOG_INTERVAL then
    if stats.lastPerf > 0 and stats.updN > 0 then
      local n = 0
      for _ in pairs(clients) do n = n + 1 end
      logI(string.format('perf: %.0f fps, update avg %.3f ms max %.3f ms, clients %d, rx %d tx %d (%d KiB), bad %d stale %d, rays %s',
        fpsAvg, stats.updMs / stats.updN, stats.updMax, n, stats.rx, stats.tx, math.floor(stats.txBytes / 1024), stats.bad, stats.stale, rays.describe()))
    end
    stats.lastPerf = t0
    stats.updMs, stats.updN, stats.updMax = 0, 0, 0
  end
end

local markerColor = ColorF and ColorF(1, 0.1, 0.1, 0.8) or nil
local function onPreRender(dtReal, dtSim, dtRaw)
  if not markers then return end
  if now() > markers.untilT then
    markers = nil
    return
  end
  for _, p in ipairs(markers.pts) do
    debugDrawer:drawSphere(p, markers.r, markerColor)
  end
end

local function onClientPostStartMission(levelPath)
  -- the old level's objects went with it; any made while this one loaded (a Minecraft connected
  -- early) are still here and would be strays nobody deletes
  pcall(deleteOwned)
  cubes, cubeCount = {}, 0
  if ground then groundSt, groundBy, postSt = ground.new(), nil, ground.new() end   -- its boxes and planes too
  if terrainMod then terrainSt, terrainBy = terrainMod.new(), nil end   -- and its terrain
  collisionBatch = collsched.new()   -- and the new level builds its collision while loading
  logI('level loaded: ' .. tostring(getCurrentLevelIdentifier()))
end

-- Console helper: mccross_bridge.status()
function M.status()
  local lines = { string.format('port %d, frame %d, fps %.0f', port, frame, fpsAvg) }
  for _, c in pairs(clients) do
    lines[#lines + 1] = string.format('  %s %s session %d, age %.1f s, dropped %d%s', c.name, c.key, c.sid, now() - c.lastRx, c.dropped,
      camOwner == c and ', drives camera' or '')
  end
  local s = table.concat(lines, '\n')
  print(s)
  return s
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onClientPostStartMission = onClientPostStartMission

return M
