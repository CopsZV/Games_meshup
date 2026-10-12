-- Native car models for Minecraft (minecraft-host.md, "Native mode"): BeamNG's own glTF exporter
-- (util_export, the in-game 3D export app; util/export.lua) writes a car, its materials and its
-- textures (DDS converted to PNG by convertDDSToPNG) to a .glb in the user folder. Minecraft reads
-- it from there and bends the mesh with the vmesh node stream. The file never leaves this PC.
-- Next to it, <name>.json: the pose the mesh was exported in (pos, n, p: node offsets in cm like
-- vmesh), which nodes each flexbody follows (groups: mesh name -> node cids, as BeamNG binds them,
-- jbeam/sections/meshs.lua:247-266), the paint (veh.color, colorPalette0/1;
-- core/vehicle/colors.lua:80) and the material fields the exporter leaves out.
--
-- util_export only exports player 0's car (export.lua:256, 651, 791, 958 all ask for it). Any
-- other car gets the player slot for the length of the call: exportFile runs to the end inside
-- the call (no coroutines, no frames pass), and the slot goes straight back afterwards.

local X = {}

local EXPORT_TIMEOUT = 120   -- s from the start of writing to a written file
local WARM_BUDGET = 0.04     -- s of texture conversion per frame before an export

-- util_export converts every DDS texture to PNG the first time a model is exported, all inside one
-- call: 20-30 s with BeamNG frozen (measured: Scintilla 29 s, citybus ~22 s). It caches each one at
-- '/temp/<lowercased path>.png' and skips the ones there (util/export.lua:641-700), so the same
-- conversions are done here first, a few per frame, and the export itself then finds them.
local TEXTURE_FIELDS = { 'baseColorMap', 'normalMap', 'roughnessMap', 'metallicMap', 'ambientOcclusionMap', 'opacityMap',
  'colorPaletteMap', 'clearCoatMap', 'emissiveMap', 'colorMap', 'specularMap' }   -- the maps _exportMaterial reads

