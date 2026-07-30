#!/bin/sh
# ITAPz — backup del database del sito.
#
# Il file SQLite contiene achievement, XP, candidature, donazioni e registro
# azioni: cose che il gioco NON puo' ricreare. Le statistiche tornano dal
# server al prossimo sync, tutto il resto no.
#
# Si usa `.backup` di sqlite e non `cp`: copiare il file mentre il sito ci
# scrive dentro produce un backup incoerente, che ci si accorge di aver
# sbagliato solo il giorno in cui serve.
#
# Uso (cron, una volta al giorno):
#   0 4 * * * root /usr/local/bin/itapz-backup.sh >> /var/log/itapz-backup.log 2>&1
#
# Variabili:
#   SITE_DIR    cartella del sito      (default /home/italian-project-zomboid)
#   BACKUP_DIR  dove salvare           (default /var/backups/itapz)
#   KEEP_DAYS   giorni da conservare   (default 14)

set -eu

SITE_DIR="${SITE_DIR:-/home/italian-project-zomboid}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/itapz}"
KEEP_DAYS="${KEEP_DAYS:-14}"

STAMP=$(date '+%Y%m%d-%H%M%S')
DEST="$BACKUP_DIR/itapz-$STAMP.db"

mkdir -p "$BACKUP_DIR"
cd "$SITE_DIR"

# .backup gestisce da solo il blocco: aspetta che le scritture in corso
# finiscano invece di catturare uno stato a meta'.
docker compose exec -T itapz-web sh -c \
  'sqlite3 "${DATABASE_URL#file:}" ".backup /tmp/itapz-backup.db"'
docker compose cp itapz-web:/tmp/itapz-backup.db "$DEST"
docker compose exec -T itapz-web rm -f /tmp/itapz-backup.db

# Un backup che non si apre non e' un backup: si verifica adesso, non il
# giorno in cui serve.
if ! sqlite3 "$DEST" "PRAGMA integrity_check;" | grep -q '^ok$'; then
  echo "$(date '+%F %T') BACKUP CORROTTO: $DEST"
  exit 1
fi

gzip -f "$DEST"
SIZE=$(du -h "$DEST.gz" | cut -f1)

# Rotazione: senza, il disco si riempie e il sito si ferma per un backup.
find "$BACKUP_DIR" -name 'itapz-*.db.gz' -mtime "+$KEEP_DAYS" -delete

TOTALE=$(find "$BACKUP_DIR" -name 'itapz-*.db.gz' | wc -l | tr -d ' ')
echo "$(date '+%F %T') OK $DEST.gz ($SIZE) — $TOTALE backup conservati"
