-- Crapouille Technologies hidden flashers.
-- Each flasher housing hides inside the body behind a little door. When the lightbar comes on
-- (and there is power) the units come out one after another in list order: the door swings
-- open, then the housing slides out. When it goes off they go back in reverse order: housing
-- in, then door shut. Reversing mid-way just turns the unit around where it is.
--
-- Per unit "<name>" this writes two electrics read by props in the flasher parts:
--   <name>_door   0 = shut .. 1 = open (door prop rotation)
--   <name>_in     1 = housing inside the body .. 0 = out in its working place (prop translation)
-- Nothing here touches physics.
--
-- jbeam:
--   ["craptechFlasherHatch", {"name":"hatchAmber", "units":["craptech_hatch_FL", ...],
--                             "stagger":0.12, "doorTime":0.28, "slideTime":0.32, "startDelay":0}]

local M = {}
M.type = "auxiliary"

local min, max = math.min, math.max

local units = {}
local stagger, doorTime, slideTime, startDelay = 0.12, 0.28, 0.32, 0
local OVERLAP = 0.06      -- the housing starts moving just before the door is fully open
local deployed = false

local function ease(x)
  return x * x * (3 - 2 * x)
end

local function write(u)
  local total = doorTime + slideTime - OVERLAP
  local s = u.pos * total
  local door = min(max(s / doorTime, 0), 1)
  local slide = min(max((s - (doorTime - OVERLAP)) / slideTime, 0), 1)
  electrics.values[u.name .. "_door"] = ease(door)
  electrics.values[u.name .. "_in"] = 1 - ease(slide)
end

local function updateGFX(dt)
  local want = (electrics.values.lightbar or 0) > 0 and (electrics.values.ignitionLevel or 0) >= 1
  local n = #units
  if want ~= deployed then
    deployed = want
    for i, u in ipairs(units) do
      -- deploy in list order, stow in reverse order
      local order = deployed and (i - 1) or (n - i)
      u.wait = (deployed and startDelay or 0) + order * stagger
    end
  end
  local rate = dt / (doorTime + slideTime - OVERLAP)
  local target = deployed and 1 or 0
  for _, u in ipairs(units) do
    if u.wait > 0 then
      u.wait = u.wait - dt
    elseif u.pos ~= target then
      u.pos = target > u.pos and min(u.pos + rate, 1) or max(u.pos - rate, 0)
    end
    write(u)
  end
end

local function reset()
  deployed = false
  for _, u in ipairs(units) do
    u.pos = 0
    u.wait = 0
    write(u)
  end
end

local function init(jbeamData)
  units = {}
  for _, name in ipairs(jbeamData.units or {}) do
    table.insert(units, {name = name, pos = 0, wait = 0})
  end
  stagger = jbeamData.stagger or stagger
  doorTime = jbeamData.doorTime or doorTime
  slideTime = jbeamData.slideTime or slideTime
  startDelay = jbeamData.startDelay or startDelay
  reset()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX

return M
