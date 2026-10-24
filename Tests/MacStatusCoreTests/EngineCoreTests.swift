import XCTest
@testable import MacStatusCore

/// Tests de caractérisation du moteur d'état : ils figent le comportement de
/// l'ancien `StateEngine` (règles, lissage, commandes, escalade, resynchronisation,
/// battement de cœur) sans file, sans minuterie et sans le système.
///
/// L'horloge est pilotée à la main : chaque `scruter(_:)` avance le temps puis
/// joue un cycle de scrutation, comme le ferait la minuterie de l'exécuteur.
/// Les pas de 0,5 s sont exacts en binaire, pour que les bornes tombent juste.
final class EngineCoreTests: XCTestCase {
    private var horloge: TestClock!
    private var signaux: FakeSignals!
    private var actions: FakeActions!
    private var publieur: FakePublisher!
    private var journal: CaptureLog!
    private var ancienRecepteur: LogSink?

    override func setUp() {
        super.setUp()
        horloge = TestClock(t: 1000)
        signaux = Self.signauxDeBureau()
        actions = FakeActions()
        publieur = FakePublisher()
        journal = CaptureLog()
        ancienRecepteur = CoreLog.sink
        CoreLog.sink = journal
    }

    override func tearDown() {
        CoreLog.sink = ancienRecepteur
        super.tearDown()
    }

    /// Bureau ouvert, un écran, aucune activité depuis 30 s (en deçà du
    /// réaffichage à 90 s : un économiseur détecté reste seul à l'écran).
    private static func signauxDeBureau() -> FakeSignals {
        let signaux = FakeSignals()
        signaux.inactiviteHID = 30
        return signaux
    }

    /// Moteur câblé comme l'exécuteur le câble, mais sur les faux.
    private func moteur(_ config: Config = Config()) -> EngineCore {
        let oracle = ScreenSaverOracle(
            minimumInterval: max(1.0, Double(config.pollIntervalMS) / 1000),
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: Double(config.saverDismissGraceMS) / 1000,
            redisplayIdle: Double(config.saverRedisplayIdleSeconds),
            signals: signaux
        )
        return EngineCore(config: config, clock: horloge, signals: signaux, oracle: oracle,
                          actions: actions, publisher: publieur)
    }

    private func scruter(_ core: EngineCore, _ secondes: Double) {
        horloge.advance(secondes)
        core.tick()
    }

    private func commandeEnAttente(_ core: EngineCore) -> [String: Any]? {
        core.statusSnapshot()["pending_command"] as? [String: Any]
    }

    private func journalContient(_ fragment: String) -> Bool {
        journal.lines.contains { $0.1.contains(fragment) }
    }

    private typealias Publication = FakePublisher.Publication

    // MARK: - Règles

    /// Chaque ligne cumule ses faits avec ceux des lignes moins prioritaires :
    /// la règle attendue doit l'emporter sur toutes celles qui suivent.
    func test_prioriteDesRegles() {
        let bureau: (FakeSignals) -> Void = { _ in }
        let sansSession: (FakeSignals) -> Void = { $0.etatSession.loggedIn = false }
        let verrouille: (FakeSignals) -> Void = { sansSession($0); $0.etatSession.locked = true }
        let aucunEcran: (FakeSignals) -> Void = { verrouille($0); $0.etatEcran.onlineCount = 0 }
        let economiseur: (FakeSignals) -> Void = { aucunEcran($0); $0.pidEconomiseur = 4242 }
        let ecranEteint: (FakeSignals) -> Void = { economiseur($0); $0.etatEcran.asleep = true }

        func verdict(veille: Bool = false, _ preparer: (FakeSignals) -> Void) -> (etat: Bool, raison: String) {
            signaux = Self.signauxDeBureau()
            preparer(signaux)
            let core = moteur()
            if veille { core.willSleep {} }
            let resultat = core.inspect()
            return (resultat.state, resultat.reason)
        }

        let veille = verdict(veille: true, ecranEteint)
        XCTAssertEqual(veille.etat, false); XCTAssertEqual(veille.raison, "system-asleep")

        let eteint = verdict(ecranEteint)
        XCTAssertEqual(eteint.etat, false); XCTAssertEqual(eteint.raison, "display-asleep")

        let actif = verdict(economiseur)
        XCTAssertEqual(actif.etat, false); XCTAssertTrue(actif.raison.hasPrefix("screensaver:"), actif.raison)

        let sansEcran = verdict(aucunEcran)
        XCTAssertEqual(sansEcran.etat, false); XCTAssertEqual(sansEcran.raison, "no-display")

        // Sans énumération réussie, zéro écran ne prouve rien.
        let enumerationKO = verdict { $0.etatEcran.onlineCount = 0; $0.etatEcran.enumerationOK = false }
        XCTAssertEqual(enumerationKO.etat, true); XCTAssertEqual(enumerationKO.raison, "desktop-ui")

        let verrou = verdict(verrouille)
        XCTAssertEqual(verrou.etat, true); XCTAssertEqual(verrou.raison, "lock-screen-ui")

        let login = verdict(sansSession)
        XCTAssertEqual(login.etat, true); XCTAssertEqual(login.raison, "login-window-ui")

        let ouvert = verdict(bureau)
        XCTAssertEqual(ouvert.etat, true); XCTAssertEqual(ouvert.raison, "desktop-ui")
    }

    // MARK: - Lissage

