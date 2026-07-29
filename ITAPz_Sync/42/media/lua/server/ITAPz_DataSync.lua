--[[
ITAPz — Data Sync
Server-side mod per Project Zomboid Build 42.
Raccoglie le statistiche dei giocatori e le invia al sito ITAPz.
--]]

-- ============================ CONFIGURAZIONE ============================
-- La mod è pubblica: NON modificare questo file (i file Workshop vengono
-- sovrascritti agli aggiornamenti). Ogni server imposta i propri valori
-- creando un file di testo nella cartella Zomboid del server:
--
--   Zomboid/ITAPz_Sync_config.txt
--
-- con righe tipo:
--   SITE_URL=https://iltuosito.it
--   API_KEY=la_tua_chiave
--   INTERVAL=300
--
-- Se il file non esiste si usano i default qui sotto.
local DEFAULTS = {
    SITE_URL = "http://localhost:3000", -- default: sito sulla stessa VPS
    API_KEY  = "",                      -- deve combaciare con SYNC_API_KEY del sito
    INTERVAL = 300,                     -- secondi tra un invio (300 = 5 min)
}

local function loadConfig()
    local cfg = { SITE_URL = DEFAULTS.SITE_URL, API_KEY = DEFAULTS.API_KEY, INTERVAL = DEFAULTS.INTERVAL }
    -- Legge via Java IO da <cartella Zomboid>/ITAPz_Sync_config.txt.
    -- (getFileReader non è affidabile lato server dedicato.)
    pcall(function()
        local dir = getCacheDir()
        if not dir then return end
        local file = JavaNew("java.io.File", dir .. "/ITAPz_Sync_config.txt")
        if not file:exists() then return end
        local reader = JavaNew("java.io.BufferedReader", JavaNew("java.io.FileReader", file))
        local line = reader:readLine()
        while line ~= nil do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k == "SITE_URL" and v ~= "" then cfg.SITE_URL = v
            elseif k == "API_KEY" then cfg.API_KEY = v
            elseif k == "INTERVAL" then cfg.INTERVAL = tonumber(v) or cfg.INTERVAL end
            line = reader:readLine()
        end
        reader:close()
    end)
    return cfg
end

local CFG = loadConfig()
local SITE_URL = CFG.SITE_URL
local API_KEY  = CFG.API_KEY
local INTERVAL = CFG.INTERVAL
local DATA_DIR = nil -- nil = directory di lavoro del server (fallback file JSON)
-- =======================================================================

--[[ Skill mappings ]]
local SKILLS = {
    "Fitness", "Strength", "Sprinting", "Lightfooted", "Nimble", "Sneaking",
    "Axe", "Blunt", "SmallBlunt", "Spear", "LongBlade", "SmallBlade",
    "Firearms", "Reloading", "Aiming",
    "Cooking", "Trapping", "Farming", "Fishing", "Foraging",
    "Carpentry", "Mechanics", "Electricity", "MetalWelding", "Tailoring",
    "Doctoring", "FirstAid",
}

