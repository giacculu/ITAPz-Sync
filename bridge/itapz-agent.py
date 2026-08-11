#!/usr/bin/env python3
"""
ITAPz — agent di controllo del server.

Il sito gira in Docker e non tocca l'host: accoda i comandi, questo agent li
preleva ed esegue sulla VPS. Nessuna porta aperta verso l'esterno, nessun
accesso del sito alla macchina.

Comandi supportati:
  RCON          esegue un comando via RCON
  START/STOP/RESTART   systemctl sull'unita' del server PZ
  READ_CONFIG   legge il file .ini del server
  WRITE_CONFIG  scrive il .ini (con backup e validazione)
  WIPE          ferma il server, svuota il salvataggio, riavvia
  DELETE_CHARACTER  cancella un personaggio dal salvataggio (e, se richiesto,
                    il suo account di gioco)
  INSPECT_SAVE  elenca tabelle e file del salvataggio, senza toccare niente
  NOTIFY        accoda un messaggio PRIVATO in gioco per un giocatore (payload
                JSON {id, username, message}); la mod lo consegna a quel solo
                giocatore
  READ_VPS_FILE / WRITE_VPS_FILE  legge/scrive gli env di agent e bridge e il
                file cron (payload: chiave, o {file, content}), via sudo con
                lo script itapz-vps-config e solo sulle chiavi ammesse

L'agent tiene anche aggiornato l'elenco delle zone che la mod usa per dire
"sei arrivato a Rosewood": lo scarica dal sito e lo scrive dove la mod lo
legge.

Uso (servizio systemd, vedi bridge/systemd/):
  SITE_URL=http://localhost:3000 RCON_PASSWORD=xxx ./itapz-agent.py --loop

Variabili:
  SITE_URL        URL del sito ITAPz        (default http://localhost:3000)
  API_KEY         = SYNC_API_KEY del sito   (obbligatoria)
  RCON_HOST/PORT/PASSWORD                   (RCON del server PZ)
  PZ_SERVICE      unita' systemd            (default pzserver)
  PZ_CONFIG       percorso del .ini         (default
                  /home/administrator/Zomboid/Server/servertest.ini)
  PZ_LOG          console del server        (default
                  /home/administrator/Zomboid/server-console.txt)
  ZOMBOID_DIR     cartella dati del gioco   (default: due livelli sopra
                  PZ_CONFIG, cioe' /home/administrator/Zomboid)
  WIPE_BACKUP_DIR dove finiscono i salvataggi spostati dal wipe
                  (default $ZOMBOID_DIR/wipe-backup)
  LOG_LINES       righe di log inviate      (default 300)
  POLL_SECONDS    intervallo in loop        (default 3)
  HEARTBEAT_SECONDS  intervallo del battito (default 15)
  ZONE_SECONDS    ogni quanto riscaricare le zone (default 600)
"""

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from itapz_notify import append_notify, append_line

SITE_URL = os.environ.get("SITE_URL", "http://localhost:3000").rstrip("/")
API_KEY = os.environ.get("API_KEY", "")
RCON_HOST = os.environ.get("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("RCON_PORT", "27015"))
RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "")
PZ_SERVICE = os.environ.get("PZ_SERVICE", "pzserver")
BRIDGE_SERVICE = os.environ.get("BRIDGE_SERVICE", "itapz-bridge")
AGENT_SERVICE = os.environ.get("AGENT_SERVICE", "itapz-agent")
PZ_CONFIG = os.environ.get(
    "PZ_CONFIG", "/home/administrator/Zomboid/Server/servertest.ini"
)
PZ_LOG = os.environ.get("PZ_LOG", "/home/administrator/Zomboid/server-console.txt")
# La cartella dati sta due livelli sopra il .ini (.../Zomboid/Server/x.ini):
# ricavarla evita di doverla configurare a mano quando il percorso non e'
# quello predefinito.
ZOMBOID_DIR = os.environ.get(
    "ZOMBOID_DIR", os.path.dirname(os.path.dirname(os.path.abspath(PZ_CONFIG)))
)
# File delle notifiche private: la mod lo legge da Zomboid/Lua/.
NOTIFY_PATH = os.environ.get("NOTIFY_PATH", os.path.join(ZOMBOID_DIR, "Lua", "ITAPz_Notify.txt"))
# File dei reset richiesti alla mod (vedi delete_character): quando un
# personaggio viene eliminato, la mod ripulisce i suoi marcatori dal ModData.
RESET_PATH = os.environ.get("RESET_PATH", os.path.join(ZOMBOID_DIR, "Lua", "ITAPz_Reset.txt"))
WIPE_BACKUP_DIR = os.environ.get("WIPE_BACKUP_DIR", os.path.join(ZOMBOID_DIR, "wipe-backup"))
LOG_LINES = int(os.environ.get("LOG_LINES", "300"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "3"))
HEARTBEAT_SECONDS = int(os.environ.get("HEARTBEAT_SECONDS", "15"))
ZONE_SECONDS = int(os.environ.get("ZONE_SECONDS", "600"))
MOD_CHECK_MINUTES = int(os.environ.get("MOD_CHECK_MINUTES", "10"))
MOD_RESTART_MINUTES = int(os.environ.get("MOD_RESTART_MINUTES", "5"))
MOD_NEED_UPDATE_RE = os.environ.get("MOD_NEED_UPDATE_RE", r"(?i)need update")
MOD_NO_UPDATE_RE = os.environ.get(
    "MOD_NO_UPDATE_RE",
    r"(?i)(no mods? need update|mods updated|all mods? updated)",
)
MOD_RESTART_PATH = os.environ.get(
    "MOD_RESTART_PATH", os.path.join(ZOMBOID_DIR, "Lua", "ITAPz_ModRestart.txt")
)

