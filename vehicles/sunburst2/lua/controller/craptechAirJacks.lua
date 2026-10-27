-- Crapouille Technologies air jacks + live track width.
-- Four feet under the floor rails, each pushed straight down by four hydros
-- (vehicles/sunburst2/aero/craptech_airjacks.jbeam). This controller moves the drop
-- distance d and, for every hydro, sets its input electric to the exact value that puts its
-- foot at (x, y, z - d), so the four hydros of each foot agree through the whole stroke.
-- Raising is a smooth push; lowering is a drop (fast), like real pit air jacks.
--
-- Track width: the axle nodes (fw1*/rw1*) are held by the knuckle beams (fh*/fs*/rh*). To
-- move a wheel out by w, each of those beams gets the rest length that puts its axle node
-- w further out (setBeamLengthRefRatio, the same call hydros use). Only done with the car
-- up on the jacks.
--
-- The race kit (craptechTransform) and the rear wing (craptechActiveAero) follow the wanted
-- track (wantsWide): out with the wide track, tucked away with the narrow one. Going wide, the
-- wheels wait up on the jacks until the fender flares are out over them; going narrow, the
-- flares tuck in once the wheels are back.
--
-- Actions (Controls > Vehicle Specific, and the radial menu):
--   toggle()       jacks up / drop the car
--   toggleTrack()  jacks up -> wheels a few cm wider (or back) -> drop the car
-- Needs power (ignition at least accessories). Above 10 mph (real ground speed, not wheel
-- speed) the jacks neither start nor move: a running stroke holds until the car slows down.

local M = {}
M.type = "auxiliary"

local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max
local MAX_MOVE_SPEED = 10 * 0.44704   -- 10 mph

local function groundSpeed()
  return abs(electrics.values.airspeed or electrics.values.wheelspeed or 0)
end

local hydros = {}
local stroke, raiseTime, dropTime = 0.42, 1.5, 0.25
local drop = 0          -- current drop distance (m)
local wantUp = false    -- true = jacks extended, car lifted
local registered = false

local trackBeams = {}
local trackDelta = 0.03 -- wheel moves out this much per side when wide (m)
local trackTime = 0.8
local track = 0         -- current widening, 0 = stock, 1 = wide
local trackTarget = 0
local sequence = nil    -- nil, "raise", "track", "drop"

local function hydroInput(h, d)
  local dx, dy, dz = h.ax - h.fx, h.ay - h.fy, h.az - (h.fz - d)
  local ratio = sqrt(dx * dx + dy * dy + dz * dz) / h.l0
  return (ratio - 1) / (h.r - 1)
end

local function powered()
  return (electrics.values.ignitionLevel or 0) >= 1
end

local function canLift()
  if not powered() then
    guihooks.message("Air jacks: no power", 2, "craptech_airjacks")
    return false
  end
  if groundSpeed() > MAX_MOVE_SPEED then
    guihooks.message("Air jacks: slow down below 10 mph first", 2, "craptech_airjacks")
    return false
  end
  return true
end

local function toggle()
  if sequence then
    return
  end
  if not wantUp and not canLift() then
    return
  end
  if wantUp and not powered() then
    guihooks.message("Air jacks: no power", 2, "craptech_airjacks")
    return
  end
  wantUp = not wantUp
  guihooks.message(wantUp and "Air jacks: UP" or "Air jacks: drop", 2, "craptech_airjacks")
end

local function toggleTrack()
  if sequence or #trackBeams == 0 then
    return
  end
  if not wantUp and not canLift() then
    return
  end
  trackTarget = trackTarget > 0.5 and 0 or 1
  wantUp = true
  sequence = "raise"
  guihooks.message(trackTarget > 0.5 and "Track: going wide" or "Track: going narrow", 2, "craptech_airjacks")
end

-- the track asked for (set as soon as the button is pressed): craptechTransform and
-- craptechActiveAero bring the race kit and the wing out with the wide one
local function wantsWide()
  return trackTarget > 0.5
end

local function applyTrack()
  local w = trackDelta * track
  for _, b in ipairs(trackBeams) do
    local dx = b.hx - (b.wx + b.side * w)
    local dy, dz = b.hy - b.wy, b.hz - b.wz
    obj:setBeamLengthRefRatio(b.cid, b.precomp * sqrt(dx * dx + dy * dy + dz * dz) / b.l0)
  end
