-- Minecraft's real terrain as a BeamNG terrain, for Minecraft-hosted worlds with normal generation
-- (minecraft-host.md, "Terrain"). Minecraft's one-block steps are 0.71 m walls at the host scale,
-- too high for a car; as a terrain (a heightfield) the surface Minecraft sends is already smoothed
-- into slopes a car can climb.
--   * terrain_load {file, size, square, x0, y0, z0, height, sea?, id?}: Minecraft wrote a 16-bit heightmap PNG
--     (size x size samples, square metres apart, 0..65535 = 0..height metres) under /temp/mccross/;
--     it becomes a TerrainBlock with BeamNG's own terrain generator (util/terrainGenerator.lua:
--     new, createTerrain = TerrainBlock + importMaps, setTerrainOffset), its corner at (x0, y0, z0).
--     A new load replaces the old terrain; the same `id` again (sent twice) is answered, not rebuilt.
--     With `sea` (metres), a WaterPlane at that height: Minecraft's
--     sea and the rivers at sea level, where cars float, flood and stall as in BeamNG's own water.
--   * terrain_cells {x, y, w, h, z}: a w x h patch of samples changed (a block dug or placed), z in
--     metres above the terrain's z0, row by row: tb:setHeight + tb:updateGrid, as the editor's
--     importer does (editor/terrainAndRoadImporter.lua:111-116). updateGrid stalls BeamNG for
--     50-70 ms (measured: the state stream's gaps came every 250 ms, Minecraft's patch rate, while
--     driving into new chunks, and the car lagged back), so it waits (T.flush): one call for every
--     patch since, within NEAR_DELAY s when a patch is near a car, else after FAR_DELAY s.
--   * cars standing below the new surface are lifted onto it (core_terrain.getTerrainHeight).
--   * terrain_reset (a Minecraft world without a terrain opened) takes it out; it stays when the
--     client leaves, so cars on it stay where they are (bridge.lua dropClient).
--
-- Engine calls only go through `env`, so bridge/test_lua.py can run this with fakes:
--   env.create(file, square, height, x0, y0, z0) -> ok     env.remove()     env.water(z)     env.removeWater()
--   env.setHeight(x, y, z)    env.updateGrid(x0, y0, x1, y1)
--   env.heightAt(x, y) -> z or nil      env.cars() -> {{id, x, y, z}, ...}     env.moveCar(id, dz)
--   env.placeCar(id, x, y, z) -> true when the car was there to move: on the ground at (x, y),
--     repaired and still (spawn.safeTeleport)
--   env.box(x0, y0, z0, x1, y1, z1) -> id     env.deleteBox(id)   a static collision box (a stand)

local T = {}

T.MAX_SIZE = 4096
T.MAX_PATCH = 4096       -- samples per terrain_cells message
T.LIFT_CLEARANCE = 0.4   -- m: a lifted car is put this far above the surface
T.NEAR_M = 60            -- m: a patch this close to a car is driven on soon
T.NEAR_DELAY = 0.1       -- s
T.FAR_DELAY = 3.0        -- s
T.RESCUE_DEPTH = 2.0     -- m: a car's reference node this far under the surface is inside the ground
T.VOID_Z = -50           -- m: this far below smallgrid's floor (z 0) a car falls forever
T.EDGE = 4               -- m: a car rescued from outside the terrain goes this far inside its edge
T.RESCUE_COOLDOWN = 5    -- s: a car just put back is left alone this long (it is still settling)
-- The highest height a sample takes, as a share of the terrain's: BeamNG keeps heights in 16 bits,
-- and setHeight of exactly the terrain's height wraps to 0 (measured 2026-10-03: a sample set to
-- 159.286 m of a 39.286 + 120 m terrain read back 39.286), which turned the town's skyscrapers,
-- taller than the terrain's range, into pits at its bottom.
T.TOP = 65534 / 65535
T.STAND_HALF = 6         -- m: half the side of the stand a parked car keeps when the terrain moves away
T.STAND_DEPTH = 2        -- m

function T.new()
  return { info = nil, rescued = {}, stands = {} }
end

local inside   -- below

local function num(v) return type(v) == 'number' and v == v and v > -1e7 and v < 1e7 end

