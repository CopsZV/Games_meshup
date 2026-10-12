-- Crossover camera filter: while Minecraft drives the view, it replaces the pose of whatever camera
-- mode is active (orbit, driver, free...) with Minecraft's camera.
--
-- core_camera discovers every file in /lua/ge/extensions/core/cameraModes/ (camera.lua,
-- getConstructors). A global camera with a runningOrder runs every frame, after the active camera
-- and in runningOrder order (cameraUpdate.lua, "running cameras"). gameengine.lua (runningOrder 1.0)
-- then sends data.res to the renderer, so 0.95 makes this the last word before output. When no
-- fresh pose is available it leaves data.res untouched: BeamNG's own camera is back instantly,
-- with nothing to switch or restore.

local C = {}
C.__index = C

function C:init()
  self.isGlobal = true
  self.isFilter = true
  self.hidden = true
  self.runningOrder = 0.95
  self.pos = vec3()
  self.fwd = vec3(0, 1, 0)
  self.up = vec3(0, 0, 1)
  self.rot = quat(0, 0, 0, 1)   -- quat() without arguments is (1,0,0,0), not identity
end

function C:update(data)
  if data.renderView ~= 'main' then return true end   -- only the player's view, not secondary views
  local bridge = rawget(_G, 'mccross_bridge')
  if not bridge then return true end
  local o = bridge.cameraOverride()
  if not o then return true end
  self.pos:set(o.px, o.py, o.pz)
  self.fwd:set(o.fx, o.fy, o.fz)
  self.up:set(o.ux, o.uy, o.uz)
  self.rot:setFromDir(self.fwd, self.up)
  data.res.pos = self.pos
  data.res.rot = self.rot
  if o.fov then data.res.fov = o.fov end   -- vertical FOV in degrees, same as Minecraft's
  bridge.noteCameraApplied(o.cseq)
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
