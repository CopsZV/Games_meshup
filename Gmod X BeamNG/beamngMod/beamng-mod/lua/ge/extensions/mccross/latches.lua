-- Doors, bonnets and boots for a player in Minecraft on cars without vehicle triggers for them (most
-- car mods, Jas's M3, G87, SF90, Porsche among them, and the doors of most stock cars). BeamNG keeps
-- them shut two ways, both in the car's jbeam (core_vehicle_manager.getVehicleData(vid).vdata):
--   * a latch controller, `controller` rows {fileName = "advancedCouplerControl", name = ...} with a
--     section of that name whose couplerNodes rows hold the two latch nodes (stock doors, bonnets):
--     toggled with the controller's own toggleGroup (vehicle/controller/advancedCouplerControl.lua:
--     209, what BeamNG's latchesOpen/Close do for all of them, gameplayInterfaceModules/interactMisc.lua)
--   * a breakGroup named ...latch... (doorlatch_FL, hoodlatch, trunklatch): the door opens when it
--     breaks, beamstate.breakBreakGroup (vehicle/beamstate.lua:166, as scenario/scenariohelper.lua:30
--     calls it); BeamNG's repair shuts it again.
-- Each becomes a target at its latch nodes, where a door handle is, tested like a trigger's box
-- (triggers.lua). Pure: node positions come in through env.

local L = {}

L.HALF = 0.2   -- m: half the side of the box around a latch the eye ray must pass

local function nodeIndex(vdata)
  local byName = {}
  for cid, n in pairs(type(vdata.nodes) == 'table' and vdata.nodes or {}) do
    if type(n) == 'table' then byName[tostring(n.name or n.id or cid)] = tonumber(n.cid) or cid end
  end
  return byName
end

local function cidOf(byName, id)
  if type(id) == 'number' then return id end
  return byName[tostring(id)]
end

-- "doorlatch_FL" -> "door FL", "hoodLatchCoupler" -> "bonnet", "trunklatch" -> "boot".
function L.label(name)
  local n = tostring(name):lower()
  local what = n:find('hood') and 'bonnet' or (n:find('trunk') or n:find('boot')) and 'boot' or n:find('tailgate') and 'tailgate'
    or n:find('hatch') and 'hatch' or n:find('door') and 'door' or 'latch'
  local s = tostring(name)
  local side = s:match('_([FR][LR])_') or s:match('_([FR][LR])$') or s:match('door([FR][LR])') or s:match('_([LR])_') or s:match('_([LR])$')
    or s:match('door([LR]%d)')
  return side and (what .. ' ' .. side) or what
end

-- The car's latches: { {id, kind = 'coupler'|'break', name, label, nodes = {cids}} }, couplers
-- first; a breakGroup a coupler already uses (its own latch beam) isn't listed twice.
function L.targets(vdata)
  local out = {}
  if type(vdata) ~= 'table' then return out end
  local byName = nodeIndex(vdata)
  local owned = {}
  for _, c in pairs(type(vdata.controller) == 'table' and vdata.controller or {}) do
    if type(c) == 'table' and c.fileName == 'advancedCouplerControl' and type(c.name) == 'string' then
      local sec = vdata[c.name]
      local rows = type(sec) == 'table' and type(sec.couplerNodes) == 'table' and sec.couplerNodes or {}
      -- couplerNodes stays a header table in the jbeam data (the controller converts it itself,
      -- tableFromHeaderTable, advancedCouplerControl.lua:429): a first row of column names
      local col = { cid1 = 1, cid2 = 2 }
      local first = rows[1]
      if type(first) == 'table' and first[1] == 'cid1' then
        for i, name in ipairs(first) do col[name] = i end
      end
      local nodes = {}
      for i, row in ipairs(rows) do
        if type(row) == 'table' and not (i == 1 and row[1] == 'cid1') then
          local a, b = cidOf(byName, row.cid1 or row[col.cid1]), cidOf(byName, row.cid2 or row[col.cid2])
          if a then nodes[#nodes + 1] = a end
          if b then nodes[#nodes + 1] = b end
          local bg = row.breakGroup or (col.breakGroup and row[col.breakGroup])
          if type(bg) == 'string' then owned[bg] = true end
        end
      end
      if #nodes > 0 then
        -- couplers for the same thing are one target: a bonnet has a latch and a safety catch
        -- (hoodLatchCoupler, hoodCatchCoupler), and toggling one of them leaves it shut
        local label = L.label(c.name)
        local same
        for _, t in ipairs(out) do
          if t.kind == 'coupler' and t.label == label then same = t end
        end
        if same then
          same.names[#same.names + 1] = c.name
          for _, cid in ipairs(nodes) do same.nodes[#same.nodes + 1] = cid end
        else
          out[#out + 1] = { id = 'latch:coupler:' .. c.name, kind = 'coupler', name = c.name, names = { c.name }, label = label, nodes = nodes }
        end
      end
    end
  end
  local groups, order = {}, {}
  for _, b in pairs(type(vdata.beams) == 'table' and vdata.beams or {}) do
    if type(b) == 'table' then
      local bg = b.breakGroup
      for _, g in ipairs(type(bg) == 'table' and bg or { bg }) do
        if type(g) == 'string' and g:lower():find('latch', 1, true) and not owned[g] then
          if not groups[g] then
            groups[g] = {}
            order[#order + 1] = g
          end
          local list = groups[g]
          local a, c = cidOf(byName, b.id1), cidOf(byName, b.id2)
          if a then list[#list + 1] = a end
          if c then list[#list + 1] = c end
        end
      end
    end
  end
  table.sort(order)
  for _, g in ipairs(order) do
    if #groups[g] > 0 then
      out[#out + 1] = { id = 'latch:break:' .. g, kind = 'break', name = g, label = L.label(g), nodes = groups[g] }
    end
  end
  return out
end

-- A target's box for triggers.aim: centred on its nodes (pos(cid) -> x, y, z world), world axes.
function L.box(target, pos)
  local sx, sy, sz, n = 0, 0, 0, 0
  for _, cid in ipairs(target.nodes) do
    local x, y, z = pos(cid)
    if x then
      sx, sy, sz, n = sx + x, sy + y, sz + z, n + 1
    end
  end
  if n == 0 then return nil end
  local title = (target.kind == 'coupler' and 'Open / close ' or 'Open ') .. target.label
  return { t = target.id, c = { sx / n, sy / n, sz / n }, a = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }, h = { L.HALF, L.HALF, L.HALF },
    name = target.name, actions = { action0 = title } }
end

-- The vehicle Lua that does it, for veh:queueLuaCommand; nil for an id this module didn't make.
-- Names go in with %q, and only names the car's own data listed reach here.
function L.command(id, targets)
  for _, t in ipairs(targets or {}) do
    if t.id == id then
      if t.kind == 'coupler' then
        local cmds = {}
        for _, name in ipairs(t.names or { t.name }) do
          cmds[#cmds + 1] = string.format('local c = controller.getController(%q) if c and c.toggleGroup then c.toggleGroup() end', name)
        end
        return table.concat(cmds, '\n')
      end
      return string.format('beamstate.breakBreakGroup(%q)', t.name)
    end
  end
  return nil
end

return L
