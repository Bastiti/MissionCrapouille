-- Sweeps the tachometer and speedometer needles to full scale then back down when the engine starts

local M = {}

local sweepUpTime = 1
local sweepDownTime = 1
local sweepTotalTime = sweepUpTime + sweepDownTime
local maxRPM = 8000
local idleRPM = 0
-- Full scale of the speedo needle (km/h), converted to the m/s that electrics.wheelspeed carries
local maxSpeed = 260 / 3.6
local restSpeed = 0

local sweeping = false
local sweepTimer = 0
local lastIgnitionLevel = 0

local function easeOut(t)
  return 1 - (1 - t) * (1 - t)
end

local function updateGFX(dt)
  local ignitionLevel = electrics.values.ignitionLevel or 0

  -- Detect key turned from off to accessory/on (rising edge: 0 -> >0)
  if ignitionLevel > 0 and lastIgnitionLevel == 0 then
    sweeping = true
    sweepTimer = 0
  end
  lastIgnitionLevel = ignitionLevel

  if sweeping then
    sweepTimer = sweepTimer + dt
    if sweepTimer <= sweepUpTime then
      local t = easeOut(sweepTimer / sweepUpTime)
      electrics.values.rpm = maxRPM * t
      electrics.values.wheelspeed = maxSpeed * t
    elseif sweepTimer <= sweepTotalTime then
      local t = easeOut((sweepTimer - sweepUpTime) / sweepDownTime)
      electrics.values.rpm = maxRPM + (idleRPM - maxRPM) * t
      electrics.values.wheelspeed = maxSpeed + (restSpeed - maxSpeed) * t
    else
      sweeping = false
    end
  end
end

local function reset()
  sweeping = false
  sweepTimer = 0
  -- Synchronize state on spawn/reset so the current state isn't misread as a new start
  lastIgnitionLevel = (electrics.values and electrics.values.ignitionLevel) or 0
end

M.init = reset
M.reset = reset
M.updateGFX = updateGFX

return M
