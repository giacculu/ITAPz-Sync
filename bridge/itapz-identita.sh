#!/bin/sh
# ITAPz — recupero delle identita' dai log di connessione archiviati.
#
# Il bridge legge solo il file di connessioni piu' recente, perche' e' quello
# che cresce. Questo script ripassa TUTTO lo storico, comprese le cartelle
# archiviate (logs_AAAA-MM-GG/), per recuperare le coppie username <-> Steam ID
# di chi non si e' piu' collegato da quando la raccolta e' attiva.
#
# Va eseguito una volta sola, dopo aver aggiornato sito e bridge. Rilanciarlo
# non fa danno: il sito riscrive sopra le stesse coppie.
#
# Uso:
#   ZOMBOID_DIR=/home/administrator/Zomboid SITE_URL=http://localhost:3000 \
#     API_KEY=LA_TUA_CHIAVE /usr/local/bin/itapz-identita.sh

set -eu

ZOMBOID_DIR="${ZOMBOID_DIR:-/home/administrator/Zomboid}"
SITE_URL="${SITE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-}"

TMP="/tmp/itapz_identita.json"

# Gli handshake iniziali hanno steam-id="0" e username="null": si tengono solo
# le righe con uno Steam ID vero (iniziano tutti per 7656) e un nome reale.
IDENTITIES=$(find "$ZOMBOID_DIR/Logs" -name '*_connections.txt' -print0 2>/dev/null \
  | xargs -0 grep -ohE 'steam-id="7656[0-9]{13}" role="[^"]*" username="[^"]+"' 2>/dev/null \
  | sed -E 's/steam-id="([0-9]+)" role="[^"]*" username="([^"]+)"/{"u":"\2","s":"\1"}/' \
  | grep -v '"u":"null"' | grep -iv '"u":"[^"]*admin' | sort -u | paste -sd, - || true)

if [ -z "$IDENTITIES" ]; then
  echo "Nessuna identita' trovata in $ZOMBOID_DIR/Logs"
  exit 0
fi

TROVATE=$(printf '%s' "$IDENTITIES" | tr ',' '\n' | wc -l | tr -d ' ')
echo "Identita' trovate nello storico: $TROVATE"

# `players` vuoto: al sito serve solo la parte identita'
printf '{"players":[],"identities":[%s]}' "$IDENTITIES" > "$TMP"

HTTP_CODE=$(curl -sS -o /tmp/itapz_identita_resp -w '%{http_code}' \
  -X POST "$SITE_URL/api/sync-server-data" \
  -H 'Content-Type: application/json' \
  -H "X-API-Key: $API_KEY" \
  --data-binary "@$TMP" --max-time 30) || HTTP_CODE=000

if [ "$HTTP_CODE" = "200" ]; then
  echo "OK — $(cat /tmp/itapz_identita_resp)"
  echo "I personaggi verranno collegati agli account al prossimo sync,"
  echo "o subito quando il giocatore accede al sito."
else
  echo "FALLITO http=$HTTP_CODE $(cat /tmp/itapz_identita_resp 2>/dev/null)"
  exit 1
fi
