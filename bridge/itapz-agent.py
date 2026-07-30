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
  LOG_LINES       righe di log inviate      (default 300)
  POLL_SECONDS    intervallo in loop        (default 3)
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

SITE_URL = os.environ.get("SITE_URL", "http://localhost:3000").rstrip("/")
API_KEY = os.environ.get("API_KEY", "")
RCON_HOST = os.environ.get("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("RCON_PORT", "27015"))
RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "")
PZ_SERVICE = os.environ.get("PZ_SERVICE", "pzserver")
PZ_CONFIG = os.environ.get(
    "PZ_CONFIG", "/home/administrator/Zomboid/Server/servertest.ini"
)
PZ_LOG = os.environ.get("PZ_LOG", "/home/administrator/Zomboid/server-console.txt")
LOG_LINES = int(os.environ.get("LOG_LINES", "300"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "3"))

# --- RCON (protocollo Source, solo libreria standard) -----------------------
import socket
import struct

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2


class Rcon:
    def __init__(self, host, port, password, timeout=10):
        self.sock = socket.create_connection((host, port), timeout=timeout)
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
        req_id = self._send(SERVERDATA_AUTH, password)
        res_id, _, _ = self._recv()
        if res_id == -1:
            raise RuntimeError("password RCON errata")
        if res_id != req_id:
            res_id, _, _ = self._recv()
            if res_id == -1:
                raise RuntimeError("password RCON errata")

    def command(self, cmd):
        self._send(SERVERDATA_EXECCOMMAND, cmd)
        _, _, body = self._recv()
        return body.strip()

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
    raise RuntimeError(f"tipo comando sconosciuto: {t}")


def tick():
    push_log()

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
