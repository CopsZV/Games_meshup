-- Car selection for Minecraft (minecraft-host.md, "Car selection"): BeamNG's own vehicle list,
-- the data its vehicle selector shows (core_vehicles.getModelList / getModel,
-- core/vehicles.lua:758-1045), and spawning the way the selector and career mode do
-- (core_vehicles.replaceVehicle / spawnNewVehicle, then spawn.safeTeleport onto the ground beside
-- the Minecraft player, as career/modules/vehicleShopping.lua:517-518 moves a new car).
--
-- Preview pictures live inside the vehicle zips. Minecraft reads plain files, so each one it
-- asks about is copied once into the user folder (temp/mccross/thumbs).
--
-- Engine calls only go through `env`, so bridge/test_lua.py can run this with fakes:
--   env.vehicles  core_vehicles (getModelList, getModel, spawnNewVehicle, replaceVehicle)
--   env.exists(p), env.read(p) -> bytes|nil, env.write(p, bytes), env.userPath
--   env.place(veh, pos, fwd)    put a car on the ground at pos, facing fwd

local S = {}

local THUMB_DIR = '/temp/mccross/thumbs/'
local DEFAULT_PREVIEW = '/ui/images/appDefault.png'   -- what getModel returns when a car has none

-- A preview copied into the user folder; returns its absolute path, or nil.
function S.thumb(env, src)
  if type(src) ~= 'string' or src == '' or src == DEFAULT_PREVIEW then return nil end
  local out = THUMB_DIR .. src:gsub('^/', ''):gsub('[^%w%._-]', '_')
  if not env.exists(out) then
    local data = env.read(src)
    if not data or #data == 0 then return nil end
    env.write(out, data)
  end
  return env.userPath .. out:sub(2)
end

local function str(v)
  return v ~= nil and tostring(v) or ''
end

local function countKeys(t)
  local n = 0
  for _ in pairs(type(t) == 'table' and t or {}) do n = n + 1 end
  return n
end

-- Every model BeamNG knows: {k, name, brand, type, configs, def, thumb}, sorted by brand, name.
function S.models(env)
  local out = {}
  local list = env.vehicles.getModelList(true)
  for _, m in ipairs(list and list.models or {}) do
    if type(m) == 'table' and m.key then
      local full = env.vehicles.getModel(m.key)
      out[#out + 1] = { k = m.key, name = str(m.Name), brand = str(m.Brand), type = str(m.Type),
        configs = countKeys(full and full.configs), def = str(m.default_pc), thumb = S.thumb(env, m.preview) }
    end
  end
  table.sort(out, function(a, b)
    if a.brand ~= b.brand then return a.brand < b.brand end
    return a.name < b.name
  end)
  return out
end

-- One model's configurations: {k, name, def, thumb}, the default first, then by name.
-- Returns nil for a model BeamNG doesn't have.
function S.configs(env, modelKey)
  local m = type(modelKey) == 'string' and env.vehicles.getModel(modelKey) or nil
  if not m or not m.model then return nil end
  local out = {}
  for key, c in pairs(m.configs or {}) do
    out[#out + 1] = { k = str(c.key or key), name = str(c.Configuration or key), def = c.is_default_config == true,
      thumb = S.thumb(env, c.preview) }
  end
  table.sort(out, function(a, b)
    if a.def ~= b.def then return a.def end
    return a.name < b.name
  end)
  return out
end

local function isVec(t)
  return type(t) == 'table' and type(t[1]) == 'number' and type(t[2]) == 'number' and type(t[3]) == 'number'
end

-- Spawn {model, config, mode = "new"|"replace", pos?, fwd?}. Only a model and config that BeamNG
-- lists are spawned (no file paths from the message). "new" puts the car at pos facing fwd and
-- leaves the player where they are; "replace" swaps the player's car in place, as the selector
-- does. Returns the vehicle, or nil and an error message.
function S.spawn(env, msg)
  local modelKey, configKey = msg.model, msg.config
  local m = type(modelKey) == 'string' and env.vehicles.getModel(modelKey) or nil
  if not m or not m.model then return nil, 'unknown model ' .. str(modelKey):sub(1, 40) end
  local implicit = configKey == nil
  if implicit then configKey = m.model.default_pc end
  local known = false
  for key, c in pairs(m.configs or {}) do
    if (c.key or key) == configKey then known = true end
  end
  if not known and implicit then
    -- a mod's default_pc can name a configuration it doesn't ship (the Cadillac CT5 mod's
    -- base_v6_A): then the one it marks default, else the first by name
    local list = S.configs(env, modelKey)
    if list and list[1] then configKey, known = list[1].k, true end
  end
  if not known then return nil, 'unknown config ' .. str(configKey):sub(1, 40) .. ' for ' .. modelKey end

  if msg.mode == 'replace' then
    local veh = env.vehicles.replaceVehicle(modelKey, { config = configKey })
    if not veh then return nil, 'BeamNG did not replace the car' end
    return veh
  end
  if not isVec(msg.pos) or not isVec(msg.fwd) then return nil, 'spawning a new car needs pos and fwd' end
  local veh = env.vehicles.spawnNewVehicle(modelKey, { config = configKey, autoEnterVehicle = false })
  if not veh then return nil, 'BeamNG did not spawn the car (vehicle limit?)' end
  env.place(veh, msg.pos, msg.fwd)
  return veh
end

return S
