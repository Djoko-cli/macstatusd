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
    /// Arrêt du daemon : publie `state` en force vers chaque destination. Une requête en vol pour un
    /// autre état garde une courte grâce (500 ms) pour aboutir, `state` part alors après elle ; encore
    /// en vol à l'échéance, elle est annulée au lieu d'être attendue davantage (R40).
    func publishBeforeExit(_ state: Bool)
    /// Prévient `done` quand l'état voulu est confirmé par toutes les destinations (`true`), quand
    /// chacune a confirmé ou abandonné, ou quand `timeout` secondes se sont écoulées (`false`).
    /// Déjà confirmé partout : `done(true)` tout de suite. Aucune destination utilisable (webhook
    /// désactivé, mode dégradé, URL invalide) : `done(false)` tout de suite. `done` est appelé
    /// exactement une fois, sur la file du moteur ; l'attente ne bloque jamais cette file, et elle
    /// est retirée à l'échéance.
    func notifyWhenDelivered(timeout: Double, _ done: @escaping (Bool) -> Void)
    /// Vrai si au moins une destination peut recevoir un envoi. Faux : webhook désactivé, mode
    /// dégradé, aucune cible ou URL invalide ; rien n'est alors envoyé, et le journal ne doit pas
    /// parler d'un OFF « confirmé ».
    var hasUsableTarget: Bool { get }
    /// Cibles qui ont confirmé l'état voulu (`confirmed`) sur le nombre de cibles configurées
    /// (`total`, 0 si le webhook est désactivé). Sert au journal d'arrêt et de veille :
    /// « OFF confirmé par n/m cibles ».
    var deliveryCounts: (confirmed: Int, total: Int) { get }
    /// Diagnostic exposé dans /status, sous la clé `webhook`.
    var statusDictionary: [String: Any] { get }
    /// Suspend (`true`) ou rend (`false`) tout envoi vers les destinations : publications, réessais
    /// rapides et lents, relance au retour du réseau. Appelé par le moteur quand cette instance
    /// n'a plus le droit de publier (port non détenu, session hors console). Une requête déjà en
    /// vol n'est pas annulée, mais sa réponse ne relance plus rien. La levée ne renvoie rien d'elle-même :
    /// le moteur publie ensuite l'état courant en `force`.
    func setSendingSuspended(_ suspended: Bool)
}

public extension StatePublisher {
    func setSendingSuspended(_ suspended: Bool) {}
    var hasUsableTarget: Bool { true }
    var deliveryCounts: (confirmed: Int, total: Int) { (0, hasUsableTarget ? 1 : 0) }
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
