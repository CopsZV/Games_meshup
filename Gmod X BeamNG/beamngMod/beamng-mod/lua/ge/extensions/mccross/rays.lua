-- Batched terrain sampling for the crossover (message "raycols" -> "rayhits", protocol.md).
--
-- A request names up to MAX_COLUMNS 1x1 m columns relative to a base cell. For each column BeamNG
-- casts, against static collision and terrain (castRayStatic: C++, fast, distance only):
--   1. a vertical scan from zTop down to zBot that collects up to SURFACES surfaces: after each hit
--      the scan restarts MIN_GAP below it (no one fits in less headroom), so a ramp over the ground,
--      a bridge deck over a road or a roof over a tunnel each give their own surface
--   2. two horizontal probes across the column at zProbe, along +X and +Y -> walls (a hit must
--      repeat WALL_CHECK_UP higher, see probe())
-- A probe that hits is cast once more with Engine.castRay to read the surface normal, so ramps
-- aren't mistaken for walls. Work is spread over frames: at most BUDGET seconds per frame.

local R = {}

local MAX_COLUMNS = 1000      -- keeps the answer well under UDP's 64 KiB
local BUDGET = 0.002          -- s of raycasting per frame
local MISS = -9999            -- "no hit" in result arrays (JSON can't hold nil inside arrays)
local SURFACES = 4            -- surfaces per column, highest first, MISS-padded
local MIN_GAP = 1.8           -- m between two reported surfaces (player height)
local INSIDE_EPS = 0.05       -- m; a hit closer than this to the ray start = started inside geometry
local STRIDE = SURFACES + 4   -- per column: s1..s4, probeXHit, probeXNz, probeYHit, probeYNz

local bridge, logI, logW
local jobs = {}
local origin, dirDown, dirX, dirY, target = vec3(), vec3(0, 0, -1), vec3(1, 0, 0), vec3(0, 1, 0), vec3()
local totals = { columns = 0, rays = 0, slowRays = 0, ms = 0, jobs = 0 }

function R.init(b, li, lw)
  bridge, logI, logW = b, li, lw
end

local function num(v) return type(v) == 'number' and v * 0 == 0 end
local floor = math.floor
-- Millimetres are plenty and keep the JSON short.
local function mm(z) return floor(z * 1000 + 0.5) / 1000 end

function R.submit(c, msg)
  if not (num(msg.req) and num(msg.bx) and num(msg.by) and num(msg.zTop) and num(msg.zMid) and num(msg.zBot) and num(msg.zProbe)) then
    return false, 'missing or non-numeric fields'
  end
  if type(msg.cols) ~= 'table' or #msg.cols % 2 ~= 0 then return false, 'cols must be [dx, dy, ...]' end
  local n = #msg.cols / 2
  if n > MAX_COLUMNS then return false, 'too many columns (max ' .. MAX_COLUMNS .. ')' end
  if not (msg.zTop > msg.zBot) then return false, 'need zTop > zBot' end
  -- One job per client at a time: a new request replaces an unfinished one (latest wins).
  R.cancel(c)
  jobs[#jobs + 1] = { c = c, req = msg.req, bx = msg.bx, by = msg.by, zTop = msg.zTop, zMid = msg.zMid, zBot = msg.zBot,
    zProbe = msg.zProbe, cols = msg.cols, n = n, i = 0, res = {}, ms = 0, rays = 0, slow = 0, t0 = os.clockhp() }
  return true
end

function R.cancel(c)
  for i = #jobs, 1, -1 do
    if jobs[i].c == c then table.remove(jobs, i) end
  end
end

-- Horizontal probe from `origin` along `dir` (1 m). Returns hit (0/1) and the hit normal's z.
-- A wall has to block at two heights, zProbe and zProbe + WALL_CHECK_UP: stepped ramps and kerbs
-- have short vertical risers that a single low probe reads as a wall (gridmap_v2's slab ramp did).
local WALL_CHECK_UP = 0.8
local function probe(job, dir)
  local d = castRayStatic(origin, dir, 1.0)
  job.rays = job.rays + 1
  if d >= 1.0 then return 0, 0 end
  origin.z = origin.z + WALL_CHECK_UP
  local d2 = castRayStatic(origin, dir, 1.0)
  origin.z = origin.z - WALL_CHECK_UP
  job.rays = job.rays + 1
  if d2 >= 1.0 then return 0, 0 end
  target:set(origin.x + dir.x, origin.y + dir.y, origin.z + dir.z)
  local hit = Engine.castRay(origin, target, true, false)
  job.slow = job.slow + 1
  if hit and hit.norm then
    return 1, floor(hit.norm.z * 100 + 0.5) / 100
  end
  return 1, 0   -- castRayStatic saw something castRay didn't: treat it as a wall
end

local function runColumn(job, i)
  local x = job.bx + job.cols[2 * i + 1]
  local y = job.by + job.cols[2 * i + 2]
  local res = job.res
  local o = i * STRIDE
  -- 1. surfaces, top to bottom
  local top = job.zTop
  local n = 0
  while n < SURFACES and top > job.zBot do
    origin:set(x + 0.5, y + 0.5, top)
    local span = top - job.zBot
    local d = castRayStatic(origin, dirDown, span)
    job.rays = job.rays + 1
    if d >= span then break end
    -- A hit right at the start means the scan began inside something solid (under the ground,
    -- inside a ramp): nothing below can be stood on, so this column is done.
    if n > 0 and d < INSIDE_EPS then break end
    local z = top - d
    n = n + 1
    res[o + n] = mm(z)
    top = z - MIN_GAP
  end
  for k = n + 1, SURFACES do res[o + k] = MISS end
  -- 2. walls
  origin:set(x, y + 0.5, job.zProbe)
  res[o + SURFACES + 1], res[o + SURFACES + 2] = probe(job, dirX)
  origin:set(x + 0.5, y, job.zProbe)
  res[o + SURFACES + 3], res[o + SURFACES + 4] = probe(job, dirY)
end

function R.process()
  local job = jobs[1]
  if not job then return end
  local t0 = os.clockhp()
  while job.i < job.n do
    runColumn(job, job.i)
    job.i = job.i + 1
    if os.clockhp() - t0 > BUDGET then break end
  end
  job.ms = job.ms + (os.clockhp() - t0) * 1000
  if job.i < job.n then return end
  table.remove(jobs, 1)
  totals.columns = totals.columns + job.n
  totals.rays = totals.rays + job.rays
  totals.slowRays = totals.slowRays + job.slow
  totals.ms = totals.ms + job.ms
  totals.jobs = totals.jobs + 1
  local reply = { req = job.req, n = job.n, stride = STRIDE, surfaces = SURFACES, miss = MISS, ms = job.ms, rays = job.rays, slow = job.slow,
    wallMs = (os.clockhp() - job.t0) * 1000 }
  if job.n > 0 then reply.res = job.res end   -- an empty Lua table would encode as {} rather than []
  bridge.send(job.c, 'rayhits', reply)
end

function R.describe()
  if totals.rays == 0 then return 'none' end
  return string.format('%d jobs, %d columns, %d rays (%d slow), %.3f ms/100 rays', totals.jobs, totals.columns, totals.rays,
    totals.slowRays, totals.ms / totals.rays * 100)
end

return R
