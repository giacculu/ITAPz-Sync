#!/bin/sh
# ITAPz bridge — invia al sito i dati che la mod stampa nel log del server.
#
# Il Lua server-side di Build 42 non ha ne' rete ne' scrittura file: la mod
# stampa i dati nel log fra marcatori e questo script li estrae e fa la POST.
#
# Uso (cron, ogni minuto):
#   * * * * * ZOMBOID_DIR=/home/administrator/Zomboid SITE_URL=http://localhost:3000 /usr/local/bin/itapz-bridge.sh >> /var/log/itapz-bridge.log 2>&1
#
# Variabili:
#   ZOMBOID_DIR  cartella Zomboid del server (default /home/administrator/Zomboid)
#   SITE_URL     URL del sito ITAPz          (default http://localhost:3000)
#   API_KEY      deve combaciare con SYNC_API_KEY del sito (opzionale)
#   LOG_FILE     log da leggere (default: il DebugLog-server piu' recente)

set -eu

ZOMBOID_DIR="${ZOMBOID_DIR:-/home/administrator/Zomboid}"
SITE_URL="${SITE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-}"

STATE_FILE="$ZOMBOID_DIR/.itapz_bridge_last"
TMP_PAYLOAD="/tmp/itapz_payload.json"

# Log piu' recente, se non indicato esplicitamente
if [ -z "${LOG_FILE:-}" ]; then
  LOG_FILE=$(ls -1t "$ZOMBOID_DIR"/Logs/*DebugLog-server.txt 2>/dev/null | head -n1 || true)
fi

if [ -z "${LOG_FILE:-}" ] || [ ! -f "$LOG_FILE" ]; then
  echo "$(date '+%F %T') nessun DebugLog-server in $ZOMBOID_DIR/Logs/"
  exit 0
fi

# Ultimo blocco ITAPZ_SYNC_BEGIN..ITAPZ_SYNC_END del log
BLOCK=$(awk '/ITAPZ_SYNC_BEGIN/{buf=""; inb=1} inb{buf=buf $0 "\n"} /ITAPZ_SYNC_END/{if(inb){last=buf; inb=0}} END{printf "%s", last}' "$LOG_FILE")

if [ -z "$BLOCK" ]; then
  echo "$(date '+%F %T') nessun blocco ITAPZ_SYNC nel log (la mod non ha ancora emesso dati)"
  exit 0
fi

# Righe giocatore -> JSON. Ogni riga del log ha un prefisso (timestamp/LOG:),
# quindi si prende tutto dal primo '{' in poi.
PLAYERS=$(printf '%s' "$BLOCK" | grep 'ITAPZ_PLAYER' | sed 's/^.*ITAPZ_PLAYER //' | sed 's/[[:space:]]*$//' | sed 's/\.$//' | paste -sd, -)

printf '{"players":[%s]}' "$PLAYERS" > "$TMP_PAYLOAD"

# Salta se identico all'ultimo invio riuscito
CURRENT_HASH=$(md5sum "$TMP_PAYLOAD" | cut -d' ' -f1)
if [ -f "$STATE_FILE" ] && [ "$CURRENT_HASH" = "$(cat "$STATE_FILE")" ]; then
  exit 0
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
  echo "$CURRENT_HASH" > "$STATE_FILE"
  echo "$(date '+%F %T') OK $(cat /tmp/itapz_bridge_resp)"
else
  echo "$(date '+%F %T') FALLITO http=$HTTP_CODE $(cat /tmp/itapz_bridge_resp 2>/dev/null)"
  exit 1
fi
