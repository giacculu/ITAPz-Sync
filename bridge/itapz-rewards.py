#!/usr/bin/env python3
"""
ITAPz — consegna ricompense in gioco.

Il sito mette in coda gli oggetti riscattati (battlepass / ruota); questo script
li preleva, li consegna al giocatore con `additem` via RCON e riporta l'esito.

Nessuna dipendenza esterna: implementa il protocollo Source RCON con la sola
libreria standard.

Uso (cron, ogni minuto):
  * * * * * SITE_URL=http://localhost:3000 RCON_PASSWORD=xxx /usr/local/bin/itapz-rewards.py >> /var/log/itapz-rewards.log 2>&1

Variabili:
  SITE_URL       URL del sito ITAPz            (default http://localhost:3000)
  API_KEY        deve combaciare con SYNC_API_KEY del sito (obbligatoria)
  RCON_HOST      host del server PZ            (default 127.0.0.1)
  RCON_PORT      porta RCON                    (default 27015)
  RCON_PASSWORD  password RCON                 (obbligatoria)
  ZOMBOID_DIR    cartella dati del gioco       (default ~/Zomboid)
  NOTIFY_PATH    file delle notifiche private  (default
                 $ZOMBOID_DIR/Lua/ITAPz_Notify.txt)
"""

import json
import os
import re
import socket
import struct
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# La notifica privata in gioco e' un bonus: se il modulo non c'e' (VPS non
# ancora aggiornata) la consegna dell'oggetto DEVE comunque funzionare.
try:
    from itapz_notify import append_notify
except ImportError:
    append_notify = None

SITE_URL = os.environ.get("SITE_URL", "http://localhost:3000").rstrip("/")
API_KEY = os.environ.get("API_KEY", "")
RCON_HOST = os.environ.get("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("RCON_PORT", "27015"))
RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "")
ZOMBOID_DIR = os.environ.get("ZOMBOID_DIR", os.path.expanduser("~/Zomboid"))
NOTIFY_PATH = os.environ.get("NOTIFY_PATH", os.path.join(ZOMBOID_DIR, "Lua", "ITAPz_Notify.txt"))

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2


class RconError(Exception):
    pass


class Rcon:
    """Client minimale del protocollo Source RCON."""

    def __init__(self, host, port, password, timeout=10):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.req_id = 0
        self._auth(password)

    def _send(self, msg_type, body):
        self.req_id += 1
        payload = struct.pack("<ii", self.req_id, msg_type) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)
        return self.req_id

    def _recv(self):
        raw_len = self._read_exactly(4)
        (length,) = struct.unpack("<i", raw_len)
        data = self._read_exactly(length)
        res_id, res_type = struct.unpack("<ii", data[:8])
        body = data[8:-2].decode("utf-8", errors="replace")
        return res_id, res_type, body

    def _read_exactly(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connessione RCON chiusa dal server")
            buf += chunk
        return buf

    def _auth(self, password):
        req_id = self._send(SERVERDATA_AUTH, password)
        res_id, _, _ = self._recv()
        # alcuni server rispondono con un pacchetto vuoto prima dell'auth
        if res_id == -1:
            raise RconError("password RCON errata")
        if res_id != req_id:
            res_id, _, _ = self._recv()
            if res_id == -1:
                raise RconError("password RCON errata")

    def command(self, cmd):
        self._send(SERVERDATA_EXECCOMMAND, cmd)
        _, _, body = self._recv()
        return body.strip()

    def online_players(self):
        """Elenco dei giocatori connessi (comando `players`).

        L'output cambia fra versioni: il piu' comune e':
            Players connected (1):
            -giacculu
        ma i nomi possono avere prefissi diversi ("[01]", "•", "1.", spazi).
        Si scarta l'intestazione e si normalizza il resto, cosi' un nome non
        letto non fa dichiarare "offline" un giocatore che c'e'.
        """
        reply = self.command("players")
        names = []
        for line in reply.splitlines():
            s = line.strip()
            if not s or "connected" in s.lower():
                continue
            nome = re.sub(r"^[-•>*\[\]\(\),\d\s:]+", "", s).strip()
            if nome:
                names.append(nome)
        return names

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def http_json(url, method="GET", payload=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json")
    if API_KEY:
        req.add_header("X-API-Key", API_KEY)
    data = json.dumps(payload).encode() if payload is not None else None
    with urllib.request.urlopen(req, data=data, timeout=20) as res:
        raw = res.read().decode()
        return json.loads(raw) if raw else {}


def main():
    if not RCON_PASSWORD:
        print("ERRORE: RCON_PASSWORD non impostata", file=sys.stderr)
        return 1

    try:
        data = http_json(f"{SITE_URL}/api/rewards/pending")
    except urllib.error.HTTPError as e:
        print(f"ERRORE lettura coda: HTTP {e.code}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"ERRORE lettura coda: {e}", file=sys.stderr)
        return 1

    deliveries = data.get("deliveries", [])
    if not deliveries:
        return 0

    try:
        rcon = Rcon(RCON_HOST, RCON_PORT, RCON_PASSWORD)
    except Exception as e:
        print(f"ERRORE connessione RCON: {e}", file=sys.stderr)
        return 1

    try:
        # additem funziona solo su giocatori connessi: chi è offline resta in
        # coda (PENDING) e verrà servito al prossimo accesso.
        try:
            online = rcon.online_players()
        except Exception as e:
            print(f"ERRORE lettura giocatori online: {e}", file=sys.stderr)
            return 1
        online_lower = {n.lower() for n in online}

        for d in deliveries:
            player = d["playerName"]
            item = d["itemId"]
            qty = int(d.get("quantity", 1) or 1)

            if player.lower() not in online_lower:
                print(f"IN ATTESA: {player} offline, {item} resta in coda")
                continue

            cmd = f'additem "{player}" "{item}" {qty}'
            try:
                reply = rcon.command(cmd)
                low = reply.lower()
                ok = not any(w in low for w in ("unknown", "error", "not found", "no such"))
                status = "DELIVERED" if ok else "FAILED"
                print(f"{status}: {player} <- {item} x{qty} :: {reply}")
                if ok:
                    # Messaggio privato in gioco: la mod lo consegna solo a lui.
                    if append_notify is not None:
                        etichetta = (d.get("message") or item).strip()
                        append_notify(
                            NOTIFY_PATH,
                            f"delivery-{d['id']}",
                            player,
                            f"Hai ricevuto: {etichetta} x{qty}",
                        )
            except Exception as e:
                status, reply = "FAILED", str(e)
                print(f"FAILED: {player} <- {item} :: {reply}", file=sys.stderr)

            try:
                http_json(
                    f"{SITE_URL}/api/rewards/complete",
                    method="POST",
                    payload={"id": d["id"], "status": status, "message": reply[:300]},
                )
            except Exception as e:
                print(f"ERRORE nel riportare l'esito ({d['id']}): {e}", file=sys.stderr)
    finally:
        rcon.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
