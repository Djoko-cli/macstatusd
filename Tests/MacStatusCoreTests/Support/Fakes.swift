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

    /// Place l'instant monotone à `instant` (même en arrière) et décale l'heure
    /// murale du même écart. Sert au `TestScheduler`, qui rejoue les échéances.
    func positionner(_ instant: Double) {
        advance(instant - t)
    }
}

/// Planificateur sans file ni attente réelle : les tâches ne s'exécutent que
/// lorsque le test appelle `runDue(at:)`. Les échéances se comptent à partir de
/// l'horloge fournie, ou à défaut de l'instant courant du planificateur.
///
/// Pendant `runDue(at:)`, l'instant courant (celui du planificateur, et celui de
/// l'horloge fournie) vaut l'échéance de la tâche en cours : une tâche qui se
/// replanifie à +n s part donc de son échéance, comme en temps réel. À la fin,
/// il vaut `t`.
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
    /// Une tâche annulée par une tâche échue avant elle ne s'exécute pas.
    func runDue(at t: Double) {
        while true {
            let echues = taches.filter { !$0.annulee && $0.echeance <= t }
            guard let prochaine = echues.min(by: { ($0.echeance, $0.ordre) < ($1.echeance, $1.ordre) }) else { break }
            taches.removeAll { $0 === prochaine }
            positionner(prochaine.echeance)
            prochaine.travail()
        }
        positionner(t)
        taches.removeAll { $0.annulee }
    }

    private func positionner(_ instant: Double) {
        maintenant = instant
        horloge?.positionner(instant)
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

/// Publieur simulé : garde chaque état publié, avec son drapeau `force`, et simule la
/// livraison comme le client webhook.
///
/// Un appel à `publish` n'est un *envoi* (`envois`) que si l'état diffère de l'état confirmé,
/// ou avec `force`. Par défaut, chaque envoi est confirmé aussitôt. Avec `livraisonManuelle`,
/// il reste en attente jusqu'à `livrer()` (confirmé) ou `terminerSansLivrer()` (échec définitif
/// ou délai écoulé) : les tests pilotent ainsi le moment où `notifyWhenDelivered` rappelle.
final class FakePublisher: StatePublisher {
    struct Publication: Equatable {
        let etat: Bool
        let force: Bool
    }

    /// Chaque appel à `publish`, envoyé ou non.
    private(set) var publications: [Publication] = []
    /// Les appels qu'un client réel aurait transmis.
    private(set) var envois: [Publication] = []
    var livraisonManuelle = false
    private(set) var voulu: Bool?
    private(set) var confirme: Bool?
    /// Délai passé à chaque `notifyWhenDelivered`, dans l'ordre.
    private(set) var delaisDemandes: [Double] = []
    private var attentes: [(Bool) -> Void] = []

    /// Attentes de livraison pas encore rappelées.
    var attentesEnCours: Int { attentes.count }

    func publish(_ state: Bool, force: Bool) {
        publications.append(Publication(etat: state, force: force))
        voulu = state
        guard force || state != confirme else { return }
        envois.append(Publication(etat: state, force: force))
        confirme = livraisonManuelle ? nil : state
    }

    func notifyWhenDelivered(timeout: Double, _ done: @escaping (Bool) -> Void) {
        delaisDemandes.append(timeout)
        guard let voulu, voulu != confirme else {
            done(true)
            return
        }
        attentes.append(done)
    }

    /// L'état voulu est confirmé : les attentes rappellent `true`, une fois chacune.
    func livrer() {
        confirme = voulu
        terminer(true)
    }

    /// Échec définitif ou délai écoulé : les attentes rappellent `false`, une fois chacune.
    func terminerSansLivrer() {
        terminer(false)
    }

    private func terminer(_ livre: Bool) {
        let enCours = attentes
        attentes.removeAll()
        enCours.forEach { $0(livre) }
    }

    var statusDictionary: [String: Any] { ["faux": true] }
}

/// Transport simulé : note chaque requête (avec l'instant de l'horloge, si on en
/// fournit une) et répond selon un script. Rien ne sort du processus.
///
/// Par défaut la réponse part tout de suite, dans l'appel à `send`. Avec
/// `differe`, les réponses restent en attente jusqu'à `terminerEnAttente()`,
/// pour simuler un envoi en vol.
final class FakeTransport: WebhookTransport {
    private let horloge: TestClock?
    /// Réponses à donner, dans l'ordre ; une fois épuisées, `reponseParDefaut`.
    var script: [WebhookOutcome]
    var reponseParDefaut = WebhookOutcome.delivered(status: 200)
    var differe = false

    private(set) var requetes: [WebhookRequest] = []
    /// Instant monotone de chaque envoi (0 sans horloge).
    private(set) var instants: [Double] = []
    private var enAttente: [() -> Void] = []

    init(script: [WebhookOutcome] = [], clock: TestClock? = nil) {
        self.script = script
        self.horloge = clock
    }

    /// Nombre de réponses retenues par `differe`.
    var reponsesEnAttente: Int { enAttente.count }

    func send(_ request: WebhookRequest, _ completion: @escaping (WebhookOutcome) -> Void) {
        requetes.append(request)
        instants.append(horloge?.t ?? 0)
        let reponse = script.isEmpty ? reponseParDefaut : script.removeFirst()
        if differe {
            enAttente.append { completion(reponse) }
        } else {
            completion(reponse)
        }
    }

    /// Livre la plus ancienne réponse retenue.
    func terminerEnAttente() {
        guard !enAttente.isEmpty else { return }
        enAttente.removeFirst()()
    }
}

/// Moteur simulé pour le routeur : chaque appel est noté, rien n'agit sur le Mac.
final class FakeEngine: EngineFacade {
    enum Appel: Equatable {
        case etat
        case instantane
        case off(String)
        case on(String)
        case resync
    }

    var etat = true
    var arret = false
    var instantane: [String: Any] = ["faux": true, "etat": "1"]
    private(set) var appels: [Appel] = []

    var isShuttingDown: Bool { arret }

    var currentState: Bool {
        appels.append(.etat)
        return etat
    }

    func statusSnapshot() -> [String: Any] {
        appels.append(.instantane)
        return instantane
    }

    func requestOff(source: String) { appels.append(.off(source)) }
    func requestOn(source: String) { appels.append(.on(source)) }
    func resync() { appels.append(.resync) }
}
