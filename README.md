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

Il Lua **server-side** di Build 42 non ha API di rete **né** scrittura file
(`getFileWriter` è client-only: sul server dedicato restituisce `nil`). L'unico
canale disponibile è il **log del server**:

```
mod (Lua) ──print──> Logs/*DebugLog-server.txt ──POST──> sito ITAPz
                                             ↑
                                  bridge/itapz-bridge.sh (cron)
```

1. La mod stampa nel log, ogni `INTERVAL` secondi, un blocco:
   ```
   ITAPZ_SYNC_BEGIN <timestamp> players=<n>
   ITAPZ_PLAYER {"name":"...","zombies":123,...}
   ITAPZ_SYNC_END
   ```
   (una riga per giocatore, per non superare limiti di lunghezza)
2. Il **bridge** (`bridge/itapz-bridge.sh`, solo `awk`+`curl`) estrae l'ultimo
   blocco, compone il payload e lo invia a `POST {SITE_URL}/api/sync-server-data`.
   Salta l'invio se i dati non sono cambiati.

### Installare il bridge

```bash
curl -o /usr/local/bin/itapz-bridge.sh   https://raw.githubusercontent.com/giacculu/ITAPz-Sync/master/bridge/itapz-bridge.sh
chmod +x /usr/local/bin/itapz-bridge.sh
```

Cron (ogni minuto):

```cron
* * * * * ZOMBOID_DIR=/home/administrator/Zomboid SITE_URL=http://localhost:3000 /usr/local/bin/itapz-bridge.sh >> /var/log/itapz-bridge.log 2>&1
```

| Variabile | Default | Note |
|---|---|---|
| `ZOMBOID_DIR` | `/home/administrator/Zomboid` | cartella Zomboid del server |
| `SITE_URL` | `http://localhost:3000` | URL del sito ITAPz |
| `API_KEY` | (vuota) | deve combaciare con `SYNC_API_KEY` del sito |
| `LOG_FILE` | ultimo `*DebugLog-server.txt` | log da leggere |

### Configurare la mod

I file Workshop sono in sola lettura (sovrascritti agli update): **non**
modificare il Lua. Per cambiare l'intervallo crea
`<Zomboid>/Lua/ITAPz_Sync_config.txt`:

```ini
INTERVAL=60
```

Se il file manca, l'intervallo è 300s. Riavvia il server dopo modifiche.

### Payload inviato dal bridge

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
bridge/itapz-bridge.sh            # estrae i dati dal log e li invia (cron + curl)
workshop.txt                      # metadati Steam Workshop
```

## Licenza

Fan project, non affiliato con The Indie Stone. Project Zomboid è un marchio di
The Indie Stone.
