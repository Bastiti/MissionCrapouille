-- Crapouille Technologies rear-window LED sign.
-- Renders an HTML page into a texture (like beamNavigator / gpsphotoframe do) and streams
-- it the few electrics it needs. Unlike genericGauges this lets the part pick its own
-- texture size and frame rate, which matters for a mostly static 1024x1024 page.

local M = {}
M.type = "auxiliary"

local htmlTexture = require("htmlTexture")

local signTexture = nil
local sendTimer = 0
local sendInterval = 0.1
-- the *_input / *_enabled electrics are steady while the stalk is on (signal_L/R blink);
-- the craptech_* ones come from the other Crapouille parts (0 when a part is not fitted):
-- JATO doors/rails and burn (craptechJato), air jacks travel (craptechAirJacks)
local electricKeys = {"lightbar", "ignitionLevel", "signal_left_input", "signal_right_input", "hazard_enabled",
                      "airspeed", "gearIndex", "brake",
                      "craptech_jato_out", "craptech_jato_burning", "jatofuel", "craptech_airjacks"}
local signData = {}

local function updateGFX(dt)
  -- the board hydros (craptech_flashers_sign.jbeam) fold it down while the lightbar is on.
  -- The lightbar switch keeps its state with the ignition off, so also require power,
  -- otherwise the board stays down after the lights have gone dark.
  local lightbarOn = (electrics.values.lightbar or 0) > 0
  local powered = (electrics.values.ignitionLevel or 0) >= 1
  electrics.values.craptech_sign_deploy = (lightbarOn and powered) and 1 or 0

  if not signTexture then
    return
  end
  sendTimer = sendTimer + dt
  if sendTimer < sendInterval then
    return
  end
  sendTimer = 0
  for _, k in ipairs(electricKeys) do
    signData[k] = electrics.values[k] or 0
  end
  signTexture:streamJS("signData", "updateData", signData)
end

local function init(jbeamData)
  local materialName = jbeamData.materialName or "@craptech_sign"
  local htmlFilePath = jbeamData.htmlFilePath or "local://local/vehicles/sunburst2/sign/craptech_sign_screen.html"
  local width = jbeamData.textureWidth or 1024
  local height = jbeamData.textureHeight or 1024
  local fps = jbeamData.textureFPS or 20

  signTexture = htmlTexture.new(materialName, htmlFilePath, width, height, fps, "automatic")
  sendTimer = sendInterval
end

M.init = init
M.updateGFX = updateGFX

return M
