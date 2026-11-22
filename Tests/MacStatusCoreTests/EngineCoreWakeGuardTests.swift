import XCTest
@testable import MacStatusCore

/// Correctif 0.6.1 (spec §12) : l'assertion de réveil est gardée jusqu'au déverrouillage (C15 révisée), et le
/// réveil d'un écran éteint sur session verrouillée est noté à l'oracle (C27). Horloge simulée, valeurs inventées.
///
/// Départ « D » : session verrouillée, écran éteint, `requestOn` à T0, écran rallumé, ON confirmé à T0 + 0,5.
final class EngineCoreWakeGuardTests: EngineCoreTestCase {
    private typealias AppelReveil = FakeActions.AppelReveil

    /// Départ D. Rend le moteur et T0.
    private func departD(_ config: Config = Config()) -> (core: EngineCore, t0: Double) {
        sessionVerrouilleeEcranEteint()
        let core = moteur(config)
        core.start()
        let t0 = horloge.t
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruterSansActivite(core, 0.5)
        return (core, t0)
    }

    /// Scrute par pas de 0,5 s jusqu'à `instant` inclus (l'horloge y arrive exactement).
    private func avancer(_ core: EngineCore, jusqu instant: Double) {
        while horloge.t < instant - 0.001 { scruterSansActivite(core, 0.5) }
    }

    private func lignesGardee() -> Int {
        journal.lines.filter { $0.1.hasPrefix("assertion de réveil gardée (") }.count
    }

