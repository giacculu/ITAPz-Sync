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
# Uso (cron, ogni minuto):
#   * * * * * ZOMBOID_DIR=/home/administrator/Zomboid SITE_URL=http://localhost:3000 /usr/local/bin/itapz-bridge.sh >> /var/log/itapz-bridge.log 2>&1
#
# Variabili:
#   ZOMBOID_DIR  cartella Zomboid del server (default /home/administrator/Zomboid)
#   SITE_URL     URL del sito ITAPz          (default http://localhost:3000)
#   API_KEY      deve combaciare con SYNC_API_KEY del sito (obbligatoria)
#   LOG_FILE     log da leggere (default: il DebugLog-server piu' recente)

set -eu

ZOMBOID_DIR="${ZOMBOID_DIR:-/home/administrator/Zomboid}"
SITE_URL="${SITE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-}"

STATE_FILE="$ZOMBOID_DIR/.itapz_bridge_last"
MARK_FILE="$ZOMBOID_DIR/.itapz_bridge_mark"
TMP_PAYLOAD="/tmp/itapz_payload.json"
TMP_NEW="/tmp/itapz_new.txt"

# Log piu' recente, se non indicato esplicitamente
if [ -z "${LOG_FILE:-}" ]; then
  LOG_FILE=$(ls -1t "$ZOMBOID_DIR"/Logs/*DebugLog-server.txt 2>/dev/null | head -n1 || true)
fi

if [ -z "${LOG_FILE:-}" ] || [ ! -f "$LOG_FILE" ]; then
  echo "$(date '+%F %T') nessun DebugLog-server in $ZOMBOID_DIR/Logs/"
  exit 0
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
  exit 0
fi

PLAYERS=$(printf '%s' "$BLOCK" | grep 'ITAPZ_PLAYER' | sed 's/^.*ITAPZ_PLAYER //' | sed 's/[[:space:]]*$//' | sed 's/\.$//' | paste -sd, - || true)
STAMP=$(printf '%s' "$BLOCK" | grep -m1 'ITAPZ_SYNC_BEGIN' | sed 's/^.*ITAPZ_SYNC_BEGIN //' | awk '{print $1}' || true)

extract_json() {
  printf '%s' "$BLOCK" | grep -m1 "$1" | sed "s/^.*$1 //" | sed 's/[[:space:]]*$//' | sed 's/\.$//'
}
WORLD=$(extract_json 'ITAPZ_WORLD' || true)
SANDBOX=$(extract_json 'ITAPZ_SANDBOX' || true)
[ -n "$WORLD" ] || WORLD="null"
[ -n "$SANDBOX" ] || SANDBOX="null"

printf '{"players":[%s],"events":[%s],"world":%s,"sandbox":%s,"timestamp":"%s"}' \
  "$PLAYERS" "$EVENTS" "$WORLD" "$SANDBOX" "$STAMP" > "$TMP_PAYLOAD"

# L'anti-duplicato vale solo quando NON ci sono eventi: due invii identici di
# sola fotografia non servono, ma gli eventi vanno mandati comunque perche'
# ognuno e' nuovo per definizione.
if [ -z "$EVENTS" ]; then
  CURRENT_HASH=$(md5sum "$TMP_PAYLOAD" | cut -d' ' -f1)
  if [ -f "$STATE_FILE" ] && [ "$CURRENT_HASH" = "$(cat "$STATE_FILE")" ]; then
    printf '%s\n%s\n' "$LOG_FILE" "$((OFFSET + NEW_BYTES))" > "$MARK_FILE"
    exit 0
  fi
else
  CURRENT_HASH=""
fi

if [ -n "$API_KEY" ]; then
  HTTP_CODE=$(curl -sS -o /tmp/itapz_bridge_resp -w '%{http_code}' \
    -X POST "$SITE_URL/api/sync-server-data" \
    -H 'Content-Type: application/json' \
    -H "X-API-Key: $API_KEY" \
    --data-binary "@$TMP_PAYLOAD" --max-time 20) || HTTP_CODE=000
else
  HTTP_CODE=$(curl -sS -o /tmp/itapz_bridge_resp -w '%{http_code}' \
    -X POST "$SITE_URL/api/sync-server-data" \
    -H 'Content-Type: application/json' \
    --data-binary "@$TMP_PAYLOAD" --max-time 20) || HTTP_CODE=000
fi

if [ "$HTTP_CODE" = "200" ]; then
  [ -n "$CURRENT_HASH" ] && echo "$CURRENT_HASH" > "$STATE_FILE"
  # Il segnalibro avanza SOLO dopo un invio riuscito: se la POST fallisce, al
  # giro dopo le stesse righe vengono rilette e nessun evento va perso.
  printf '%s\n%s\n' "$LOG_FILE" "$((OFFSET + NEW_BYTES))" > "$MARK_FILE"
  echo "$(date '+%F %T') OK $(cat /tmp/itapz_bridge_resp)"
else
  echo "$(date '+%F %T') FALLITO http=$HTTP_CODE $(cat /tmp/itapz_bridge_resp 2>/dev/null)"
  exit 1
fi
