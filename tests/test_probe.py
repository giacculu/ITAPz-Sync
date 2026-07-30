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


def test_primo_avvio_conta_uno():
    probe = load_probe(ALL_EVENTS)
    assert probe.has("ITAPZ_PROBE_MODDATA fase=load avvii=1 precedente=nil stato=ok")


def test_riavvio_incrementa_il_contatore():
    # simula un riavvio: il ModData contiene gia' un avvio precedente
    probe = load_probe(ALL_EVENTS, moddata={"ITAPz_Probe": {"boots": 1}})
    assert probe.has("ITAPZ_PROBE_MODDATA fase=load avvii=2")
    assert probe.has("stato=ok")


def test_contatore_scritto_nel_moddata():
    probe = load_probe(ALL_EVENTS, moddata={"ITAPz_Probe": {"boots": 4}})
    assert probe.moddata["ITAPz_Probe"]["boots"] == 5


def test_moddata_rotto_non_blocca_la_sonda():
    probe = load_probe(ALL_EVENTS, moddata_broken=True)
    assert probe.has("ITAPZ_PROBE_MODDATA fase=load stato=non-disponibile")
    # gli hook devono essere stati registrati lo stesso
    assert probe.has("ITAPZ_PROBE_HOOK OnPlayerDeath registrato")


def test_moddata_fase_init_dopo_oninitglobalmoddata():
    # OnInitGlobalModData e' l'evento che PZ usa per confermare che il
    # salvataggio e' stato deserializzato: la lettura fatta al bootstrap
    # (fase=load) e' sempre vuota, quella fatta qui e' quella affidabile.
    probe = load_probe(ALL_EVENTS + ["OnInitGlobalModData"])
    assert probe.has("ITAPZ_PROBE_MODDATA fase=load avvii=1")
    probe.fire("OnInitGlobalModData")
    assert probe.has("ITAPZ_PROBE_MODDATA fase=init avvii=2")


def test_rapporto_dopo_la_soglia_di_scatti():
    probe = load_probe(ALL_EVENTS)
    for _ in range(25):
        probe.fire("OnHitZombie")
    assert probe.has("ITAPZ_PROBE_REPORT")
    assert probe.has("OnHitZombie=25")


def test_rapporto_non_a_ogni_scatto():
    probe = load_probe(ALL_EVENTS)
    for _ in range(75):
        probe.fire("OnHitZombie")
    # con soglia 25: rapporti al 25esimo, 50esimo e 75esimo
    assert probe.count("ITAPZ_PROBE_REPORT") == 3


def test_rapporto_include_gli_hook_mai_scattati():
    probe = load_probe(ALL_EVENTS)
    for _ in range(25):
        probe.fire("OnHitZombie")
    assert probe.has("LevelPerk=0")


def test_nessun_rapporto_senza_scatti():
    probe = load_probe(ALL_EVENTS)
    assert not probe.has("ITAPZ_PROBE_REPORT")


def test_first_riporta_il_giocatore_se_disponibile():
    # Un achievement deve sapere A CHI attribuire l'evento: se l'argomento
    # e' un oggetto con getUsername(), la riga FIRST deve nominarlo.
    probe = load_probe(ALL_EVENTS)
    probe._lua.execute("""
    __test_player = { __class = "IsoPlayer" }
    function __test_player:getUsername() return "Mario" end
    """)
    player = probe._lua.globals()["__test_player"]
    probe.fire("OnPlayerDeath", player)
    assert probe.has("ITAPZ_PROBE_FIRST OnPlayerDeath")
    assert probe.has("args=player:Mario")


def test_first_nomina_lo_zombie_senza_chiamare_getclass():
    # Il caso che in produzione riempiva il log di stack trace: su un IsoZombie
    # getClass():getSimpleName() solleva un'eccezione dentro Kahlua, e il pcall
    # la cattura ma PZ la registra lo stesso accendendo l'icona di errore.
    probe = load_probe(ALL_EVENTS)
    probe._lua.execute("""
    __test_zombie = { __class = "IsoZombie" }
    function __test_zombie:getClass() error("attempted index: getSimpleName") end
    function __test_zombie:getUsername() error("non esiste sugli zombie") end
    """)
    zombie = probe._lua.globals()["__test_zombie"]
    probe.fire("OnZombieDead", zombie)
    assert probe.has("args=zombie,nil,nil")


def test_argomento_di_tipo_sconosciuto_non_esplode():
    probe = load_probe(ALL_EVENTS)
    probe._lua.execute("""
    __test_boh = { __class = "QualcosAltro" }
    function __test_boh:getClass() error("boom") end
    """)
    probe.fire("OnMakeItem", probe._lua.globals()["__test_boh"])
    assert probe.has("ITAPZ_PROBE_FIRST OnMakeItem")
    assert probe.has("args=table,nil,nil")


def test_first_riporta_nil_senza_argomenti():
    # Se l'evento scatta senza argomenti (o il chiamante non ne fornisce),
    # la riga deve dirlo esplicitamente invece di nasconderlo.
    probe = load_probe(ALL_EVENTS)
    probe.fire("OnPlayerDeath")
    assert probe.has("args=nil,nil,nil")
