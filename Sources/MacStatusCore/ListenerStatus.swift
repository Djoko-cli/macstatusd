import Foundation

/// Ce que le serveur HTTP annonce de son écoute au moteur. Seul `.ready` autorise la publication ;
/// les autres états la bloquent, chacun avec sa raison (journal et `/status`).
public enum ListenerStatus: Equatable {
    /// Le serveur détient son port.
    case ready
    /// Le listener attend (réseau pas encore prêt, adresse pas encore disponible…) : il se relance seul.
    case waiting
    /// Un autre processus détient le port (`EADDRINUSE`) : typiquement une seconde instance.
    case portBusy
    /// Le listener a échoué ou n'a pas pu être créé, pour une autre raison que l'occupation du port.
    case failed
    /// Le listener est arrêté (annulé, ou serveur arrêté).
    case stopped
    /// Le port configuré n'est pas un numéro de port utilisable.
    case invalidPort

    /// Raison affichée quand l'état bloque la publication.
    public var blockedReason: String {
        switch self {
        case .ready: return "prêt"
        case .waiting: return "écoute en attente"
        case .portBusy: return "port occupé"
        case .failed: return "écoute en échec"
        case .stopped: return "écoute arrêtée"
        case .invalidPort: return "port invalide"
        }
    }
}
