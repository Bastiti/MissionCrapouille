-- Crapouille dash switch panel (vehicles/sunburst2/switchpanel/craptech_switchpanel.jbeam).
--
-- A piece of the dash top above the centre vents turns out (the button on the shifter panel, between TC
-- and C.DIFF, or the key in Controls), turning about its windshield edge, and shows a row of toggle switches,
-- one per animated part (left to right):
--   1 JACKS   air jacks up / drop (craptechAirJacks.toggle)
--   2 WHEELS  wide / narrow track (craptechAirJacks.toggleTrack)
--   3 KIT     race kit out / tucked away (the transform controller, named "transform")
--   4 WING    rear wing out / stowed (craptechActiveAero.toggle)
--   5 JATO    rockets deployed / stowed (craptechJato.toggleDeploy)
--   6 FLASH   hidden flashers (the lightbar)
--   7 SIGN    rear-window sign board down (craptechSign.toggle)
-- The wheels, the kit and the wing only move with the car up on the air jacks (JACKS, never raised
-- for them); the JATO needs all three out (the parts' controllers see to it).
-- The rockets fire from a big red mushroom button on the console behind the shifter (fire():
-- craptechJato.toggleFire), with the panel in or out; it is lit while they burn, blinking while it waits
-- for them.
-- The piece is a wedge with the leather on two faces: turned out, the second one lies flush in the cut, so the
-- dash stays closed. With the panel out, a click on a switch flips its lever. The switches' click boxes are
-- there only while the panel is out: otherwise they are shrunk away (the trigger objects live in GE) and a
-- click on one does nothing.
--
-- Each lever shows what its part is asked to do (so keys and other controls move it too), and the light in
-- its tip is lit when the part is there, blinking while it moves or waits (wheels, kit and wing for the
-- car to be up on the jacks).
--
-- A prop has one motion: each lever comes twice, on and off, fixed to the turning piece, shown and hidden
-- here with their "hidden" flag. The piece is cut out of a copy of the dash, which replaces the stock dash
-- mesh: the config fits a copy of the stock dashboard without it (stockparts/craptech_stockparts.jbeam;
-- nothing is faded, a replay would show a faded mesh again).
--
-- Electrics written: craptech_swpanel (the piece, 0 in .. 1 out, eased), craptech_swpanel_lit (the
-- shifter button's light), craptech_swbtn (the shifter button pressed), craptech_firebtn (the fire button
-- pressed), craptech_firebtn_lit (its light), per switch i: craptech_gled_i (tip light, 0/1).
--
-- jbeam: ["craptechSwitchPanel", {"flipTime":1.0}]

local M = {}
M.type = "auxiliary"

local min, max = math.min, math.max

local flipTime = 1.0
local flip, flipTarget = 0, 0
local PRESS_TIME = 0.2       -- s, a button held in
local pressed = 0            -- the shifter button
local firePressed = 0        -- the fire button
local blink = 0
local propsByMesh = nil
local shown = {}
local boxesOut = nil      -- the switches' click boxes: full size (true) or shrunk away (false), nil = not sent yet

local function ease(x)
  return x * x * (3 - 2 * x)
end

local function call(name, fn)
  local c = controller.getController(name)
  if c and c[fn] then
    return c[fn]()
  end
  return nil
end

local function ev(name)
  return electrics.values[name] or 0
end

-- per switch: what its part is asked to do, whether the part is there (not moving or waiting),
-- and what a flip of the lever does
local SWITCHES = {
  { -- 1 jacks
    wanted = function() return call("craptechAirJacks", "isUp") == true end,
    settled = function(on) return on and ev("craptech_airjacks") >= 0.99 or not on and ev("craptech_airjacks") <= 0.01 end,
    flip = function() call("craptechAirJacks", "toggle") end,
  },
  { -- 2 wheels
    wanted = function() return call("craptechAirJacks", "wantsWide") == true end,
    settled = function(on) return call("craptechAirJacks", "busy") ~= true and (on and ev("craptech_track_wide") >= 0.99 or not on and ev("craptech_track_wide") <= 0.01) end,
    flip = function() call("craptechAirJacks", "toggleTrack") end,
  },
  { -- 3 race kit
    wanted = function() return call("transform", "wantsOut") == true end,   -- its jbeam names it "transform"
    settled = function(on) return on and ev("craptech_xf_state") <= 0.001 or not on and ev("craptech_xf_state") >= 0.999 end,
    flip = function() call("transform", "toggle") end,
  },
  { -- 4 wing
    wanted = function() return call("craptechActiveAero", "wantsOut") == true end,
    settled = function(on) return on and ev("craptech_spoiler_lift") >= 1.99 or not on and ev("craptech_spoiler_lift") <= 0.01 end,
    flip = function() call("craptechActiveAero", "toggle") end,
  },
  { -- 5 JATO deployed
    wanted = function() return call("craptechJato", "isDeployed") == true end,
    settled = function(on) return on and ev("craptech_jato_out") >= 0.99 or not on and ev("craptech_jato_door") <= 0.01 end,
    flip = function() call("craptechJato", "toggleDeploy") end,
  },
  { -- 6 hidden flashers
    wanted = function() return ev("lightbar") > 0 end,
    settled = function() return true end,
    flip = function() electrics.toggle_lightbar_signal() end,
  },
  { -- 7 sign
    wanted = function() return call("craptechSign", "isOn") == true end,
    settled = function() return true end,
    flip = function() call("craptechSign", "toggle") end,
  },
}

-- the switches' click boxes at their jbeam size with their highlight, or shrunk to nothing without it (resized
-- and updated the way jbeam/sections/events.lua makes them)
local function setBoxes(on)
  boxesOut = on
  local id = obj:getId()
  obj:queueGameEngineLua(string.format(
    "local v = be:getObjectByID(%d) local d = v and extensions.core_vehicle_manager.getVehicleData(%d) " ..
    "for _, t in pairs(d and d.vdata and d.vdata.triggers or {}) do " ..
    "if type(t.name) == 'string' and t.name:find('^craptech_gsw_') and t.size and t.abid then " ..
    "local o = v:getTrigger(t.abid) if o then " ..
    "local m = {} if %s then m = type(t.mesh) == 'table' and t.mesh or {t.mesh} end o:setHighlightMeshes(m) " ..
    "o:setBoxSize(%s) o:update(vec3(t.translation or vec3()), vec3(t.rotation or vec3()), true, 0) end end end",
    id, id, tostring(on), on and "vec3(t.size)" or "vec3(0.0001, 0.0001, 0.0001)"))
