-- Crapouille digital cluster (vehicles/fullsize/cluster/craptech_cluster.jbeam, a copy of the fullsize's "Dashboard"
-- part): the analog gauges give way to one screen filling the cluster's opening, an HTML page
-- (craptech_cluster.html) drawn into the texture webView: speedometer, tachometer with the gear, coolant and fuel,
-- warning lights, and in the middle a map, the trip computer or the engine's readings (nextPage, a click on the
-- screen; resetTrip, a middle click). From the accessory position it shows the clock and odometer; switched on, it
-- greets, sweeps its needles and checks its lamps, like a car's.
--
-- The page gets its settings with cluster.setup (units, scales, the vehicle id it asks the map for: the game's
-- dashboard map, extensions.ui_uiNavi.requestVehicleDashboardMap, as the stock digital clusters), sent on change and
-- again every 2 s in case the page reloaded, and the car's state with cluster.update while someone sits in it: one at
-- a time, the next once the page has acknowledged it (ack, through GE; again after ACK_TIMEOUT without). Sent each
-- frame through the game's stream channel instead, the states queued up (the page runs at the 15 frames a second
-- the game gives a vehicle texture) and the cluster showed the car as it was minutes before, ever later.
-- The glowMap shows the page glowing through the screen's dark
-- glass while it is lit (electric craptech_cluster_lit: 1 bright, 0.5 dimmed with the headlights on; held a moment
-- after switching off for the page to fade out), the bare glass otherwise. The screen materials are reloaded once
-- the page texture is there (see craptechLimoTV.lua).
--
-- The automatic shifter's gear needle (a prop of the shifter part, which ran along the stock face) is hidden.
-- No electric gives the battery voltage: it is modelled (12.4 V at rest, sagging while cranking, 14.2 V charging).
--
-- jbeam: ["craptechCluster", {"htmlPath":"local://local/vehicles/fullsize/cluster/craptech_cluster.html",
--          "webView":"@craptech_cluster", "screenMaterials":["craptech_dcl_night", "craptech_dcl_day"], "textureWidth":1280,
--          "textureHeight":364, "textureFPS":60, "hideProps":["fullsize_needle_gear"]}]

local M = {}
M.type = "auxiliary"

local htmlTexture = require("htmlTexture")

local max, min, abs, exp, floor = math.max, math.min, math.abs, math.exp, math.floor

local PAGES = 3            -- map, trip, engine
local RESEND_TIME = 2
local REFRESH_DELAY = 0.5  -- s after creating the page texture before reloading the screen material
local FADE_TIME = 1        -- s the screen stays lit after switching off, for the page to fade out
local VOLT_TAU = 0.4       -- s, time constant of the modelled battery voltage
local ACK_TIMEOUT = 1      -- s without the page's acknowledgement before sending the state again (page reloading)

local webView = "@craptech_cluster"
local screenMaterials = {"craptech_dcl_night", "craptech_dcl_day"}
local texture = nil
local refresh = nil        -- s left before reloading the screen material (nil: done)
local hideProps = {}       -- prop meshes hidden (by name)
local hidden = false
local engine = nil
local setupData = {}
local setupSent = nil
local resend = 0
local page = 1
local fade = 0
local volts = 0
local tripBase = 0         -- relative odometer (m) when the trip was reset
local tripTime = 0         -- s driven (engine running) since
local tripFuel = 0         -- l burnt since
local lastFuel = nil
local waiting = nil        -- s since the last state was sent while the page hasn't acknowledged it (nil: it has)
local data = {}

-- a number fit to send: jsonEncode writes NaN as an infinity, which once froze the page's drawing
local function num(x)
  if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then return 0 end
  return x
end

-- a lamp: electrics give 0/1 or true/false (the blinkers)
local function flag(x)
  return (x == true or type(x) == "number" and x == x and x ~= 0) and 1 or 0
end

local function nextPage()
  page = page % PAGES + 1
  setupSent = nil
end

-- the page took the last state (called through GE)
local function ack()
  waiting = nil
end

local function resetTrip()
  tripBase = extensions.odometer and extensions.odometer.getRelativeRecording() or 0
  tripTime, tripFuel = 0, 0
end

-- hides the props of other parts this cluster replaces (props.reset shows them again)
local function hide()
  for _, p in pairs(v.data.props or {}) do
    if hideProps[p.mesh] then
      p.hidden = true
    end
  end
  hidden = true
end

local function sendSetup()
  setupData.page = page
  setupData.vid = obj:getID()
  local text = jsonEncode(setupData)
  if text ~= setupSent then
    texture:callJS("cluster.setup", setupData)
    setupSent = text
  end
end

