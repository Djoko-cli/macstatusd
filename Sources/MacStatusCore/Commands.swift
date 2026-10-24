import Foundation

/// Primitives d'extinction et de réveil que le moteur d'état commande.
///
/// Chaque primitive rapporte seulement son *lancement* : la confirmation vient
/// toujours des faits observés par le moteur, jamais de la commande elle-même.
/// L'implémentation réelle (`PowerActions`) vit dans l'exécutable.
public protocol CommandActions: AnyObject {
    /// Une commande OFF personnalisée (`off_command`) remplace l'action configurée.
    var hasOffOverride: Bool { get }
    func runOff(_ action: OffAction)
    func displaySleep()
    func wake()
    func stopScreenSaver()
}

/// Destination de l'état publié (webhook Homebridge aujourd'hui).
public protocol StatePublisher: AnyObject {
    /// Demande la publication d'un état. `force` réémet même si l'état est déjà
    /// confirmé (battement de cœur, resynchronisation).
    func publish(_ state: Bool, force: Bool)
    /// Diagnostic exposé dans /status, sous la clé `webhook`.
    var statusDictionary: [String: Any] { get }
}

/// Événements système qui accélèrent la réévaluation des faits. Aucun état n'en
/// dépend exclusivement : le moteur relit les faits à chaque cycle de scrutation.
/// La valeur brute sert au journal.
public enum SystemEvent: String {
    case systemDidWake = "system-did-wake"
    case screensDidSleep = "screens-did-sleep"
    case screensDidWake = "screens-did-wake"
    case screenSaverDidStart = "screensaver-did-start"
    case screenSaverDidStop = "screensaver-did-stop"
    case screenLocked = "screen-locked"
    case screenUnlocked = "screen-unlocked"
    case sessionActive = "session-active"
    case sessionInactive = "session-inactive"
    case saverProcessChanged = "saver-process-changed"
}
