import Foundation
import Network
import MacStatusCore

/// Adaptateur réseau (`NWListener`) du serveur HTTP : il lit les octets, délègue
/// l'analyse à `RequestParser` et le routage à `Router`, puis écrit la réponse.
/// Requêtes bornées en taille et en durée, une réponse par connexion, et surtout
/// **redémarrage automatique** du listener en cas d'échec (port occupé,
/// réinitialisation réseau) au lieu d'un crash.
final class HTTPServer {
    private let queue = DispatchQueue(label: "macstatusd.http")
    private let port: UInt16
    private let bindAddress: String
    private let router: Router
    private let maxRequestBytes = 16 * 1024
    private let requestTimeout: TimeInterval = 5

    private var listener: NWListener?
    private var restartDelay: TimeInterval = 1
    private var restartScheduled = false
    private var stopped = false

    init(port: UInt16, bindAddress: String, router: Router) {
        self.port = port
        self.bindAddress = bindAddress
        self.router = router
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
        let remote = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        let peer = Self.describe(endpoint: remote)
        let peerIsLoopback = Self.isLoopback(endpoint: remote)
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
                    let parsed = RequestParser.parse(head: head).map { request -> HTTPRequest in
                        var request = request
                        request.peer = peer
                        request.peerIsLoopback = peerIsLoopback
                        return request
                    }
                    switch parsed {
                    case .success(let request):
                        method = request.method
                        logDebug("HTTP \(escapeForLog(request.method, limit: 16)) \(escapeForLog(request.path)) depuis \(peer)")
                    case .failure(let error):
                        // Ligne de requête reçue, échappée : jamais de caractère de contrôle au journal.
                        var firstLine = head.prefix { $0 != 0x0A }
                        if firstLine.last == 0x0D { firstLine = firstLine.dropLast() }
                        logDebug("HTTP refusée (\(error)) « \(escapeForLog(String(decoding: firstLine, as: UTF8.self))) » "
                            + "depuis \(peer)")
                    }
                    complete(router.handle(parsed))
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
        // En-têtes construits par `HTTPResponse`, qui écarte tout en-tête contenant CR ou LF.
        let head = response.serializedHead()

        var payload = Data(head.utf8)
        if includeBody { payload.append(response.body) }

        connection.send(content: payload, isComplete: true, completion: .contentProcessed { error in
            if let error { logDebug("envoi de la réponse échoué: \(error)") }
            connection.cancel()
        })
    }

    // MARK: - Pair

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

    /// Vrai si le pair est en boucle locale, d'après les octets de l'adresse du `NWEndpoint`
    /// (décision dans `isLoopbackAddress` : 127.0.0.0/8, `::1`, `::ffff:127.x.y.z`), jamais
    /// d'après une chaîne. Un nom d'hôte ou un autre type de point d'accès (`.service`…)
    /// n'est pas une boucle locale.
    static func isLoopback(endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isLoopbackAddress([UInt8](address.rawValue))
        case .ipv6(let address):
            return isLoopbackAddress([UInt8](address.rawValue))
        case .name:
            return false
        @unknown default:
            return false
        }
    }
}
