# ITAPz — Data Sync

Mod **server-side** per Project Zomboid **Build 42**. Raccoglie le statistiche dei
giocatori online e le invia via HTTP al sito [ITAPz](https://github.com/giacculu/italian-project-zomboid)
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

## Configurazione

La mod è pubblica e i file Workshop sono in sola lettura (sovrascritti agli
update): **non** modificare il Lua. Ogni server imposta i propri valori creando
un file di testo nella cartella Zomboid del server:

```
C:\Users\<Utente>\Zomboid\ITAPz_Sync_config.txt   (Windows)
~/Zomboid/ITAPz_Sync_config.txt                    (Linux)
```

```ini
SITE_URL=https://iltuosito.it   # default: http://localhost:3000
API_KEY=la_tua_chiave           # deve combaciare con SYNC_API_KEY del sito
INTERVAL=300                    # secondi tra un invio (default 5 min)
```

Se il file manca si usano i default. Riavvia il server dopo modifiche.

## Come invia i dati

Ogni `INTERVAL` secondi, per ogni giocatore online, esegue una **HTTP POST**:

- **URL**: `{SITE_URL}/api/sync-server-data`
- **Metodo**: `POST`
- **Header**: `Content-Type: application/json; charset=UTF-8`, `X-API-Key: {API_KEY}`
- **Fallback**: se la POST fallisce, scrive `itapz_sync_data.json` nella
  directory del server (per un eventuale bridge esterno, vedi `reporter-bridge/`).

### Body

```json
{
  "players": [
    {
      "name": "Marco_Z",
      "occupation": "Poliziotto",
      "trait": "Coraggioso, Forte",
      "kills": 0,
      "zombies": 1240,
      "daysSurvived": 45,
      "hoursSurvived": 128,
      "distanceWalked": 120000,
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

| Campo | Fonte PZ | Note |
|-------|----------|------|
| `name` | `getUsername()` | chiave per legare al profilo del sito |
| `occupation` | `getProfession()` | professione |
| `trait` | tratti del personaggio | csv |
| `zombies` | `getZombieKills()` | zombie uccisi |
| `kills` | `getKills()` | player uccisi (0 in B42, NPC assenti) |
| `daysSurvived` | `getSurviveDays()` | giorni sopravvissuti |
| `hoursSurvived` | `getHoursSurvived()` | ore giocate |
| `distanceWalked` | `getTotalDistanceWalked()` | metri |
| `treesChopped` | `getStats():getTreesChopped()` | alberi tagliati |
| `bulletsFired` | `getStats():getBulletsFired()` | colpi sparati |
| `panicAttacks` | `getStats():getPanicAttacks()` | attacchi di panico |
| `weight` | `getNutrition():getWeight()` | peso (kg) |
| `recipesKnown` | `getKnownRecipes():size()` | ricette imparate |
| `infected` | `getBodyDamage():isInfected()` | infetto dal virus Knox |
| `skills[]` | 26 perk | `name`, `level`, `maxLevel` |

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
reporter-bridge/                  # bridge Python opzionale (fallback file → sito)
workshop.txt                      # metadati Steam Workshop
```

## Licenza

Fan project, non affiliato con The Indie Stone. Project Zomboid è un marchio di
The Indie Stone.
