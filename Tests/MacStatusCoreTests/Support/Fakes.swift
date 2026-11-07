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
    /// Instant « éveillé » : n'avance pas pendant une veille simulée.
    var awakeT: Double

    init(t: Double = 0, date: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.t = t
        self.awakeT = t
        self.date = date
    }

    func monotonic() -> Double { t }
    func awake() -> Double { awakeT }
    func wall() -> Date { date }

    /// Avance les deux horloges de la même durée.
    func advance(_ s: Double) {
        t += s
        awakeT += s
        date = date.addingTimeInterval(s)
    }

    /// Veille simulée : `monotonic` et l'heure murale avancent, pas `awake`.
    func dormir(_ s: Double) {
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
    /// Simule la course d'une minuterie déjà partie quand on l'annule : `cancel()` est sans
    /// effet, la tâche s'exécute quand même. Sert à éprouver le compteur de génération.
    var ignorerAnnulations = false

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
        return ignorerAnnulations ? AnnulationSansEffet() : tache
    }

    private final class AnnulationSansEffet: Cancellable {
        func cancel() {}
    }

    /// Échéances des tâches en attente (annulées exclues), dans l'ordre.
    var echeances: [Double] { taches.filter { !$0.annulee }.map(\.echeance).sorted() }

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

/// Écrans d'essai (identifiants et valeurs inventés). Le fantôme porte le fournisseur et le modèle que le
/// système donne à l'écran fantôme (`DisplayTopology`) ; l'écran physique, un fournisseur et un modèle quelconques.
extension DisplayInfo {
    static func physique(_ id: UInt32, asleep: Bool = false, main: Bool = false) -> DisplayInfo {
        DisplayInfo(id: id, vendor: 0x1234, model: 0x5678, asleep: asleep, isMain: main)
    }

    static func fantome(_ id: UInt32, asleep: Bool = false, main: Bool = false) -> DisplayInfo {
        DisplayInfo(id: id, vendor: DisplayTopology.placeholderVendor, model: DisplayTopology.placeholderModel,
                    asleep: asleep, isMain: main)
    }
}

/// Signaux système simulés : un champ modifiable par méthode du protocole.
final class FakeSignals: SystemSignals {
    var etatSession = SessionState(locked: false, loggedIn: true, onConsole: true, evidence: "unlocked")
    /// Écrans en ligne tels que le système les rapporte : par défaut, un écran physique principal éveillé.
    var ecrans = DisplaySnapshot(displays: [.physique(1, main: true)], enumerationOK: true)
    /// Raccourci des tests écrits avant la topologie : `DisplayState(asleep: a, onlineCount: n, enumerationOK: ok)`
    /// donne n écrans physiques `0x1`…, le premier principal, tous endormis si `a`. La lecture rend l'état que la
    /// topologie tire de `ecrans` (sans avis d'extinction). Zéro écran ne peut pas être endormi : `asleep` se
    /// perd alors à l'écriture.
    var etatEcran: DisplayState {
        get { DisplayTopology.state(ecrans, screensAsleepNotified: false) }
        set {
            ecrans = DisplaySnapshot(
                displays: (0..<max(0, newValue.onlineCount)).map { rang in
                    .physique(UInt32(rang + 1), asleep: newValue.asleep, main: rang == 0)
                },
                enumerationOK: newValue.enumerationOK)
        }
    }
    var inactiviteHID: Double = 0
    var saisieSecurisee = false
    var pidEconomiseur: Int32 = 0
    var sessionAqua = true
    /// `SACScreenSaverIsRunning` : vrai pendant une session d'économiseur, faux hors session, `nil` si la
    /// fonction est indisponible.
    var drapeauSAC: Bool? = false
    /// Process que `saverHosts()` rend (hôtes d'économiseur de l'utilisateur).
    var hotes: [SaverHost] = []

    /// Nombre d'appels de `saverProcessHint()`.
    private(set) var indicesProcess = 0
    /// Nombre de lectures de `saverEnginePID()`.
    private(set) var lecturesPID = 0
    /// Pour chaque indice, le nombre de lectures de `saverEnginePID()` déjà faites à cet instant :
    /// prouve qu'un indice précède la relecture qu'il annonce.
    private(set) var lecturesPIDAuxIndices: [Int] = []
    /// Nombre d'appels de `session()` : une relecture des faits par appel.
    private(set) var lecturesSession = 0
    /// Nombre d'appels de `saverHosts()` (balayage coûteux, réservé au repli sans SAC).
    private(set) var lecturesHotes = 0
    /// Nombre d'appels de `hidIdleSeconds()` : une lecture du registre IOKit par appel. Les relectures des faits
    /// et chaque `statusSnapshot()` y comptent.
    private(set) var lecturesHID = 0

