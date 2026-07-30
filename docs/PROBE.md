# Sonda hook — come leggere l'esito

La sonda stampa nel log del server. Si legge da **Admin → Console Server**,
riquadro "Console del server (live)", oppure sulla VPS:

    grep ITAPZ_PROBE /home/administrator/Zomboid/server-console.txt | grep -v ITAPZ_PROBE_REPORT

Le righe `HOOK` e `FIRST` si stampano solo all'avvio e al primo scatto; le
`REPORT` si accumulano per tutta la sessione. Dopo mezz'ora di gioco un
semplice `tail` mostrerebbe solo `REPORT` e le prove che contano sarebbero
fuori vista: per questo vanno escluse esplicitamente.

## Cosa cercare

| riga | significato |
|---|---|
| `ITAPZ_PROBE avvio <ora>` | il file e' stato caricato dal LuaManager. Va letta **prima** di concludere che un hook non ha sparato: se manca anche questa, il problema e' che la mod non e' caricata, non che l'evento non scatti |
| `ITAPZ_PROBE_HOOK <nome> registrato` | l'evento esiste in questa build |
| `ITAPZ_PROBE_HOOK <nome> ASSENTE` | l'evento non esiste: inutilizzabile |
| `ITAPZ_PROBE_FIRST <nome> <ora> args=...` | l'evento ha **davvero** sparato sul server dedicato, con i primi argomenti ricevuti dalla callback |
| `ITAPZ_PROBE_REPORT ...` | conteggi complessivi per ogni evento |
| `ITAPZ_PROBE_MODDATA fase=load avvii=N ... stato=ok` | lettura fatta al bootstrap del LuaManager, prima che il salvataggio sia deserializzato: e' normale che resti sempre `avvii=1` |
| `ITAPZ_PROBE_MODDATA fase=init avvii=N ... stato=ok` | lettura fatta dopo `OnInitGlobalModData` (o `OnServerStarted`): questa e' la lettura affidabile sulla persistenza |
| `ITAPZ_PROBE_MODDATA fase=... stato=non-disponibile` | ModData non disponibile su questo server: i contatori vanno tenuti altrove |

**"registrato" non basta.** Contano solo gli eventi che compaiono in una riga
`ITAPZ_PROBE_FIRST`: sono gli unici su cui si possono costruire achievement.

**`EveryTenMinutes` è il controllo positivo.** È già dimostrato funzionante in
produzione da `ITAPz_DataSync.lua`, quindi se anche lui non compare fra le
righe `FIRST` il problema è la sonda che non osserva quello che crede — non
gli hook candidati. In quel caso non fidarsi di nessun risultato negativo
riportato dagli altri eventi finché la sonda stessa non viene corretta.

## Risultati del secondo giro (30/07/2026) — conclusivi

Provato tutto: uccisioni, costruzione, morte, creazione personaggio, livelli,
veicoli, esplorazione.

### Utilizzabili per gli achievement (portano il giocatore)

| evento | argomenti | serve per |
|---|---|---|
| `OnWeaponHitCharacter` | `player:<nome>`, bersaglio, **arma** | uccisioni con un'arma specifica — il migliore del gruppo |
| `AddXP` | `player:<nome>`, abilità, quantità | ogni guadagno di esperienza |
| `LevelPerk` | `player:<nome>`, abilità, livello | salita di livello in un'abilità |
| `OnHitZombie` | zombie, `player:<nome>`, arma | colpi inferti |
| `OnCreateLivingCharacter` | `player:<nome>` | creazione personaggio |

### Scattano ma senza dire a chi attribuirli

`OnZombieDead`, `OnCharacterDeath`, `OnDestroyIsoThumpable`, `OnSeeNewRoom`,
`OnPlayerGetDamage`.

`OnCharacterDeath` scatta sia per gli zombie sia per i giocatori: la riga
`ITAPZ_PROBE_PLAYER` serve proprio a catturare il caso del giocatore, che la
riga `FIRST` si perde quando il primo a morire è uno zombie.

### Non scattano mai

`OnPlayerDeath` (usare `OnCharacterDeath`), `OnCreatePlayer` (usare
`OnCreateLivingCharacter`), `OnDoTileBuilding2`, `OnDoTileBuilding3`,
`OnObjectAdded`, `OnWeaponHitTree`, `OnPlayerAttackFinished`, `OnUseVehicle`,
`OnMechanicActionDone`, `OnItemFound`, `OnNewFire`.

### Non esistono in Build 42

`OnExitVehicle`, `OnSwitchVehicleSeat` (riportati `ASSENTE`).

### Conseguenze per il progetto

- **Costruzione: nessun evento utilizzabile.** Né `OnDoTileBuilding2/3` né
  `OnObjectAdded` scattano, e nell'elenco completo dei 227 eventi correnti non
  ce n'è altri. Gli achievement "costruisci N muri" non si possono fare.
