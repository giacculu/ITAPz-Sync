#!/bin/sh
# Gestisce i file di configurazione VPS che il pannello admin puo' modificare.
#
# Lo esegue l'agent via sudo (regola ITAPZ_CONFIG in /etc/sudoers.d/itapz).
# Accetta SOLO le chiavi sotto, mai un percorso arbitrario:
#
#   itapz-vps-config read  <agent_env|bridge_env|cron>
#   itapz-vps-config write <agent_env|bridge_env|cron>   (contenuto da stdin)
#
# Le variabili d'ambiente e i cron sono file di root: l'agent (utente
# administrator) non puo' toccarli senza questo ponte, che valida e fa un
# backup prima di scrivere.

if [ "$1" != "read" ] && [ "$1" != "write" ]; then
    echo "uso: itapz-vps-config read|write <agent_env|bridge_env|cron>" >&2
    exit 1
fi

case "$2" in
    agent_env)  FILE=/etc/itapz-agent.env ;;
    bridge_env) FILE=/etc/itapz-bridge.env ;;
    cron)       FILE=/etc/cron.d/itapz ;;
    *)
        echo "chiave non ammessa: $2" >&2
        exit 1
        ;;
esac

if [ "$1" = "read" ]; then
    cat "$FILE" 2>/dev/null || { echo "file non trovato: $FILE" >&2; exit 1; }
    exit 0
fi

# write: il contenuto arriva da stdin
TMP="/tmp/itapz-vps-config.$$"
cat > "$TMP" || { echo "scrittura temporanea fallita" >&2; exit 1; }

# Validazione leggera ma utile: evita di spezzare un file con una riga che
# non c'entra. L'env deve essere KEY=VAL o commento; il cron deve contenere
# un percorso di comando (il crond lo rifiuterebbe comunque, meglio qui).
if [ "$2" = "cron" ]; then
    while IFS= read -r riga; do
        case "$riga" in
            ""|\#*) continue ;;
            # Assegnazione variabile in cima al file (KEY=VALUE): valida nei
            # crontab. Il comando di una riga di cron non inizia mai cosi'.
            [A-Za-z_]*=*) continue ;;
            */*) ;;
            *) echo "riga cron non valida: $riga" >&2; rm -f "$TMP"; exit 1 ;;
        esac
    done < "$TMP"
else
    while IFS= read -r riga; do
        case "$riga" in
            ""|\#*) continue ;;
            *=*) ;;
            *) echo "riga env non valida: $riga" >&2; rm -f "$TMP"; exit 1 ;;
        esac
    done < "$TMP"
fi

# Backup prima di toccare il file vero.
cp "$FILE" "$FILE.bak" 2>/dev/null || true
mv -f "$TMP" "$FILE" || { echo "scrittura fallita" >&2; exit 1; }
chmod 600 "$FILE" 2>/dev/null || true
chown root:root "$FILE" 2>/dev/null || true
echo "scritto $2"
