import Foundation
import MacStatusCore

/// Transport réel du client webhook : une session éphémère à délégué, sans cache ni pipelining,
/// aux délais de la configuration. Chaque réponse est rappelée sur la file reçue à l'init (celle
/// du moteur d'état).
///
/// Bornes :
/// - **aucune redirection** : le délégué répond `completionHandler(nil)`, la réponse 3xx est
///   rendue telle quelle au client, qui la compte comme un échec ;
/// - **corps plafonné à 4 Kio** : au-delà, la tâche est annulée et l'envoi échoue ;
/// - **annulation** : le jeton rendu par `send` annule la tâche ; sa réponse n'est alors pas rendue.
///
/// En échec, le détail donne le domaine et le code de l'`NSError` (le client y repère -1009 et -1004).
final class URLSessionTransport: NSObject, WebhookTransport, URLSessionDataDelegate {
    /// Taille maximale du corps d'une réponse.
    static let maxBodyBytes = 4 * 1024

    private var session: URLSession!
    private let queue: DispatchQueue

    /// État d'une tâche, du lancement à la fin. Protégé par `lock` : `send` et `cancel` viennent de
    /// la file du moteur, les rappels du délégué de la file de la session.
    private final class Pending {
        let completion: (WebhookOutcome) -> Void
        var response: HTTPURLResponse?
        var received = 0
        var tooLarge = false
        var cancelledByClient = false
        init(_ completion: @escaping (WebhookOutcome) -> Void) { self.completion = completion }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    private final class Token: Cancellable {
        weak var transport: URLSessionTransport?
        let task: URLSessionDataTask
        init(transport: URLSessionTransport, task: URLSessionDataTask) {
            self.transport = transport
            self.task = task
        }
        func cancel() { transport?.cancel(task) }
    }

    init(config: Config, queue: DispatchQueue) {
        self.queue = queue
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.webhookTimeout
        configuration.timeoutIntervalForResource = config.webhookTimeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldUsePipelining = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "macstatusd.webhook.session"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    @discardableResult
    func send(_ request: WebhookRequest, _ completion: @escaping (WebhookOutcome) -> Void) -> Cancellable {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.dataTask(with: urlRequest)
        lock.lock()
        pending[task.taskIdentifier] = Pending(completion)
        lock.unlock()
        task.resume()
        return Token(transport: self, task: task)
    }

    private func cancel(_ task: URLSessionDataTask) {
        lock.lock()
        pending[task.taskIdentifier]?.cancelledByClient = true
        lock.unlock()
        task.cancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Refus : la réponse 3xx elle-même termine la tâche.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let state = pending[dataTask.taskIdentifier]
        state?.response = response as? HTTPURLResponse
        let announced = response.expectedContentLength
        if announced > Int64(Self.maxBodyBytes) { state?.tooLarge = true }
        lock.unlock()
        completionHandler(announced > Int64(Self.maxBodyBytes) ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var overflow = false
        if let state = pending[dataTask.taskIdentifier] {
            state.received += data.count
            if state.received > Self.maxBodyBytes {
                state.tooLarge = true
                overflow = true
            }
        }
        lock.unlock()
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state, !state.cancelledByClient else { return }

        let outcome: WebhookOutcome
        if state.tooLarge {
            outcome = .failed(detail: "corps de réponse au-delà de \(Self.maxBodyBytes / 1024) Kio, requête annulée")
        } else if let error {
            let ns = error as NSError
            outcome = .failed(detail: ns.localizedDescription,
                              error: TransportError(domain: ns.domain, code: ns.code))
        } else if let http = state.response {
            outcome = .delivered(status: http.statusCode)
        } else {
            outcome = .failed(detail: "réponse non HTTP")
        }
        let completion = state.completion
        queue.async { completion(outcome) }
    }
}
