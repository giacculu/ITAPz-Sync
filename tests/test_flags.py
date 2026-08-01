"""I marcatori permanenti, provati sul Lua vero della mod.

Il punto di questi test: un marcatore visto una volta deve restare per sempre.
Se sparisse al ciclo successivo, achievement come "prendi fuoco" — che dura
pochi secondi — non scatterebbero praticamente mai, ed e' esattamente il
problema che i marcatori esistono per risolvere.
"""

import json
import os

import pytest
from lupa import LuaRuntime

SYNC_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "ITAPz_Sync", "42", "media", "lua", "server", "ITAPz_DataSync.lua",
)

PRELUDE = """
__lines = {}
print = function(s) table.insert(__lines, tostring(s)) end

__handlers = {}
function __mkEvent(name)
  return { Add = function(fn)
    __handlers[name] = __handlers[name] or {}
    table.insert(__handlers[name], fn)
  end }
end
function __fire(name, a, b, c)
  for _, fn in ipairs(__handlers[name] or {}) do fn(a, b, c) end
end

Events = setmetatable({}, { __index = function(t, k)
  local e = __mkEvent(k); rawset(t, k, e); return e
end })

__moddata = {}
ModData = {
  getOrCreate = function(nome)
    __moddata[nome] = __moddata[nome] or {}
    return __moddata[nome]
  end,
  exists = function(nome) return __moddata[nome] ~= nil end,
}

-- Sul server dedicato `isClient()` e' falso: e' li' che la mod deve girare.
isClient = function() return false end
isServer = function() return true end

function instanceof(v, className)
  if type(v) ~= "table" then return false end
  return v.__class == className
end

-- Opzioni del server: serve solo il limite di velocita'.
getServerOptions = function()
  return { getOption = function(_, nome) if nome == "SpeedLimit" then return 70 end return nil end }
end

-- Abilita': una sola, quella che serve al marcatore "costruttore".
local carpenteria = { getName = function() return "Carpentry" end,
                      getParent = function() return "qualcosa" end }
Perks = { None = "none", Woodwork = carpenteria }
PerkFactory = { PerkList = {
  size = function() return 1 end,
  get = function(_, i) return carpenteria end,
} }

-- Lettore di file finto: serve alle zone (e alla configurazione).
__files = {}
getFileReader = function(nome)
  local righe = __files[nome]
  if not righe then return nil end
  local i = 0
  return {
    readLine = function() i = i + 1; return righe[i] end,
    close = function() end,
  }
end

SafeHouse = { hasSafehouse = function() return nil end }
Faction = { getPlayerFaction = function() return nil end }
getGameTime = function() return nil end
getClimateManager = function() return nil end
getSandboxOptions = function() return nil end
getWorld = function() return nil end

-- Orologio controllabile: fra un ciclo e l'altro la mod aspetta INTERVAL
-- secondi reali, e un test non puo' aspettarli davvero.
__now = 100000
os.time = function() return __now end

-- Il giocatore finto: ogni valore e' pilotabile dal test.
__stato = {
  drunk = 0, salute = 100, veleno = 0, ciboAvariato = 0,
  sanguinanti = 0, fuoco = false, xpCarpenteria = 0,
  velocita = 0, inVeicolo = false, haFlauto = false, infetto = false,
  x = 100, y = 200,
}

local function faiGiocatore(nome)
  local bd = {
    getOverallBodyHealth = function() return __stato.salute end,
    getPoisonLevel = function() return __stato.veleno end,
    getFoodSicknessLevel = function() return __stato.ciboAvariato end,
    getNumPartsBleeding = function() return __stato.sanguinanti end,
    isOnFire = function() return __stato.fuoco end,
    isInfected = function() return __stato.infetto end,
  }
  local veicolo = { getCurrentSpeedKmHour = function() return __stato.velocita end }
  return {
    __class = "IsoPlayer",
    getUsername = function() return nome end,
    getDescriptor = function() return nil end,
    getCharacterTraits = function() return nil end,
    getHoursSurvived = function() return 10 end,
    getZombieKills = function() return 3 end,
    getNutrition = function() return { getWeight = function() return 80 end } end,
    getKnownRecipes = function() return { size = function() return 0 end } end,
    getBodyDamage = function() return bd end,
    getStats = function() return { getDrunkenness = function() return __stato.drunk end } end,
    getPerkLevel = function() return 0 end,
    getXp = function() return { getXP = function() return __stato.xpCarpenteria end } end,
    getVehicle = function() if __stato.inVeicolo then return veicolo end return nil end,
    getInventory = function()
      return {
        contains = function(_, tipo) return __stato.haFlauto and tipo == "Flute" end,
        containsTypeRecurse = function(_, tipo) return __stato.haFlauto and tipo == "Flute" end,
      }
    end,
    isOnFire = function() return __stato.fuoco end,
    getX = function() return __stato.x end,
    getY = function() return __stato.y end,
  }
end

__giocatore = faiGiocatore("Tester")
getOnlinePlayers = function()
  return { size = function() return 1 end, get = function(_, i) return __giocatore end }
end
"""