    func test_lissage_offAttend800ms_onAttend300ms() {
        let core = moteur()
        core.start()
        // L'état initial est une transition (rien → ON) : publié sans `force`,
        // comme dans l'ancien `StateEngine`.
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)])

        // OFF : candidat à t+0,5 ; rien à 790 ms de stabilité, publié à 810 ms.
        signaux.etatEcran.asleep = true
        scruter(core, 0.5)
        scruter(core, 0.29)
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications.count, 1)
        XCTAssertTrue(core.currentState)
        scruter(core, 0.02)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: false))
        XCTAssertFalse(core.currentState)

        // ON : rien à 290 ms, publié à 310 ms.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        scruter(core, 0.29)
        XCTAssertEqual(publieur.publications.count, 2)
        XCTAssertFalse(core.currentState)
        scruter(core, 0.02)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: false))
        XCTAssertTrue(core.currentState)
    }

    // MARK: - Commandes

    func test_commandeOff_confirmeeParLesFaits() {
        let core = moteur()
        core.start()

        core.requestOff(source: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])
        // OFF publié tout de suite, sans attendre le lissage.
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: false))
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/screensaver")

        // L'économiseur démarre : les faits confirment la commande.
        signaux.pidEconomiseur = 4242
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande off/screensaver confirmée par les faits en 0.5 s"))
        XCTAssertFalse(core.currentState)

        // Plus aucune escalade ni publication une fois la commande confirmée.
        for _ in 0..<10 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false)])
    }

    func test_commandeSansEffet_escaladeA2500ms_puisRetourAuxFaitsA12s() {
        let core = moteur()
        core.start()
        core.requestOff(source: "essai")

        // Jusqu'à 2,0 s : pas d'escalade.
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])

        // À 2,5 s : une seule escalade, l'extinction de l'écran.
        scruter(core, 0.5)
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .displaySleep])
        XCTAssertEqual(commandeEnAttente(core)?["escalated"] as? Bool, true)

        // Jusqu'à 11,5 s : la commande tient l'état OFF.
        for _ in 0..<18 { scruter(core, 0.5) }
        XCTAssertFalse(core.currentState)
        XCTAssertNotNil(commandeEnAttente(core))

        // À 12 s : retour aux faits, puis ON après le lissage de 300 ms.
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande off/screensaver non confirmée après 12.0 s → retour aux faits (desktop-ui)"))
        XCTAssertFalse(core.currentState)
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)

        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .displaySleep])
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false),
                                               Publication(etat: true, force: false)])
    }

    func test_offSurSessionVerrouillee_eteintLEcran() {
        signaux.etatSession.locked = true
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        core.requestOff(source: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.displaySleep)])
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/display_sleep")

        // Avec une commande OFF personnalisée, l'action configurée est gardée.
        actions = FakeActions()
        actions.hasOffOverride = true
        let personnalise = moteur()
        personnalise.start()
        personnalise.requestOff(source: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])
    }

    func test_dejaOff_aucuneAction() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        XCTAssertFalse(core.currentState)
        let avant = publieur.publications

        core.requestOff(source: "essai")
        XCTAssertEqual(actions.appels, [])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertTrue(journalContient("commande OFF (essai) → déjà OFF (display-asleep), aucune action"))
    }

    // MARK: - Resynchronisation et battement de cœur

    func test_trouDeScrutation_au_dela_de_10s_resynchronise() {
        let core = moteur()
        core.start()
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications.count, 1)

        // Un trou de 9,5 s reste une scrutation normale.
        scruter(core, 9.5)
        XCTAssertEqual(publieur.publications.count, 1)

        // Au-delà de 10 s : republication forcée de l'état.
        scruter(core, 10.5)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: true))
        XCTAssertEqual(publieur.publications.count, 2)
        XCTAssertTrue(journalContient("interruption de 10.5 s détectée → resynchronisation"))

        // Une veille dont le réveil n'a pas été notifié est oubliée après le trou.
        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(autorisations, 1)
        XCTAssertFalse(core.currentState)
        scruter(core, 11)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: false))
    }

    func test_battementDeCoeur_republieAvecForce() {
        let core = moteur()
        // Rien à republier avant le premier état.
        core.heartbeat()
        XCTAssertEqual(publieur.publications, [])

        core.start()
        core.heartbeat()
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: true, force: true)])

        signaux.etatEcran.asleep = true
        scruter(core, 0.5)
        scruter(core, 1.0)
        core.heartbeat()
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: true))
    }

    // MARK: - Diagnostic

    /// Ruling R6 : le contexte de session vient des signaux, pas de CoreGraphics.
    func test_statusSnapshot_contexteDeSessionParLesSignaux() {
        signaux.sessionAqua = false
        let core = moteur()
        core.start()
        var instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["session_context"] as? String, "headless")
        XCTAssertEqual(instantane["state"] as? String, "1")
        XCTAssertEqual(instantane["reason"] as? String, "desktop-ui")
        XCTAssertEqual((instantane["webhook"] as? [String: Any])?["faux"] as? Bool, true)
        // L'horodatage affiché vient de l'heure murale.
        XCTAssertEqual(instantane["last_transition"] as? String,
                       ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_000_000)))

        signaux.sessionAqua = true
        horloge.advance(5)
        instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["session_context"] as? String, "aqua")
        XCTAssertEqual(instantane["uptime_seconds"] as? Int, 5)
    }
}
