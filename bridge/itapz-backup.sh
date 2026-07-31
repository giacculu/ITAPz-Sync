#!/bin/sh
# ITAPz — backup del database del sito.
#
# Il file SQLite contiene achievement, XP, candidature, donazioni e registro
# azioni: cose che il gioco NON puo' ricreare. Le statistiche tornano dal
# server al prossimo sync, tutto il resto no.
#
# Il database sta su un volume Docker con nome, quindi l'host non lo raggiunge
# per percorso: copia e verifica avvengono DENTRO il container, dove sqlite
# c'e' (installato nel Dockerfile). Sull'host serve solo docker.
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

fallisci() {
  echo "$(date '+%F %T') FALLITO: $1"
  exit 1
}

docker compose exec -T itapz-web sh -c 'command -v sqlite3 >/dev/null' 2>/dev/null \
  || fallisci "sqlite3 non presente nel container. Ricostruisci l'immagine: docker compose up -d --build itapz-web"

# .backup gestisce da solo il blocco: aspetta che le scritture in corso
# finiscano invece di catturare uno stato a meta'. Il percorso arriva da
# DATABASE_URL, che e' nella forma file:/app/data/dev.db.
docker compose exec -T itapz-web sh -c '
  set -e
  DB="${DATABASE_URL#file:}"
  [ -f "$DB" ] || { echo "database non trovato: $DB" >&2; exit 1; }
  sqlite3 "$DB" ".backup /tmp/itapz-backup.db"
  # Un backup che non si apre non e" un backup: si verifica adesso, non il
  # giorno in cui serve.
  sqlite3 /tmp/itapz-backup.db "PRAGMA integrity_check;" | grep -q "^ok$"
' || fallisci "copia o verifica del database non riuscita"

docker compose cp itapz-web:/tmp/itapz-backup.db "$DEST" || fallisci "estrazione dal container"
docker compose exec -T itapz-web rm -f /tmp/itapz-backup.db

gzip -f "$DEST"
SIZE=$(du -h "$DEST.gz" | cut -f1)

# Rotazione: senza, il disco si riempie e il sito si ferma per un backup.
find "$BACKUP_DIR" -name 'itapz-*.db.gz' -mtime "+$KEEP_DAYS" -delete

TOTALE=$(find "$BACKUP_DIR" -name 'itapz-*.db.gz' | wc -l | tr -d ' ')
echo "$(date '+%F %T') OK $DEST.gz ($SIZE) — $TOTALE backup conservati"
