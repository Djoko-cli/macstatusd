import Foundation
import MacStatusCore

/// Transport réel du client webhook : une session éphémère, sans cache ni
/// pipelining, aux délais de la configuration. Chaque réponse est rappelée sur
/// la file reçue à l'init (celle du moteur d'état).
final class URLSessionTransport: WebhookTransport {
    private let session: URLSession
    private let queue: DispatchQueue

    init(config: Config, queue: DispatchQueue) {
        self.queue = queue
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(config.webhookTimeoutMS) / 1000
        configuration.timeoutIntervalForResource = Double(config.webhookTimeoutMS) / 1000 * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldUsePipelining = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: WebhookRequest, _ completion: @escaping (WebhookOutcome) -> Void) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        session.dataTask(with: urlRequest) { [queue] _, response, error in
            let outcome: WebhookOutcome
            if let error {
                outcome = .failed(detail: error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                outcome = .delivered(status: http.statusCode)
            } else {
                outcome = .failed(detail: "réponse non HTTP")
            }
            queue.async { completion(outcome) }
        }.resume()
    }
}
