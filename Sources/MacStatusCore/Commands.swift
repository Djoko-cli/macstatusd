import Foundation

/// Primitives d'extinction et de réveil que le moteur d'état commande.
///
/// Chaque primitive rapporte seulement son *lancement* : la confirmation vient
/// des faits observés par le moteur, jamais de la commande elle-même (seule exception :
/// l'écartement natif de l'économiseur, que le moteur annonce à l'oracle). L'implémentation
/// réelle (`PowerActions`) vit dans l'exécutable.
public protocol CommandActions: AnyObject {
    /// Une commande OFF personnalisée (`off_command`) remplace l'action configurée.
    var hasOffOverride: Bool { get }
    /// Une commande de réveil personnalisée (`wake_command`) remplace l'assertion : `wake()` ne pose
    /// alors rien, `releaseWake()` et `holdDisplay(seconds:)` sont sans effet.
    var hasWakeOverride: Bool { get }
    func runOff(_ action: OffAction)
    func displaySleep()
    func wake()
    /// Relâche ce que `wake()` a posé : l'assertion « utilisateur actif » et, s'il tourne encore, le
    /// `caffeinate` lancé. Appelé dès que le ON est confirmé par les faits (ou abandonné), et à l'arrêt.
    /// Sans effet quand rien n'est posé, et avec une surcharge `wake_command` (aucune assertion alors).
    /// Ne bloque jamais : l'appelant est la file du moteur.
    func releaseWake()
    /// Retient l'écran allumé `seconds` secondes (assertion « pas de veille d'écran par inactivité »,
    /// avec son propre délai). Une nouvelle retenue remplace l'ancienne : jamais deux à la fois.
    /// `seconds <= 0` relâche la retenue en cours. Ne bloque jamais.
    func holdDisplay(seconds: Double)
    /// Moyen par lequel `dismissScreenSaver()` écarte l'économiseur. Connu dès la création des actions (la
    /// fonction du système est résolue une fois pour toutes) : le moteur le journalise au démarrage et le
    /// publie dans `/status` (`saver_dismissal`).
    var screenSaverDismissal: ScreenSaverDismissal { get }
    /// Écarte l'économiseur d'écran par `screenSaverDismissal`, comme le ferait une frappe. Rapporte
    /// seulement le lancement : la confirmation vient des faits, sauf pour le moyen natif, que le moteur annonce à
    /// l'oracle (`noteDismissed`) : l'ordre y compte lui-même comme preuve (`écarté-par-commande`). Ne bloque
    /// jamais : l'appelant est la file du moteur.
    func dismissScreenSaver()
}

/// Moyen d'écarter l'économiseur lors d'un ON. La valeur brute sert au journal et à `/status`.
public enum ScreenSaverDismissal: String {
    /// `SACScreenSaverStopNow` (login.framework, sans argument) : fait apparaître le panneau de connexion
    /// par-dessus l'économiseur, comme une frappe. L'économiseur d'inactivité tourne encore dessous, et macOS
    /// y revient quelques secondes plus tard (30 s mesurées).
    case native = "SACScreenSaverStopNow"
    /// Repli quand la fonction manque : `killall ScreenSaverEngine`. Au banc 1, sans effet visible sous
    /// macOS 27 sur l'économiseur d'inactivité : le moteur n'en suppose aucun et attend les faits.
    case processKill = "killall ScreenSaverEngine"
}

/// Résumé d'une commande de surcharge (`off_command`, `wake_command`) pour le journal : l'exécutable,
/// échappé, et le nombre d'arguments. Jamais les arguments eux-mêmes : ils peuvent porter un jeton,
/// une adresse ou un nom.
public func commandSummaryForLog(_ argv: [String]) -> String {
    guard let executable = argv.first else { return "(commande vide)" }
    let count = argv.count - 1
    return "\(escapeForLog(executable)) + \(count) argument\(count > 1 ? "s" : "")"
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
    /// Le chemin réseau est redevenu utilisable : renvoi immédiat aux destinations non confirmées.
    func networkBecameAvailable()
}

public extension StatePublisher {
    func setSendingSuspended(_ suspended: Bool) {}
    func networkBecameAvailable() {}
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