    func session() -> SessionState {
        lecturesSession += 1
        return etatSession
    }
    /// Appelé au début de chaque `displaySnapshot()` : un test y fait avancer l'horloge d'essai pour simuler une
    /// lecture lente des écrans.
    var surLectureEcrans: (() -> Void)?
    func displaySnapshot() -> DisplaySnapshot {
        surLectureEcrans?()
        return ecrans
    }
    func hidIdleSeconds() -> Double {
        lecturesHID += 1
        return inactiviteHID
    }
    func secureInputActive() -> Bool { saisieSecurisee }
    func saverEnginePID() -> Int32 {
        lecturesPID += 1
        return pidEconomiseur
    }
    func saverSessionFlag() -> Bool? { drapeauSAC }
    func saverHosts() -> [SaverHost] {
        lecturesHotes += 1
        return hotes
    }
    func saverProcessHint() {
        indicesProcess += 1
        lecturesPIDAuxIndices.append(lecturesPID)
    }
    func hasAquaSession() -> Bool { sessionAqua }
}

/// Actions de commande simulées : chaque appel est noté, rien n'agit sur le Mac.
final class FakeActions: CommandActions {
    enum Appel: Equatable {
        case runOff(OffAction)
        case displaySleep
        case wake
        case dismissScreenSaver
    }

    var hasOffOverride = false
    /// Vrai : une surcharge `wake_command` est définie, `wake()` ne pose rien à relâcher.
    var hasWakeOverride = false
    /// Moyen d'écartement que ces actions annoncent : `.native` (`SACScreenSaverStopNow`), ou le repli
    /// `.processKill` quand la fonction manque. Les tests le changent avant de créer le moteur.
    var moyenEcartement: ScreenSaverDismissal = .native
    var screenSaverDismissal: ScreenSaverDismissal { moyenEcartement }
    /// Moyen de démarrage annoncé : `.native` (`SACScreenSaverStartNow`) ou le repli `.openApp`.
    var screenSaverStart: ScreenSaverStart = .native
    private(set) var appels: [Appel] = []

    func runOff(_ action: OffAction) { appels.append(.runOff(action)) }
    func displaySleep() { appels.append(.displaySleep) }
    func wake() { appels.append(.wake) }
    /// Appelé à l'instant de l'écartement, pour observer l'état du moteur (journal) au moment de l'appel.
    var surDismiss: (() -> Void)?
    func dismissScreenSaver() {
        appels.append(.dismissScreenSaver)
        surDismiss?()
    }

    /// Appels de la tâche 17, tenus à part de `appels` pour ne pas toucher aux assertions
    /// existantes : relâchement du réveil, pose (`seconds > 0`) ou levée (`seconds <= 0`) de la retenue.
    enum AppelReveil: Equatable {
        case releaseWake
        case holdDisplay(Double)
    }
    private(set) var appelsReveil: [AppelReveil] = []

    func releaseWake() { appelsReveil.append(.releaseWake) }
    func holdDisplay(seconds: Double) { appelsReveil.append(.holdDisplay(seconds)) }
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
    /// Faux : aucune destination utilisable (webhooks coupés). `notifyWhenDelivered` répond `false`.
    var cibleUtilisable = true
    var hasUsableTarget: Bool { cibleUtilisable }
    var deliveryCounts: (confirmed: Int, total: Int) {
        (cibleUtilisable && voulu != nil && confirme == voulu ? 1 : 0, cibleUtilisable ? 1 : 0)
    }
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

    /// Nombre d'appels à `publishBeforeExit`.
    private(set) var publicationsAvantDepart = 0

    /// Comme un `publish(state, force: true)` : le faux n'a pas de requête en vol à annuler.
    func publishBeforeExit(_ state: Bool) {
        publicationsAvantDepart += 1
        publish(state, force: true)
    }

