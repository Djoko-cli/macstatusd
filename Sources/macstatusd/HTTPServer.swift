import Foundation
import Network
import MacStatusCore

/// Adaptateur réseau (`NWListener`) du serveur HTTP : il lit les octets, délègue
/// l'analyse à `RequestParser` et le routage à `Router`, puis écrit la réponse.
///
/// - **Plafond de connexions** (`ConnectionLimiter`, 32 au total, 8 par pair) appliqué à
///   l'acceptation, avant toute lecture : une connexion refusée est fermée aussitôt, sans
///   réponse ; les refus sont journalisés une fois, puis au plus une fois par minute.
/// - **Délai d'en-têtes** de 2 s compté depuis l'acceptation : à l'échéance, `cancel()`.
///   Durée de vie totale bornée à 10 s (envoi bloqué par un client qui ne lit pas).
/// - En-tête borné à 16 Kio (413), une réponse par connexion.
/// - **Reprise automatique** du listener : `.failed` ou `.cancelled` inattendu → nouvelle
///   écoute avec un délai croissant (1 s, doublé jusqu'à 30 s) ; `.waiting` → une ligne par
///   épisode, puis `cancel()` et nouvelle écoute au bout de 5 s si l'état n'a pas changé.
///
/// - **Détention du port** : l'adaptateur annonce à `onListenerReadyChange` (sur sa file) si le
///   listener est prêt (`.ready` → vrai ; `.waiting`, `.failed`, `.cancelled`, création impossible,
///   arrêt → faux). Le moteur ne publie rien tant que le port n'est pas détenu (tâche 16).
///
/// Tout s'exécute sur une seule file série (`queue`) : listener, connexions, minuteries et
/// routage. La lecture est asynchrone (`NWConnection.receive` rend la main aussitôt et rappelle
/// sur la file quand des octets arrivent) : un client lent n'occupe jamais la file pendant
/// qu'il envoie. Seul le routage s'y exécute d'un bloc, lecture du moteur comprise.
final class HTTPServer {
    private let queue = DispatchQueue(label: "macstatusd.http")
    private let port: UInt16
    private let listenAddress: ListenAddress
    private let router: Router
    private let maxRequestBytes = 16 * 1024
    /// Délai d'obtention des en-têtes, depuis l'acceptation.
    private let headerTimeout: TimeInterval = 2
    /// Durée de vie maximale d'une connexion, envoi de la réponse compris.
    private let connectionLifetime: TimeInterval = 10
    /// Durée d'un état `.waiting` avant d'abandonner le listener pour un neuf.
    private let waitingTimeout: TimeInterval = 5

    private let limiter = ConnectionLimiter(maxTotal: ConnectionLimiter.defaultMaxTotal,
                                            maxPerPeer: ConnectionLimiter.defaultMaxPerPeer)
    private let refusalLog = PeriodicLogGate(period: 60, clock: SystemClock())

    /// Appelé sur la file de l'adaptateur à chaque changement de détention du port (sans répétition).
    /// À brancher avant `start()`.
    var onListenerReadyChange: ((Bool) -> Void)?
    private var reportedReady: Bool?

    private var listener: NWListener?
    private var restartDelay: TimeInterval = 1
    private var restartScheduled = false
    private var stopped = false
    /// Épisode `.waiting` déjà journalisé : plus de ligne jusqu'au prochain `.ready`, même si
    /// le listener neuf retombe en attente.
    private var waitingLogged = false
    /// Le listener courant est en `.waiting` (un `.waiting` suivant ne relance pas le délai).
    private var listenerWaiting = false
    /// Numéro de la période d'attente du listener courant : la reprise à 5 s ne vaut que pour
    /// elle ; tout autre état en ouvre une nouvelle.
    private var waitingEpisode = 0

