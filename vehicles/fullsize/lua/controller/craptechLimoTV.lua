-- Crapouille limo TV (vehicles/fullsize/limotv/craptech_limotv.jbeam, a copy of the limousine's "Interior Lights &
-- Wiring" part): the TV in the bar plays videos and can be used from the back, with the set's own buttons under
-- the screen:
--   POWER (the round one)   on / off
--   CH up, CH down          next / previous channel (switching the TV on if it is off)
--   VL up, VL down          volume, shown along the bottom of the screen
--   DISP                    shows the channel number
-- A click on the screen also goes to the next channel; MENU does nothing. The same actions are in Controls.
--
-- Each of the nine channels plays the WebM files of its folder (channelFolder .. "ch<n>", e.g.
-- vehicles/fullsize/limotv/channels/ch3), in name order, looping; a channel without any shows
-- "No video input" (the game's browser plays WebM only: MP4 and the like are pointed out on that screen). The
-- folders are read when the car loads and each time the TV is switched on, so videos dropped in show after a
-- power off / on. A change blanks the screen a moment, switching on a little longer (the tube warming up), then
-- the channel number shows in the corner for a few seconds, like an old set. It runs from the accessory position
-- on; a reset keeps the channel and whether it is on.
--
-- A channel can show a live stream instead (a Twitch channel...): craptech_limotv_live.py, run outside the game
-- (which has no network access), writes it as one-second WebM pieces into liveFolder .. "ch<n>/" of the user
-- folder, listed in live.json. While the TV is on, the current channel's live.json is read twice a second and
-- passed to the page (tv.setLive), which plays the pieces while it keeps being written. Read here rather than by
-- the page: the game's browser logs an error for each file it doesn't find.
--
-- The sound, of a file or a stream, plays in the game's UI (a texture's page may not play sound), placed like a
-- sound of the world by the GE extension craptech_limoTVAudio (lua/ge/extensions/craptech/limoTVAudio.lua, loaded
-- from here), which the page tells what it shows and where its picture is, and this controller which node the set
-- sits on (the one nearest "speaker") and the set's volume (the volume steps on a decibel scale).
--
-- The screen is an HTML page (craptech_limotv_screen.html) drawn into the texture webView, told what to show
-- with tv.setChannels / tv.setState (sent on change, and again every 2 s in case the page reloaded). The glowMap
-- shows it on the tube while the TV is on (electric craptech_limotv_lit), the dark glass otherwise. A material
-- that first showed while its page texture didn't exist yet (a car loaded with a failing controller) keeps a
-- black picture for the session, so the screen material is reloaded once the page texture is there.
--
-- jbeam: ["craptechLimoTV", {"channels":9, "channelFolder":"/vehicles/fullsize/limotv/channels/",
--          "htmlPath":"local://local/vehicles/fullsize/limotv/craptech_limotv_screen.html", "webView":"@craptech_limotv",
--          "screenMaterial":"craptech_ltv_on", "liveFolder":"/temp/craptech_limotv/", "textureWidth":640,
--          "textureHeight":480, "textureFPS":30, "blankTime":0.25, "warmTime":0.8, "osdTime":3,
--          "speaker":{"x":-0.276, "y":2.28, "z":0.735}, "volumeSteps":20, "volumeStepDb":1.5, "volume":14}]

local M = {}
M.type = "auxiliary"

local htmlTexture = require("htmlTexture")

local max, min = math.max, math.min

local PLAYABLE = {webm = true}
local OTHER_VIDEO = {mp4 = true, m4v = true, mov = true, avi = true, mkv = true, wmv = true, flv = true, mpg = true,
                     mpeg = true, ogv = true, ts = true, ["3gp"] = true}
local RESEND_TIME = 2
local REFRESH_DELAY = 0.5 -- s after creating the page texture before reloading the screen material
local LIVE_POLL = 0.5     -- s between reads of the current channel's live.json

local channels = 9
local channelFolder = "/vehicles/fullsize/limotv/channels/"
local liveFolder = "/temp/craptech_limotv/"
local webView = "@craptech_limotv"
local screenMaterial = "craptech_ltv_on"
local refresh = nil       -- s left before reloading the screen material (nil: done)
local livePoll = 0
local liveSent = nil      -- what tv.setLive last got (channel and text)
local blankTime, warmTime, osdTime = 0.25, 0.8, 3
local volumeSteps, volumeStepDb = 20, 1.5
local speakerNode = nil   -- the node the set sits on (its sound comes from there)
local soundSent = nil     -- what craptech_limoTVAudio.source last got
local on = true
local channel = 1
local volume = 14
local blank = 0           -- s left with the screen dark (changing channel, warming up)
local osd = 0             -- s left with the channel number shown, once the picture is there
local volumeOsd = 0       -- s left with the volume shown
local wasPowered = nil    -- nil until the first frame: a spawn with the ignition on doesn't warm up
local lists, unsupported = {}, {}
local sentState = nil
local channelsSent = false
local resend = 0

-- the channel folders: per channel its playable files (sorted) and how many other videos it holds
local function scan()
  for i = 1, channels do
    local files, other = {}, 0
    for _, path in ipairs(FS:findFiles(channelFolder .. "ch" .. i, "*", 0, false, false) or {}) do
      local ext = string.lower(string.match(path, "%.([^./]+)$") or "")
      if PLAYABLE[ext] then
        table.insert(files, path)
      elseif OTHER_VIDEO[ext] then
        other = other + 1
      end
    end
    table.sort(files)
    lists[i], unsupported[i] = files, other
  end
  channelsSent = false
end

local function switchOn()
  on = true
  blank, osd = warmTime, osdTime
  scan()
end

local function step(dir)
  if not on then
    switchOn()
    return
  end
  channel = (channel - 1 + dir) % channels + 1
  blank, osd = blankTime, osdTime
  livePoll = 0
end

local function nextChannel()
  step(1)
end

local function prevChannel()
  step(-1)
end

local function power()
  if on then
    on = false
  else
    switchOn()
  end
end

local function display()
  osd = max(osd, osdTime)
end

-- VL: nothing while the set is off, like the set
local function changeVolume(dir)
  if not on or (electrics.values.ignitionLevel or 0) < 1 then return end
  volume = min(max(volume + dir, 0), volumeSteps)
  volumeOsd = osdTime
end

local function volumeUp()
  changeVolume(1)
end

local function volumeDown()
  changeVolume(-1)
end

-- the set's volume as a gain: volumeStepDb per step below the top one, 0 at step 0
local function volumeGain()
  return volume > 0 and 10 ^ ((volume - volumeSteps) * volumeStepDb / 20) or 0
end

local function updateGFX(dt)
  if refresh then
    refresh = refresh - dt
    if refresh <= 0 then
      refresh = nil
      obj:queueGameEngineLua(string.format("local m = scenetree.findObject(%q) if m then m:reload() end", screenMaterial))
    end
  end

  local e = electrics.values
  local powered = (e.ignitionLevel or 0) >= 1
  if wasPowered == false and powered and on then
    blank, osd = warmTime, osdTime
  end
  wasPowered = powered
  if blank > 0 then
    blank = max(blank - dt, 0)
  else
    osd = max(osd - dt, 0)
  end
  volumeOsd = max(volumeOsd - dt, 0)
  local lit = powered and on
  e.craptech_limotv_lit = lit and 1 or 0
  e.craptech_limotv_channel = channel

  local mode = not lit and "off" or blank > 0 and "blank" or "on"
  local state = mode .. channel .. (osd > 0 and "+" or "") .. "|" .. volume .. (volumeOsd > 0 and "+" or "")
  resend = resend - dt
  if resend <= 0 then
    resend = RESEND_TIME
    sentState, channelsSent, liveSent, soundSent = nil, false, nil, nil
  end
  if not channelsSent then
    htmlTexture.call(webView, "tv.setChannels", {channels = lists, unsupported = unsupported})
    channelsSent = true
  end
  if state ~= sentState then
    htmlTexture.call(webView, "tv.setState", {mode = mode, channel = channel, osd = osd > 0, volume = volume,
      volumeSteps = volumeSteps, volumeOsd = volumeOsd > 0})
    sentState = state
  end

  local sound = speakerNode and string.format("%d, %d, %.5f", obj:getID(), speakerNode, volumeGain())
  if sound and sound ~= soundSent then
    obj:queueGameEngineLua("if craptech_limoTVAudio then craptech_limoTVAudio.source(" .. sound .. ") end")
    soundSent = sound
  end

  livePoll = livePoll - dt
  if livePoll <= 0 then
    livePoll = LIVE_POLL
    local text = ""
    if lit then
      local path = liveFolder .. "ch" .. channel .. "/live.json"
      text = FS:fileExists(path) and readFile(path) or ""
    end
    local sent = channel .. "|" .. text
    if sent ~= liveSent then
      htmlTexture.call(webView, "tv.setLive", {channel = channel, folder = liveFolder .. "ch" .. channel .. "/", text = text,
        vid = obj:getID()})
      liveSent = sent
    end
  end
end

local function reset()
  blank, osd, volumeOsd = 0, 0, 0
  wasPowered = nil
  sentState, channelsSent, liveSent, soundSent = nil, false, nil, nil
  livePoll = 0
end

-- the node nearest a point (jbeam coordinates)
local function nearestNode(p)
  local best, bestDist = nil, math.huge
  for cid, n in pairs(v.data.nodes) do
    if n.pos then
      local dx, dy, dz = n.pos.x - p.x, n.pos.y - p.y, n.pos.z - p.z
      local d = dx * dx + dy * dy + dz * dz
      if d < bestDist then
        best, bestDist = cid, d
      end
    end
  end
  return best
end

local function init(jbeamData)
  channels = jbeamData.channels or channels
  channelFolder = jbeamData.channelFolder or channelFolder
  liveFolder = jbeamData.liveFolder or liveFolder
  webView = jbeamData.webView or webView
  screenMaterial = jbeamData.screenMaterial or screenMaterial
  blankTime = jbeamData.blankTime or blankTime
  warmTime = jbeamData.warmTime or warmTime
  osdTime = jbeamData.osdTime or osdTime
  volumeSteps = jbeamData.volumeSteps or volumeSteps
  volumeStepDb = jbeamData.volumeStepDb or volumeStepDb
  speakerNode = nearestNode(jbeamData.speaker or {x = -0.276, y = 2.28, z = 0.735})
  htmlTexture.create(webView, jbeamData.htmlPath or "local://local/vehicles/fullsize/limotv/craptech_limotv_screen.html",
    jbeamData.textureWidth or 640, jbeamData.textureHeight or 480, jbeamData.textureFPS or 30, "automatic")
  refresh = REFRESH_DELAY
  obj:queueGameEngineLua("extensions.load('craptech_limoTVAudio')")
  on = true
  channel = math.random(channels)
  volume = min(jbeamData.volume or volume, volumeSteps)
  scan()
  reset()
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX
M.nextChannel = nextChannel
M.prevChannel = prevChannel
M.power = power
M.display = display
M.volumeUp = volumeUp
M.volumeDown = volumeDown

return M