    /// Économiseur SAC ouvert sur session `verrouillee`, puis écran éteint. Rend T0 (le `requestOn` est à faire).
    private func economiseurPuisEcranEteint(verrouillee: Bool) -> EngineCore {
        signaux.drapeauSAC = true
        signaux.etatSession.locked = verrouillee
        signaux.inactiviteHID = 300
        let core = moteur()
        core.start()
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState, "économiseur seul à l'écran : OFF")
        signaux.etatEcran.asleep = true
        scruterSansActivite(core, 0.5)
        return core
    }

    // 1
    func test_deverrouillage_relachement30sApres() {
        let (core, t0) = departD()
        XCTAssertEqual(actions.appelsReveil, [], "ON confirmé sur session verrouillée : l'assertion est gardée")
        avancer(core, jusqu: t0 + 4.5)
        signaux.etatSession.locked = false
        scruterSansActivite(core, 0.5)   // T0 + 5 : déverrouillage vu
        avancer(core, jusqu: t0 + 34.5)
        XCTAssertEqual(actions.appelsReveil, [], "T0 + 34,5 : 29,5 s après le déverrouillage")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "T0 + 35 : 30 s après le déverrouillage")
        XCTAssertTrue(journalContient("30 s après le déverrouillage)"), "\(journal.lines.map { $0.1 })")
        XCTAssertEqual(lignesGardee(), 1, "une seule ligne de retenue par réveil : \(journal.lines.map { $0.1 })")
        XCTAssertEqual(actions.appels, [.wake])
    }

    // 2
    func test_sansDeverrouillage_relachementAuPlafond() {
        let (core, t0) = departD()
        avancer(core, jusqu: t0 + 29.5)
        XCTAssertEqual(actions.appelsReveil, [], "T0 + 29,5 : sous le plafond")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "T0 + 30 : plafond")
        XCTAssertTrue(journalContient("plafond atteint)"), "\(journal.lines.map { $0.1 })")
        XCTAssertEqual(actions.appels, [.wake])
    }

    // 3
    func test_retenueDEcran60s_leplafondLaSuit() {
        let (core, t0) = departD(configRetenue(60))
        XCTAssertEqual(actions.appelsReveil, [.holdDisplay(60)], "T0 + 0,5")
        avancer(core, jusqu: t0 + 60)
        XCTAssertEqual(actions.appelsReveil, [.holdDisplay(60)], "T0 + 60 : le plafond suit la retenue")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.holdDisplay(60), .releaseWake], "T0 + 60,5")
    }

    // 4
    func test_faitsOff_relachementAussitot() {
        let (core, t0) = departD()
        avancer(core, jusqu: t0 + 14.5)
        XCTAssertEqual(actions.appelsReveil, [])
        signaux.etatEcran.asleep = true
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "T0 + 15 : faits OFF")
        XCTAssertTrue(journalContient("faits OFF)"), "\(journal.lines.map { $0.1 })")
    }

    // 5
    func test_commandeOff_relachementAussitot_puisPlusRien() {
        let (core, t0) = departD()
        avancer(core, jusqu: t0 + 10)
        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        XCTAssertTrue(journalContient("assertion de réveil relâchée (commande OFF)"))
        XCTAssertEqual(actions.appels, [.wake, .runOff(.displaySleep)])
        avancer(core, jusqu: t0 + 40)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "aucun autre relâchement jusqu'à T0 + 40")
    }

    // 6
    func test_secondReveil_repartDeZero() {
        let (core, t0) = departD()
        avancer(core, jusqu: t0 + 20)
        core.requestOn(peer: "essai")   // déjà ON : réveil léger
        XCTAssertEqual(actions.appels, [.wake, .wake])
        avancer(core, jusqu: t0 + 49.5)
        XCTAssertEqual(actions.appelsReveil, [], "T0 + 49,5 : 29,5 s après le second réveil")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "T0 + 50 : plafond du second réveil")
        XCTAssertTrue(journal.lines.contains { $0.1 == "assertion de réveil relâchée (réveil léger : évaluation suivante ; plafond atteint)" },
                      "\(journal.lines.map { $0.1 })")
        XCTAssertEqual(lignesGardee(), 2, "une ligne « gardée » par réveil : \(journal.lines.map { $0.1 })")
    }

    // 7
    func test_reveilSansIntention_sessionVerrouillee_gardeJusquAuPlafond() {
        signaux.etatSession.locked = true
        let core = moteur()
        core.start()
        signaux.pidEconomiseur = 4242
        for _ in 0..<4 { scruter(core, 0.5) }
        signaux.inactiviteHID = 0   // une frappe : le panneau est supposé visible
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState, "le panneau est supposé visible")
        let t0 = horloge.t
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
        avancer(core, jusqu: t0 + 4.5)
        signaux.pidEconomiseur = 0
        avancer(core, jusqu: t0 + 29.5)
        XCTAssertEqual(actions.appelsReveil, [], "l'économiseur est parti à T0 + 5 : l'assertion reste gardée")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "T0 + 30")
        XCTAssertTrue(journal.lines.contains { $0.1 == "assertion de réveil relâchée (réveil sans intention : économiseur parti ou délai écoulé ; plafond atteint)" },
                      "\(journal.lines.map { $0.1 })")
    }

    // 8
    func test_reverrouillage_ramenAuPlafond() {
        let (core, t0) = departD()
        avancer(core, jusqu: t0 + 4.5)
        signaux.etatSession.locked = false
        scruterSansActivite(core, 0.5)   // T0 + 5
        avancer(core, jusqu: t0 + 9.5)
        signaux.etatSession.locked = true
        scruterSansActivite(core, 0.5)   // T0 + 10
        avancer(core, jusqu: t0 + 29.5)
        XCTAssertEqual(actions.appelsReveil, [], "T0 + 29,5")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "T0 + 30 : le plafond, pas T0 + 35")
        XCTAssertTrue(journalContient("plafond atteint)"), "\(journal.lines.map { $0.1 })")
    }

    // 9
    func test_arret_relacheUneSeuleFois() {
        let (core, t0) = departD()
        avancer(core, jusqu: t0 + 10)
        var termines = 0
        core.shutdown(publishOff: false) { termines += 1 }
        XCTAssertEqual(termines, 1)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        avancer(core, jusqu: t0 + 40)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "plus rien après l'arrêt")
    }

    // 10
    func test_veille_relacheAussitot() {
        let (core, t0) = departD()
        avancer(core, jusqu: t0 + 10)
        core.willSleep {}
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "avant tout tick")
        XCTAssertTrue(journalContient("assertion de réveil relâchée (veille du système)"),
                      "\(journal.lines.map { $0.1 })")
    }

    // 11
    func test_deverrouillageSansCommande_puisReveilLeger_garde30s() {
        signaux.etatSession.locked = true
        let core = moteur()
        core.start()
        scruterSansActivite(core, 0.5)
        signaux.etatSession.locked = false
        scruterSansActivite(core, 0.5)
        let t1 = horloge.t
        avancer(core, jusqu: t1 + 5)
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        avancer(core, jusqu: t1 + 29.5)
        XCTAssertEqual(actions.appelsReveil, [], "T1 + 29,5")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "T1 + 30")
        XCTAssertTrue(journalContient("30 s après le déverrouillage)"), "\(journal.lines.map { $0.1 })")
    }

    // 13
    func test_reveilNoteAOracle_economiseurSurSessionVerrouillee() {
        let core = economiseurPuisEcranEteint(verrouillee: true)
        let t0 = horloge.t
        core.requestOn(peer: "essai")
        XCTAssertTrue(journalContient("réveil noté à l'oracle : panneau de connexion attendu"))
        signaux.etatEcran.asleep = false
        scruterSansActivite(core, 0.5)
        XCTAssertTrue(core.currentState, "ON confirmé à T0 + 0,5 : \(journal.lines.map { $0.1 })")
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-réveil")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertFalse(journalContient("escalade"), "\(journal.lines.map { $0.1 })")
        XCTAssertEqual(actions.appelsReveil, [], "assertion gardée")

        avancer(core, jusqu: t0 + 29.5)
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-réveil", "T0 + 29,5")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(preuveEconomiseur(core), "sac+réaffiché", "T0 + 30 : la preuve cède")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        XCTAssertTrue(journalContient("faits OFF)"), "\(journal.lines.map { $0.1 })")
        XCTAssertEqual(actions.appels, [.wake], "aucune escalade")
    }

    // 14
    func test_reveilNonNote_avecWakeCommand_escaladeComme060() {
        actions.hasWakeOverride = true
        let core = economiseurPuisEcranEteint(verrouillee: true)
        let t0 = horloge.t
        core.requestOn(peer: "essai")
        XCTAssertFalse(journalContient("réveil noté à l'oracle"))
        signaux.etatEcran.asleep = false
        avancer(core, jusqu: t0 + 2)
        XCTAssertEqual(actions.appels, [.wake], "T0 + 2")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "T0 + 2,5 : escalade")
        XCTAssertTrue(journalContient("escalade: écartement de l'économiseur"), "\(journal.lines.map { $0.1 })")
    }

    // 15
    func test_reveilNonNote_surSessionOuverte_escaladeComme060() {
        let core = economiseurPuisEcranEteint(verrouillee: false)
        let t0 = horloge.t
        core.requestOn(peer: "essai")
        XCTAssertFalse(journalContient("réveil noté à l'oracle"))
        signaux.etatEcran.asleep = false
        avancer(core, jusqu: t0 + 2)
        XCTAssertEqual(actions.appels, [.wake], "T0 + 2")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "T0 + 2,5 : escalade")
        XCTAssertTrue(journalContient("escalade: écartement de l'économiseur"), "\(journal.lines.map { $0.1 })")
    }

    // m4 : la retenue d'écran est posée avant la demande de relâchement gardé (§12 : plafond = fin de la retenue).
    func test_retenuePoseeAvantLaGarde_confirmationApresLePlafondDuReveil() {
        var config = configRetenue(60)
        config.commandConfirmTimeoutMS = 40000
        sessionVerrouilleeEcranEteint()
        let core = moteur(config)
        core.start()
        let t0 = horloge.t
        core.requestOn(peer: "essai")
        avancer(core, jusqu: t0 + 32.5)   // l'écran reste éteint : l'escalade de T0 + 2,5 a relancé le réveil
        XCTAssertEqual(actions.appelsReveil, [], "écran éteint : rien à retenir ni à relâcher")
        signaux.etatEcran.asleep = false
        scruterSansActivite(core, 0.5)    // T0 + 33 : ON confirmé, plafond du réveil (T0 + 32,5) dépassé
        XCTAssertEqual(actions.appelsReveil, [.holdDisplay(60)], "retenue posée, assertion gardée : \(journal.lines.map { $0.1 })")
        avancer(core, jusqu: t0 + 92.5)
        XCTAssertEqual(actions.appelsReveil, [.holdDisplay(60)], "T0 + 92,5 : fin de la retenue (T0 + 93) pas encore atteinte")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.holdDisplay(60), .releaseWake], "T0 + 93 : fin de la retenue")
    }
}
