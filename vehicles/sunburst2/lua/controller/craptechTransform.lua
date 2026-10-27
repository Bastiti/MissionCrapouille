-- Crapouille Technologies transform (vehicles/sunburst2/transform/craptech_transform.jbeam).
--
-- With the narrow track the race add-ons tuck away, mechanically: the fender flares sink into
-- the body (a ring of tiles round each arch, all together), turn over out of sight inside it and
-- rise back out, flush, as the plain panel each tile carries on its back; the side skirts fold in
-- about their top edge until they hang straight like the stock skirt (their lower half swings up
-- under the sill); the splitter slides into the bumper in pieces and rises out of sight (its centre
-- piece stays, flush, as the bumper's lower edge, and a lower lip hidden inside the splitter closes
-- the bumper round the corners); and the diffuser fins fold up into the diffuser, sliding doors
-- closing the slots behind them. The wide track brings them back out. Nothing is swapped for
-- another part.
--
-- The track is the air jacks' (craptechAirJacks): the kit follows the track asked for as soon as
-- the button is pressed; the air jacks hold the wheels until the flares are out, and tucking away
-- waits for the wheels to be back in (the flares come in over the tyres). Without the air jacks
-- the kit stays out. Like the wing and the air jacks it only moves with power on and below 10 mph
-- (it waits otherwise). Before tucking away it stows the JATO if it is out.
--
-- How: each add-on has a moving copy (prop). In the race look the fitted mesh (flexbody, which
-- deforms with the car) shows; as soon as the move starts it is faded out with setMeshAlpha (GE)
-- and the prop, identical at that point, takes over (one fitted mesh may hand over to several props,
-- like the splitter's pieces or the diffuser's fins and doors). A move in two directions would be
-- two props, the second starting where the first ends. Props are shown / hidden with their "hidden"
-- flag (setMeshAlpha does not reach props).
--
-- Electrics written: craptech_xf_state (0 = race look .. 1 = tucked away), and one 0..1 travel per
-- group of props, each moving in its own part of the transform time.
--
-- jbeam: ["craptechTransform", {"name":"transform", "time":3.0, "pumpNode":"...",
--          "groups":[["craptech_xf_flares", 0, 0.5], ...],     electric, start, end
--          "pieces":[["<fitted mesh>", [["<prop mesh>", "<its electric>"], <later stages>]], ...],   (a fitted mesh may head several pieces)
--          "hidden":["<mesh hidden for good>", ...]}]

local M = {}
M.type = "auxiliary"

local min, max, abs = math.min, math.max, math.abs

local MAX_MOVE_SPEED = 10 * 0.44704   -- m/s

local transformTime = 3.0
local groups, pieces, hidden = {}, {}, {}
local alpha = {}           -- flexbody mesh -> alpha last sent
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

local function narrowTrack()
  local jacks = controller.getController("craptechAirJacks")
  return jacks ~= nil and jacks.wantsWide ~= nil and not jacks.wantsWide()
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
  local cmds = {}
  local function setAlpha(mesh, a)
    if force or alpha[mesh] ~= a then
      alpha[mesh] = a
      cmds[#cmds + 1] = string.format("v:setMeshAlpha(%d,%q,false)", a, mesh)
    end
  end
  for _, mesh in ipairs(hidden) do
    setAlpha(mesh, 0)
  end
  local moved = p > 0
  local ev = electrics.values
  for _, pc in ipairs(pieces) do
    setAlpha(pc[1], moved and 0 or 1)
    -- stage props: a later stage takes over once its own move has started
    local stages = pc[2]
    local active = 1
    for i = 2, #stages do
      if (ev[stages[i][2]] or 0) > 0 then
        active = i
      end
    end
    for i, st in ipairs(stages) do
      local show = moved and i == active
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
  if #cmds > 0 then
    obj:queueGameEngineLua(string.format("local v = be:getObjectByID(%d) if v then %s end", obj:getId(), table.concat(cmds, " ")))
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
  local target = narrowTrack() and 1 or 0

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
    elseif (ev.craptech_track_wide or 0) > 0 then
      -- the wheels are still on their way in: the flares wait for them
      target = p
    end
  end

  local moving = false
  if p ~= target then
    local canMove = (ev.ignitionLevel or 0) >= 1 and (ev.airspeed or 0) <= MAX_MOVE_SPEED
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
  alpha = {}
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
  hidden = jbeamData.hidden or {}
  p = 0
  reset()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX
M.initSounds = initSounds
M.resetSounds = resetSounds

return M
