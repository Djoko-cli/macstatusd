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

/// Destination de l'état publié (webhooks : Homebridge, Home Assistant).
public protocol StatePublisher: AnyObject {
    /// Demande la publication d'un état. `force` réémet même si l'état est déjà
    /// confirmé (battement de cœur, resynchronisation).
    func publish(_ state: Bool, force: Bool)
    /// Arrêt du daemon : publie `state` en force et tout de suite, vers chaque destination. Une
    /// requête en vol pour un autre état est annulée au lieu d'être attendue (R40).
    func publishBeforeExit(_ state: Bool)
    /// Prévient `done` quand l'état voulu est confirmé par toutes les destinations (`true`), quand
    /// chacune a confirmé ou abandonné, ou quand `timeout` secondes se sont écoulées (`false`).
    /// Déjà confirmé partout : `done(true)` tout de suite. Aucune destination utilisable (webhook
    /// désactivé, mode dégradé, URL invalide) : `done(false)` tout de suite. `done` est appelé
    /// exactement une fois, sur la file du moteur ; l'attente ne bloque jamais cette file, et elle
    /// est retirée à l'échéance.
    func notifyWhenDelivered(timeout: Double, _ done: @escaping (Bool) -> Void)
    /// Diagnostic exposé dans /status, sous la clé `webhook`.
    var statusDictionary: [String: Any] { get }
}

/// Rappel à usage unique : seul le premier `run()` exécute le travail, les suivants sont sans
/// effet. Sert à l'autorisation de veille (`IOAllowPowerChange`), que le garde-fou du veilleur
/// et la confirmation de livraison peuvent tous deux demander. Protégé par un verrou : il
/// reste sûr même appelé depuis deux files.
public final class OnceCallback {
    private let lock = NSLock()
    private var work: (() -> Void)?

    public init(_ work: @escaping () -> Void) {
        self.work = work
    }

    /// Exécute le travail s'il n'a pas encore été exécuté. Vrai si cet appel l'a exécuté.
    @discardableResult
    public func run() -> Bool {
        lock.lock()
        let pending = work
        work = nil
        lock.unlock()
        guard let pending else { return false }
        pending()
        return true
    }

    /// Vrai une fois le travail exécuté.
    public var hasRun: Bool {
        lock.lock(); defer { lock.unlock() }
        return work == nil
    }
}

/// Événements système qui accélèrent la réévaluation des faits. Aucun état n'en
/// dépend exclusivement : le moteur relit les faits à chaque cycle de scrutation.
/// La valeur brute sert au journal.
public enum SystemEvent: String {
    case systemDidWake = "system-did-wake"
    /// Veille annulée (`kIOMessageSystemWillNotSleep`) : ce n'est pas un réveil.
    case systemWillNotSleep = "system-will-not-sleep"
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