@pytest.fixture
def mod():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    with open(SYNC_PATH, encoding="utf-8") as f:
        lua.execute(f.read())
    return lua


def stato(lua, **valori):
    """Cambia lo stato del giocatore finto."""
    s = lua.globals()["__stato"]
    for k, v in valori.items():
        s[k] = v


def sincronizza(lua):
    """Fa girare un ciclo e restituisce i marcatori mandati al sito.

    L'orologio va avanti: la mod salta i cicli troppo ravvicinati, e senza
    questo il secondo sync di un test non produrrebbe niente.
    """
    lua.execute("__lines = {}")
    lua.execute("__now = __now + 3600")
    lua.execute('__fire("EveryTenMinutes")')
    righe = lua.globals()["__lines"]
    for i in range(1, len(righe) + 1):
        riga = righe[i]
        if riga.startswith("ITAPZ_PLAYER "):
            return json.loads(riga[len("ITAPZ_PLAYER "):]).get("flags", [])
    return None


def test_nessun_marcatore_allinizio(mod):
    assert sincronizza(mod) == []


def test_ogni_marcatore_si_accende(mod):
    stato(
        mod, drunk=95, salute=80, veleno=1, sanguinanti=2, fuoco=True,
        xpCarpenteria=5, inVeicolo=True, velocita=90, haFlauto=True, infetto=True,
    )
    trovati = sincronizza(mod)
    attesi = [
        "avvelenato", "bruciato", "costruttore", "ferito", "flauto",
        "infetto", "sanguina", "ubriaco", "velocista",
    ]
    assert trovati == attesi


def test_il_marcatore_resta_anche_quando_lo_stato_passa(mod):
    """Il caso che conta: prendere fuoco dura pochi secondi."""
    stato(mod, fuoco=True)
    assert "bruciato" in sincronizza(mod)

    stato(mod, fuoco=False)
    assert "bruciato" in sincronizza(mod), "il marcatore e' sparito quando il fuoco si e' spento"


def test_ubriaco_solo_oltre_la_soglia(mod):
    stato(mod, drunk=50)
    assert "ubriaco" not in sincronizza(mod)
    stato(mod, drunk=95)
    assert "ubriaco" in sincronizza(mod)


def test_velocista_solo_al_limite_del_server(mod):
    stato(mod, inVeicolo=True, velocita=50)
    assert "velocista" not in sincronizza(mod)
    stato(mod, velocita=70)
    assert "velocista" in sincronizza(mod), "il limite del server e' 70: a 70 deve scattare"


def test_velocista_non_scatta_a_piedi(mod):
    stato(mod, inVeicolo=False, velocita=200)
    assert "velocista" not in sincronizza(mod)


