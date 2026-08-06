import Foundation
import Network

struct HTTPRequest {
    var method = "GET"
    var path = "/"
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var peer = "?"
}

struct HTTPResponse {
    var status = 200
    var contentType = "text/plain; charset=utf-8"
    var body = Data()

    static func text(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    var reasonPhrase: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}

/// Serveur HTTP minimal mais défensif : requêtes bornées en taille et en durée,
/// une réponse par connexion, et surtout **redémarrage automatique** du listener
/// en cas d'échec (port occupé, réinitialisation réseau) au lieu d'un crash.
final class HTTPServer {
    private let queue = DispatchQueue(label: "macstatusd.http")
    private let port: UInt16
    private let bindAddress: String
    private let handler: (HTTPRequest) -> HTTPResponse
    private let maxRequestBytes = 16 * 1024
    private let requestTimeout: TimeInterval = 5

    private var listener: NWListener?
    private var restartDelay: TimeInterval = 1
    private var restartScheduled = false
    private var stopped = false

    init(port: UInt16, bindAddress: String, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.bindAddress = bindAddress
        self.handler = handler
    }

    func start() {
        queue.async { [self] in
            stopped = false
            createListener()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            listener?.cancel()
            listener = nil
        }
    }

    private func createListener() {
        restartScheduled = false
        guard !stopped else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            logError("port \(port) invalide")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
            tcp.noDelay = true
        }

        let newListener: NWListener
        do {
            if bindAddress.isEmpty {
                newListener = try NWListener(using: parameters, on: nwPort)
            } else {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: nwPort)
                newListener = try NWListener(using: parameters)
            }
        } catch {
            logError("création du listener impossible: \(error) → nouvelle tentative dans \(Int(restartDelay)) s")
            scheduleRestart()
            return
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                restartDelay = 1
                let bind = bindAddress.isEmpty ? "0.0.0.0" : bindAddress
                logInfo("serveur HTTP à l'écoute sur \(bind):\(port)")
            case .failed(let error):
                logError("listener en échec: \(error)")
                listener?.cancel()
                listener = nil
                scheduleRestart()
            case .cancelled:
                if !stopped {
                    logWarn("listener annulé")
                    listener = nil
                    scheduleRestart()
                }
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener = newListener
        newListener.start(queue: queue)
    }

    /// Idempotent : `.failed` puis `.cancelled` arrivent souvent en paire, une
    /// seule reprise doit être planifiée.
    private func scheduleRestart() {
        guard !stopped, !restartScheduled else { return }
        restartScheduled = true
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        logInfo("nouvelle tentative d'écoute dans \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !stopped else { return }
            createListener()
        }
    }

    // MARK: - Connexions

    private func accept(_ connection: NWConnection) {
        let peer = Self.describe(endpoint: connection.currentPath?.remoteEndpoint ?? connection.endpoint)
        var buffer = Data()
        var finished = false

        var method = "GET"
        let complete: (HTTPResponse?) -> Void = { [weak self] response in
            guard !finished else { return }
            finished = true
            if let response, let self {
                // HEAD : mêmes en‑têtes (Content-Length inclus), sans corps.
                send(response, on: connection, includeBody: method != "HEAD")
            } else {
                connection.cancel()
            }
        }

        queue.asyncAfter(deadline: .now() + requestTimeout) {
            guard !finished else { return }
            logDebug("connexion \(peer) sans requête complète → fermeture")
            complete(nil)
        }

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { buffer.append(data) }

                if buffer.count > maxRequestBytes {
                    complete(.text("request too large", status: 413))
                    return
                }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8)) {
                    let head = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    guard var request = Self.parse(head: head) else {
                        complete(.text("bad request", status: 400))
                        return
                    }
                    request.peer = peer
                    method = request.method
                    logDebug("HTTP \(request.method) \(request.path) depuis \(peer)")
                    complete(handler(request))
                    return
                }
                if error != nil || isComplete {
                    complete(buffer.isEmpty ? nil : .text("bad request", status: 400))
                    return
                }
                receiveMore()
            }
        }

        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                logDebug("connexion \(peer) en échec: \(error)")
                complete(nil)
            }
        }
        connection.start(queue: queue)
        receiveMore()
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, includeBody: Bool = true) {
        var head = "HTTP/1.1 \(response.status) \(response.reasonPhrase)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if includeBody { payload.append(response.body) }

        connection.send(content: payload, isComplete: true, completion: .contentProcessed { error in
            if let error { logDebug("envoi de la réponse échoué: \(error)") }
            connection.cancel()
        })
    }

    // MARK: - Analyse

    private static func parse(head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" })
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var request = HTTPRequest()
        request.method = String(parts[0]).uppercased()

        let target = String(parts[1])
        if let questionMark = target.firstIndex(of: "?") {
            request.path = String(target[target.startIndex..<questionMark])
            let queryString = String(target[target.index(after: questionMark)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                request.query[String(key).removingPercentEncoding ?? String(key)] =
                    value.removingPercentEncoding ?? value
            }
        } else {
            request.path = target
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            request.headers[name] = value
        }
        return request
    }

    private static func describe(endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let address): return "\(address)"
            case .ipv6(let address): return "\(address)"
            case .name(let name, _): return name
            @unknown default: return "\(host)"
            }
        }
        return "\(endpoint)"
    }
}
