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
    func moteur(_ config: Config = Config(), ecoute: ListenerStatus? = .ready) -> EngineCore {
        let core = moteurBrut(config)
        if let ecoute { core.setListenerStatus(ecoute) }
        return core
    }

    func moteurBrut(_ config: Config = Config()) -> EngineCore {
        let oracle = ScreenSaverOracle(
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: config.saverDismissGrace,
            redisplayIdle: Double(config.saverRedisplayIdleSeconds),
            signals: signaux
        )
        return EngineCore(config: config, clock: horloge, signals: signaux, oracle: oracle,
                          actions: actions, publisher: publieur)
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
