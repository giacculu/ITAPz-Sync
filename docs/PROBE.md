# Sonda hook — come leggere l'esito

La sonda stampa nel log del server. Si legge da **Admin → Console Server**,
riquadro "Console del server (live)", oppure sulla VPS:

    grep ITAPZ_PROBE /home/administrator/Zomboid/server-console.txt | tail -40

## Cosa cercare

| riga | significato |
|---|---|
| `ITAPZ_PROBE_HOOK <nome> registrato` | l'evento esiste in questa build |
| `ITAPZ_PROBE_HOOK <nome> ASSENTE` | l'evento non esiste: inutilizzabile |
| `ITAPZ_PROBE_FIRST <nome> <ora>` | l'evento ha **davvero** sparato sul server dedicato |
| `ITAPZ_PROBE_REPORT ...` | conteggi complessivi per ogni evento |
| `ITAPZ_PROBE_MODDATA avvii=N stato=ok` | il ModData globale funziona |

**"registrato" non basta.** Contano solo gli eventi che compaiono in una riga
`ITAPZ_PROBE_FIRST`: sono gli unici su cui si possono costruire achievement.

## Prova da fare

1. Entrare nel server e uccidere qualche zombie → attendersi `OnHitZombie` e
   `OnZombieDead`.
2. Fabbricare un oggetto → `OnMakeItem`.
3. Costruire un muro → `OnDoTileBuilding`.
4. Salire di livello in un'abilità → `LevelPerk`.
5. Entrare in un veicolo → `OnEnterVehicle`.
6. Morire → `OnPlayerDeath`.

## Verifica del ModData

1. Annotare il numero in `avvii=` alla prima accensione.
2. Riavviare il server da **Admin → Console Server → Riavvia**.
3. Rileggere la riga: se `avvii=` è aumentato di uno, il ModData persiste e i
   contatori degli achievement possono viverci. Se resta a 1, la persistenza
   non funziona e i contatori vanno tenuti altrove.

## Dopo

Riportare l'elenco degli eventi con una riga `ITAPZ_PROBE_FIRST` e l'esito del
ModData: decidono quali achievement di tipo evento sono realizzabili.
La sonda va rimossa quando la fase 3 è completata.
