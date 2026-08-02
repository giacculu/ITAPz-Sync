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

--[[ Solo sul server.

     Build 42 carica media/lua/server anche sul CLIENT quando ci si collega a
     una partita in rete. Li' questa mod non serve a niente — nessuno legge il
     log del giocatore — ma i suoi agganci girano lo stesso, su oggetti che il
     client ha solo a meta' mentre carica.

     Uscire subito toglie di mezzo tutto quel rischio e un po' di rumore nel
     log di chi gioca. `isClient()` e' vero solo sul client collegato a un
     server dedicato: in singleplayer resta falso, e li' la mod puo' girare. ]]
local function soloClient()
    local risposta = false
    pcall(function() risposta = isClient() == true end)
    return risposta
end

if soloClient() then
    print("ITAPz: mod server-side, niente da fare sul client")
    return
end

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

--[[ Tratti del personaggio (B42).

     Si manda il "type" del tratto (es. "strong", "nightowl"), non il nome
     tradotto: il sito ha la sua tabella id -> nome italiano + icona, cosi' la
     resa non dipende da come il gioco traduce e le icone si agganciano per id.

     getKnownTraits() restituisce le voci; da ognuna si risale alla definizione
     con CharacterTraitDefinition.getCharacterTraitDefinition(...) e se ne legge
     getType(). Se qualcosa non risponde si ripiega su getName()/tostring, per
     non perdere il tratto del tutto. ]]
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
                local id = nil
                pcall(function()
                    local def = CharacterTraitDefinition.getCharacterTraitDefinition(t)
                    if def and def.getType then id = def:getType() end
                end)
                if not id then pcall(function() id = t:getType() end) end
                if not id then pcall(function() id = t:getName() end) end
                table.insert(list, tostring(id or t))
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
--[[ Marcatori permanenti.

     Alcuni achievement chiedono cose che durano pochi secondi: essere a fuoco,
     sanguinare, toccare la velocita' massima. La sincronizzazione passa ogni
     30 secondi, quindi guardare solo lo stato del momento vorrebbe dire
     perderli quasi sempre.

     Qui ogni marcatore, una volta visto, resta: si tiene in ModData, che il
     gioco salva col mondo. Al wipe sparisce col resto, ed e' giusto cosi'.

     I nomi devono combaciare con FLAG_TARGETS in src/lib/achievements.ts del
     sito: un marcatore scritto diverso e' un achievement che non scatta mai. ]]
local FLAG_STORE = "ITAPzFlags"

local function flagsDi(username)
    local tutti = ModData.getOrCreate(FLAG_STORE)
    if not tutti[username] then tutti[username] = {} end
    return tutti[username]
end

--[[ Ubriacatura: la scala del gioco arriva a 100. Si chiede quasi il massimo
     invece del massimo esatto, perche' il valore cala da solo e centrare il
     100 al momento del controllo sarebbe questione di fortuna. ]]
local SOGLIA_UBRIACO = 90

--[[ Velocita' massima del server. `SpeedLimit` e' l'opzione che la impone;
     se non si riesce a leggerla si usa il valore predefinito del gioco. ]]
local function limiteVelocita()
    local limite = nil
    pcall(function()
        local opts = getServerOptions()
        if opts then limite = tonumber(opts:getOption("SpeedLimit")) end
    end)
    return limite or 70
end

--[[ XP di carpenteria: qualsiasi valore sopra zero significa aver costruito o
     smontato qualcosa. Piu' affidabile di un evento di costruzione, che in
     Build 42 ha cambiato nome piu' volte. ]]
local function xpCarpenteria(player)
    local xp = 0
    pcall(function()
        local perk = Perks.Woodwork
        -- In alcune versioni la costante non esiste: si cerca per nome.
        if not perk then
            local list = PerkFactory.PerkList
            for i = 0, list:size() - 1 do
                local p = list:get(i)
                if p and tostring(p:getName()) == "Carpentry" then perk = p break end
            end
        end
        if perk then xp = tonumber(player:getXp():getXP(perk)) or 0 end
    end)
    return xp
end

--[[ Aggiorna i marcatori del giocatore e restituisce l'elenco.

     Ogni controllo e' protetto: un metodo che in una versione non esiste deve
     saltare quel marcatore, non far fallire tutta la raccolta dati. ]]
local function aggiornaFlags(player, username, infetto, inVeicolo)
    local flags = {}
    pcall(function() flags = flagsDi(username) end)

    local function segna(nome, condizione)
        if flags[nome] then return end
        local ok, valore = pcall(condizione)
        if ok and valore then flags[nome] = true end
    end

    --[[ Livello di un moodle (0-4), o 0 se il tipo non esiste in questa
         versione. Il moodle e' cio' che il gioco mostra al giocatore, piu'
         affidabile del valore grezzo che cala da solo fra un sync e l'altro. ]]
    local function moodle(tipo)
        local n = 0
        pcall(function()
            local m = player:getMoodles()
            if m and tipo then n = tonumber(m:getMoodleLevel(tipo)) or 0 end
        end)
        return n
    end

    --[[ Il fuoco dura pochi secondi e un sync ogni tanto lo perde quasi sempre.
         Le ustioni invece restano: se una parte del corpo e' bruciata, il
         giocatore e' stato a fuoco. Cosi' il marcatore scatta anche a fiamme
         gia' spente. ]]
    local function haUstioni()
        local ok, res = pcall(function()
            local bd = player:getBodyDamage()
            if bd.isOnFire and bd:isOnFire() then return true end
            local parti = nil
            pcall(function() parti = bd:getBodyParts() end)
            if parti and parti.size then
                for i = 0, parti:size() - 1 do
                    local bp = parti:get(i)
                    if bp then
                        if bp.isBurnt and bp:isBurnt() then return true end
                        if bp.getBurnTime and (tonumber(bp:getBurnTime()) or 0) > 0 then return true end
                    end
                end
            end
            return false
        end)
        return ok and res == true
    end

    segna("ubriaco", function()
        -- Moodle "Ubriaco" (livello 3) o oltre; in ripiego il valore grezzo con
        -- una soglia bassa, perche' 90 non lo prendeva quasi mai.
        if moodle(MoodleType.DRUNK) >= 3 then return true end
        return (tonumber(player:getStats():getDrunkenness()) or 0) >= 40
    end)
    segna("ferito", function()
        return (tonumber(player:getBodyDamage():getOverallBodyHealth()) or 100) < 100
    end)
    segna("avvelenato", function()
        -- Il moodle della nausea (avvelenamento da cibo) se c'e', altrimenti i
        -- valori grezzi di veleno e malattia da cibo.
        if moodle(MoodleType.SICK) >= 1 then return true end
        local bd = player:getBodyDamage()
        local veleno = tonumber(bd:getPoisonLevel()) or 0
        local cibo = 0
        pcall(function() cibo = tonumber(bd:getFoodSicknessLevel()) or 0 end)
        return veleno > 0 or cibo > 0
    end)
    segna("infetto", function() return infetto == true end)
    segna("sanguina", function()
        local bd = player:getBodyDamage()
        local parti = nil
        pcall(function() parti = bd:getNumPartsBleeding() end)
        if parti ~= nil then return (tonumber(parti) or 0) > 0 end
        return bd:isBleeding() == true
    end)
    segna("bruciato", function()
        if player.isOnFire and player:isOnFire() then return true end
        if player:getBodyDamage():isOnFire() == true then return true end
        return haUstioni()
    end)
    segna("costruttore", function() return xpCarpenteria(player) > 0 end)
    segna("velocista", function()
        if not inVeicolo then return false end
        local v = player:getVehicle()
        if not v then return false end
        return (tonumber(v:getCurrentSpeedKmHour()) or 0) >= limiteVelocita()
    end)
    segna("flauto", function()
        local inv = player:getInventory()
        if not inv then return false end
        if inv.containsTypeRecurse and inv:containsTypeRecurse("Flute") then return true end
        return inv:contains("Flute") == true
    end)

    local elenco = {}
    for nome, attivo in pairs(flags) do
        if attivo then table.insert(elenco, nome) end
    end
    table.sort(elenco)
    return elenco
end


--[[ Traccia degli spostamenti.

     Gli achievement di esplorazione chiedono di aver raggiunto un posto. Il
     sito pero' vede la posizione solo quando arrivano i dati, cioe' ogni 30
     secondi: chi entra in una citta' e ne esce prima del giro successivo non
     ci e' mai stato, per quanto ne sa il sito.

     Qui la posizione si annota a ogni scatto del timer — che batte sul minuto
     di gioco, molto piu' fitto — e il percorso viene spedito insieme ai dati.
     A guardare se quel percorso attraversa una zona ci pensa il sito, che e'
     l'unico a sapere dove sono le zone: metterne una copia nella mod
     significherebbe doverle tenere allineate in due posti.

     La traccia sta in memoria e non in ModData: perderla a un riavvio non e'
     grave, sono al massimo trenta secondi di cammino. ]]
local MAX_PUNTI = 120 -- tetto per giocatore: oltre, un percorso lungo gonfierebbe la riga

local tracce = {}

local function annotaPosizione(username, x, y)
    if not username then return end
    local punti = tracce[username]
    if not punti then
        punti = {}
        tracce[username] = punti
    end

    -- Fermo sul posto: non si annota due volte lo stesso punto, o la traccia
    -- si riempirebbe di ripetizioni di chi sta in base.
    local ultimo = punti[#punti]
    if ultimo and ultimo[1] == x and ultimo[2] == y then return end

    if #punti >= MAX_PUNTI then table.remove(punti, 1) end
    table.insert(punti, { x, y })
end

--[[ Zone della mappa.

     L'elenco lo tiene il sito, che e' l'unico posto dove ha senso: l'agent lo
     scarica e lo scrive in Zomboid/Lua/ITAPz_Zone.txt, l'unica cartella da cui
     il Lua del server sa leggere.

     Serve perche' il sito vede la posizione solo quando arrivano i dati, ogni
     mezzo minuto: chi entra in una citta' e ne esce nel mezzo non ci e' mai
     stato. Qui invece il controllo avviene a ogni scatto del timer e, appena
     si entra, parte un evento — che e' un fatto preciso, non una posizione da
     interpretare.

     Una zona raggiunta si segna in ModData e non si ripete: l'evento vale una
     volta per personaggio. Al wipe sparisce col mondo, come deve.

     Formato del file, una riga per zona:  codice x1 y1 x2 y2 ]]
local ZONE_FILE = "ITAPz_Zone.txt"
local ZONE_STORE = "ITAPzZone"

local zone = {}

local function caricaZone()
    local caricate = {}
    pcall(function()
        local reader = getFileReader(ZONE_FILE, false)
        if not reader then return end
        local line = reader:readLine()
        while line ~= nil do
            local codice, x1, y1, x2, y2 =
                -- Il trattino va protetto: nei modelli Lua "-" da solo e'
                -- un quantificatore, non il segno meno.
                line:match("^%s*([%w_]+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s*$")
            if codice then
                table.insert(caricate, {
                    codice = codice,
                    x1 = tonumber(x1), y1 = tonumber(y1),
                    x2 = tonumber(x2), y2 = tonumber(y2),
                })
            end
            line = reader:readLine()
        end
        reader:close()
    end)
    zone = caricate
    print("ITAPz: zone caricate: " .. #zone)
end

local function zoneRaggiunte(username)
    local tutte = ModData.getOrCreate(ZONE_STORE)
    if not tutte[username] then tutte[username] = {} end
    return tutte[username]
end

-- Dichiarata qui e definita piu' in basso: il corpo usa emitEvent, che in Lua
-- e' una locale che nasce dopo. Senza questa dichiarazione la funzione
-- vedrebbe una globale inesistente e morirebbe dentro il pcall che la chiama,
-- in silenzio.
local controllaZone


--[[ Segna dove sono adesso tutti i giocatori online.

     Gira a ogni scatto del timer, anche quando non e' ancora ora di spedire i
     dati: e' proprio fra un invio e l'altro che serve. ]]
local function annotaTutti()
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            pcall(function()
                local nome = p:getUsername()
                local x = math.floor(p:getX() or 0)
                local y = math.floor(p:getY() or 0)
                annotaPosizione(nome, x, y)
                controllaZone(p, nome, x, y)
            end)
        end
    end
end

--[[ Il percorso di un giocatore, e lo svuota.

     Si svuota subito: i punti sono gia' partiti verso il sito, tenerli
     significherebbe rimandarli a ogni giro. ]]
local function prendiTraccia(username)
    local punti = tracce[username] or {}
    tracce[username] = nil
    return punti
end


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

            local accessLevel = ""
            pcall(function() username = p:getUsername() end)
            local forename, surname = "", ""
            pcall(function()
                local desc = p:getDescriptor()
                if desc then
                    occupation = tostring(desc:getCharacterProfession() or "")
                    forename = tostring(desc:getForename() or "")
                    surname = tostring(desc:getSurname() or "")
                end
            end)
            pcall(function() trait = getTraits(p) end)
            -- Ruolo sul server (admin/moderator/gm/observer, vuoto per i comuni):
            -- il sito ci nasconde lo staff da classifiche e profili, senza dover
            -- indovinare dal nickname.
            pcall(function() accessLevel = tostring(p:getAccessLevel() or "") end)

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

            -- Marcatori: aggiornati adesso, con lo stato appena letto.
            local flags = {}
            if username then
                pcall(function() flags = aggiornaFlags(p, username, infected, inVehicle) end)
            end

            table.insert(results, {
                name = username or ("Player_" .. i),
                occupation = occupation,
                forename = forename,
                surname = surname,
                trait = trait,
                accessLevel = accessLevel,
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
                flags = flags,
                traccia = username and prendiTraccia(username) or {},
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

--[[ Guarda se il giocatore e' dentro una zona nuova, e in tal caso lo dice.

     Il confronto e' sui bordi inclusi, come sul sito: un giocatore esattamente
     sul confine e' dentro. ]]
controllaZone = function(player, username, x, y)
    if #zone == 0 or not username then return end

    local viste
    if not pcall(function() viste = zoneRaggiunte(username) end) then return end

    for _, z in ipairs(zone) do
        if not viste[z.codice]
            and x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then
            viste[z.codice] = true
            emitEvent("zona", player, z.codice)
        end
    end
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

    -- Vittima umana: e' un altro conto, e un altro achievement. Si controlla
    -- che sia un giocatore diverso dall'attaccante, o un colpo andato male su
    -- se stessi verrebbe contato come omicidio.
    local vittima = usernameOf(target)
    local colpevole = usernameOf(attacker)
    if vittima and colpevole and vittima ~= colpevole then
        emitEvent("kill_player", attacker, vittima)
    end
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

--[[ Scioglimento fazioni richieste dallo staff.

     Il file lo scrive l'agent (mirror della blocklist del sito). Build 42 non
     ha un comando RCON per sciogliere una fazione: l'unica via dal Lua e'
     sendFactionDisband, pensata per il client ma qui tentata dal server —
     va verificata in gioco, potrebbe non avere effetto.

     La mod sul server NON puo' scrivere file, quindi non svuota l'elenco: lo
     rilegge a ogni giro. Sciogliere una fazione gia' sparita e' un no-op,
     quindi ripetere non fa danno; e finche' un nome resta nell'elenco, quella
     fazione viene sciolta appena ricompare. ]]
local DISBAND_FILE = "ITAPz_Disband.txt"

local function processaDisband()
    local nomi = {}
    pcall(function()
        local reader = getFileReader(DISBAND_FILE, false)
        if not reader then return end
        local line = reader:readLine()
        while line ~= nil do
            local n = line:match("^%s*(.-)%s*$")
            if n and n ~= "" then nomi[string.lower(n)] = true end
            line = reader:readLine()
        end
        reader:close()
    end)
    if next(nomi) == nil then return end

    pcall(function()
        local facts = Faction.getFactions()
        if not facts then return end
        -- All'indietro: sciogliere una fazione puo' modificare la lista.
        for i = facts:size() - 1, 0, -1 do
            local f = facts:get(i)
            if f then
                local nome, tag = "", ""
                pcall(function() nome = tostring(f:getName() or "") end)
                pcall(function() tag = tostring(f:getTag() or "") end)
                if nomi[string.lower(nome)] or (tag ~= "" and nomi[string.lower(tag)]) then
                    pcall(function() sendFactionDisband(f) end)
                    print("ITAPz: tentato scioglimento fazione '" .. nome .. "'")
                end
            end
        end
    end)
end

--[[ Notifiche private in gioco.

     Il sito accoda un messaggio per UN solo giocatore (achievement sbloccati,
     consegne del battlepass). Non esiste un comando RCON per parlare a uno
     solo: l'agent e il rewards scrivono una riga in Zomboid/Lua/ITAPz_Notify.txt
     (formato: <id>\t<username>\t<message>) e qui la si inoltra a quel giocatore
     con sendServerCommand. Il client la mostra in chat, invisibile agli altri.

     L'id rende la riga unica: una volta inviata si segna in ModData e non si
     ripete, anche se il file non e' ancora stato ripulito. Se il giocatore e'
     offline la riga resta in attesa finche' e' nel file. ]]
local NOTIFY_FILE = "ITAPz_Notify.txt"
local NOTIFY_STORE = "ITAPzNotify"

local function trovaGiocatore(username)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local nome = ""
            pcall(function() nome = tostring(p:getUsername() or "") end)
            if nome == username then return p end
        end
    end
    return nil
end

local function processaNotifiche()
    local righe = {}
    pcall(function()
        local reader = getFileReader(NOTIFY_FILE, false)
        if not reader then return end
        local line = reader:readLine()
        while line ~= nil do
            table.insert(righe, line)
            line = reader:readLine()
        end
        reader:close()
    end)
    if #righe == 0 then return end

    local visti = {}
    pcall(function() visti = ModData.getOrCreate(NOTIFY_STORE) end)

    for _, riga in ipairs(righe) do
        local id, nome, msg = riga:match("^([^\t]+)\t([^\t]+)\t(.+)$")
        if id and nome and msg and not visti[id] then
            local p = trovaGiocatore(nome)
            if p then
                visti[id] = true
                pcall(function()
                    sendServerCommand(p, "ITAPz_Sync", "Notify", { message = msg })
                end)
            end
        end
    end
end

--[[ Ciclo principale ]]
local function syncData()
    local ok = pcall(emitData)
    if not ok then
        print("ITAPz: ERRORE durante la raccolta dati")
    end
    pcall(processaDisband)
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

    -- Prima si annota dove sono tutti, poi si guarda se e' ora di spedire:
    -- e' fra un invio e l'altro che la traccia serve.
    pcall(annotaTutti)
    -- Notifiche private (achievement, consegne): si inoltrano a ogni scatto,
    -- senza aspettare l'intervallo di sync.
    pcall(processaNotifiche)
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

caricaZone()

print("ITAPz: Data Sync caricato (intervallo: " .. INTERVAL .. "s, output: log del server)")

-- Emissione immediata al load: i dati compaiono subito nel log, senza attendere
-- il timer (utile anche a server vuoto per verificare che tutto funzioni).
syncData()
