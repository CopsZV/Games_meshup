-- When to rebuild BeamNG's static collision after Minecraft blocks change (blocks -> cubes).
--
-- be:reloadCollision() rebuilds the collision of the whole level on the game thread, whatever
-- changed: about 0.53 s on gridmap_v2 (~20 900 collision instances) for a single cube, measured
-- 2026-10-02. be:reloadStaticCollision() and be:reloadCollision(false, true|false) cost the same,
-- and without a rebuild a new cube has no collision at all (beamng-api-notes.md). Every rebuild is
-- a visible hitch, so this decides when one is worth it:
--   * at once when a car could reach the changed blocks within LOOKAHEAD seconds, or when a client
--     re-sent its full block set,
--   * otherwise once nothing has changed for QUIET seconds: one hitch per building burst instead
--     of one per block, or MAX_WAIT seconds after the first change if changes never pause,
--   * never more often than MIN_INTERVAL.
-- Terrain patches need a rebuild too: BeamNG's physics takes up new terrain heights only ~0.7 s after
-- the last tb:updateGrid anywhere, every call restarting the wait (measured 2026-10-05: the ground
-- lowered under a parked car, it fell 0.77 s later, or 0.55 s after patches 40 m away stopped). A
-- steady stream of patches kept the physics on the old ground and a car fell through a deck whose
-- heights BeamNG already had. A rebuild pushes them at once (the car fell 0.08 s later), 5-8 ms on
-- smallgrid with ~1100 cubes: after a terrain flush, at most every TERRAIN_INTERVAL, and never on
-- a level whose rebuild takes longer than TERRAIN_MAX_MS.
-- Pure Lua, no engine calls: tested by bridge/test_lua.py.

local S = {}

S.QUIET = 2.0          -- s without block changes before a batch is rebuilt anyway
S.MAX_WAIT = 8.0       -- s after a batch's first change it is rebuilt even if changes continue
S.LOOKAHEAD = 1.5      -- s of driving a car may be from the changed blocks before it needs them
S.MARGIN = 4.0         -- m from a car's reference node to its far end (a pickup is ~5.4 m long)
S.MIN_INTERVAL = 0.5   -- s between two rebuilds
S.TERRAIN_INTERVAL = 0.25   -- s between two rebuilds for terrain patches
S.TERRAIN_MAX_MS = 30       -- ms: a rebuild slower than this (a big level) is not worth it for terrain

function S.new()
  return { dirty = false, urgent = false, terrain = false, slow = false }
end

-- A terrain patch went into the grid (terrain.lua T.flush): the physics needs it.
function S.markTerrain(st)
  st.terrain = not st.slow
end

-- A rebuild took ms milliseconds: on a level where that is slow, terrain patches don't ask for one.
function S.reloaded(st, ms)
  st.slow = ms > S.TERRAIN_MAX_MS
  if st.slow then st.terrain = false end
end

-- Canonical cell (min corner) x, y, z changed at time t.
function S.mark(st, x, y, z, t)
  if not st.dirty then
    st.dirty = true
    st.firstChange = t
    st.minX, st.minY, st.minZ, st.maxX, st.maxY, st.maxZ = x, y, z, x, y, z
  else
    st.minX, st.minY, st.minZ = math.min(st.minX, x), math.min(st.minY, y), math.min(st.minZ, z)
    st.maxX, st.maxY, st.maxZ = math.max(st.maxX, x), math.max(st.maxY, y), math.max(st.maxZ, z)
  end
  st.lastChange = t
end

-- Everything may have changed (a full re-send or a clear): rebuild as soon as allowed.
function S.markAll(st, t)
  st.urgent = true
  st.lastChange = t
end

-- Distance from a point to the box of changed cells (each cell spans [min, min + 1]).
local function boxDistance(st, x, y, z)
  local dx = math.max(st.minX - x, 0, x - (st.maxX + 1))
  local dy = math.max(st.minY - y, 0, y - (st.maxY + 1))
  local dz = math.max(st.minZ - z, 0, z - (st.maxZ + 1))
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- cars: array of {x, y, z, speed}. Returns why a rebuild is due now ('resend', 'car near',
-- 'quiet'), or nil.
function S.due(st, cars, t, lastReload)
  if st.terrain and t - lastReload >= S.TERRAIN_INTERVAL then return 'terrain' end
  if not (st.dirty or st.urgent) then return nil end
  if t - lastReload < S.MIN_INTERVAL then return nil end
  if st.urgent then return 'resend' end
  for _, c in ipairs(cars) do
    if boxDistance(st, c[1], c[2], c[3]) - (c[4] or 0) * S.LOOKAHEAD <= S.MARGIN then return 'car near' end
  end
  if t - st.lastChange >= S.QUIET then return 'quiet' end
  if t - st.firstChange >= S.MAX_WAIT then return 'max wait' end
  return nil
end

function S.done(st)
  st.dirty, st.urgent, st.terrain = false, false, false
end

return S
