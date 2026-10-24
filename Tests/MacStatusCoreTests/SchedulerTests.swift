import XCTest
@testable import MacStatusCore

/// Horloge et planificateurs : le réel pour ses garanties de base, le faux pour ses règles.
final class SchedulerTests: XCTestCase {
    func test_horlogeSysteme_estMonotone() {
        let horloge = SystemClock()
        let a = horloge.monotonic()
        let b = horloge.monotonic()
        XCTAssertGreaterThan(a, 0)
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func test_planificateurDeTest_executeLesTachesEchuesDansLOrdre() {
        let planificateur = TestScheduler()
        var ordre: [String] = []
        planificateur.schedule(after: 5) { ordre.append("c") }
        planificateur.schedule(after: 1) { ordre.append("a") }
        planificateur.schedule(after: 1) { ordre.append("b") }
        planificateur.runDue(at: 0.5)
        XCTAssertEqual(ordre, [])
        planificateur.runDue(at: 2)
        XCTAssertEqual(ordre, ["a", "b"])
        planificateur.runDue(at: 10)
        XCTAssertEqual(ordre, ["a", "b", "c"])
    }

    func test_planificateurDeTest_neLancePasUneTacheAnnulee() {
        let planificateur = TestScheduler()
        var lancee = false
        let tache = planificateur.schedule(after: 1) { lancee = true }
        tache.cancel()
        planificateur.runDue(at: 5)
        XCTAssertFalse(lancee)
    }

    func test_planificateurDeTest_compteLesEcheancesDepuisLHorloge() {
        let horloge = TestClock(t: 100)
        let planificateur = TestScheduler(clock: horloge)
        var lancee = false
        planificateur.schedule(after: 10) { lancee = true }
        planificateur.runDue(at: 105)
        XCTAssertFalse(lancee)
        horloge.advance(10)
        planificateur.runDue(at: horloge.t)
        XCTAssertTrue(lancee)
    }

    func test_planificateurReel_executeSurLaFileDonnee() {
        let file = DispatchQueue(label: "essai.planificateur")
        let planificateur = DispatchScheduler(queue: file)
        let attendue = expectation(description: "tâche exécutée")
        planificateur.schedule(after: 0.05) { attendue.fulfill() }
        wait(for: [attendue], timeout: 2)
    }

    func test_planificateurReel_neLancePasUneTacheAnnulee() {
        let file = DispatchQueue(label: "essai.annulation")
        let planificateur = DispatchScheduler(queue: file)
        let inattendue = expectation(description: "tâche annulée")
        inattendue.isInverted = true
        let tache = planificateur.schedule(after: 0.1) { inattendue.fulfill() }
        tache.cancel()
        wait(for: [inattendue], timeout: 0.4)
    }
}
