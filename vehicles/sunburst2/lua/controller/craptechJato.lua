-- Crapouille Technologies twin bumper JATO (vehicles/sunburst2/jato/craptech_jato.jbeam).
--
-- Deploying and firing are separate:
--   M.toggleDeploy()  deploy: the painted panels slide down behind the bumper lip, then the two
--                     rockets come out on their rails. Retract: the reverse (a burn is stopped
--                     first). Needs power (ignition at least accessories). Refused while the
--                     race kit is not fully out (narrow track, craptechTransform).
--   M.toggleFire()    fire / stop. Also driven by electrics.values.jatoInput, the electric of the
--                     stock JATO key, the simple powertrain app button, drag races and AI.
--                     Only burns with the rockets fully out; otherwise it says so.
--
-- Electrics written: craptech_jato_door (0..1), craptech_jato_out (0..1),
-- craptech_jato_thrust (0..1, thruster control), craptech_jato_flame (glow),
-- craptech_jato_burning (0/1, read by craptechActiveAero: blade flat), jato / jatofuel (stock
-- names, for apps).

local M = {}
M.type = "auxiliary"
M.defaultOrder = 1100

local min, max = math.min, math.max

local fuel, initialFuel = 8, 8
local doorTime, slideTime, rampTime = 0.35, 0.35, 0.15
local OVERLAP = 0.05
local deployed = false     -- wanted state of doors + rails
local pos = 0              -- 0 = stowed .. 1 = doors open and rockets fully out
local thrust = 0
local nozzles = {}         -- {nozzle cid, exhaust cid}
local nozzleNames = {{"cj_al", "cj_bl"}, {"cj_ar", "cj_br"}}
local loops = {}
local soundPlaying = false
local smokeTick = 0
local lastFuelRatio = -1
local registered = false
local warnedNotDeployed = false

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

local function msg(text)
  guihooks.message("JATO: " .. text, 2, "craptech_jato")
end

local function updateButton(ratio)
  if extensions.ui_simplePowertrainControl then
    extensions.ui_simplePowertrainControl.setButton("jato_" .. M.name, "JATO", "powertrain_jato", "ff6a00", ratio,
      "electrics.values.jatoInput = 1 - (electrics.values.jatoInput or 0)")
  end
end

local function toggleDeploy()
  if (electrics.values.ignitionLevel or 0) < 1 then
    msg("no power")
    return
  end
  -- no rockets unless the race kit is out (craptechTransform: wide track)
  if not deployed and (electrics.values.craptech_xf_state or 0) > 0 then
    msg("race kit tucked away (wide track brings it out)")
    return
  end
  deployed = not deployed
  if not deployed then
    electrics.values.jatoInput = 0
  end
  msg(deployed and "deploying" or "retracting")
end

-- stow the rockets (used by craptechTransform before it turns the car stock-looking)
local function retract()
  if deployed then
    toggleDeploy()
  end
end

local function toggleFire()
  if fuel <= 0 then
    msg("empty (reset the car to refill)")
    electrics.values.jatoInput = 0
    return
  end
  electrics.values.jatoInput = (electrics.values.jatoInput or 0) > 0.5 and 0 or 1
end

local function setSound(on)
  if on ~= soundPlaying then
    for _, s in ipairs(loops) do
      if on then
        obj:cutSFX(s)
        obj:playSFX(s)
      else
        obj:stopSFX(s)
      end
    end
    soundPlaying = on
  end
  if soundPlaying then
    for _, s in ipairs(loops) do
      obj:setVolume(s, thrust)
    end
  end
end

