"""Riavvio automatico per mod da aggiornare, provato sull'agent vero."""

import os
import importlib.util

BRIDGE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "bridge", "itapz-agent.py"
)


def carica_agent(monkeypatch, tmp_path):
    """Importa l'agent come modulo, con percorsi e orologio pilotabili."""
    spec = importlib.util.spec_from_file_location("itapz_agent_test", BRIDGE)
    agent = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(agent)
    monkeypatch.setattr(agent, "MOD_RESTART_PATH", str(tmp_path / "ITAPz_ModRestart.txt"))
    return agent


def test_rileva_il_testo_di_aggiornamento(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    assert agent.rileva_mod_aggiornamento("Some mods Need Update")
    assert agent.rileva_mod_aggiornamento("Mods need update")
    assert agent.rileva_mod_aggiornamento("mods need update for 3774019032")


def test_non_rileva_output_pulito(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    assert not agent.rileva_mod_aggiornamento("No mods need update")
    assert not agent.rileva_mod_aggiornamento("")


def test_check_mods_preavvisa_e_salva(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    chiamate = []

    def finto_rcon(cmd):
        chiamate.append(cmd)
        if cmd == "checkModsNeedUpdate":
            return "Some mods Need Update"
        return "ok"

    monkeypatch.setattr(agent, "run_rcon", finto_rcon)
    monkeypatch.setattr(agent, "_ultimo_mod_check", 0.0)

    esito = agent.check_mods(ora=1000.0)

    assert any(c.startswith("servermsg") and "riavvio" in c for c in chiamate)
    assert "save" in chiamate
    assert "checkModsNeedUpdate" in chiamate
    assert os.path.exists(agent.MOD_RESTART_PATH)
    contenuto = open(agent.MOD_RESTART_PATH, encoding="utf-8").read().strip()
    atteso = int(1000 + agent.MOD_RESTART_MINUTES * 60)
    assert int(contenuto) == atteso
    assert "pendente" in esito


def test_check_mods_non_ripete_se_gia_pendente(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    chiamate = []

    def finto_rcon(cmd):
        chiamate.append(cmd)
        return "Some mods Need Update"

    with open(agent.MOD_RESTART_PATH, "w", encoding="utf-8") as f:
        f.write("2000")

    monkeypatch.setattr(agent, "run_rcon", finto_rcon)
    monkeypatch.setattr(agent, "_ultimo_mod_check", 0.0)

    agent.check_mods(ora=1000.0)

    assert "save" not in chiamate, "con un riavvio gia' pendente non si risalva"
    assert not any(c.startswith("servermsg") for c in chiamate)


def test_check_mods_niente_di_nuovo(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    monkeypatch.setattr(
        agent, "run_rcon", lambda cmd: "No mods need update"
    )
    monkeypatch.setattr(agent, "_ultimo_mod_check", 0.0)
    esito = agent.check_mods(ora=1000.0)
    assert not os.path.exists(agent.MOD_RESTART_PATH)
    assert "nessuna" in esito


def test_check_mods_rispetta_il_timer(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    chiamate = []
    monkeypatch.setattr(
        agent, "run_rcon", lambda cmd: (chiamate.append(cmd), "Some Need Update")[1]
    )
    monkeypatch.setattr(agent, "_ultimo_mod_check", 500.0)
    agent.check_mods(ora=505.0)  # 5 secondi dopo: meno di MOD_CHECK_MINUTES
    assert not chiamate, "il check non deve girare prima dell'intervallo"


def test_check_mods_rcon_non_risponde(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)

    def finto_rcon(cmd):
        raise RuntimeError("server spento")

    monkeypatch.setattr(agent, "run_rcon", finto_rcon)
    monkeypatch.setattr(agent, "_ultimo_mod_check", 0.0)
    esito = agent.check_mods(ora=1000.0)
    assert not os.path.exists(agent.MOD_RESTART_PATH)
    assert "fallito" in esito


def test_scadenza_accoda_il_restart(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    with open(agent.MOD_RESTART_PATH, "w", encoding="utf-8") as f:
        f.write("1000")

    inviati = []

    def finto_http(url, method="GET", payload=None):
        if url.endswith("/api/server-control/schedule"):
            inviati.append(payload)
            return {"ok": True, "id": "abc"}
        return {}

    monkeypatch.setattr(agent, "http_json", finto_http)

    esito = agent.scadenza_mod_restart(ora=1500.0)

    assert len(inviati) == 1
    assert inviati[0] == {"type": "RESTART", "requestedBy": "mod da aggiornare"}
    assert not os.path.exists(agent.MOD_RESTART_PATH)
    assert "accodato" in esito


def test_scadenza_non_ancora_maturata(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    with open(agent.MOD_RESTART_PATH, "w", encoding="utf-8") as f:
        f.write("2000")

    inviati = []
    monkeypatch.setattr(
        agent, "http_json", lambda *a, **k: inviati.append(1) or {}
    )
    agent.scadenza_mod_restart(ora=1500.0)
    assert not inviati, "prima del target non si accoda nulla"
    assert os.path.exists(agent.MOD_RESTART_PATH)


def test_scadenza_file_resta_se_la_post_fallisce(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    with open(agent.MOD_RESTART_PATH, "w", encoding="utf-8") as f:
        f.write("1000")

    def finto_http(*a, **k):
        raise RuntimeError("sito giu'")

    monkeypatch.setattr(agent, "http_json", finto_http)
    esito = agent.scadenza_mod_restart(ora=1500.0)
    assert os.path.exists(agent.MOD_RESTART_PATH), "il file deve restare per riprovare"
    assert "riprovera'" in esito


def test_tick_chiama_check_e_scadenza(monkeypatch, tmp_path):
    agent = carica_agent(monkeypatch, tmp_path)
    visti = []

    def finto_rcon(cmd):
        visti.append(("rcon", cmd))
        return "No mods need update"

    def finto_http(url, method="GET", payload=None):
        if url.endswith("/api/server-control"):
            return {"commands": []}
        return {}

    def finto_check(ora=None):
        visti.append(("check", ora))
        return "check"

    def finto_scadenza(ora=None):
        visti.append(("scadenza", ora))
        return "scadenza"

    monkeypatch.setattr(agent, "run_rcon", finto_rcon)
    monkeypatch.setattr(agent, "http_json", finto_http)
    monkeypatch.setattr(agent, "check_mods", finto_check)
    monkeypatch.setattr(agent, "scadenza_mod_restart", finto_scadenza)
    monkeypatch.setattr(agent, "push_heartbeat", lambda: None)
    monkeypatch.setattr(agent, "push_log", lambda: None)
    monkeypatch.setattr(agent, "push_zone", lambda: None)
    monkeypatch.setattr(agent, "push_disband", lambda: None)

    agent.tick()

    assert any(k == "check" for k, _ in visti), "il tick deve fare il check mod"
    assert any(k == "scadenza" for k, _ in visti), "il tick deve gestire la scadenza"


def test_tick_stampa_lesito_del_check(monkeypatch, tmp_path, capsys):
    agent = carica_agent(monkeypatch, tmp_path)

    monkeypatch.setattr(agent, "check_mods", lambda ora=None: "mod check: nessuna mod da aggiornare")
    monkeypatch.setattr(agent, "scadenza_mod_restart", lambda ora=None: "")
    monkeypatch.setattr(agent, "http_json", lambda *a, **k: {"commands": []})
    monkeypatch.setattr(agent, "push_heartbeat", lambda: None)
    monkeypatch.setattr(agent, "push_log", lambda: None)
    monkeypatch.setattr(agent, "push_zone", lambda: None)
    monkeypatch.setattr(agent, "push_disband", lambda: None)

    agent.tick()

    assert "mod check: nessuna mod da aggiornare" in capsys.readouterr().out