- **Crafting: nessun evento, punto.** Build 42 non ne espone. Si può ripiegare
  sulle ricette conosciute, che sono già nelle statistiche sincronizzate.
- **Veicoli: nessun evento utilizzabile.**
- **Esplorazione:** `OnSeeNewRoom` scatta ma non dice chi, quindi resta da fare
  con le coordinate nel sync, come previsto dal design originale.
- **Il ModData persiste** (`avvii=4` dopo tre riavvii), ma solo per le
  scritture fatte dopo `OnInitGlobalModData`.

## Risultati del primo giro (30/07/2026)

| evento | esito | note |
|---|---|---|
| `EveryTenMinutes` | **scatta** | controllo positivo: i risultati negativi sotto sono affidabili |
| `OnHitZombie` | **scatta** | `args=userdata,player:<nome>,userdata` — porta il giocatore |
| `OnZombieDead` | **scatta** | solo lo zombie, nessuna attribuzione al giocatore |
| `OnEnterVehicle` | non scatta | rimosso dai candidati |
| `OnMakeItem` | non scatta | **non esiste più in B42**: assente dall'elenco eventi di pzwiki, e il gioco stesso lo tiene commentato in `XpSystem/XpUpdate.lua` |
| `OnDoTileBuilding` | non scatta | **nome deprecato**: B42 usa `OnDoTileBuilding2` e `OnDoTileBuilding3` |

Il ModData globale **persiste** attraverso i riavvii, ma solo per le scritture
fatte dopo `OnInitGlobalModData`: quelle fatte al caricamento del file vengono
scartate quando PZ deserializza il salvataggio.

Conseguenza per gli achievement: `OnHitZombie` è l'unico evento di combattimento
che dice **chi** ha colpito, quindi è quello su cui costruire. E **Build 42 non
espone alcun evento di crafting**, quindi "fabbrica N oggetti" non si può fare a
eventi.

## Prova da fare (secondo giro)

I candidati sono stati sostituiti con i nomi corretti presi dall'elenco
"Current Lua events" di pzwiki. Da provare:

1. **Uccidere zombie** → `OnWeaponHitCharacter`, `OnPlayerAttackFinished`,
   `OnPlayerGetDamage` (farsi colpire).
2. **Costruire un muro o un tavolo** → `OnDoTileBuilding2`,
   `OnDoTileBuilding3`, `OnObjectAdded`.
3. **Distruggere una costruzione** → `OnDestroyIsoThumpable`.
4. **Tagliare un albero** → `OnWeaponHitTree`.
5. **Salire di livello in un'abilità** → `LevelPerk`, `AddXP` (quest'ultimo
   dovrebbe scattare a ogni guadagno di esperienza, non solo al livello).
6. **Guidare un veicolo**, uscirne, cambiare posto, riparare →
   `OnExitVehicle`, `OnUseVehicle`, `OnSwitchVehicleSeat`,
   `OnMechanicActionDone`.
7. **Entrare in una stanza mai vista** → `OnSeeNewRoom` (serve per gli
   achievement di esplorazione).
8. **Raccogliere/foraggiare** → `OnItemFound`.
9. **Accendere un fuoco** → `OnNewFire`.
10. **Morire** → `OnPlayerDeath`, `OnCharacterDeath`.
11. **Creare un personaggio nuovo** → `OnCreatePlayer`,
    `OnCreateLivingCharacter`.

Per ognuno conta soprattutto la parte `args=`: se non contiene
`player:<nome>`, l'evento non basta da solo per un achievement, perché non
dice a chi attribuirlo.

## Verifica del ModData

1. Annotare il numero in `avvii=` della riga `fase=init` alla prima
   accensione (la riga `fase=load` va ignorata: legge sempre prima che il
   salvataggio sia deserializzato, quindi resta a `avvii=1` anche quando la
   persistenza funziona — è tardiva, non rotta).
2. Riavviare il server da **Admin → Console Server → Riavvia**.
3. Rileggere la riga `fase=init`: se `avvii=` è aumentato di uno, il ModData
   persiste e i contatori degli achievement possono viverci. Se `fase=load`
   resta a `avvii=1` ma `fase=init` cresce a ogni riavvio, il ModData
   persiste comunque: è solo tardivo al caricamento, non rotto. Se anche
   `fase=init` resta a 1, la persistenza non funziona e i contatori vanno
   tenuti altrove.
4. Se il ModData risulta non persistente, controllare prima
   `journalctl -u itapz-agent`: il riavvio dal pannello admin salta il
   salvataggio se `RCON_PASSWORD` non è impostata, il che farebbe sembrare
   il ModData non persistente quando in realtà non è mai stato salvato.

## Dopo

Riportare l'elenco degli eventi con una riga `ITAPZ_PROBE_FIRST` e l'esito del
ModData: decidono quali achievement di tipo evento sono realizzabili.
La sonda va rimossa quando la fase 3 è completata.
