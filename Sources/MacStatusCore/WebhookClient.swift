import Foundation

/// Requête HTTP que le client demande au transport d'émettre.
public struct WebhookRequest: Equatable {
    public let url: URL
    public let method: String
    public let headers: [String: String]

    public init(url: URL, method: String, headers: [String: String]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

/// Résultat d'un envoi : une réponse HTTP (de n'importe quel code, le client
/// décide ce qui compte comme un succès) ou un échec avant toute réponse.
public enum WebhookOutcome: Equatable {
    case delivered(status: Int)
    case failed(detail: String)
}

/// Émetteur de requêtes, injectable pour que les tests n'ouvrent aucune connexion.
///
/// **Contrat de file** : `completion` est toujours rappelé sur la file du moteur
/// d'état, celle depuis laquelle le client appelle `send`. Le client n'a aucune
/// file propre et ne se protège par aucun verrou.
public protocol WebhookTransport: AnyObject {
    func send(_ request: WebhookRequest, _ completion: @escaping (WebhookOutcome) -> Void)
}

/// Pousse l'état vers Homebridge (plugin http‑webhooks) avec réessais,
/// fusion des changements et suivi de ce qui a réellement été confirmé.
///
/// Un webhook perdu ne peut pas laisser HomeKit désynchronisé : tant que l'état
/// confirmé diffère de l'état voulu, l'envoi est réessayé (et le battement de
/// cœur du moteur d'état repousse l'état périodiquement).
///
/// **Contrat de file** : le client vit sur la file du moteur d'état. Toutes ses
/// méthodes, `statusDictionary` comprise, s'appellent depuis cette file ; le
/// transport et le planificateur y rappellent. Rien n'y bloque jamais.
public final class WebhookClient: StatePublisher {
    private let transport: WebhookTransport
    private let scheduler: Scheduler
    private let clock: Clock

    private let enabled: Bool
    private let baseURL: String
    private let accessoryID: String
    private let maxRetries: Int
    private let retryDelays: [TimeInterval] = [0.5, 2, 5, 10]

    private var desired: Bool?
    private var confirmed: Bool?
    private var inFlight = false
    private var attempt = 0
    private var retryTask: Cancellable?
    private var lastAttemptAt: Date?
    private var lastSuccessAt: Date?
    private var lastDetail = "aucun envoi"
    private var lastRequestURL: String?
    private var failureCount = 0
    private var waiters: [DeliveryWaiter] = []

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

    public init(config: Config, transport: WebhookTransport, scheduler: Scheduler, clock: Clock) {
        self.transport = transport
        self.scheduler = scheduler
        self.clock = clock
        enabled = config.enabled && !config.webhookBaseURL.isEmpty
        baseURL = config.webhookBaseURL
        accessoryID = config.accessoryID
        maxRetries = config.webhookRetries

        if !enabled {
            lastDetail = "désactivé par la configuration"
        }
    }

    /// Demande la publication d'un état. `force` réémet même si l'état est déjà
    /// confirmé (battement de cœur, resynchronisation).
    public func publish(_ state: Bool, force: Bool = false) {
        guard enabled else { return }
        if force { confirmed = nil }
        if desired != state {
            desired = state
            attempt = 0
        }
        guard desired != confirmed else { return }
        sendIfIdle()
    }

    /// Prévient `done` dès que l'état voulu est confirmé (`true`), que l'envoi est abandonné
    /// ou que `timeout` secondes se sont écoulées (`false`). Si rien n'est à livrer, `done`
    /// part tout de suite avec `true`. `done` est appelé exactement une fois, et l'attente est
    /// retirée de la liste à l'échéance.
    ///
    /// Ne bloque jamais : c'est un rappel, pas une attente. Le client partage la file du
    /// moteur, et une attente bloquante l'empêcherait de recevoir la réponse qu'elle attend.
    /// `done` s'exécute sur la file du moteur.
    public func notifyWhenDelivered(timeout: Double, _ done: @escaping (Bool) -> Void) {
        guard enabled, let desired, desired != confirmed else {
            done(true)
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

    /// Attentes de livraison en cours (diagnostic et tests).
    var pendingDeliveryNotifications: Int { waiters.count }

    private func sendIfIdle() {
        guard !inFlight, let state = desired else { return }
        guard let url = makeURL(state: state) else {
            lastDetail = "URL invalide: \(redactURL(baseURL))"
            logError("webhook: \(lastDetail)")
            return
        }

        // Un nouvel envoi remplace tout réessai en attente.
        retryTask?.cancel()
        retryTask = nil

        inFlight = true
        lastAttemptAt = clock.wall()
        let attemptNumber = attempt
        lastRequestURL = url.absoluteString

        let request = WebhookRequest(url: url, method: "GET",
                                     headers: ["User-Agent": "macstatusd/\(macstatusdVersion)"])

        logDebug("webhook → \(state ? "true" : "false") (essai \(attemptNumber + 1))")

        transport.send(request) { [weak self] outcome in
            self?.finish(state: state, outcome: outcome)
        }
    }

    private func finish(state: Bool, outcome: WebhookOutcome) {
        inFlight = false

        var failure: String?
        switch outcome {
        case .delivered(let status) where (200...299).contains(status):
            lastDetail = "HTTP \(status)"
        case .delivered(let status):
            failure = "HTTP \(status)"
        case .failed(let detail):
            failure = "erreur \(hidingConfiguredURL(in: detail))"
        }

        guard let failure else {
            confirmed = state
            lastSuccessAt = clock.wall()
            failureCount = 0
            attempt = 0
            logInfo("webhook confirmé: état=\(state ? "1" : "0")")
            if desired == confirmed {
                resolveWaiters(delivered: true)
            } else {
                sendIfIdle()
            }
            return
        }

        failureCount += 1
        lastDetail = failure
        logWarn("webhook échoué (état=\(state ? "1" : "0")): \(lastDetail)")
        if attempt < maxRetries {
            let delay = retryDelays[min(attempt, retryDelays.count - 1)]
            attempt += 1
            retryTask = scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                retryTask = nil
                // L'état voulu a pu être confirmé entre-temps : rien à réessayer.
                guard desired != confirmed else { return }
                sendIfIdle()
            }
            return
        }
        logError("webhook abandonné après \(attempt + 1) essais — reprise au prochain battement de cœur")
        attempt = 0
        resolveWaiters(delivered: false)
    }

    /// Un message d'erreur du transport peut citer l'URL demandée : la requête complète, puis l'URL de
    /// base, sont remplacées par leur version masquée (`redactURL`) avant d'entrer au journal ou
    /// dans `/status`.
    private func hidingConfiguredURL(in detail: String) -> String {
        var text = detail
        if let lastRequestURL, !lastRequestURL.isEmpty {
            text = text.replacingOccurrences(of: lastRequestURL, with: redactURL(lastRequestURL))
        }
        if !baseURL.isEmpty {
            text = text.replacingOccurrences(of: baseURL, with: redactURL(baseURL))
        }
        return text
    }

    private func resolveWaiters(delivered: Bool) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.finish(delivered) }
    }

    private func makeURL(state: Bool) -> URL? {
        let separator = baseURL.contains("?") ? "&" : "?"
        let identifier = accessoryID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? accessoryID
        return URL(string: "\(baseURL)\(separator)accessoryId=\(identifier)&state=\(state ? "true" : "false")")
    }

    /// Diagnostic pour /status. À appeler depuis la file du moteur.
    public var statusDictionary: [String: Any] {
        var dict: [String: Any] = [
            "enabled": enabled,
            "detail": lastDetail,
            "failures_since_success": failureCount,
            "in_flight": inFlight,
        ]
        if let desired { dict["desired"] = desired ? "1" : "0" }
        if let confirmed { dict["confirmed"] = confirmed ? "1" : "0" }
        if let lastAttemptAt { dict["last_attempt"] = ISO8601DateFormatter().string(from: lastAttemptAt) }
        if let lastSuccessAt { dict["last_success"] = ISO8601DateFormatter().string(from: lastSuccessAt) }
        return dict
    }
}
