"""Esegue il Lua vero della mod con le API di Project Zomboid simulate.

Testare una copia del codice non dimostra niente: qui viene caricato lo stesso
file che finisce sul Workshop. Di PZ si simula solo ciò che la sonda tocca —
Events, ModData e print.
"""

import os
from lupa import LuaRuntime

PROBE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "ITAPz_Sync", "42", "media", "lua", "server", "ITAPz_Probe.lua",
)

PRELUDE = """
__lines = {}
print = function(s) table.insert(__lines, tostring(s)) end

__handlers = {}
__moddata = {}

function __mkEvent(name)
  return { Add = function(fn)
    __handlers[name] = __handlers[name] or {}
    table.insert(__handlers[name], fn)
  end }
end

function __fire(name)
  for _, fn in ipairs(__handlers[name] or {}) do fn() end
end
"""


class Probe:
    # I nomi Lua vanno letti con la notazione a indice: dentro una classe
    # Python un attributo con due underscore iniziali verrebbe rinominato
    # (self._lua.globals().__lines diventerebbe _Probe__lines).
    def __init__(self, lua):
        self._lua = lua

    @property
    def lines(self):
        raw = self._lua.globals()["__lines"]
        return [raw[i] for i in range(1, len(raw) + 1)]

    @property
    def moddata(self):
        md = self._lua.globals()["__moddata"]
        out = {}
        for key in md:
            entry = md[key]
            out[key] = {k: entry[k] for k in entry}
        return out

    def fire(self, event_name):
        self._lua.globals()["__fire"](event_name)

    def has(self, needle):
        return any(needle in line for line in self.lines)

    def count(self, needle):
        return sum(1 for line in self.lines if needle in line)


def load_probe(available_events, moddata=None, moddata_broken=False):
    """Carica la sonda.

    available_events: quali eventi esistono in questa "versione" di PZ
    moddata:          contenuto gia' presente, per simulare un riavvio
    moddata_broken:   ModData che solleva errore, per verificare la resistenza
    """
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)

    g = lua.globals()
    g.Events = lua.eval("{}")
    for name in available_events:
        g.Events[name] = g["__mkEvent"](name)

    if moddata_broken:
        lua.execute("ModData = { getOrCreate = function() error('non disponibile') end }")
    else:
        lua.execute("""
        ModData = { getOrCreate = function(k)
          __moddata[k] = __moddata[k] or {}
          return __moddata[k]
        end }
        """)
        if moddata:
            store = g["__moddata"]
            for key, values in moddata.items():
                store[key] = lua.eval("{}")
                for k, v in values.items():
                    store[key][k] = v

    with open(PROBE_PATH, encoding="utf-8") as f:
        lua.execute(f.read())

    return Probe(lua)


ALL_EVENTS = [
    "OnPlayerDeath", "LevelPerk", "OnHitZombie", "OnZombieDead",
    "OnMakeItem", "OnDoTileBuilding", "OnEnterVehicle",
    "OnPlayerAttackFinished", "OnCreatePlayer",
]
