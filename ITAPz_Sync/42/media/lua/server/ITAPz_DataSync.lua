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
--   INTERVAL=15
--
local DEFAULT_INTERVAL = 30 -- secondi tra due emissioni

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

--[[ Stato del mondo: ora in-game, stagione, meteo.
     Letti direttamente dalle API del gioco (piu' affidabile del parsing di
     map_t.bin fatto dal reporter). Ogni chiamata e' protetta. ]]
local function collectWorld()
    local w = {}

    pcall(function()
        local gt = getGameTime()
        if not gt then return end
        pcall(function() w.hour = math.floor(gt:getHour() or 0) end)
        pcall(function() w.minutes = math.floor(gt:getMinutes() or 0) end)
        pcall(function() w.day = math.floor((gt:getDay() or 0) + 1) end)
        pcall(function() w.month = math.floor((gt:getMonth() or 0) + 1) end)
        pcall(function() w.year = math.floor(gt:getYear() or 0) end)
        pcall(function() w.nightsSurvived = math.floor(gt:getNightsSurvived() or 0) end)
        pcall(function() w.worldAgeHours = math.floor(gt:getWorldAgeHours() or 0) end)
    end)

    pcall(function()
        local cm = getClimateManager()
        if not cm then return end
        -- tonumber() e' obbligatorio, non difensivo: un getter che restituisce
        -- un oggetto Java invece di un numero fa fallire la moltiplicazione
        -- ("__mul not defined for operands"), e il pcall che la avvolge NON
        -- basta — PZ registra comunque lo stack trace e accende l'icona di
        -- errore in gioco a ogni ciclo di sync.
        local function num(v, decimali)
            local n = tonumber(v)
            if not n then return 0 end
            return math.floor(n * decimali) / decimali
        end

        pcall(function() w.season = tostring(cm:getSeasonName() or "") end)
        pcall(function() w.temperature = num(cm:getTemperature(), 10) end)
        pcall(function() w.rain = num(cm:getPrecipitationIntensity(), 100) end)
        pcall(function() w.snow = num(cm:getSnowStrength(), 100) end)
        pcall(function() w.fog = num(cm:getFogIntensity(), 100) end)
        pcall(function() w.wind = num(cm:getWindPower(), 100) end)
        pcall(function() w.isRaining = cm:isRaining() and true or false end)
        -- niente `thunder`: getThunderStorm() restituisce un oggetto
        -- ThunderStorm (getClouds/triggerThunderEvent), non un'intensita'.
        -- B42 non espone un valore numerico, quindi il campo resta a 0.
    end)

    return w
end

--[[ Impostazioni sandbox rilevanti (sola lettura). ]]
local SANDBOX_KEYS = {
    "Zombies", "Distribution", "DayLength", "StartYear", "StartMonth", "StartDay",
    "WaterShut", "ElecShut", "WaterShutModifier", "ElecShutModifier",
    "XpMultiplier", "LootRespawn", "HoursForLootRespawn", "TimeSinceApo",
    "ZombieLore.Speed", "ZombieLore.Strength", "ZombieLore.Toughness",
    "ZombieLore.Cognition", "ZombieLore.Memory", "ZombieLore.Sight",
    "ZombieLore.Hearing", "ZombieLore.ActiveOnly",
}

local function collectSandbox()
    local out = {}
    pcall(function()
        local so = getSandboxOptions()
        if not so then return end
        for _, key in ipairs(SANDBOX_KEYS) do
            pcall(function()
                local opt = so:getOptionByName(key)
                if opt then
                    local v = opt:getValue()
                    if v ~= nil then out[key] = tostring(v) end
                end
            end)
        end
    end)
    return out
end

--[[ Elenco completo delle fazioni del server.

     Serve perche' i dati per giocatore mostrano solo le fazioni di chi sta
     giocando: una fazione i cui membri non entrano da giorni resterebbe
     invisibile al sito.

     getPlayers() NON comprende il fondatore — il codice del gioco fa
     `getPlayers():size() + 1` — quindi va aggiunto a mano all'elenco. ]]
local function collectFactions()
    local out = {}
    pcall(function()
        local factions = Faction.getFactions()
        if not factions then return end

        for i = 0, factions:size() - 1 do
            pcall(function()
                local f = factions:get(i)
                if not f then return end

                local nome, tag, owner = "", "", ""
                pcall(function() nome = tostring(f:getName() or "") end)
                pcall(function() tag = tostring(f:getTag() or "") end)
                pcall(function() owner = tostring(f:getOwner() or "") end)
                if nome == "" then return end

                local membri = {}
                if owner ~= "" then table.insert(membri, owner) end
                pcall(function()
                    local ps = f:getPlayers()
                    if not ps then return end
                    for j = 0, ps:size() - 1 do
                        local m = tostring(ps:get(j) or "")
                        if m ~= "" and m ~= owner then table.insert(membri, m) end
                    end
                end)

                table.insert(out, { name = nome, tag = tag, owner = owner, members = membri })
            end)
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
            -- Stato osservato: Build 42 non emette eventi per veicoli, fazioni
            -- e safehouse, ma tutto questo si puo' leggere qui a ogni ciclo.
            local faction, factionTag, factionOwner = "", "", false
            local hasSafehouse, inVehicle = false, false
            local px, py = 0, 0

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

            pcall(function() inVehicle = p:getVehicle() ~= nil end)
            pcall(function() px = math.floor(p:getX() or 0) end)
            pcall(function() py = math.floor(p:getY() or 0) end)
            pcall(function() hasSafehouse = SafeHouse.hasSafehouse(p) ~= nil end)
            pcall(function()
                local f = Faction.getPlayerFaction(p)
                if f then
                    faction = tostring(f:getName() or "")
                    factionTag = tostring(f:getTag() or "")
                    -- getOwner restituisce lo username del fondatore
                    factionOwner = tostring(f:getOwner() or "") == tostring(username or "")
                end
            end)

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
                faction = faction,
                factionTag = factionTag,
                factionOwner = factionOwner and true or false,
                hasSafehouse = hasSafehouse and true or false,
                inVehicle = inVehicle and true or false,
                x = tonumber(px) or 0,
                y = tonumber(py) or 0,
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
    print("ITAPZ_WORLD " .. toJson(collectWorld()))
    print("ITAPZ_SANDBOX " .. toJson(collectSandbox()))
    print("ITAPZ_FACTIONS " .. toJson(collectFactions()))
    for _, p in ipairs(players) do
        print("ITAPZ_PLAYER " .. toJson(p))
    end
    print("ITAPZ_SYNC_END")
end

--[[ ===================== EVENTI =====================

     Le fotografie di stato non bastano per tutto: un'uccisione con l'ascia o
     una morte non lasciano traccia nello stato al ciclo successivo. Questi
     eventi vengono stampati NEL MOMENTO in cui accadono, con una sequenza
     progressiva; il bridge tiene un segnalibro sul log e li raccoglie tutti,
     anche se salta un giro.

     Solo gli eventi che la sonda ha dimostrato funzionanti su server dedicato,
     e solo quelli che dicono a CHI attribuirli: un evento senza giocatore non
     puo' reggere un achievement. ]]

-- Identifica questa esecuzione del server: insieme a `seq` rende ogni evento
-- unico, cosi' il sito puo' scartare i duplicati se il bridge rimanda.
local SESSION = tostring(os.time())
local seq = 0

local function usernameOf(v)
    local name = nil
    pcall(function()
        if instanceof(v, "IsoPlayer") then name = tostring(v:getUsername() or "") end
    end)
    if name == "" then return nil end
    return name
end

local function emitEvent(code, player, detail)
    local name = usernameOf(player)
    if not name then return end -- senza giocatore l'evento e' inutilizzabile

    seq = seq + 1
    print("ITAPZ_EVENT " .. toJson({
        s = SESSION,
        n = seq,
        code = code,
        player = name,
        detail = tostring(detail or ""),
    }))
end

local function hookEvent(name, fn)
    pcall(function()
        if Events and Events[name] and Events[name].Add then
            Events[name].Add(function(a, b, c) pcall(fn, a, b, c) end)
        end
    end)
end

-- Uccisione con arma: l'unico evento che porta insieme attaccante, vittima e
-- arma. Il dettaglio e' il tipo di arma, cosi' il sito puo' contare sia le
-- uccisioni totali sia quelle con un'arma specifica.
hookEvent("OnWeaponHitCharacter", function(attacker, target, weapon)
    local morto = false
    pcall(function() morto = target:isDead() end)
    if not morto then return end

    local arma = ""
    pcall(function() arma = tostring(weapon:getFullType() or "") end)
    emitEvent("kill_weapon", attacker, arma)
end)

-- Morte: OnPlayerDeath non scatta sui server dedicati, OnCharacterDeath si',
-- ma vale anche per gli zombie: usernameOf() filtra da solo.
hookEvent("OnCharacterDeath", function(character)
    emitEvent("death", character, "")
end)

-- Livello di abilita' guadagnato
hookEvent("LevelPerk", function(player, perk, level)
    local nome = ""
    pcall(function() nome = tostring(perk:getName() or "") end)
    emitEvent("level_up", player, nome .. ":" .. tostring(level or ""))
end)

-- Personaggio nuovo (OnCreatePlayer non scatta sui server dedicati)
hookEvent("OnCreateLivingCharacter", function(player)
    emitEvent("new_character", player, "")
end)

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