local function updateGFX(dt)
  local request = (electrics.values.jatoInput or 0) > 0.5
  if request and fuel <= 0 then
    electrics.values.jatoInput = 0
    request = false
  end

  -- firing needs the rockets fully out; the request is not kept if they are not
  if request and pos < 1 then
    if not warnedNotDeployed then
      msg(deployed and "wait, still deploying" or "deploy the rockets first")
      warnedNotDeployed = true
    end
    if not deployed then
      electrics.values.jatoInput = 0
      request = false
    end
  else
    warnedNotDeployed = false
  end

  local burning = request and pos >= 1
  if burning then
    thrust = min(thrust + dt / rampTime, 1)
    fuel = max(fuel - dt * thrust, 0)
    if fuel <= 0 then
      electrics.values.jatoInput = 0
      msg("burnt out")
    end
  else
    thrust = max(thrust - dt / rampTime, 0)
  end

  -- doors and rails (powered); retracting waits for the flame to be out
  if (electrics.values.ignitionLevel or 0) >= 1 then
    local total = doorTime + slideTime - OVERLAP
    if deployed and pos < 1 then
      pos = min(pos + dt / total, 1)
    elseif not deployed and thrust <= 0 and pos > 0 then
      pos = max(pos - dt / total, 0)
    end
  end
  local total = doorTime + slideTime - OVERLAP
  local s = pos * total
  electrics.values.craptech_jato_door = ease(min(max(s / doorTime, 0), 1))
  electrics.values.craptech_jato_out = ease(min(max((s - (doorTime - OVERLAP)) / slideTime, 0), 1))

  electrics.values.craptech_jato_thrust = thrust
  electrics.values.craptech_jato_flame = thrust > 0.05 and 1 or 0
  electrics.values.craptech_jato_burning = thrust > 0 and 1 or 0
  electrics.values.jato = thrust

  if thrust > 0 then
    smokeTick = smokeTick + dt * thrust * 60
    if smokeTick > 1 then
      for _, n in ipairs(nozzles) do
        obj:addParticleByNodes(n[1], n[2], 20, 81, 0.01, 1)
      end
      smokeTick = 0
    end
  end
  setSound(thrust > 0)

  local ratio = initialFuel > 0 and fuel / initialFuel or 0
  electrics.values.jatofuel = ratio
  if math.abs(ratio - lastFuelRatio) > 0.01 then
    lastFuelRatio = ratio
    updateButton(ratio)
  end
end

local function registerQuickAccess()
  if registered or not core_quickAccess then
    return
  end
  core_quickAccess.addEntry({
    level = "/root/playerVehicle/", uniqueID = "craptech_jato_deploy", title = "JATO: deploy / retract", icon = "powertrain_jato",
    onSelect = function()
      toggleDeploy()
      return {"reload"}
    end
  })
  core_quickAccess.addEntry({
    level = "/root/playerVehicle/", uniqueID = "craptech_jato_fire", title = "JATO: fire / stop", icon = "powertrain_jato",
    onSelect = function()
      toggleFire()
      return {"reload"}
    end
  })
  registered = true
end

local function reset()
  fuel = initialFuel
  deployed = false
  pos = 0
  thrust = 0
  smokeTick = 0
  lastFuelRatio = -1
  warnedNotDeployed = false
  electrics.values.jatoInput = 0
  setSound(false)
  updateGFX(0)
end

local function initSounds()
  loops = {}
  for i, n in ipairs(nozzles) do
    table.insert(loops, obj:createSFXSource2("event:>Vehicle>Thrusters", "AudioDefaultLoop3D", "craptechJatoLoop" .. i, n[1], 0))
  end
  soundPlaying = false
end

local function resetSounds()
  setSound(false)
end

local function init(jbeamData)
  initialFuel = jbeamData.fuel or initialFuel
  doorTime = jbeamData.doorTime or doorTime
  slideTime = jbeamData.slideTime or slideTime
  rampTime = jbeamData.thrustRampTime or rampTime
  nozzleNames = jbeamData.nozzles or nozzleNames
  nozzles = {}
  for _, pair in ipairs(nozzleNames) do
    local a, b = findNode(pair[1]), findNode(pair[2])
    if a and b then
      table.insert(nozzles, {a, b})
    end
  end
  reset()
  registerQuickAccess()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX
M.initSounds = initSounds
M.resetSounds = resetSounds
M.toggleDeploy = toggleDeploy
M.retract = retract
M.toggleFire = toggleFire
M.toggle = toggleFire

return M