local function texturesToWarm(veh)
  local todo, seen = {}, {}
  local okNames, names = pcall(function() return veh:getMaterialNames() end)
  for _, name in ipairs(okNames and type(names) == 'table' and names or {}) do
    local mat = scenetree.findObject(name)
    if mat and tostring(mat:getClassName()):lower() == 'material' then
      for l = 0, 3 do
        for _, field in ipairs(TEXTURE_FIELDS) do
          local p = tostring(mat:getField(field, l) or ''):lower()
          if p ~= '' and p:sub(1, 1) ~= '@' then
            -- a cooked texture is named .png but shipped as .dds (export.lua _isTextureCookerFilepath)
            if not FS:fileExists(p) and (p:match('%.color%.png$') or p:match('%.normal%.png$') or p:match('%.data%.png$')) then
              p = p:sub(1, -5) .. '.dds'
            end
            local out = '/temp/' .. p .. '.png'
            if p:sub(-4) == '.dds' and not seen[p] and FS:fileExists(p) and not FS:fileExists(out) then
              seen[p] = true
              todo[#todo + 1] = { p, out }
            end
          end
        end
      end
    end
  end
  return todo
end

-- The exporter leaves some material fields out (util/export.lua _exportMaterial): baseColorFactor
-- (untextured trims are dark only through it), detail maps (the carbon weave) and which UV set
-- the AO map uses. Read them as the material editor does (editor/materialEditor.lua:1272-1275,
-- 1314). Colours come as "r g b a" or as a name ("White"). Detail textures are converted to PNG
-- into the user folder (convertDDSToPNG, as util/export.lua:686 does).
local NAMED = { white = { 1, 1, 1, 1 }, black = { 0, 0, 0, 1 }, gray = { 0.5, 0.5, 0.5, 1 }, grey = { 0.5, 0.5, 0.5, 1 } }

local function colorField(mat, field, l)
  local raw = tostring(mat:getField(field, l) or '')
  local f = {}
  for v in raw:gmatch('[-%d%.eE]+') do f[#f + 1] = tonumber(v) end
  if #f >= 3 then return f end
  return NAMED[raw:lower()] or false
end

local function pngCopy(texPath)
  if texPath == '' then return nil end
  local src = texPath
  if not FS:fileExists(src) and src:sub(-4) == '.png' then src = src:sub(1, -5) .. '.dds' end
  if not FS:fileExists(src) then return nil end
  local out = '/temp/mccross/tex/' .. src:gsub('[^%w%._-]', '_') .. '.png'
  if not FS:fileExists(out) then
    if src:sub(-4) == '.dds' then
      if not convertDDSToPNG(src, out) then return nil end
    else
      local data = readFile(src)
      if not data then return nil end
      writeFile(out, data)
    end
  end
  return FS:getUserPath() .. out:sub(2)
end

-- Every layer of a material as BeamNG renders it (shaders/common/material/shadergen/
-- defaultMat.hlsl:212-424 reads these per layer), with the field names of the material editor
-- (editor/materialEditor.lua:1282-1340). The exporter's own extras miss the palette switches,
-- roughnessFactor, opacityFactor and the UV set of most maps, and once recorded a v1.5 material as
-- version 1 (a second mod defining the same material names), so the live values are written here.
local MAPS = { base = 'baseColorMap', palette = 'colorPaletteMap', opacity = 'opacityMap', metallic = 'metallicMap',
  roughness = 'roughnessMap', ao = 'ambientOcclusionMap', clearCoat = 'clearCoatMap', normal = 'normalMap' }
local MAP_UV1 = { base = 'diffuseMapUseUV', palette = 'colorPaletteMapUseUV', opacity = 'opacityMapUseUV', metallic = 'metallicMapUseUV',
  roughness = 'roughnessMapUseUV', ao = 'ambientOcclusionMapUseUV', clearCoat = 'clearCoatMapUseUV', normal = 'normalMapUseUV' }
local FACTORS = { metallic = 'metallicFactor', roughness = 'roughnessFactor', clearCoat = 'clearCoatFactor',
  clearCoatRoughness = 'clearCoatRoughnessFactor', opacity = 'opacityFactor', normalStrength = 'normalMapStrength' }
local PALETTE = { base = 'paletteBaseColor', roughness = 'paletteRoughness', metallic = 'paletteMetallic',
  clearCoat = 'paletteClearCoat', clearCoatRoughness = 'paletteClearCoatRoughness' }

local function on(mat, field, l)
  local v = tostring(mat:getField(field, l) or ''):lower()
  return v == '1' or v == 'true'
end

-- A v1 material keeps its colour in diffuseColor, v1.5 in baseColorFactor (the material editor's
-- "Color" for each, editor/materialEditor.lua:1283, 1314, 2216).
local function colorFieldOf(mat, legacy)
  return legacy and 'diffuseColor' or 'baseColorFactor'
end

local function layerOf(mat, l, legacy)
  local layer = { baseColorFactor = colorField(mat, colorFieldOf(mat, legacy), l), instanceDiffuse = on(mat, 'instanceDiffuse', l),
    maps = {}, uv1 = {}, palette = {} }
  for k, field in pairs(MAPS) do layer.maps[k] = tostring(mat:getField(field, l) or '') end
  for k, field in pairs(MAP_UV1) do layer.uv1[k] = tostring(mat:getField(field, l) or '') == '1' end
  for k, field in pairs(FACTORS) do layer[k] = tonumber(mat:getField(field, l)) end
  for k, field in pairs(PALETTE) do layer.palette[k] = on(mat, field, l) end
  return layer
end

local function materialsOf(veh)
  local materials = {}
  local okNames, names = pcall(function() return veh:getMaterialNames() end)
  for _, name in ipairs(okNames and type(names) == 'table' and names or {}) do
    local mat = scenetree.findObject(name)
    if mat and tostring(mat:getClassName()):lower() == 'material' then
      local entry = { baseColorFactor = {}, paletteBaseColor = {}, aoUv1 = tostring(mat:getField('ambientOcclusionMapUseUV', 0)) == '1',
        version = tonumber(mat:getField('version', 0)), activeLayers = tonumber(mat:getField('activeLayers', 0)), layers = {} }
      local legacy = entry.version ~= nil and entry.version < 1.5
      for l = 0, math.max(0, math.min(4, entry.activeLayers or 1) - 1) do entry.layers[l + 1] = layerOf(mat, l, legacy) end
      for l = 0, 3 do
        entry.baseColorFactor[l + 1] = colorField(mat, colorFieldOf(mat, legacy), l)
        -- whether the palette mask paints the base colour (editor/materialEditor.lua:1288, 2633)
        entry.paletteBaseColor[l + 1] = tostring(mat:getField('paletteBaseColor', l)) == '1'
        local dm = tostring(mat:getField('detailMap', l) or '')
        if dm ~= '' and not entry.detail then
          local scale = {}
          for v in tostring(mat:getField('detailScale', l) or ''):gmatch('[-%d%.eE]+') do scale[#scale + 1] = tonumber(v) end
          entry.detail = { file = pngCopy(dm), layer = l, strength = tonumber(mat:getField('detailBaseColorMapStrength', l)) or 1,
            scale = scale, uv1 = tostring(mat:getField('detailMapUseUV', l)) == '1' }
        end
      end
      materials[name] = entry
    end
  end
  return materials
end

-- The driver's view as BeamNG's own onboard camera builds it (core/camera.lua:880-912,
-- core/cameraModes/onboard.lua:53-110): the "driver" onboard camera is a node of its own, added
-- by jbeam/sections/camera.lua:93-108 (camNodeID), aimed along ref - back with ref - left as left,
-- unless the camera names its own idUp/idBack; offset moves it along those axes. Node cids, as
-- vmesh sends them. nil without vehicle data.
local function cameraOf(vd)
  local v = vd and vd.vdata
  if not v then return nil end
  local rn = v.refNodes and v.refNodes[0] or {}
  local out = { ref = rn.ref, left = rn.left, back = rn.back }
  for _, cam in pairs(v.cameraData and v.cameraData.onboard or {}) do
    if type(cam) == 'table' and cam.name == 'driver' and cam.camNodeID then
      local crn = v.cameraRefNodes and (v.cameraRefNodes['onboard.driver'] or v.cameraRefNodes.driver)
      if crn then out.ref, out.left, out.back = crn.ref, crn.left, crn.back end
      out.driver = cam.camNodeID
      out.idUp, out.idBack, out.idRef = cam.idUp, cam.idBack, cam.idRef
      if type(cam.offset) == 'table' then out.offset = { cam.offset.x or 0, cam.offset.y or 0, cam.offset.z or 0 } end
      break
    end
  end
  return out
end

-- The car's paint: its three colours (veh.color, colorPalette0/1; core/vehicle/colors.lua:80) and
-- each paint's metallic, roughness, clear coat and clear coat roughness, which the palette layers
-- multiply in (shadergen.h.hlsl:181-192; read as core/vehicle/colors.lua:79 does).
local function paintOf(veh)
  local function paint(col) return col and { col.x, col.y, col.z, col.w } or nil end
  local okData, data = pcall(function() return veh:getMetallicPaintData() end)
  local paintData = {}
  for i = 1, 3 do
    local d = okData and type(data) == 'table' and data[i] or nil
    -- by name or by position, as createVehiclePaint (ge_utils.lua:958-961) accepts it
    paintData[i] = type(d) == 'table' and { tonumber(d.metallic or d[1]), tonumber(d.roughness or d[2]), tonumber(d.clearcoat or d[3]),
      tonumber(d.clearcoatRoughness or d[4]) } or false
  end
  return { paint(veh.color), paint(veh.colorPalette0), paint(veh.colorPalette1) }, paintData
end

local function sideFile(veh, vid)
  local n = veh:getNodeCount()
  local p = {}
  for i = 0, n - 1 do
    local x, y, z = veh:getNodePositionXYZ(i)
    p[#p + 1] = math.floor(x * 1000 + 0.5)   -- mm, as vmesh sends them
    p[#p + 1] = math.floor(y * 1000 + 0.5)
    p[#p + 1] = math.floor(z * 1000 + 0.5)
  end
  local px, py, pz = veh:getPositionXYZ()
  local groups = {}
  local vd = core_vehicle_manager.getVehicleData(vid)   -- core/vehicle/manager.lua:236
  for _, fb in pairs(vd and vd.vdata and vd.vdata.flexbodies or {}) do
    if fb.mesh and type(fb._group_nodes) == 'table' then groups[fb.mesh] = fb._group_nodes end
  end
  local paint, paintData = paintOf(veh)
  return { id = vid, model = veh:getJBeamFilename(), pos = { px, py, pz }, n = n, p = p, q = 1000, groups = groups,
    paint = paint, paintData = paintData, materials = materialsOf(veh), camera = cameraOf(vd) }
end

-- util_export on any car: the player slot is lent to it for the call, then handed back.
local function exportAs(veh, path)
  local prev = getPlayerVehicle(0)
  local lend = not prev or prev:getID() ~= veh:getID()
  if lend then
    local okEnter, e = pcall(be.enterVehicle, be, 0, veh)
    if not okEnter then return false, e end
  end
  local ok, err = pcall(util_export.exportFile, path)
  if lend and prev then pcall(be.enterVehicle, be, 0, prev) end
  return ok, err
end

-- Finished exports by the parts they were made from, kept across restarts in the user folder.
local INDEX = '/temp/mccross/exports.json'

-- What a car is built from: its model and part configuration (veh.partConfig, as core/vehicles.lua
-- reads it at :933 and :1949 to clone a car: a .pc path, or a serialized table once parts were
-- changed in BeamNG). Cars with the same key have the same mesh, nodes and materials; only the
-- paint differs, and Minecraft takes that from the side file (NativeCars.load), not the .glb.
local function partsKey(veh)
  local okPc, pc = pcall(function() return veh.partConfig end)
  return veh:getJBeamFilename() .. '|' .. tostring(okPc and pc or '')
end
X.partsKey = partsKey   -- for the tests
-- BeamNG damage below which an export is shared: a dented car would give every later one its dents
-- (BeamNG's traffic counts 500 as big damage, gameplay/traffic/vehicle.lua:712)
X.SHARE_DAMAGE = 100

-- done: vid -> the last finished export of that car, answered again while the car is unchanged.
-- byParts: partsKey -> {model, n, path, side, bytes}, one export for every car built the same way:
-- each new spawn of a model used to be exported again and froze BeamNG another 25 s (the G87 three
-- times in a row, 2026-10-03).
function X.new()
  local okIdx, idx = pcall(jsonReadFile, INDEX)
  return { job = nil, done = {}, byParts = okIdx and type(idx) == 'table' and idx or {} }
end

-- A car built like one exported before: that export's .glb, with a side file of its own (the same
-- node pose, groups and materials, this car's id and paint). Returns the vexported reply, or nil.
local function fromParts(st, veh, vid, tv, logI)
  local e = st.byParts[partsKey(veh)]
  if type(e) ~= 'table' or e.model ~= veh:getJBeamFilename() or e.n ~= veh:getNodeCount()
      or not FS:fileExists(e.path or '') or not FS:fileExists(e.side or '') then
    return nil
  end
  local okRead, side = pcall(jsonReadFile, e.side)
  if not okRead or type(side) ~= 'table' or side.n ~= e.n then return nil end
  side.id = vid
  side.paint, side.paintData = paintOf(veh)
  side.materials = materialsOf(veh)   -- live, so a fix in how materials are read reaches cached exports too
  local path = string.format('/temp/mccross/%s_%d.json', e.model, vid)
  if not pcall(jsonWriteFile, path, side, false) then return nil end
  local reply = { id = vid, model = e.model, file = FS:getUserPath() .. e.path:sub(2), side = FS:getUserPath() .. path:sub(2), ms = 0,
    bytes = e.bytes, cached = true, shared = true }
  st.done[vid] = { model = e.model, n = e.n, tv = tv, path = e.path, side = path, reply = reply }
  logI(string.format('car %d (%s): built like an earlier export, reusing %s (no export, no freeze)', vid, e.model, e.path))
  local r = {}
  for k, v in pairs(reply) do r[k] = v end
  return r
end

local function copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

-- The export proper: side file, then util_export on the car. Returns nil, or an error {code, msg}.
local function write(job, veh, t, logI)
  extensions.load('util_export')
  util_export.gltfBinaryFormat = true
  util_export.embedBuffers = true
  util_export.exportNormals = true
  util_export.exportTexCoords = true
  util_export.exportBeams = false
  if FS:fileExists(job.path) then FS:removeFile(job.path) end
  -- BeamNG's own damage tally (vehicle/mapmgr.lua:125 sends beamstate.damage; read as
  -- gameplay/traffic/vehicle.lua:707 does): only an export of an undamaged car is shared with others
  local okDmg, dmg = pcall(function() return map.objects[job.vid].damage end)
  job.damage = okDmg and tonumber(dmg) or nil
  jsonWriteFile(job.side, sideFile(veh, job.vid), false)
  local ok, err = exportAs(veh, job.path)
  if not ok then return { code = 'export_failed', id = job.vid, msg = tostring(err) } end
  job.phase, job.t0, job.size = 'write', t, -1
  logI(string.format('exporting car %d (%s) to %s for Minecraft', job.vid, job.model, job.path))
  return nil
end

-- Starts an export of veh for client c: textures first (spread over frames), then the export.
-- tv: the car's vmesh shape (vmesh.lua), which changes when the car is replaced or rebuilt.
-- A car exported before and unchanged since (same model, node count and tv) is answered from the
-- files already written, without freezing BeamNG for another export: returns nil, the vexported
-- reply. Asked again for the car being exported (a lost answer, a client that reconnected), the
-- running export answers when it is done. Returns nil (answer later), nil + reply (answer now),
-- or an error {code, msg}.
function X.start(st, c, veh, t, logI, tv)
  local vid = veh:getID()
  if st.job and st.job.vid == vid then
    st.job.c = c
    return nil
  end
  local d = st.done[vid]
  if d and tv ~= nil and d.tv == tv and d.model == veh:getJBeamFilename() and d.n == veh:getNodeCount()
      and FS:fileExists(d.path) and FS:fileExists(d.side) then
    local reply = copy(d.reply)
    reply.cached = true
    return nil, reply
  end
  -- answers from files already written don't need the exporter, so they don't wait for a running export
  local shared = tv ~= nil and fromParts(st, veh, vid, tv, logI)
  if shared then return nil, shared end
  if st.job then
    return { code = 'busy', msg = 'an export is already running' }
  end
  local path = string.format('/temp/mccross/%s_%d.glb', veh:getJBeamFilename(), vid)
  local job = { c = c, vid = vid, model = veh:getJBeamFilename(), path = path, side = path:gsub('%.glb$', '.json'),
    warm = texturesToWarm(veh), next = 1, tWarm = t, n = veh:getNodeCount(), tv = tv, parts = partsKey(veh) }
  st.job = job
  if #job.warm == 0 then
    local err = write(job, veh, t, logI)
    if err then st.job = nil end
    return err
  end
  job.phase = 'warm'
  logI(string.format('car %d (%s): converting %d textures for Minecraft first, a few per frame', vid, job.model, #job.warm))
  return nil
end

-- Every frame: converts textures within the budget, then exports; answers vexported once the
-- file is written and no longer growing.
function X.update(st, t, send, logI)
  local job = st.job
  if not job then return end
  if job.phase == 'warm' then
    local veh = getObjectByID(job.vid)
    if not veh then
      st.job = nil
      send(job.c, 'error', { code = 'export_failed', id = job.vid, msg = 'the car is gone' })
      return
    end
    local t0 = os.clockhp()
    while job.next <= #job.warm and os.clockhp() - t0 < WARM_BUDGET do
      local w = job.warm[job.next]
      if not FS:fileExists(w[2]) then convertDDSToPNG(w[1], w[2]) end
      job.next = job.next + 1
    end
    if job.next > #job.warm then
      logI(string.format('car %d (%s): %d textures converted in %.1f s', job.vid, job.model, #job.warm, t - job.tWarm))
      local err = write(job, veh, t, logI)
      if err then
        st.job = nil
        send(job.c, 'error', err)
      end
    end
    return
  end
  local size = FS:fileExists(job.path) and FS:stat(job.path).filesize or -1
  if size > 0 and size == job.size then
    st.job = nil
    local reply = { id = job.vid, model = job.model, file = FS:getUserPath() .. job.path:sub(2),
      side = FS:getUserPath() .. job.side:sub(2), ms = (t - job.t0) * 1000, bytes = size }
    st.done[job.vid] = { model = job.model, n = job.n, tv = job.tv, path = job.path, side = job.side, reply = reply }
    -- this export's files may have been another build's before (vehicle ids repeat after a restart)
    for k, e in pairs(st.byParts) do
      if type(e) == 'table' and (e.path == job.path or e.side == job.side) then st.byParts[k] = nil end
    end
    if job.parts and job.damage and job.damage < X.SHARE_DAMAGE then
      st.byParts[job.parts] = { model = job.model, n = job.n, path = job.path, side = job.side, bytes = size }
    end
    pcall(jsonWriteFile, INDEX, st.byParts, true)
    send(job.c, 'vexported', copy(reply))
    logI(string.format('car %d exported: %d bytes in %.0f ms', job.vid, size, (t - job.t0) * 1000))
  elseif size > 0 then
    job.size = size   -- written or still growing: check again next frame
  elseif t - job.t0 > EXPORT_TIMEOUT then
    st.job = nil
    send(job.c, 'error', { code = 'export_failed', id = job.vid, msg = 'no export file after ' .. EXPORT_TIMEOUT .. ' s' })
  end
end

-- A client that leaves gets no answer.
function X.forget(st, c)
  if st.job and st.job.c == c then st.job = nil end
end

X.layerOf = layerOf   -- for the tests

return X