--[[ Utility: serialize table to JSON ]]
local function toJson(t)
    if t == nil then return "null" end
    local typ = type(t)
    if typ == "string" then
        return '"' .. t:gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\\', '\\\\') .. '"'
    elseif typ == "number" or typ == "boolean" then
        return tostring(t)
    elseif typ == "table" then
        local parts = {}
        local isArray = true
        for k, v in pairs(t) do
            if type(k) ~= "number" then isArray = false; break end
        end
        if isArray then
            for _, v in ipairs(t) do
                table.insert(parts, toJson(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(t) do
                table.insert(parts, toJson(k) .. ":" .. toJson(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

--[[ Get all traits as comma-separated string ]]
local function getTraits(descriptor)
    if not descriptor then return "" end
    local traits = descriptor:getTraits()
    if not traits then return "" end
    local list = {}
    for i = 0, traits:size() - 1 do
        table.insert(list, traits:get(i))
    end
    return table.concat(list, ", ")
end

--[[ Risoluzione perk UNA volta al load.
     In Build 42 l'API skill è cambiata: Perks.FromString potrebbe non esistere.
     Risolvo qui in modo protetto; se l'API non c'è, RESOLVED_PERKS resta vuoto e
     getSkills non chiama mai una funzione nil (niente spam di errori a runtime). ]]
local RESOLVED_PERKS = {}
pcall(function()
    if not (Perks and Perks.FromString) then return end
    for _, name in ipairs(SKILLS) do
        local ok, perk = pcall(function() return Perks.FromString(name) end)
        if ok and perk then
            table.insert(RESOLVED_PERKS, { name = name, perk = perk })
        end
    end
end)

--[[ Get all skill levels ]]
local function getSkills(player)
    local out = {}
    for _, rp in ipairs(RESOLVED_PERKS) do
        local ok, level = pcall(function() return player:getPerkLevel(rp.perk) or 0 end)
        local okm, maxLevel = pcall(function() return player:getMaxPerkLevel(rp.perk) or 10 end)
        if ok then
            table.insert(out, { name = rp.name, level = level, maxLevel = (okm and maxLevel) or 10 })
        end
    end
    return out
end

--[[ Collect data from all online players ]]
local function collectPlayerData()
    local players = getOnlinePlayers()
    if not players then return {} end

    local results = {}
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            -- OGNI getter è protetto e salvato in una variabile locale. Nessuna
            -- chiamata a metodo dentro il table.insert finale, così un getter
            -- mancante in una data versione B42 non aborta mai il sync.
            local username, occupation, trait = nil, "", ""
            local trees, bullets, panic, distance, hours = 0, 0, 0, 0, 0
            local kills, zombies, days = 0, 0, 0
            local weight, recipes, infected = 0, 0, false
            local skills = {}

            pcall(function() username = p:getUsername() end)

            local desc = nil
            pcall(function() desc = p:getDescriptor() end)
            pcall(function() occupation = (desc and desc:getProfession()) or "" end)
            pcall(function() trait = getTraits(desc) end)

            local stats = nil
            pcall(function() stats = p:getStats() end)
            if stats then
                pcall(function() trees = stats:getTreesChopped() or 0 end)
                pcall(function() bullets = stats:getBulletsFired() or 0 end)
                pcall(function() panic = stats:getPanicAttacks() or 0 end)
            end

            pcall(function() distance = p:getTotalDistanceWalked() or 0 end)
            pcall(function() hours = p:getHoursSurvived() or 0 end)
            pcall(function() kills = p:getKills() or 0 end)
            pcall(function() zombies = p:getZombieKills() or 0 end)
            pcall(function() days = p:getSurviveDays() or 0 end)
            pcall(function() weight = p:getNutrition():getWeight() or 0 end)
            pcall(function() recipes = p:getKnownRecipes():size() or 0 end)
            pcall(function() infected = p:getBodyDamage():isInfected() or false end)
            pcall(function() skills = getSkills(p) end)

            table.insert(results, {
                name = username or ("Player_" .. i),
                occupation = occupation,
                trait = trait,
                kills = kills,
                zombies = zombies,
                daysSurvived = days,
                hoursSurvived = hours,
                distanceWalked = distance,
                treesChopped = trees,
                bulletsFired = bullets,
                panicAttacks = panic,
                weight = weight,
                recipesKnown = recipes,
                infected = infected,
                skills = skills,
            })
        end
    end
    return results
end

--[[ Write JSON to file ]]
local function writeFile(path, content)
    local ok, err = pcall(function()
        local file = JavaNew("java.io.File", path)
        local dir = file:getParentFile()
        if dir and not dir:exists() then dir:mkdirs() end
        local writer = JavaNew("java.io.FileWriter", file)
        writer:write(content)
        writer:close()
    end)
    if not ok then
        print("ITAPz: Errore scrittura file " .. path .. ": " .. tostring(err))
    end
end

--[[ HTTP POST via Java URLConnection ]]
local function postJson(url, jsonStr, apiKey)
    local ok, code = pcall(function()
        local urlObj = JavaNew("java.net.URL", url)
        local conn = urlObj:openConnection()
        conn:setRequestMethod("POST")
        conn:setDoOutput(true)
        conn:setRequestProperty("Content-Type", "application/json; charset=UTF-8")
        conn:setConnectTimeout(8000)
        conn:setReadTimeout(8000)
        if apiKey and apiKey ~= "" then
            conn:setRequestProperty("X-API-Key", apiKey)
        end

        local out = conn:getOutputStream()
        local bytes = jsonStr:getBytes("UTF-8")
        out:write(bytes)
        out:close()

        return conn:getResponseCode()
    end)
    return code
end

--[[ Main sync function ]]
local function syncData()
    local players = collectPlayerData()
    if #players == 0 then return end

    local payload = toJson({ players = players, timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ") })

    -- 1. Try HTTP POST
    local syncUrl = SITE_URL .. "/api/sync-server-data"
    local httpOk = false
    local code = postJson(syncUrl, payload, API_KEY)
    if code and code >= 200 and code < 300 then
        httpOk = true
    end

    -- 2. Write file (fallback / for bridge)
    local filePath = DATA_DIR
    if not filePath then
        -- Prova a scrivere nella directory di lavoro del server
        local ok, dir = pcall(function()
            return JavaNew("java.io.File", "."):getAbsolutePath()
        end)
        if ok then
            filePath = dir .. "/itapz_sync_data.json"
        else
            filePath = "itapz_sync_data.json"
        end
    else
        filePath = filePath .. "/itapz_sync_data.json"
    end
    writeFile(filePath, payload)

    if httpOk then
        print("ITAPz: Sincronizzati " .. #players .. " giocatori (HTTP " .. code .. ")")
    else
        print("ITAPz: Dati salvati su file (" .. #players .. " giocatori, HTTP fallito: " .. tostring(code) .. ")")
    end
end

--[[ Timer basato sul tempo reale.
     OnTick NON parte sui server dedicati (evento client): si usa
     EveryOneMinute (evento server-side) e si controlla os.time(). ]]
local lastSyncTime = 0

local function onPeriodic()
    local now = os.time()
    if now - lastSyncTime >= INTERVAL then
        lastSyncTime = now
        syncData()
    end
end

Events.EveryOneMinute.Add(onPeriodic)
-- Backup: se EveryOneMinute non fosse disponibile, prova anche EveryTenMinutes.
if Events.EveryTenMinutes then Events.EveryTenMinutes.Add(onPeriodic) end

print("ITAPz: Data Sync caricato (intervallo: " .. INTERVAL .. "s, URL: " .. SITE_URL .. ")")
