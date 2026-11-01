-- Crapouille Technologies reverse-hinged trunk lid (trunk/craptech_trunk_reverse.jbeam).
-- The lid turns about an axis along x at the bottom of the rear panel (axisY, axisZ): the
-- front edge lifts and the lid swings up and back, Taxi 2 style. Lid hydros run from the body
-- to lid nodes; for the current lid angle each hydro's input is set to the exact length that
-- puts its lid node where the rotation says, so the hydros never fight each other.
--
-- Interface (electrics):
--   craptech_lid_request  written by others (craptechActiveAero): 1 = open, 0 = closed
--   craptech_lid_open     written here: 0 = shut .. 1 = fully open
--   craptech_lid_hold     written by others: 1 = do not move (car too fast, or not up on the air jacks yet)
-- Nothing moves without power (ignition at least accessories).

local M = {}
M.type = "auxiliary"

local sqrt, sin, cos, min, max = math.sqrt, math.sin, math.cos, math.min, math.max

local hydros = {}
local openAngle, openTime = math.rad(70), 0.9
local axisY, axisZ = 2.17, 0.57
local pos = 0   -- 0 = shut, 1 = open (linear in time, eased for the angle)

-- input for one hydro with the lid turned by phi; inputs 0..0.5..1 map to rmin..1..rmax
local function hydroInput(h, phi)
  local dy, dz = h.ly - axisY, h.lz - axisZ
  local c, s = cos(phi), sin(phi)
  local y, z = axisY + dy * c + dz * s, axisZ + dz * c - dy * s
  local ex, ey, ez = h.ax - h.lx, h.ay - y, h.az - z
  local ratio = sqrt(ex * ex + ey * ey + ez * ez) / h.l0
  if ratio >= 1 then
    return 0.5 + 0.5 * (ratio - 1) / (h.rmax - 1)
  end
  return 0.5 - 0.5 * (1 - ratio) / (1 - h.rmin)
end

local function write()
  local e = pos * pos * (3 - 2 * pos)
  local phi = openAngle * e
  for _, h in ipairs(hydros) do
    electrics.values[h.electric] = hydroInput(h, phi)
  end
  electrics.values.craptech_lid_open = pos
end

local function updateGFX(dt)
  -- craptech_lid_hold (craptechActiveAero: car above 10 mph or not up on the jacks yet): the lid stays where it is
  if (electrics.values.ignitionLevel or 0) >= 1 and (electrics.values.craptech_lid_hold or 0) < 0.5 then
    local target = (electrics.values.craptech_lid_request or 0) > 0.5 and 1 or 0
    if pos < target then
      pos = min(pos + dt / openTime, target)
    elseif pos > target then
      pos = max(pos - dt / openTime, target)
    end
  end
  write()
end

local function reset()
  pos = 0
  electrics.values.craptech_lid_request = 0
  write()
end

local function init(jbeamData)
  openAngle = math.rad(jbeamData.openAngle or 70)
  openTime = jbeamData.openTime or openTime
  axisY = jbeamData.axisY or axisY
  axisZ = jbeamData.axisZ or axisZ
  hydros = {}
  for _, row in ipairs(jbeamData.hydros or {}) do
    table.insert(hydros, {electric = row[1], ax = row[2], ay = row[3], az = row[4],
                          lx = row[5], ly = row[6], lz = row[7], l0 = row[8],
                          rmin = row[9], rmax = row[10]})
  end
  reset()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX

return M
