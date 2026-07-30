--[[
ITAPz — Data Sync
Mod server-side per Project Zomboid Build 42.

Raccoglie le statistiche dei giocatori online e le stampa nel log del server
fra marcatori. Il Lua server-side di Build 42 non ha API di rete NE' scrittura
file (getFileWriter e' client-only: sul server dedicato torna nil), quindi il
log e' l'unico canale disponibile.

Il bridge esterno (bridge/itapz-bridge.sh) estrae i dati dal log e li invia al
sito con una POST.

Formato nel log:
  ITAPZ_SYNC_BEGIN <timestamp> players=<n>
  ITAPZ_PLAYER {"name":...}
  ITAPZ_SYNC_END
--]]

-- ============================ CONFIGURAZIONE ============================
-- NON modificare questo file (i file Workshop vengono sovrascritti agli
-- aggiornamenti). Per cambiare l'intervallo crea il file
--   <cartella Zomboid>/Lua/ITAPz_Sync_config.txt
-- con:
--
--   INTERVAL=60
--
local DEFAULT_INTERVAL = 300 -- secondi tra due emissioni (300 = 5 min)

local function loadInterval()
    local interval = DEFAULT_INTERVAL
    pcall(function()
        local reader = getFileReader("ITAPz_Sync_config.txt", false)
        if not reader then return end
        local line = reader:readLine()
        while line ~= nil do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k == "INTERVAL" then interval = tonumber(v) or interval end
            line = reader:readLine()
        end
        reader:close()
    end)
    return interval
end

local INTERVAL = loadInterval()
-- =======================================================================

--[[ Serializza una tabella Lua in JSON ]]
local function toJson(t)
    if t == nil then return "null" end
    local typ = type(t)
    if typ == "string" then
        return '"' .. t:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif typ == "number" or typ == "boolean" then
        return tostring(t)
    elseif typ == "table" then
        local parts = {}
        local isArray = true
        for k, _ in pairs(t) do
            if type(k) ~= "number" then isArray = false; break end
        end
        if isArray then
            for _, v in ipairs(t) do
                table.insert(parts, toJson(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(t) do
                table.insert(parts, toJson(tostring(k)) .. ":" .. toJson(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

--[[ Tratti del personaggio (B42):
     player:getCharacterTraits():getKnownTraits() -> lista, trait:getName() ]]
local function getTraits(player)
    local list = {}
    pcall(function()
        local traits = player:getCharacterTraits()
        if not traits then return end
        local known = traits:getKnownTraits()
        if not known then return end
        for i = 0, known:size() - 1 do
            local t = known:get(i)
            if t then
                local name = nil
                pcall(function() name = t:getName() end)
                table.insert(list, name or tostring(t))
            end
        end
    end)
    return table.concat(list, ", ")
end

--[[ Skill: enumera PerkFactory.PerkList (stesso pattern usato dal gioco).
     Solo le skill attive (child perk, parent ~= Perks.None). ]]
local function getSkills(player)
    local out = {}
    pcall(function()
        local list = PerkFactory.PerkList
        for i = 0, list:size() - 1 do
            local perk = list:get(i)
            if perk and perk:getParent() ~= Perks.None then
                local level = player:getPerkLevel(perk) or 0
                table.insert(out, { name = perk:getName(), level = level, maxLevel = 10 })
            end
        end
    end)
    return out
end

--[[ Raccoglie i dati di tutti i giocatori online.
     Ogni getter è protetto: un metodo assente in una versione B42 non
     interrompe la raccolta. ]]
local function collectPlayerData()
    local players = getOnlinePlayers()
    if not players then return {} end

    local results = {}
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local username, occupation = nil, ""
            local trait = ""
            local hours, zombies = 0, 0
            local weight, recipes, infected = 0, 0, false
            local skills = {}

            pcall(function() username = p:getUsername() end)
            pcall(function()
                local desc = p:getDescriptor()
                if desc then occupation = tostring(desc:getCharacterProfession() or "") end
            end)
            pcall(function() trait = getTraits(p) end)

            pcall(function() hours = p:getHoursSurvived() or 0 end)
            pcall(function() zombies = p:getZombieKills() or 0 end)
            pcall(function() weight = p:getNutrition():getWeight() or 0 end)
            pcall(function() recipes = p:getKnownRecipes():size() or 0 end)
            pcall(function() infected = p:getBodyDamage():isInfected() or false end)
            pcall(function() skills = getSkills(p) end)

            -- getSurviveDays non esiste in B42: i giorni si derivano dalle ore
            local days = math.floor((tonumber(hours) or 0) / 24)

            table.insert(results, {
                name = username or ("Player_" .. i),
                occupation = occupation,
                trait = trait,
                kills = 0,          -- B42: nessun getter "player uccisi"
                zombies = tonumber(zombies) or 0,
                daysSurvived = days,
                hoursSurvived = math.floor(tonumber(hours) or 0),
                distanceWalked = 0, -- B42: nessun getter distanza percorsa
                treesChopped = 0,   -- B42: getStats() non espone questi contatori
                bulletsFired = 0,
                panicAttacks = 0,
                weight = tonumber(weight) or 0,
                recipesKnown = tonumber(recipes) or 0,
                infected = infected and true or false,
                skills = skills,
            })
        end
    end
    return results
end

--[[ Output dei dati.

     In Build 42 il Lua SERVER-SIDE non ha né API di rete né scrittura file
     (getFileWriter è client-only: sul server dedicato restituisce nil). L'unico
     canale disponibile è il log del server: la mod stampa i dati fra marcatori e
     il bridge esterno (bridge/itapz-bridge.sh) li estrae dal log e fa la POST.

     Un giocatore per riga, per non superare limiti di lunghezza. ]]
local function emitData()
    local players = collectPlayerData()
    local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

    print("ITAPZ_SYNC_BEGIN " .. stamp .. " players=" .. #players)
    for _, p in ipairs(players) do
        print("ITAPZ_PLAYER " .. toJson(p))
    end
    print("ITAPZ_SYNC_END")
end

--[[ Ciclo principale ]]
local function syncData()
    local ok = pcall(emitData)
    if not ok then
        print("ITAPz: ERRORE durante la raccolta dati")
    end
end

--[[ Timer. OnTick non parte sui server dedicati: si usa EveryOneMinute.
     Si preferisce il tempo reale (os.time); se non disponibile si contano
     i trigger dell'evento. ]]
local lastSyncTime = 0
local ticks = 0

local function realTime()
    local t = nil
    pcall(function() t = os.time() end)
    return t
end

local announced = false

local function onPeriodic()
    if not announced then
        announced = true
        print("ITAPz: timer attivo (primo trigger ricevuto)")
    end
    local now = realTime()
    if now then
        if now - lastSyncTime >= INTERVAL then
            lastSyncTime = now
            syncData()
        end
    else
        -- fallback: un sync ogni ceil(INTERVAL/60) trigger
        ticks = ticks + 1
        local every = math.max(1, math.floor(INTERVAL / 60))
        if ticks >= every then
            ticks = 0
            syncData()
        end
    end
end

-- Registra un handler solo se l'evento esiste (evita errori al caricamento)
local function hook(name, fn)
    if Events and Events[name] and Events[name].Add then
        Events[name].Add(fn)
        return true
    end
    return false
end

-- Timer principale (scatta col tempo di gioco)
hook("EveryOneMinute", onPeriodic)
-- Backup: se EveryOneMinute non scatta (server vuoto/tempo fermo)
hook("EveryTenMinutes", onPeriodic)
-- All'avvio del server: scrive subito, così il file esiste sempre
hook("OnServerStarted", function()
    lastSyncTime = realTime() or 0
    syncData()
end)

print("ITAPz: Data Sync caricato (intervallo: " .. INTERVAL .. "s, output: log del server)")

-- Emissione immediata al load: i dati compaiono subito nel log, senza attendere
-- il timer (utile anche a server vuoto per verificare che tutto funzioni).
syncData()