# --- RCON (protocollo Source, solo libreria standard) -----------------------
import socket
import struct

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2
# Tipi in RISPOSTA (numerati a parte da quelli in richiesta)
SERVERDATA_RESPONSE_VALUE = 0
SERVERDATA_AUTH_RESPONSE = 2


class Rcon:
    def __init__(self, host, port, password, timeout=10):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.timeout = timeout
        self.req_id = 0
        self._auth(password)

    def _send(self, msg_type, body):
        self.req_id += 1
        payload = struct.pack("<ii", self.req_id, msg_type) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)
        return self.req_id

    def _read_exactly(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("connessione RCON chiusa")
            buf += chunk
        return buf

    def _recv(self):
        (length,) = struct.unpack("<i", self._read_exactly(4))
        data = self._read_exactly(length)
        res_id, res_type = struct.unpack("<ii", data[:8])
        return res_id, res_type, data[8:-2].decode("utf-8", errors="replace")

    def _auth(self, password):
        """Autentica consumando TUTTI i pacchetti dell'auth.

        Il protocollo Source risponde all'autenticazione con due pacchetti: un
        RESPONSE_VALUE vuoto e poi l'AUTH_RESPONSE vero. Leggerne uno solo
        lasciava l'altro nel buffer, e il comando successivo se lo ritrovava
        come propria prima risposta — vuota. E' per questo che `players`
        tornava vuoto pur essendoci gente collegata.

        Si riconosce dal TIPO, non dall'id: entrambi i pacchetti portano l'id
        della richiesta, quindi l'id non li distingue.
        """
        self._send(SERVERDATA_AUTH, password)

        for _ in range(4):  # limite di sicurezza: non restare in ascolto per sempre
            res_id, res_type, _ = self._recv()
            if res_id == -1:
                raise RuntimeError("password RCON errata")
            if res_type == SERVERDATA_AUTH_RESPONSE:
                return
        raise RuntimeError("autenticazione RCON senza risposta riconoscibile")

    def command(self, cmd):
        """Esegue un comando e restituisce l'output completo.

        Due accortezze, entrambe imparate sul campo:

        - si tengono solo i pacchetti con l'id di QUESTA richiesta. Se qualcosa
          e' rimasto nel buffer da prima, viene scartato invece di essere preso
          per la risposta;
        - PZ puo' spezzare le risposte lunghe su piu' pacchetti, quindi si
          continua a leggere finche' il socket tace, senza fermarsi al primo
          pacchetto vuoto.
        """
        req_id = self._send(SERVERDATA_EXECCOMMAND, cmd)

        chunks = []
        scartati = 0
        try:
            # Primo pacchetto col nostro id: col timeout pieno, perche' il
            # server potrebbe metterci un attimo.
            while True:
                res_id, _, body = self._recv()
                if res_id == req_id:
                    chunks.append(body)
                    break
                scartati += 1
                if scartati > 4:
                    return ""
        except (socket.timeout, TimeoutError):
            return ""

        self.sock.settimeout(0.6)
        try:
            while True:
                res_id, _, more = self._recv()
                if res_id == req_id:
                    chunks.append(more)
        except (socket.timeout, TimeoutError, OSError, struct.error):
            pass
        finally:
            try:
                self.sock.settimeout(self.timeout)
            except OSError:
                pass

        return "".join(chunks).strip()

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# --- HTTP -------------------------------------------------------------------
def http_json(url, method="GET", payload=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json")
    if API_KEY:
        req.add_header("X-API-Key", API_KEY)
    data = json.dumps(payload).encode() if payload is not None else None
    with urllib.request.urlopen(req, data=data, timeout=20) as res:
        raw = res.read().decode()
        return json.loads(raw) if raw else {}


# --- esecuzione comandi -----------------------------------------------------
def run_rcon(cmd):
    if not RCON_PASSWORD:
        raise RuntimeError("RCON_PASSWORD non impostata")
    rcon = Rcon(RCON_HOST, RCON_PORT, RCON_PASSWORD)
    try:
        return rcon.command(cmd) or "(nessun output)"
    finally:
        rcon.close()


def rileva_mod_aggiornamento(output):
    """True se l'output di checkModsNeedUpdate parla di mod da aggiornare.

    Il positivo contiene "Need Update" (case-insensitive); il negativo e'
    "No mods need update", che la conterrebbe comunque: lo si esclude prima.
    Le regex si calibrano dall'env senza toccare il codice."""
    testo = output or ""
    if re.search(MOD_NO_UPDATE_RE, testo):
        return False
    return bool(re.search(MOD_NEED_UPDATE_RE, testo))


_ultimo_mod_check = 0.0


def _scadenza_pendente():
    """Timestamp target del riavvio pendente, o None."""
    try:
        with open(MOD_RESTART_PATH, "r", encoding="utf-8") as f:
            testo = f.read().strip()
            if testo.isdigit():
                return int(testo)
    except (FileNotFoundError, OSError):
        pass
    return None


def check_mods(ora=None):
    """Check periodico di mod da aggiornare (al piu' ogni MOD_CHECK_MINUTES).

    Con mod da aggiornare e nessun riavvio gia' pendente: preavviso in gioco,
    salvataggio immediato del mondo e file persistente con il timestamp del
    riavvio. Ritorna un messaggio per il log."""
    global _ultimo_mod_check
    now = ora if ora is not None else time.time()
    if now - _ultimo_mod_check < MOD_CHECK_MINUTES * 60:
        return ""
    _ultimo_mod_check = now

    if _scadenza_pendente() is not None:
        return "riavvio mod gia' pendente"

    try:
        output = run_rcon("checkModsNeedUpdate")
    except Exception as e:
        print(f"mod check: RCON non risponde ({e})", file=sys.stderr)
        return "mod check fallito"

    if not rileva_mod_aggiornamento(output):
        return "mod check: nessuna mod da aggiornare"

    try:
        run_rcon(
            f'servermsg "Mod da aggiornare: riavvio automatico tra '
            f'{MOD_RESTART_MINUTES} minuti. Il mondo viene salvato adesso."'
        )
        run_rcon("save")
    except Exception as e:
        print(f"mod check: preavviso/save fallito ({e})", file=sys.stderr)

    try:
        os.makedirs(os.path.dirname(MOD_RESTART_PATH), exist_ok=True)
        with open(MOD_RESTART_PATH, "w", encoding="utf-8", newline="\n") as f:
            f.write(str(int(now + MOD_RESTART_MINUTES * 60)))
    except OSError as e:
        print(f"mod check: scrittura file pendente fallita ({e})", file=sys.stderr)
        return "mod check: riavvio programmato ma file non scritto"

    return "mod check: riavvio per mod aggiornate pendente"


def scadenza_mod_restart(ora=None):
    """Alla scadenza dei MOD_RESTART_MINUTES accoda il RESTART alla coda del sito.

    Se la POST fallisce il file resta: al tick successivo si riprova. Il
    RESTART passa dalla coda comandi del sito, quindi notifica Discord e
    audit arrivano da soli."""
    now = ora if ora is not None else time.time()
    target = _scadenza_pendente()
    if target is None or now < target:
        return ""

    try:
        http_json(
            f"{SITE_URL}/api/server-control/schedule",
            method="POST",
            payload={"type": "RESTART", "requestedBy": "mod da aggiornare"},
        )
    except Exception as e:
        print(f"mod restart: accodamento fallito ({e})", file=sys.stderr)
        return "mod restart: accodamento fallito, si riprovera'"

    try:
        os.remove(MOD_RESTART_PATH)
    except OSError:
        pass
    return "mod restart: RESTART accodato al sito"


def run_systemctl(action):
    """start/stop/restart dell'unita' del server (sudoers ristretto)."""
    if action not in ("start", "stop", "restart"):
        raise RuntimeError("azione non valida")
    # Spegnimento pulito: salva il mondo prima di fermare il servizio
    if action in ("stop", "restart") and RCON_PASSWORD:
        try:
            run_rcon("save")
        except Exception as e:
            print(f"  avviso: salvataggio pre-{action} fallito: {e}", file=sys.stderr)

    res = subprocess.run(
        ["sudo", "-n", "/usr/bin/systemctl", action, PZ_SERVICE],
        capture_output=True, text=True, timeout=120,
    )
    out = (res.stdout + res.stderr).strip()
    if res.returncode != 0:
        raise RuntimeError(out or f"systemctl {action} uscito con {res.returncode}")
    return out or f"{action} eseguito su {PZ_SERVICE}"


def _systemctl_unit(action, unit):
    """systemctl su un'unita' qualsiasi (bridge/agent). Sudoers ristretto."""
    res = subprocess.run(
        ["sudo", "-n", "/usr/bin/systemctl", action, unit],
        capture_output=True, text=True, timeout=60,
    )
    out = (res.stdout + res.stderr).strip()
    if res.returncode != 0:
        raise RuntimeError(out or f"systemctl {action} {unit} uscito con {res.returncode}")
    return out or f"{action} {unit} ok"


def sync_agents(_payload=None):
    """Aggiorna bridge, agent e rewards dalla versione pubblicata, poi riavvia.

    Scarica gli script piu' recenti del repo ITAPz-Sync in /usr/local/bin (via
    sudo, con lo script installatore dedicato) e riavvia bridge e agent. Il
    rewards e' un cron: la prossima corsa usera' il file nuovo.

    L'agent si riavvia da solo DOPO aver risposto: un restart sincrono qui
    ucciderebbe questo processo prima di mandare l'esito, e il comando
    resterebbe PENDING. Si lancia staccato, con un piccolo ritardo.
    """
    messaggi = []
    try:
        esito = subprocess.run(
            ["sudo", "-n", "/usr/local/bin/itapz-update.sh"],
            capture_output=True, text=True, timeout=180,
        )
        output = (esito.stdout or "").strip()
        if not output:
            output = "nessun aggiornamento"
        messaggi.append(f"aggiornamento: {output}")
        if esito.returncode != 0:
            messaggi.append(f"aggiornamento: esito {esito.returncode}")
    except Exception as e:
        messaggi.append(f"aggiornamento NON riuscito: {e}")

    try:
        messaggi.append(_systemctl_unit("restart", BRIDGE_SERVICE))
    except Exception as e:
        messaggi.append(f"bridge NON riavviato: {e}")

    subprocess.Popen(
        ["bash", "-c", f"sleep 3 && sudo -n /usr/bin/systemctl restart {AGENT_SERVICE}"],
        start_new_session=True,
    )
    messaggi.append(f"{AGENT_SERVICE} in riavvio")
    return " | ".join(messaggi)


def nome_server():
    """Nome del server, cioe' il nome del file .ini senza estensione.

    E' lo stesso nome che il gioco usa per la cartella del salvataggio e per
    il file degli account, quindi basta questo per sapere cosa cancellare."""
    return os.path.splitext(os.path.basename(PZ_CONFIG))[0]


def _sposta_o_cancella(percorso, backup, etichetta, stamp, fatte):
    """Toglie di mezzo un file o una cartella, spostandolo se richiesto."""
    if not os.path.exists(percorso):
        fatte.append(f"{etichetta}: non c'era ({percorso})")
        return

    if backup:
        os.makedirs(WIPE_BACKUP_DIR, exist_ok=True)
        destinazione = os.path.join(
            WIPE_BACKUP_DIR, f"{os.path.basename(percorso)}.{stamp}"
        )
        shutil.move(percorso, destinazione)
        fatte.append(f"{etichetta}: spostato in {destinazione}")
    elif os.path.isdir(percorso):
        shutil.rmtree(percorso)
        fatte.append(f"{etichetta}: cancellato {percorso}")
    else:
        os.remove(percorso)
        fatte.append(f"{etichetta}: cancellato {percorso}")


def run_wipe(payload):
    """Wipe del server: ferma, svuota, riavvia.

    Il mondo di Project Zomboid sta tutto in Saves/Multiplayer/<nome>: mappa,
    costruzioni, veicoli e personaggi. Gli account (login e password) stanno
    invece in db/<nome>.db, e si toccano solo se richiesto — cancellarli
    obbligherebbe tutti a registrarsi di nuovo, che di solito non e' quel che
    si vuole da un wipe.

    Con `backup` le cartelle vengono spostate invece che cancellate: un wipe
    non si annulla, e avere ancora il mondo di ieri e' l'unica rete."""
    try:
        opz = json.loads(payload or "{}")
    except Exception:
        opz = {}

    mondo = opz.get("mondo", True)
    account = opz.get("account", False)
    backup = opz.get("backup", True)

    if not mondo and not account:
        raise RuntimeError("wipe senza niente da cancellare")

    nome = nome_server()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    fatte = []

    # Il server va fermo prima: cancellare sotto i piedi di un processo che
    # scrive lascerebbe file a meta' e un mondo corrotto al riavvio.
    fatte.append(run_systemctl("stop"))
    time.sleep(3)

    if mondo:
        _sposta_o_cancella(
            os.path.join(ZOMBOID_DIR, "Saves", "Multiplayer", nome),
            backup, "mondo e personaggi", stamp, fatte,
        )
    if account:
        _sposta_o_cancella(
            os.path.join(ZOMBOID_DIR, "db", f"{nome}.db"),
            backup, "account di gioco", stamp, fatte,
        )

    fatte.append(run_systemctl("start"))
    return "\n".join(fatte)


def _percorso_salvataggio():
    """Cartella del mondo: Saves/Multiplayer/<nome server>."""
    return os.path.join(ZOMBOID_DIR, "Saves", "Multiplayer", nome_server())


def _db_personaggi():
    """Il database dei personaggi.

    Sta nella cartella del mondo e non in db/: quello contiene gli account
    (login e password), che sono un'altra cosa e si toccano solo su richiesta.
    """
    return os.path.join(_percorso_salvataggio(), "players.db")


def _db_account():
    """Il database degli account del server: login, password, permessi.

    Sta in db/<nome>.db, fuori dalla cartella del mondo: un wipe del
    salvataggio non lo tocca, ed e' giusto — chi ha perso il personaggio puo'
    comunque rientrare.
    """
    return os.path.join(ZOMBOID_DIR, "db", f"{nome_server()}.db")


def _cancella_da_db(percorso, username, etichetta, fatte):
    """Toglie un nome da tutte le tabelle che hanno una colonna 'username'.

    Restituisce quante righe ha rimosso. Il database va toccato a server
    fermo: aperto, lo tiene in memoria e riscriverebbe sopra.
    """
    if not os.path.exists(percorso):
        fatte.append(f"{etichetta}: database non trovato ({percorso})")
        return 0

    conn = sqlite3.connect(percorso)
    try:
        tabelle = _tabelle_con_username(conn)
        if not tabelle:
            fatte.append(f"{etichetta}: nessuna tabella con una colonna 'username'")
            return 0
        totale = 0
        for tabella, colonna in tabelle:
            cur = conn.execute(
                f'DELETE FROM "{tabella}" WHERE "{colonna}" = ?', (username,)
            )
            if cur.rowcount > 0:
                fatte.append(f"{etichetta}: {tabella}, {cur.rowcount} righe rimosse")
                totale += cur.rowcount
        conn.commit()
        return totale
    finally:
        conn.close()


def _tabelle_con_username(conn):
    """Tabelle che hanno una colonna con lo username, con il nome esatto.

    Si guarda com'e' fatto il database invece di dare per scontata una
    tabella: Project Zomboid ne ha cambiato la forma fra una build e l'altra
    (`localPlayers` in singolo, `networkPlayers` in rete), e una query scritta
    a memoria fallirebbe in silenzio proprio dove serve precisione.
    """
    trovate = []
    nomi = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()
    for (tabella,) in nomi:
        for colonna in conn.execute(f'PRAGMA table_info("{tabella}")').fetchall():
            # Solo "username": e' inequivocabile. Una colonna chiamata "name"
            # puo' essere il nome di qualsiasi cosa — un veicolo, una stanza —
            # e cancellare per nome in una tabella sbagliata farebbe un danno
            # peggiore di quello che si voleva evitare.
            if str(colonna[1]).lower() == "username":
                trovate.append((tabella, colonna[1]))
                break
    return trovate


def inspect_save(_payload=None):
    """Fotografia del salvataggio, senza modificare niente.

    Serve a sapere davvero dove stanno le cose prima di cancellarle: le
    fazioni, per esempio, non sono documentate da nessuna parte.
    """
    righe = [f"cartella: {_percorso_salvataggio()}"]

    try:
        for nome in sorted(os.listdir(_percorso_salvataggio())):
            intero = os.path.join(_percorso_salvataggio(), nome)
            tipo = "dir " if os.path.isdir(intero) else "file"
            dim = "" if os.path.isdir(intero) else f" {os.path.getsize(intero)} byte"
            righe.append(f"  {tipo} {nome}{dim}")
    except FileNotFoundError:
        righe.append("  (cartella inesistente)")

    db = _db_personaggi()
    righe.append(f"players.db: {'presente' if os.path.exists(db) else 'assente'}")
    if os.path.exists(db):
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        try:
            for (tabella,) in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            ).fetchall():
                colonne = [c[1] for c in conn.execute(f'PRAGMA table_info("{tabella}")')]
                quante = conn.execute(f'SELECT COUNT(*) FROM "{tabella}"').fetchone()[0]
                righe.append(f"  {tabella} ({quante} righe): {', '.join(colonne)}")
        finally:
            conn.close()

    return "\n".join(righe)


def delete_character(payload):
    """Cancella un personaggio dal salvataggio.

    Il server va fermato prima: tiene i personaggi in memoria e al primo
    salvataggio riscriverebbe la riga appena tolta, facendo sembrare che il
    comando non abbia funzionato.

    L'account di gioco (login e password) e' un'altra cosa e si tocca solo se
    richiesto: cancellare il personaggio di qualcuno non significa impedirgli
    di rientrare.
    """
    try:
        opz = json.loads(payload or "{}")
    except Exception:
        opz = {}

    username = str(opz.get("username") or "").strip()
    if not username:
        raise RuntimeError("nessun personaggio indicato")
    # Anti command injection: username finisce in un comando RCON tra
    # virgolette; caratteri pericolosi e si spezza il comando.
    if re.search(r'["\n\r`;$\\\x00]', username):
        raise RuntimeError(f"username non valido per il comando RCON: {username!r}")
    anche_account = opz.get("account", False)

    db = _db_personaggi()
    if not os.path.exists(db):
        raise RuntimeError(f"database dei personaggi non trovato: {db}")

    fatte = []

    # L'account si prova prima via RCON, che funziona a server acceso ed e' la
    # via che il gioco offre. Puo' pero' non rispondere — server gia' fermo,
    # ancora in avvio, RCON spento — e in quel caso l'account restava li'
    # mentre il comando risultava riuscito.
    rcon_ok = False
    if anche_account:
        try:
            fatte.append("account (RCON): " + run_rcon(f'removeuserfromwhitelist "{username}"'))
            rcon_ok = True
        except Exception as e:
            fatte.append(f"account (RCON): non riuscito ({e}), si prova sul file")

    fatte.append(run_systemctl("stop"))
    time.sleep(3)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    os.makedirs(WIPE_BACKUP_DIR, exist_ok=True)
    copia = os.path.join(WIPE_BACKUP_DIR, f"players.db.{stamp}")
    shutil.copy2(db, copia)
    fatte.append(f"copia di sicurezza: {copia}")

    # Stessa funzione che toglie gli account: e' lo stesso lavoro su un altro
    # file, e tenerne due copie significherebbe correggerle due volte.
    totale = _cancella_da_db(db, username, "personaggio", fatte)
    if totale == 0:
        fatte.append(
            f'personaggio: nessuna riga per "{username}". Il nome non combacia, '
            "oppure lancia INSPECT_SAVE per vedere com'e' fatto players.db"
        )

    # Se RCON non ha risposto, ora il server e' fermo e il file degli account
    # si puo' toccare direttamente: e' lo stesso lavoro, fatto dall'altra
    # parte. Con una copia di sicurezza prima, come per i personaggi.
    if anche_account and not rcon_ok:
        account_db = _db_account()
        if os.path.exists(account_db):
            copia_account = os.path.join(WIPE_BACKUP_DIR, f"{os.path.basename(account_db)}.{stamp}")
            shutil.copy2(account_db, copia_account)
            fatte.append(f"copia degli account: {copia_account}")
        quanti = _cancella_da_db(account_db, username, "account (file)", fatte)
        if quanti == 0:
            fatte.append(f'account (file): nessuna riga per "{username}"')

    # I marcatori della mod (flag degli achievement, zone, notifiche) vivono nel
    # ModData del mondo, che la cancellazione dei soli personaggi non tocca: un
    # nuovo personaggio con lo stesso nome ritroverebbe i flag vecchi e gli
    # achievement-flag scatterebbero subito. Lo si segnala alla mod, che li
    # ripulisce al prossimo avvio del server.
    append_line(RESET_PATH, username)
    fatte.append(f"reset marcatori per {username}")

    fatte.append(run_systemctl("start"))
    return "\n".join(fatte)


def read_config():
    with open(PZ_CONFIG, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def validate_config(text):
    """Un .ini malformato impedisce l'avvio del server: si accettano solo
    righe vuote, commenti e coppie chiave=valore."""
    if not text.strip():
        raise RuntimeError("configurazione vuota")
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#") or s.startswith(";") or s.startswith("["):
            continue
        if "=" not in s:
            raise RuntimeError(f"riga {i} non valida: {s[:60]!r}")
        key = s.split("=", 1)[0].strip()
        if not key or any(c in key for c in " \t"):
            raise RuntimeError(f"riga {i}: chiave non valida {key[:40]!r}")
    return True


def write_config(text):
    validate_config(text)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{PZ_CONFIG}.bak-{stamp}"
    shutil.copy2(PZ_CONFIG, backup)
    with open(PZ_CONFIG, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return f"Salvato. Backup: {backup}. Riavvia il server per applicare."


_last_beat = 0.0


def collect_status():
    """Il server e' su se RCON risponde. Il conteggio giocatori esce dalla
    stessa chiamata: "Players connected (2):" seguito da una riga per nome.

    Se l'output non e' interpretabile si manda players=None invece di zero: il
    sito ripiega sul conteggio della mod, meglio di dichiarare il server vuoto
    per un formato di risposta inatteso."""
    try:
        out = run_rcon("players")
    except Exception:
        return {"online": False, "players": 0}

    m = re.search(r"\((\d+)\)", out)
    if m:
        return {"online": True, "players": int(m.group(1))}

    lines = [l for l in out.splitlines() if l.strip().startswith("-")]
    if lines:
        return {"online": True, "players": len(lines)}

    if re.search(r"players? connected", out, re.I):
        return {"online": True, "players": 0}

    print(f"battito: output di 'players' non interpretabile: {out[:120]!r}", file=sys.stderr)
    return {"online": True, "players": None}


def push_heartbeat():
    """Battito verso il sito. Non a ogni giro: RCON ogni 3s sarebbe inutile."""
    global _last_beat
    now = time.monotonic()
    if now - _last_beat < HEARTBEAT_SECONDS:
        return
    _last_beat = now
    try:
        http_json(f"{SITE_URL}/api/server-heartbeat", method="POST", payload=collect_status())
    except Exception as e:
        print(f"ERRORE invio battito: {e}", file=sys.stderr)


_last_log_hash = None


def tail_log():
    """Ultime righe della console. Legge solo la coda del file: il log del
    server cresce di continuo e puo' arrivare a centinaia di MB."""
    size = os.path.getsize(PZ_LOG)
    with open(PZ_LOG, "rb") as f:
        f.seek(max(0, size - 128 * 1024))
        chunk = f.read()
    text = chunk.decode("utf-8", errors="replace")
    return "\n".join(text.splitlines()[-LOG_LINES:])


def push_log():
    """Manda la coda del log al sito, ma solo se e' cambiata."""
    global _last_log_hash
    try:
        text = tail_log()
    except FileNotFoundError:
        return
    except Exception as e:
        print(f"ERRORE lettura log: {e}", file=sys.stderr)
        return

    h = hash(text)
    if h == _last_log_hash:
        return
    try:
        http_json(f"{SITE_URL}/api/server-log", method="POST", payload={"content": text})
        _last_log_hash = h
    except Exception as e:
        print(f"ERRORE invio log: {e}", file=sys.stderr)


# File di configurazione VPS che il pannello puo' leggere/scrivere. L'agent li
# tocca SOLO via /usr/local/bin/itapz-vps-config (sudo), che accetta queste
# chiavi e mai percorsi arbitrari.
VPS_FILE_MAP = {
    "agent_env": "/etc/itapz-agent.env",
    "bridge_env": "/etc/itapz-bridge.env",
    "cron": "/etc/cron.d/itapz",
}


def _vps_config(*args, contenuto=None):
    try:
        esito = subprocess.run(
            ["sudo", "-n", "/usr/local/bin/itapz-vps-config.sh", *args],
            input=contenuto,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:
        raise RuntimeError(f"itapz-vps-config non eseguibile: {e}")
    if esito.returncode != 0:
        raise RuntimeError((esito.stderr or "").strip() or f"esito {esito.returncode}")
    return esito.stdout


def vps_file_read(chiave):
    if chiave not in VPS_FILE_MAP:
        raise RuntimeError(f"chiave non ammessa: {chiave}")
    return _vps_config("read", chiave)


def vps_file_write(chiave, contenuto):
    if chiave not in VPS_FILE_MAP:
        raise RuntimeError(f"chiave non ammessa: {chiave}")
    return _vps_config("write", chiave, contenuto=contenuto)


def notify_player(payload):
    """NOTIFY: accoda un messaggio privato per un giocatore.

    Il payload dal sito e' JSON {id, username, message}: id rende la notifica
    unica (la mod non la manda due volte, anche se il file non e' ancora stato
    pulito). Il messaggio lo vede solo il destinatario.
    """
    try:
        data = json.loads(payload or "{}")
    except Exception as e:
        raise RuntimeError(f"NOTIFY: payload JSON non valido ({e})")
    username = str(data.get("username", "")).strip()
    message = str(data.get("message", "")).strip()
    if not username or not message:
        raise RuntimeError("NOTIFY: username e message obbligatori")
    notif_id = str(data.get("id") or "").strip() or f"notify-{int(time.time())}-{os.getpid()}"
    append_notify(NOTIFY_PATH, notif_id, username, message)
    return f"notifica privata accodata per {username}"


def execute(cmd):
    t = cmd["type"]
    if t == "RCON":
        return run_rcon(cmd["payload"])
    if t == "START":
        return run_systemctl("start")
    if t == "STOP":
        return run_systemctl("stop")
    if t == "RESTART":
        return run_systemctl("restart")
    if t == "READ_CONFIG":
        return read_config()
    if t == "WRITE_CONFIG":
        return write_config(cmd["payload"])
    if t == "NOTIFY":
        return notify_player(cmd.get("payload"))
    if t == "READ_VPS_FILE":
        return vps_file_read(str(cmd.get("payload") or "").strip())
    if t == "WRITE_VPS_FILE":
        try:
            data = json.loads(cmd.get("payload") or "{}")
        except Exception as e:
            raise RuntimeError(f"WRITE_VPS_FILE: payload JSON non valido ({e})")
        return vps_file_write(str(data.get("file") or ""), str(data.get("content") or ""))
    if t == "WIPE":
        return run_wipe(cmd.get("payload"))
    if t == "DELETE_CHARACTER":
        return delete_character(cmd.get("payload"))
    if t == "INSPECT_SAVE":
        return inspect_save(cmd.get("payload"))
    if t == "SYNC_AGENTS":
        return sync_agents(cmd.get("payload"))
    raise RuntimeError(f"tipo comando sconosciuto: {t}")


_ultime_zone = 0.0


def push_zone():
    """Scarica le zone dal sito e le scrive dove la mod le legge.

    Il file sta in Zomboid/Lua/ perche' e' l'unica cartella da cui il Lua del
    server sa leggere. La mod lo rilegge quando riparte: cambiare una zona sul
    sito ha effetto al riavvio successivo, che per un elenco che cambia due
    volte l'anno e' abbastanza.

    Si riscrive solo se il contenuto e' cambiato: toccare il file a ogni giro
    non servirebbe a niente e sporcherebbe la data di modifica.
    """
    global _ultime_zone
    ora = time.monotonic()
    if ora - _ultime_zone < ZONE_SECONDS:
        return
    _ultime_zone = ora

    try:
        req = urllib.request.Request(f"{SITE_URL}/api/zone")
        if API_KEY:
            req.add_header("X-API-Key", API_KEY)
        with urllib.request.urlopen(req, timeout=10) as risposta:
            testo = risposta.read().decode("utf-8")
    except Exception as e:
        print(f"ERRORE scaricamento zone: {e}", file=sys.stderr)
        return

    if not testo.strip():
        return

    percorso = os.path.join(ZOMBOID_DIR, "Lua", "ITAPz_Zone.txt")
    try:
        if os.path.exists(percorso):
            with open(percorso, "r", encoding="utf-8") as f:
                if f.read() == testo:
                    return
        os.makedirs(os.path.dirname(percorso), exist_ok=True)
        with open(percorso, "w", encoding="utf-8", newline="\n") as f:
            f.write(testo)
        print(f"zone aggiornate: {len(testo.strip().splitlines())} righe in {percorso}")
    except Exception as e:
        print(f"ERRORE scrittura zone: {e}", file=sys.stderr)


_ultime_disband = 0.0
DISBAND_SECONDS = int(os.environ.get("DISBAND_SECONDS", "60"))


def push_disband():
    """Scarica l'elenco delle fazioni rimosse e lo scrive dove la mod lo legge.

    Mirror della blocklist del sito: la mod prova a sciogliere ogni fazione
    elencata. Anche un elenco vuoto va scritto — cosi' una fazione ripristinata
    esce dal file e la mod smette. Si riscrive solo se cambia.
    """
    global _ultime_disband
    ora = time.monotonic()
    if ora - _ultime_disband < DISBAND_SECONDS:
        return
    _ultime_disband = ora

    try:
        req = urllib.request.Request(f"{SITE_URL}/api/factions/blocklist")
        if API_KEY:
            req.add_header("X-API-Key", API_KEY)
        with urllib.request.urlopen(req, timeout=10) as risposta:
            testo = risposta.read().decode("utf-8")
    except Exception as e:
        print(f"ERRORE scaricamento blocklist fazioni: {e}", file=sys.stderr)
        return

    percorso = os.path.join(ZOMBOID_DIR, "Lua", "ITAPz_Disband.txt")
    try:
        if os.path.exists(percorso):
            with open(percorso, "r", encoding="utf-8") as f:
                if f.read() == testo:
                    return
        os.makedirs(os.path.dirname(percorso), exist_ok=True)
        with open(percorso, "w", encoding="utf-8", newline="\n") as f:
            f.write(testo)
        n = len([r for r in testo.splitlines() if r.strip()])
        print(f"blocklist fazioni aggiornata: {n} nomi in {percorso}")
    except Exception as e:
        print(f"ERRORE scrittura blocklist fazioni: {e}", file=sys.stderr)


def tick():
    push_heartbeat()
    push_log()
    push_zone()
    push_disband()

    try:
        esito = check_mods()
        if esito:
            print(f"mod check: {esito}")
    except Exception as e:
        print(f"ERRORE check mod: {e}", file=sys.stderr)
    try:
        esito = scadenza_mod_restart()
        if esito:
            print(f"mod restart: {esito}")
    except Exception as e:
        print(f"ERRORE scadenza mod restart: {e}", file=sys.stderr)

    try:
        data = http_json(f"{SITE_URL}/api/server-control")
    except Exception as e:
        print(f"ERRORE lettura coda: {e}", file=sys.stderr)
        return

    for cmd in data.get("commands", []):
        try:
            output, status = execute(cmd), "DONE"
            print(f"DONE  {cmd['type']} {cmd.get('payload','')[:60]}")
        except Exception as e:
            output, status = str(e), "FAILED"
            print(f"FAIL  {cmd['type']}: {e}", file=sys.stderr)

        try:
            http_json(
                f"{SITE_URL}/api/server-control",
                method="POST",
                payload={"id": cmd["id"], "status": status, "output": output[:20000]},
            )
        except Exception as e:
            print(f"ERRORE invio esito ({cmd['id']}): {e}", file=sys.stderr)


def main():
    loop = "--loop" in sys.argv
    if not loop:
        tick()
        return 0
    print(f"ITAPz agent avviato (poll {POLL_SECONDS}s, servizio {PZ_SERVICE})")
    while True:
        tick()
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main() or 0)
