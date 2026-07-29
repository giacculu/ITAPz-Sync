# Caricare la mod ITAPz_Sync sullo Steam Workshop

La mod è pronta. Il caricamento si fa dal **client Project Zomboid** (Build 42),
non da riga di comando: PZ ha un uploader Workshop integrato.

## 1. Prepara la cartella Workshop

Crea questa struttura dentro la cartella dati di Zomboid del tuo PC
(`C:\Users\<Utente>\Zomboid\Workshop\`):

```
Zomboid/Workshop/ITAPz_Sync/
├── workshop.txt                      ← da mod/workshop.txt
├── preview.png                       ← anteprima (copia di mod/ITAPz_Sync/poster.png)
└── Contents/
    └── mods/
        └── ITAPz_Sync/
            ├── mod.info                     (root)
            ├── poster.png                   (root)
            ├── common/                      ← CARTELLA VUOTA (obbligatoria in B42)
            └── 42/                          ← contenuto specifico Build 42
                ├── mod.info
                ├── poster.png
                └── media/lua/server/ITAPz_DataSync.lua
```

> **Build 42**: la nuova gerarchia `42/` + `common/` (vuota) è **obbligatoria** —
> senza, l'uploader dà "manca il file mod.info" (fallisce anche il ModTemplate
> vanilla flat). `common/` va lasciata **completamente vuota**; `media/`,
> `mod.info`, `poster.png` vanno dentro `42/` (con copia di mod.info/poster
> anche nella root del mod).

In pratica: copia l'intera cartella `mod/ITAPz_Sync/` di questo repo (ha già la
struttura B42) dentro `Contents/mods/`, e assicurati che `common/` resti vuota
(nel repo contiene solo un `.gitkeep` segnaposto — cancellalo nella copia).

## 2. Carica da dentro il gioco

1. Avvia **Project Zomboid** (Build 42).
2. Main Menu → **Workshop** → **Create and Upload a mod / Modifica**.
3. Seleziona **ITAPz_Sync** dalla lista (legge da `Zomboid/Workshop/`).
4. Controlla titolo, descrizione, anteprima, tag → **Upload**.
5. Accetta i termini Steam Workshop. Al primo upload Steam assegna un **ID**;
   viene scritto in automatico nel tuo `workshop.txt` locale.

> L'upload richiede di essere loggati su Steam con l'account che possiede PZ.
> La prima pubblicazione conviene lasciarla su **visibility=public** o
> `friends`/`private` finché non la testi.

## 3. Dopo l'upload

- Prendi l'**ID Workshop** (numero) e il **Mod ID** (`ITAPz_Sync`).
- Nel `servertest.ini` del server:
  ```
  WorkshopItems=<ID_WORKSHOP>
  Mods=ITAPz_Sync
  ```
- Configura le opzioni mod (URL sito, API key, intervallo) come da SETUP.md.

## Note

- `poster.png` deve essere una **vera immagine PNG** (ora usa il logo del server).
- La struttura `media/lua/server/` è corretta per una mod **server-side** B42.
- Se aggiorni la mod, rialza `version=` in `mod.info` e ri-carica dallo stesso
  uploader (mantiene lo stesso ID Workshop).
