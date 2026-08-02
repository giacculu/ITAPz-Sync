#!/bin/sh
# Aggiorna gli script ITAPz in /usr/local/bin dalla versione pubblicata.
#
# Lo esegue l'agent via sudo (regola ITAPZ_UPDATE in /etc/sudoers.d/itapz):
# per questo deve stare in /usr/local/bin con proprietario root. Scarica ogni
# file dal repo, controlla che il contenuto sia plausibile (prima riga con
# shebang) e lo sostituisce solo se lo e'. Il rewards e' un cron: la prossima
# corsa usera' il file nuovo.
#
#   sudo cp bridge/itapz-update.sh /usr/local/bin/
#   sudo chmod 755 /usr/local/bin/itapz-update.sh
#
# Non si aggiorna da solo: e' l'installatore, lo tocca root quando serve.

REPO="https://raw.githubusercontent.com/giacculu/ITAPz-Sync/master/bridge"
DIR="/usr/local/bin"

for f in itapz-agent.py itapz-rewards.py itapz_notify.py itapz-bridge.sh itapz-identita.sh itapz-backup.sh; do
    if ! curl -fsS --max-time 30 -o "$DIR/$f.tmp" "$REPO/$f"; then
        echo "$f: download fallito"
        rm -f "$DIR/$f.tmp"
        continue
    fi
    if ! head -n 1 "$DIR/$f.tmp" | grep -q '#!/'; then
        echo "$f: contenuto inatteso, non sostituito"
        rm -f "$DIR/$f.tmp"
        continue
    fi
    chmod 755 "$DIR/$f.tmp"
    mv -f "$DIR/$f.tmp" "$DIR/$f"
    echo "$f aggiornato"
done
