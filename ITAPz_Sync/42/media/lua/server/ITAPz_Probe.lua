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
    -- Controllo positivo: ITAPz_DataSync.lua dimostra gia' in produzione che
    -- questo evento scatta su un server dedicato. Se non compare una riga
    -- ITAPZ_PROBE_FIRST anche per lui, il problema e' la sonda stessa (non
    -- sta osservando cio' che crede), non gli hook candidati sopra.
    "EveryTenMinutes",
}

-- Un rapporto ogni N scatti complessivi. OnHitZombie scatta a ogni colpo:
-- senza soglia il log, che e' anche il canale delle statistiche, sarebbe
-- inutilizzabile.
local REPORT_EVERY = 25

local registered = {}
local fired = {}
local firstFire = {}

local function stamp()
    local s = ""
    pcall(function() s = os.date("!%Y-%m-%dT%H:%M:%SZ") end)
    return s
end

local totalFires = 0

local function report()
    local parts = {}
    for _, name in ipairs(CANDIDATES) do
        if registered[name] then
            table.insert(parts, name .. "=" .. (fired[name] or 0))
        end
    end
    print("ITAPZ_PROBE_REPORT " .. table.concat(parts, " "))
end

local function describe(v)
    local t = type(v)
    if t ~= "userdata" and t ~= "table" then return t end
    local s = nil
    pcall(function() s = v:getUsername() end)
    if s then return "player:" .. s end
    pcall(function() s = v:getClass():getSimpleName() end)
    return s or t
end

local function record(name, a, b, c)
    fired[name] = (fired[name] or 0) + 1
    if not firstFire[name] then
        firstFire[name] = stamp()
        local args = ""
        pcall(function()
            args = " args=" .. describe(a) .. "," .. describe(b) .. "," .. describe(c)
        end)
        print("ITAPZ_PROBE_FIRST " .. name .. " " .. firstFire[name] .. args)
    end

    totalFires = totalFires + 1
    if totalFires % REPORT_EVERY == 0 then
        report()
    end
end

local function register(name)
    local ok = false
    pcall(function()
        if Events and Events[name] and Events[name].Add then
            Events[name].Add(function(a, b, c) record(name, a, b, c) end)
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
     I file in media/lua/server/ vengono eseguiti al bootstrap del
     LuaManager, prima che il ModData globale venga deserializzato dal
     salvataggio: una lettura fatta qui (fase=load) e' sempre vuota anche
     quando la persistenza funziona. Events.OnInitGlobalModData scatta dopo
     la deserializzazione: e' la lettura (fase=init) che conta davvero. Se
     dopo un riavvio del server la riga fase=init riporta avvii=2, i
     contatori degli achievement possono viverci dentro. ]]
local MODDATA_KEY = "ITAPz_Probe"

local function checkModData(fase)
    local boots, prev = nil, nil
    pcall(function()
        local md = ModData.getOrCreate(MODDATA_KEY)
        if md then
            prev = md.lastBoot
            boots = (tonumber(md.boots) or 0) + 1
            md.boots = boots
            md.lastBoot = stamp()
        end
    end)

    if boots then
        print("ITAPZ_PROBE_MODDATA fase=" .. fase .. " avvii=" .. boots ..
              " precedente=" .. tostring(prev) .. " stato=ok")
    else
        print("ITAPZ_PROBE_MODDATA fase=" .. fase .. " stato=non-disponibile")
    end
end

checkModData("load")
if Events and Events.OnInitGlobalModData and Events.OnInitGlobalModData.Add then
    Events.OnInitGlobalModData.Add(function() checkModData("init") end)
elseif Events and Events.OnServerStarted and Events.OnServerStarted.Add then
    Events.OnServerStarted.Add(function() checkModData("init") end)
end

for _, name in ipairs(CANDIDATES) do
    register(name)
end
