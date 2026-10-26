import Foundation
import Network
import MacStatusCore
import MacStatusNet

/// Surveille le chemin réseau (`NWPathMonitor`) et prévient quand il redevient utilisable, pour
/// que le client webhook renvoie tout de suite l'état aux cibles non confirmées.
///
/// `onAvailable` part (sur la file du moniteur) seulement pour un **vrai changement** vers
/// `.satisfied` : retour depuis un chemin non satisfait, ou chemin satisfait dont les interfaces
/// **pertinentes** ont changé (passage du Wi-Fi à l'Ethernet). Seuls le Wi-Fi, l'Ethernet filaire
/// et le cellulaire comptent : un tunnel (VPN), le bouclage ou une interface « autre » qui va et
/// vient ne relance rien. Le premier relevé sert de référence et ne prévient pas ; les relevés
/// `.satisfied` répétés à l'identique ne préviennent pas non plus (pas de rafale).
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "macstatusd.network")
    /// Signature du dernier chemin vu (statut et interfaces), sur `queue`.
    private var lastSignature: String?
    private var lastSatisfied = false

    var onAvailable: (() -> Void)?

    /// Pas de `stop()` : la surveillance dure jusqu'à la sortie du processus (l'avis reçu pendant
    /// l'arrêt est ignoré par l'exécuteur et le moteur).
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in self?.handle(path) }
        monitor.start(queue: queue)
    }

    private func handle(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        let signature = NetworkPathSignature.make(
            status: path.status, interfaces: path.availableInterfaces.map { ($0.name, $0.type) })
        defer {
            lastSignature = signature
            lastSatisfied = satisfied
        }
        guard let previous = lastSignature else {
            logDebug("réseau : chemin initial \(satisfied ? "utilisable" : "non utilisable")")
            return
        }
        guard signature != previous else { return }
        guard satisfied else {
            logInfo("réseau : chemin non utilisable (\(path.status))")
            return
        }
        if lastSatisfied {
            logDebug("réseau : interfaces changées, chemin utilisable")
        } else {
            logInfo("réseau : chemin de nouveau utilisable")
        }
        onAvailable?()
    }
}

/// Sonde du chemin vers une cible du webhook : une connexion TCP `NWConnection` vers l'hôte et le
/// port de la cible (jamais une autre adresse), le temps de lire `unsatisfiedReason`. Fermée dès
/// la réponse, ou au bout de 5 s. Le résultat est rappelé sur la file du moteur.
final class NWLocalNetworkProbe: LocalNetworkProbe {
    private let engineQueue: DispatchQueue
    private let queue = DispatchQueue(label: "macstatusd.network.probe")

    init(engineQueue: DispatchQueue) {
        self.engineQueue = engineQueue
    }

    func checkLocalNetworkDenied(host: String, port: Int, _ completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0, port <= 65_535 else {
            engineQueue.async { completion(false) }
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var finished = false
        let engineQueue = self.engineQueue
        // Tout se passe sur `queue` : rappels d'état, échéance et fin.
        func finish(_ denied: Bool) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            engineQueue.async { completion(denied) }
        }
        func denied() -> Bool {
            connection.currentPath?.unsatisfiedReason == .localNetworkDenied
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(false)
            case .waiting, .failed:
                finish(denied())
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(denied()) }
    }
}
