-- Minecraft's ground as BeamNG collision, for Minecraft-hosted worlds (minecraft-host.md, "Holes").
-- smallgrid's floor is solid at z = 0 everywhere. It can't be lowered or removed: moving or even
-- deleting the level's GroundPlanes leaves the floor where it is (measured with rays and a car).
-- So the floor is used as Minecraft's bedrock: Minecraft's ground surface sits `top` metres above
-- it (BngWorld.HOST_REGION), and the dirt and grass in between come as boxes.
--   * ground_chunk {cx, cz, boxes}: one 16 x 16 chunk's boxes, merged by Minecraft (a flat chunk is
--     one box, a hole splits it into a few). Each box is smallgrid's 1 m collision cube scaled to
--     size. A new list for a chunk replaces the old one. A hole is just missing boxes: a car drops
--     onto the floor, the bedrock.
--   * ground_on {top, lift}: the ground is in. Cars still on the floor are lifted onto it.
--   * when the client leaves, the boxes go and cars on the ground are lowered back to the floor.
--
-- Engine calls only go through `env`, so bridge/test_lua.py can run this with fakes:
--   env.box(x0, y0, z0, x1, y1, z1) -> object id     env.delete(id)
--   env.cars() -> {{id, z}, ...}     env.moveCar(id, dz)

local G = {}

G.MAX_BOXES = 6000
G.MAX_PER_CHUNK = 256   -- 16 x 16 cells x 3 layers can't need more than this many merged boxes

function G.new()
  return { chunks = {}, count = 0, on = false, top = 0, lift = 0 }
end

local function key(cx, cz) return string.format('%d,%d', cx, cz) end

local function clearChunk(st, env, k)
  local ids = st.chunks[k]
  if not ids then return 0 end
  for _, id in ipairs(ids) do env.delete(id) end
  st.chunks[k] = nil
  st.count = st.count - #ids
  return #ids
end

-- Replaces one chunk's boxes. boxes: flat {x0, y0, z0, x1, y1, z1, ...}, canonical whole metres,
-- min corner inclusive, max exclusive. Returns how many boxes changed (removed + added).
function G.setChunk(st, env, cx, cz, boxes)
  local k = key(cx, cz)
  local changed = clearChunk(st, env, k)
  local ids = {}
  if type(boxes) == 'table' then
    for i = 1, #boxes - 5, 6 do
      if #ids >= G.MAX_PER_CHUNK or st.count >= G.MAX_BOXES then break end
      local x0, y0, z0, x1, y1, z1 = boxes[i], boxes[i + 1], boxes[i + 2], boxes[i + 3], boxes[i + 4], boxes[i + 5]
      if type(x0) == 'number' and type(y0) == 'number' and type(z0) == 'number' and type(x1) == 'number' and type(y1) == 'number'
        and type(z1) == 'number' and x1 > x0 and y1 > y0 and z1 > z0 and x1 - x0 <= 16 and y1 - y0 <= 16 and z1 - z0 <= 64 then
        ids[#ids + 1] = env.box(x0, y0, z0, x1, y1, z1)
        st.count = st.count + 1
      end
    end
  end
  if #ids > 0 then st.chunks[k] = ids end
  return changed + #ids
end

-- The ground is in: cars still on the floor (more than a metre below the surface) go up by lift,
-- once. Returns how many were lifted.
function G.turnOn(st, env, top, lift)
  local lifted = 0
  if not st.on then
    for _, car in ipairs(env.cars()) do
      if car.z < top - 1 then
        env.moveCar(car.id, lift)
        lifted = lifted + 1
      end
    end
  end
  st.on, st.top, st.lift = true, top, lift
  return lifted
end

-- Everything back as the level had it: no boxes, cars on the ground lowered to the floor.
-- Returns whether anything changed.
function G.restore(st, env)
  local had = st.on or st.count > 0
  if st.on then
    for _, car in ipairs(env.cars()) do
      if car.z > st.top - 1 then env.moveCar(car.id, -st.lift) end
    end
  end
  for k in pairs(st.chunks) do clearChunk(st, env, k) end
  st.chunks, st.count, st.on = {}, 0, false
  return had
end

return G
