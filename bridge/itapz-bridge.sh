#!/bin/sh
# ITAPz bridge — invia al sito i dati che la mod stampa nel log del server.
#
# Il Lua server-side di Build 42 non ha ne' rete ne' scrittura file: la mod
# stampa i dati nel log fra marcatori e questo script li estrae e fa la POST.
#
# Due canali diversi nello stesso log:
#   - le FOTOGRAFIE di stato (blocco ITAPZ_SYNC_BEGIN..END): conta solo l'ultima
#   - gli EVENTI (righe ITAPZ_EVENT): contano TUTTI, perche' un'uccisione o una
#     morte non lasciano traccia nello stato del ciclo dopo
#
# Per non perdere eventi lo script ricorda file + posizione gia' letta e
# rilegge solo il nuovo. Alla primissima esecuzione parte dalla fine: senza
# quella regola riverserebbe mesi di storico in una volta.
#
# Due modi di lanciarlo:
#
#   --loop   resta acceso e ricontrolla ogni POLL_SECONDS (consigliato, come
#            servizio systemd: vedi bridge/systemd/itapz-bridge.service)
#   senza    fa un giro solo ed esce (da cron)
#
# Il ciclo esiste perche' da cron il minimo e' un minuto: un'uccisione poteva
# restare ferma nel log fino a sessanta secondi prima di arrivare al sito, e
# con lei l'achievement e l'annuncio su Discord. Non e' una consegna spinta —
# il log resta l'unico canale che la mod ha — ma due secondi al posto di
# sessanta si notano.
#
#   ZOMBOID_DIR=/home/administrator/Zomboid SITE_URL=http://localhost:3000 \
#     API_KEY=xxx /usr/local/bin/itapz-bridge.sh --loop
#
# Variabili:
#   ZOMBOID_DIR   cartella Zomboid del server (default /home/administrator/Zomboid)
#   SITE_URL      URL del sito ITAPz          (default http://localhost:3000)
#   API_KEY       deve combaciare con SYNC_API_KEY del sito (obbligatoria)
#   LOG_FILE      log da leggere (default: il DebugLog-server piu' recente)
#   POLL_SECONDS  attesa fra un giro e l'altro in --loop (default 2)

set -eu

ZOMBOID_DIR="${ZOMBOID_DIR:-/home/administrator/Zomboid}"
SITE_URL="${SITE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-}"
POLL_SECONDS="${POLL_SECONDS:-2}"

# Il log da leggere si ricalcola a ogni giro: quando il server riparte ne apre
# uno nuovo, e restando appesi al vecchio non arriverebbe piu' niente.
LOG_FILE_FISSO="${LOG_FILE:-}"

