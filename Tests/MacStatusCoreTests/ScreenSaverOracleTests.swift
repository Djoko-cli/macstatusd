import XCTest
@testable import MacStatusCore

/// Règle de décision de l'économiseur d'écran, sans économiseur réel ni frappe
/// humaine : les sondes sont des faux signaux, `now` et `hidIdle` sont explicites.
///
/// Le scénario nominal reproduit la séquence mesurée sur macOS 26.5 : l'économiseur
/// démarre, tourne seul, puis une frappe fait apparaître le panneau
/// d'authentification par-dessus un économiseur qui continue de tourner.
/// Les 17 tests portent un à un les 17 vérifications de l'ancien `--check-rules`.
final class ScreenSaverOracleTests: XCTestCase {
    private let t0 = 1000.0
    private var signaux: FakeSignals!

    override func setUp() {
        super.setUp()
        signaux = FakeSignals()
        signaux.fenetreEconomiseur = .notVisible
    }

    private func oracleNominal() -> ScreenSaverOracle {
        ScreenSaverOracle(minimumInterval: 1, dismissOnInput: true, dismissGrace: 1.5,
                          redisplayIdle: 90, signals: signaux)
    }

    /// Scénario nominal rejoué jusqu'au démarrage de l'économiseur (PID 4242).
    private func demarrer(_ oracle: ScreenSaverOracle) {
        _ = oracle.verdict(now: t0, hidIdle: 3.0)
        signaux.pidEconomiseur = 4242
        _ = oracle.verdict(now: t0 + 1, hidIdle: 4.0)
    }

    /// Nominal rejoué jusqu'à la frappe qui écarte l'économiseur (t0 + 15).
    private func jusquALaFrappe(_ oracle: ScreenSaverOracle) -> ScreenSaverOracle.Verdict {
        demarrer(oracle)
        _ = oracle.verdict(now: t0 + 10, hidIdle: 13.0)
        return oracle.verdict(now: t0 + 15, hidIdle: 0.2)
    }

    /// Nominal rejoué jusqu'au réaffichage (t0 + 120), puis déverrouillage (t0 + 130).
    private func jusquAuDeverrouillage(_ oracle: ScreenSaverOracle) -> ScreenSaverOracle.Verdict {
        _ = jusquALaFrappe(oracle)
        _ = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        _ = oracle.verdict(now: t0 + 120, hidIdle: 95)
        signaux.pidEconomiseur = 0
        return oracle.verdict(now: t0 + 130, hidIdle: 0.1)
    }

    // MARK: - Scénario nominal

    func test_aucunEconomiseur_estInactif() {
        let verdict = oracleNominal().verdict(now: t0, hidIdle: 3.0)
        XCTAssertFalse(verdict.active)
        XCTAssertFalse(verdict.running)
    }