def test_uccisione_di_un_giocatore_emette_evento_a_parte(mod):
    lua = mod
    lua.execute("__lines = {}")
    lua.execute("""
        __vittima = { __class = "IsoPlayer",
                      getUsername = function() return "Vittima" end,
                      isDead = function() return true end }
        __arma = { getFullType = function() return "Base.Axe" end }
        __fire("OnWeaponHitCharacter", __giocatore, __vittima, __arma)
    """)
    righe = lua.globals()["__lines"]
    eventi = []
    for i in range(1, len(righe) + 1):
        if righe[i].startswith("ITAPZ_EVENT "):
            eventi.append(json.loads(righe[i][len("ITAPZ_EVENT "):]))
    codici = [e["code"] for e in eventi]
    assert "kill_weapon" in codici
    assert "kill_player" in codici
    assert next(e for e in eventi if e["code"] == "kill_player")["detail"] == "Vittima"


def test_uno_zombie_non_conta_come_giocatore(mod):
    lua = mod
    lua.execute("__lines = {}")
    lua.execute("""
        __zombie = { __class = "IsoZombie", isDead = function() return true end }
        __arma = { getFullType = function() return "Base.Axe" end }
        __fire("OnWeaponHitCharacter", __giocatore, __zombie, __arma)
    """)
    righe = lua.globals()["__lines"]
    codici = [
        json.loads(righe[i][len("ITAPZ_EVENT "):])["code"]
        for i in range(1, len(righe) + 1)
        if righe[i].startswith("ITAPZ_EVENT ")
    ]
    assert "kill_weapon" in codici
    assert "kill_player" not in codici, "uno zombie non e' un giocatore"


def test_sul_client_la_mod_non_fa_niente():
    """Build 42 carica media/lua/server anche sul client collegato in rete.

    Li' questa mod non serve — nessuno legge il log del giocatore — e i suoi
    agganci girerebbero su oggetti che il client ha solo a meta' mentre carica.
    """
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute("isClient = function() return true end")
    with open(SYNC_PATH, encoding="utf-8") as f:
        lua.execute(f.read())

    righe = lua.globals()["__lines"]
    stampate = [righe[i] for i in range(1, len(righe) + 1)]
    assert not any(r.startswith("ITAPZ_") for r in stampate), (
        "sul client la mod ha emesso dati: " + str(stampate)
    )
    assert any("niente da fare sul client" in r for r in stampate)


def traccia(lua):
    """Il percorso mandato al sito con l'ultimo giro di dati."""
    righe = lua.globals()["__lines"]
    for i in range(1, len(righe) + 1):
        if righe[i].startswith("ITAPZ_PLAYER "):
            punti = json.loads(righe[i][len("ITAPZ_PLAYER "):]).get("traccia", [])
            # Lua manda tabelle: lupa le rende come dizionari con indici da 1
            return [[p["1"] if isinstance(p, dict) else p[0],
                     p["2"] if isinstance(p, dict) else p[1]] for p in punti]
    return None


def test_la_traccia_raccoglie_le_posizioni_fra_due_invii(mod):
    """Il caso che rompeva: entrare in una citta' e uscirne fra due sync.

    Il sito vede la posizione solo quando arrivano i dati. Senza il percorso,
    chi passa e se ne va non ci e' mai stato.
    """
    lua = mod
    sincronizza_completo(lua)  # si parte da una traccia vuota

    # Scatti del timer SENZA far avanzare l'orologio: troppo ravvicinati per
    # far partire un invio, che e' esattamente la situazione del problema.
    for x, y in [(8107, 11576), (9000, 11576), (12000, 9000)]:
        stato(lua, x=x, y=y)
        lua.execute('__fire("EveryOneMinute")')

    stato(lua, x=13000, y=8000)
    punti = sincronizza_completo(lua)
    assert punti is not None, "nessuna riga giocatore"
    assert [8107, 11576] in punti, f"il passaggio nella citta' e' andato perso: {punti}"
    assert len(punti) >= 3