    func notifyWhenDelivered(timeout: Double, _ done: @escaping (Bool) -> Void) {
        delaisDemandes.append(timeout)
        guard cibleUtilisable else {
            done(false)
            return
        }
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

    /// Nombre d'avis de retour du réseau transmis par le moteur.
    private(set) var avisReseau = 0

    func networkBecameAvailable() { avisReseau += 1 }

    /// Chaque appel à `setSendingSuspended`, dans l'ordre.
    private(set) var suspensions: [Bool] = []

    func setSendingSuspended(_ suspended: Bool) {
        suspensions.append(suspended)
    }
}

/// Transport simulé : note chaque requête (avec l'instant de l'horloge, si on en
/// fournit une) et répond selon un script. Rien ne sort du processus.
///
/// Par défaut la réponse part tout de suite, dans l'appel à `send`. Avec
/// `differe` (toutes les requêtes) ou `hotesDifferes` (celles de ces hôtes), les réponses
/// restent en attente jusqu'à `terminerEnAttente()`, pour simuler un envoi en vol.
///
/// L'annulation (`cancel()` du jeton rendu par `send`) retire la réponse en attente et rappelle
/// aussitôt, dans l'appel à `cancel()`, un échec `NSURLErrorCancelled` : plus dur que le
/// transport réel (qui ne rappelle pas), pour éprouver la garde de génération du client.
final class FakeTransport: WebhookTransport {
    private let horloge: TestClock?
    /// Réponses à donner, dans l'ordre ; une fois épuisées, `reponseParDefaut`.
    var script: [WebhookOutcome]
    var reponseParDefaut = WebhookOutcome.delivered(status: 200)
    /// Réponse par hôte : prioritaire sur `script` et `reponseParDefaut`.
    var reponsesParHote: [String: WebhookOutcome] = [:]
    var differe = false
    var hotesDifferes: Set<String> = []

    private(set) var requetes: [WebhookRequest] = []
    /// Instant monotone de chaque envoi (0 sans horloge).
    private(set) var instants: [Double] = []
    /// Requêtes annulées alors que leur réponse était en attente.
    private(set) var annulations: [WebhookRequest] = []

    private final class EnVol: Cancellable {
        let requete: WebhookRequest
        let reponse: WebhookOutcome
        var completion: ((WebhookOutcome) -> Void)?
        weak var transport: FakeTransport?
        init(requete: WebhookRequest, reponse: WebhookOutcome, completion: @escaping (WebhookOutcome) -> Void) {
            self.requete = requete
            self.reponse = reponse
            self.completion = completion
        }
        func cancel() { transport?.annuler(self) }
    }
    private var enAttente: [EnVol] = []

    init(script: [WebhookOutcome] = [], clock: TestClock? = nil) {
        self.script = script
        self.horloge = clock
    }

    /// Nombre de réponses retenues.
    var reponsesEnAttente: Int { enAttente.count }

    /// Requêtes envoyées vers cet hôte.
    func requetes(vers hote: String) -> [WebhookRequest] {
        requetes.filter { $0.url.host == hote }
    }

    @discardableResult
    func send(_ request: WebhookRequest, _ completion: @escaping (WebhookOutcome) -> Void) -> Cancellable {
        requetes.append(request)
        instants.append(horloge?.t ?? 0)
        let hote = request.url.host ?? ""
        let reponse: WebhookOutcome
        if let parHote = reponsesParHote[hote] {
            reponse = parHote
        } else {
            reponse = script.isEmpty ? reponseParDefaut : script.removeFirst()
        }
        let vol = EnVol(requete: request, reponse: reponse, completion: completion)
        vol.transport = self
        if differe || hotesDifferes.contains(hote) {
            enAttente.append(vol)
        } else {
            vol.completion = nil
            completion(reponse)
        }
        return vol
    }

    /// Livre la plus ancienne réponse retenue (de cet hôte, s'il est donné).
    func terminerEnAttente(hote: String? = nil) {
        guard let index = enAttente.firstIndex(where: { hote == nil || $0.requete.url.host == hote }) else { return }
        let vol = enAttente.remove(at: index)
        let completion = vol.completion
        vol.completion = nil
        completion?(vol.reponse)
    }

    private func annuler(_ vol: EnVol) {
        guard let index = enAttente.firstIndex(where: { $0 === vol }) else { return }
        enAttente.remove(at: index)
        annulations.append(vol.requete)
        let completion = vol.completion
        vol.completion = nil
        completion?(.failed(detail: "requête annulée",
                            error: TransportError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    }
}

/// Sonde du réseau local simulée : note chaque sonde, répond `refuse` (dans l'appel, ou à
/// `repondre()` avec `differe`). Aucune connexion n'est ouverte.
final class FakeProbe: LocalNetworkProbe {
    var refuse = false
    var differe = false
    private(set) var sondes: [(host: String, port: Int)] = []
    private var enAttente: [(Bool) -> Void] = []

    func checkLocalNetworkDenied(host: String, port: Int, _ completion: @escaping (Bool) -> Void) {
        sondes.append((host, port))
        if differe { enAttente.append(completion) } else { completion(refuse) }
    }

    func repondre() {
        let attentes = enAttente
        enAttente.removeAll()
        attentes.forEach { $0(refuse) }
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

    func requestOff(peer: String) { appels.append(.off(peer)) }
    func requestOn(peer: String) { appels.append(.on(peer)) }
    func resync() { appels.append(.resync) }
}
