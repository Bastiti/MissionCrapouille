-- Crapouille Technologies matrix LED high beam (vehicles/sunburst2/matrix/craptech_matrix_highbeam.jbeam).
-- One instance per headlight.
--
-- The part makes the headlight's high beam out of vertical slices, one SPOTLIGHT each. While the
-- high beam is on, every slice that would shine on another vehicle fades out, so oncoming and
-- preceding drivers sit in a dark tunnel while the rest of the road stays on high beam. Vehicles
-- are the ones the map tracks (traffic, AI, other cars), except parked ones, ones switched off and
-- ones the lamp can't see past terrain or buildings.
--
-- Electrics written, with the jbeam "func" prefix (craptech_mx_<lamp node>_):
--   <prefix>01 .. <prefix>NN  slices 0..1, left to right as seen from the driver's seat
--
-- jbeam:
--   ["craptechMatrixBeam", {"name":"matrixBeam_he4l", "func":"craptech_mx_he4l_", "lampNode":"he4l",
--                           "electric":"highbeam_filament", "edges":[-55, ..., 55], "spill":[...]}]
--   edges: slice limits in degrees of bearing, + = driver's right; spill: how far each slice's soft
--   edge reaches past its limits (both written by gen_matrix.py)

local M = {}
M.type = "auxiliary"

local min, max = math.min, math.max
local atan2, deg, huge = math.atan2, math.deg, math.huge

local FADE_OUT = 0.15      -- s, a slice switching off
local FADE_IN = 0.45       -- s, a slice coming back
local HOLD = 0.6           -- s a slice stays off after the last vehicle has left it
local SWITCH_TIME = 0.05   -- s, LED on / off
local SCAN_PERIOD = 0.05   -- s between two looks at the traffic
local RANGE = 300          -- m, further vehicles are ignored
local MARGIN = 0.4         -- deg of extra darkness either side of a vehicle (the slices' soft
                           -- edges already fade the light out around it)
local CAMERA_HEIGHT = 0.7  -- m above the lamp: line of sight is checked from windscreen height
local TARGET_HEIGHT = 0.8  -- m above the other vehicle's reference point
local NO_STATES = {}

local source = "highbeam"
local lampName
local lampCid
local edges = {}
local spill = {}
local names = {}
local count = 0
local level = {}           -- slice brightness 0..1 (before easing)
local hold = {}            -- s left before a slice may come back
local masked = {}          -- result of the last scan: a vehicle is in the slice
local beam = 0             -- LED switch ramp 0..1
local scanTimer = 0

local function ease(x)
  return x * x * (3 - 2 * x)
end

local function findNode(name)
  for _, n in pairs(v.data.nodes) do
    if n.name == name then
      return n.cid
    end
  end
  return nil
end

local function highBeamOn()
  local val = electrics.values[source]
  return val == true or (type(val) == "number" and val > 0.5)
end

local function maskRange(lo, hi)
  lo, hi = lo - MARGIN, hi + MARGIN
  for i = 1, count do
    if edges[i] - spill[i] < hi and edges[i + 1] + spill[i] > lo then
      masked[i] = true
    end
  end
end

local function scan()
  for i = 1, count do
    masked[i] = false
  end
  if not lampCid then
    return
  end
  local objects = mapmgr.getObjects()
  local myId = obj:getId()
  local lamp = obj:getPosition() + obj:getNodePosition(lampCid)
  local fwd = obj:getDirectionVector()
  local up = obj:getDirectionVectorUp()
  local right = fwd:cross(up)
  local eye = lamp + up * CAMERA_HEIGHT
  for id, o in pairs(objects) do
    local states = o.states or NO_STATES
    -- (o.active only says whether a player sits in it)
    if id ~= myId and not o.isParked and states.ignitionLevel ~= 0 then
      local toCar = o.pos - lamp
      if toCar:length() < RANGE and toCar:dot(fwd) > 0 then
        -- bearings of the four corners of the other vehicle's footprint
        local front = vec3(obj:getObjectFrontPositionXYZ(id)) - lamp
        local back = front - o.dirVec * obj:getObjectInitialLength(id)
        local side = o.dirVec:cross(o.dirVecUp)
        side = side * (obj:getObjectInitialWidth(id) * 0.5 / max(side:length(), 1e-6))
        local lo, hi, behind = huge, -huge, false
        for _, p in ipairs({front + side, front - side, back + side, back - side}) do
          local ahead = p:dot(fwd)
          if ahead > 0.3 then
            local a = deg(atan2(p:dot(right), ahead))
            lo, hi = min(lo, a), max(hi, a)
          else
            behind = true
          end
        end
        if lo <= hi then
          -- alongside us: it reaches the edge of the beam on its side
          if behind then
            if toCar:dot(right) > 0 then hi = 90 else lo = -90 end
          end
          local target = o.pos + o.dirVecUp * TARGET_HEIGHT
          local ray = target - eye
          local dist = ray:length()
          if dist < 1 or obj:castRayStatic(eye, ray * (1 / dist), dist) >= dist - 0.5 then
            maskRange(lo, hi)
          end
        end
      end
    end
  end
end

local function write()
  local ev = electrics.values
  for i = 1, count do
    ev[names[i]] = beam * ease(level[i])
  end
end

local function updateGFX(dt)
  local on = highBeamOn()
  if on and beam == 0 then
    -- switching on: the slices that should be dark start dark
    scan()
    for i = 1, count do
      level[i] = masked[i] and 0 or 1
      hold[i] = masked[i] and HOLD or 0
    end
    scanTimer = SCAN_PERIOD
  end
  beam = on and min(beam + dt / SWITCH_TIME, 1) or max(beam - dt / SWITCH_TIME, 0)

  if beam > 0 then
    scanTimer = scanTimer - dt
    if scanTimer <= 0 then
      scanTimer = SCAN_PERIOD
      scan()
    end
    for i = 1, count do
      if masked[i] then
        hold[i] = HOLD
        level[i] = max(level[i] - dt / FADE_OUT, 0)
      elseif hold[i] > 0 then
        hold[i] = hold[i] - dt
      else
        level[i] = min(level[i] + dt / FADE_IN, 1)
      end
    end
  end
  write()
end

local function reset()
  beam = 0
  scanTimer = 0
  for i = 1, count do
    level[i] = 1
    hold[i] = 0
    masked[i] = false
  end
  write()
end

local function init(jbeamData)
  local prefix = jbeamData.func or "craptech_mx_"
  source = jbeamData.electric or "highbeam"
  -- the stock slot wires a halogen bulb to the slow filament value; LEDs switch at once
  if source == "highbeam_filament" then
    source = "highbeam"
  end
  lampName = jbeamData.lampNode
  lampCid = lampName and findNode(lampName)
  if not lampCid then
    log("E", "craptechMatrixBeam", "lamp node not found: " .. tostring(lampName))
  end
  edges = jbeamData.edges or {-55, 55}
  count = #edges - 1
  names = {}
  spill = {}
  for i = 1, count do
    names[i] = prefix .. string.format("%02d", i)
    spill[i] = jbeamData.spill and jbeamData.spill[i] or 0
  end
  reset()
end

-- for checking in game: which slices are masked / lit right now
local function getState()
  local t = {beam = beam, masked = {}, level = {}}
  for i = 1, count do
    t.masked[i] = masked[i] and 1 or 0
    t.level[i] = math.floor(level[i] * 100 + 0.5) / 100
  end
  return t
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX
M.getState = getState

return M
