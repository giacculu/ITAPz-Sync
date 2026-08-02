#!/usr/bin/env python3
"""
ITAPz — coda di notifiche private in gioco.

Il sito e il bridge non possono scrivere un messaggio diretto a un giocatore
via RCON (non esiste un comando "whisper"): il canale e' la mod. L'agent (per
gli achievement) e il rewards (per le consegne) appendono una riga a
Zomboid/Lua/ITAPz_Notify.txt, l'unica cartella da cui il Lua del server sa
leggere; la mod la processa a ogni scatto del timer e manda sendServerCommand
al solo destinatario, che lo mostra in chat.

Formato, una riga per notifica:
    <id>\t<username>\t<message>

Il file e' solo "accodato" e tenuto corto: la mod ricorda i messaggi gia'
inviati in ModData, quindi le righe vecchie si possono buttare via.
"""

import os

try:
    import fcntl  # solo su Linux (la VPS): su Windows la scrittura resta senza lock
except ImportError:
    fcntl = None

MAX_LINES = 100  # oltre, si scartano le righe piu' vecchie


def _lock(f):
    if fcntl:
        fcntl.flock(f, fcntl.LOCK_EX)


def _unlock(f):
    if fcntl:
        fcntl.flock(f, fcntl.LOCK_UN)


def append_notify(path, notif_id, username, message):
    """Appende una notifica al file (con lock e tetto di righe).

    Tabelle e andate a capo vengono rimosse dai campi per non rompere il
    parsing della mod (separatore: tab).
    """
    message = str(message).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()
    username = str(username).replace("\t", " ").replace("\n", " ").strip()
    notif_id = str(notif_id).replace("\t", " ").replace("\n", " ").strip()
    if not notif_id or not username or not message:
        return

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a+", encoding="utf-8", newline="\n") as f:
        _lock(f)
        try:
            f.seek(0)
            lines = f.read().splitlines()
            lines.append(f"{notif_id}\t{username}\t{message}")
            if len(lines) > MAX_LINES:
                lines = lines[-MAX_LINES:]
            f.seek(0)
            f.truncate()
            f.write("\n".join(lines) + "\n")
            f.flush()
            os.fsync(f.fileno())
        finally:
            _unlock(f)
