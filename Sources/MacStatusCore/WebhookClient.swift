import Foundation

/// Requête HTTP que le client demande au transport d'émettre.
public struct WebhookRequest: Equatable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    /// Corps de la requête (POST : JSON), `nil` en GET.
    public let body: Data?

    public init(url: URL, method: String, headers: [String: String], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Erreur du transport avant toute réponse : domaine et code de l'`NSError`.
public struct TransportError: Equatable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// Résultat d'un envoi : une réponse HTTP (de n'importe quel code, le client
/// décide ce qui compte comme un succès) ou un échec avant toute réponse.
public enum WebhookOutcome: Equatable {
    case delivered(status: Int)
    /// `detail` est lisible ; `error` donne le domaine et le code quand le transport les connaît.
    case failed(detail: String, error: TransportError? = nil)
}

/// Émetteur de requêtes, injectable pour que les tests n'ouvrent aucune connexion.
///
/// **Contrat de file** : `completion` est toujours rappelé sur la file du moteur
/// d'état, celle depuis laquelle le client appelle `send`. Le client n'a aucune
/// file propre et ne se protège par aucun verrou.
///
/// **Annulation** : `cancel()` sur le jeton rendu interrompt la requête en vol. Après
/// l'annulation, `completion` peut encore être rappelé (avec un échec), ou ne pas l'être ; le
/// client ignore toute réponse d'une requête qu'il a annulée.
public protocol WebhookTransport: AnyObject {
    @discardableResult
    func send(_ request: WebhookRequest, _ completion: @escaping (WebhookOutcome) -> Void) -> Cancellable
}

/// Sonde du chemin réseau vers une cible, quand un envoi échoue faute de réseau (-1009) ou de
/// connexion (-1004) : `completion(true)` si macOS refuse l'accès au réseau local au processus
/// (`NWPath.UnsatisfiedReason.localNetworkDenied`). Rappelée sur la file du moteur. L'adaptateur
/// réel (`NWConnection`) vit dans l'exécutable ; le client ne sonde jamais qu'une de ses cibles.
public protocol LocalNetworkProbe: AnyObject {
    func checkLocalNetworkDenied(host: String, port: Int, _ completion: @escaping (Bool) -> Void)
}

/// Pousse l'état vers une ou plusieurs cibles (Homebridge en GET, Home Assistant en POST), avec
/// réessais, fusion des changements et suivi de ce que chaque cible a réellement confirmé.
///
/// **Par cible** : état confirmé, requête en vol (une seule à la fois), tentative, génération et
/// minuterie de réessai. Une cible en panne ne retarde jamais une autre. L'état voulu, lui, est
/// commun.
///
/// **Calendrier d'une cible qui échoue** : réessais rapides à +0,5 s, +2 s, +5 s, +10 s (au plus
/// `webhook_retries`), puis abandon de la série et réessai lent, à +15 s, +30 s, puis toutes les
/// 60 s, tant que l'état voulu n'est pas confirmé. Un nouvel état voulu, ou le retour du réseau
/// (`networkBecameAvailable`), relance tout de suite une série rapide complète.
///
/// **Génération** : chaque envoi et chaque annulation font avancer le compteur de la cible ; une
/// minuterie ou une réponse d'une génération passée ne fait rien.
///
/// **Secrets** : l'URL d'une cible n'entre au journal et dans `/status` que masquée
/// (`redactURL`) ; ses en-têtes jamais.
///
/// **Contrat de file** : le client vit sur la file du moteur d'état. Toutes ses
/// méthodes, `statusDictionary` comprise, s'appellent depuis cette file ; le
/// transport, la sonde et le planificateur y rappellent. Rien n'y bloque jamais.
public final class WebhookClient: StatePublisher {
    /// Délais des réessais rapides, dans l'ordre (le dernier se répète si `webhook_retries` > 4).
    static let fastRetryDelays: [TimeInterval] = [0.5, 2, 5, 10]
    /// Délais du réessai lent après l'abandon d'une série rapide (le dernier se répète).
    static let slowRetryDelays: [TimeInterval] = [15, 30, 60]
    /// Intervalle minimal entre deux relances par `networkBecameAvailable` (pas de rafale).
    static let networkKickInterval: TimeInterval = 2
    /// Grâce de l'arrêt : une requête ON déjà en vol dispose de ce délai pour aboutir avant d'être
    /// annulée au profit de OFF. Courte, pour que le départ reste sous le délai de livraison de 2 s.
    static let exitGraceDelay: TimeInterval = 0.5

    private let transport: WebhookTransport
    private let scheduler: Scheduler
    private let clock: Clock
    private let probe: LocalNetworkProbe?

    private let enabled: Bool
    private let accessoryID: String
    private let maxRetries: Int
    private let disabledDetail: String
    private let targets: [Target]

    private var desired: Bool?
    private var waiters: [DeliveryWaiter] = []
    private var lastNetworkKickAt: Double?
    private var unusableLogged = false
    /// Vrai tant que le moteur interdit tout envoi (voir `setSendingSuspended`).
    private var suspended = false

    /// État d'une cible. Classe : le client la modifie en place, et les rappels la retrouvent.
    private final class Target {
        let number: Int
        let target: WebhookTarget
        /// URL masquée, seule forme qui entre au journal et dans `/status`.
        let shownURL: String
        /// Requêtes préparées pour chaque état ; `nil` si l'URL est inutilisable.
        let requests: [Bool: WebhookRequest]?

        var confirmed: Bool?
        /// Dernier état confirmé par cette cible, que `force` n'efface pas (journal : changement
        /// ou battement de cœur).
        var lastDelivered: Bool?
        var inFlightState: Bool?
        var inFlightToken: Cancellable?
        var attempt = 0
        var abandoned = false
        var slowIndex = 0
        var generation = 0
        var retryTask: Cancellable?
        var retryDueAt: Double?
        /// Minuterie de grâce de l'arrêt (voir `publishBeforeExit`), gardée par la génération.
        var graceTask: Cancellable?
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var lastDetail = "aucun envoi"
        var lastRequestURL: String?
        var failureCount = 0
        /// Instant monotone du premier échec de l'épisode en cours (`nil` : pas de panne).
        var outageSince: Double?
        /// Sonde du réseau local déjà lancée pendant cet épisode d'échec.
        var probed = false

        var usable: Bool { requests != nil }
        var inFlight: Bool { inFlightState != nil }
        var label: String { "cible \(number)" }
        var description: String { "cible \(number) (\(target.method) \(shownURL))" }

        init(number: Int, target: WebhookTarget, requests: [Bool: WebhookRequest]?) {
            self.number = number
            self.target = target
            self.shownURL = redactURL(target.url)
            self.requests = requests
            if requests == nil { lastDetail = "URL invalide : \(shownURL)" }
        }
    }

    /// Attente de livraison : se termine une seule fois, par la livraison, l'abandon ou le délai.
    private final class DeliveryWaiter {
        private var completion: ((Bool) -> Void)?
        var timeout: Cancellable?

        init(_ completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        func finish(_ delivered: Bool) {
            guard let completion else { return }
            self.completion = nil
            timeout?.cancel()
            timeout = nil
            completion(delivered)
        }
    }

    public init(config: Config, transport: WebhookTransport, scheduler: Scheduler, clock: Clock,
                probe: LocalNetworkProbe? = nil) {
        self.transport = transport
        self.scheduler = scheduler
        self.clock = clock
        self.probe = probe
        accessoryID = config.accessoryID
        maxRetries = config.webhookRetries
        let configured = config.webhookTargets
        targets = configured.enumerated().map { index, target in
            Target(number: index + 1, target: target,
                   requests: Self.prepareRequests(for: target, accessoryID: config.accessoryID))
        }
        enabled = config.enabled && !targets.isEmpty
        disabledDetail = config.enabled ? "aucune cible configurée" : "désactivé par la configuration"
    }

    // MARK: - Publication

    /// Demande la publication d'un état. `force` réémet même si l'état est déjà
    /// confirmé (battement de cœur, resynchronisation) ; vers une cible au réessai lent, c'est un
    /// essai de plus, sans nouvelle série rapide.
    public func publish(_ state: Bool, force: Bool = false) {
        guard enabled, !suspended else { return }
        logUnusableTargetsOnce()
        if desired != state {
            desired = state
            for target in targets {
                target.attempt = 0
                target.abandoned = false
                target.slowIndex = 0
            }
        }
        for target in targets where target.usable {
            if force { target.confirmed = nil }
            // Une requête en vol rend la main d'abord : sa réponse relance l'envoi s'il le faut.
            guard desired != target.confirmed, !target.inFlight else { continue }
            send(target)
        }
    }

    /// Arrêt : publie `state` en force vers chaque cible, sans attendre le battement de cœur. Les
    /// minuteries en attente sont remplacées par l'envoi.
    ///
    /// **Requête en vol pour un autre état** (un ON, à l'arrêt) : elle n'est pas annulée tout de
    /// suite, car une requête annulée a pu atteindre la cible sans qu'on le sache, et rien ne
    /// garantit alors l'ordre d'arrivée des deux requêtes. L'état voulu devient `state` ; si l'ON
    /// aboutit (ou échoue) dans la grâce de `exitGraceDelay` (500 ms), OFF part par le chemin
    /// normal, après lui, donc dans l'ordre. Si l'ON est encore en vol à l'échéance, il est annulé
    /// et OFF part aussitôt. Une requête en vol pour ce même état est gardée : sa réponse vaut
    /// confirmation.
    ///
    /// Limite connue : une requête annulée à l'échéance a pu atteindre la cible ; l'ordre d'arrivée
    /// n'est alors plus garanti. C'est le prix d'un départ borné.
    public func publishBeforeExit(_ state: Bool) {
        guard enabled, !suspended else { return }
        logUnusableTargetsOnce()
        desired = state
        for target in targets where target.usable {
            target.attempt = 0
            target.abandoned = false
            target.slowIndex = 0
            target.confirmed = nil
            if let flying = target.inFlightState {
                if flying == state { continue }
                logDebug("webhook \(target.label) : requête état=\(flying ? "1" : "0") en vol, "
                         + "grâce de 500 ms avant de l'annuler pour l'arrêt")
                scheduleExitGrace(target)
                continue
            }
            send(target)
        }
    }

    /// Le réseau est revenu (`NWPathMonitor` passé à `.satisfied`) : pour chaque cible non
    /// confirmée et sans requête en vol, la tentative revient à 0 et l'envoi part tout de suite.
    /// Deux avis à moins de `networkKickInterval` secondes : le second ne fait rien.
    public func networkBecameAvailable() {
        guard enabled, !suspended, let desired else { return }
        let now = clock.monotonic()
        if let last = lastNetworkKickAt, now >= last, now - last < Self.networkKickInterval {
            logDebug("webhook : avis de retour du réseau trop rapproché, ignoré")
            return
        }
        var kicked = 0
        for target in targets where target.usable && target.confirmed != desired && !target.inFlight {
            target.attempt = 0
            target.abandoned = false
            target.slowIndex = 0
            send(target)
            kicked += 1
        }
        guard kicked > 0 else { return }
        lastNetworkKickAt = now
        logInfo("webhook : réseau disponible → renvoi immédiat vers \(kicked) cible(s) non confirmée(s)")
    }

    // MARK: - Suspension

    /// Suspend ou rend les envois. Suspendu : plus aucune requête ne part (publication, réessais
    /// rapides et lents, relance au retour du réseau, envoi d'arrêt), les minuteries de réessai sont
    /// retirées et les réponses tardives ne relancent rien. Une requête déjà en vol n'est pas annulée.
    /// À la levée, rien ne part de soi-même : les cibles non confirmées repartent d'une série rapide
    /// neuve, et le moteur publie l'état courant en `force`.
    public func setSendingSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        if suspended {
            for target in targets {
                cancelRetry(target)
                cancelGrace(target)
            }
            logInfo("webhook : envois suspendus (cette instance ne publie plus)")
        } else {
            for target in targets {
                target.attempt = 0
                target.abandoned = false
                target.slowIndex = 0
            }
            logInfo("webhook : envois repris")
        }
    }

    // MARK: - Attente de livraison

    /// Prévient `done` dès que l'état voulu est confirmé par toutes les cibles (`true`), dès que
    /// chacune a confirmé ou abandonné sa série rapide (`false`), ou quand `timeout` secondes se
    /// sont écoulées (`false`).
    /// - déjà confirmé partout, ou rien n'a jamais été demandé : `done(true)` tout de suite ;
    /// - aucune cible utilisable (client désactivé, mode dégradé, URL invalide) : `done(false)`
    ///   tout de suite, sans attendre l'échéance (ajout 3).
    /// `done` est appelé exactement une fois, et l'attente est retirée de la liste à l'échéance.
    ///
    /// Ne bloque jamais : c'est un rappel, pas une attente. Le client partage la file du
    /// moteur, et une attente bloquante l'empêcherait de recevoir la réponse qu'elle attend.
    /// `done` s'exécute sur la file du moteur.
    public func notifyWhenDelivered(timeout: Double, _ done: @escaping (Bool) -> Void) {
        if let verdict = deliveryVerdict() {
            done(verdict)
            return
        }
        let waiter = DeliveryWaiter(done)
        waiters.append(waiter)
        waiter.timeout = scheduler.schedule(after: timeout) { [weak self, weak waiter] in
            guard let self, let waiter else { return }
            waiters.removeAll { $0 === waiter }
            waiter.finish(false)
        }
    }

    /// Vrai si le client est actif et qu'au moins une cible a une URL utilisable.
    public var hasUsableTarget: Bool { enabled && targets.contains(where: \.usable) }

    /// Cibles qui ont confirmé l'état voulu, sur toutes les cibles configurées (0 si désactivé).
    public var deliveryCounts: (confirmed: Int, total: Int) {
        guard enabled else { return (0, 0) }
        guard let desired else { return (0, targets.count) }
        return (targets.filter { $0.usable && $0.confirmed == desired }.count, targets.count)
    }

    /// Attentes de livraison en cours (diagnostic et tests).
    var pendingDeliveryNotifications: Int { waiters.count }

    /// `true` : tout est confirmé ; `false` : rien de plus ne sera confirmé sans nouvel événement
    /// (aucune cible utilisable, ou chaque cible non confirmée a abandonné) ; `nil` : un envoi
    /// est encore en cours (requête en vol ou réessai rapide en attente).
    private func deliveryVerdict() -> Bool? {
        let usable = targets.filter(\.usable)
        guard enabled, !usable.isEmpty else { return false }
        guard let desired else { return true }
        var allConfirmed = true
        for target in usable where target.confirmed != desired {
            allConfirmed = false
            if target.inFlight || !target.abandoned { return nil }
        }
        return allConfirmed && usable.count == targets.count
    }

    private func resolveWaitersIfSettled() {
        guard !waiters.isEmpty, let verdict = deliveryVerdict() else { return }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.finish(verdict) }
    }

    // MARK: - Envoi et réponse

    private func send(_ target: Target) {
        guard !suspended, let state = desired, let request = target.requests?[state] else { return }
        cancelRetry(target)
        cancelGrace(target)
        target.generation += 1
        let generation = target.generation
        target.inFlightState = state
        target.inFlightToken = nil
        target.lastAttemptAt = clock.wall()
        target.lastRequestURL = request.url.absoluteString

        logDebug("webhook \(target.label) → \(state ? "true" : "false") (essai \(target.attempt + 1)"
                 + (target.abandoned ? ", réessai lent" : "") + ")")

        let token = transport.send(request) { [weak self, weak target] outcome in
            guard let self, let target else { return }
            finish(target, generation: generation, state: state, outcome: outcome)
        }
        // Le transport peut avoir répondu dans l'appel : le jeton ne sert qu'à une requête encore en vol.
        if target.generation == generation, target.inFlight { target.inFlightToken = token }
    }

    /// Annule la requête en vol : la génération avance d'abord, pour que la réponse (même rendue
    /// dans l'appel à `cancel()`) soit ignorée.
    private func cancelInFlight(_ target: Target) {
        let token = target.inFlightToken
        cancelGrace(target)
        target.generation += 1
        target.inFlightState = nil
        target.inFlightToken = nil
        token?.cancel()
    }

    private func cancelRetry(_ target: Target) {
        target.retryTask?.cancel()
        target.retryTask = nil
        target.retryDueAt = nil
    }

    private func cancelGrace(_ target: Target) {
        target.graceTask?.cancel()
        target.graceTask = nil
    }

    /// Grâce de l'arrêt : si la requête en vol (d'un autre état que le voulu) l'est encore à
    /// l'échéance, elle est annulée et l'état voulu part. Gardée par la génération et `inFlight` :
    /// une réponse, un envoi ou une annulation survenus entre-temps la rendent sans effet.
    private func scheduleExitGrace(_ target: Target) {
        cancelGrace(target)
        let generation = target.generation
        target.graceTask = scheduler.schedule(after: Self.exitGraceDelay) { [weak self, weak target] in
            guard let self, let target else { return }
            guard target.generation == generation, let flying = target.inFlightState, flying != desired else { return }
            target.graceTask = nil
            cancelInFlight(target)
            logInfo("webhook \(target.label) : requête état=\(flying ? "1" : "0") encore en vol après 500 ms "
                    + "→ annulée pour l'arrêt")
            send(target)
        }
    }

    private func scheduleRetry(_ target: Target, after delay: TimeInterval) {
        cancelRetry(target)
        guard !suspended else { return }
        let generation = target.generation
        target.retryDueAt = clock.monotonic() + delay
        target.retryTask = scheduler.schedule(after: delay) { [weak self, weak target] in
            guard let self, let target else { return }
            // Minuterie périmée (un envoi, une annulation ont eu lieu depuis) : rien.
            guard target.generation == generation, !target.inFlight else { return }
            target.retryTask = nil
            target.retryDueAt = nil
            // L'état voulu a pu être confirmé entre-temps : rien à réessayer.
            guard desired != target.confirmed else { return }
            send(target)
        }
    }

    private func finish(_ target: Target, generation: Int, state: Bool, outcome: WebhookOutcome) {
        guard target.generation == generation, target.inFlight else {
            logDebug("webhook \(target.label) : réponse d'une requête annulée ou remplacée, ignorée")
            return
        }
        target.inFlightState = nil
        target.inFlightToken = nil
        let shown = state ? "1" : "0"

        var failure: String?
        switch outcome {
        case .delivered(let status) where (200...299).contains(status):
            target.lastDetail = "HTTP \(status)"
        case .delivered(let status) where status == 404:
            failure = "HTTP 404 : accessoryId inconnu de la cible"
        case .delivered(let status) where (300...399).contains(status):
            failure = "HTTP \(status) : redirection refusée"
        case .delivered(let status):
            failure = "HTTP \(status)"
        case .failed(let detail, let error):
            var text = "erreur \(hidingSecrets(in: detail, of: target))"
            if let error { text += " (\(error.domain) \(error.code))" }
            failure = text
        }

        guard let failure else {
            let outage = target.outageSince
            let changed = target.lastDelivered != state
            target.confirmed = state
            target.lastDelivered = state
            target.lastSuccessAt = clock.wall()
            target.failureCount = 0
            target.attempt = 0
            target.abandoned = false
            target.slowIndex = 0
            target.outageSince = nil
            target.probed = false
            if let outage {
                let duration = Self.duration(clock.monotonic() - outage)
                logInfo("webhook \(target.description) de retour après \(duration) de panne : état=\(shown) confirmé")
            } else if changed {
                logInfo("webhook \(target.label) confirmé : état=\(shown)")
            } else {
                logDebug("webhook \(target.label) : état=\(shown) reconfirmé (\(target.lastDetail))")
            }
            if desired != state {
                send(target)
            }
            resolveWaitersIfSettled()
            return
        }

        target.failureCount += 1
        target.lastDetail = failure
        if target.outageSince == nil { target.outageSince = clock.monotonic() }
        probeIfNeeded(target, outcome: outcome)

        // L'état voulu a changé pendant le vol : l'échec ne concerne qu'un état périmé, le nouvel
        // état part tout de suite, avec une série rapide entière (ajout 2, `webhook_retries` = 0 compris).
        if let wanted = desired, wanted != state {
            logWarn("webhook \(target.description) échoué (état=\(shown), remplacé par état=\(wanted ? "1" : "0")) : \(failure)")
            target.attempt = 0
            target.abandoned = false
            target.slowIndex = 0
            send(target)
            return
        }

        if target.abandoned {
            // Réessai lent : le journal a déjà dit l'abandon, le retour dira la durée de la panne.
            logDebug("webhook \(target.label) : réessai lent échoué (état=\(shown)) : \(failure)")
            scheduleSlowRetry(target)
            resolveWaitersIfSettled()
            return
        }

        logWarn("webhook \(target.description) échoué (état=\(shown)) : \(failure)")
        if target.attempt < maxRetries {
            let delay = Self.fastRetryDelays[min(target.attempt, Self.fastRetryDelays.count - 1)]
            target.attempt += 1
            scheduleRetry(target, after: delay)
            return
        }
        let tries = target.attempt + 1
        logError("webhook \(target.description) abandonné après \(tries) \(tries == 1 ? "essai" : "essais") — "
                 + "réessai lent dans 15 s, 30 s, puis toutes les 60 s")
        target.attempt = 0
        target.abandoned = true
        target.slowIndex = 0
        scheduleSlowRetry(target)
        resolveWaitersIfSettled()
    }

    private func scheduleSlowRetry(_ target: Target) {
        let delay = Self.slowRetryDelays[min(target.slowIndex, Self.slowRetryDelays.count - 1)]
        target.slowIndex += 1
        scheduleRetry(target, after: delay)
    }

    // MARK: - Accès au réseau local

    /// Échec faute de réseau (-1009) ou de connexion (-1004) : une sonde du chemin vers la cible,
    /// une seule fois par épisode d'échec. Un refus d'accès au réseau local donne une seule ligne
    /// ERROR par épisode.
    private func probeIfNeeded(_ target: Target, outcome: WebhookOutcome) {
        guard let probe, !target.probed,
              case .failed(_, let error?) = outcome, error.domain == NSURLErrorDomain,
              error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorCannotConnectToHost,
              let parts = URLComponents(string: target.target.url), let rawHost = parts.host, !rawHost.isEmpty
        else { return }
        target.probed = true
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
        probe.checkLocalNetworkDenied(host: host, port: port) { [weak target] denied in
            guard let target else { return }
            if denied {
                logError("webhook \(target.description) : accès au réseau local refusé à macstatusd "
                         + "(Réglages Système → Confidentialité et sécurité → Réseau local) : aucun envoi n'aboutira")
            } else {
                logDebug("webhook \(target.label) : sonde du chemin sans refus de l'accès au réseau local")
            }
        }
    }

    // MARK: - Requêtes

    /// Prépare les requêtes `true` et `false` d'une cible ; `nil` si son URL est inutilisable.
    private static func prepareRequests(for target: WebhookTarget, accessoryID: String) -> [Bool: WebhookRequest]? {
        guard Config.isUsableWebhookURL(target.url) else { return nil }
        let method = target.method.uppercased()
        var requests: [Bool: WebhookRequest] = [:]
        for state in [true, false] {
            var headers = ["User-Agent": "macstatusd/\(macstatusdVersion)"]
            let url: URL?
            var body: Data?
            if method == "POST" {
                url = URL(string: target.url)
                headers["Content-Type"] = "application/json"
                let object: [String: Any] = ["accessoryId": accessoryID, "state": state]
                body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            } else {
                let separator = target.url.contains("?") ? "&" : "?"
                let identifier = accessoryID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? accessoryID
                url = URL(string: "\(target.url)\(separator)accessoryId=\(identifier)&state=\(state ? "true" : "false")")
            }
            // Les en-têtes de la cible l'emportent, sans doublon de casse.
            for (name, value) in target.headers {
                headers = headers.filter { $0.key.lowercased() != name.lowercased() }
                headers[name] = value
            }
            guard let url, method == "GET" || body != nil else { return nil }
            requests[state] = WebhookRequest(url: url, method: method == "POST" ? "POST" : "GET",
                                             headers: headers, body: body)
        }
        return requests
    }

    private func logUnusableTargetsOnce() {
        guard !unusableLogged else { return }
        unusableLogged = true
        for target in targets where !target.usable {
            logError("webhook \(target.label) : \(target.lastDetail) → cible ignorée")
        }
    }

    /// Un message d'erreur du transport peut citer l'URL demandée, voire un en-tête : la requête
    /// complète, puis l'URL de la cible, sont remplacées par leur version masquée (`redactURL`), et
    /// toute valeur d'en-tête par `<masqué>`, avant d'entrer au journal ou dans `/status`.
    private func hidingSecrets(in detail: String, of target: Target) -> String {
        var text = detail
        if let lastRequestURL = target.lastRequestURL, !lastRequestURL.isEmpty {
            text = text.replacingOccurrences(of: lastRequestURL, with: redactURL(lastRequestURL))
        }
        if !target.target.url.isEmpty {
            text = text.replacingOccurrences(of: target.target.url, with: target.shownURL)
        }
        for value in target.target.headers.values.sorted(by: { $0.count > $1.count }) where value.count >= 4 {
            text = text.replacingOccurrences(of: value, with: "<masqué>")
        }
        return text
    }

    /// Durée lisible : « 42 s », « 3 min 5 s », « 2 h 17 min ».
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \((total % 3600) / 60) min"
    }

    // MARK: - Diagnostic

    /// Un seul formateur pour les heures de `/status` : en créer un coûte cher, et `statusDictionary` n'est lu que
    /// depuis la file du moteur.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Diagnostic pour /status. À appeler depuis la file du moteur. Une entrée par cible sous
    /// `targets`, l'URL masquée, jamais les en-têtes. Les clés communes (`confirmed`, `detail`…)
    /// résument les cibles : `confirmed` n'y figure que si toutes ont confirmé le même état.
    public var statusDictionary: [String: Any] {
        let formatter = Self.isoFormatter
        let now = clock.monotonic()
        var dict: [String: Any] = [
            "enabled": enabled,
            "failures_since_success": targets.reduce(0) { $0 + $1.failureCount },
            "in_flight": targets.contains { $0.inFlight },
            "suspended": suspended,
        ]
        if !enabled {
            dict["detail"] = disabledDetail
        } else if targets.count == 1 {
            dict["detail"] = targets[0].lastDetail
        } else {
            dict["detail"] = targets.map { "\($0.label) : \($0.lastDetail)" }.joined(separator: " ; ")
        }
        if let desired { dict["desired"] = desired ? "1" : "0" }
        if let first = targets.first?.confirmed, targets.allSatisfy({ $0.confirmed == first }) {
            dict["confirmed"] = first ? "1" : "0"
        }
        if let last = targets.compactMap(\.lastAttemptAt).max() { dict["last_attempt"] = formatter.string(from: last) }
        if let last = targets.compactMap(\.lastSuccessAt).max() { dict["last_success"] = formatter.string(from: last) }

        dict["targets"] = targets.map { target -> [String: Any] in
            var entry: [String: Any] = [
                "url": target.shownURL,
                "method": target.target.method.uppercased(),
                "detail": target.lastDetail,
                "failures_since_success": target.failureCount,
                "in_flight": target.inFlight,
                "phase": phase(of: target),
            ]
            if let confirmed = target.confirmed { entry["confirmed"] = confirmed ? "1" : "0" }
            if let due = target.retryDueAt { entry["next_retry_seconds"] = Int(max(0, due - now).rounded(.up)) }
            if let since = target.outageSince { entry["outage_seconds"] = Int(max(0, now - since)) }
            if let last = target.lastAttemptAt { entry["last_attempt"] = formatter.string(from: last) }
            if let last = target.lastSuccessAt { entry["last_success"] = formatter.string(from: last) }
            return entry
        }
        return dict
    }

    private func phase(of target: Target) -> String {
        if !target.usable { return "URL invalide" }
        if target.inFlight { return "en vol" }
        if suspended { return "suspendu" }
        if target.abandoned { return "réessai lent" }
        if target.retryTask != nil { return "réessais rapides" }
        if let desired, target.confirmed == desired { return "confirmé" }
        return "en attente"
    }
}
