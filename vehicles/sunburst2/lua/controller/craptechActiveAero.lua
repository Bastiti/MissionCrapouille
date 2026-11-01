-- Crapouille Technologies active rear wing ("Taxi mode").
-- Writes the wing command electric read by the spoiler hydros in
-- vehicles/sunburst2/aero/craptech_spoiler_active.jbeam:
--   -1 = blade flat (-6 deg)   0 = stock angle   +1 = airbrake (+25 deg)
--
-- On its own switch (toggle(): the dash switch panel; it spawns stowed):
-- Off: the wing is stowed inside the trunk, the lid shut over it.
-- On: the wing comes out, lands on the lid, flicks to full angle, then goes active.
-- Active: the faster the car, the flatter the blade (sport pose up to 40 km/h, fully flat from
-- 160 km/h); braking and cornering add angle back, a hard stop from speed is an airbrake.
-- Below 20 km/h the blade follows the brake pedal. While the bumper JATO burns
-- (craptech_jato_burning) the blade is flat.
-- Nothing moves without power (ignition below accessories): everything holds where it is.
-- The wing needs the car up on the air jacks (craptechAirJacks.lifted(), raised by their own switch
-- only): with the car down it waits, and a move pauses if the car drops (the lid too).
-- Above maxMoveSpeed (10 mph) the wing, its end plates and the lid do not travel: a mode change
-- waits, and a sequence already running holds where it is until the car slows down.
--
-- Pop-up path. The whole wing stands on lift hydros to the body; every hydro has its own
-- input, set from the exact geometry for the current wing position so they never fight.
-- Positions along the path (offsets from the wing's stock place on the lid):
--   0 STOWED    (stowY, -sinkDepth)   inside the trunk
--   1 HOVER     (stowY, +hoverHeight) high enough for the lid to swing under it
--   2 DEPLOYED  (0, 0)                sitting on the closed lid
-- Between 0 and 1 the wing crosses the lid line, so the reverse-hinged lid
-- (craptechReverseLid, which publishes craptech_lid_open) must be fully open; between 1 and 2
-- the wing is over the lid, so it must be shut. The wing waits at the hover point while the
-- lid swings:
--   off -> on: lid opens, wing rises out of the trunk (its end plates sliding out to full width
--              once it is clear of the body), lid shuts under it, wing lands.
--   on -> off: wing lifts off the lid, lid opens while the end plates start sliding in, wing
--              drops into the trunk (the end plates are in before it nears the opening), lid shuts.
-- Without the reverse lid (no craptech_lid_open) the wing simply moves along the path.
--
-- Spawn: the wing is built on the lid (its nodes are there after a spawn or a reset), but the switch
-- spawns at stowed. Then, in the first moments, the wing drops straight down into the trunk through
-- the shut lid (its nodes and triangles collide with nothing on the car), hidden on the way, and
-- shows again once inside. No power or air jacks needed: it is where it should have been built.
--
-- Width: the wing is full stock width on the lid but 22 cm wider than the trunk opening, so
-- its end plates telescope (craptech_wing_narrow: 0 = stock width, 1 = narrow, eased). They are in
-- whenever the wing is lower than CLEAR_HEIGHT above its place on the lid (in or near the trunk
-- opening) and may be out above that, clear of the body: rising, they slide out on the way to the
-- hover point; going down, they slide in while the lid opens and the wing waits at CLEAR_HEIGHT if
-- they are not in yet. At the hover point the wing waits for them and for the lid.
-- Two struts from the rear-glass seam hold the wing (props on node triads, no logic here).
-- A hydraulic pump sound runs while the wing, its end plates or the lid move.

local M = {}
M.type = "auxiliary"

local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt

local wingElectric = "craptech_aero_wing"
local wingOut = false         -- the switch: wing out (spawns stowed)
local taxiMode = nil
local flourishTimer = 0
local airbrakeTimer = 0

local narrow = 0              -- end plates: 0 = stock width, 1 = slid in
local narrowTarget = 0
local narrowTime = 0.7
local CLEAR_HEIGHT = 0.25     -- m above its place on the lid: from here up the end plates may be out
local clearPos = 1            -- path position (rising) where the wing is that high
local slot = 0              -- strut slot covers in the lid: 0 shut .. 1 open
local SLOT_TIME = 0.35
local pumpNode = "spsp_l"
local pumpSound = nil
local pumpPlaying = false
local lastLid = 0

local liftHydros = {}
local stowY, sinkDepth, hoverHeight = -0.07, 0.375, 0.41
local riseTime, landTime = 1.3, 0.8
local pathPos = 2            -- 0 stowed .. 1 hover .. 2 deployed (the wing is built deployed)
local pendingFlourish = false

-- the drop into the trunk after a spawn: 0..1 along a straight line from the lid to the stowed place,
-- then a short wait for the nodes to settle; nil when not dropping
local spawnDrop = nil
local SPAWN_DROP_TIME, SPAWN_SETTLE = 0.8, 0.3
local dropHidden = false
-- what shows of the wing: flexbodies (setMeshAlpha, GE) and props ("hidden" flag); the strut mounts
-- stay, they are fixed to the body
local WING_MESHES = {"craptech_spoiler_blade", "craptech_spoiler_fixed"}
local WING_PROPS = {craptech_spoiler_end_l = true, craptech_spoiler_end_r = true,
                    craptech_spoiler_tip_l = true, craptech_spoiler_tip_r = true,
                    craptech_strut_barrel_l = true, craptech_strut_barrel_r = true,
                    craptech_strut_rod_l = true, craptech_strut_rod_r = true,
                    craptech_strut_tab_l = true, craptech_strut_tab_r = true}

local REST_TARGET = 0.2   -- sport pose when nothing else asks for more
local FLAT_FROM, FLAT_AT = 40 / 3.6, 160 / 3.6   -- speed range over which the blade flattens
local maxMoveSpeed = 10 * 0.44704                 -- 10 mph
local blockedWarned = false
local FLOURISH_TIME = 0.9
local AIRBRAKE_HOLD = 0.4
local G = 9.81

local function smooth(x)
  return x * x * (3 - 2 * x)
end

-- wing offset (dy, dz) from its stock place for a path position
local function pose(u)
  if u <= 1 then
    return stowY, -sinkDepth + (sinkDepth + hoverHeight) * smooth(u)
  end
  local e = smooth(u - 1)
  return stowY * (1 - e), hoverHeight * (1 - e)
end

-- input for one lift hydro with its foot moved by (dy, dz). The hydros map input 0.5 to their
-- built length, 0..0.5 to rmin..1 and 0.5..1 to 1..rmax.
local function liftInput(hy, dy, dz)
  local ex, ey, ez = hy.ax - hy.fx, hy.ay - (hy.fy + dy), hy.az - (hy.fz + dz)
  local ratio = sqrt(ex * ex + ey * ey + ez * ez) / hy.l0
  if ratio >= 1 then
    return 0.5 + 0.5 * (ratio - 1) / (hy.rmax - 1)
  end
  return 0.5 - 0.5 * (1 - ratio) / (1 - hy.rmin)
end

local function writeLift()
  local dy, dz = pose(pathPos)
  if spawnDrop then
    local e = smooth(min(spawnDrop, 1))
    dy, dz = stowY * e, -sinkDepth * e
  end
  for _, hy in ipairs(liftHydros) do
    electrics.values[hy.electric] = liftInput(hy, dy, dz)
  end
  electrics.values.craptech_spoiler_lift = pathPos
  electrics.values.craptech_wing_narrow = smooth(narrow)
  electrics.values.craptech_strut_slot = smooth(slot)
end

-- step the wing along its path towards stowed (switch off) or deployed (taxi), asking the lid to
-- open or shut and the end plates to slide as each stretch needs, and waiting for both at the
-- hover point. Returns true if the wing moved.
local function moveWing(dt, taxi)
  local target = taxi and 2 or 0
  if pathPos == target then
    electrics.values.craptech_lid_request = 0
    narrowTarget = target == 0 and 1 or 0
    return false
  end
  local dir = target > pathPos and 1 or -1
  local lower = (dir > 0 and pathPos < 1) or (dir < 0 and pathPos <= 1)
  electrics.values.craptech_lid_request = lower and 1 or 0
  -- end plates in through the opening, out once the rising wing is clear of the body
  narrowTarget = (lower and not (dir > 0 and pathPos >= clearPos)) and 1 or 0
  local lidOpen = electrics.values.craptech_lid_open
  if lower then
    if lidOpen ~= nil and lidOpen < 1 then
      return false
    end
  else
    if narrow ~= narrowTarget then
      return false
    end
    if lidOpen ~= nil and lidOpen > 0 then
      return false
    end
  end
  local newPos = pathPos + dir * dt / (lower and riseTime or landTime)
  if (pathPos < 1 and newPos > 1) or (pathPos > 1 and newPos < 1) then
    newPos = 1
  end
  if narrow < 1 then
    -- end plates not in: no lower than clearPos (and no lower at all if already below it)
    newPos = max(newPos, min(pathPos, clearPos))
  end
  if dir > 0 then
    newPos = min(newPos, target)
  else
    newPos = max(newPos, target)
  end
  local moved = newPos ~= pathPos
  pathPos = newPos
  return moved
end

-- path position where the rising wing is CLEAR_HEIGHT above its place on the lid (pose() inverted)
local function findClearPos()
  local s = min(max((CLEAR_HEIGHT + sinkDepth) / (sinkDepth + hoverHeight), 0), 1)
  local lo, hi = 0, 1
  for _ = 1, 30 do
    local mid = (lo + hi) / 2
    if smooth(mid) < s then
      lo = mid
    else
      hi = mid
    end
  end
  return hi
end

-- end plates follow narrowTarget at a steady rate (eased in writeLift); true while moving
local function moveEndPlates(dt)
  if narrow < narrowTarget then
    narrow = min(narrow + dt / narrowTime, narrowTarget)
    return true
  elseif narrow > narrowTarget then
    narrow = max(narrow - dt / narrowTime, narrowTarget)
    return true
  end
  return false
end

-- one hydraulic pump for the wing, its end plates and the lid
local function updatePump(running, lidMoving)
  if not pumpSound then
    return
  end
  if running then
    obj:setVolumePitch(pumpSound, 0.55, lidMoving and 0.85 or 0.7)
    if not pumpPlaying then
      obj:cutSFX(pumpSound)
      obj:playSFX(pumpSound)
      pumpPlaying = true
    end
  elseif pumpPlaying then
    obj:stopSFX(pumpSound)
    pumpPlaying = false
  end
end

local function isTaxiMode()
  return wingOut
end

local function toggle()
  wingOut = not wingOut
end

local function wantsOut()
  return wingOut
end

local function groundSpeed()
  return abs(electrics.values.airspeed or electrics.values.wheelspeed or 0)
end

local function activeTarget(dt)
  local speed = electrics.values.wheelspeed or 0
  local brake = electrics.values.brake or 0
  local latG = abs(sensors.gx2 or 0) / G

  if speed < 20 / 3.6 then
    -- stopped: the wing follows the brake pedal, from the sport pose up to full airbrake
    airbrakeTimer = 0
    return REST_TARGET + (1 - REST_TARGET) * min(max(brake, 0), 1)
  end
  if brake > 0.6 and speed > 80 / 3.6 then
    airbrakeTimer = AIRBRAKE_HOLD
  else
    airbrakeTimer = max(airbrakeTimer - dt, 0)
  end
  if airbrakeTimer > 0 then
    return 1
  end
  -- speed sets the base angle: sport pose up to FLAT_FROM, fully flat from FLAT_AT
  local f = min(max((speed - FLAT_FROM) / (FLAT_AT - FLAT_FROM), 0), 1)
  local base = REST_TARGET + (-1 - REST_TARGET) * f
  -- braking and cornering ask for downforce on top of it
  local demand = min(max(max(brake, (latG - 0.3) / 0.6), 0), 1)
  return min(base + 0.65 * demand, 0.6)
end

-- strut slot covers in the lid: the struts pass through the closed lid only with the wing at
-- the hover point or above it, so the covers are open then and shut whenever the wing is below
-- it. They follow the wing's position directly (power or not), so the slots are never left open
-- with the wing inside.
local function updateSlotCovers(dt)
  local slotTarget = pathPos >= 0.98 and 1 or 0
  if slot < slotTarget then
    slot = min(slot + dt / SLOT_TIME, 1)
  elseif slot > slotTarget then
    slot = max(slot - dt / SLOT_TIME, 0)
  end
end

local function showWing(on)
  local cmds = {}
  for _, mesh in ipairs(WING_MESHES) do
    cmds[#cmds + 1] = string.format("v:setMeshAlpha(%d,%q,false)", on and 1 or 0, mesh)
  end
  obj:queueGameEngineLua(string.format("local v = be:getObjectByID(%d) if v then %s end", obj:getId(), table.concat(cmds, " ")))
  for _, prop in pairs(v.data.props or {}) do
    if type(prop) == "table" and WING_PROPS[prop.mesh] and not prop.disabled then   -- broken props stay hidden
      prop.hidden = not on
    end
  end
end

-- the wing, built on the lid, drops hidden into the trunk (see the header)
local function updateSpawnDrop(dt)
  if not dropHidden then
    dropHidden = true
    showWing(false)
  end
  spawnDrop = spawnDrop + dt / SPAWN_DROP_TIME
  writeLift()
  electrics.values[wingElectric] = -1
  electrics.values.craptech_taxi_mode = 0
  if spawnDrop >= 1 + SPAWN_SETTLE / SPAWN_DROP_TIME then
    spawnDrop = nil
    writeLift()
    showWing(true)
    dropHidden = false
  end
end

local function updateGFX(dt)
  if spawnDrop then
    updateSpawnDrop(dt)
    return
  end
  updateSlotCovers(dt)
  -- no power (ignition below accessories): the actuators hold the wing where it is.
  -- The mode change is picked up, with its flourish, once power comes back.
  if (electrics.values.ignitionLevel or 0) < 1 then
    updatePump(false)
    writeLift()
    return
  end

  local taxi = isTaxiMode()
  if taxiMode ~= nil and taxi ~= taxiMode then
    local jacks = controller.getController("craptechAirJacks")
    local wait = (jacks and not jacks.lifted()) and " once the car is up on the air jacks" or ""
    if taxi then
      -- the flick happens once the wing has landed on the shut lid
      pendingFlourish = true
      guihooks.message("Crapouille: TAXI MODE" .. wait, 3, "craptech_taxi")
    else
      flourishTimer = 0
      pendingFlourish = false
      guihooks.message("Crapouille: wing stowed" .. wait, 3, "craptech_taxi")
    end
  end
  taxiMode = taxi

  -- the wing needs the car up on the air jacks (craptechAirJacks), and above maxMoveSpeed nothing
  -- travels: until then hold the wing, its end plates and the lid
  local busy = pathPos ~= (taxi and 2 or 0) or narrow ~= narrowTarget
  local jacks = controller.getController("craptechAirJacks")
  local tooFast = busy and groundSpeed() > maxMoveSpeed
  local hold = tooFast or (busy and jacks ~= nil and not jacks.lifted())
  electrics.values.craptech_lid_hold = hold and 1 or 0
  if tooFast and not blockedWarned then
    guihooks.message("Crapouille wing: slow down below 10 mph to move it", 3, "craptech_taxi")
  end
  blockedWarned = tooFast
  local wingMoved = (not hold) and moveWing(dt, taxi) or false
  local platesMoved = (not hold) and moveEndPlates(dt) or false

  local lid = electrics.values.craptech_lid_open or 0
  local lidMoved = lid ~= lastLid
  lastLid = lid
  updatePump(wingMoved or platesMoved or lidMoved, lidMoved)
  writeLift()
  if pendingFlourish and pathPos >= 2 then
    pendingFlourish = false
    flourishTimer = FLOURISH_TIME
  end

  local target
  if (electrics.values.craptech_jato_burning or 0) > 0 then
    target = -1             -- rocket burning: no drag, no lift, blade flat
  elseif flourishTimer > 0 then
    flourishTimer = flourishTimer - dt
    target = 1
  elseif not taxi or pathPos < 2 then
    target = -1             -- flat while stowed or travelling: lowest profile under the lid
  else
    target = activeTarget(dt)
  end

  electrics.values[wingElectric] = target
  electrics.values.craptech_taxi_mode = taxi and 1 or 0
end

local function reset()
  flourishTimer = 0
  airbrakeTimer = 0
  taxiMode = nil
  pendingFlourish = false
  -- a reset puts every node back where it was built: on the lid. The switch keeps its place;
  -- at stowed (as spawned) the wing drops into the trunk first
  if wingOut then
    pathPos = 2
    narrow, narrowTarget = 0, 0
    slot = 1                -- built pose: wing on the lid, struts through the slots
    spawnDrop = nil
  else
    pathPos = 0
    narrow, narrowTarget = 1, 1
    slot = 0                -- the slots shut at once: the struts are hidden while the wing drops
    spawnDrop = 0
  end
  dropHidden = false
  lastLid = 0
  electrics.values.craptech_lid_request = 0
  writeLift()
end

local function findNode(name)
  for _, n in pairs(v.data.nodes) do
    if n.name == name then
      return n.cid
    end
  end
  return nil
end

local function initSounds()
  local cid = findNode(pumpNode)
  if cid then
    pumpSound = obj:createSFXSource2("event:>Vehicle>Hydraulics>Pump_01", "AudioDefaultLoop3D", "craptechWingPump", cid, 0)
  end
  pumpPlaying = false
end

local function resetSounds()
  if pumpSound and pumpPlaying then
    obj:stopSFX(pumpSound)
  end
  pumpPlaying = false
end

local function init(jbeamData)
  wingElectric = jbeamData.wingElectric or wingElectric
  electrics.values[wingElectric] = -1
  stowY = jbeamData.stowY or stowY
  sinkDepth = jbeamData.sinkDepth or sinkDepth
  hoverHeight = jbeamData.hoverHeight or hoverHeight
  riseTime = jbeamData.riseTime or riseTime
  landTime = jbeamData.landTime or landTime
  narrowTime = jbeamData.narrowTime or narrowTime
  clearPos = findClearPos()
  maxMoveSpeed = jbeamData.maxMoveSpeed or maxMoveSpeed
  pumpNode = jbeamData.pumpNode or pumpNode
  liftHydros = {}
  for _, row in ipairs(jbeamData.liftHydros or {}) do
    table.insert(liftHydros, {electric = row[1], ax = row[2], ay = row[3], az = row[4],
                              fx = row[5], fy = row[6], fz = row[7], l0 = row[8],
                              rmin = row[9], rmax = row[10]})
  end
  wingOut = false
  reset()
end

M.init = init
M.toggle = toggle
M.wantsOut = wantsOut
M.reset = reset
M.updateGFX = updateGFX
M.initSounds = initSounds
M.resetSounds = resetSounds

return M
