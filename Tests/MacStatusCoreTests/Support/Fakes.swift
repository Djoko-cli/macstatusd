import Foundation
@testable import MacStatusCore

/// Récepteur de journal pour les tests : garde les lignes (niveau, message) en mémoire.
/// Protégé par un verrou, car le moteur écrira depuis plusieurs files.
final class CaptureLog: LogSink {
    private let verrou = NSLock()
    private var stockage: [(LogLevel, String)] = []

    var lines: [(LogLevel, String)] {
        get { verrou.lock(); defer { verrou.unlock() }; return stockage }
        set { verrou.lock(); defer { verrou.unlock() }; stockage = newValue }
    }

    func log(_ level: LogLevel, _ message: String) {
        verrou.lock(); defer { verrou.unlock() }
        stockage.append((level, message))
    }
}

/// Horloge pilotée par les tests : `t` est l'instant monotone, `date` l'heure murale.
final class TestClock: Clock {
    var t: Double
    var date: Date

    init(t: Double = 0, date: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.t = t
        self.date = date
    }

    func monotonic() -> Double { t }
    func wall() -> Date { date }

    /// Avance les deux horloges de la même durée.
    func advance(_ s: Double) {
        t += s
        date = date.addingTimeInterval(s)
    }
}

/// Planificateur sans file ni attente réelle : les tâches ne s'exécutent que
/// lorsque le test appelle `runDue(at:)`. Les échéances se comptent à partir de
/// l'horloge fournie, ou à défaut du dernier instant passé à `runDue(at:)`.
final class TestScheduler: Scheduler {
    private final class Tache: Cancellable {
        let echeance: Double
        let ordre: Int
        let travail: () -> Void
        var annulee = false
        init(echeance: Double, ordre: Int, travail: @escaping () -> Void) {
            self.echeance = echeance
            self.ordre = ordre
            self.travail = travail
        }
        func cancel() { annulee = true }
    }

    private let horloge: TestClock?
    private var maintenant: Double
    private var compteur = 0
    private var taches: [Tache] = []

    init(clock: TestClock? = nil) {
        self.horloge = clock
        self.maintenant = clock?.t ?? 0
    }

    /// Nombre de tâches encore en attente (annulées exclues).
    var pending: Int { taches.filter { !$0.annulee }.count }

    @discardableResult
    func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable {
        let base = horloge?.t ?? maintenant
        compteur += 1
        let tache = Tache(echeance: base + seconds, ordre: compteur, travail: work)
        taches.append(tache)
        return tache
    }

    /// Exécute, dans l'ordre d'échéance (puis de planification), les tâches échues
    /// à l'instant `t`, y compris celles qu'elles planifient et qui sont déjà échues.
    func runDue(at t: Double) {
        maintenant = t
        while true {
            let echues = taches.filter { !$0.annulee && $0.echeance <= t }
            guard let prochaine = echues.min(by: { ($0.echeance, $0.ordre) < ($1.echeance, $1.ordre) }) else { break }
            taches.removeAll { $0 === prochaine }
            prochaine.travail()
        }
        taches.removeAll { $0.annulee }
    }
}

/// Signaux système simulés : un champ modifiable par méthode du protocole.
final class FakeSignals: SystemSignals {
    var etatSession = SessionState(locked: false, loggedIn: true, onConsole: true, evidence: "unlocked")
    var etatEcran = DisplayState(asleep: false, onlineCount: 1, enumerationOK: true)
    var inactiviteHID: Double = 0
    var saisieSecurisee = false
    var pidEconomiseur: Int32 = 0
    var fenetreEconomiseur = WindowVerdict.notVisible
    var sessionAqua = true

    func session() -> SessionState { etatSession }
    func display() -> DisplayState { etatEcran }
    func hidIdleSeconds() -> Double { inactiviteHID }
    func secureInputActive() -> Bool { saisieSecurisee }
    func saverEnginePID() -> Int32 { pidEconomiseur }
    func saverWindow() -> WindowVerdict { fenetreEconomiseur }
    func hasAquaSession() -> Bool { sessionAqua }
}

/// Actions de commande simulées : chaque appel est noté, rien n'agit sur le Mac.
final class FakeActions: CommandActions {
    enum Appel: Equatable {
        case runOff(OffAction)
        case displaySleep
        case wake
        case stopScreenSaver
    }

    var hasOffOverride = false
    private(set) var appels: [Appel] = []

    func runOff(_ action: OffAction) { appels.append(.runOff(action)) }
    func displaySleep() { appels.append(.displaySleep) }
    func wake() { appels.append(.wake) }
    func stopScreenSaver() { appels.append(.stopScreenSaver) }
}

/// Publieur simulé : garde chaque état publié, avec son drapeau `force`.
final class FakePublisher: StatePublisher {
    struct Publication: Equatable {
        let etat: Bool
        let force: Bool
    }

    private(set) var publications: [Publication] = []

    func publish(_ state: Bool, force: Bool) {
        publications.append(Publication(etat: state, force: force))
    }

    var statusDictionary: [String: Any] { ["faux": true] }
}
