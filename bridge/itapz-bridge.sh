#!/bin/sh
# ITAPz bridge — invia al sito il JSON scritto dalla mod.
#
# Il Lua di Build 42 non ha API di rete: la mod scrive
# <ZOMBOID_DIR>/itapz_sync_data.json e questo script fa la POST.
#
# Uso (cron, ogni minuto):
#   * * * * * ZOMBOID_DIR=/home/administrator/Zomboid SITE_URL=http://localhost:3000 /path/itapz-bridge.sh >> /var/log/itapz-bridge.log 2>&1
#
# Variabili:
#   ZOMBOID_DIR  cartella Zomboid del server   (default /home/administrator/Zomboid)
#   SITE_URL     URL del sito ITAPz            (default http://localhost:3000)
#   API_KEY      deve combaciare con SYNC_API_KEY del sito (opzionale)

set -eu

ZOMBOID_DIR="${ZOMBOID_DIR:-/home/administrator/Zomboid}"
SITE_URL="${SITE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-}"

# getFileWriter del gioco scrive in <Zomboid>/Lua/ ; si controlla anche la root
# per sicurezza.
DATA_FILE="$ZOMBOID_DIR/Lua/itapz_sync_data.json"
[ -f "$DATA_FILE" ] || DATA_FILE="$ZOMBOID_DIR/itapz_sync_data.json"
STATE_FILE="$ZOMBOID_DIR/.itapz_bridge_last"

if [ ! -f "$DATA_FILE" ]; then
  echo "$(date '+%F %T') nessun itapz_sync_data.json in $ZOMBOID_DIR/Lua/ (la mod non ha ancora scritto)"
  exit 0
fi

# Salta se il file non è cambiato dall'ultimo invio riuscito
CURRENT_HASH=$(md5sum "$DATA_FILE" | cut -d' ' -f1)
if [ -f "$STATE_FILE" ] && [ "$CURRENT_HASH" = "$(cat "$STATE_FILE")" ]; then
  exit 0
fi

if [ -n "$API_KEY" ]; then
  HTTP_CODE=$(curl -sS -o /tmp/itapz_bridge_resp -w '%{http_code}' \
    -X POST "$SITE_URL/api/sync-server-data" \
    -H 'Content-Type: application/json' \
    -H "X-API-Key: $API_KEY" \
    --data-binary "@$DATA_FILE" --max-time 20) || HTTP_CODE=000
else
  HTTP_CODE=$(curl -sS -o /tmp/itapz_bridge_resp -w '%{http_code}' \
    -X POST "$SITE_URL/api/sync-server-data" \
    -H 'Content-Type: application/json' \
    --data-binary "@$DATA_FILE" --max-time 20) || HTTP_CODE=000
fi

if [ "$HTTP_CODE" = "200" ]; then
  echo "$CURRENT_HASH" > "$STATE_FILE"
  echo "$(date '+%F %T') OK ($(cat /tmp/itapz_bridge_resp))"
else
  echo "$(date '+%F %T') FALLITO http=$HTTP_CODE $(cat /tmp/itapz_bridge_resp 2>/dev/null)"
  exit 1
fi
