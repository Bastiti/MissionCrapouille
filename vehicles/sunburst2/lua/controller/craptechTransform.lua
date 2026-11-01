-- Crapouille Technologies transform (vehicles/sunburst2/transform/craptech_transform.jbeam).
--
-- On its own switch (toggle(), the glove box panel) the race add-ons tuck away, mechanically: the fender flares sink into
-- the body (a ring of tiles round each arch, all together), turn over out of sight inside it and
-- rise back out, flush, as the plain panel each tile carries on its back; the side skirts fold in
-- about their top edge until they hang straight like the stock skirt (their lower half swings up
-- under the sill); the splitter slides into the bumper in pieces and rises out of sight (its centre
-- piece stays, flush, as the bumper's lower edge, and a lower lip hidden inside the splitter closes
-- the bumper round the corners); and the diffuser fins fold up into the diffuser, sliding doors
-- closing the slots behind them. The switch again brings them back out. Nothing is swapped for
-- another part. The kit spawns tucked away (the stock look); a reset keeps what the switch says.
--
-- It needs the car up on the air jacks (craptechAirJacks.lifted(), raised by their own switch only):
-- with the car down it waits, and a move pauses if the car drops. Like the wing and the air jacks
-- it only moves with power on and below 10 mph (it waits otherwise). Before tucking away it stows
-- the JATO if it is out.
--
-- How: each add-on is a prop (a rigid mesh riding on three of the nodes it sits on), in the race look
-- too: a replay records props but not meshes faded with setMeshAlpha, so nothing is faded. The config
-- fits copies of the stock parts that leave out the add-ons' own meshes and the panels cut open for
-- them (stockparts/craptech_stockparts.jbeam). A flare, the splitter or the diffuser fins come as
-- several pieces, and a move in two directions is two props, the second starting where the first
-- ends: each piece shows one stage, shown / hidden with the props' "hidden" flag.
--
-- Electrics written: craptech_xf_state (0 = race look .. 1 = tucked away), and one 0..1 travel per
-- group of props, each moving in its own part of the transform time.
--
-- jbeam: ["craptechTransform", {"name":"transform", "time":3.0, "pumpNode":"...",
--          "groups":[["craptech_xf_flares", 0, 0.5], ...],     electric, start, end
--          "pieces":[[["<prop mesh>", "<its electric>"], <later stages>], ...]}]

local M = {}
M.type = "auxiliary"

local min, max, abs = math.min, math.max, math.abs

local MAX_MOVE_SPEED = 10 * 0.44704   -- m/s

local transformTime = 3.0
local groups, pieces = {}, {}
local propsByMesh = {}     -- prop mesh -> list of prop entries of v.data.props
local propShown = {}       -- prop mesh -> visibility last set
local p = 0                -- 0 race look .. 1 tucked away
local snapNext = true      -- jump straight to the wanted look (spawn, reset)
local warnedSpeed = false
local pumpNode
local pumpSound
local pumpPlaying = false

local function clamp01(x)
  return min(max(x, 0), 1)
end

local function ease(x)
  x = clamp01(x)
  return x * x * (3 - 2 * x)
end

local kitOut = false       -- the switch: race kit out (spawns tucked away)

local function jacksUp()
  local jacks = controller.getController("craptechAirJacks")
  return not jacks or jacks.lifted()
end

local function toggle()
  kitOut = not kitOut
  guihooks.message((kitOut and "Crapouille: race kit out" or "Crapouille: race kit tucks away") ..
    (jacksUp() and "" or " once the car is up on the air jacks"), 2, "craptech_transform")
end

local function wantsOut()
  return kitOut
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

local function apply(force)
  local ev = electrics.values
  for _, stages in ipairs(pieces) do
    -- a later stage takes over once its own move has started
    local active = 1
    for i = 2, #stages do
      if (ev[stages[i][2]] or 0) > 0 then
        active = i
      end
    end
    for i, st in ipairs(stages) do
      local show = i == active
      if force or propShown[st[1]] ~= show then
        propShown[st[1]] = show
        for _, prop in ipairs(propsByMesh[st[1]] or {}) do
          if not prop.disabled then   -- broken props stay hidden
            prop.hidden = not show
          end
        end
      end
    end
  end
end

local function writeElectrics()
  local ev = electrics.values
  ev.craptech_xf_state = p
  for _, g in ipairs(groups) do
    ev[g[1]] = ease((p - g[2]) / (g[3] - g[2]))
  end
end

local function updatePump(running)
  if not pumpSound then
    return
  end
  if running and not pumpPlaying then
    obj:setVolumePitch(pumpSound, 0.45, 0.95)
    obj:cutSFX(pumpSound)
    obj:playSFX(pumpSound)
    pumpPlaying = true
  elseif not running and pumpPlaying then
    obj:stopSFX(pumpSound)
    pumpPlaying = false
  end
end

local function updateGFX(dt)
  local ev = electrics.values
  local target = kitOut and 0 or 1

  if snapNext then
    snapNext = false
    p = target
    indexProps()
    writeElectrics()
    apply(true)
    return
  end

  if target == 1 and p < 1 then
    if (ev.craptech_jato_out or 0) + (ev.craptech_jato_door or 0) > 0 then
      -- rockets out: stow them first
      local jato = controller.getController("craptechJato")
      if jato and jato.retract then
        jato.retract()
      end
      target = p
    end
  end

  local moving = false
  if p ~= target then
    local canMove = (ev.ignitionLevel or 0) >= 1 and (ev.airspeed or 0) <= MAX_MOVE_SPEED and jacksUp()
    if canMove then
      warnedSpeed = false
      local step = dt / transformTime
      p = target > p and min(p + step, target) or max(p - step, target)
      writeElectrics()
      apply(false)
      moving = true
    elseif not warnedSpeed and (ev.airspeed or 0) > MAX_MOVE_SPEED then
      warnedSpeed = true
      guihooks.message("Crapouille: body kit moves below 10 mph", 3, "craptech_transform")
    end
  end
  updatePump(moving)
end

local function reset()
  propShown = {}
  snapNext = true
  warnedSpeed = false
  writeElectrics()
end

local function initSounds()
  local cid
  for _, n in pairs(v.data.nodes) do
    if n.name == pumpNode then
      cid = n.cid
    end
  end
  if cid then
    pumpSound = obj:createSFXSource2("event:>Vehicle>Hydraulics>Pump_01", "AudioDefaultLoop3D", "craptechTransformPump", cid, 0)
  end
  pumpPlaying = false
end

local function resetSounds()
  updatePump(false)
end

local function init(jbeamData)
  transformTime = jbeamData.time or transformTime
  pumpNode = jbeamData.pumpNode
  groups = jbeamData.groups or {}
  pieces = jbeamData.pieces or {}
  kitOut = false
  p = 0
  reset()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX
M.initSounds = initSounds
M.resetSounds = resetSounds
M.toggle = toggle
M.wantsOut = wantsOut

return M
