--[[
ITAPz — Data Sync
Mod server-side per Project Zomboid Build 42.

Raccoglie le statistiche dei giocatori online e le scrive in un file JSON nella
cartella Zomboid del server. Il Lua di Build 42 NON ha alcuna API di rete
(niente socket, niente JavaNew): la POST verso il sito la fa il bridge esterno
(vedi bridge/itapz-bridge.sh nella repo della mod).

File prodotto:  <cartella Zomboid>/Lua/itapz_sync_data.json
                (getFileWriter/getFileReader lavorano nella sottocartella Lua/)
--]]

-- ============================ CONFIGURAZIONE ============================
-- NON modificare questo file (i file Workshop vengono sovrascritti agli
-- aggiornamenti). Per cambiare l'intervallo crea il file
--   <cartella Zomboid>/Lua/ITAPz_Sync_config.txt
-- con:
--
--   INTERVAL=60
--
local DEFAULT_INTERVAL = 300 -- secondi tra due scritture (300 = 5 min)
local DATA_FILE = "itapz_sync_data.json"

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

--[[ Tratti del personaggio: player:getCharacterTraits() (B42) ]]
local function getTraits(player)
    local list = {}
    pcall(function()
        local traits = player:getCharacterTraits()
        if not traits then return end
        for i = 0, traits:size() - 1 do
            local t = traits:get(i)
            if t then table.insert(list, tostring(t)) end
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
            local trees, bullets, panic, hours, zombies = 0, 0, 0, 0, 0
            local weight, recipes, infected = 0, 0, false
            local skills = {}

            pcall(function() username = p:getUsername() end)
            pcall(function()
                local desc = p:getDescriptor()
                if desc then occupation = tostring(desc:getCharacterProfession() or "") end
            end)
            pcall(function() trait = getTraits(p) end)

            pcall(function()
                local stats = p:getStats()
                if stats then
                    pcall(function() trees = stats:getTreesChopped() or 0 end)
                    pcall(function() bullets = stats:getBulletsFired() or 0 end)
                    pcall(function() panic = stats:getPanicAttacks() or 0 end)
                end
            end)

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
                treesChopped = tonumber(trees) or 0,
                bulletsFired = tonumber(bullets) or 0,
                panicAttacks = tonumber(panic) or 0,
                weight = tonumber(weight) or 0,
                recipesKnown = tonumber(recipes) or 0,
                infected = infected and true or false,
                skills = skills,
            })
        end
    end
    return results
end

--[[ Scrive il JSON nella cartella Zomboid (getFileWriter: unica API file
     disponibile lato Lua). ]]
local function writeData(content)
    local ok = pcall(function()
        -- (nome, creaSeNonEsiste, append=false -> sovrascrive)
        local writer = getFileWriter(DATA_FILE, true, false)
        if not writer then error("writer nil") end
        writer:write(content)
        writer:close()
    end)
    return ok
end

--[[ Ciclo principale ]]
local function syncData()
    local players = collectPlayerData()
    local payload = toJson({
        players = players,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })

    if writeData(payload) then
        print("ITAPz: Dati scritti su " .. DATA_FILE .. " (" .. #players .. " giocatori)")
    else
        print("ITAPz: ERRORE scrittura " .. DATA_FILE)
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

print("ITAPz: Data Sync caricato (intervallo: " .. INTERVAL .. "s, file: " .. DATA_FILE .. ")")

-- Scrittura immediata al load: crea subito il file (anche a server vuoto) e
-- mostra nel log se la scrittura funziona, senza attendere il timer.
syncData()
