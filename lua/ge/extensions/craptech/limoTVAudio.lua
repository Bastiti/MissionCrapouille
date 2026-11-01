-- craptech_limoTVAudio: the sound of the Crapouille limo TV (vehicles/fullsize/limotv, controller craptechLimoTV).
-- The TV's picture is a page drawn into the screen texture, and the game's browser plays no sound in a page nobody
-- clicked (no click ever reaches a texture). The game's UI page has been clicked, so the sound plays there:
-- craptech_limotv_audio.js, loaded into the UI by this extension and fed ten times a second, follows the picture
-- (where the TV's page says it is) and sounds like the set in the world: full close to it, falling with the distance,
-- from its side, muffled and quieter from outside the car (the game's own test of a camera inside the car, the one
-- its own sounds use), times the set's volume and the game's master volume.
--
--   craptech_limoTVAudio.source(vid, node, volume)   from the TV's controller: the node the set sits on, its volume
--                                                     (0..1, already the set's volume curve)
--   craptech_limoTVAudio.sync(vid, json)             from the TV's page: {feed, t, at, playing} (a live stream),
--                                                     {file, t, at, playing} (a channel's file), or {stop: true}

local M = {}

local SCRIPT = "local://local/vehicles/fullsize/limotv/craptech_limotv_audio.js"
local PUSH = 0.1                       -- s between updates to the UI
local STALE = 2                        -- s without news from a TV's page: its sound stops
local NEAR = 1                         -- m: full volume this close, then falling as 1 / distance
local OUTSIDE = 0.3                    -- the body's damping, heard from outside the car
local CUTOFF_IN, CUTOFF_OUT = 20000, 900   -- Hz: the low-pass filter, inside / outside
local PAN = 0.8                        -- how far to one side a set straight to the camera's left or right sounds
local TOKEN = tostring(os.clock())     -- this load of the extension: the UI's player, if from an older one, is loaded again

local tvs = {}     -- vid -> {node, volume, sync (decoded), age (s since the page's last news)}
local timer = 0

local camPos, camRight, setPos, offset = vec3(), vec3(), vec3(), vec3()
local obbCenter, obbAxis0, obbAxis1, obbAxis2 = vec3(), vec3(), vec3(), vec3()

-- calls craptechLimoTVAudio.<call> in the UI page, once the player is there (loaded at most every 5 s until it is;
-- a reloaded UI gets it again, and so does one holding the player of an earlier load of this extension: from the
-- file, not the browser's cache)
local function ui(call)
  be:executeJS("if (window.craptechLimoTVAudio && window.craptechLimoTVAudioToken === '" .. TOKEN .. "') { " ..
    "craptechLimoTVAudio." .. call .. " } " ..
    "else if (Date.now() - (window.craptechLimoTVAudioLoad || 0) > 5000) { window.craptechLimoTVAudioLoad = Date.now(); " ..
    "var s = document.createElement('script'); s.src = '" .. SCRIPT .. "?" .. TOKEN .. "'; " ..
    "s.onload = function () { window.craptechLimoTVAudioToken = '" .. TOKEN .. "'; }; document.head.appendChild(s); }")
end

local function stop(vid)
  ui(string.format("update({vid: %d, sync: {stop: true}})", vid))
end

local function source(vid, node, volume)
  local tv = tvs[vid] or {age = 0}
  tv.node, tv.volume = node, volume
  tvs[vid] = tv
end

local function sync(vid, text)
  local ok, data = pcall(jsonDecode, text)
  if not ok or type(data) ~= "table" then return end
  local tv = tvs[vid] or {volume = 0}
  tvs[vid] = tv
  tv.age = 0
  if data.stop then
    if tv.sync then stop(vid) end
    tv.sync = nil
  else
    tv.sync = data
  end
end

-- the camera inside the car: the game's test for the player's car, its bounding box for another
local function inside(vid)
  local player = getPlayerVehicle(0)
  if player and player:getId() == vid then
    return core_camera and core_camera.isCameraInside(0, camPos) == 1
  end
  obbCenter:set(be:getObjectOOBBCenterXYZ(vid))
  obbAxis0:set(be:getObjectOOBBHalfAxisXYZ(vid, 0))
  obbAxis1:set(be:getObjectOOBBHalfAxisXYZ(vid, 1))
  obbAxis2:set(be:getObjectOOBBHalfAxisXYZ(vid, 2))
  return containsOBB_point(obbCenter, obbAxis0, obbAxis1, obbAxis2, camPos)
end

local function onUpdate(dtReal)
  timer = timer + dtReal
  for _, tv in pairs(tvs) do tv.age = (tv.age or 0) + dtReal end
  if timer < PUSH then return end
  timer = 0
  if not core_camera then return end
  camPos:set(core_camera.getPositionXYZ())
  camRight:set(core_camera.getRight())
  local master = Engine.Audio.getChannelVolume("AudioChannelMaster", true) or 1
  for vid, tv in pairs(tvs) do
    local veh = be:getObjectByID(vid)
    if not veh then
      if tv.sync then stop(vid) end
      tvs[vid] = nil
    elseif tv.sync and tv.age > STALE then
      stop(vid)
      tv.sync = nil
    elseif tv.sync and tv.node then
      setPos:set(veh:getNodeAbsPositionXYZ(tv.node))
      offset:setSub2(setPos, camPos)
      local dist = offset:length()
      local isIn = inside(vid)
      local gain = tv.volume * master * math.min(1, NEAR / math.max(dist, 0.01)) * (isIn and 1 or OUTSIDE)
      local pan = dist > 0.2 and clamp(offset:dot(camRight) / dist, -1, 1) * PAN or 0
      ui(string.format("update({vid: %d, gain: %.4f, pan: %.3f, cutoff: %d, sync: %s})",
        vid, gain, pan, isIn and CUTOFF_IN or CUTOFF_OUT, jsonEncode(tv.sync)))
    end
  end
end

local function onVehicleDestroyed(vid)
  if tvs[vid] then
    if tvs[vid].sync then stop(vid) end
    tvs[vid] = nil
  end
end

local function onExtensionUnloaded()
  for vid, tv in pairs(tvs) do
    if tv.sync then stop(vid) end
  end
  tvs = {}
end

M.source = source
M.sync = sync
M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionUnloaded = onExtensionUnloaded

return M
