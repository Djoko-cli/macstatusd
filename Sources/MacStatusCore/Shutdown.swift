import Foundation

/// Marqueur de redémarrage prévu : un fichier `restart-pending` dans le dossier de support.
///
/// C'est le script d'installation ou de redémarrage qui le pose, juste avant d'arrêter le daemon.
/// Au SIGTERM suivant, il est consommé (supprimé) et OFF n'est pas publié : le Mac ne s'éteint pas,
/// le daemon revient aussitôt, et un OFF suivi d'un ON ferait clignoter HomeKit pour rien.
/// Un marqueur plus vieux que `maxAge` est oublié : sans cela, un marqueur resté en place ferait
/// taire tous les arrêts suivants.
public enum RestartMarker {
    public static let fileName = "restart-pending"
    /// Âge au-delà duquel un marqueur est périmé : 10 minutes.
    public static let maxAge: TimeInterval = 600
    /// Variable d'environnement qui remplace le dossier de support (tests, essais hors installation).
    public static let supportDirectoryVariable = "MACSTATUSD_SUPPORT_DIR"

    public enum Outcome: Equatable {
        /// Aucun marqueur (ou autre chose qu'un fichier ordinaire : jamais touché).
        case absent
        /// Marqueur récent : redémarrage prévu. Il a été supprimé.
        case fresh
        /// Marqueur périmé : ignoré et supprimé.
        case stale(ageSeconds: Int)
    }

    /// Dossier de support : `MACSTATUSD_SUPPORT_DIR` s'il est défini et non vide, sinon
    /// `~/Library/Application Support/macstatusd`.
    public static func supportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        home: String = NSHomeDirectory()) -> String {
        if let override = environment[supportDirectoryVariable], !override.isEmpty { return override }
        return home + "/Library/Application Support/macstatusd"
    }

    /// Lit le marqueur de `directory` et le supprime s'il existe (récent ou périmé).
    /// L'âge est celui de la dernière modification du fichier.
    public static func consume(in directory: String, now: Date = Date()) -> Outcome {
        let path = directory + "/" + fileName
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .absent }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        let age = max(0, now.timeIntervalSince1970 - modified)
        if unlink(path) != 0, errno != ENOENT {
            logWarn("marqueur \(fileName) non supprimé (errno \(errno))")
        }
        if age > maxAge {
            logWarn("marqueur \(fileName) périmé (\(Int(age) / 60) min, au plus \(Int(maxAge) / 60) min) → ignoré et supprimé")
            return .stale(ageSeconds: Int(age))
        }
        return .fresh
    }
}

/// Ce que l'arrêt doit publier, et pourquoi (la raison entre au journal).
public struct ShutdownDecision: Equatable {
    public let publishOff: Bool
    public let reason: String
}

public enum ShutdownPolicy {
    /// - mode dégradé (config invalide) : rien, les webhooks sont coupés ;
    /// - marqueur de redémarrage récent : rien ;
    /// - sinon : `publish_off_on_exit`.
    public static func decide(degraded: Bool, publishOffOnExit: Bool, marker: RestartMarker.Outcome) -> ShutdownDecision {
        if degraded {
            return ShutdownDecision(publishOff: false, reason: "mode dégradé, webhooks coupés")
        }
        if marker == .fresh {
            return ShutdownDecision(publishOff: false, reason: "redémarrage prévu (marqueur \(RestartMarker.fileName))")
        }
        if !publishOffOnExit {
            return ShutdownDecision(publishOff: false, reason: "publish_off_on_exit désactivé")
        }
        return ShutdownDecision(publishOff: true, reason: "arrêt sans redémarrage prévu")
    }
}

/// Garantit que l'arrêt se termine : une séquence, un filet, un second signal.
///
/// - `begin` lance la séquence d'arrêt ; elle rend la main en appelant `finished`, ce qui termine
///   le processus (`terminate`), une seule fois ;
/// - si `finished` n'est pas appelé dans `forcedExitDelay` (3 s, sous l'`ExitTimeOut` de 5 s de
///   launchd), le filet termine le processus quand même, avec une ligne de journal ;
/// - un second signal pendant l'arrêt termine tout de suite.
///
/// Le filet doit tourner sur un planificateur qui ne dépend pas de la file du moteur : il sert
/// justement quand cette file ne répond plus. Les appels peuvent venir de files différentes.
public final class ShutdownGuard {
    /// Délai du filet, en secondes : plus court que l'`ExitTimeOut` du plist.
    public static let forcedExitDelay: Double = 3

    private let scheduler: Scheduler
    private let forcedExitDelay: Double
    private let terminate: () -> Void
    private let lock = NSLock()
    private var started = false
    private var terminated = false
    private var net: Cancellable?

    public init(scheduler: Scheduler, forcedExitDelay: Double = ShutdownGuard.forcedExitDelay,
                terminate: @escaping () -> Void) {
        self.scheduler = scheduler
        self.forcedExitDelay = forcedExitDelay
        self.terminate = terminate
    }

    public func begin(_ sequence: (_ finished: @escaping () -> Void) -> Void) {
        lock.lock()
        if started {
            lock.unlock()
            logWarn("second signal pendant l'arrêt → sortie immédiate")
            finish()
            return
        }
        started = true
        lock.unlock()

        let task = scheduler.schedule(after: forcedExitDelay) { [self] in
            logWarn("arrêt non terminé après \(String(format: "%.0f", forcedExitDelay)) s → sortie forcée")
            finish()
        }
        lock.lock()
        net = task
        lock.unlock()

        sequence { [self] in finish() }
    }

    /// Termine le processus, une seule fois, et retire le filet.
    private func finish() {
        lock.lock()
        let first = !terminated
        terminated = true
        let task = net
        net = nil
        lock.unlock()
        task?.cancel()
        if first { terminate() }
    }
}
