import Foundation
import Network

/// Signature d'un chemin réseau : son statut et ses interfaces pertinentes (Wi-Fi, Ethernet filaire,
/// cellulaire), triées. Deux chemins de même signature ne se distinguent pour aucun envoi.
public enum NetworkPathSignature {
    public static let relevantTypes: Set<NWInterface.InterfaceType> = [.wifi, .wiredEthernet, .cellular]

    public static func make(status: NWPath.Status, interfaces: [(name: String, type: NWInterface.InterfaceType)]) -> String {
        let relevant = interfaces.filter { relevantTypes.contains($0.type) }
            .map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",")
        return "\(status) \(relevant)"
    }
}