local function updateGFX(dt)
  if not texture then return end
  if refresh then
    refresh = refresh - dt
    if refresh <= 0 then
      refresh = nil
      for _, name in ipairs(screenMaterials) do
        obj:queueGameEngineLua(string.format("local m = scenetree.findObject(%q) if m then m:reload() end", name))
      end
    end
  end
  if not hidden then hide() end

  local e = electrics.values
  local ign = e.ignitionLevel or 0
  fade = ign >= 1 and FADE_TIME or max(fade - dt, 0)
  local night = flag(e.lowbeam) + flag(e.highbeam) > 0
  e.craptech_cluster_lit = fade <= 0 and 0 or night and 0.5 or 1

  -- the battery: resting voltage, sagging under the starter, charging with the engine running
  local running = (e.engineRunning or 0) > 0.5
  local target = ign < 1 and 12.6 or ign >= 3 and 10.4 or running and 14.2 - 0.3 * (e.engineLoad or 0) or 12.3
  volts = volts > 0 and volts + (target - volts) * (1 - exp(-dt / VOLT_TAU)) or target

  -- the trip computer: distance from the odometer extension, time and fuel while the engine runs
  local fuelVolume = e.fuelVolume or 0
  if lastFuel and lastFuel - fuelVolume > 0 and lastFuel - fuelVolume < 0.5 then
    tripFuel = tripFuel + lastFuel - fuelVolume    -- a refill or a reset doesn't count
  end
  lastFuel = fuelVolume
  if running then tripTime = tripTime + dt end

  resend = resend - dt
  if resend <= 0 then
    resend = RESEND_TIME
    setupSent = nil
  end
  sendSetup()

  if waiting then
    waiting = waiting + dt
    if waiting < ACK_TIMEOUT then return end
  end
  if not playerInfo.anyPlayerSeated then return end
  local x, y = obj:getPositionXYZ()
  local dir = obj:getDirectionVector()
  local d = data
  d.vid = obj:getID()
  d.ign = num(ign)
  d.run = running and 1 or 0
  d.spd = abs(num(e.wheelspeed))
  d.rpm = num(e.rpm)
  d.gear = tostring(e.gear or "")
  d.gi = num(e.gearIndex)
  d.thr = num(e.throttle)
  d.fuel = num(e.fuel)
  d.fv = num(fuelVolume)
  d.wt = num(e.watertemp)
  d.ot = num(e.oiltemp)
  d.v = num(volts)
  d.sl = flag(e.signal_L)
  d.sr = flag(e.signal_R)
  d.lb = flag(e.lowbeam)
  d.hb = flag(e.highbeam)
  d.fog = flag(e.fog)
  d.pb = flag(e.parkingbrakelight)
  d.abs = flag(e.abs)
  d.ce = flag(e.checkengine)
  d.lf = flag(e.lowfuel)
  d.tp = flag(e.lowpressure)
  d.cc = flag(e.cruiseControlActive)
  d.odo = num(e.odometer)
  d.trip = max(num((extensions.odometer and extensions.odometer.getRelativeRecording() or 0) - tripBase), 0)
  d.tt = num(tripTime)
  d.tf = num(tripFuel)
  d.x, d.y = num(x), num(y)
  d.dx, d.dy = num(dir.x), num(dir.y)
  d.env = num(obj:getEnvTemperature() - 273.15)
  d.time = os.date("%H:%M")
  texture:callJS("cluster.update", d)
  waiting = 0
end

local function reset()
  hidden = false
  setupSent = nil
  lastFuel = nil
  waiting = nil
end

local function initSecondStage(jbeamData)
  engine = powertrain.getDevice("mainEngine")
  local maxRPM = engine and engine.maxRPM or electrics.values.maxrpm or 6000
  setupData = {
    maxRPM = maxRPM,
    idleRPM = engine and engine.idleRPM or 700,
    fuelCapacity = electrics.values.fuelCapacity or 0,
    uiUnitLength = settings.getValue("uiUnitLength") or "metric",
    uiUnitTemperature = settings.getValue("uiUnitTemperature") or "c",
    uiUnitVolume = settings.getValue("uiUnitVolume") or "l",
    uiUnitConsumptionRate = settings.getValue("uiUnitConsumptionRate") or "metric",
    uiUnitDate = settings.getValue("uiUnitDate") or "ger",
    webView = webView,
  }
  setupSent = nil
end

local function init(jbeamData)
  webView = jbeamData.webView or webView
  screenMaterials = jbeamData.screenMaterials or screenMaterials
  hideProps = {}
  for _, name in ipairs(jbeamData.hideProps or {}) do
    hideProps[name] = true
  end
  texture = htmlTexture.new(webView, jbeamData.htmlPath or "local://local/vehicles/fullsize/cluster/craptech_cluster.html",
    jbeamData.textureWidth or 1280, jbeamData.textureHeight or 364, jbeamData.textureFPS or 60, "automatic")
  refresh = REFRESH_DELAY
  page = 1
  fade = (electrics.values.ignitionLevel or 0) >= 1 and FADE_TIME or 0
  volts = 0
  resetTrip()
  reset()
end

M.init = init
M.initSecondStage = initSecondStage
M.reset = reset
M.updateGFX = updateGFX
M.nextPage = nextPage
M.resetTrip = resetTrip
M.ack = ack

return M
