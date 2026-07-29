#!/usr/bin/env python3
"""
ITAPz Reporter Bridge
Legge i dati dal mod ITAPz_Sync (file JSON) e/o dal Zomboid Server Stats Reporter
e li inoltra al sito ITAPz.

Installazione:
  1. Copia questo script sul server PZ
  2. Imposta le variabili d'ambiente o modifica il config qui sotto
  3. Esegui con cron / systemd timer ogni 5 minuti:
     python3 reporter-bridge.py

Variabili d'ambiente:
  ITAPZ_SITE_URL      - URL del sito (default: https://italianpz.it)
  ITAPZ_API_KEY       - Chiave API per l'autenticazione
  ITAPZ_DATA_FILE     - Path del file JSON generato dal mod (auto-rilevato)
  ZOMBOID_REPORTER_URL - URL del reporter (opzionale, per dati server)
"""

import json
import os
import sys
import glob
import time
import urllib.request
import urllib.error

# Configurazione (sovrascrivibile da env)
SITE_URL = os.environ.get("ITAPZ_SITE_URL", "https://italianpz.it")
API_KEY = os.environ.get("ITAPZ_API_KEY", "")
DATA_FILE = os.environ.get("ITAPZ_DATA_FILE", "")
REPORTER_URL = os.environ.get("ZOMBOID_REPORTER_URL", "")

SYNC_ENDPOINT = f"{SITE_URL.rstrip('/')}/api/sync-server-data"
REPORTER_ENDPOINT = f"{SITE_URL.rstrip('/')}/api/reporter"


def find_data_file():
    """Cerca automaticamente il file JSON del mod."""
    if DATA_FILE and os.path.exists(DATA_FILE):
        return DATA_FILE

    # Cerca in posizioni comuni
    search_paths = [
        os.path.expanduser("~/Zomboid/Server/"),
        os.path.expanduser("~/Zomboid/"),
        ".",
        os.path.join(os.path.dirname(__file__), ".."),
    ]

    for base in search_paths:
        candidate = os.path.join(base, "itapz_sync_data.json")
        if os.path.exists(candidate):
            return candidate

    return None


def read_data_file(path):
    """Legge il file JSON prodotto dal mod."""
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"[Bridge] Errore lettura file: {e}", file=sys.stderr)
        return None


def send_post(url, data, api_key=""):
    """Invia una POST JSON."""
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["X-API-Key"] = api_key

    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")
    except Exception as e:
        return None, str(e)


def fetch_reporter():
    """Recupera i dati dal Zomboid Server Stats Reporter."""
    if not REPORTER_URL:
        return None

    api_url = f"{REPORTER_URL.rstrip('/')}/getserver"
    players_url = f"{REPORTER_URL.rstrip('/')}/getplayers"

    data = {"server": None, "players": None}

    try:
        with urllib.request.urlopen(api_url, timeout=5) as resp:
            data["server"] = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"[Bridge] Reporter server fetch fallito: {e}", file=sys.stderr)

    try:
        with urllib.request.urlopen(players_url, timeout=5) as resp:
            data["players"] = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"[Bridge] Reporter players fetch fallito: {e}", file=sys.stderr)

    return data


def main():
    print(f"[Bridge] ITAPz Reporter Bridge")
    print(f"[Bridge] Sito: {SITE_URL}")

    # 1. Leggi dati dal mod
    data_path = find_data_file()
    if data_path:
        print(f"[Bridge] File mod trovato: {data_path}")
        mod_data = read_data_file(data_path)
        if mod_data:
            print(f"[Bridge] Invio {len(mod_data.get('players', []))} giocatori...")
            code, body = send_post(SYNC_ENDPOINT, mod_data, API_KEY)
            if code and 200 <= code < 300:
                print(f"[Bridge] OK ({code})")
            else:
                print(f"[Bridge] Fallito ({code}): {body}", file=sys.stderr)
    else:
        print("[Bridge] Nessun file mod trovato, skip sync")

    # 2. Invia dati reporter (se configurato)
    if REPORTER_URL:
        print(f"[Bridge] Reporter URL: {REPORTER_URL}")
        reporter_data = fetch_reporter()
        if reporter_data and (reporter_data["server"] or reporter_data["players"]):
            print(f"[Bridge] Invio dati reporter...")
            payload = {"reporter": reporter_data}
            code, body = send_post(REPORTER_ENDPOINT, payload, API_KEY)
            if code and 200 <= code < 300:
                print(f"[Bridge] Reporter OK ({code})")
            else:
                print(f"[Bridge] Reporter fallito ({code}): {body}", file=sys.stderr)

    print("[Bridge] Completato")


if __name__ == "__main__":
    main()