end

local function indexProps()
  propsByMesh = {}
  for _, prop in pairs(v.data.props or {}) do
    if type(prop) == "table" and prop.mesh then
      propsByMesh[prop.mesh] = propsByMesh[prop.mesh] or {}
      table.insert(propsByMesh[prop.mesh], prop)
    end
  end
end

local function show(mesh, on)
  if shown[mesh] == on then
    return
  end
  shown[mesh] = on
  for _, prop in ipairs(propsByMesh[mesh] or {}) do
    if not prop.disabled then   -- broken props stay hidden
      prop.hidden = not on
    end
  end
end

-- the shifter button: out, or back in
local function toggle()
  flipTarget = flipTarget > 0.5 and 0 or 1
  pressed = PRESS_TIME
end

-- a click on switch i (only with the panel out): flip its lever
local function press(i)
  if not SWITCHES[i] or flip < 1 then
    return
  end
  SWITCHES[i].flip()
end

-- the big red button: fire the rockets, or stop them
local function fire()
  firePressed = PRESS_TIME
  call("craptechJato", "toggleFire")
end

local function updateGFX(dt)
  if not propsByMesh then
    indexProps()
  end
  local e = electrics.values
  if flip ~= flipTarget then
    local step = dt / flipTime
    flip = flipTarget > flip and min(flip + step, flipTarget) or max(flip - step, flipTarget)
  end
  e.craptech_swpanel = ease(flip)
  local out = flip >= 1
  if out ~= boxesOut then
    setBoxes(out)
  end

  pressed = max(pressed - dt, 0)
  e.craptech_swbtn = pressed > 0 and 1 or 0
  firePressed = max(firePressed - dt, 0)
  e.craptech_firebtn = firePressed > 0 and 1 or 0
  blink = (blink + dt) % 0.6
  local on = blink < 0.3
  local powered = (e.ignitionLevel or 0) >= 1
  e.craptech_swpanel_lit = (powered and (flip > 0 or flipTarget > 0)) and 1 or 0
  for i, sw in ipairs(SWITCHES) do
    local want = sw.wanted()
    show("craptech_gsw_lever_on_" .. i, want)
    show("craptech_gsw_lever_off_" .. i, not want)
    local light = 0
    if powered then
      if sw.settled(want) then
        light = want and 1 or 0
      else
        light = on and 1 or 0
      end
    end
    e["craptech_gled_" .. i] = light
  end
  -- the fire button: lit while the rockets burn, blinking while they are asked for but not burning
  local fireLight = 0
  if powered and ev("jatoInput") > 0.5 then
    fireLight = (ev("craptech_jato_burning") > 0 or on) and 1 or 0
  end
  e.craptech_firebtn_lit = fireLight
end

local function reset()
  flip, flipTarget = 0, 0
  pressed, firePressed = 0, 0
  shown = {}              -- a reset clears the props' hidden flags: set them again
  boxesOut = nil
  electrics.values.craptech_swpanel = 0
end

local function init(jbeamData)
  flipTime = jbeamData.flipTime or flipTime
  propsByMesh = nil
  reset()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX
M.toggle = toggle
M.press = press
M.fire = fire

return M
