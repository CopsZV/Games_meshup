-- What Minecraft items do to a BeamNG car (minecraft-host.md, "Items"): each effect is the vehicle
-- Lua BeamNG's own code uses for it, built here from checked numbers only (nothing from the
-- message is ever run as Lua):
--   ignite      fire.igniteVehicle()                        (vehicle/fire.lua:419, 471)
--   extinguish  fire.extinguishVehicle()                    (vehicle/fire.lua:453, 474)
--   dent        obj:applyForceVectorTime(node, force, dt) (vehicle/controller/couplings/
--               containerLockFollow.lua:97): the nodes within DENT_RADIUS of the hit get a speed
--               change inward along the blow, hardest at the centre, each pushed by its own mass
--               (obj:getNodeMass, vehicle/bdebugImpl.lua:777) times that speed over DENT_SECONDS, and
--               every other node an equal and opposite share, so the panel caves in and the car as a
--               whole doesn't move. A fixed 4000 N per damage point tore light door nodes off and
--               flung them 389 m (measured 2026-10-03), which drew as nothing. (A point force like
--               our TNT's moved the whole car instead: Jas, "it more moves a lot".)
--   tire        beamstate.deflateTire(id) for the wheel whose hub is nearest the hit, if within
--               TIRE_REACH (vehicle/beamstate.lua:517; hub world position = obj:getNodePosition(
--               wheel.node1) + obj:getPosition(), as vehicle/extensions/aeroDebug.lua:56)
local F = {}

F.DENT_RADIUS = 0.3          -- m around the hit that caves in
-- m/s inward at the centre per point of Minecraft damage (a diamond sword: 7). Measured on the stock
-- pickup's sides (a local dent test, 2026-10-03): damage 8 dents 1.7-2.6 cm, 12 up to
-- 3.6 cm; 0.5 m/s per point only flexed the panel (2 mm).
F.DENT_SPEED_PER_DAMAGE = 8.0
F.MAX_DENT_SPEED = 120       -- m/s: harder blows are capped, so nodes are pushed in, not flung off
F.DENT_SECONDS = 0.015
F.MAX_DAMAGE = 40
F.TIRE_REACH = 0.8          -- m from a wheel hub

local function num(v) return type(v) == 'number' and v == v and v > -1e6 and v < 1e6 end
local function vec(t) return type(t) == 'table' and num(t[1]) and num(t[2]) and num(t[3]) end

-- The vehicle Lua for one effect, or nil and why not.
function F.command(msg)
  local kind = msg.kind
  if kind == 'ignite' then return 'fire.igniteVehicle()' end
  if kind == 'extinguish' then return 'fire.extinguishVehicle()' end
  if kind ~= 'dent' and kind ~= 'tire' then return nil, 'unknown effect ' .. tostring(kind):sub(1, 20) end
  if not vec(msg.pos) then return nil, 'dent and tire need pos' end
  local x, y, z = msg.pos[1], msg.pos[2], msg.pos[3]
  local out = {}
  if kind == 'dent' then
    if not vec(msg.dir) then return nil, 'dent needs dir' end
    local dx, dy, dz = msg.dir[1], msg.dir[2], msg.dir[3]
    local n = math.sqrt(dx * dx + dy * dy + dz * dz)
    if n < 1e-6 then return nil, 'dir is zero' end
    dx, dy, dz = dx / n, dy / n, dz / n
    local dmg = math.max(0, math.min(F.MAX_DAMAGE, tonumber(msg.damage) or 0))
    if dmg > 0 then
      out[#out + 1] = string.format([[
local hx, hy, hz, dx, dy, dz, R, DV, T = %.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %.3f, %.3f, %.4f
local base = obj:getPosition()
local n = obj:getNodeCount()
local push, sum = {}, 0
for cid = 0, n - 1 do
  local p = obj:getNodePosition(cid) + base
  local d = math.sqrt((p.x - hx) ^ 2 + (p.y - hy) ^ 2 + (p.z - hz) ^ 2)
  if d < R then
    local f = DV * (1 - d / R) * obj:getNodeMass(cid) / T
    push[cid] = f
    sum = sum + f
  end
end
local others = n - tableSize(push)
if sum > 0 and others > 0 then
  local dir = vec3(dx, dy, dz)
  local back = dir * (-sum / others)
  for cid = 0, n - 1 do
    local f = push[cid]
    obj:applyForceVectorTime(cid, f and dir * f or back, T)
  end
end]], x, y, z, dx, dy, dz, F.DENT_RADIUS, math.min(F.MAX_DENT_SPEED, F.DENT_SPEED_PER_DAMAGE * dmg), F.DENT_SECONDS)
    end
  end
  if kind == 'tire' or msg.tire == true then
    out[#out + 1] = string.format([[
local tx, ty, tz = %.3f, %.3f, %.3f
local base = obj:getPosition()
local best, bestD = nil, %.3f
for id, w in pairs(v.data.wheels or {}) do
  if w.node1 then
    local p = obj:getNodePosition(w.node1) + base
    local d = (p.x - tx) ^ 2 + (p.y - ty) ^ 2 + (p.z - tz) ^ 2
    if d < bestD then best, bestD = id, d end
  end
end
if best then beamstate.deflateTire(best) end]], x, y, z, F.TIRE_REACH * F.TIRE_REACH)
  end
  if #out == 0 then return nil, 'nothing to do' end
  return table.concat(out, '\n')
end

return F