end

local function updateGFX(dt)
  if powered() and groundSpeed() <= MAX_MOVE_SPEED then
    local target = wantUp and stroke or 0
    if drop < target then
      drop = min(drop + stroke / raiseTime * dt, target)
    elseif drop > target then
      drop = max(drop - stroke / dropTime * dt, target)
    end

    if sequence == "raise" and drop >= stroke then
      sequence = "track"
    elseif sequence == "track" and (trackTarget < track or (electrics.values.craptech_xf_state or 0) <= 0) then
      -- going wide, the wheels wait for the fender flares to be out (craptechTransform)
      local step = dt / trackTime
      local before = track
      track = track < trackTarget and min(track + step, trackTarget) or max(track - step, trackTarget)
      if track ~= before then
        applyTrack()
      end
      if track == trackTarget then
        sequence = "drop"
        wantUp = false
      end
    elseif sequence == "drop" and drop <= 0 then
      sequence = nil
    end
  end
  for _, h in ipairs(hydros) do
    electrics.values[h.electric] = hydroInput(h, drop)
  end
  electrics.values.craptech_airjacks = drop / stroke
  electrics.values.craptech_track_wide = track
end

local AXLE = {fw1l = 1, fw1ll = 1, fw1r = -1, fw1rr = -1, rw1l = 1, rw1ll = 1, rw1r = -1, rw1rr = -1}

local function findTrackBeams()
  trackBeams = {}
  local nodes = v.data.nodes
  for _, b in pairs(v.data.beams or {}) do
    local n1, n2 = nodes[b.id1], nodes[b.id2]
    if n1 and n2 and n1.name and n2.name then
      local wheel, hub = n1, n2
      if not AXLE[wheel.name] then
        wheel, hub = n2, n1
      end
      -- knuckle beams only: crash-support beams to the body are left alone
      if AXLE[wheel.name] and not AXLE[hub.name] and (hub.name:match("^[fr]h%d") or hub.name:match("^fs%d")) then
        local wp, hp = wheel.pos, hub.pos
        local dx, dy, dz = hp.x - wp.x, hp.y - wp.y, hp.z - wp.z
        table.insert(trackBeams, {
          cid = b.cid, side = AXLE[wheel.name],
          wx = wp.x, wy = wp.y, wz = wp.z, hx = hp.x, hy = hp.y, hz = hp.z,
          l0 = sqrt(dx * dx + dy * dy + dz * dz),
          precomp = tonumber(b.beamPrecompression) or 1,
        })
      end
    end
  end
end

local function registerQuickAccess()
  if registered then
    return
  end
  core_quickAccess.addEntry({
    level = "/root/playerVehicle/",
    uniqueID = "craptech_airjacks",
    title = "Air Jacks",
    icon = "axleLift",
    onSelect = function()
      toggle()
      return {"reload"}
    end
  })
  core_quickAccess.addEntry({
    level = "/root/playerVehicle/",
    uniqueID = "craptech_track",
    title = "Wide / Narrow Track",
    icon = "twoArrowsHorizontal",
    onSelect = function()
      toggleTrack()
      return {"reload"}
    end
  })
  registered = true
end

local function reset()
  -- a vehicle reset restores every beam, so the track is back to stock
  drop = 0
  wantUp = false
  sequence = nil
  track = 0
  trackTarget = 0
  updateGFX(0)
end

local function init(jbeamData)
  stroke = jbeamData.stroke or stroke
  raiseTime = jbeamData.travelTime or raiseTime
  dropTime = jbeamData.dropTime or dropTime
  trackDelta = jbeamData.trackDelta or trackDelta
  hydros = {}
  for _, row in ipairs(jbeamData.hydros or {}) do
    table.insert(hydros, {electric = row[1], ax = row[2], ay = row[3], az = row[4],
                          fx = row[5], fy = row[6], fz = row[7], l0 = row[8], r = row[9]})
  end
  reset()
  registerQuickAccess()
end

local function initSecondStage()
  findTrackBeams()
end

M.init = init
M.initSecondStage = initSecondStage
M.reset = reset
M.updateGFX = updateGFX
M.toggle = toggle
M.toggleTrack = toggleTrack
M.wantsWide = wantsWide

return M
