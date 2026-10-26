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

    /// Moteur câblé comme l'exécuteur le câble, mais sur les faux. `ecoute` : ce que le serveur HTTP
    /// a annoncé de son port (`true` : détenu, `false` : occupé, `nil` : rien encore). Sans port
    /// détenu, le moteur ne publie rien (tâche 16).
    private func moteur(_ config: Config = Config(), ecoute: Bool? = true) -> EngineCore {
        let core = moteurBrut(config)
        if let ecoute { core.setListenerReady(ecoute) }
        return core
    }

    private func moteurBrut(_ config: Config = Config()) -> EngineCore {
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

    /// Option `require_auth_ui_when_locked` : une session verrouillée sans saisie
    /// sécurisée (pas de champ de mot de passe) est OFF. Cette règle passe après
    /// « aucun écran » et avant « écran de verrouillage visible ».
    func test_verrouilleSansSaisieSecurisee_donneLockedWithoutAuthUI() {
        var config = Config()
        config.requireAuthUIWhenLocked = true

        func verdict(_ config: Config, preparer: (FakeSignals) -> Void) -> (etat: Bool, raison: String) {
            signaux = Self.signauxDeBureau()
            preparer(signaux)
            let resultat = moteur(config).inspect()
            return (resultat.state, resultat.reason)
        }

        // Verrouillée, aucune saisie sécurisée : OFF.
        let sansChamp = verdict(config) { $0.etatSession.locked = true }
        XCTAssertEqual(sansChamp.etat, false); XCTAssertEqual(sansChamp.raison, "locked-without-auth-ui")

        // Priorité inférieure à « aucun écran » : celle-ci l'emporte.
        let sansEcran = verdict(config) { $0.etatSession.locked = true; $0.etatEcran.onlineCount = 0 }
        XCTAssertEqual(sansEcran.etat, false); XCTAssertEqual(sansEcran.raison, "no-display")

        // Priorité supérieure à « écran de verrouillage visible » : avec le champ
        // de mot de passe (saisie sécurisée), c'est lock-screen-ui qui reste.
        let avecChamp = verdict(config) { $0.etatSession.locked = true; $0.saisieSecurisee = true }
        XCTAssertEqual(avecChamp.etat, true); XCTAssertEqual(avecChamp.raison, "lock-screen-ui")

        // Option inactive (défaut) : la session verrouillée sans champ reste ON.
        let optionInactive = verdict(Config()) { $0.etatSession.locked = true }
        XCTAssertEqual(optionInactive.etat, true); XCTAssertEqual(optionInactive.raison, "lock-screen-ui")

        // Session déverrouillée : l'option n'agit pas.
        let deverrouillee = verdict(config) { _ in }
        XCTAssertEqual(deverrouillee.etat, true); XCTAssertEqual(deverrouillee.raison, "desktop-ui")
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

    // MARK: - Idempotence (tâche 9)

    func test_doublonOff_pendantUneCommandeOff_aucuneActionEtEcheanceInchangee() {
        let core = moteur()
        core.start()
        core.requestOff(source: "essai")
        let publications = publieur.publications

        // Doublons à 1 s et à 2 s : aucune action, la commande garde son origine.
        scruter(core, 0.5)
        scruter(core, 0.5)
        core.requestOff(source: "essai")
        scruter(core, 0.5)
        scruter(core, 0.5)
        core.requestOff(source: "autre")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])
        XCTAssertEqual(commandeEnAttente(core)?["age_seconds"] as? Int, 2)
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/screensaver")
        XCTAssertEqual(publieur.publications, publications)
        XCTAssertTrue(journalContient("commande OFF (essai) → commande OFF déjà en cours, ignorée"))

        // L'escalade tombe toujours à 2,5 s du premier OFF, le retour aux faits à 12 s.
        scruter(core, 0.5)
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .displaySleep])
        for _ in 0..<18 { scruter(core, 0.5) }
        XCTAssertNotNil(commandeEnAttente(core))
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("non confirmée après 12.0 s"))
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .displaySleep])
    }

    func test_doublonOn_pendantUneCommandeOn_aucuneAction() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        scruter(core, 0.5)
        core.requestOn(source: "essai")
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(commandeEnAttente(core)?["age_seconds"] as? Int, 0)
        XCTAssertTrue(journalContient("commande ON (essai) → commande ON déjà en cours, ignorée"))

        // Une fois la commande échue (retour aux faits), un nouvel ON agit de nouveau.
        for _ in 0..<24 { scruter(core, 0.5) }
        XCTAssertNil(commandeEnAttente(core))
        let avant = actions.appels.count
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels.count, avant + 1)
        XCTAssertEqual(actions.appels.last, .wake)
    }

    func test_onPuisOff_rapides_leDernierGagne() {
        // Écran éteint : ON puis OFF aussitôt. Les faits disent déjà OFF : l'intention ON
        // est remplacée, sans action OFF, et l'état reste OFF.
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(source: "essai")
        XCTAssertTrue(core.currentState)
        core.requestOff(source: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertFalse(core.currentState)
        for _ in 0..<30 { scruter(core, 0.5) }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(actions.appels, [.wake])
    }

    func test_offPuisOn_rapides_leDernierGagne() {
        // Bureau ouvert : OFF puis ON aussitôt. L'intention ON remplace l'intention OFF.
        let core = moteur()
        core.start()
        core.requestOff(source: "essai")
        XCTAssertFalse(core.currentState)
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .wake])
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false),
                                               Publication(etat: true, force: false)])
        // Les faits disent ON : confirmée au cycle suivant, et jamais d'escalade OFF.
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        for _ in 0..<30 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .wake])
    }

    func test_onQuandDejaOn_aucuneAction() {
        let core = moteur()
        core.start()
        let avant = publieur.publications
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertTrue(journalContient("commande ON (essai) → déjà ON (desktop-ui), aucune action"))

        // Les faits sont relus avant de décider : un écran éteint depuis le dernier cycle
        // n'est pas « déjà ON ».
        signaux.etatEcran.asleep = true
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertNotNil(commandeEnAttente(core))
    }

    func test_onSousUnEconomiseurEcarte_reveilSansIntention() {
        // R30 : l'oracle dit « écarté » (ON) jusqu'à 90 s après une frappe, alors que macOS a pu
        // revenir à l'économiseur. Tant qu'il tourne, /wake réveille quand même, sans intention.
        let core = moteur()
        core.start()
        signaux.pidEconomiseur = 4242
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertFalse(core.currentState)
        // Une frappe : le panneau d'authentification recouvre l'économiseur, qui tourne encore.
        signaux.inactiviteHID = 0
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        // 60 s sans activité : toujours « écarté » pour l'oracle (réaffichage à 90 s).
        for _ in 0..<120 {
            signaux.inactiviteHID += 0.5
            scruter(core, 0.5)
        }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["facts"].flatMap { ($0 as? [String: Any])?["screensaver_running"] as? Bool }, true)
        XCTAssertEqual(actions.appels, [])

        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(core.currentState)
        XCTAssertTrue(journalContient("économiseur en marche"), "\(journal.lines.map { $0.1 })")

        // Sans économiseur, le court-circuit « déjà ON » reste sans action.
        signaux.pidEconomiseur = 0
        scruter(core, 0.5)
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [.wake])
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

    /// Le seuil vaut `max(10, scrutation × 20 ms)` : à 1000 ms, 20 s.
    func test_seuilDeTrouDeScrutation_suitLIntervalleDeScrutation() {
        var config = Config()
        config.pollIntervalMS = 1000
        let core = moteur(config)
        core.start()
        scruter(core, 1)
        XCTAssertEqual(publieur.publications.count, 1)

        // 15 s dépassent le seuil de base (10 s) mais pas celui de 20 s.
        scruter(core, 15)
        XCTAssertEqual(publieur.publications.count, 1)
        XCTAssertFalse(journalContient("interruption de"))

        // 21 s : au-delà du seuil, resynchronisation forcée.
        scruter(core, 21)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: true))
        XCTAssertEqual(publieur.publications.count, 2)
        XCTAssertTrue(journalContient("interruption de 21.0 s détectée → resynchronisation"))
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

    // MARK: - Veille et réveil (tâche 13)

    /// Client webhook réel sur un transport simulé : la livraison et les délais sont pilotés
    /// par le test (`terminerEnAttente`, `runDue`).
    private func clientWebhook(_ transport: FakeTransport, _ planificateur: TestScheduler) -> WebhookClient {
        var config = Config()
        config.enabled = true
        config.webhookBaseURL = "http://192.0.2.10:51828/"
        config.accessoryID = "mac"
        return WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge)
    }

    private func clientWebhookDeuxCibles(_ transport: FakeTransport, _ planificateur: TestScheduler) -> WebhookClient {
        var config = Config()
        config.enabled = true
        config.webhookTargets = [WebhookTarget(url: "http://192.0.2.10:51828/", method: "GET", headers: [:]),
                                 WebhookTarget(url: "http://192.0.2.11:51828/", method: "GET", headers: [:])]
        config.accessoryID = "mac"
        return WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge)
    }

    private func moteur(publieur autre: StatePublisher) -> EngineCore {
        let core = moteurBrut(publieur: autre)
        core.setListenerReady(true)
        return core
    }

    private func moteurBrut(publieur autre: StatePublisher) -> EngineCore {
        let config = Config()
        let oracle = ScreenSaverOracle(
            minimumInterval: max(1.0, Double(config.pollIntervalMS) / 1000),
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: Double(config.saverDismissGraceMS) / 1000,
            redisplayIdle: Double(config.saverRedisplayIdleSeconds),
            signals: signaux
        )
        return EngineCore(config: config, clock: horloge, signals: signaux, oracle: oracle,
                          actions: actions, publisher: autre)
    }

    /// F11 : `/wake` réveille le Mac, puis IOKit annonce le réveil. Ce réveil n'efface plus la
    /// commande ON : elle tient l'état ON, s'escalade et attend la confirmation des faits.
    func test_reveilPendantUneCommandeOn_conserveLIntention() {
        let core = moteur()
        core.start()
        core.willSleep {}
        XCTAssertFalse(core.currentState)
        horloge.advance(40)

        // La commande arrive au sortir de la veille, écran encore éteint.
        signaux.etatEcran.asleep = true
        core.requestOn(source: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertTrue(core.currentState)

        core.handle(.systemDidWake)
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "on")
        XCTAssertEqual(commandeEnAttente(core)?["age_seconds"] as? Int, 0)
        XCTAssertTrue(core.currentState)
        // Le réveil système n'ajoute aucune action.
        XCTAssertEqual(actions.appels, [.wake])

        // L'écran reste éteint : la commande tient ON et s'escalade à 2,5 s.
        for _ in 0..<5 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(actions.appels, [.wake, .wake])
        XCTAssertEqual(commandeEnAttente(core)?["escalated"] as? Bool, true)

        // L'écran se rallume : les faits confirment la commande.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande on confirmée par les faits"))
        XCTAssertTrue(core.currentState)
    }

    /// F12 : `kIOMessageSystemWillNotSleep` (veille annulée) n'est pas un réveil. Il lève la
    /// veille, s'il y en avait une, par une évaluation lissée, sans effacer la commande en
    /// cours ni oublier une notification `didstart` de l'économiseur.
    func test_veilleAnnulee_neToucheNiIntentionNiNotification() {
        // Commande en cours : intacte.
        let core = moteur()
        core.start()
        core.requestOff(source: "essai")
        scruter(core, 0.5)
        let avant = publieur.publications
        core.handle(.systemWillNotSleep)
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/screensaver")
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])

        // Notification de l'économiseur : intacte (l'oracle des fenêtres ne tranche pas).
        signaux = Self.signauxDeBureau()
        signaux.fenetreEconomiseur = .unavailable
        publieur = FakePublisher()
        let autre = moteur()
        autre.start()
        autre.handle(.screenSaverDidStart)
        scruter(autre, 0.5)
        scruter(autre, 0.5)
        XCTAssertFalse(autre.currentState)
        XCTAssertEqual(autre.statusSnapshot()["reason"] as? String, "screensaver:notification")
        let publicationsAvant = publieur.publications
        autre.handle(.systemWillNotSleep)
        for _ in 0..<4 { scruter(autre, 0.5) }
        XCTAssertFalse(autre.currentState)
        XCTAssertEqual(autre.statusSnapshot()["reason"] as? String, "screensaver:notification")
        XCTAssertEqual(publieur.publications, publicationsAvant)

        // Après une veille annoncée : la veille est levée, mais par le lissage (300 ms), sans
        // publication forcée.
        signaux = Self.signauxDeBureau()
        publieur = FakePublisher()
        let troisieme = moteur()
        troisieme.start()
        troisieme.willSleep {}
        XCTAssertFalse(troisieme.currentState)
        troisieme.handle(.systemWillNotSleep)
        XCTAssertFalse(troisieme.currentState, "évaluation non immédiate")
        scruter(troisieme, 0.5)
        XCTAssertTrue(troisieme.currentState)
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false),
                                               Publication(etat: true, force: false)])
    }

    /// F39 : l'attente de la livraison OFF ne bloque plus la file. `willSleep` rend la main
    /// tout de suite ; `allow` part à l'échéance de 1,5 s, une seule fois, même si la
    /// livraison arrive ensuite.
    func test_veille_attenteAsynchrone_allowAppeleUneSeuleFois() {
        let planificateur = TestScheduler(clock: horloge)
        let transport = FakeTransport(clock: horloge)
        transport.differe = true
        let client = clientWebhook(transport, planificateur)
        let core = moteur(publieur: client)
        core.start()
        transport.terminerEnAttente()
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1")

        var autorisations = 0
        let debut = horloge.t
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(autorisations, 0, "willSleep rend la main avant la livraison")
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertTrue(transport.requetes.last?.url.absoluteString.hasSuffix("state=false") ?? false)

        planificateur.runDue(at: debut + 1.4)
        XCTAssertEqual(autorisations, 0)
        planificateur.runDue(at: debut + 1.5)
        XCTAssertEqual(autorisations, 1)
        XCTAssertEqual(client.pendingDeliveryNotifications, 0)

        // La livraison tardive, puis le temps qui passe, ne rappellent pas une seconde fois.
        transport.terminerEnAttente()
        planificateur.runDue(at: debut + 10)
        XCTAssertEqual(autorisations, 1)
    }

    /// Ruling R19 (1) : OFF est publié avant `allow()`, et `allow()` attend la confirmation.
    func test_veille_offPublieAvantAllow_allowALaLivraison() {
        publieur.livraisonManuelle = true
        let core = moteur()
        core.start()
        publieur.livrer()

        var autorisations = 0
        var publieeAuMomentDAllow: Publication?
        core.willSleep { [publieur] in
            autorisations += 1
            publieeAuMomentDAllow = publieur?.publications.last
        }
        XCTAssertEqual(publieur.envois.last, Publication(etat: false, force: false))
        XCTAssertEqual(publieur.delaisDemandes, [1.5])
        XCTAssertEqual(autorisations, 0, "pas d'autorisation avant la confirmation")

        publieur.livrer()
        XCTAssertEqual(autorisations, 1)
        XCTAssertEqual(publieeAuMomentDAllow, Publication(etat: false, force: false))
        publieur.terminerSansLivrer()
        XCTAssertEqual(autorisations, 1)
    }

    /// Décision 3 : OFF déjà confirmé, la veille n'envoie rien et n'attend pas.
    func test_veille_offDejaConfirme_aucunEnvoi() {
        // Faux publieur : aucun envoi, autorisation immédiate.
        signaux.etatEcran.asleep = true
        publieur.livraisonManuelle = true
        let core = moteur()
        core.start()
        publieur.livrer()
        XCTAssertEqual(publieur.envois, [Publication(etat: false, force: false)])

        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(autorisations, 1)
        XCTAssertEqual(publieur.envois, [Publication(etat: false, force: false)])
        XCTAssertEqual(publieur.attentesEnCours, 0)

        // Client réel : aucune requête, aucun délai planifié.
        let planificateur = TestScheduler(clock: horloge)
        let transport = FakeTransport(clock: horloge)
        let client = clientWebhook(transport, planificateur)
        let reel = moteur(publieur: client)
        reel.start()
        XCTAssertEqual(transport.requetes.count, 1)
        var autorisationsReelles = 0
        reel.willSleep { autorisationsReelles += 1 }
        XCTAssertEqual(autorisationsReelles, 1)
        XCTAssertEqual(transport.requetes.count, 1)
        XCTAssertEqual(planificateur.pending, 0)
    }

    /// F74 : une veille de moins de 30 s ne force pas la republication au réveil ; à 30 s,
    /// si.
    func test_reveilApresVeilleCourte_pasDePublicationForcee() {
        let core = moteur()
        core.start()

        core.willSleep {}
        horloge.advance(29.5)
        core.handle(.systemDidWake)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false),
                                               Publication(etat: true, force: false)])

        // Sans transition au réveil (écran resté éteint), on voit le drapeau `force` : il part
        // à 30 s de veille…
        signaux.etatEcran.asleep = true
        core.willSleep {}
        horloge.advance(30)
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: true))

        // … et un second avis de réveil (NSWorkspace, plus de 5 s après IOKit) ne force rien.
        var avant = publieur.publications.count
        horloge.advance(6)
        core.handle(.systemDidWake)
        XCTAssertFalse(publieur.publications.dropFirst(avant).contains { $0.force })

        // … mais pas à 29,5 s.
        avant = publieur.publications.count
        core.willSleep {}
        horloge.advance(29.5)
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertFalse(publieur.publications.dropFirst(avant).contains { $0.force })
    }

    /// Au réveil court, un état publié mais non confirmé repart, sans `force`.
    func test_reveilCourt_etatNonConfirme_estRenvoyeSansForce() {
        publieur.livraisonManuelle = true
        let core = moteur()
        core.start()
        publieur.livrer()
        core.willSleep {}
        publieur.terminerSansLivrer()   // OFF jamais confirmé avant le gel

        horloge.advance(5)
        signaux.etatEcran.asleep = true // l'écran reste éteint au réveil : l'état reste OFF
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: false))
        XCTAssertFalse(publieur.publications.contains { $0.force })
        XCTAssertEqual(publieur.envois.last, Publication(etat: false, force: false))
        XCTAssertEqual(publieur.envois.count, 3)
    }

    /// Décision 4 : le garde-fou du veilleur et le rappel de livraison partagent un rappel
    /// unique. Si le garde-fou passe d'abord, la livraison tardive n'autorise pas une seconde
    /// fois la veille.
    func test_gardeFouPuisLivraisonTardive_uneSeuleAutorisation() {
        publieur.livraisonManuelle = true
        let core = moteur()
        core.start()
        publieur.livrer()

        var autorisations = 0
        let accord = OnceCallback { autorisations += 1 }
        core.willSleep { accord.run() }
        XCTAssertEqual(autorisations, 0)

        // Garde-fou de 2 s du veilleur : il autorise la veille.
        XCTAssertTrue(accord.run())
        XCTAssertEqual(autorisations, 1)
        // La livraison arrive ensuite : le second appel est sans effet.
        publieur.livrer()
        XCTAssertEqual(autorisations, 1)
        XCTAssertFalse(accord.run())
        XCTAssertTrue(accord.hasRun)
    }

    // MARK: - Trou de scrutation couvert par une veille (R38)

    private var publicationsForcees: Int { publieur.publications.filter { $0.force }.count }

    /// Écran éteint de bout en bout : l'état reste OFF à travers la veille, aucune transition
    /// ne masque le drapeau `force` (une transition publie toujours sans `force`).
    private func moteurEcranEteint() -> EngineCore {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publicationsForcees, 0)
        return core
    }

    /// R38 : une veille courte fait un trou de scrutation de plus de 10 s. Ce trou est couvert
    /// par la veille : `tick()` ne force pas, le réveil (veille < 30 s) non plus.
    func test_trouCouvertParUneVeilleCourte_neForcePas() {
        let core = moteurEcranEteint()
        core.willSleep {}
        horloge.advance(15)
        core.tick()
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publicationsForcees, 0, "\(publieur.publications)")
        XCTAssertTrue(journalContient("couverte par la veille"), "\(journal.lines)")
    }

    /// R38 : veille de 40 s. Que la scrutation passe avant ou après l'avis de réveil, une seule
    /// publication forcée en tout.
    func test_trouCouvertParUneVeilleLongue_uneSeulePublicationForcee() {
        // Scrutation d'abord (secours si l'avis IOKit est perdu), puis l'avis de réveil.
        let core = moteurEcranEteint()
        core.willSleep {}
        horloge.advance(40)
        core.tick()
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")
        core.handle(.systemDidWake)
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")

        // Avis de réveil d'abord (il force), puis la scrutation (elle ne force plus).
        publieur = FakePublisher()
        let autre = moteurEcranEteint()
        autre.willSleep {}
        horloge.advance(40)
        autre.handle(.systemDidWake)
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")
        horloge.advance(0.5)
        autre.tick()
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")
        XCTAssertFalse(autre.currentState)
    }

    /// Trou couvert, sans `force` : un OFF publié mais jamais confirmé avant le gel repart quand
    /// même, sans `force`, dès la première scrutation après le réveil.
    func test_trouCouvert_etatNonConfirme_estRenvoyeSansForce() {
        publieur.livraisonManuelle = true
        let core = moteurEcranEteint()
        core.willSleep {}
        publieur.terminerSansLivrer()
        let envoisAvant = publieur.envois.count
        horloge.advance(15)
        core.tick()
        XCTAssertEqual(publieur.envois.count, envoisAvant + 1, "\(publieur.envois)")
        XCTAssertEqual(publieur.envois.last, Publication(etat: false, force: false))
        XCTAssertEqual(publicationsForcees, 0)
    }

    /// Trou de 15 s sans veille annoncée : forcé, comme avant.
    func test_trouSansVeille_forceToujours() {
        let core = moteurEcranEteint()
        scruter(core, 15)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: true))
        XCTAssertEqual(publicationsForcees, 1)
        XCTAssertTrue(journalContient("interruption de 15.0 s détectée → resynchronisation"))
    }

    /// Un trou qui déborde de la veille (gel avant la veille, ou après le réveil) n'est pas
    /// couvert : forcé, comme avant.
    func test_trouQuiDebordeDeLaVeille_force() {
        // Dernière scrutation 12 s avant la veille annoncée (gel), réveil 5 s plus tard.
        let core = moteurEcranEteint()
        horloge.advance(12)
        core.willSleep {}
        horloge.advance(5)
        core.tick()
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")

        // Veille de 5 s, réveil traité, puis 12 s sans scrutation (gel après le réveil).
        publieur = FakePublisher()
        let autre = moteurEcranEteint()
        autre.willSleep {}
        horloge.advance(5)
        autre.handle(.systemDidWake)
        XCTAssertEqual(publicationsForcees, 0)
        horloge.advance(12)
        autre.tick()
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")
    }

    // MARK: - Réveil perdu (lot de retouches avant la tâche 16)

    /// Veille courte (5 s, moins que le seuil de trou) dont ni `HasPoweredOn` ni `didWake` ne sont
    /// arrivés : sans rattrapage, `system_asleep` resterait vrai indéfiniment (OFF). Au-delà de
    /// 35 s sans avis de réveil, la scrutation continue rattrape le réveil, sans republication forcée.
    func test_reveilPerdu_scrutationContinue_rattrapeAvant36s() {
        let core = moteur()
        core.start()
        publieur.livrer()
        XCTAssertTrue(core.currentState)
        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["state"] as? String, "0")

        // 5 s de veille réelle : le Mac dort, aucun tick ; puis scrutation continue, pas d'avis.
        horloge.advance(5)
        for _ in 0..<60 { scruter(core, 0.5) }   // 35 s depuis la veille
        XCTAssertFalse(core.currentState, "pas avant le délai de 35 s")
        XCTAssertFalse(journalContient("réveil non signalé"))
        scruter(core, 0.5)                        // 35,5 s
        XCTAssertTrue(core.currentState, "réveil rattrapé : ON")
        XCTAssertTrue(journalContient("réveil non signalé : rattrapé"), "\(journal.lines)")
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "desktop-ui")
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: false))
        XCTAssertEqual(publicationsForcees, 0, "\(publieur.publications)")
        XCTAssertEqual((core.statusSnapshot()["facts"] as? [String: Any])?["system_asleep"] as? Bool, false)

        // L'avis de réveil qui arriverait enfin ne force rien et ne change rien.
        let avant = publieur.envois.count
        core.handle(.systemDidWake)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publicationsForcees, 0)
        XCTAssertEqual(publieur.envois.count, avant, "rien de plus n'est envoyé")
    }

    /// Une veille dont l'avis de réveil arrive à temps ne déclenche jamais le rattrapage, et une
    /// veille longue traitée par le chemin du trou non plus (`end` renseigné).
    func test_reveilPerdu_pasDeRattrapageSiLeReveilEstTraite() {
        let core = moteur()
        core.start()
        core.willSleep {}
        horloge.advance(8)
        core.handle(.systemDidWake)
        XCTAssertTrue(core.currentState)
        for _ in 0..<100 { scruter(core, 0.5) }
        XCTAssertFalse(journalContient("réveil non signalé"), "\(journal.lines)")

        // Veille longue : le trou de scrutation la traite, pas le rattrapage.
        let autre = moteur()
        autre.start()
        autre.willSleep {}
        horloge.advance(60)
        autre.tick()
        XCTAssertTrue(journalContient("couverte par la veille"))
        XCTAssertFalse(journalContient("réveil non signalé"), "\(journal.lines)")
    }

    // MARK: - Veille : détails (tâche 13, tour 1)

    /// Une veille qui abandonne une commande en cours le dit au journal (INFO).
    func test_veille_abandonDIntention_journalise() {
        let core = moteur()
        core.start()
        core.requestOff(source: "essai")
        XCTAssertNotNil(commandeEnAttente(core))
        core.willSleep {}
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journal.lines.contains { $0.0 == .info && $0.1.contains("intention OFF abandonnée : veille") },
                      "\(journal.lines)")

        // Sans commande en cours : rien de tel.
        journal.lines = []
        core.willSleep {}
        XCTAssertFalse(journalContient("abandonnée"))
    }

    /// Deux avis de veille sans réveil : le début de la veille est celui du premier.
    func test_deuxVeillesSansReveil_gardentLePremierDebut() {
        let core = moteur()
        core.start()
        signaux.etatEcran.asleep = true   // pas de transition au réveil : on voit le drapeau `force`
        core.willSleep {}
        horloge.advance(20)
        core.willSleep {}
        horloge.advance(15)
        core.handle(.systemDidWake)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: true))
        XCTAssertTrue(journalContient("réveil après 35.0 s de veille"), "\(journal.lines)")
    }

    /// OFF déjà publié mais pas confirmé (envoi perdu) : `willSleep` le renvoie avant la veille.
    func test_veille_offPublieNonConfirme_estRenvoye() {
        publieur.livraisonManuelle = true
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        publieur.terminerSansLivrer()
        XCTAssertEqual(publieur.envois, [Publication(etat: false, force: false)])

        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(publieur.envois, [Publication(etat: false, force: false),
                                         Publication(etat: false, force: false)])
        XCTAssertEqual(autorisations, 0, "attend la livraison du renvoi")
        publieur.livrer()
        XCTAssertEqual(autorisations, 1)
        XCTAssertTrue(journalContient("veille : OFF confirmé"))
    }

    /// « OFF confirmé » ne sort que si l'état voulu est encore OFF à la livraison.
    func test_veille_offConfirme_seulementSiLEtatVouluEstEncoreOff() {
        publieur.livraisonManuelle = true
        let core = moteur()
        core.start()
        publieur.livrer()

        var autorisations = 0
        core.willSleep { autorisations += 1 }
        // Une commande ON arrive avant la confirmation de OFF.
        core.requestOn(source: "essai")
        XCTAssertTrue(core.currentState)
        publieur.livrer()
        XCTAssertEqual(autorisations, 1)
        XCTAssertFalse(journalContient("OFF confirmé"), "\(journal.lines)")
        XCTAssertTrue(journalContient("veille : état voulu redevenu ON"), "\(journal.lines)")
    }

    // MARK: - Arrêt

    /// Tâche 14 : l'arrêt publie OFF en `force`, attend 2 s au plus, puis le moteur ne fait plus rien.
    func test_arret_publieOff_puisPlusRien() {
        publieur.livraisonManuelle = true
        let core = moteur()
        core.start()
        publieur.livrer()
        XCTAssertEqual(publieur.envois, [Publication(etat: true, force: false)])

        var termines = 0
        core.shutdown(publishOff: true) { termines += 1 }
        XCTAssertEqual(publieur.envois.last, Publication(etat: false, force: true))
        XCTAssertEqual(publieur.delaisDemandes, [2.0])
        XCTAssertEqual(termines, 0, "done attend la livraison")
        publieur.livrer()
        XCTAssertEqual(termines, 1)

        // Plus rien après l'arrêt : une évaluation (scrutation, battement, événement, commande,
        // resynchronisation, veille) ne publie ni n'agit.
        let publicationsApresArret = publieur.publications
        signaux.etatEcran.asleep = true
        scruter(core, 0.5); scruter(core, 0.5); scruter(core, 30)
        core.heartbeat()
        core.handle(.screensDidSleep)
        core.handle(.systemDidWake)
        core.handle(.screenSaverDidStart)
        core.requestOff(source: "http")
        core.requestOn(source: "http")
        core.resync()
        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(autorisations, 1, "la veille n'attend plus rien pendant l'arrêt")

        XCTAssertEqual(publieur.publications, publicationsApresArret)
        XCTAssertEqual(actions.appels, [])
        XCTAssertEqual(publieur.delaisDemandes, [2.0], "aucune nouvelle attente")
        XCTAssertEqual(core.statusSnapshot()["shutting_down"] as? Bool, true)
        XCTAssertEqual(core.currentState, false)
        XCTAssertTrue(journalContient("ignorée : arrêt en cours"))
    }

    /// Tâche 14, puis 15 (R40), puis lot 2 (point 6) : une requête ON muette en vol est annulée à
    /// l'arrêt après 500 ms de grâce ; OFF part alors (bien avant le délai de 2 s), et `done`
    /// n'est appelé qu'à sa confirmation.
    func test_arret_requeteEnVol_estAnnulee_OFFPartAussitot() {
        // Faux publieur : l'arrêt passe par la publication avant le départ.
        publieur.livraisonManuelle = true
        let core = moteur()
        core.start()
        var termines = 0
        core.shutdown(publishOff: true) { termines += 1 }
        XCTAssertEqual(publieur.publicationsAvantDepart, 1)
        XCTAssertEqual(publieur.envois, [Publication(etat: true, force: false),
                                         Publication(etat: false, force: true)])
        publieur.livrer()
        XCTAssertEqual(termines, 1)

        // Client réel : l'ON est en vol, bloqué (sa réponse n'arrive jamais) ; l'arrêt l'annule.
        journal.lines = []
        let planificateur = TestScheduler(clock: horloge)
        let transport = FakeTransport(clock: horloge)
        transport.differe = true
        let client = clientWebhook(transport, planificateur)
        let reel = moteur(publieur: client)
        reel.start()
        XCTAssertEqual(transport.requetes.count, 1)
        XCTAssertTrue(transport.requetes[0].url.absoluteString.hasSuffix("state=true"))

        var termine = 0
        let debut = horloge.t
        reel.shutdown(publishOff: true) { termine += 1 }
        XCTAssertEqual(transport.annulations.count, 0, "l'ON en vol garde 500 ms de grâce")
        XCTAssertEqual(transport.requetes.count, 1)
        planificateur.runDue(at: debut + 0.5)
        XCTAssertEqual(transport.annulations.count, 1, "l'ON encore en vol est annulé à 500 ms")
        XCTAssertEqual(transport.requetes.count, 2, "OFF part sans attendre la réponse de l'ON")
        XCTAssertTrue(transport.requetes[1].url.absoluteString.hasSuffix("state=false"))
        XCTAssertEqual(transport.instants[1] - debut, 0.5, accuracy: 0.001)
        XCTAssertEqual(termine, 0)
        transport.terminerEnAttente()   // l'OFF aboutit
        XCTAssertEqual(termine, 1)
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "0")
        XCTAssertTrue(journalContient("arrêt : OFF confirmé par 1/1 cibles"), "\(journal.lines)")
    }

    /// Lot de retouches : sans cible utilisable (webhooks coupés), l'arrêt ne prétend pas qu'OFF est
    /// « confirmé » (ni « non confirmé en 2 s ») : OFF n'est publié que localement, et `done` part tout de suite.
    func test_arret_webhooksCoupes_offPubliePlocalement() {
        // Client réel désactivé par la configuration.
        var config = Config()
        config.enabled = false
        let client = WebhookClient(config: config, transport: FakeTransport(clock: horloge),
                                   scheduler: TestScheduler(clock: horloge), clock: horloge)
        for publieurCoupe in [client as StatePublisher, { () -> StatePublisher in
            let faux = FakePublisher(); faux.cibleUtilisable = false; return faux }()] {
            journal.lines = []
            let core = moteur(publieur: publieurCoupe)
            core.start()
            var termine = 0
            core.shutdown(publishOff: true) { termine += 1 }
            XCTAssertEqual(termine, 1)
            XCTAssertTrue(journalContient("arrêt : OFF publié localement (webhooks coupés) : aucune cible"), "\(journal.lines)")
            XCTAssertFalse(journalContient("OFF confirmé"), "\(journal.lines)")
            XCTAssertFalse(journalContient("non confirmé"), "\(journal.lines)")
        }
    }

    /// Même formulation à la veille : rien n'est envoyé, `allow` part aussitôt.
    func test_veille_webhooksCoupes_offPubliePlocalement() {
        let faux = FakePublisher()
        faux.cibleUtilisable = false
        let core = moteur(publieur: faux)
        core.start()
        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(autorisations, 1)
        XCTAssertTrue(journalContient("veille : OFF publié localement (webhooks coupés) : aucune cible"), "\(journal.lines)")
        XCTAssertFalse(journalContient("confirmé"), "\(journal.lines)")
    }

    /// Lot 2, point 7 : le journal d'arrêt compte les cibles. Deux cibles qui confirment : « 2/2 » ;
    /// une seule : « 1/2 seulement » en WARN, jamais un « OFF confirmé » sans nombre ni un « non confirmé »
    /// qui nierait la cible qui a répondu.
    func test_arret_journalCompteLesCibles() {
        let planificateur = TestScheduler(clock: horloge)
        let transport = FakeTransport(clock: horloge)
        let client = clientWebhookDeuxCibles(transport, planificateur)
        let core = moteur(publieur: client)
        core.start()
        var termine = 0
        core.shutdown(publishOff: true) { termine += 1 }
        XCTAssertEqual(termine, 1)
        XCTAssertTrue(journalContient("arrêt : OFF confirmé par 2/2 cibles"), "\(journal.lines)")

        journal.lines = []
        let transport2 = FakeTransport(clock: horloge)
        transport2.hotesDifferes = ["192.0.2.11"]
        let planificateur2 = TestScheduler(clock: horloge)
        let client2 = clientWebhookDeuxCibles(transport2, planificateur2)
        let core2 = moteur(publieur: client2)
        core2.start()
        var termine2 = 0
        let debut = horloge.t
        core2.shutdown(publishOff: true) { termine2 += 1 }
        planificateur2.runDue(at: debut + 2)
        XCTAssertEqual(termine2, 1)
        let ligne = journal.lines.first { $0.1.contains("arrêt : OFF confirmé par 1/2 cibles seulement") }
        XCTAssertEqual(ligne?.0, .warn, "\(journal.lines)")
        XCTAssertFalse(journalContient("OFF non confirmé"), "\(journal.lines)")
    }

    /// Lot 2, point 7 : à la veille aussi, « OFF confirmé par n/m cibles ».
    func test_veille_journalCompteLesCibles() {
        let planificateur = TestScheduler(clock: horloge)
        let transport = FakeTransport(clock: horloge)
        let client = clientWebhookDeuxCibles(transport, planificateur)
        let core = moteur(publieur: client)
        core.start()
        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(autorisations, 1)
        XCTAssertTrue(journalContient("veille : OFF confirmé par 2/2 cibles"), "\(journal.lines)")

        journal.lines = []
        let transport2 = FakeTransport(clock: horloge)
        transport2.hotesDifferes = ["192.0.2.11"]
        let planificateur2 = TestScheduler(clock: horloge)
        let core2 = moteur(publieur: clientWebhookDeuxCibles(transport2, planificateur2))
        core2.start()
        var autorisations2 = 0
        let debut = horloge.t
        core2.willSleep { autorisations2 += 1 }
        planificateur2.runDue(at: debut + 1.5)
        XCTAssertEqual(autorisations2, 1)
        XCTAssertTrue(journalContient("veille : OFF confirmé par 1/2 cibles seulement"), "\(journal.lines)")
    }

    /// Tâche 14 : si OFF ne peut pas être livré, `done` part au délai de 2 s, une seule fois.
    func test_arret_delaiDe2s_doneSansLivraison() {
        let planificateur = TestScheduler(clock: horloge)
        let transport = FakeTransport(clock: horloge)
        transport.differe = true
        let client = clientWebhook(transport, planificateur)
        let core = moteur(publieur: client)
        core.start()
        transport.terminerEnAttente()

        var termine = 0
        let debut = horloge.t
        core.shutdown(publishOff: true) { termine += 1 }
        planificateur.runDue(at: debut + 1.9)
        XCTAssertEqual(termine, 0)
        planificateur.runDue(at: debut + 2)
        XCTAssertEqual(termine, 1)
        transport.terminerEnAttente()
        planificateur.runDue(at: debut + 10)
        XCTAssertEqual(termine, 1)
        XCTAssertTrue(journalContient("OFF non confirmé en 2.0 s (0/1 cibles)"), "\(journal.lines)")
    }

    /// Tâche 14 : sans `publishOff` (redémarrage prévu, mode dégradé), rien n'est publié et `done`
    /// part tout de suite ; le moteur est verrouillé quand même.
    func test_arret_sansPublication_doneAussitot_moteurVerrouille() {
        let core = moteur()
        core.start()
        let avant = publieur.publications
        var termine = 0
        core.shutdown(publishOff: false) { termine += 1 }
        XCTAssertEqual(termine, 1)
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertEqual(publieur.delaisDemandes, [])

        core.requestOff(source: "http")
        core.heartbeat()
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertEqual(actions.appels, [])
    }

    /// Tâche 14 : une commande en cours est oubliée par l'arrêt ; un second appel ne republie rien.
    func test_arret_commandeEnCoursOubliee_etSecondAppelSansEffet() {
        let core = moteur()
        core.start()
        core.requestOff(source: "http")
        XCTAssertNotNil(commandeEnAttente(core))
        var termines = 0
        core.shutdown(publishOff: true) { termines += 1 }
        XCTAssertNil(commandeEnAttente(core))
        let publications = publieur.publications
        core.shutdown(publishOff: true) { termines += 1 }
        XCTAssertEqual(termines, 2, "le second appel rend la main tout de suite")
        XCTAssertEqual(publieur.publications, publications)
    }

    // MARK: - Instance unique (tâche 16)

    private func lignesDuJournal(contenant fragment: String) -> Int {
        journal.lines.filter { $0.1.contains(fragment) }.count
    }

    /// Le serveur HTTP ne détient pas son port (occupé, en attente, en échec) : le moteur calcule
    /// son état pour lui-même, mais rien ne part vers les cibles. Ni état, ni battement de cœur,
    /// ni resynchronisation, ni commande, ni événement, ni scrutation.
    func test_publicationBloquee_tantQueListenerPasPret() {
        let core = moteur(ecoute: false)
        core.start()
        XCTAssertEqual(publieur.publications, [], "pas d'état initial annoncé sans le port")
        XCTAssertEqual(core.currentState, true, "l'état local reste calculé")

        signaux.etatEcran.asleep = true
        scruter(core, 0.5); scruter(core, 1.0)
        XCTAssertEqual(core.currentState, false)
        core.heartbeat()
        core.resync()
        core.handle(.screensDidWake)
        core.handle(.systemDidWake)
        core.requestOn(source: "essai")
        core.requestOff(source: "essai")
        scruter(core, 30)
        XCTAssertEqual(publieur.publications, [], "aucune publication tant que le port n'est pas détenu")
        XCTAssertEqual(publieur.publicationsAvantDepart, 0)

        let instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["publishing_allowed"] as? Bool, false)
        XCTAssertEqual(instantane["publishing_reason"] as? String, "port occupé")
    }

    /// Au retour du port, l'état courant (celui calculé pendant le blocage) est publié en `force`,
    /// une seule fois : répéter l'annonce, ou scruter ensuite, n'ajoute rien.
    func test_publicationReprise_forceAuRetour() {
        let core = moteur(ecoute: false)
        core.start()
        signaux.etatEcran.asleep = true
        scruter(core, 0.5); scruter(core, 1.0)
        XCTAssertEqual(publieur.publications, [])

        core.setListenerReady(true)
        XCTAssertEqual(publieur.publications, [Publication(etat: false, force: true)],
                       "l'état courant (OFF) est publié en force dès le retour du port")
        core.setListenerReady(true)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications, [Publication(etat: false, force: true)],
                       "une seule publication, même si l'annonce se répète")
        XCTAssertEqual(publieur.suspensions, [true, false], "suspendu au départ, levé au retour du port")

        // Oscillation : chaque retour publie une fois, jamais plus.
        core.setListenerReady(false)
        core.setListenerReady(true)
        XCTAssertEqual(publieur.suspensions, [true, false, true, false])
        XCTAssertEqual(publieur.publications.count, 2)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: true))
    }

    /// Le publieur est suspendu dès que le moteur est bloqué : réessais et retour du réseau
    /// ne peuvent plus rien envoyer ; il est levé avant la publication forcée.
    func test_perteDuPort_suspendLePublieur_puisLeLeve() {
        let core = moteur()
        core.start()
        XCTAssertEqual(publieur.suspensions, [], "autorisé dès le départ : rien à suspendre")
        core.setListenerReady(false)
        XCTAssertEqual(publieur.suspensions, [true])
        core.setListenerReady(false)
        XCTAssertEqual(publieur.suspensions, [true], "pas de répétition")
        core.setListenerReady(true)
        XCTAssertEqual(publieur.suspensions, [true, false])
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: true))
    }

    /// La session quitte la console (changement rapide d'utilisateur) : rien ne part, puis la
    /// publication reprend en force au retour. `onConsole` se relit à chaque scrutation.
    func test_sessionHorsConsole_bloquePuisReprend() {
        let core = moteur()
        core.start()
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)])

        signaux.etatSession.onConsole = false
        scruter(core, 0.5)
        core.heartbeat()
        signaux.etatEcran.asleep = true
        scruter(core, 0.5); scruter(core, 1.0)
        XCTAssertEqual(core.currentState, false)
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)],
                       "rien de plus tant que la session n'est pas à la console")
        XCTAssertEqual(core.statusSnapshot()["publishing_allowed"] as? Bool, false)
        XCTAssertEqual(core.statusSnapshot()["publishing_reason"] as? String, "session hors console")

        signaux.etatSession.onConsole = true
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: true))
        XCTAssertEqual(publieur.publications.count, 2)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications.count, 2, "une seule publication forcée au retour")
        XCTAssertEqual(core.statusSnapshot()["publishing_allowed"] as? Bool, true)
        XCTAssertEqual(core.statusSnapshot()["publishing_reason"] as? String, "prêt")
    }

    /// Une ligne INFO à chaque changement d'autorisation, avec sa raison : jamais une par scrutation.
    func test_autorisation_uneLigneParChangement() {
        let core = moteur(ecoute: false)
        core.start()
        for _ in 0..<5 { scruter(core, 0.5) }
        XCTAssertEqual(lignesDuJournal(contenant: "publication bloquée"), 1)
        XCTAssertTrue(journalContient("publication bloquée : port occupé"))

        core.setListenerReady(true)
        for _ in 0..<5 { scruter(core, 0.5) }
        XCTAssertEqual(lignesDuJournal(contenant: "publication autorisée"), 1)
        XCTAssertTrue(journalContient("publication autorisée : prêt"))

        signaux.etatSession.onConsole = false
        for _ in 0..<5 { scruter(core, 0.5) }
        XCTAssertEqual(lignesDuJournal(contenant: "publication bloquée"), 2)
        XCTAssertTrue(journalContient("publication bloquée : session hors console"))
        XCTAssertTrue(journal.lines.filter { $0.1.contains("publication autorisée") || $0.1.contains("publication bloquée") }
                        .allSatisfy { $0.0 == .info })
    }

    /// Avant que le serveur HTTP ait rien annoncé, la raison n'est pas « port occupé » : l'écoute
    /// démarre seulement.
    func test_avantToutAvisDuServeur_raisonEstEcouteEnCours() {
        let core = moteur(ecoute: nil)
        XCTAssertEqual(core.statusSnapshot()["publishing_allowed"] as? Bool, false)
        XCTAssertEqual(core.statusSnapshot()["publishing_reason"] as? String, "écoute en cours")
        core.start()
        XCTAssertEqual(core.statusSnapshot()["publishing_reason"] as? String, "écoute en cours")
        XCTAssertTrue(journalContient("publication bloquée : écoute en cours"))
    }

    /// Règle 1 : une instance qui n'a jamais été autorisée n'a rien annoncé, elle ne publie pas OFF
    /// en partant.
    func test_arret_instanceJamaisAutorisee_neFaitRien() {
        let core = moteur(ecoute: false)
        core.start()
        var termines = 0
        core.shutdown(publishOff: true) { termines += 1 }
        XCTAssertEqual(termines, 1, "done part tout de suite")
        XCTAssertEqual(publieur.publications, [])
        XCTAssertEqual(publieur.publicationsAvantDepart, 0)
        XCTAssertEqual(publieur.delaisDemandes, [])
        XCTAssertTrue(journalContient("arrêt : aucune publication OFF (publication jamais autorisée)"))
    }

    /// Règle 2 : une instance autorisée puis bloquée (port perdu, console perdue) ne publie pas OFF
    /// non plus : une autre session détient peut-être l'état.
    func test_arret_instanceBloqueeApresAutorisation_neFaitRien() {
        let core = moteur()
        core.start()
        let avant = publieur.publications
        signaux.etatSession.onConsole = false
        scruter(core, 0.5)
        var termines = 0
        core.shutdown(publishOff: true) { termines += 1 }
        XCTAssertEqual(termines, 1)
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertEqual(publieur.publicationsAvantDepart, 0)
        XCTAssertTrue(journalContient("arrêt : aucune publication OFF (publication bloquée : session hors console)"))
    }

    /// Autorisée, l'instance publie toujours OFF en partant (comportement inchangé).
    func test_arret_instanceAutorisee_publieOff() {
        let core = moteur()
        core.start()
        core.shutdown(publishOff: true) {}
        XCTAssertEqual(publieur.publicationsAvantDepart, 1)
    }

    /// Veille imminente sans droit de publier : la veille est autorisée aussitôt, sans attendre
    /// une livraison qui ne viendra pas.
    func test_veille_publicationBloquee_autoriseAussitot() {
        publieur.livraisonManuelle = true
        let core = moteur(ecoute: false)
        core.start()
        var autorisations = 0
        core.willSleep { autorisations += 1 }
        XCTAssertEqual(autorisations, 1)
        XCTAssertEqual(publieur.delaisDemandes, [])
        XCTAssertEqual(publieur.publications, [])
        XCTAssertFalse(core.currentState, "l'état local passe à OFF")
        XCTAssertTrue(journalContient("veille : publication bloquée"))
    }

    /// Les faits exposent `on_console`.
    func test_faits_exposentOnConsole() {
        let core = moteur()
        core.start()
        let faits = core.statusSnapshot()["facts"] as? [String: Any]
        XCTAssertEqual(faits?["on_console"] as? Bool, true)
    }

    /// De bout en bout avec le vrai client webhook : cible en panne, réessai lent en attente ; le
    /// port est perdu → ni réessai, ni relance au retour du réseau, ni battement ; au retour, une
    /// seule requête, en force.
    func test_clientReel_rienNePartTantQueLaPublicationEstBloquee() {
        let transport = FakeTransport(clock: horloge)
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let planificateur = TestScheduler(clock: horloge)
        let client = clientWebhook(transport, planificateur)
        let core = moteur(publieur: client)
        core.start()
        XCTAssertEqual(transport.requetes.count, 1)
        planificateur.runDue(at: horloge.t + 30)           // série rapide épuisée → réessai lent
        let avant = transport.requetes.count
        XCTAssertGreaterThan(avant, 1)

        core.setListenerReady(false)
        planificateur.runDue(at: horloge.t + 600)
        client.networkBecameAvailable()
        core.heartbeat()
        core.resync()
        XCTAssertEqual(transport.requetes.count, avant, "rien ne part : ni réessai lent, ni réseau, ni battement")

        transport.reponseParDefaut = .delivered(status: 200)
        core.setListenerReady(true)
        XCTAssertEqual(transport.requetes.count, avant + 1, "une seule requête au retour, en force")
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1")
        planificateur.runDue(at: horloge.t + 600)
        XCTAssertEqual(transport.requetes.count, avant + 1)
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
