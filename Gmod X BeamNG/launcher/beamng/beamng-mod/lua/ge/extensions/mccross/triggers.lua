-- Vehicle triggers for a player in Minecraft: door handles, the bonnet and boot, switches in the
-- cabin. BeamNG's own interaction (core/vehicleTriggers.lua: findHoveredTrigger, onActionEvent)
-- raycasts from BeamNG's camera (be:triggerRaycastClosest, the engine's) and fires the trigger's
-- links (triggerEvent). Minecraft's eye isn't BeamNG's camera, so the eye's ray is tested here
-- against each trigger's box as BeamNG places it: centre from Trigger:getCenter(), axes and half
-- extents from core_vehicle_triggerLabelPlacement.computeTriggerBasisAndHalfExtents (the C++
-- trigger basis, written out in Lua by BeamNG). Pure: the engine calls come in through env.

local T = {}

T.REACH = 3.0     -- m from the eye: BeamNG's own reach is a few metres (getTriggerRaycastDistance)
T.NEAR = 12.0     -- m: vehicles whose box is this close to the eye are searched
T.ACTIONS = 3     -- action0..action2, as triggerEventLinksDict keys them

-- Ray o + s * d (d a unit vector, {x, y, z}) against a box: centre c, unit axes a[1..3], half
-- extents h[1..3]. The distance s >= 0 where the ray enters the box (0 inside it), or nil.
function T.rayBox(o, d, c, a, h)
  local tmin, tmax = 0, math.huge
  local px, py, pz = c[1] - o[1], c[2] - o[2], c[3] - o[3]
  for i = 1, 3 do
    local ax = a[i]
    local e = ax[1] * px + ax[2] * py + ax[3] * pz      -- the centre along this axis, from o
    local f = ax[1] * d[1] + ax[2] * d[2] + ax[3] * d[3]
    if math.abs(f) > 1e-9 then
      local t1, t2 = (e - h[i]) / f, (e + h[i]) / f
      if t1 > t2 then t1, t2 = t2, t1 end
      if t1 > tmin then tmin = t1 end
      if t2 < tmax then tmax = t2 end
      if tmin > tmax then return nil end
    elseif math.abs(e) > h[i] then
      return nil                                         -- parallel to this slab and outside it
    end
  end
  return tmin
end

-- Whether a ball (centre c, radius r) can meet the ray o + s * d within reach: the cheap test that
-- saves working out the boxes of a car's other triggers.
function T.nearRay(o, d, c, r, reach)
  local px, py, pz = c[1] - o[1], c[2] - o[2], c[3] - o[3]
  local along = px * d[1] + py * d[2] + pz * d[3]
  if along < -r or along > reach + r then return false end
  local qx, qy, qz = px - along * d[1], py - along * d[2], pz - along * d[3]
  return qx * qx + qy * qy + qz * qz <= r * r
end

-- A trigger's bounding radius from its jbeam size (a box's full extents, a sphere's radius), as
-- computeHalfExtents reads it (default box 0.2 m). The size may be a table or a vec3 (jbeam
-- processing turns it into one, events.lua:87).
function T.radius(size)
  if type(size) == 'number' then return math.abs(size) * 1.75 end
  local x, y, z = 0.2, 0.2, 0.2
  if size ~= nil then
    local ok, sx, sy, sz = pcall(function() return size.x or size[1], size.y or size[2], size.z or size[3] end)
    if ok then x, y, z = tonumber(sx) or x, tonumber(sy) or y, tonumber(sz) or z end
  end
  return 0.5 * math.sqrt(x * x + y * y + z * z)
end

-- The trigger the ray reaches first, within reach. env.vehicles(o, near) -> vehicle ids near the
-- eye; env.triggers(vid, o, d, reach) -> { {t = id, c = {..}, a = {{..}, {..}, {..}}, h = {..},
-- name = .., actions = {action0 = title, ..}}, .. }: triggers that do something, at least those
-- near the ray. The hit gets v and dist.
function T.aim(env, o, d, reach)
  reach = reach or T.REACH
  local best, bestS = nil, reach
  for _, vid in ipairs(env.vehicles(o, T.NEAR)) do
    for _, trg in ipairs(env.triggers(vid, o, d, reach)) do
      local s = T.rayBox(o, d, trg.c, trg.a, trg.h)
      if s and s <= bestS then
        best, bestS = trg, s
        best.v = vid
      end
    end
  end
  if best then best.dist = bestS end
  return best
end

-- The action titles of a trigger's links (triggerEventLinksDict[t]['action0'..] -> the input
-- action's title, as updateHoveredTriggerActions reads them), or nil if it has none.
function T.actionTitles(vdata, t, translate)
  local links = vdata.triggerEventLinksDict and vdata.triggerEventLinksDict[t]
  if type(links) ~= 'table' then return nil end
  local titles, any = {}, false
  for i = 0, T.ACTIONS - 1 do
    local key = 'action' .. i
    local list = links[key]
    local lnk = type(list) == 'table' and list[1] or nil
    if lnk then
      local action = lnk.inputAction and vdata.inputActions and vdata.inputActions[lnk.inputAction]
      local title = action and action.title or (lnk.targetEventId and tostring(lnk.targetEventId)) or key
      titles[key] = translate and translate(title) or title
      any = true
    end
  end
  return any and titles or nil
end

return T
