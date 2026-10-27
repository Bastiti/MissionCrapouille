--Made by Strict (code based on mod version 3.0)

local M = {}
local volume, pitch = 12, 1
local camNode = 0
local timer = 0
local lastIgnitionLevel = 0
local chimeTimer = 0
local chimePlaying = false
local chimeDuration = 6 --Changes speed of chime playing (will mess with the amount of times the chime plays)
local nextChimeTime = 0
local chimeCompleted = false

local function inside()
    local cam = obj:getCameraPosition()
    local seat = obj:getPosition() + obj:getNodePosition(camNode)
    return cam and seat and cam:distance(seat) <= 1.2
end

local function update(dt)
    local ignitionLevel = electrics.values['ignitionLevel']
    local engineRunning = electrics.values.engineRunning
	local ignitionOn = (ignitionLevel > 0)
    if spawnedRecently and ignitionLevel < 2 then
        spawnedRecently = false
    end
    local ignitionChimeActive = (ignitionLevel == 2 and engineRunning and not spawnedRecently)

    if lastIgnitionLevel == 2 and ignitionLevel ~= 2 then
        chimePlaying = false
        chimeTimer = 0
        nextChimeTime = 0
        chimeCompleted = false
    end
	local isInside = inside()
    if isInside then
        if ignitionChimeActive and not chimeCompleted then
            if not chimePlaying then
                chimePlaying = true
                chimeTimer = 0
            end
            chimeTimer = chimeTimer + dt
            if chimeTimer >= nextChimeTime and chimeTimer < 4 then  --change the number value for number of times you want the chime to play after ignition. (consider that if this plays for 1.5 (in chimeDuration) and you want the chime to play 4 times you will need to extend it to 5)
                obj:playSFXOnce("craptech_chime.wav", camNode, volume, pitch)  --Change File Name
                nextChimeTime = chimeTimer + chimeDuration
            end
            if chimeTimer >= 4 then  --change this value to match the one above
                chimePlaying = false
                chimeCompleted = true
            --  obj:playSFXOnce("AlternateChime.wav", camNode, volume, pitch) --use this if you wish to have a different chime play at the very end. I used this in my mod for the Grand Marshall and Roamer if you want an example
                obj:playSFXOnce("craptech_chime_off.wav", camNode, volume, pitch)
            end
        end
    else
        if not isInside then
            if chimePlaying then
                chimePlaying = false
                chimeTimer = 0
                nextChimeTime = 0
                chimeCompleted = true
            end
        end
    end
    lastIgnitionLevel = ignitionLevel
end

local function init()
    camNode = beamstate.nodeNameMap["driver"] or 0
    obj:createSFXSource("/art/sound/craptech/craptech_chime.wav", "Audio2D", "craptech_chime.wav", -1) --Change File Names
--  obj:createSFXSource("/art/sound/YourVehicle/AlternateChime.wav", "Audio2D", "YourVehicleChimeOn.wav", -1) --use this if you are using the alternative chime at the end of the main chime
    obj:createSFXSource("/art/sound/craptech/craptech_chime_off.wav", "Audio2D", "craptech_chime_off.wav", -1)  --Change directory

        -- Reset chime state on vehicle reset/spawn
    chimePlaying = false
    chimeTimer = 0
    nextChimeTime = 0
    chimeCompleted = false
    lastIgnitionLevel = 0
    spawnedRecently = true
end

M.onInit = init
M.updateGFX = update
return M