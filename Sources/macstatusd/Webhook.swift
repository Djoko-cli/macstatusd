import Foundation

/// Pousse l'état vers Homebridge (plugin http‑webhooks) avec réessais,
/// fusion des changements et suivi de ce qui a réellement été confirmé.
///
/// Un webhook perdu ne peut pas laisser HomeKit désynchronisé : tant que l'état
/// confirmé diffère de l'état voulu, l'envoi est réessayé (et le battement de
/// cœur du moteur d'état repousse l'état périodiquement).
final class WebhookClient {
    private let queue = DispatchQueue(label: "macstatusd.webhook", qos: .utility)
    private let session: URLSession
    private let enabled: Bool
    private let baseURL: String
    private let accessoryID: String
    private let maxRetries: Int
    private let retryDelays: [TimeInterval] = [0.5, 2, 5, 10]

    private var desired: Bool?
    private var confirmed: Bool?
    private var inFlight = false
    private var attempt = 0
    private var lastAttemptAt: Date?
    private var lastSuccessAt: Date?
    private var lastDetail = "aucun envoi"
    private var failureCount = 0
    private var waiters: [(Bool) -> Void] = []

    init(config: Config) {
        enabled = config.enabled && !config.webhookBaseURL.isEmpty
        baseURL = config.webhookBaseURL
        accessoryID = config.accessoryID
        maxRetries = config.webhookRetries

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(config.webhookTimeoutMS) / 1000
        configuration.timeoutIntervalForResource = Double(config.webhookTimeoutMS) / 1000 * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldUsePipelining = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        if !enabled {
            lastDetail = "désactivé par la configuration"
        }
    }

    /// Demande la publication d'un état. `force` réémet même si l'état est déjà
    /// confirmé (battement de cœur, resynchronisation).
    func publish(_ state: Bool, force: Bool = false) {
        guard enabled else { return }
        queue.async { [self] in
            if force { confirmed = nil }
            if desired != state {
                desired = state
                attempt = 0
            }
            guard desired != confirmed else { return }
            sendIfIdle()
        }
    }

    /// Attend que l'état voulu soit confirmé (ou le délai écoulé).
    /// À n'appeler que depuis une autre file que celle du client.
    func waitForDelivery(timeout: TimeInterval) {
        guard enabled else { return }
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            guard desired != nil, desired != confirmed else {
                semaphore.signal()
                return
            }
            waiters.append { _ in semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func sendIfIdle() {
        guard !inFlight, let state = desired else { return }
        guard let url = makeURL(state: state) else {
            lastDetail = "URL invalide: \(baseURL)"
            logError("webhook: \(lastDetail)")
            return
        }

        inFlight = true
        lastAttemptAt = Date()
        let attemptNumber = attempt

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("macstatusd/\(macstatusdVersion)", forHTTPHeaderField: "User-Agent")

        logDebug("webhook → \(state ? "true" : "false") (essai \(attemptNumber + 1))")

        session.dataTask(with: request) { [weak self] _, response, error in
            self?.queue.async {
                self?.finish(state: state, response: response as? HTTPURLResponse, error: error)
            }
        }.resume()
    }

    private func finish(state: Bool, response: HTTPURLResponse?, error: Error?) {
        inFlight = false

        let statusCode = response?.statusCode ?? 0
        let success = error == nil && (200...299).contains(statusCode)

        if success {
            confirmed = state
            lastSuccessAt = Date()
            failureCount = 0
            attempt = 0
            lastDetail = "HTTP \(statusCode)"
            logInfo("webhook confirmé: état=\(state ? "1" : "0")")
            if desired == confirmed {
                let pending = waiters
                waiters.removeAll()
                pending.forEach { $0(true) }
            }
        } else {
            failureCount += 1
            lastDetail = error.map { "erreur \($0.localizedDescription)" } ?? "HTTP \(statusCode)"
            logWarn("webhook échoué (état=\(state ? "1" : "0")): \(lastDetail)")
            if attempt < maxRetries {
                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                attempt += 1
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sendIfIdle() }
                return
            }
            logError("webhook abandonné après \(attempt + 1) essais — reprise au prochain battement de cœur")
            attempt = 0
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0(false) }
            return
        }

        if desired != confirmed {
            sendIfIdle()
        }
    }

    private func makeURL(state: Bool) -> URL? {
        let separator = baseURL.contains("?") ? "&" : "?"
        let identifier = accessoryID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? accessoryID
        return URL(string: "\(baseURL)\(separator)accessoryId=\(identifier)&state=\(state ? "true" : "false")")
    }

    var statusDictionary: [String: Any] {
        queue.sync {
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
}
