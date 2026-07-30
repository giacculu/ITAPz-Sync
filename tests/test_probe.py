from harness import ALL_EVENTS, load_probe


def test_registra_gli_hook_presenti():
    probe = load_probe(ALL_EVENTS)
    for name in ALL_EVENTS:
        assert probe.has(f"ITAPZ_PROBE_HOOK {name} registrato"), f"{name} non registrato"


def test_segnala_gli_hook_assenti():
    probe = load_probe(["OnPlayerDeath"])
    assert probe.has("ITAPZ_PROBE_HOOK OnPlayerDeath registrato")
    assert probe.has("ITAPZ_PROBE_HOOK LevelPerk ASSENTE")


def test_non_esplode_senza_events():
    probe = load_probe([])
    assert probe.has("ITAPZ_PROBE_HOOK OnPlayerDeath ASSENTE")


def test_primo_scatto_annunciato_una_sola_volta():
    probe = load_probe(ALL_EVENTS)
    probe.fire("OnPlayerDeath")
    probe.fire("OnPlayerDeath")
    probe.fire("OnPlayerDeath")
    assert probe.count("ITAPZ_PROBE_FIRST OnPlayerDeath") == 1


def test_hook_diversi_annunciati_separatamente():
    probe = load_probe(ALL_EVENTS)
    probe.fire("OnPlayerDeath")
    probe.fire("OnMakeItem")
    assert probe.has("ITAPZ_PROBE_FIRST OnPlayerDeath")
    assert probe.has("ITAPZ_PROBE_FIRST OnMakeItem")


def test_hook_mai_scattato_non_annunciato():
    probe = load_probe(ALL_EVENTS)
    probe.fire("OnPlayerDeath")
    assert not probe.has("ITAPZ_PROBE_FIRST LevelPerk")