    func test_economiseurDemarre_sansActiviteDepuis_donneOFF() {
        let oracle = oracleNominal()
        _ = oracle.verdict(now: t0, hidIdle: 3.0)
        signaux.pidEconomiseur = 4242
        let verdict = oracle.verdict(now: t0 + 1, hidIdle: 4.0)
        XCTAssertTrue(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertFalse(verdict.dismissed)
    }

    func test_economiseurQuiTourneSeulDepuis10s_resteOFF() {
        let oracle = oracleNominal()
        demarrer(oracle)
        let verdict = oracle.verdict(now: t0 + 10, hidIdle: 13.0)
        XCTAssertTrue(verdict.active)
    }

    func test_activiteApresDemarrage_ecarteEtDoncON() {
        let verdict = jusquALaFrappe(oracleNominal())
        XCTAssertFalse(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertTrue(verdict.dismissed)
    }

    func test_activiteApresDemarrage_donneLaPreuveExplicite() {
        let verdict = jusquALaFrappe(oracleNominal())
        XCTAssertTrue(verdict.evidence.contains("écarté-par-activité"))
    }

    func test_saisieDuMotDePasse_resteON() {
        let oracle = oracleNominal()
        _ = jusquALaFrappe(oracle)
        let verdict = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        XCTAssertFalse(verdict.active)
    }

    func test_inactiviteProlongee_reaffichageEtRetourOFF() {
        let oracle = oracleNominal()
        _ = jusquALaFrappe(oracle)
        _ = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        let verdict = oracle.verdict(now: t0 + 120, hidIdle: 95)
        XCTAssertTrue(verdict.active)
    }

    func test_inactiviteProlongee_donneLaPreuveDeReaffichage() {
        let oracle = oracleNominal()
        _ = jusquALaFrappe(oracle)
        _ = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        let verdict = oracle.verdict(now: t0 + 120, hidIdle: 95)
        XCTAssertTrue(verdict.evidence.contains("réaffiché"))
    }

    func test_economiseurTermine_estInactif() {
        let verdict = jusquAuDeverrouillage(oracleNominal())
        XCTAssertFalse(verdict.active)
        XCTAssertFalse(verdict.running)
    }

    func test_redemarrageAvecNouveauPID_donneOFFMalgreActiviteRecente() {
        let oracle = oracleNominal()
        _ = jusquAuDeverrouillage(oracle)
        signaux.pidEconomiseur = 5000
        let verdict = oracle.verdict(now: t0 + 140, hidIdle: 0.1)
        XCTAssertTrue(verdict.active)
    }

    func test_activiteApresRedemarrage_donneON() {
        let oracle = oracleNominal()
        _ = jusquAuDeverrouillage(oracle)
        signaux.pidEconomiseur = 5000
        _ = oracle.verdict(now: t0 + 140, hidIdle: 0.1)
        let verdict = oracle.verdict(now: t0 + 145, hidIdle: 0.1)
        XCTAssertFalse(verdict.active)
    }

    // MARK: - Règle désactivée

    func test_ecartementDesactive_ignoreLActivite() {
        signaux.pidEconomiseur = 7000
        let oracle = ScreenSaverOracle(minimumInterval: 1, dismissOnInput: false,
                                       dismissGrace: 1.5, redisplayIdle: 90, signals: signaux)
        let verdict = oracle.verdict(now: t0, hidIdle: 0.0)
        XCTAssertTrue(verdict.active)
    }

    func test_ecartementDesactive_suitQuandMemeLeProcess() {
        signaux.pidEconomiseur = 7000
        let oracle = ScreenSaverOracle(minimumInterval: 1, dismissOnInput: false,
                                       dismissGrace: 1.5, redisplayIdle: 90, signals: signaux)
        _ = oracle.verdict(now: t0, hidIdle: 0.0)
        signaux.pidEconomiseur = 0
        let verdict = oracle.verdict(now: t0 + 1, hidIdle: 0.0)
        XCTAssertFalse(verdict.active)
    }

    // MARK: - Inactivité matérielle indisponible

    func test_inactiviteIndisponible_neConclutPasALEcartement() {
        signaux.pidEconomiseur = 8000
        let oracle = ScreenSaverOracle(minimumInterval: 1, dismissOnInput: true,
                                       dismissGrace: 1.5, redisplayIdle: 90, signals: signaux)
        let verdict = oracle.verdict(now: t0, hidIdle: -1)
        XCTAssertTrue(verdict.active)
    }

    func test_inactiviteIndisponible_suitLeProcess() {
        signaux.pidEconomiseur = 8000
        let oracle = ScreenSaverOracle(minimumInterval: 1, dismissOnInput: true,
                                       dismissGrace: 1.5, redisplayIdle: 90, signals: signaux)
        _ = oracle.verdict(now: t0, hidIdle: -1)
        signaux.pidEconomiseur = 0
        let verdict = oracle.verdict(now: t0 + 1, hidIdle: -1)
        XCTAssertFalse(verdict.active)
    }

    // MARK: - Oracle fenêtres seul (économiseur hébergé par legacyScreenSaver)

    func test_fenetreSansProcess_donneOFF() {
        signaux.fenetreEconomiseur = .visible
        let oracle = ScreenSaverOracle(minimumInterval: 0, dismissOnInput: true,
                                       dismissGrace: 1.5, redisplayIdle: 90, signals: signaux)
        let verdict = oracle.verdict(now: t0, hidIdle: 5)
        XCTAssertTrue(verdict.active)
        XCTAssertTrue(verdict.evidence.contains("window"))
    }

    func test_fenetreDisparue_estInactif() {
        signaux.fenetreEconomiseur = .visible
        let oracle = ScreenSaverOracle(minimumInterval: 0, dismissOnInput: true,
                                       dismissGrace: 1.5, redisplayIdle: 90, signals: signaux)
        _ = oracle.verdict(now: t0, hidIdle: 5)
        signaux.fenetreEconomiseur = .notVisible
        let verdict = oracle.verdict(now: t0 + 1, hidIdle: 5)
        XCTAssertFalse(verdict.active)
    }
}