def test_la_traccia_si_svuota_dopo_l_invio(mod):
    """I punti gia' spediti non vanno rimandati a ogni giro."""
    lua = mod
    sincronizza_completo(lua)
    stato(lua, x=500, y=500)
    lua.execute('__fire("EveryOneMinute")')
    assert sincronizza_completo(lua)

    secondo = sincronizza_completo(lua)
    assert secondo == [] or secondo is None or len(secondo) <= 1, (
        f"la traccia non e' stata svuotata: {secondo}"
    )


def test_fermo_sul_posto_non_riempie_la_traccia(mod):
    """Chi sta in base non deve produrre cento volte lo stesso punto."""
    lua = mod
    sincronizza_completo(lua)
    stato(lua, x=777, y=888)
    for _ in range(10):
        lua.execute('__fire("EveryOneMinute")')
    punti = sincronizza_completo(lua)
    assert punti is not None
    assert len(punti) <= 2, f"punti ripetuti: {punti}"


def sincronizza_completo(lua):
    """Fa scattare un invio e restituisce la traccia spedita."""
    lua.execute("__lines = {}")
    lua.execute("__now = __now + 3600")
    lua.execute('__fire("EveryTenMinutes")')
    return traccia(lua)


def eventi(lua):
    """Gli eventi emessi dall'ultimo azzeramento del log."""
    righe = lua.globals()["__lines"]
    fuori = []
    for i in range(1, len(righe) + 1):
        if righe[i].startswith("ITAPZ_EVENT "):
            fuori.append(json.loads(righe[i][len("ITAPZ_EVENT "):]))
    return fuori


def mod_con_zone():
    """Carica la mod con un elenco di zone gia' scritto nel file."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute("""
        __files["ITAPz_Zone.txt"] = {
          "rosewood 7657 11126 8557 12026",
          "laboratorio_droga 11467 9144 11767 9444",
        }
    """)
    with open(SYNC_PATH, encoding="utf-8") as f:
        lua.execute(f.read())
    return lua


def test_entrare_in_una_zona_emette_un_evento():
    """Il punto di tutto: l'evento parte quando entri, non quando parte il sync."""
    lua = mod_con_zone()
    lua.execute("__lines = {}")
    stato(lua, x=8107, y=11576)  # centro di Rosewood
    lua.execute('__fire("EveryOneMinute")')

    zone = [e["detail"] for e in eventi(lua) if e["code"] == "zona"]
    assert zone == ["rosewood"], f"eventi zona: {zone}"


def test_la_zona_si_annuncia_una_volta_sola():
    lua = mod_con_zone()
    stato(lua, x=8107, y=11576)
    lua.execute('__fire("EveryOneMinute")')

    lua.execute("__lines = {}")
    for _ in range(5):
        lua.execute('__fire("EveryOneMinute")')
    zone = [e["detail"] for e in eventi(lua) if e["code"] == "zona"]
    assert zone == [], f"la zona e' stata riannunciata: {zone}"


def test_fuori_da_ogni_zona_non_emette_niente():
    lua = mod_con_zone()
    lua.execute("__lines = {}")
    stato(lua, x=1, y=1)
    lua.execute('__fire("EveryOneMinute")')
    assert [e for e in eventi(lua) if e["code"] == "zona"] == []


def test_senza_file_zone_la_mod_funziona_lo_stesso():
    """Se l'agent non ha ancora scritto il file, non deve rompersi niente."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    with open(SYNC_PATH, encoding="utf-8") as f:
        lua.execute(f.read())

    lua.execute("__lines = {}")
    stato(lua, x=8107, y=11576)
    lua.execute('__fire("EveryOneMinute")')
    assert [e for e in eventi(lua) if e["code"] == "zona"] == []
    # e il resto continua a girare
    assert sincronizza_completo(lua) is not None