-- Returns nil, or an error string; nil, true when this load (its id) is the terrain already built.
function T.load(st, env, msg)
  if type(msg.file) ~= 'string' or not msg.file:match('^/temp/mccross/[%w_%-]+%.png$') then return 'bad file' end
  for _, k in ipairs({ 'size', 'square', 'x0', 'y0', 'z0', 'height' }) do
    if not num(msg[k]) then return 'bad ' .. k end
  end
  if msg.size < 128 or msg.size > T.MAX_SIZE or msg.square <= 0 or msg.height <= 0 then return 'out of range' end
  -- Minecraft sends a load again when the answer is late; building it twice would undo the patches
  -- sent in between (chunks loaded, blocks dug), which Minecraft won't send again
  local id = num(msg.id) and msg.id or nil
  if id ~= nil and st.info and st.info.id == id then return nil, true end
  T.keepCars(st, env, msg)
  if not env.create(msg.file, msg.square, msg.height, msg.x0, msg.y0, msg.z0) then return 'terrain not created' end
  st.dirty = nil   -- a new terrain has its whole grid
  st.info = { size = msg.size, square = msg.square, x0 = msg.x0, y0 = msg.y0, z0 = msg.z0, height = msg.height, id = id }
  if st.water then env.removeWater() st.water = nil end
  if num(msg.sea) then
    env.water(msg.sea)
    st.water = msg.sea
  end
  return nil
end

-- A patch of samples. Returns how many were set, or nil and why not.
function T.cells(st, env, msg)
  local i = st.info
  if not i then return nil, 'no terrain' end
  local x, y, w, h, z = msg.x, msg.y, msg.w, msg.h, msg.z
  if not (num(x) and num(y) and num(w) and num(h)) or type(z) ~= 'table' then return nil, 'bad patch' end
  if w < 1 or h < 1 or w * h > T.MAX_PATCH or #z < w * h or x < 0 or y < 0 or x + w > i.size or y + h > i.size then
    return nil, 'patch out of range'
  end
  local n = 0
  for row = 0, h - 1 do
    for col = 0, w - 1 do
      local v = z[row * w + col + 1]
      if num(v) then
        env.setHeight(x + col, y + row, math.max(0, math.min(i.height * T.TOP, v)))
        n = n + 1
      end
    end
  end
  local d = st.dirty
  if d then
    d[1], d[2], d[3], d[4] = math.min(d[1], x), math.min(d[2], y), math.max(d[3], x + w - 1), math.max(d[4], y + h - 1)
  else
    st.dirty = { x, y, x + w - 1, y + h - 1 }
    st.dirtySince = env.now()
    st.dirtyNear = false
  end
  if not st.dirtyNear then
    -- the patch in metres: grid column x is east of x0, grid row y north of y0
    local ax, ay = i.x0 + x * i.square, i.y0 + y * i.square
    local bx, by = i.x0 + (x + w - 1) * i.square, i.y0 + (y + h - 1) * i.square
    for _, c in ipairs(env.cars()) do
      if c.x and c.y then
        local dx = math.max(ax - c.x, 0, c.x - bx)
        local dy = math.max(ay - c.y, 0, c.y - by)
        if dx * dx + dy * dy < T.NEAR_M * T.NEAR_M then st.dirtyNear = true break end
      end
    end
  end
  return n
end

-- Every frame: the patches since the last call go into the grid at once, when due. Returns the
-- grid rectangle updated, or nil.
function T.flush(st, env)
  local d = st.dirty
  if not d or not st.info then return nil end
  local age = env.now() - st.dirtySince
  if age < (st.dirtyNear and T.NEAR_DELAY or T.FAR_DELAY) then return nil end
  st.dirty = nil
  env.updateGrid(d[1], d[2], d[3], d[4])
  return d
end

-- Cars more than half a metre below the surface (on the floor under it) go up onto it. Returns how many.
function T.liftCars(st, env)
  if not st.info then return 0 end
  local lifted = 0
  for _, c in ipairs(env.cars()) do
    local ground = env.heightAt(c.x, c.y)
    if ground and c.z < ground - 0.5 then
      env.moveCar(c.id, ground + T.LIFT_CLEARANCE - c.z)
      lifted = lifted + 1
    end
  end
  return lifted
end

inside = function(i, x, y)
  local far = (i.size - 1) * i.square
  return x >= i.x0 and y >= i.y0 and x <= i.x0 + far and y <= i.y0 + far
end