giro() {

STATE_FILE="$ZOMBOID_DIR/.itapz_bridge_last"
MARK_FILE="$ZOMBOID_DIR/.itapz_bridge_mark"
# I file di lavoro stanno in una cartella che porta dentro l'utente. Con un
# nome fisso in /tmp bastava che lo script fosse girato una volta da root —
# come faceva da cron — perche' poi, da servizio con un altro utente, non
# potesse piu' sovrascriverli: "Permission denied" e riavvio in ciclo.
TMP_DIR="${TMPDIR:-/tmp}/itapz-bridge-$(id -u)"
mkdir -p "$TMP_DIR"
TMP_PAYLOAD="$TMP_DIR/payload.json"
TMP_NEW="$TMP_DIR/new.txt"
TMP_RESP="$TMP_DIR/risposta.txt"

  # Log piu' recente, se non indicato esplicitamente
  LOG_FILE="$LOG_FILE_FISSO"
  if [ -z "$LOG_FILE" ]; then
    LOG_FILE=$(ls -1t "$ZOMBOID_DIR"/Logs/*DebugLog-server.txt 2>/dev/null | head -n1 || true)
  fi

  if [ -z "${LOG_FILE:-}" ] || [ ! -f "$LOG_FILE" ]; then
    echo "$(date '+%F %T') nessun DebugLog-server in $ZOMBOID_DIR/Logs/"
    return 0
  fi

  SIZE=$(wc -c < "$LOG_FILE" | tr -d ' ')

  # --- segnalibro: da dove riprendere la lettura ------------------------------
  OFFSET=0
  if [ -f "$MARK_FILE" ]; then
    PREV_FILE=$(sed -n '1p' "$MARK_FILE" 2>/dev/null || true)
    PREV_OFF=$(sed -n '2p' "$MARK_FILE" 2>/dev/null || echo 0)
    case "$PREV_OFF" in ''|*[!0-9]*) PREV_OFF=0 ;; esac

    if [ "$PREV_FILE" = "$LOG_FILE" ] && [ "$PREV_OFF" -le "$SIZE" ]; then
      OFFSET="$PREV_OFF"
    else
      # log ruotato (riavvio del server) o troncato: si riparte dall'inizio del
      # file nuovo, non dalla posizione vecchia che punterebbe a meta' riga
      OFFSET=0
    fi
  else
    # prima esecuzione: parte dalla fine, altrimenti riverserebbe tutto lo storico
    OFFSET="$SIZE"
  fi

  tail -c "+$((OFFSET + 1))" "$LOG_FILE" > "$TMP_NEW" 2>/dev/null || : > "$TMP_NEW"

  # L'ultima riga puo' essere tronca (il server stava scrivendo): si scarta e il
  # segnalibro si ferma prima, cosi' al giro dopo viene riletta intera.
  NEW_BYTES=$(wc -c < "$TMP_NEW" | tr -d ' ')
  if [ "$NEW_BYTES" -gt 0 ] && [ "$(tail -c 1 "$TMP_NEW" | od -An -c | tr -d ' ')" != "\n" ]; then
    LAST_LEN=$(tail -n 1 "$TMP_NEW" | wc -c | tr -d ' ')
    NEW_BYTES=$((NEW_BYTES - LAST_LEN))
    [ "$NEW_BYTES" -lt 0 ] && NEW_BYTES=0
    head -c "$NEW_BYTES" "$TMP_NEW" > "$TMP_NEW.cut" && mv "$TMP_NEW.cut" "$TMP_NEW"
  fi

  # --- eventi: tutte le righe nuove -------------------------------------------
  EVENTS=$(grep 'ITAPZ_EVENT' "$TMP_NEW" 2>/dev/null | sed 's/^.*ITAPZ_EVENT //' | sed 's/[[:space:]]*$//' | sed 's/\.$//' | paste -sd, - || true)

  # --- fotografia: l'ultimo blocco completo del log intero ---------------------
  BLOCK=$(awk '/ITAPZ_SYNC_BEGIN/{buf=""; inb=1} inb{buf=buf $0 "\n"} /ITAPZ_SYNC_END/{if(inb){last=buf; inb=0}} END{printf "%s", last}' "$LOG_FILE")

  if [ -z "$BLOCK" ] && [ -z "$EVENTS" ]; then
    echo "$(date '+%F %T') niente di nuovo (la mod non ha ancora emesso dati)"
    printf '%s\n%s\n' "$LOG_FILE" "$((OFFSET + NEW_BYTES))" > "$MARK_FILE"
    return 0
  fi

  PLAYERS=$(printf '%s' "$BLOCK" | grep 'ITAPZ_PLAYER' | sed 's/^.*ITAPZ_PLAYER //' | sed 's/[[:space:]]*$//' | sed 's/\.$//' | paste -sd, - || true)
  STAMP=$(printf '%s' "$BLOCK" | grep -m1 'ITAPZ_SYNC_BEGIN' | sed 's/^.*ITAPZ_SYNC_BEGIN //' | awk '{print $1}' || true)

  # --- identita': username <-> Steam ID dai log di connessione ------------------
  # Il Lua di B42 non espone lo Steam ID dei giocatori, ma il server lo scrive
  # qui insieme all'username. E' l'unico modo per collegare personaggio e account
  # in modo esatto invece di confrontare i nomi.
  #
  # Le righe di handshake hanno steam-id="0" e username="null": si tengono solo
  # quelle con uno Steam ID vero (iniziano tutti per 7656) e un nome reale.
  #
  # Gli account di servizio NON si filtrano qui: il nome da escludere si imposta
  # dal pannello, e uno scritto nel codice escluderebbe anche nomi legittimi che
  # lo contengono per caso. Il controllo lo fa il sito, che quel valore ce l'ha.
  #
  # Il file e' piccolo (qualche KB) e le coppie sono le stesse a ogni giro,
  # quindi si rilegge intero: il sito le riscrive sopra, l'operazione e' idempotente.
  CONN_FILE=$(ls -1t "$ZOMBOID_DIR"/Logs/*_connections.txt 2>/dev/null | head -n1 || true)
  IDENTITIES=""
  if [ -n "${CONN_FILE:-}" ] && [ -f "$CONN_FILE" ]; then
    IDENTITIES=$(grep -ohE 'steam-id="7656[0-9]{13}" role="[^"]*" username="[^"]+"' "$CONN_FILE" 2>/dev/null \
      | sed -E 's/steam-id="([0-9]+)" role="[^"]*" username="([^"]+)"/{"u":"\2","s":"\1"}/' \
      | grep -v '"u":"null"' | sort -u | paste -sd, - || true)
  fi

  extract_json() {
    printf '%s' "$BLOCK" | grep -m1 "$1" | sed "s/^.*$1 //" | sed 's/[[:space:]]*$//' | sed 's/\.$//'
  }
  WORLD=$(extract_json 'ITAPZ_WORLD' || true)
  SANDBOX=$(extract_json 'ITAPZ_SANDBOX' || true)
  FACTIONS=$(extract_json 'ITAPZ_FACTIONS' || true)
  [ -n "$WORLD" ] || WORLD="null"
  [ -n "$SANDBOX" ] || SANDBOX="null"
  [ -n "$FACTIONS" ] || FACTIONS="null"

  printf '{"players":[%s],"events":[%s],"world":%s,"sandbox":%s,"factions":%s,"identities":[%s],"timestamp":"%s"}' \
    "$PLAYERS" "$EVENTS" "$WORLD" "$SANDBOX" "$FACTIONS" "$IDENTITIES" "$STAMP" > "$TMP_PAYLOAD"

  # L'anti-duplicato vale solo quando NON ci sono eventi: due invii identici di
  # sola fotografia non servono, ma gli eventi vanno mandati comunque perche'
  # ognuno e' nuovo per definizione.
  if [ -z "$EVENTS" ]; then
    CURRENT_HASH=$(md5sum "$TMP_PAYLOAD" | cut -d' ' -f1)
    if [ -f "$STATE_FILE" ] && [ "$CURRENT_HASH" = "$(cat "$STATE_FILE")" ]; then
      printf '%s\n%s\n' "$LOG_FILE" "$((OFFSET + NEW_BYTES))" > "$MARK_FILE"
      return 0
    fi
  else
    CURRENT_HASH=""
  fi

  if [ -n "$API_KEY" ]; then
    HTTP_CODE=$(curl -sS -o "$TMP_RESP" -w '%{http_code}' \
      -X POST "$SITE_URL/api/sync-server-data" \
      -H 'Content-Type: application/json' \
      -H "X-API-Key: $API_KEY" \
      --data-binary "@$TMP_PAYLOAD" --max-time 20) || HTTP_CODE=000
  else
    HTTP_CODE=$(curl -sS -o "$TMP_RESP" -w '%{http_code}' \
      -X POST "$SITE_URL/api/sync-server-data" \
      -H 'Content-Type: application/json' \
      --data-binary "@$TMP_PAYLOAD" --max-time 20) || HTTP_CODE=000
  fi

  if [ "$HTTP_CODE" = "200" ]; then
    [ -n "$CURRENT_HASH" ] && echo "$CURRENT_HASH" > "$STATE_FILE"
    # Il segnalibro avanza SOLO dopo un invio riuscito: se la POST fallisce, al
    # giro dopo le stesse righe vengono rilette e nessun evento va perso.
    printf '%s\n%s\n' "$LOG_FILE" "$((OFFSET + NEW_BYTES))" > "$MARK_FILE"
    echo "$(date '+%F %T') OK $(cat "$TMP_RESP")"
  else
    echo "$(date '+%F %T') FALLITO http=$HTTP_CODE $(cat "$TMP_RESP" 2>/dev/null)"
    return 1
  fi
}

# --- avvio ------------------------------------------------------------------
if [ "${1:-}" = "--loop" ]; then
  echo "$(date '+%F %T') bridge in ascolto: un giro ogni ${POLL_SECONDS}s"
  while true; do
    # Un giro che fallisce non deve spegnere il servizio: il log potrebbe
    # essere in rotazione, o il sito momentaneamente giu'.
    giro || echo "$(date '+%F %T') giro fallito, si riprova"
    sleep "$POLL_SECONDS"
  done
else
  giro
fi
