"""Riavvio automatico per mod da aggiornare, provato sull'agent vero."""

import os
import sys
import importlib.util

import pytest

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
