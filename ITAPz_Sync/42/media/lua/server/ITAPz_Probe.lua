--[[
ITAPz — Sonda diagnostica (temporanea)

Serve a stabilire quali hook Lua scattano davvero su un server DEDICATO di
Build 42. Che un evento esista nei file del gioco non implica che venga
emesso sul server: Events.OnTick, per esempio, non scatta mai.

Non modifica nulla e non tocca ITAPz_DataSync.lua. Stampa solo nel log, che
si legge dalla console del pannello admin.

Va rimossa quando gli hook utili sono stati identificati.
--]]

local CANDIDATES = {
    "OnPlayerDeath",
    "LevelPerk",
    "OnHitZombie",
    "OnZombieDead",
    "OnMakeItem",
    "OnDoTileBuilding",
    "OnEnterVehicle",
    "OnPlayerAttackFinished",
    "OnCreatePlayer",
}

local registered = {}
local fired = {}
local firstFire = {}

local function stamp()
    local s = ""
    pcall(function() s = os.date("!%Y-%m-%dT%H:%M:%SZ") end)
    return s
end

local function record(name)
    fired[name] = (fired[name] or 0) + 1
    if not firstFire[name] then
        firstFire[name] = stamp()
        print("ITAPZ_PROBE_FIRST " .. name .. " " .. firstFire[name])
    end
end

local function register(name)
    local ok = false
    pcall(function()
        if Events and Events[name] and Events[name].Add then
            Events[name].Add(function() record(name) end)
            ok = true
        end
    end)
    registered[name] = ok
    fired[name] = 0
    if ok then
        print("ITAPZ_PROBE_HOOK " .. name .. " registrato")
    else
        print("ITAPZ_PROBE_HOOK " .. name .. " ASSENTE")
    end
end

print("ITAPZ_PROBE avvio " .. stamp())

--[[ Verifica che il ModData globale sopravviva ai riavvii.
     Se dopo un riavvio del server questa riga riporta avvii=2, i contatori
     degli achievement possono viverci dentro. ]]
local MODDATA_KEY = "ITAPz_Probe"

local function checkModData()
    local boots = nil
    pcall(function()
        local md = ModData.getOrCreate(MODDATA_KEY)
        if md then
            boots = (tonumber(md.boots) or 0) + 1
            md.boots = boots
            md.lastBoot = stamp()
        end
    end)

    if boots then
        print("ITAPZ_PROBE_MODDATA avvii=" .. boots .. " stato=ok")
    else
        print("ITAPZ_PROBE_MODDATA stato=non-disponibile")
    end
end

checkModData()

for _, name in ipairs(CANDIDATES) do
    register(name)
end
