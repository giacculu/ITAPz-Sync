# ITAPz — Data Sync

Mod **server-side** per Project Zomboid **Build 42**. Raccoglie le statistiche dei
giocatori online e le passa al sito [ITAPz](https://github.com/giacculu/italian-project-zomboid)
(profili, XP, rank, classifiche, battlepass).

- **Non modifica il gameplay**, nessun effetto lato client.
- Steam Workshop: **`3774019032`**
- Struttura Build 42 (`42/` + `common/`), `mod.info`/`workshop.txt` in CRLF.

## Installazione (server)

1. Iscrivi il server alla mod:
   ```ini
   ; Zomboid/Server/<nome>.ini
   WorkshopItems=3774019032
   Mods=ITAPz_Sync
   ```
2. Configura (vedi sotto) e riavvia.

Per caricare/aggiornare la mod sul Workshop vedi [WORKSHOP-UPLOAD.md](WORKSHOP-UPLOAD.md).

## Come funziona (importante)

Il Lua di **Build 42 non ha alcuna API di rete** (nessun socket, nessun accesso
Java arbitrario): una mod **non può** fare una HTTP POST. Quindi:

```
mod (Lua) ──scrive──> Zomboid/Lua/itapz_sync_data.json  ──POST──>  sito ITAPz
                                                   ↑
                                          bridge/itapz-bridge.sh (cron)
```

1. La mod scrive il JSON in `<Zomboid>/Lua/itapz_sync_data.json` ogni `INTERVAL` secondi (getFileWriter lavora nella sottocartella `Lua/`).
2. Il **bridge** (`bridge/itapz-bridge.sh`, solo `curl`) lo invia a
   `POST {SITE_URL}/api/sync-server-data`. Salta l'invio se il file non è cambiato.

### Configurare il bridge (cron, ogni minuto)

```cron
* * * * * ZOMBOID_DIR=/home/administrator/Zomboid SITE_URL=http://localhost:3000 API_KEY= /path/itapz-bridge.sh >> /var/log/itapz-bridge.log 2>&1
```

| Variabile | Default | Note |
|---|---|---|
| `ZOMBOID_DIR` | `/home/administrator/Zomboid` | cartella Zomboid del server |
| `SITE_URL` | `http://localhost:3000` | URL del sito ITAPz |
| `API_KEY` | (vuota) | deve combaciare con `SYNC_API_KEY` del sito |

### Configurare la mod

I file Workshop sono in sola lettura (sovrascritti agli update): **non**
modificare il Lua. Per cambiare l'intervallo crea, nella cartella Zomboid del
server, `Lua/ITAPz_Sync_config.txt`:

```ini
INTERVAL=60
```

Se il file manca, l'intervallo è 300s. Riavvia il server dopo modifiche.

### Formato del JSON

```json
{
  "players": [
    {
      "name": "Marco_Z",
      "occupation": "police",
      "trait": "Coraggioso, Forte",
      "kills": 0,
      "zombies": 1240,
      "daysSurvived": 45,
      "hoursSurvived": 128,
      "distanceWalked": 0,
      "treesChopped": 80,
      "bulletsFired": 5000,
      "panicAttacks": 12,
      "weight": 82.5,
      "recipesKnown": 63,
      "infected": false,
      "skills": [
        { "name": "Fitness", "level": 6, "maxLevel": 10 },
        { "name": "Axe", "level": 4, "maxLevel": 10 }
      ]
    }
  ],
  "timestamp": "2026-07-29T20:00:00Z"
}
```

### Campi

Fonti verificate sull'API **Build 42** (Lua del gioco / JavaDocs):

| Campo | Fonte PZ (B42) | Note |
|-------|----------------|------|
| `name` | `getUsername()` | chiave per legare al profilo del sito |
| `occupation` | `getDescriptor():getCharacterProfession()` | professione |
| `trait` | `getCharacterTraits()` | csv |
| `zombies` | `getZombieKills()` | zombie uccisi |
| `hoursSurvived` | `getHoursSurvived()` | ore giocate |
| `daysSurvived` | derivato: `hoursSurvived / 24` | `getSurviveDays()` non esiste in B42 |
| `treesChopped` | `getStats():getTreesChopped()` | alberi tagliati |
| `bulletsFired` | `getStats():getBulletsFired()` | colpi sparati |
| `panicAttacks` | `getStats():getPanicAttacks()` | attacchi di panico |
| `weight` | `getNutrition():getWeight()` | peso (kg) |
| `recipesKnown` | `getKnownRecipes():size()` | ricette imparate |
| `infected` | `getBodyDamage():isInfected()` | infetto dal virus Knox |
| `skills[]` | `PerkFactory.PerkList` + `getPerkLevel(perk)` | skill attive: `name`, `level`, `maxLevel` |
| `kills` | — | sempre `0`: B42 non espone i player uccisi |
| `distanceWalked` | — | sempre `0`: B42 non espone la distanza percorsa |

Tutti i getter sono `pcall`-protetti: se un metodo non esiste in una versione
di B42, il campo resta al default e il sync non si blocca.

## Privacy

Invia solo dati di gioco e lo username Steam pubblico. Nessuna password, nessun
dato personale.

## Struttura

```
ITAPz_Sync/
├── mod.info, poster.png          # root
├── common/                       # vuota (richiesta da B42)
└── 42/
    ├── mod.info, poster.png
    └── media/lua/server/ITAPz_DataSync.lua
bridge/itapz-bridge.sh            # invia il JSON al sito (cron + curl)
workshop.txt                      # metadati Steam Workshop
```

## Licenza

Fan project, non affiliato con The Indie Stone. Project Zomboid è un marchio di
The Indie Stone.
