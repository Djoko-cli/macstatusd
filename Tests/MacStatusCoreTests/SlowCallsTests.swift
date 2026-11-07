import XCTest
@testable import MacStatusCore

/// Mesure des lectures lentes du moteur (plan 4, tâche 2, R85) : une lecture du système qui dépasse le seuil
/// est nommée dans le journal et comptée dans `slow_calls` de `/status`.
final class SlowCallsTests: EngineCoreTestCase {

    private func appelsLents(_ core: EngineCore) -> [String: [String: Any]] {
        core.statusSnapshot()["slow_calls"] as? [String: [String: Any]] ?? [:]
    }

    private func avertissementsAppelLent() -> [String] {
        journal.lines.filter { $0.0 == .warn && $0.1.contains("appel lent") }.map { $0.1 }
    }

    func test_appelLent_auDelaDuSeuil_avertitAvecSonNomEtSaDuree() {
        let core = moteur()
        core.start()
        XCTAssertTrue(avertissementsAppelLent().isEmpty)

        signaux.surLectureEcrans = { [horloge] in horloge!.advance(7) }
        core.tick()

        let avertissements = avertissementsAppelLent()
        XCTAssertEqual(avertissements.count, 1)
        XCTAssertTrue(avertissements.first?.contains("appel lent : ecrans 7.0 s (seuil 1.0 s)") ?? false,
                      "reçu : \(avertissements)")
        XCTAssertEqual(appelsLents(core)["ecrans"]?["count"] as? Int, 1)
        XCTAssertEqual(appelsLents(core)["ecrans"]?["max_seconds"] as? Double, 7.0)
    }

    func test_appelSousLeSeuil_rienAuJournal() {
        let core = moteur()
        core.start()

        signaux.surLectureEcrans = { [horloge] in horloge!.advance(0.5) }
        core.tick()

        XCTAssertTrue(avertissementsAppelLent().isEmpty)
        XCTAssertTrue(appelsLents(core).isEmpty)
    }

    func test_appelsLentsRepetes_unSeulAvertissementParMinute() {
        let core = moteur()
        core.start()

        signaux.surLectureEcrans = { [horloge] in horloge!.advance(2) }
        core.tick()
        scruter(core, 3)
        scruter(core, 3)

        XCTAssertEqual(avertissementsAppelLent().count, 1, "un seul WARN en moins d'une minute")
        XCTAssertEqual(appelsLents(core)["ecrans"]?["count"] as? Int, 3)

        // Une minute plus tard, le même nom avertit de nouveau.
        scruter(core, 60)
        XCTAssertEqual(avertissementsAppelLent().count, 2)
        XCTAssertEqual(appelsLents(core)["ecrans"]?["count"] as? Int, 4)
    }

    /// Le moniteur seul : la durée se mesure sur l'horloge, le résultat de l'appel passe tel quel.
    func test_moniteur_rendLeResultatEtNeNommeQueLesAppelsLents() {
        let moniteur = SlowCallMonitor(clock: horloge)
        let valeur = moniteur.measure("rapide") { 42 }
        XCTAssertEqual(valeur, 42)
        _ = moniteur.measure("lent") { horloge.advance(1.0) }
        XCTAssertEqual(Set(moniteur.snapshot.keys), ["lent"])
    }
}
