-- Car shapes for Minecraft's cutouts (docs/minecraft-host.md). A client that subscribes
-- (`vmesh_sub`) gets, for every car within its range of the camera:
--   * "vmesh" every BeamNG frame (Minecraft blends between them by the envelope's ts): the car
--     position, its forward and up vectors, and every node's offset from it, in whole
--     centimetres. GE's veh:getNodePositionXYZ(i) is a world-aligned offset from
--     veh:getPositionXYZ() (beamng-api-notes.md, measured), so world = pos + offset / 100.
--   * "vtris" once per car shape: the skin triangles as node index triples, read from vehicle Lua
--     (v.data.triangles, wheels' tread and sidewalls included) and cached here. `tv` names a
--     shape; it changes when the car's node count does (a reload with other parts).
-- Engine calls only go through the vehicle objects passed in, so bridge/test_lua.py can run this
-- with fake cars.

local V = {}

-- Runs inside the car's vehicle Lua; `vid` is prepended. Sends the triangles back to GE.
local FETCH = [[
local t = v.data.triangles
local n = t and tableSizeC(t) or 0
local out = {}
for i = 0, n - 1 do
  local x = t[i]
  out[#out + 1] = x.id1; out[#out + 1] = x.id2; out[#out + 1] = x.id3
end
obj:queueGameEngineLua(string.format('mccross_bridge.vmeshTris(%d, %d, %q)', vid, obj:getNodeCount(), jsonEncode(out)))
]]

function V.new()
  return { subs = {}, shapes = {}, nextTv = 0 }
end

function V.subscribe(st, c, range)
  st.subs[c] = { range = range, sent = {} }
end

function V.unsubscribe(st, c)
  st.subs[c] = nil
end

-- Vehicle Lua answered FETCH: `list` holds node index triples for a car with `nodeCount` nodes.
function V.onTris(st, vid, nodeCount, list)
  st.nextTv = st.nextTv + 1
  st.shapes[vid] = { n = nodeCount, tv = st.nextTv, tris = list }
end

-- A client lost the vtris datagram (it sees a vmesh tv it has no triangles for).
function V.resendTris(st, c, vid)
  local sub = st.subs[c]
  if sub then sub.sent[vid] = nil end
end

local floor = math.floor

-- Node offsets in whole millimetres (q = 1000 in the message). Centimetres were too coarse: a
-- mesh vertex rides on three nodes, and 5 mm of rounding on them shook the Moonhawk's panels by
-- up to several cm (RealExportJitterTest).
local Q = 1000

local function readNodes(veh, n)
  local p = {}
  for i = 0, n - 1 do
    local x, y, z = veh:getNodePositionXYZ(i)
    p[#p + 1] = floor(x * Q + 0.5)
    p[#p + 1] = floor(y * Q + 0.5)
    p[#p + 1] = floor(z * Q + 0.5)
  end
  return p
end

-- Once per frame. cars: array of vehicle objects; (cx, cy, cz): the camera; send(c, t, payload).
function V.tick(st, cars, cx, cy, cz, send)
  if next(st.subs) == nil then return end
  for _, veh in ipairs(cars) do
    local vid = veh:getID()
    local px, py, pz = veh:getPositionXYZ()
    local d2 = (px - cx) ^ 2 + (py - cy) ^ 2 + (pz - cz) ^ 2
    local n, p, shape, dir = nil, nil, nil, nil
    for c, sub in pairs(st.subs) do
      if d2 <= sub.range * sub.range then
        if not n then
          n = veh:getNodeCount()
          shape = st.shapes[vid]
          if shape and shape.n ~= n then shape = nil end
          if not shape and not (st.shapes[vid] and st.shapes[vid].pending == n) then
            st.shapes[vid] = { n = -1, pending = n }
            veh:queueLuaCommand('local vid = ' .. vid .. '\n' .. FETCH)
          end
          p = readNodes(veh, n)
        end
        if not dir then
          local fx, fy, fz = veh:getDirectionVectorXYZ()
          local ux, uy, uz = veh:getDirectionVectorUpXYZ()
          dir = { { fx, fy, fz }, { ux, uy, uz } }
        end
        send(c, 'vmesh', { id = vid, tv = shape and shape.tv or 0, n = n, pos = { px, py, pz }, fwd = dir[1], up = dir[2], p = p, q = Q })
        if shape and shape.tv and sub.sent[vid] ~= shape.tv then
          sub.sent[vid] = shape.tv
          send(c, 'vtris', { id = vid, tv = shape.tv, n = shape.n, tris = shape.tris })
        end
      end
    end
  end
end

return V
