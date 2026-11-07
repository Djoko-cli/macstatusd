import XCTest
@testable import MacStatusCore

/// Classe de base des tests du moteur d'état : la fixture partagée (horloge, faux signaux, fausses actions,
/// faux publieur, journal capturé) et les aides communes aux sous-classes `EngineCoreTests` et
/// `EngineCoreSaverTests`. Elle ne contient aucun test.
class EngineCoreTestCase: XCTestCase {
    var horloge: TestClock!
    var signaux: FakeSignals!
    var actions: FakeActions!
    var publieur: FakePublisher!
    var journal: CaptureLog!
    var ancienRecepteur: LogSink?

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
    static func signauxDeBureau() -> FakeSignals {
        let signaux = FakeSignals()
        signaux.inactiviteHID = 30
        return signaux
    }

    /// Moteur câblé comme l'exécuteur le câble, mais sur les faux. `ecoute` : ce que le serveur HTTP
    /// a annoncé de son port (`.ready` : détenu, `.portBusy` : occupé, `nil` : rien encore). Sans port
    /// détenu, le moteur ne publie rien (tâche 16).
    func moteur(_ config: Config = Config(), ecoute: ListenerStatus? = .ready, build: BuildInfo = .unknown) -> EngineCore {
        let core = moteurBrut(config, build: build)
        if let ecoute { core.setListenerStatus(ecoute) }
        return core
    }

    func moteurBrut(_ config: Config = Config(), build: BuildInfo = .unknown) -> EngineCore {
        let oracle = ScreenSaverOracle(
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: config.saverDismissGrace,
            redisplayIdle: Double(config.saverRedisplayIdleSeconds),
            signals: signaux
        )
        return EngineCore(config: config, clock: horloge, signals: signaux, oracle: oracle,
                          actions: actions, publisher: publieur, buildInfo: build)
    }

    func scruter(_ core: EngineCore, _ secondes: Double) {
        horloge.advance(secondes)
        core.tick()
    }

    /// Comme `scruter`, sans aucune activité matérielle : l'inactivité HID grandit du même pas, pour que la
    /// dernière frappe connue de l'oracle reste fixe.
    func scruterSansActivite(_ core: EngineCore, _ secondes: Double) {
        signaux.inactiviteHID += secondes
        scruter(core, secondes)
    }

    func commandeEnAttente(_ core: EngineCore) -> [String: Any]? {
        core.statusSnapshot()["pending_command"] as? [String: Any]
    }

    /// Preuve de l'économiseur telle que `/status` la publie (`facts.screensaver_evidence`), sans relire
    /// le système.
    func preuveEconomiseur(_ core: EngineCore) -> String? {
        (core.statusSnapshot()["facts"] as? [String: Any])?["screensaver_evidence"] as? String
    }

    func journalContient(_ fragment: String) -> Bool {
        journal.lines.contains { $0.1.contains(fragment) }
    }

    typealias Publication = FakePublisher.Publication

    /// Les trois chemins de réveil que le moteur rattrape sans avis IOKit (M4, R68) : un cinquième chemin
    /// s'ajoute ici, une fois, et entre dans chaque test qui énumère les réveils. Chaque déclencheur part d'un
    /// moteur démarré.
    var declencheursDeReveil: [(String, (EngineCore) -> Void)] {
        [
            // Plan 3, tâche 5 : la veille annoncée n'aboutit pas, une frappe y met fin (2,7 s après l'annonce).
            ("fin de veille sans avis", { core in
                core.willSleep {}
                self.horloge.advance(3)
                self.signaux.inactiviteHID = 0.3
                core.tick()
            }),
            // Les deux rattrapages de `tick()` : plus de 5 s ont passé depuis le `didstart`, l'attente non oubliée
            // expirerait avec un avertissement ; ils tiennent la même comptabilité que l'avis IOKit.
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
    }

    var publicationsForcees: Int { publieur.publications.filter { $0.force }.count }

    /// Écran éteint de bout en bout : l'état reste OFF à travers la veille, aucune transition
    /// ne masque le drapeau `force` (une transition publie toujours sans `force`).
    func moteurEcranEteint() -> EngineCore {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publicationsForcees, 0)
        return core
    }
}
