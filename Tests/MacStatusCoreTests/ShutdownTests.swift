import XCTest
@testable import MacStatusCore

/// Tâche 14 : marqueur de redémarrage prévu, décision de publication à l'arrêt, filet de sortie.
final class ShutdownTests: XCTestCase {
    private var dossier: URL!
    private var journal: CaptureLog!
    private var ancienRecepteur: LogSink?

    override func setUp() {
        super.setUp()
        dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstatusd-arret-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        journal = CaptureLog()
        ancienRecepteur = CoreLog.sink
        CoreLog.sink = journal
    }

    override func tearDown() {
        CoreLog.sink = ancienRecepteur
        try? FileManager.default.removeItem(at: dossier)
        super.tearDown()
    }

    private var marqueur: String { dossier.path + "/" + RestartMarker.fileName }

    /// Pose un marqueur dont la dernière modification remonte à `age` secondes.
    private func poserMarqueur(age: TimeInterval) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: marqueur, contents: Data()))
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: marqueur)
    }

    private var existe: Bool { FileManager.default.fileExists(atPath: marqueur) }

    // MARK: - Dossier de support

    func test_dossierDeSupport_variableOuDefaut() {
        XCTAssertEqual(RestartMarker.supportDirectory(environment: ["MACSTATUSD_SUPPORT_DIR": "/tmp/essai"],
                                                      home: "/home/exemple"), "/tmp/essai")
        XCTAssertEqual(RestartMarker.supportDirectory(environment: [:], home: "/home/exemple"),
                       "/home/exemple/Library/Application Support/macstatusd")
        XCTAssertEqual(RestartMarker.supportDirectory(environment: ["MACSTATUSD_SUPPORT_DIR": ""], home: "/home/exemple"),
                       "/home/exemple/Library/Application Support/macstatusd")
    }

    // MARK: - Marqueur

    func test_marqueurAbsent() {
        XCTAssertEqual(RestartMarker.consume(in: dossier.path), .absent)
        XCTAssertEqual(RestartMarker.consume(in: dossier.path + "/inexistant"), .absent)
    }

    func test_marqueurRecent_estConsomme() throws {
        try poserMarqueur(age: 30)
        XCTAssertEqual(RestartMarker.consume(in: dossier.path), .fresh)
        XCTAssertFalse(existe, "le marqueur est supprimé")
        XCTAssertEqual(RestartMarker.consume(in: dossier.path), .absent, "il ne sert qu'une fois")
        XCTAssertTrue(journal.lines.isEmpty, "\(journal.lines)")
    }

    /// Un marqueur de 9 min 59 s sert encore ; au-delà de 10 min il est ignoré, supprimé, signalé.
    func test_marqueurPerime_estIgnoreSupprimeEtSignale() throws {
        try poserMarqueur(age: 599)
        XCTAssertEqual(RestartMarker.consume(in: dossier.path), .fresh)

        try poserMarqueur(age: 601)
        guard case .stale(let age) = RestartMarker.consume(in: dossier.path) else {
            return XCTFail("un marqueur de 10 min 1 s doit être périmé")
        }
        XCTAssertGreaterThanOrEqual(age, 600)
        XCTAssertFalse(existe, "le marqueur périmé est supprimé aussi")
        let avertissements = journal.lines.filter { $0.0 == .warn }.map { $0.1 }
        XCTAssertEqual(avertissements.count, 1, "\(avertissements)")
        XCTAssertTrue(avertissements[0].contains("périmé"), avertissements[0])
    }

    func test_marqueurQuiNEstPasUnFichier_jamaisTouche() throws {
        try FileManager.default.createDirectory(atPath: marqueur, withIntermediateDirectories: false)
        XCTAssertEqual(RestartMarker.consume(in: dossier.path), .absent)
        XCTAssertTrue(existe)
    }

    // MARK: - Décision

    func test_decision_parDefaut_publieOff() {
        let d = ShutdownPolicy.decide(degraded: false, publishOffOnExit: true, marker: .absent)
        XCTAssertTrue(d.publishOff)
    }

    func test_decision_marqueurRecent_neRienPublier() {
        let d = ShutdownPolicy.decide(degraded: false, publishOffOnExit: true, marker: .fresh)
        XCTAssertFalse(d.publishOff)
        XCTAssertTrue(d.reason.contains("restart-pending"), d.reason)
    }

    func test_decision_marqueurPerime_publieOff() {
        XCTAssertTrue(ShutdownPolicy.decide(degraded: false, publishOffOnExit: true,
                                            marker: .stale(ageSeconds: 4000)).publishOff)
    }

    func test_decision_optionDesactivee_neRienPublier() {
        XCTAssertFalse(ShutdownPolicy.decide(degraded: false, publishOffOnExit: false, marker: .absent).publishOff)
    }

    /// Mode dégradé : les webhooks sont coupés, rien n'est publié, quoi que disent l'option et le marqueur.
    func test_decision_modeDegrade_neRienPublier() {
        for marqueur in [RestartMarker.Outcome.absent, .fresh, .stale(ageSeconds: 4000)] {
            let d = ShutdownPolicy.decide(degraded: true, publishOffOnExit: true, marker: marqueur)
            XCTAssertFalse(d.publishOff)
            XCTAssertTrue(d.reason.contains("dégradé"), d.reason)
        }
    }

    // MARK: - Filet de sortie

    private func garde(_ planificateur: TestScheduler, _ sorties: Counter) -> ShutdownGuard {
        ShutdownGuard(scheduler: planificateur) { sorties.n += 1 }
    }

    private final class Counter { var n = 0 }

    func test_filet_sequenceTerminee_sortUneFois_etRetireLeFilet() {
        let planificateur = TestScheduler()
        let sorties = Counter()
        let garde = garde(planificateur, sorties)
        var fin: (() -> Void)?
        garde.begin { fin = $0 }
        XCTAssertEqual(planificateur.pending, 1, "le filet est armé")
        XCTAssertEqual(sorties.n, 0)

        fin?()
        XCTAssertEqual(sorties.n, 1)
        XCTAssertEqual(planificateur.pending, 0, "le filet est retiré")
        fin?()
        planificateur.runDue(at: 10)
        XCTAssertEqual(sorties.n, 1)
    }

    /// Si `finished` n'est jamais appelé, la sortie est forcée à 3 s, avec une ligne de journal.
    func test_filet_a3s_forceLaSortie() {
        let planificateur = TestScheduler()
        let sorties = Counter()
        let garde = garde(planificateur, sorties)
        var fin: (() -> Void)?
        garde.begin { fin = $0 }

        planificateur.runDue(at: 2.9)
        XCTAssertEqual(sorties.n, 0)
        planificateur.runDue(at: 3)
        XCTAssertEqual(sorties.n, 1)
        XCTAssertTrue(journal.lines.contains { $0.0 == .warn && $0.1.contains("sortie forcée") }, "\(journal.lines)")

        // La séquence qui se termine après le filet ne sort pas une seconde fois.
        fin?()
        XCTAssertEqual(sorties.n, 1)
    }

    func test_filet_delaiParDefaut_estSousLExitTimeOut() {
        XCTAssertEqual(ShutdownGuard.forcedExitDelay, 3)
    }

    func test_secondSignal_sortTouDeSuite() {
        let planificateur = TestScheduler()
        let sorties = Counter()
        let garde = garde(planificateur, sorties)
        var sequences = 0
        garde.begin { _ in sequences += 1 }
        XCTAssertEqual(sorties.n, 0)

        garde.begin { _ in sequences += 1 }
        XCTAssertEqual(sequences, 1, "la séquence ne se lance qu'une fois")
        XCTAssertEqual(sorties.n, 1)
        XCTAssertEqual(planificateur.pending, 0)
        XCTAssertTrue(journal.lines.contains { $0.1.contains("second signal") })

        garde.begin { _ in sequences += 1 }
        XCTAssertEqual(sorties.n, 1, "une seule sortie")
    }

    /// Une séquence qui se termine avant même de rendre la main (rien à publier) sort aussitôt.
    func test_sequenceSynchrone_sortAussitot() {
        let planificateur = TestScheduler()
        let sorties = Counter()
        garde(planificateur, sorties).begin { $0() }
        XCTAssertEqual(sorties.n, 1)
        XCTAssertEqual(planificateur.pending, 0)
    }
}
