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

    /// Bureau ouvert, un écran, aucune activité depuis 30 s, SAC à 0 : la dernière frappe précède
    /// toute session d'économiseur ouverte ensuite, qui reste donc seule à l'écran.
    private static func signauxDeBureau() -> FakeSignals {
        let signaux = FakeSignals()
        signaux.inactiviteHID = 30
        return signaux
    }

    /// Moteur câblé comme l'exécuteur le câble, mais sur les faux. `ecoute` : ce que le serveur HTTP
    /// a annoncé de son port (`.ready` : détenu, `.portBusy` : occupé, `nil` : rien encore). Sans port
    /// détenu, le moteur ne publie rien (tâche 16).
    private func moteur(_ config: Config = Config(), ecoute: ListenerStatus? = .ready) -> EngineCore {
        let core = moteurBrut(config)
        if let ecoute { core.setListenerStatus(ecoute) }
        return core
    }

    private func moteurBrut(_ config: Config = Config()) -> EngineCore {
        let oracle = ScreenSaverOracle(
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: config.saverDismissGrace,
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

    /// Comme `scruter`, sans aucune activité matérielle : l'inactivité HID grandit du même pas, pour que la
    /// dernière frappe connue de l'oracle reste fixe.
    private func scruterSansActivite(_ core: EngineCore, _ secondes: Double) {
        signaux.inactiviteHID += secondes
        scruter(core, secondes)
    }

    private func commandeEnAttente(_ core: EngineCore) -> [String: Any]? {
        core.statusSnapshot()["pending_command"] as? [String: Any]
    }

    /// Preuve de l'économiseur telle que `/status` la publie (`facts.screensaver_evidence`), sans relire
    /// le système.
    private func preuveEconomiseur(_ core: EngineCore) -> String? {
        (core.statusSnapshot()["facts"] as? [String: Any])?["screensaver_evidence"] as? String
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
        // « Aucun écran physique » et « écran éteint » s'excluent : l'écran éteint est un écran physique endormi.
        let ecranEteint: (FakeSignals) -> Void = {
            economiseur($0)
            $0.etatEcran = DisplayState(asleep: true, onlineCount: 1, enumerationOK: true)
        }

        /// `attente` : secondes entre deux lectures. « Aucun écran physique » ne vaut `no-display` qu'après 5 s
        /// (`displays-reconfiguring` jusque-là) ; la première lecture démarre le délai.
        func verdict(veille: Bool = false, attente: Double = 0,
                     _ preparer: (FakeSignals) -> Void) -> (etat: Bool, raison: String) {
            signaux = Self.signauxDeBureau()
            preparer(signaux)
            let core = moteur()
            if veille { core.willSleep {} }
            if attente > 0 {
                _ = core.inspect()
                horloge.advance(attente)
            }
            let resultat = core.inspect()
            return (resultat.state, resultat.reason)
        }

        let veille = verdict(veille: true, ecranEteint)
        XCTAssertEqual(veille.etat, false); XCTAssertEqual(veille.raison, "system-asleep")

        let eteint = verdict(ecranEteint)
        XCTAssertEqual(eteint.etat, false); XCTAssertEqual(eteint.raison, "display-asleep")

        let actif = verdict(economiseur)
        XCTAssertEqual(actif.etat, false); XCTAssertTrue(actif.raison.hasPrefix("screensaver:"), actif.raison)

        let sansEcran = verdict(attente: 5, aucunEcran)
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

        /// `attente` : secondes entre deux lectures (« aucun écran physique » ne vaut `no-display` qu'après 5 s).
        func verdict(_ config: Config, attente: Double = 0,
                     preparer: (FakeSignals) -> Void) -> (etat: Bool, raison: String) {
            signaux = Self.signauxDeBureau()
            preparer(signaux)
            let core = moteur(config)
            if attente > 0 {
                _ = core.inspect()
                horloge.advance(attente)
            }
            let resultat = core.inspect()
            return (resultat.state, resultat.reason)
        }

        // Verrouillée, aucune saisie sécurisée : OFF.
        let sansChamp = verdict(config) { $0.etatSession.locked = true }
        XCTAssertEqual(sansChamp.etat, false); XCTAssertEqual(sansChamp.raison, "locked-without-auth-ui")

        // Priorité inférieure à « aucun écran » : celle-ci l'emporte.
        let sansEcran = verdict(config, attente: 5) { $0.etatSession.locked = true; $0.etatEcran.onlineCount = 0 }
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

        core.requestOff(peer: "essai")
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
        core.requestOff(peer: "essai")

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

        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.displaySleep)])
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/display_sleep")

        // Avec une commande OFF personnalisée, l'action configurée est gardée.
        actions = FakeActions()
        actions.hasOffOverride = true
        let personnalise = moteur()
        personnalise.start()
        personnalise.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])
    }

    func test_dejaOff_aucuneAction() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        XCTAssertFalse(core.currentState)
        let avant = publieur.publications

        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertTrue(journalContient("commande OFF (essai) → déjà OFF (display-asleep), aucune action"))
    }

    // MARK: - Idempotence (tâche 9)

    func test_doublonOff_pendantUneCommandeOff_aucuneActionEtEcheanceInchangee() {
        let core = moteur()
        core.start()
        core.requestOff(peer: "essai")
        let publications = publieur.publications

        // Doublons à 1 s et à 2 s : aucune action, la commande garde son origine.
        scruter(core, 0.5)
        scruter(core, 0.5)
        core.requestOff(peer: "essai")
        scruter(core, 0.5)
        scruter(core, 0.5)
        core.requestOff(peer: "autre")
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
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        scruter(core, 0.5)
        core.requestOn(peer: "essai")
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(commandeEnAttente(core)?["age_seconds"] as? Int, 0)
        XCTAssertTrue(journalContient("commande ON (essai) → commande ON déjà en cours, ignorée"))

        // Une fois la commande échue (retour aux faits), un nouvel ON agit de nouveau.
        for _ in 0..<24 { scruter(core, 0.5) }
        XCTAssertNil(commandeEnAttente(core))
        let avant = actions.appels.count
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels.count, avant + 1)
        XCTAssertEqual(actions.appels.last, .wake)
    }

    func test_onPuisOff_rapides_leDernierGagne() {
        // Écran éteint : ON puis OFF aussitôt. Les faits disent déjà OFF : l'intention ON
        // est remplacée, sans action OFF, et l'état reste OFF.
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        XCTAssertTrue(core.currentState)
        core.requestOff(peer: "essai")
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
        core.requestOff(peer: "essai")
        XCTAssertFalse(core.currentState)
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .wake])
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false),
                                               Publication(etat: true, force: false)])
        // Les faits disent ON, mais l'économiseur lancé par l'OFF peut encore démarrer : pas de
        // confirmation avant le délai d'escalade (2,5 s), puis confirmée sans escalade.
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertNotNil(commandeEnAttente(core), "2,0 s : l'ON attend encore")
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande on confirmée par les faits en 2.5 s"))
        for _ in 0..<30 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .wake])
    }

    /// C8/F13 : OFF puis ON rapides, l'économiseur lancé par `open -a` démarre 1 s après l'OFF, donc
    /// après l'ON. L'ON n'est pas confirmé avant le délai d'escalade : l'escalade arrête l'économiseur
    /// et l'état final est ON. Sans cela, l'ON confirmé aussitôt laissait l'économiseur gagner.
    func test_offPuisOn_economiseurQuiDemarreApres_etatFinalOn() {
        let core = moteur()
        core.start()
        core.requestOff(peer: "essai")
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .wake])
        XCTAssertNotNil(commandeEnAttente(core), "l'ON n'est pas confirmé dans l'évaluation du réveil")
        XCTAssertEqual(actions.appelsReveil, [], "R47 : rien n'est relâché dans l'évaluation du réveil")
        XCTAssertTrue(journalContient("remplace l'OFF en cours"))

        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [])
        // 1 s après l'OFF, l'économiseur démarre enfin.
        signaux.pidEconomiseur = 4242
        for _ in 0..<3 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState, "l'intention ON tient l'état")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .wake])

        // 2,5 s : escalade, l'économiseur est écarté par la commande du système (C24).
        scruter(core, 0.5)
        XCTAssertEqual(actions.appels, [.runOff(.screensaver), .wake, .dismissScreenSaver])
        XCTAssertNotNil(commandeEnAttente(core), "les faits n'ont pas encore relu l'écartement")
        // L'évaluation suivante voit le panneau de connexion par-dessus l'économiseur, qui tourne encore :
        // l'arrêt natif compte comme une activité, et confirme l'ON.
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(preuveEconomiseur(core), "process+écarté-par-commande")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])

        for _ in 0..<30 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: false))
        XCTAssertFalse(publieur.publications.dropFirst(2).contains { !$0.etat }, "aucun OFF après l'ON")
    }

    /// R49 : déjà ON selon les faits (qui ne voient ni l'économiseur d'inactivité de macOS 27 ni
    /// l'écran assombri), /wake envoie quand même un réveil léger : sans intention, sans attente, et
    /// relâché à l'évaluation suivante, jamais dans la même.
    func test_onQuandDejaOn_reveilLeger_relacheALEvaluationSuivante() {
        let core = moteur()
        core.start()
        let avant = publieur.publications
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake], "un seul réveil")
        XCTAssertNil(commandeEnAttente(core), "aucune intention")
        XCTAssertEqual(actions.appelsReveil, [], "rien n'est relâché dans la même évaluation")
        XCTAssertEqual(publieur.publications, avant, "aucune publication")
        XCTAssertEqual(publieur.delaisDemandes, [], "chemin sans attente")
        XCTAssertTrue(journalContient("commande ON (essai) → déjà ON (desktop-ui) : réveil léger"))

        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "relâché à l'évaluation suivante")
        XCTAssertTrue(journalContient("assertion de réveil relâchée (réveil léger"))
        for _ in 0..<10 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "une seule fois")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(publieur.publications, avant)

        // Les faits sont relus avant de décider : un écran éteint depuis le dernier cycle
        // n'est pas « déjà ON » : la commande a son intention.
        signaux.etatEcran.asleep = true
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .wake])
        XCTAssertNotNil(commandeEnAttente(core))
    }

    /// R49 : deux /wake de suite sur un Mac déjà ON : deux réveils légers, chacun relâché.
    func test_reveilsLegersRepetes_chacunRelache() {
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .wake])
        XCTAssertEqual(actions.appelsReveil, [])
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        core.requestOn(peer: "essai")
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .releaseWake])
    }

    func test_onSousUnEconomiseurEcarte_reveilSansIntention() {
        // R30 : l'oracle dit « écarté » (ON) jusqu'à 30 s après une frappe, alors que macOS a pu
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
        // 20 s sans activité : toujours « écarté » pour l'oracle (retour à l'économiseur à 30 s).
        for _ in 0..<40 {
            signaux.inactiviteHID += 0.5
            scruter(core, 0.5)
        }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["facts"].flatMap { ($0 as? [String: Any])?["screensaver_running"] as? Bool }, true)
        XCTAssertEqual(actions.appels, [])

        // Le réveil est suivi de l'arrêt de l'économiseur par la commande du système (C24) : macOS a pu
        // revenir à l'économiseur, que le panneau supposé visible ne montre plus.
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(core.currentState)
        XCTAssertTrue(journalContient("économiseur en marche"), "\(journal.lines.map { $0.1 })")

        // Sans économiseur (deux lectures sans process), « déjà ON » donne un réveil léger (R49), toujours
        // sans intention, et sans arrêt de l'économiseur.
        signaux.pidEconomiseur = 0
        scruter(core, 0.5)
        scruter(core, 0.5)
        core.requestOn(peer: "essai")
        XCTAssertTrue(journalContient("déjà ON (desktop-ui) : réveil léger"))
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver, .wake])
        XCTAssertNil(commandeEnAttente(core))
    }

    // MARK: - Réveil maîtrisé (tâche 17)

    private typealias AppelReveil = FakeActions.AppelReveil

    /// Configuration avec retenue d'écran de `secondes` secondes.
    private func configRetenue(_ secondes: Int) -> Config {
        var config = Config()
        config.wakeHoldSeconds = secondes
        return config
    }

    /// Session verrouillée, écran éteint : un /wake doit rallumer l'écran sur l'écran de verrouillage.
    private func sessionVerrouilleeEcranEteint() {
        signaux.etatSession.locked = true
        signaux.etatEcran.asleep = true
    }

    /// L'assertion posée par /wake est relâchée dès que les faits confirment le ON, une seule fois.
    func test_onConfirme_libereLAssertion() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(actions.appelsReveil, [], "tant que les faits ne confirment pas, l'assertion reste posée")

        // Les faits restent OFF : toujours rien.
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [])

        // L'écran se rallume : ON confirmé, assertion relâchée aussitôt.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("assertion de réveil relâchée (ON confirmé par les faits)"))

        // Une seule fois, et aucune retenue (wake_hold_seconds = 0 par défaut).
        for _ in 0..<10 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// Commande jamais confirmée : l'assertion ne survit pas à l'échéance (12 s), malgré l'escalade
    /// qui a re-déclaré l'activité entre-temps.
    func test_onNonConfirme_libereALEcheance() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        for _ in 0..<23 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appels, [.wake, .wake], "escalade à 2,5 s : nouvelle tentative de réveil")
        XCTAssertEqual(actions.appelsReveil, [], "11,5 s : la commande tient encore")
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        XCTAssertTrue(journalContient("assertion de réveil relâchée (commande terminée sans confirmation)"))
    }

    /// Un OFF qui remplace un ON en attente relâche aussi l'assertion, ON déjà ou non refusé par les faits.
    func test_offRemplaceOn_libereLAssertion() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        // Un second OFF ne relâche rien de plus.
        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// La veille emporte sur la commande ON en attente : l'assertion est relâchée.
    func test_veille_pendantUnOnEnAttente_libereLAssertion() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        core.willSleep {}
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// Arrêt : l'assertion posée est relâchée, même sans confirmation, et même sans publication OFF.
    func test_arret_libereLAssertion() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        var termines = 0
        core.shutdown(publishOff: false) { termines += 1 }
        XCTAssertEqual(termines, 1)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        // Le moteur arrêté ne relâche ni ne retient plus rien.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// R30 : /wake sous un économiseur « écarté » réveille sans intention. L'assertion tient tant que
    /// l'économiseur tourne, puis est relâchée dès qu'il est parti (ou à l'échéance de la commande).
    func test_reveilSansIntention_libereQuandLEconomiseurPart() {
        let core = moteur()
        core.start()
        signaux.pidEconomiseur = 4242
        for _ in 0..<4 { scruter(core, 0.5) }
        signaux.inactiviteHID = 0
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "C24 : réveil, puis écartement")
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(actions.appelsReveil, [], "l'économiseur tourne encore : l'assertion reste posée")
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [])

        // Parti : la deuxième lecture de suite sans process ferme la session.
        signaux.pidEconomiseur = 0
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [], "une lecture sans source ne ferme pas la session")
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// Sans économiseur qui part, l'assertion d'un réveil sans intention est quand même relâchée à
    /// l'échéance habituelle d'une commande (12 s).
    func test_reveilSansIntention_libereALEcheanceSiLEconomiseurRestePose() {
        let core = moteur()
        core.start()
        signaux.pidEconomiseur = 4242
        for _ in 0..<4 { scruter(core, 0.5) }
        signaux.inactiviteHID = 0
        for _ in 0..<4 { scruter(core, 0.5) }
        core.requestOn(peer: "essai")
        for _ in 0..<23 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appelsReveil, [])
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// `wake_hold_seconds = 0` (défaut) : aucune retenue, même sur une session verrouillée.
    func test_wakeHold0_aucuneRetenue() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(0))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        XCTAssertFalse(journalContient("retenue d'écran"))
    }

    /// `wake_hold_seconds = 60`, session verrouillée : après le ON confirmé, l'assertion de réveil est
    /// relâchée puis l'écran est retenu 60 s. Rien n'est posé pendant `requestOn` : le chemin /wake
    /// n'attend rien.
    func test_wakeHold60_retenueSurSessionVerrouillee() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [], "la retenue vient après la confirmation, jamais dans /wake")

        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60)])
        XCTAssertTrue(journalContient("retenue d'écran posée pour 60 s (session verrouillée)"))

        // Tant que la session reste verrouillée et allumée : aucun nouvel appel.
        for _ in 0..<20 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60)])
    }

    /// Session déverrouillée (bureau) : la retenue ne sert à rien, même avec `wake_hold_seconds > 0`.
    func test_wakeHold60_sessionDeverrouillee_aucuneRetenue() {
        signaux.etatEcran.asleep = true
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// Un ON déjà vrai (aucune commande) ne pose aucune retenue : le réveil léger (R49) est
    /// seulement relâché à l'évaluation suivante.
    func test_wakeHold60_onDejaOn_aucuneRetenue() {
        signaux.etatSession.locked = true
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        scruter(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// La retenue est levée au déverrouillage.
    func test_retenue_relacheeAuDeverrouillage() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil.last, .holdDisplay(60))

        signaux.etatSession.locked = false
        core.handle(.screenUnlocked)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60), .holdDisplay(0)])
        XCTAssertTrue(journalContient("retenue d'écran levée (session déverrouillée)"))
        for _ in 0..<10 { scruter(core, 0.5) }
        XCTAssertEqual(actions.appelsReveil.count, 3, "une seule levée")
    }

    /// La retenue est levée dès que les faits passent à OFF (écran éteint à la main, économiseur…).
    func test_retenue_relacheeAUnOff() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)

        signaux.etatEcran.asleep = true
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60), .holdDisplay(0)])
        XCTAssertTrue(journalContient("retenue d'écran levée (OFF)"))
    }

    /// Une commande OFF lève la retenue avant d'agir.
    func test_retenue_relacheeParUneCommandeOff() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60), .holdDisplay(0)])
        XCTAssertEqual(actions.appels.last, .runOff(.displaySleep))
    }

    /// À l'échéance, l'assertion s'éteint d'elle-même : le moteur oublie la retenue et ne la lève plus.
    func test_retenue_echue_neSeLevePlus() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        for _ in 0..<12 { scruter(core, 5) }
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60)])
        XCTAssertTrue(journalContient("retenue d'écran échue"))

        signaux.etatEcran.asleep = true
        scruter(core, 0.5)
        var termines = 0
        core.shutdown(publishOff: false) { termines += 1 }
        XCTAssertEqual(actions.appelsReveil.filter { $0 == .holdDisplay(0) }.count, 0)
    }

    /// Un nouveau ON confirmé pendant une retenue la remplace (un seul appel de plus, jamais deux
    /// retenues côté actions : c'est `holdDisplay` qui remplace).
    func test_retenue_nouveauOnLaRenouvelle() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60)])

        // Écran éteint (retenue levée), puis un second /wake.
        signaux.etatEcran.asleep = true
        scruter(core, 0.5)
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake, .holdDisplay(60), .holdDisplay(0),
                                              .releaseWake, .holdDisplay(60)])
    }

    /// Avec `wake_command`, le réveil ne pose rien : ni relâchement d'assertion, ni retenue d'écran,
    /// et le journal ne parle ni de l'un ni de l'autre.
    func test_wakeCommand_niAssertionNiRetenue() {
        sessionVerrouilleeEcranEteint()
        actions.hasWakeOverride = true
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core), "ON confirmé")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(actions.appelsReveil, [])
        XCTAssertFalse(journalContient("assertion de réveil relâchée"), "\(journal.lines.map { $0.1 })")
        XCTAssertFalse(journalContient("retenue d'écran"), "\(journal.lines.map { $0.1 })")

        // Réveil léger (R49) : la commande part, rien à relâcher ensuite.
        core.requestOn(peer: "essai")
        scruter(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake, .wake])
        XCTAssertEqual(actions.appelsReveil, [])
        XCTAssertFalse(journalContient("assertion de réveil relâchée"))

        // Un OFF ne lève aucune retenue qui n'existe pas.
        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [])
    }

    /// Arrêt : la retenue en cours est levée.
    func test_arret_leveLaRetenue() {
        sessionVerrouilleeEcranEteint()
        let core = moteur(configRetenue(60))
        core.start()
        core.requestOn(peer: "essai")
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        var termines = 0
        core.shutdown(publishOff: false) { termines += 1 }
        XCTAssertEqual(termines, 1)
        XCTAssertEqual(actions.appelsReveil.last, .holdDisplay(0))
        XCTAssertEqual(actions.appelsReveil.filter { $0 == .holdDisplay(0) }.count, 1)
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
        core.setListenerStatus(.ready)
        return core
    }

    private func moteurBrut(publieur autre: StatePublisher) -> EngineCore {
        let config = Config()
        let oracle = ScreenSaverOracle(
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: config.saverDismissGrace,
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
        core.requestOn(peer: "essai")
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
        core.requestOff(peer: "essai")
        scruter(core, 0.5)
        let avant = publieur.publications
        core.handle(.systemWillNotSleep)
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/screensaver")
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])

        // Notification de l'économiseur : intacte. Sans SAC (repli), un didstart attend son hôte ;
        // une veille annulée entre les deux n'efface pas l'attente, contrairement à un réveil.
        signaux = Self.signauxDeBureau()
        signaux.drapeauSAC = nil
        publieur = FakePublisher()
        let autre = moteur()
        autre.start()
        autre.handle(.screenSaverDidStart)
        autre.handle(.systemWillNotSleep)
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
        for _ in 0..<3 { scruter(autre, 0.5) }
        XCTAssertFalse(autre.currentState)
        XCTAssertEqual(autre.statusSnapshot()["reason"] as? String, "screensaver:notification+hôte")
        let publicationsAvant = publieur.publications
        autre.handle(.systemWillNotSleep)
        for _ in 0..<4 { scruter(autre, 0.5) }
        XCTAssertFalse(autre.currentState)
        XCTAssertEqual(autre.statusSnapshot()["reason"] as? String, "screensaver:notification+hôte")
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
    /// 120 s sans avis de réveil, la scrutation continue rattrape le réveil, sans republication forcée.
    /// Sans aucune activité (`scruterSansActivite`) : une frappe postérieure à l'annonce mettrait fin à la
    /// veille bien avant le filet (tâche 5).
    func test_reveilPerdu_scrutationContinue_rattrapeAvant121s() {
        XCTAssertEqual(EngineCore.lostWakeDelay, 120)
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
        signaux.inactiviteHID += 5
        for _ in 0..<230 { scruterSansActivite(core, 0.5) }   // 120 s depuis la veille
        XCTAssertFalse(core.currentState, "pas avant le délai de 120 s")
        XCTAssertFalse(journalContient("réveil non signalé"))
        scruterSansActivite(core, 0.5)                         // 120,5 s
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
        for _ in 0..<250 { scruter(core, 0.5) }   // 125 s : au-delà du délai de 120 s
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
        core.requestOff(peer: "essai")
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
        core.requestOn(peer: "essai")
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
        core.requestOff(peer: "http")
        core.requestOn(peer: "http")
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

        core.requestOff(peer: "http")
        core.heartbeat()
        XCTAssertEqual(publieur.publications, avant)
        XCTAssertEqual(actions.appels, [])
    }

    /// Tâche 14 : une commande en cours est oubliée par l'arrêt ; un second appel ne republie rien.
    func test_arret_commandeEnCoursOubliee_etSecondAppelSansEffet() {
        let core = moteur()
        core.start()
        core.requestOff(peer: "http")
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
        let core = moteur(ecoute: .portBusy)
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
        core.requestOn(peer: "essai")
        core.requestOff(peer: "essai")
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
        let core = moteur(ecoute: .portBusy)
        core.start()
        signaux.etatEcran.asleep = true
        scruter(core, 0.5); scruter(core, 1.0)
        XCTAssertEqual(publieur.publications, [])

        core.setListenerStatus(.ready)
        XCTAssertEqual(publieur.publications, [Publication(etat: false, force: true)],
                       "l'état courant (OFF) est publié en force dès le retour du port")
        core.setListenerStatus(.ready)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications, [Publication(etat: false, force: true)],
                       "une seule publication, même si l'annonce se répète")
        XCTAssertEqual(publieur.suspensions, [true, false], "suspendu au départ, levé au retour du port")

        // Oscillation espacée de plus de 2 s : chaque retour publie une fois, jamais plus.
        scruter(core, 2.0)
        core.setListenerStatus(.portBusy)
        core.setListenerStatus(.ready)
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
        core.setListenerStatus(.portBusy)
        XCTAssertEqual(publieur.suspensions, [true])
        core.setListenerStatus(.portBusy)
        XCTAssertEqual(publieur.suspensions, [true], "pas de répétition")
        core.setListenerStatus(.ready)
        XCTAssertEqual(publieur.suspensions, [true, false])
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: true))
    }

    /// Lot 3, point 2 : si l'écoute oscille `.ready` / `.waiting`, la reprise forcée est espacée d'au
    /// moins 2 s. Un retour trop proche attend (il n'est pas perdu) et part, forcé, à la scrutation qui
    /// suit l'échéance.
    func test_oscillationDeLEcoute_repriseForceeEspaceeDeDeuxSecondes() {
        let core = moteur()
        core.start()
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)])

        core.setListenerStatus(.waiting)
        core.setListenerStatus(.ready)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: true))
        XCTAssertEqual(publieur.publications.filter { $0.force }.count, 1, "première reprise : tout de suite")

        // Oscillations dans les 2 s qui suivent : aucune nouvelle publication forcée.
        for _ in 0..<3 {
            scruter(core, 0.25)
            core.setListenerStatus(.waiting)
            core.setListenerStatus(.ready)
        }
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications.filter { $0.force }.count, 1,
                       "pas de seconde reprise forcée avant 2 s (0,5 + 3 × 0,25 s = 1,25 s écoulées)")
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications.filter { $0.force }.count, 1, "1,75 s écoulées")

        // À l'échéance, la reprise retenue part, une seule fois.
        scruter(core, 0.25)
        XCTAssertEqual(publieur.publications.filter { $0.force }.count, 2, "2 s écoulées : la reprise retenue part")
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: true))
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertEqual(publieur.publications.filter { $0.force }.count, 2, "une seule, malgré les oscillations")
    }

    /// Un retour d'écoute retenu par le plancher est abandonné si l'écoute retombe avant l'échéance :
    /// rien ne part pendant le blocage, et le prochain vrai retour repart du plancher.
    func test_oscillationDeLEcoute_repriseRetenueAbandonneeSiBloque() {
        let core = moteur()
        core.start()
        core.setListenerStatus(.waiting)
        core.setListenerStatus(.ready)            // reprise forcée n° 1
        scruter(core, 0.5)
        core.setListenerStatus(.waiting)
        core.setListenerStatus(.ready)            // retenue
        core.setListenerStatus(.waiting)          // bloquée avant l'échéance
        let avant = publieur.publications.count
        scruter(core, 3.0)
        XCTAssertEqual(publieur.publications.count, avant, "rien ne part tant que l'écoute est en attente")
        core.setListenerStatus(.ready)            // 3,5 s après la n° 1
        XCTAssertEqual(publieur.publications.count, avant + 1)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: true))
    }

    /// Lot 3, point 7 : la raison du blocage dit ce que le serveur a annoncé, sans tout appeler
    /// « port occupé ».
    func test_raisonDuBlocage_distingueLesEtatsDeLEcoute() {
        let attendu: [(ListenerStatus, String)] = [
            (.waiting, "écoute en attente"),
            (.portBusy, "port occupé"),
            (.failed, "écoute en échec"),
            (.stopped, "écoute arrêtée"),
            (.invalidPort, "port invalide"),
        ]
        for (statut, raison) in attendu {
            let core = moteur(ecoute: statut)
            core.start()
            XCTAssertEqual(core.statusSnapshot()["publishing_allowed"] as? Bool, false, raison)
            XCTAssertEqual(core.statusSnapshot()["publishing_reason"] as? String, raison)
            XCTAssertTrue(journalContient("publication bloquée : \(raison)"), raison)
        }
        let pret = moteur(ecoute: .ready)
        pret.start()
        XCTAssertEqual(pret.statusSnapshot()["publishing_reason"] as? String, "prêt")
    }

    /// Passer d'un blocage à un autre change la raison journalisée, une fois, sans lever le blocage.
    func test_changementDeRaisonDeBlocage_estJournalise() {
        let core = moteur(ecoute: .waiting)
        core.start()
        core.setListenerStatus(.portBusy)
        XCTAssertTrue(journalContient("publication bloquée : écoute en attente"))
        XCTAssertTrue(journalContient("publication bloquée : port occupé"))
        XCTAssertEqual(core.statusSnapshot()["publishing_reason"] as? String, "port occupé")
        core.setListenerStatus(.portBusy)
        XCTAssertEqual(lignesDuJournal(contenant: "publication bloquée : port occupé"), 1)
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
        let core = moteur(ecoute: .portBusy)
        core.start()
        for _ in 0..<5 { scruter(core, 0.5) }
        XCTAssertEqual(lignesDuJournal(contenant: "publication bloquée"), 1)
        XCTAssertTrue(journalContient("publication bloquée : port occupé"))

        core.setListenerStatus(.ready)
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
        let core = moteur(ecoute: .portBusy)
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
        let core = moteur(ecoute: .portBusy)
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

        core.setListenerStatus(.portBusy)
        planificateur.runDue(at: horloge.t + 600)
        client.networkBecameAvailable()
        core.heartbeat()
        core.resync()
        XCTAssertEqual(transport.requetes.count, avant, "rien ne part : ni réessai lent, ni réseau, ni battement")

        transport.reponseParDefaut = .delivered(status: 200)
        core.setListenerStatus(.ready)
        XCTAssertEqual(transport.requetes.count, avant + 1, "une seule requête au retour, en force")
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1")
        planificateur.runDue(at: horloge.t + 600)
        XCTAssertEqual(transport.requetes.count, avant + 1)
    }

    // MARK: - Relecture finale : resynchronisation pendant la veille, réseau pendant l'arrêt

    /// `resync()` pendant une veille annoncée (sans réveil) ne remet pas `system_asleep` à faux :
    /// l'état reste OFF, republié en force.
    func test_resyncPendantUneVeille_gardeLaVeille() {
        let core = moteur()
        core.start()
        core.willSleep {}
        XCTAssertFalse(core.currentState)
        core.resync()
        let faits = core.statusSnapshot()["facts"] as? [String: Any]
        XCTAssertEqual(faits?["system_asleep"] as? Bool, true)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publieur.publications.last, Publication(etat: false, force: true))

        // Après le réveil, la resynchronisation reprend son cours ordinaire.
        core.handle(.systemDidWake)
        core.resync()
        XCTAssertTrue(core.currentState)
    }

    /// Veille annulée : `resync()` remet bien `system_asleep` à faux (aucune veille en cours).
    func test_resyncApresVeilleAnnulee_veilleOubliee() {
        let core = moteur()
        core.start()
        core.willSleep {}
        core.handle(.systemWillNotSleep)
        core.resync()
        let faits = core.statusSnapshot()["facts"] as? [String: Any]
        XCTAssertEqual(faits?["system_asleep"] as? Bool, false)
        XCTAssertTrue(core.currentState)
    }

    /// Le retour du réseau est transmis au publieur, sauf pendant l'arrêt.
    func test_retourDuReseau_transmisSaufPendantLArret() {
        let core = moteur()
        core.start()
        core.networkBecameAvailable()
        XCTAssertEqual(publieur.avisReseau, 1)
        core.shutdown(publishOff: true) {}
        core.networkBecameAvailable()
        XCTAssertEqual(publieur.avisReseau, 1, "avis ignoré pendant l'arrêt")
    }

    /// De bout en bout avec le vrai client : OFF d'arrêt en échec, le réseau revient pendant l'arrêt
    /// → aucune requête de plus.
    func test_clientReel_retourDuReseauPendantLArret_rienNePart() {
        let transport = FakeTransport(clock: horloge)
        let planificateur = TestScheduler(clock: horloge)
        let client = clientWebhook(transport, planificateur)
        let core = moteur(publieur: client)
        core.start()
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        core.shutdown(publishOff: true) {}
        let avant = transport.requetes.count
        XCTAssertGreaterThan(avant, 1, "l'OFF d'arrêt est parti")
        horloge.advance(5)
        core.networkBecameAvailable()
        XCTAssertEqual(transport.requetes.count, avant, "le retour du réseau ne relance rien pendant l'arrêt")
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

    // MARK: - Indices de scan des process d'économiseur (plan 3, tâche 1)

    /// Ruling R55 : l'événement donne son indice une seule fois, AVANT que le moteur relise les faits.
    /// Sinon la relecture qu'il déclenche pourrait ne pas chercher le process tout neuf.
    private func verifierUnIndiceAvantLaRelecture(_ evenement: SystemEvent,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        let core = moteur()
        core.start()
        XCTAssertEqual(signaux.indicesProcess, 0, "aucun indice au démarrage", file: file, line: line)
        let lecturesAvant = signaux.lecturesPID

        core.handle(evenement)

        XCTAssertEqual(signaux.indicesProcess, 1, file: file, line: line)
        XCTAssertEqual(signaux.lecturesPIDAuxIndices, [lecturesAvant],
                       "l'indice précède la relecture des faits", file: file, line: line)
        XCTAssertGreaterThan(signaux.lecturesPID, lecturesAvant, "la relecture a bien lieu", file: file, line: line)
    }

    func test_didstart_demandeUnScanDesProcess() {
        verifierUnIndiceAvantLaRelecture(.screenSaverDidStart)
    }

    func test_didstop_demandeUnScanDesProcess() {
        verifierUnIndiceAvantLaRelecture(.screenSaverDidStop)
    }

    func test_processEconomiseurChange_demandeUnScanDesProcess() {
        verifierUnIndiceAvantLaRelecture(.saverProcessChanged)
    }

    /// Un indice par scrutation annulerait la politique de balayage (un scan toutes les 5 s) : ni la
    /// scrutation ordinaire ni les autres événements n'en donnent.
    func test_scrutationEtAutresEvenements_neDonnentAucunIndice() {
        let core = moteur()
        core.start()
        for _ in 0..<4 { scruter(core, 0.5) }
        let autres: [SystemEvent] = [.systemWillNotSleep, .screensDidSleep, .screensDidWake, .screenLocked,
                                     .screenUnlocked, .sessionActive, .sessionInactive, .systemDidWake]
        for evenement in autres { core.handle(evenement) }
        core.resync()
        XCTAssertEqual(signaux.indicesProcess, 0)
        XCTAssertGreaterThan(signaux.lecturesPID, 0, "les faits ont bien été relus")
    }

    /// L'OFF par économiseur lance `ScreenSaverEngine` : la lecture suivante doit le chercher tout de
    /// suite, sans attendre l'échéance du balayage.
    func test_offParEconomiseur_demandeUnScanDesProcess() {
        let core = moteur()
        core.start()
        XCTAssertEqual(signaux.indicesProcess, 0)

        core.requestOff(peer: "essai")

        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])
        XCTAssertEqual(signaux.indicesProcess, 1)
    }

    /// Une extinction de l'écran, choisie ou imposée par la session verrouillée, ne lance aucun
    /// économiseur : rien à chercher.
    func test_offParExtinctionDEcran_neDemandePasDeScan() {
        var config = Config()
        config.offAction = .displaySleep
        let configuree = moteur(config)
        configuree.start()
        configuree.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.displaySleep)])
        XCTAssertEqual(signaux.indicesProcess, 0)

        signaux = Self.signauxDeBureau()
        signaux.etatSession.locked = true
        actions = FakeActions()
        publieur = FakePublisher()
        let verrouillee = moteur()
        verrouillee.start()
        verrouillee.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.displaySleep)], "session verrouillée : extinction de l'écran")
        XCTAssertEqual(signaux.indicesProcess, 0)
    }

    // MARK: - Économiseur sous macOS 27 (plan 3, tâche 2)

    /// F03 : l'économiseur d'inactivité de macOS 27 n'a pas de `ScreenSaverEngine` ; SAC le voit, et OFF
    /// part après le lissage de 800 ms.
    func test_economiseurDInactivite_publieOFF() {
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        signaux.drapeauSAC = true
        core.handle(.screenSaverDidStart)
        XCTAssertTrue(core.currentState, "OFF attend le lissage")
        signaux.inactiviteHID += 0.5
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        signaux.inactiviteHID += 0.5
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "screensaver:sac")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false)])
    }

    /// Point de vigilance 1 : un simple verrouillage (⌃⌘Q) laisse SAC à 0. L'écran de verrouillage est une
    /// UI accessible : ON, jamais `screensaver`, même bien au-delà de 30 s sans activité.
    func test_verrouillageSimple_sansSAC_resteSurLEcranDeVerrouillage() {
        let core = moteur()
        core.start()
        signaux.etatSession.locked = true
        core.handle(.screenLocked)
        for _ in 0..<80 {
            signaux.inactiviteHID += 0.5
            scruter(core, 0.5)
        }
        XCTAssertTrue(core.currentState)
        // La raison publiée reste celle de la dernière transition (ON → ON n'en est pas une) : la raison
        // des faits se lit par `inspect()`.
        let lecture = core.inspect()
        XCTAssertTrue(lecture.state)
        XCTAssertEqual(lecture.reason, "lock-screen-ui")
        XCTAssertEqual(lecture.facts.screenSaverEvidence, "none")
        XCTAssertFalse(lecture.facts.screenSaverRunning)
        XCTAssertFalse(publieur.publications.contains { !$0.etat }, "aucun OFF")
    }

    /// Réveil du Mac pendant une session d'économiseur (SAC toujours à 1) : la session est gardée, l'état
    /// reste OFF, sans passer par ON.
    func test_reveilAvecSessionSAC_resteOFF() {
        let core = moteur()
        core.start()
        signaux.drapeauSAC = true
        core.handle(.screenSaverDidStart)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)

        core.willSleep {}
        horloge.advance(60)
        signaux.inactiviteHID += 60
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "screensaver:sac")
        for _ in 0..<10 {
            signaux.inactiviteHID += 0.5
            scruter(core, 0.5)
        }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "screensaver:sac")
        XCTAssertFalse(publieur.publications.dropFirst().contains { $0.etat }, "aucun ON après l'état initial")
    }

    /// Au réveil (avis IOKit, fin de veille sans avis, rattrapages du trou couvert et du réveil perdu), au trou de
    /// scrutation et à la resynchronisation, le moteur fait oublier à l'oracle le `didstart` en attente (repli sans
    /// SAC) : un hôte apparu ensuite n'ouvre pas de session, et l'attente oubliée n'expire pas.
    func test_reveilEtResynchronisation_oublientLeDidstartEnAttente() {
        let declencheurs: [(String, (EngineCore) -> Void)] = [
            ("avis de réveil", { $0.handle(.systemDidWake) }),
            ("resynchronisation", { $0.resync() }),
            // Plan 3, tâche 5 : la veille annoncée n'aboutit pas, une frappe y met fin (2,7 s après l'annonce).
            ("fin de veille sans avis", { core in
                core.willSleep {}
                self.horloge.advance(3)
                self.signaux.inactiviteHID = 0.3
                core.tick()
            }),
            // Les deux rattrapages de `tick()` : plus de 5 s ont passé depuis le `didstart`, l'attente non oubliée
            // expirerait avec un avertissement.
            ("trou de scrutation couvert par la veille", { core in
                core.willSleep {}
                self.horloge.advance(15)
                core.tick()
            }),
            ("réveil perdu", { core in
                core.willSleep {}
                for _ in 0..<241 { self.scruterSansActivite(core, 0.5) }   // 120,5 s sans avis de réveil ni activité
            }),
        ]
        for (nom, declencher) in declencheurs {
            journal.lines = []
            signaux = Self.signauxDeBureau()
            signaux.drapeauSAC = nil
            let core = moteur()
            core.start()
            core.handle(.screenSaverDidStart)
            declencher(core)
            XCTAssertFalse(journalContient("didstart non corroboré"), "\(nom) : l'attente oubliée n'expire pas")
            let lectures = signaux.lecturesHotes
            signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
            for _ in 0..<4 { scruter(core, 0.5) }
            XCTAssertTrue(core.currentState, nom)
            XCTAssertEqual(signaux.lecturesHotes, lectures, "\(nom) : plus d'attente, les hôtes ne sont pas lus")
        }

        signaux = Self.signauxDeBureau()
        signaux.drapeauSAC = nil
        let core = moteur()
        core.start()
        core.handle(.screenSaverDidStart)
        scruter(core, 20)
        XCTAssertTrue(journalContient("interruption de 20.0 s détectée"))
        XCTAssertFalse(journalContient("didstart non corroboré"), "trou de scrutation : attente oubliée")
    }

    /// Point de vigilance 2 : une rafale de notifications ne coûte qu'une relecture des faits par 250 ms ;
    /// la scrutation rattrape le reste. L'indice de scan, lui, part à chaque notification (R55).
    /// Pas de 1/64 s : exacts en binaire, pour que la borne des 250 ms tombe juste.
    func test_rafaleDeNotifications_unRafraichissementPar250ms() {
        XCTAssertEqual(EngineCore.notificationRefreshMinInterval, 0.25)
        let core = moteur()
        core.start()
        let avant = signaux.lecturesSession

        // 10 didstart en 0,16 s.
        for _ in 0..<10 {
            core.handle(.screenSaverDidStart)
            horloge.advance(0.015625)
        }
        XCTAssertEqual(signaux.lecturesSession, avant + 1, "une seule relecture hors scrutation")
        XCTAssertEqual(signaux.indicesProcess, 10, "un indice par notification, avant le filtre")

        // didstop, verrouillage et déverrouillage partagent le même filtre.
        core.handle(.screenSaverDidStop)
        core.handle(.screenLocked)
        core.handle(.screenUnlocked)
        XCTAssertEqual(signaux.lecturesSession, avant + 1)
        XCTAssertEqual(signaux.indicesProcess, 11)

        // 250 ms après la dernière relecture due à une notification, la suivante relit les faits.
        horloge.advance(0.09375)
        core.handle(.screenLocked)
        XCTAssertEqual(signaux.lecturesSession, avant + 2)

        // La scrutation relit toujours, et ne compte pas pour le filtre.
        scruter(core, 0.5)
        XCTAssertEqual(signaux.lecturesSession, avant + 3)
        core.handle(.screenUnlocked)
        XCTAssertEqual(signaux.lecturesSession, avant + 4)
    }

    /// Point de vigilance 3 : sans SAC (macOS futur), un avertissement au démarrage, une seule fois.
    func test_sansSAC_avertissementAuDemarrage() {
        let message = "économiseur : SACScreenSaverIsRunning indisponible → repli sur l'hôte apparu après didstart ; "
            + "les paysages aériens ne seront pas détectés"
        let avecSAC = moteur()
        avecSAC.start()
        XCTAssertFalse(journal.lines.contains { $0.1 == message })

        signaux.drapeauSAC = nil
        let sansSAC = moteur()
        sansSAC.start()
        for _ in 0..<4 { scruter(sansSAC, 0.5) }
        sansSAC.handle(.screenSaverDidStart)
        XCTAssertEqual(journal.lines.filter { $0.0 == .warn && $0.1 == message }.count, 1)
    }

    /// `/status` dit comment l'économiseur est détecté : par SAC, ou par l'hôte apparu après didstart.
    func test_statusDitLaSourceDeDetection() {
        let core = moteur()
        core.start()
        XCTAssertEqual(core.statusSnapshot()["saver_detection"] as? String, "sac")
        signaux.drapeauSAC = true
        XCTAssertEqual(core.statusSnapshot()["saver_detection"] as? String, "sac")
        signaux.drapeauSAC = nil
        XCTAssertEqual(core.statusSnapshot()["saver_detection"] as? String, "hôte")
    }

    // MARK: - Écartement de l'économiseur par la commande du système (plan 3, tâche 3)

    /// C24 : un ON sur un économiseur seul à l'écran le réveille, puis l'écarte par la commande du système.
    /// Le panneau de connexion apparaît par-dessus l'économiseur, qui tourne encore (SAC reste à 1) : l'oracle
    /// compte l'arrêt natif comme une activité, sans grâce, et l'évaluation suivante confirme l'ON.
    func test_onSurEconomiseurSeul_ecarteParLeSystemeEtConfirme() {
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()
        XCTAssertFalse(core.currentState, "économiseur seul à l'écran : OFF")
        XCTAssertEqual(preuveEconomiseur(core), "sac")

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "le réveil d'abord, puis l'écartement")
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "on")
        XCTAssertEqual(actions.appelsReveil, [], "R47 : rien n'est relâché dans l'évaluation du réveil")

        // L'évaluation suivante relit les faits : le panneau recouvre l'économiseur, l'ON est confirmé.
        scruterSansActivite(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande on confirmée par les faits en 0.5 s (desktop-ui)"))
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-commande")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "un seul écartement")
    }

    /// Repli sans `SACScreenSaverStopNow` : `killall ScreenSaverEngine` n'écarte rien de l'économiseur
    /// d'inactivité sous macOS 27. Aucun écartement n'est supposé (l'oracle n'est pas prévenu) : la
    /// confirmation attend les faits, ici la fin de la session.
    func test_onSurEconomiseurSeul_repliKillall_attendLesFaits() {
        actions.moyenEcartement = .processKill
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "le repli est lancé aussi")
        for _ in 0..<3 { scruterSansActivite(core, 0.5) }
        XCTAssertNotNil(commandeEnAttente(core), "aucun écartement supposé : l'intention attend les faits")
        XCTAssertEqual(preuveEconomiseur(core), "sac", "l'oracle n'a pas été prévenu d'un arrêt natif")
        XCTAssertTrue(core.currentState, "l'intention ON tient l'état")
        XCTAssertEqual(actions.appelsReveil, [])

        // La session se termine (deux lectures sans source de suite) : les faits confirment l'ON.
        signaux.drapeauSAC = false
        scruterSansActivite(core, 0.5)
        XCTAssertNotNil(commandeEnAttente(core), "une lecture sans source ne ferme pas la session")
        scruterSansActivite(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande on confirmée par les faits"))
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
    }

    /// `stop_screensaver_on_wake` à faux : un ON réveille sans jamais écarter l'économiseur, ni à la commande
    /// ni à l'escalade (nouvelle tentative de réveil, comme avant).
    func test_onAvecStopDesactive_nEcartePas() {
        var config = Config()
        config.stopScreensaverOnWake = false
        signaux.drapeauSAC = true
        let core = moteur(config)
        core.start()

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        for _ in 0..<5 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(actions.appels, [.wake, .wake], "2,5 s : l'escalade renouvelle le réveil, sans écarter")
        XCTAssertTrue(journalContient("escalade: nouvelle tentative de réveil"))
        XCTAssertEqual(preuveEconomiseur(core), "sac")
        XCTAssertNotNil(commandeEnAttente(core))
    }

    /// Même option à faux, sur un Mac déjà ON dont l'économiseur tourne (R30) : le réveil seul.
    func test_onSurMacDejaON_stopDesactive_reveilSansEcartement() {
        var config = Config()
        config.stopScreensaverOnWake = false
        let core = moteur(config)
        mettreLePanneauSurUnEconomiseurSAC(core)

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("économiseur en marche"))
    }

    /// Bureau, économiseur SAC, puis une frappe 2 s plus tard : le panneau recouvre l'économiseur, qui tourne
    /// encore. 20 s sans activité plus tard, l'oracle suppose encore le panneau visible (ON), alors que
    /// macOS a pu revenir à l'économiseur (R30). La dernière frappe date de `T0 + 2 s`, T0 étant l'instant
    /// du démarrage ; l'horloge est à `T0 + 22 s` au retour.
    private func mettreLePanneauSurUnEconomiseurSAC(_ core: EngineCore) {
        signaux.drapeauSAC = true
        core.start()
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState)
        signaux.inactiviteHID = 0
        for _ in 0..<40 { scruterSansActivite(core, 0.5) }
        XCTAssertTrue(core.currentState, "le panneau est supposé visible")
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-activité")
        XCTAssertEqual(actions.appels, [])
    }

    /// R30 + C24 : le Mac est déjà ON (l'oracle suppose le panneau visible) mais l'économiseur tourne. /wake
    /// le réveille, sans intention, et l'écarte aussi par la commande du système : si macOS est déjà revenu
    /// à l'économiseur, le panneau reparaît pour 30 s de plus. Le réveil léger (R49) reste pour les cas sans
    /// session d'économiseur.
    func test_onSurMacDejaON_economiseurEnMarche_ecarteAussi() {
        let core = moteur()
        mettreLePanneauSurUnEconomiseurSAC(core)

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
        XCTAssertNil(commandeEnAttente(core), "aucune intention")
        XCTAssertTrue(core.currentState)
        XCTAssertTrue(journalContient("économiseur en marche"))
        XCTAssertFalse(journalContient("réveil léger"))

        // Sans l'arrêt natif, le panneau serait retiré 30 s après la frappe, soit à T0 + 32 s. Il tient 30 s
        // après l'arrêt : à T0 + 33 s, l'état est toujours ON.
        for _ in 0..<22 { scruterSansActivite(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-commande")
        // À T0 + 54 s, 32 s après l'arrêt, macOS est revenu à l'économiseur : OFF, sans nouvelle commande.
        for _ in 0..<42 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(preuveEconomiseur(core), "sac")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
    }

    /// L'escalade d'un ON (2,5 s) dont l'économiseur est encore seul à l'écran l'écarte de nouveau, au lieu de
    /// renouveler le réveil. Ici le premier écartement n'a rien changé (repli `killall`, sans effet sous
    /// macOS 27 sur l'économiseur d'inactivité).
    func test_escaladeOn_economiseurEncoreSeul_ecarteEncore() {
        actions.moyenEcartement = .processKill
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])

        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "2,0 s : pas d'escalade")

        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver, .dismissScreenSaver], "2,5 s : écarté de nouveau")
        XCTAssertEqual(commandeEnAttente(core)?["escalated"] as? Bool, true)
        XCTAssertTrue(journalContient("escalade: écartement de l'économiseur"), "\(journal.lines)")

        // Une seule escalade.
        for _ in 0..<10 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver, .dismissScreenSaver])
    }

    /// Écran éteint sous une session d'économiseur : au moment du ON, les faits ne voient pas l'économiseur
    /// (écran éteint : non évalué), donc rien n'est écarté. L'écran se rallume sur l'économiseur, seul à
    /// l'écran : l'escalade l'écarte par la commande du système, et l'évaluation suivante confirme l'ON.
    func test_escaladeOn_ecranRallumeSurEconomiseur_ecarteParLeSysteme() {
        signaux.drapeauSAC = true
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake], "écran éteint : l'économiseur n'est pas évalué, rien à écarter")

        signaux.etatEcran.asleep = false
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(preuveEconomiseur(core), "sac", "l'écran est rallumé sur l'économiseur")
        XCTAssertNotNil(commandeEnAttente(core))
        XCTAssertEqual(actions.appels, [.wake], "2,0 s : pas d'escalade")

        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "2,5 s : l'escalade écarte l'économiseur")
        scruterSansActivite(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-commande")
        XCTAssertTrue(core.currentState)
    }

    /// R52 : un /wake sur un Mac déjà ON pose un réveil léger (jamais relâché dans la même évaluation). Un
    /// OFF qui arrive avant l'évaluation suivante le relâche, puis lance l'économiseur : l'assertion et son
    /// `caffeinate` ne survivent pas à l'OFF.
    func test_reveilLegerPuisOFF_relacheEtExecuteLOFF() {
        let core = moteur()
        core.start()

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(actions.appelsReveil, [], "le réveil léger tient jusqu'à l'évaluation suivante")

        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "l'OFF relâche le réveil léger")
        XCTAssertEqual(actions.appels, [.wake, .runOff(.screensaver)], "puis exécute l'OFF")
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/screensaver")
        XCTAssertFalse(core.currentState)
        XCTAssertTrue(journalContient("assertion de réveil relâchée (commande OFF)"))

        // L'évaluation suivante ne relâche rien de plus.
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// Le moyen d'écartement est journalisé une fois, au démarrage : INFO s'il est natif, WARN pour le repli.
    func test_demarrage_journaliseLeMoyenDEcartement() {
        let natif = moteur()
        natif.start()
        for _ in 0..<3 { scruter(natif, 0.5) }
        XCTAssertEqual(journal.lines.filter { $0.0 == .info && $0.1.contains("SACScreenSaverStopNow") }.count, 1)
        XCTAssertFalse(journal.lines.contains { $0.0 == .warn && $0.1.contains("SACScreenSaverStopNow") })

        journal.lines = []
        actions.moyenEcartement = .processKill
        let repli = moteur()
        repli.start()
        for _ in 0..<3 { scruter(repli, 0.5) }
        let avertissement = "SACScreenSaverStopNow indisponible → repli killall ScreenSaverEngine, "
            + "sans effet sous macOS 27 sur l'économiseur d'inactivité"
        XCTAssertEqual(journal.lines.filter { $0.0 == .warn && $0.1 == avertissement }.count, 1)
        XCTAssertFalse(journal.lines.contains { $0.0 == .info && $0.1.contains("SACScreenSaverStopNow") })
    }

    /// `/status` dit par quel moyen l'économiseur est écarté : la commande du système, ou le repli.
    func test_statusDitLeMoyenDEcartement() {
        let natif = moteur()
        natif.start()
        XCTAssertEqual(natif.statusSnapshot()["saver_dismissal"] as? String, "SACScreenSaverStopNow")

        actions.moyenEcartement = .processKill
        let repli = moteur()
        repli.start()
        XCTAssertEqual(repli.statusSnapshot()["saver_dismissal"] as? String, "killall ScreenSaverEngine")
    }

    // MARK: - Écrans : fantôme, extinction, topologie (plan 3, tâche 4)

    /// Instantané d'une énumération réussie.
    private func lister(_ ecrans: DisplayInfo...) -> DisplaySnapshot {
        DisplaySnapshot(displays: ecrans, enumerationOK: true)
    }

    /// Lignes INFO de topologie du journal.
    private func lignesEcrans() -> [String] {
        journal.lines.filter { $0.0 == .info && $0.1.hasPrefix("écrans :") }.map { $0.1 }
    }

    /// Un virtuel principal (fournisseur `0x4321`, que rien ne distingue d'un écran physique) qui reste éveillé
    /// quand l'écran physique s'endort.
    private var virtuelPrincipal: DisplayInfo {
        DisplayInfo(id: 1, vendor: 0x4321, model: 0x5678, asleep: false, isMain: true)
    }

    /// Point de vigilance 5 : au réveil capot fermé ou dock débranché, macOS ne montre plus que l'écran fantôme.
    /// L'état publié tient 5 s (`displays-reconfiguring`) : les écrans physiques reviennent d'eux-mêmes. Passé ce
    /// délai, plus aucun écran n'est là : `no-display`, publié après le lissage de 800 ms.
    func test_ecranFantomeSeul_tient5sPuisNoDisplay() {
        XCTAssertEqual(EngineCore.noDisplayHoldSeconds, 5)
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(core, 0.5)  // première lecture sans écran physique : le délai démarre
        let premiere = core.inspect()
        XCTAssertEqual(premiere.reason, "displays-reconfiguring")
        XCTAssertEqual(premiere.facts.onlineDisplays, 0)
        XCTAssertTrue(premiere.facts.displayEnumerationOK)
        XCTAssertEqual(core.statusSnapshot()["facts_verdict"] as? String, "1", "le verdict des faits tient l'ON")

        for _ in 0..<9 { scruter(core, 0.5) }  // 4,5 s après la première lecture
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)], "rien n'est publié")

        scruter(core, 0.5)  // 5,0 s : le délai est écoulé, le lissage de l'OFF commence
        XCTAssertEqual(core.inspect().reason, "no-display")
        XCTAssertEqual(core.statusSnapshot()["facts_verdict"] as? String, "0")
        XCTAssertTrue(core.currentState, "OFF attend le lissage de 800 ms")
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "no-display")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false)])
    }

    /// Les écrans physiques reviennent avant la fin du délai : l'état publié n'a jamais bougé, aucun OFF.
    func test_ecranFantomeSeul_ecransPhysiquesDeRetourAvant5s_aucunOFF() {
        let core = moteur()
        core.start()
        signaux.ecrans = lister(.fantome(9, main: true))
        for _ in 0..<8 { scruter(core, 0.5) }  // 3,5 s après la première lecture
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")

        signaux.ecrans = lister(.physique(1, main: true), .fantome(9))
        for _ in 0..<20 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().reason, "desktop-ui")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)])

        // Le délai est remis à zéro : un nouveau fantôme seul repart de 5 s.
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(core, 0.5)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
    }

    /// Le Mac se réveille sur le fantôme seul : l'OFF de la veille tient (`displays-reconfiguring`) jusqu'au
    /// retour des écrans physiques, qui ramènent l'ON. Jamais d'ON sur le fantôme.
    func test_ecranFantomeAuReveil_resteOFFJusquAuxEcransPhysiques() {
        let core = moteur()
        core.start()
        core.willSleep {}
        XCTAssertFalse(core.currentState, "OFF de veille")

        horloge.advance(1)
        signaux.ecrans = lister(.fantome(9, main: true))
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
        for _ in 0..<8 { scruter(core, 0.5) }  // 4 s sur le fantôme seul
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
        XCTAssertEqual(publieur.publications.filter(\.etat).count, 1, "aucun ON depuis l'état initial")

        // Les écrans physiques reviennent : ON après le lissage de 300 ms.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2), .fantome(9))
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: false))
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "desktop-ui")
    }

    /// Point de vigilance 5, second volet : le fantôme est l'écran principal et reste éveillé, mais les écrans
    /// physiques s'éteignent : `display-asleep`.
    func test_fantomePrincipal_ecransPhysiquesEteints_moteurDitDisplayAsleep() {
        signaux.ecrans = lister(.fantome(9, main: true), .physique(1), .physique(2))
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        signaux.ecrans = lister(.fantome(9, main: true), .physique(1, asleep: true), .physique(2, asleep: true))
        scruter(core, 0.5)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "display-asleep")
        XCTAssertEqual(core.inspect().facts.displayEvidence, "all")
        XCTAssertTrue(journalContient("display_off=1(all)"), "les faits journalisés donnent la preuve")
    }

    /// L'avis `screensDidSleep` départage un virtuel resté éveillé : tant qu'un écran physique dort, l'affichage
    /// est éteint. Dès que plus aucun écran physique ne dort, l'avis est effacé : s'il se rendort sans nouvel
    /// avis, rien ne le retient plus.
    func test_avisEcransEteints_effaceQuandUnEcranSeReveille() {
        signaux.ecrans = lister(virtuelPrincipal, .physique(2))
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        // L'écran physique s'endort, sans avis : le virtuel principal éveillé garde l'état ON.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "awake")

        // L'avis du système départage : écran éteint, OFF après le lissage.
        core.handle(.screensDidSleep)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep")
        XCTAssertTrue(core.inspect().facts.displayAsleep)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "display-asleep")

        // Plus aucun écran physique endormi : l'avis est effacé, l'ON revient.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2))
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)

        // Il se rendort sans nouvel avis : l'ancien avis ne revient pas.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "awake")
    }

    /// L'avis s'efface aussi sur le réveil des écrans, sur le réveil du système (avis IOKit, fin de veille sans avis,
    /// ou l'un des deux rattrapages de `tick()` : trou couvert par la veille, réveil perdu) et à la
    /// resynchronisation, même si un écran physique dort encore : l'avis dit alors une chose périmée.
    func test_avisEcransEteints_effaceParLesReveilsEtLaResynchronisation() {
        let effaceurs: [(String, (EngineCore) -> Void)] = [
            ("réveil des écrans", { $0.handle(.screensDidWake) }),
            ("réveil du système", { $0.handle(.systemDidWake) }),
            ("resynchronisation", { $0.resync() }),
            // Plan 3, tâche 5 : la veille annoncée n'aboutit pas, une frappe y met fin (2,7 s après l'annonce).
            ("fin de veille sans avis", { core in
                core.willSleep {}
                self.horloge.advance(3)
                self.signaux.inactiviteHID = 0.3
                core.tick()
            }),
            // Les deux rattrapages de `tick()` font la même tenue de compte que l'avis IOKit.
            ("trou de scrutation couvert par la veille", { core in
                core.willSleep {}
                self.horloge.advance(15)
                core.tick()
            }),
            ("réveil perdu", { core in
                core.willSleep {}
                for _ in 0..<241 { self.scruterSansActivite(core, 0.5) }   // 120,5 s sans avis de réveil ni activité
            }),
        ]
        for (nom, effacer) in effaceurs {
            signaux = Self.signauxDeBureau()
            signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
            let core = moteur()
            core.start()
            XCTAssertEqual(core.inspect().facts.displayEvidence, "awake", nom)
            core.handle(.screensDidSleep)
            XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep", nom)

            effacer(core)
            XCTAssertEqual(core.inspect().facts.displayEvidence, "awake", "\(nom) : l'avis est effacé")
        }
    }

    /// Une ligne INFO « écrans : <résumé> » quand l'ensemble des écrans, l'écran principal ou la présence du
    /// fantôme change ; la première lecture est journalisée une fois. Aucune quand un écran s'endort ou se réveille,
    /// quand l'ordre de la liste change seul, ni pendant une énumération qui échoue.
    func test_topologie_journaliseeAuChangement() {
        let core = moteur()
        core.start()
        XCTAssertEqual(lignesEcrans(), ["écrans : 0x1*"], "première lecture, une seule fois")
        for _ in 0..<3 { scruter(core, 0.5) }
        XCTAssertEqual(lignesEcrans().count, 1, "rien ne change : rien n'est journalisé")

        // Un écran s'ajoute.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans(), ["écrans : 0x1*", "écrans : 0x1*,0x2"])

        // Un écran s'endort, puis tous, puis tous se réveillent : aucune ligne.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2, asleep: true))
        scruter(core, 0.5)
        signaux.ecrans = lister(.physique(1, asleep: true, main: true), .physique(2, asleep: true))
        scruter(core, 0.5)
        core.handle(.screensDidSleep)
        signaux.ecrans = lister(.physique(1, main: true), .physique(2))
        core.handle(.screensDidWake)
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().count, 2, "endormir et réveiller ne journalise rien")

        // Le fantôme apparaît.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2), .fantome(9))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x1*,0x2,0x9v")

        // L'écran principal change.
        signaux.ecrans = lister(.physique(1), .physique(2, main: true), .fantome(9))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x1,0x2*,0x9v")
        XCTAssertEqual(lignesEcrans().count, 4)

        // Même ensemble dans un autre ordre : rien.
        signaux.ecrans = lister(.fantome(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().count, 4, "l'ensemble des écrans est comparé, pas l'ordre de la liste")

        // Mêmes identifiants, même principal, mais l'écran 9 n'est plus le fantôme : sa présence change. Puis il
        // le redevient.
        signaux.ecrans = lister(.physique(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x9,0x2*,0x1")
        signaux.ecrans = lister(.fantome(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x9v,0x2*,0x1")
        XCTAssertEqual(lignesEcrans().count, 6)

        // Une énumération ratée ne prouve rien : ni ligne, ni topologie oubliée.
        signaux.ecrans = DisplaySnapshot(displays: [], enumerationOK: false)
        scruter(core, 0.5)
        signaux.ecrans = lister(.fantome(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().count, 6)

        // Le fantôme disparaît.
        signaux.ecrans = lister(.physique(1), .physique(2, main: true))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x1,0x2*")
        XCTAssertEqual(lignesEcrans().count, 7)
    }

    /// Une énumération qui échoue ne prouve rien : elle ne démarre pas le délai de 5 s, et ne le remet pas à zéro.
    func test_enumerationRatee_neDemarreNiNeRemetAZeroLeDelaiDesEcrans() {
        let echec = DisplaySnapshot(displays: [], enumerationOK: false)

        // Elle ne le démarre pas : l'état tient (ON, rien n'est prouvé), le délai ne court qu'à la première
        // lecture réussie sans écran physique.
        signaux.ecrans = echec
        let core = moteur()
        core.start()
        for _ in 0..<8 { scruter(core, 0.5) }  // 4 s d'échecs
        XCTAssertEqual(core.inspect().reason, "desktop-ui")
        XCTAssertTrue(core.currentState)
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(core, 0.5)  // le délai démarre ici
        for _ in 0..<8 { scruter(core, 0.5) }  // 4 s plus tard, 8,5 s après le premier échec
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")

        // Elle ne le remet pas à zéro : 5 s après la première lecture sans écran physique, c'est fini.
        signaux = Self.signauxDeBureau()
        let autre = moteur()
        autre.start()
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(autre, 0.5)  // le délai démarre ici
        for _ in 0..<4 { scruter(autre, 0.5) }  // 2 s plus tard
        signaux.ecrans = echec
        for _ in 0..<3 { scruter(autre, 0.5) }  // 3,5 s plus tard : lectures qui échouent
        XCTAssertEqual(autre.inspect().reason, "desktop-ui", "énumération ratée : rien n'est prouvé")
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(autre, 0.5)  // 4,0 s
        XCTAssertEqual(autre.inspect().reason, "displays-reconfiguring")
        scruter(autre, 0.5)  // 4,5 s
        XCTAssertEqual(autre.inspect().reason, "displays-reconfiguring")
        scruter(autre, 0.5)  // 5,0 s
        XCTAssertEqual(autre.inspect().reason, "no-display", "le délai a couru pendant l'échec")
    }

    /// `/status` donne la topologie : l'écran principal, la liste des écrans (fantôme compris) et, dans les faits,
    /// la preuve d'extinction, le résumé et le nombre d'écrans physiques.
    func test_statusDonneLaTopologie() {
        signaux.ecrans = lister(.physique(0x5, main: true), .physique(0x2, asleep: true), .fantome(0x9))
        let core = moteur()
        core.start()
        let status = core.statusSnapshot()

        XCTAssertEqual(status["main_display"] as? String, "0x5")
        let liste = status["display_list"] as? [[String: Any]]
        XCTAssertEqual(liste?.count, 3)
        let attendue: [[String: Any]] = [
            ["id": "0x5", "main": true, "asleep": false, "placeholder": false],
            ["id": "0x2", "main": false, "asleep": true, "placeholder": false],
            ["id": "0x9", "main": false, "asleep": false, "placeholder": true],
        ]
        XCTAssertEqual(liste.map { $0 as NSArray }, attendue as NSArray)

        let faits = status["facts"] as? [String: Any]
        XCTAssertEqual(faits?["displays"] as? String, "0x5*,0x2z,0x9v")
        XCTAssertEqual(faits?["display_evidence"] as? String, "awake")
        XCTAssertEqual(faits?["online_displays"] as? Int, 2, "le fantôme n'est pas compté")
        XCTAssertEqual(faits?["display_asleep"] as? Bool, false)

        // Aucun écran principal : « none », comme pour une liste vide.
        signaux.ecrans = lister(.physique(0x2), .fantome(0x9))
        _ = core.inspect()
        XCTAssertEqual(core.statusSnapshot()["main_display"] as? String, "none")
        signaux.ecrans = lister()
        _ = core.inspect()
        let vide = core.statusSnapshot()
        XCTAssertEqual(vide["main_display"] as? String, "none")
        XCTAssertEqual((vide["display_list"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((vide["facts"] as? [String: Any])?["displays"] as? String, "none")
    }

    // MARK: - Veille avortée et réveils sombres (plan 3, tâche 5)

    /// Faits tels que `/status` les publie, sans relire le système.
    private func faitsPublies(_ core: EngineCore) -> [String: Any] {
        core.statusSnapshot()["facts"] as? [String: Any] ?? [:]
    }

    /// `facts.system_asleep` de `/status`.
    private func veilleSignalee(_ core: EngineCore) -> Bool? {
        faitsPublies(core)["system_asleep"] as? Bool
    }

    /// Moteur démarré (ON publié), puis une veille annoncée à l'instant courant, rendu avec le moteur : OFF
    /// `system-asleep`. Le Mac reste éveillé, comme au banc du 31/10 : la scrutation continue de tourner.
    private func moteurEnVeille() -> (core: EngineCore, annonce: Double) {
        let core = moteur()
        core.start()
        core.willSleep {}
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(veilleSignalee(core), true)
        return (core, horloge.t)
    }

    /// La ligne INFO exacte de fin de veille sans avis de réveil, avec sa cause entre parenthèses.
    private func finDeVeilleJournalisee(_ cause: String) -> Bool {
        journal.lines.contains { $0.0 == .info && $0.1 == "fin de la veille sans avis de réveil (\(cause))" }
    }

    /// C26 : la veille annoncée n'aboutit pas, puis une frappe, plus de 2 s après l'annonce, met fin à la veille
    /// sans attendre IOKit. `system_asleep` retombe, une ligne INFO le dit, et ON revient après le lissage de
    /// 300 ms (l'évaluation n'est pas immédiate), sans republication forcée.
    func test_frappeApresLAnnonce_metFinALaVeille() {
        XCTAssertEqual(EngineCore.sleepAbortInputMargin, 2)
        let (core, annonce) = moteurEnVeille()
        for _ in 0..<29 { scruterSansActivite(core, 0.5) }   // 14,5 s sans activité depuis l'annonce
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))

        // Une frappe 0,3 s avant la lecture de t + 15 s : à t + 14,7 s.
        signaux.inactiviteHID = 0.3
        scruter(core, 0.5)
        XCTAssertEqual(horloge.t - annonce, 15)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("activité 14.7 s après l'annonce"), "\(journal.lines)")
        XCTAssertFalse(core.currentState, "évaluation non immédiate : ON attend le lissage de 300 ms")

        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "desktop-ui")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false),
                                               Publication(etat: true, force: false)])
    }

    /// Le clic qui a demandé la veille précède l'annonce, ou la suit de moins de 2 s : il ne l'annule pas.
    func test_frappeAvantLAnnonce_neMetPasFinALaVeille() {
        let (core, _) = moteurEnVeille()
        signaux.inactiviteHID = 1.5
        scruter(core, 1)                // t + 1 s : dernière frappe à t − 0,5 s, avant l'annonce
        XCTAssertEqual(veilleSignalee(core), true)
        signaux.inactiviteHID = 0.2
        scruter(core, 0.5)              // t + 1,5 s : dernière frappe à t + 1,3 s, à moins de 2 s de l'annonce
        XCTAssertEqual(veilleSignalee(core), true)
        for _ in 0..<20 { scruterSansActivite(core, 0.5) }   // la dernière frappe reste à t + 1,3 s
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// La borne de la marge est stricte : une frappe à 2,0 s pile de l'annonce n'y met pas fin, une frappe à 2,5 s si.
    func test_margeDeDeuxSecondes_borneStricte() {
        let (core, _) = moteurEnVeille()
        signaux.inactiviteHID = 0.5
        scruter(core, 2.5)              // t + 2,5 s : dernière frappe à t + 2,0 s exactement
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))

        signaux.inactiviteHID = 0.5
        scruter(core, 0.5)              // t + 3 s : dernière frappe à t + 2,5 s
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("activité 2.5 s après l'annonce"), "\(journal.lines)")
    }

    /// Une inactivité illisible (−1) ne prouve aucune frappe : elle ne met jamais fin à la veille (sans cette
    /// garde, `now + 1` passerait pour une activité postérieure à l'annonce).
    func test_inactiviteIllisible_neMetPasFinALaVeille() {
        let (core, _) = moteurEnVeille()
        signaux.inactiviteHID = -1
        for _ in 0..<20 { scruter(core, 0.5) }   // 10 s
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// C26 : une session vue verrouillée depuis l'annonce, puis relue déverrouillée, met fin à la veille — à la
    /// scrutation ou sur l'avis de déverrouillage, que le verrou précède l'annonce ou la suive. L'inactivité HID
    /// continue de croître : aucune frappe n'entre en compte, seule la règle du déverrouillage joue.
    func test_deverrouillageApresLAnnonce_metFinALaVeille() {
        let declencheurs: [(String, (EngineCore) -> Void)] = [
            ("scrutation", { self.scruterSansActivite($0, 0.5) }),
            ("avis de déverrouillage", { core in
                self.horloge.advance(0.5)
                self.signaux.inactiviteHID += 0.5
                core.handle(.screenUnlocked)
            }),
        ]
        for verrouAvantLAnnonce in [true, false] {
            for (nom, deverrouiller) in declencheurs {
                let cas = "\(nom), verrou \(verrouAvantLAnnonce ? "avant" : "après") l'annonce"
                signaux = Self.signauxDeBureau()
                publieur = FakePublisher()
                journal.lines = []
                signaux.etatSession.locked = verrouAvantLAnnonce
                let (core, _) = moteurEnVeille()
                if !verrouAvantLAnnonce {
                    signaux.etatSession.locked = true
                    scruterSansActivite(core, 0.5)   // la session est vue verrouillée après l'annonce
                }
                for _ in 0..<10 { scruterSansActivite(core, 0.5) }   // toujours verrouillée, aucune activité
                XCTAssertEqual(veilleSignalee(core), true, cas)
                XCTAssertFalse(journalContient("fin de la veille"), cas)

                signaux.etatSession.locked = false
                deverrouiller(core)
                XCTAssertEqual(veilleSignalee(core), false, cas)
                XCTAssertTrue(finDeVeilleJournalisee("session déverrouillée"), "\(cas) : \(journal.lines)")
                XCTAssertFalse(core.currentState, "\(cas) : évaluation non immédiate")
                scruterSansActivite(core, 0.5)
                XCTAssertTrue(core.currentState, cas)
                XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "desktop-ui", cas)
                XCTAssertEqual(publicationsForcees, 0, cas)
            }
        }
    }

    /// Un avis de déverrouillage seul ne prouve rien : la session n'a jamais été vue verrouillée depuis l'annonce.
    func test_sessionJamaisVerrouillee_avisDeDeverrouillage_neMetPasFin() {
        let (core, _) = moteurEnVeille()
        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.handle(.screenUnlocked)
        for _ in 0..<10 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// L'indicateur « session vue verrouillée » est remis à zéro à chaque annonce de veille : un verrou vu avant la
    /// seconde annonce (sans réveil entre les deux) ne compte plus.
    func test_nouvelleAnnonce_remetAZeroLaSessionVueVerrouillee() {
        signaux.etatSession.locked = true
        let (core, _) = moteurEnVeille()   // vue verrouillée à la première annonce
        signaux.etatSession.locked = false
        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.willSleep {}                  // seconde annonce : la session est lue déverrouillée
        XCTAssertEqual(veilleSignalee(core), true)

        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.handle(.screenUnlocked)
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// Un avis de déverrouillage écarté par le filtre de 250 ms n'est pas perdu : le tick suivant relit la session
    /// et met fin à la veille.
    func test_avisDeDeverrouillageEcarteParLeFiltre_rattrapeAuTickSuivant() {
        signaux.etatSession.locked = true
        let (core, _) = moteurEnVeille()
        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.handle(.screenLocked)         // première relecture due à une notification : le filtre démarre
        horloge.advance(0.0625)
        signaux.inactiviteHID += 0.0625
        signaux.etatSession.locked = false
        core.handle(.screenUnlocked)       // écarté par le filtre : aucune relecture
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))

        scruterSansActivite(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("session déverrouillée"), "\(journal.lines)")
    }

    /// Le trou de scrutation d'une veille réelle passe avant la règle de l'activité : un Mac qui dort 40 s puis
    /// se réveille sur une frappe suit le chemin du trou couvert (une seule publication forcée, veille de plus de
    /// 30 s), non la fin de veille sans avis.
    func test_trouCouvertParUneVeilleLongue_activiteAuReveil_pasDeFinSansAvis() {
        let core = moteurEcranEteint()
        core.willSleep {}
        horloge.advance(40)
        signaux.inactiviteHID = 0.3
        core.tick()
        XCTAssertTrue(journalContient("couverte par la veille"), "\(journal.lines)")
        XCTAssertFalse(journalContient("fin de la veille"), "\(journal.lines)")
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")
        XCTAssertEqual(veilleSignalee(core), false)
    }

    /// Banc 1 (B6) : une entrée en veille retardée de 29 s ne déclenche aucun rattrapage du « réveil perdu » avant
    /// 120 s. La scrutation tourne sans activité : l'état reste OFF `system-asleep`.
    func test_entreeEnVeilleRetardee_pasDeRattrapageAvant120s() {
        let (core, annonce) = moteurEnVeille()
        for _ in 0..<58 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(horloge.t - annonce, 29)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "system-asleep")
        XCTAssertFalse(journalContient("réveil non signalé"))

        for _ in 0..<182 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(horloge.t - annonce, 120)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("réveil non signalé"), "\(journal.lines)")
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// Le cas du banc, en entier : l'entrée en veille tarde de 29 s, le Mac dort ensuite 8 s (daemon gelé) et se
    /// réveille 37 s après l'annonce — au-delà de l'ancien seuil de 35 s, mais avec un trou de scrutation de 8 s,
    /// sous le seuil de trou. Rien n'est rattrapé à tort : l'avis de réveil d'IOKit, en retard, est traité
    /// normalement (veille de plus de 30 s : republication forcée).
    func test_entreeEnVeilleRetardee_puisVeilleCourte_avisDeReveilTraiteNormalement() {
        let (core, annonce) = moteurEnVeille()
        for _ in 0..<58 { scruterSansActivite(core, 0.5) }
        horloge.advance(8)
        signaux.inactiviteHID += 8
        core.tick()
        XCTAssertEqual(horloge.t - annonce, 37)
        XCTAssertFalse(journalContient("réveil non signalé"), "\(journal.lines)")
        XCTAssertFalse(journalContient("interruption de"), "un trou de 8 s reste une scrutation normale")
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)

        core.handle(.systemDidWake)
        XCTAssertTrue(journalContient("réveil après 37.0 s de veille → republication forcée"), "\(journal.lines)")
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(core.currentState)
    }

    /// R56 : l'avis IOKit qui arrive après la fin de veille sans avis trouve la fin posée. Il ne force rien, même
    /// après plus de 30 s de veille annoncée, et n'envoie rien de plus.
    func test_avisIOKitApresLaFin_neForcePas() {
        let (core, _) = moteurEnVeille()
        for _ in 0..<64 { scruterSansActivite(core, 0.5) }   // 32 s : un avis normal forcerait la republication
        signaux.inactiviteHID = 0.3
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("activité 32.2 s après l'annonce"), "\(journal.lines)")
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publicationsForcees, 0, "\(publieur.publications)")
        let envois = publieur.envois.count

        core.handle(.systemDidWake)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publicationsForcees, 0, "\(publieur.publications)")
        XCTAssertEqual(publieur.envois.count, envois, "rien de plus n'est envoyé")
        XCTAssertFalse(journalContient("réveil après"), "la fin est déjà posée : la durée n'est plus annoncée")
    }

    /// Réveil sombre (maintenance, Power Nap) : le système se réveille, les écrans restent éteints. L'avis de
    /// réveil laisse l'état OFF (`display-asleep`) : aucun ON n'est publié, ni au réveil ni ensuite, jusqu'au
    /// rallumage des écrans.
    func test_reveilSombre_ecranEteint_resteOFF() {
        let (core, _) = moteurEnVeille()
        horloge.advance(300)
        signaux.inactiviteHID += 300
        signaux.etatEcran.asleep = true
        core.handle(.systemDidWake)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "display-asleep")
        for _ in 0..<20 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "display-asleep")
        XCTAssertFalse(publieur.publications.dropFirst().contains { $0.etat }, "aucun ON depuis l'état initial")

        // Les écrans se rallument : ON après le lissage de 300 ms.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
    }

    /// Un trou de scrutation qu'aucune veille n'explique (gel, surcharge) n'est pas un réveil : l'avis d'écrans
    /// éteints tient, contrairement à ce que font les trous couverts par une veille et le réveil perdu. Un virtuel
    /// principal éveillé ne ramène donc pas l'ON tant que l'écran physique dort.
    func test_trouNonCouvert_gardeLAvisDEcransEteints() {
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        let core = moteur()
        core.start()
        core.handle(.screensDidSleep)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep")

        scruter(core, 15)
        XCTAssertTrue(journalContient("interruption de 15.0 s détectée → resynchronisation"), "\(journal.lines)")
        XCTAssertFalse(journalContient("couverte par la veille"))
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep", "un gel n'est pas un réveil")
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "display-asleep")
    }

    // MARK: - Coût de la scrutation (plan 3, tâche 6)

    /// F78 : l'inactivité HID ne sert qu'à l'oracle de l'économiseur, que le moteur n'évalue ni pendant une veille ni
    /// écran éteint. Écran éteint, hors veille : aucune lecture, à aucun chemin de relecture des faits, et les faits
    /// gardés disent −1. Dès que l'écran se rallume, l'oracle revient et la lecture avec lui, une fois par relecture.
    func test_ecranEteint_neLitPasLInactivite() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        XCTAssertEqual(signaux.lecturesHID, 0, "le démarrage, écran éteint, ne lit pas l'inactivité")

        for _ in 0..<6 { scruterSansActivite(core, 0.5) }
        core.handle(.sessionActive)
        core.handle(.screensDidSleep)
        core.resync()
        XCTAssertEqual(signaux.lecturesHID, 0, "scrutations, notifications et resynchronisation, écran éteint")
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, -1, "non lue : −1, jamais une valeur périmée")
        XCTAssertEqual(signaux.lecturesHID, 0, "`--once` et `--watch` ne la lisent pas non plus")
        XCTAssertEqual(core.inspect().reason, "display-asleep")

        signaux.etatEcran.asleep = false
        core.handle(.screensDidWake)
        XCTAssertEqual(signaux.lecturesHID, 1, "écran rallumé : l'oracle est évalué, l'inactivité est lue")
        scruterSansActivite(core, 0.5)
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(signaux.lecturesHID, 3, "une lecture par scrutation")
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, signaux.inactiviteHID, accuracy: 0.001)
        XCTAssertEqual(signaux.lecturesHID, 4)
    }

    /// Exception de la tâche 5 : pendant une veille en cours, l'inactivité est lue même si l'oracle ne l'est pas
    /// (veille, écran éteint) : la fin d'une veille qui n'aboutit pas en dépend. Une frappe plus de 2 s après
    /// l'annonce y met fin, écran éteint compris ; la veille finie, l'écran toujours éteint, la lecture s'arrête.
    func test_veilleEnCours_litLInactivite() {
        signaux.etatEcran.asleep = true      // l'écran éteint, seul, couperait la lecture
        let (core, annonce) = moteurEnVeille()
        let avant = signaux.lecturesHID
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(horloge.t - annonce, 2)
        XCTAssertEqual(signaux.lecturesHID, avant + 4, "une lecture par scrutation pendant la veille en cours")
        XCTAssertEqual(veilleSignalee(core), true)

        signaux.inactiviteHID = 0.3          // une frappe 0,3 s avant la lecture de t + 2,5 s : à t + 2,2 s
        scruter(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), false, "\(journal.lines)")
        XCTAssertTrue(finDeVeilleJournalisee("activité 2.2 s après l'annonce"), "\(journal.lines)")

        let apres = signaux.lecturesHID
        scruterSansActivite(core, 0.5)
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(signaux.lecturesHID, apres, "veille finie, écran toujours éteint : plus de lecture")
    }

    /// `/status` relit l'inactivité à chaque appel : les faits gardés ne la portent plus hors de l'oracle (−1), et
    /// `facts.hid_idle_seconds` ne montre ni le −1 des faits gardés, ni la valeur de la dernière scrutation.
    func test_statusRelitLInactivite() {
        signaux.etatEcran.asleep = true      // les faits gardés disent −1
        let core = moteur()
        core.start()
        scruter(core, 0.5)
        XCTAssertEqual(signaux.lecturesHID, 0)

        signaux.inactiviteHID = 12.5
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, 12.5)
        signaux.inactiviteHID = 20
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, 20)
        XCTAssertEqual(signaux.lecturesHID, 2, "une lecture par appel")
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, -1, "/status ne réécrit pas les faits gardés")

        signaux.etatEcran.asleep = false     // écran allumé : la valeur de la scrutation précédente est périmée aussi
        scruter(core, 0.5)
        signaux.inactiviteHID = 7
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, 7)
        signaux.inactiviteHID = -1           // illisible : −1, comme avant
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, -1)
    }

    // MARK: - Observabilité et code mort (plan 3, tâche 7)

    private func raisonPubliee(_ core: EngineCore) -> String? {
        core.statusSnapshot()["reason"] as? String
    }

    /// F71 : « mêmes faits » veut dire tous les faits sauf l'inactivité HID, qui change à chaque lecture sans rien
    /// décider. Chaque autre champ, changé seul, donne d'autres faits. Le décompte par réflexion échoue si un champ
    /// est ajouté à `Facts` sans être traité ici (et dans `sameDecision`).
    func test_faits_memeDecisionMalgreLInactivite() {
        let base = Facts()
        var inactif = base
        inactif.hidIdleSeconds = 42.5
        XCTAssertTrue(base.sameDecision(as: inactif), "l'inactivité seule ne change aucune décision")
        inactif.hidIdleSeconds = -1
        XCTAssertTrue(base.sameDecision(as: inactif), "illisible (−1) non plus")

        let changements: [(champ: String, modifier: (inout Facts) -> Void)] = [
            ("systemAsleep", { $0.systemAsleep.toggle() }),
            ("displayAsleep", { $0.displayAsleep.toggle() }),
            ("onlineDisplays", { $0.onlineDisplays += 1 }),
            ("displayEnumerationOK", { $0.displayEnumerationOK.toggle() }),
            ("displayEvidence", { $0.displayEvidence = "main" }),
            ("displays", { $0.displays = [.physique(1, main: true)] }),
            ("screenSaverActive", { $0.screenSaverActive.toggle() }),
            ("screenSaverEvidence", { $0.screenSaverEvidence = "sac" }),
            ("screenSaverRunning", { $0.screenSaverRunning.toggle() }),
            ("screenSaverDismissed", { $0.screenSaverDismissed.toggle() }),
            ("sessionLocked", { $0.sessionLocked.toggle() }),
            ("lockEvidence", { $0.lockEvidence = "IOConsoleLocked" }),
            ("consoleUserLoggedIn", { $0.consoleUserLoggedIn.toggle() }),
            ("onConsole", { $0.onConsole.toggle() }),
            ("secureInputActive", { $0.secureInputActive.toggle() }),
        ]
        for (champ, modifier) in changements {
            var autre = base
            modifier(&autre)
            XCTAssertFalse(base.sameDecision(as: autre), champ)
            XCTAssertFalse(autre.sameDecision(as: base), "\(champ), sens inverse")
            autre.hidIdleSeconds += 7
            XCTAssertFalse(base.sameDecision(as: autre), "\(champ), l'inactivité en plus ne l'efface pas")
        }
        XCTAssertEqual(changements.count + 1, Mirror(reflecting: base).children.count,
                       "un champ de Facts n'est pas traité ici (l'inactivité est le +1)")

        // La liste des écrans se compare en entier : un écran qui s'endort fait d'autres faits.
        var deux = base
        deux.displays = [.physique(1, main: true), .physique(2)]
        var identiques = base
        identiques.displays = [.physique(1, main: true), .physique(2)]
        XCTAssertTrue(deux.sameDecision(as: identiques))
        identiques.displays = [.physique(1, main: true), .physique(2, asleep: true)]
        XCTAssertFalse(deux.sameDecision(as: identiques))
    }

    /// F71 : l'inactivité change à chaque scrutation, écran allumé. La ligne DEBUG « faits: » ne part plus que
    /// pour un changement qui compte.
    func test_faits_ligneDeDebugSeulementAuChangement() {
        let core = moteur()
        core.start()
        func lignesFaits() -> [String] {
            journal.lines.filter { $0.0 == .debug && $0.1.hasPrefix("faits:") }.map { $0.1 }
        }
        let avant = lignesFaits().count
        XCTAssertGreaterThan(avant, 0, "la première lecture des faits est écrite")

        for _ in 0..<10 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, 35, accuracy: 0.001, "l'inactivité a bien grandi de 5 s")
        XCTAssertEqual(lignesFaits().count, avant, "dix scrutations où seule l'inactivité change : aucune ligne")

        signaux.etatSession.locked = true
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(lignesFaits().count, avant + 1, "un vrai changement s'écrit, lui")
        XCTAssertTrue(lignesFaits().last?.contains("locked=1") ?? false, "\(lignesFaits())")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(lignesFaits().count, avant + 1, "et une seule fois")
    }

    /// F44 : une fois l'état stable et inchangé, la raison publiée suit la raison courante, sans republier. Avant,
    /// elle restait collée sur `command:on` (ou sur `displays-reconfiguring`) jusqu'à la transition suivante.
    func test_raisonSuitLesFaitsSansRepublier() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        XCTAssertEqual(raisonPubliee(core), "display-asleep")

        core.requestOn(peer: "essai")
        XCTAssertEqual(raisonPubliee(core), "command:on")
        XCTAssertTrue(core.currentState)
        let publications = publieur.publications

        // Les faits confirment la commande : la raison passe à celle des faits, l'état est le même.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(raisonPubliee(core), "desktop-ui")
        XCTAssertTrue(journal.lines.contains { $0.0 == .debug && $0.1 == "raison : command:on → desktop-ui" },
                      "\(journal.lines)")

        // La session se verrouille : toujours ON, la raison suit, rien n'est republié.
        signaux.etatSession.locked = true
        scruter(core, 0.5)
        XCTAssertEqual(raisonPubliee(core), "lock-screen-ui")
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications, publications, "aucune nouvelle publication")
        XCTAssertTrue(journal.lines.contains { $0.0 == .debug && $0.1 == "raison : desktop-ui → lock-screen-ui" })
        let lignes = journal.lines.count
        scruter(core, 0.5)
        XCTAssertEqual(journal.lines.count, lignes, "rien ne change : rien n'est écrit")

        // Les écrans physiques disparaissent (seul le fantôme reste) : l'état publié tient, la raison le dit, puis elle
        // revient avec les écrans.
        signaux.etatSession.locked = false
        signaux.ecrans = DisplaySnapshot(displays: [.fantome(9, main: true)], enumerationOK: true)
        scruter(core, 0.5)
        XCTAssertEqual(raisonPubliee(core), "displays-reconfiguring")
        XCTAssertTrue(core.currentState)
        signaux.ecrans = DisplaySnapshot(displays: [.physique(1, main: true)], enumerationOK: true)
        scruter(core, 0.5)
        XCTAssertEqual(raisonPubliee(core), "desktop-ui")
        XCTAssertEqual(publieur.publications, publications, "toujours aucune publication")
    }

    /// F44 : `off_command` remplace l'action configurée. La source de l'intention, donc la raison publiée et le journal,
    /// dit `off/override`, et non `off/screensaver`, qui laisserait croire qu'un économiseur a été lancé.
    func test_offSurcharge_sourceOverride() {
        actions.hasOffOverride = true
        let core = moteur()
        core.start()

        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)], "l'action configurée est passée telle quelle")
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/override")
        XCTAssertEqual(raisonPubliee(core), "command:off/override")
        XCTAssertTrue(journalContient("commande OFF (essai) → action=override"), "\(journal.lines)")

        // Les faits ne confirment rien : retour aux faits à l'échéance, la source est dans la ligne d'échéance.
        for _ in 0..<24 { scruter(core, 0.5) }
        XCTAssertTrue(journalContient("commande off/override non confirmée après 12.0 s"), "\(journal.lines)")
    }

    /// F44 : `/status` donne la raison des faits seuls (`facts_reason`, celle que `--once` appelle `reason`) à côté de
    /// la raison publiée, qui peut être celle d'une commande.
    func test_statusDonneLaRaisonDesFaits() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        var instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["reason"] as? String, "display-asleep")
        XCTAssertEqual(instantane["facts_reason"] as? String, "display-asleep")

        // Une commande ON tient l'état ON alors que les faits disent encore OFF.
        core.requestOn(peer: "essai")
        instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["state"] as? String, "1")
        XCTAssertEqual(instantane["reason"] as? String, "command:on")
        XCTAssertEqual(instantane["facts_verdict"] as? String, "0")
        XCTAssertEqual(instantane["facts_reason"] as? String, "display-asleep")

        // Les faits rejoignent la commande.
        signaux.etatEcran.asleep = false
        signaux.etatSession.locked = true
        scruter(core, 0.5)
        instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["facts_reason"] as? String, "lock-screen-ui")
        XCTAssertEqual(instantane["facts_reason"] as? String, core.inspect().reason, "même raison que `--once`")
    }
}
