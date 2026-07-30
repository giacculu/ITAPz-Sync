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

## Prova da fare

1. Entrare nel server e uccidere qualche zombie → attendersi `OnHitZombie` e
   `OnZombieDead`.
2. Fabbricare un oggetto → `OnMakeItem`.
3. Costruire un muro → `OnDoTileBuilding`.
4. Salire di livello in un'abilità → `LevelPerk`.
5. Entrare in un veicolo → `OnEnterVehicle`.
6. Morire → `OnPlayerDeath`.
7. Creare un personaggio nuovo (primo accesso, oppure dopo la morte) →
   `OnCreatePlayer`.
8. Colpire uno zombie senza ucciderlo → `OnPlayerAttackFinished`
   (probabilmente già coperto dal punto sulle uccisioni, ma va reso
   esplicito perché l'esito vada tracciato).

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