-- Before a new terrain (msg) replaces this one: cars standing on this one that the new one doesn't
-- cover get a flat stand at the height they stand at, so they stay parked instead of falling to
-- smallgrid's floor 60 m down (2026-10-03: the M3 parked at the gas station fell from z 62 to 0 when
-- the player went to the city and the terrain was built around him). Stands the new terrain covers
-- go. The boxes are in place before the terrain is swapped, and its setTerrainOffset rebuilds the
-- collision with them. Returns how many stands were added.
function T.keepCars(st, env, msg)
  st.stands = st.stands or {}
  local new = { size = msg.size, square = msg.square, x0 = msg.x0, y0 = msg.y0 }
  for k, s in pairs(st.stands) do
    if inside(new, s.x, s.y) then
      env.deleteBox(s.id)
      st.stands[k] = nil
    end
  end
  local old = st.info
  if not old then return 0 end
  local added = 0
  for _, c in ipairs(env.cars()) do
    if inside(old, c.x, c.y) and not inside(new, c.x, c.y) then
      local g = env.heightAt(c.x, c.y)
      local k = string.format('%d,%d', math.floor(c.x), math.floor(c.y))
      if g and c.z > g - T.RESCUE_DEPTH and c.z < g + 3 and not st.stands[k] then   -- on it, not flying off it
        local h = T.STAND_HALF
        st.stands[k] = { id = env.box(c.x - h, c.y - h, g - T.STAND_DEPTH, c.x + h, c.y + h, g), x = c.x, y = c.y }
        added = added + 1
      end
    end
  end
  return added
end

-- The height a new car is asked for at (x, y): never under the terrain. spawn.safeTeleport looks
-- for the ground with rays from the car down 10-50 m (spawn.lua:260-296), so a car asked for under
-- the surface (a garage under a lawn, the town's old pit) missed the terrain and stood on the
-- floor beneath it, from where the terrain shoved it through the floor (a G87 at z -19874,
-- 2026-10-03).
function T.spawnZ(st, env, x, y, z)
  local i = st.info
  if not i or not inside(i, x, y) then return z end
  local g = env.heightAt(x, y)
  if g and z < g + T.LIFT_CLEARANCE then return g + T.LIFT_CLEARANCE end
  return z
end

-- Cars inside the ground (RESCUE_DEPTH under the terrain) or, off the terrain, fallen through the
-- floor (below VOID_Z) go back onto the terrain, at their own x, y when that is on it, else just
-- inside its edge; with no terrain, back onto smallgrid's floor. Over the terrain only the surface
-- counts: a valley in a tall world can be far below z 0. Returns {{id, why, from, x, y, z}, ...}.
function T.rescue(st, env)
  local out = {}
  -- heights already set but not yet in the grid (T.flush): heightAt says new, the collision is old,
  -- and spawn.safeTeleport's rays would put the car back on the old surface, still buried (seen
  -- 2026-10-03: a 5 m patch over a parked pickup)
  if st.dirty then return out end
  local i = st.info
  local t = env.now()
  st.rescued = st.rescued or {}
  for _, c in ipairs(env.cars()) do
    local why
    if i and inside(i, c.x, c.y) then
      local g = env.heightAt(c.x, c.y)
      if g and c.z < g - T.RESCUE_DEPTH then why = c.z < T.VOID_Z and 'fell through the floor' or 'was inside the ground' end
    elseif c.z < T.VOID_Z then
      why = 'fell through the floor'
    end
    if why and st.rescued[c.id] and t - st.rescued[c.id] < T.RESCUE_COOLDOWN then why = nil end
    if why then
      local x, y, z = c.x, c.y, T.LIFT_CLEARANCE
      if i then
        local far = (i.size - 1) * i.square
        x = math.max(i.x0 + T.EDGE, math.min(i.x0 + far - T.EDGE, x))
        y = math.max(i.y0 + T.EDGE, math.min(i.y0 + far - T.EDGE, y))
        z = (env.heightAt(x, y) or 0) + T.LIFT_CLEARANCE
      end
      if env.placeCar(c.id, x, y, z) then
        st.rescued[c.id] = t
        out[#out + 1] = { id = c.id, why = why, from = c.z, x = x, y = y, z = z }
      end
    end
  end
  return out
end

function T.remove(st, env)
  st.dirty = nil
  for k, s in pairs(st.stands or {}) do
    env.deleteBox(s.id)
    st.stands[k] = nil
  end
  if not st.info then return false end
  env.remove()
  if st.water then env.removeWater() st.water = nil end
  st.info = nil
  return true
end

return T
