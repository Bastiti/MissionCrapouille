-- Crapouille Technologies sequential LED indicators (vehicles/sunburst2/seqsignals/craptech_seqsignals.jbeam).
--
-- Each time an indicator lights up (signal_L / signal_R, so turn signals and hazards alike) its
-- segments come on one after another - from the inside out on the head and tail lights, from front
-- to back on the mirror repeaters - and stay on until the blink ends, when they all go off together.
-- Every lamp sweeps in the same time whatever its number of segments. If the blink gets too short
-- for the sweep (a faster indicator cycle) the sweep is shortened to fit.
--
-- Electrics written: craptech_seqsig_<lamp>_<side>_<n>, 0..1 (glowMap brightness of segment n).
--
-- jbeam:
--   ["craptechSeqSignal", {"name":"seqSignals", "lamps":[["F", 6], ["B", 4], ["M", 5]], "sweepTime":0.2}]

local M = {}
M.type = "auxiliary"

local min, max = math.min, math.max

local RISE = 0.04          -- s for one segment to come fully on (LED)
local sweepTime = 0.2      -- s from the first segment starting to the last one starting
local lamps = {}           -- {count, names = {L = {...}, R = {...}}}
local sides = {
  L = {signal = "signal_L"},
  R = {signal = "signal_R"},
}

local function write(side, s)
  local ev = electrics.values
  local sweep = min(sweepTime, s.lastOn * 0.55)
  for _, lamp in ipairs(lamps) do
    local names = lamp.names[side]
    local n = lamp.count
    for k = 1, n do
      local start = n > 1 and (k - 1) / (n - 1) * sweep or 0
      ev[names[k]] = s.lit and min(max((s.t - start) / RISE, 0), 1) or 0
    end
  end
end

local function updateGFX(dt)
  for side, s in pairs(sides) do
    local val = electrics.values[s.signal]
    local on = val == true or (type(val) == "number" and val > 0.5)
    if on and not s.lit then
      s.t = 0
    elseif not on and s.lit then
      s.lastOn = s.t
    end
    s.lit = on
    if on then
      s.t = s.t + dt
    end
    write(side, s)
  end
end

local function reset()
  for side, s in pairs(sides) do
    s.lit = false
    s.t = 0
    s.lastOn = math.huge
    write(side, s)
  end
end

local function init(jbeamData)
  sweepTime = jbeamData.sweepTime or sweepTime
  lamps = {}
  for _, l in ipairs(jbeamData.lamps or {}) do
    local key, count = l[1], l[2]
    local lamp = {count = count, names = {L = {}, R = {}}}
    for side in pairs(sides) do
      for k = 1, count do
        lamp.names[side][k] = string.format("craptech_seqsig_%s_%s_%d", key, side, k)
      end
    end
    table.insert(lamps, lamp)
  end
  reset()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX

return M