    init(port: UInt16, bindAddress: String, router: Router) {
        self.port = port
        // `Config` a déjà validé l'adresse ; par prudence, une valeur invalide donne le repli
        // fermé de `Config` (boucle locale seulement), jamais l'écoute sur toutes les interfaces.
        self.listenAddress = ListenAddress(bindAddress: bindAddress) ?? .ipv4("127.0.0.1")
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
            reportReady(false)
        }
    }

    /// Annonce la détention (ou la perte) du port, une seule fois par changement.
    private func reportReady(_ ready: Bool) {
        guard reportedReady != ready else { return }
        reportedReady = ready
        onListenerReadyChange?(ready)
    }

    private func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if listenAddress == .allIPv4,
           let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    private func createListener() {
        restartScheduled = false
        guard !stopped else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            logError("port \(port) invalide")
            reportReady(false)
            return
        }

        let parameters = makeParameters()
        let newListener: NWListener
        do {
            switch listenAddress {
            case .dualStack, .allIPv4:
                newListener = try NWListener(using: parameters, on: nwPort)
            case .ipv4(let address), .ipv6(let address):
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: nwPort)
                newListener = try NWListener(using: parameters)
            }
        } catch {
            logError("création du listener impossible: \(error)")
            reportReady(false)
            scheduleRestart()
            return
        }

        // Le gestionnaire ne touche `listener` que s'il s'agit encore de cette instance : un
        // ancien listener annulé ne doit ni effacer ni relancer son successeur.
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, listener === newListener else { return }
            if case .waiting = state {} else {
                // Sortie de l'attente (ou jamais entrée) : la reprise planifiée devient caduque.
                listenerWaiting = false
                waitingEpisode += 1
            }
            switch state {
            case .ready:
                restartDelay = 1
                waitingLogged = false
                let actual = newListener.port?.rawValue ?? port
                logInfo("serveur HTTP à l'écoute sur \(listenAddress.description(port: actual))")
                reportReady(true)
            case .waiting(let error):
                // Le port n'est pas (ou plus) détenu : le moteur cesse de publier.
                reportReady(false)
                // Déjà en attente : l'état ne change pas, le délai de 5 s court toujours.
                guard !listenerWaiting else {
                    logDebug("listener toujours en attente: \(error)")
                    return
                }
                listenerWaiting = true
                waitingEpisode += 1
                let episode = waitingEpisode
                if !waitingLogged {
                    waitingLogged = true
                    logWarn("listener en attente: \(error) → nouvelle écoute dans \(Int(waitingTimeout)) s "
                            + "si l'état ne change pas")
                } else {
                    logDebug("listener de nouveau en attente: \(error)")
                }
                queue.asyncAfter(deadline: .now() + waitingTimeout) { [weak self, weak newListener] in
                    guard let self, let newListener, !stopped,
                          listener === newListener, listenerWaiting, waitingEpisode == episode else { return }
                    logDebug("listener en attente depuis \(Int(waitingTimeout)) s → nouvelle écoute")
                    listener = nil
                    listenerWaiting = false
                    newListener.cancel()
                    createListener()
                }
            case .failed(let error):
                logError("listener en échec: \(error)")
                reportReady(false)
                listener = nil
                newListener.cancel()
                scheduleRestart()
            case .cancelled:
                reportReady(false)
                listener = nil
                if !stopped {
                    logWarn("listener annulé")
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
        listenerWaiting = false
        waitingEpisode += 1
        newListener.start(queue: queue)
    }

    /// Idempotent : une seule reprise planifiée à la fois.
    private func scheduleRestart() {
        guard !stopped, !restartScheduled else { return }
        restartScheduled = true
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        logInfo("nouvelle tentative d'écoute dans \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Jamais deux listeners : rien à faire si un autre a pris la place entre-temps.
            guard let self else { return }
            restartScheduled = false
            guard !stopped, listener == nil else { return }
            createListener()
        }
    }

    // MARK: - Connexions

    private func accept(_ connection: NWConnection) {
        let remote = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        let peer = Self.describe(endpoint: remote)

        // Plafond appliqué avant toute lecture : la connexion refusée n'est jamais démarrée.
        guard limiter.acquire(peer: peer) else {
            connection.cancel()
            if let count = refusalLog.note() {
                logWarn("HTTP connexion refusée depuis \(escapeForLog(peer)) : plafond atteint "
                        + "(\(ConnectionLimiter.defaultMaxTotal) au total, \(ConnectionLimiter.defaultMaxPerPeer) par pair), "
                        + "\(count) refus depuis la dernière ligne")
            }
            return
        }

        let peerIsLoopback = Self.isLoopback(endpoint: remote)
        var buffer = Data()
        var finished = false
        // Tout ce qui suit s'exécute sur `queue` (connexion démarrée sur elle, minuteries
        // sur elle) : ce drapeau n'est lu et écrit que depuis cette file série.
        var released = false

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

        // Délai d'en-têtes, compté depuis l'acceptation.
        queue.asyncAfter(deadline: .now() + headerTimeout) {
            guard !finished else { return }
            logDebug("connexion \(peer) sans en-têtes complets en \(Int(self.headerTimeout)) s → fermeture")
            complete(nil)
        }
        // Filet : une connexion ne vit jamais plus de `connectionLifetime`, envoi compris.
        queue.asyncAfter(deadline: .now() + connectionLifetime) { [weak connection] in
            guard let connection, !released else { return }
            logDebug("connexion \(peer) encore ouverte après \(Int(self.connectionLifetime)) s → fermeture")
            finished = true
            connection.cancel()
        }

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self, !finished else { return }
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
                    if case .success(let request) = parsed { method = request.method }
                    // Requête de la cible masquée (`?…`) : jamais de jeton au journal.
                    logReceivedRequest(parsed, head: head, peer: peer)
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

        // La place est rendue une seule fois, à l'état final de la connexion. Toute issue
        // finit par `cancel()` (réponse envoyée, délai, erreur, filet), qui livre `.cancelled` ;
        // `.failed` peut le précéder : le drapeau empêche la seconde libération.
        connection.stateUpdateHandler = { [limiter] state in
            switch state {
            case .failed(let error):
                logDebug("connexion \(peer) en échec: \(error)")
                complete(nil)
                connection.cancel()
                if !released { released = true; limiter.release(peer: peer) }
            case .cancelled:
                finished = true
                if !released { released = true; limiter.release(peer: peer) }
            default:
                break
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
