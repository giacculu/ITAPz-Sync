--[[
ITAPz — Sonda diagnostica (temporanea)

Serve a stabilire quali hook Lua scattano davvero su un server DEDICATO di
Build 42. Che un evento esista nei file del gioco non implica che venga
emesso sul server: Events.OnTick, per esempio, non scatta mai.

Non modifica nulla e non tocca ITAPz_DataSync.lua. Stampa solo nel log, che
si legge dalla console del pannello admin.

Va rimossa quando gli hook utili sono stati identificati.
--]]

--[[ Candidati, secondo giro.

     Il primo giro sul server ha dato: OnHitZombie scatta e porta il giocatore
     come secondo argomento, OnZombieDead scatta ma senza attribuzione,
     OnEnterVehicle / OnMakeItem / OnDoTileBuilding non scattano mai.

     I nomi qui sotto sono presi dall'elenco "Current Lua events" di pzwiki,
     che spiega due di quei silenzi: OnMakeItem non esiste piu' in Build 42
     (il gioco stesso lo tiene commentato in XpSystem/XpUpdate.lua), e
     OnDoTileBuilding e' stato sostituito dalle varianti numerate 2 e 3.
     Sono stati tolti insieme a OnEnterVehicle, gia' provato senza esito. ]]
local CANDIDATES = {
    -- confermati funzionanti nel primo giro
    "OnHitZombie",
    "OnZombieDead",

    -- morte e creazione personaggio: ancora da provare
    "OnPlayerDeath",
    "OnCharacterDeath",
    "OnCreatePlayer",
    "OnCreateLivingCharacter",

    -- progressione abilita'
    "LevelPerk",
    "AddXP",

    -- costruzione: i nomi corretti in Build 42
    "OnDoTileBuilding2",
    "OnDoTileBuilding3",
    "OnObjectAdded",
    "OnDestroyIsoThumpable",

    -- combattimento e attribuzione dell'uccisione
    "OnWeaponHitCharacter",
    "OnWeaponHitTree",
    "OnPlayerAttackFinished",
    "OnPlayerGetDamage",

    -- veicoli: alternative a OnEnterVehicle, che non scatta
    "OnExitVehicle",
    "OnUseVehicle",
    "OnSwitchVehicleSeat",
    "OnMechanicActionDone",

    -- esplorazione e raccolta
    "OnSeeNewRoom",
    "OnItemFound",
    "OnNewFire",

    -- Controllo positivo: ITAPz_DataSync.lua dimostra gia' in produzione che
    -- questo evento scatta su un server dedicato. Se non compare una riga
    -- ITAPZ_PROBE_FIRST anche per lui, il problema e' la sonda stessa (non
    -- sta osservando cio' che crede), non gli hook candidati sopra.
    "EveryTenMinutes",
}

--[[ Intervallo minimo fra due rapporti, in secondi reali.

     Prima la soglia era a scatti (uno ogni 25): sul server OnPlayerGetDamage
     e' scattato 660 volte in pochi minuti, quindi il rapporto usciva piu'
     volte al secondo e annegava il log — che e' anche il canale delle
     statistiche verso il sito. Contare il tempo invece degli scatti rende il
     costo indipendente da quanto sono rumorosi gli eventi. ]]
local REPORT_MIN_SECONDS = 60

local registered = {}
local fired = {}
local firstFire = {}

local function stamp()
    local s = ""
    pcall(function() s = os.date("!%Y-%m-%dT%H:%M:%SZ") end)
    return s
end

local lastReport = 0

local function now()
    local t = 0
    pcall(function() t = os.time() or 0 end)
    return t
end

local function report()
    local parts = {}
    for _, name in ipairs(CANDIDATES) do
        if registered[name] then
            table.insert(parts, name .. "=" .. (fired[name] or 0))
        end
    end
    print("ITAPZ_PROBE_REPORT " .. table.concat(parts, " "))
end

--[[ Descrive un argomento di evento senza chiamare metodi che possano
     sollevare eccezioni.

     `getClass():getSimpleName()` fallisce dentro Kahlua su un IsoZombie
     ("attempted index: getSimpleName of non-table"), e il pcall NON basta:
     PZ registra comunque lo stack trace nel log e accende l'icona di errore
     in gioco. `instanceof` e' il test sicuro, ed e' quello che usa il codice
     del gioco stesso. ]]
local function describe(v)
    local t = type(v)
    if t ~= "userdata" and t ~= "table" then return t end

    local out = t
    pcall(function()
        if instanceof(v, "IsoPlayer") then
            out = "player:" .. tostring(v:getUsername())
        elseif instanceof(v, "IsoZombie") then
            out = "zombie"
        elseif instanceof(v, "IsoGameCharacter") then
            out = "character"
        elseif instanceof(v, "InventoryItem") then
            out = "item"
        elseif instanceof(v, "BaseVehicle") then
            out = "vehicle"
        end
    end)
    return out
end

--[[ Un evento puo' scattare sia per un giocatore sia per uno zombie
     (OnCharacterDeath lo fa). La prima riga cattura solo il primo dei due:
     quando arriva un giocatore su un evento gia' visto, vale una riga in piu',
     una sola volta, altrimenti l'attribuzione resterebbe sconosciuta. ]]
local playerSeen = {}

local function record(name, a, b, c)
    fired[name] = (fired[name] or 0) + 1

    local args = nil
    local function describeArgs()
        pcall(function()
            args = "args=" .. describe(a) .. "," .. describe(b) .. "," .. describe(c)
        end)
        return args or "args=?"
    end

    if not firstFire[name] then
        firstFire[name] = stamp()
        print("ITAPZ_PROBE_FIRST " .. name .. " " .. firstFire[name] .. " " .. describeArgs())
    elseif not playerSeen[name] then
        if describeArgs():find("player:", 1, true) then
            playerSeen[name] = true
            print("ITAPZ_PROBE_PLAYER " .. name .. " " .. stamp() .. " " .. args)
        end
    end

    local t = now()
    if t - lastReport >= REPORT_MIN_SECONDS then
        lastReport = t
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
