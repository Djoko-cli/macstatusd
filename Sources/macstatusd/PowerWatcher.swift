import Foundation
import AppKit
import IOKit
import MacStatusCore

// iokit_common_msg(x) == 0xE0000000 | x — les macros IOMessage.h ne sont pas
// exposées à Swift, on les redéclare. Valeurs vérifiées le 26/10/2026 par un témoin C
// compilé contre le SDK (printf des macros kIOMessage*) : 0xE0000270, 0xE0000280,
// 0xE0000290, 0xE0000300, 0xE0000320.
private let messageCanSystemSleep: UInt32 = 0xE000_0270
private let messageSystemWillSleep: UInt32 = 0xE000_0280
private let messageSystemWillNotSleep: UInt32 = 0xE000_0290
private let messageSystemHasPoweredOn: UInt32 = 0xE000_0300
private let messageSystemWillPowerOn: UInt32 = 0xE000_0320

private func powerNotificationCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<PowerWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(messageType: messageType, argument: messageArgument)
}

/// Surveillance événementielle de l'alimentation et de la session.
///
/// IOKit (`IORegisterForSystemPower`) est la source de vérité pour la veille
/// système : contrairement à `NSWorkspace`, il fonctionne hors session graphique
/// et permet de **retenir** la veille le temps de pousser l'état OFF vers
/// Homebridge — sinon HomeKit resterait sur ON pendant toute la veille.
///
/// Les notifications AppKit / distribuées servent d'accélérateurs : elles
/// déclenchent une réévaluation immédiate, mais aucun état n'en dépend
/// exclusivement (le moteur repolle les faits en continu).
final class PowerWatcher {
    /// Appelé juste avant la veille. Le daemon doit invoquer `allow()` dès que
    /// l'état OFF est poussé ; un garde‑fou l'appelle de toute façon.
    var onWillSleep: ((_ allow: @escaping () -> Void) -> Void)?
    var onEvent: ((SystemEvent) -> Void)?

    /// Délai du garde‑fou : la veille n'est jamais retenue plus longtemps.
    private static let sleepGuardDelay: Double = 2.0
    /// Un `NSWorkspace.didWake` reçu moins de 5 s après un réveil IOKit est un doublon.
    private static let workspaceWakeDedupWindow: Double = 5.0

    private let queue: DispatchQueue
    private let clock = SystemClock()
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// Instant monotone du dernier réveil IOKit (`HasPoweredOn`) transmis au moteur.
    private var lastIOKitWakeAt: Double?
    private var observers: [NSObjectProtocol] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        startIOKit()
        startNotifications()
    }

    // MARK: - IOKit

    private func startIOKit() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, powerNotificationCallback, &notifier)
        guard rootPort != 0, let notifyPort else {
            logWarn("IORegisterForSystemPower indisponible : repli sur les notifications NSWorkspace")
            return
        }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        logInfo("surveillance IOKit de l'alimentation active")
    }

    /// Rappelé par IOKit sur `queue` (`IONotificationPortSetDispatchQueue`).
    fileprivate func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let notificationID = Int(bitPattern: argument)

        switch messageType {
        case messageCanSystemSleep:
            // Jamais de veto : on laisse le système décider.
            IOAllowPowerChange(rootPort, notificationID)

        case messageSystemWillSleep:
            logInfo("IOKit: veille imminente")
            // Une seule autorisation par veille, que la demande vienne du moteur (livraison
            // confirmée ou délai de 1,5 s) ou du garde‑fou : la seconde est sans effet.
            let acknowledgement = OnceCallback { [weak self] in
                guard let self else { return }
                IOAllowPowerChange(rootPort, notificationID)
            }
            guard let onWillSleep else {
                acknowledgement.run()
                return
            }
            let allow: () -> Void = { [weak self] in
                // Au prochain tour de file, jamais depuis l'intérieur du rappel IOKit.
                self?.queue.async { acknowledgement.run() }
            }
            onWillSleep(allow)
            // Garde‑fou : ne jamais retenir la veille plus de 2 s.
            queue.asyncAfter(deadline: .now() + Self.sleepGuardDelay) {
                if acknowledgement.run() {
                    logWarn("IOKit: garde‑fou de \(Self.sleepGuardDelay) s → veille autorisée sans réponse du moteur")
                }
            }

        case messageSystemWillPowerOn:
            // Le réveil n'est pas encore fait (les pilotes se rallument) : seul
            // HasPoweredOn le confirme.
            logDebug("IOKit: réveil en cours (WillPowerOn)")

        case messageSystemHasPoweredOn:
            logInfo("IOKit: réveil système")
            lastIOKitWakeAt = clock.monotonic()
            onEvent?(.systemDidWake)

        case messageSystemWillNotSleep:
            logInfo("IOKit: veille annulée")
            onEvent?(.systemWillNotSleep)

        default:
            break
        }
    }

    // MARK: - Notifications AppKit / distribuées

    private func startNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.workspaceDidWake() }
        })
        observe(workspace, NSWorkspace.screensDidSleepNotification, .screensDidSleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .screensDidWake)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive)

        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let identity = ((app?.bundleIdentifier ?? "") + " " + (app?.localizedName ?? "")).lowercased()
                guard identity.contains("screensaver") else { return }
                self?.emit(.saverProcessChanged)
            }
            observers.append(token)
        }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, NSNotification.Name("com.apple.screensaver.didstart"), .screenSaverDidStart)
        observe(distributed, NSNotification.Name("com.apple.screensaver.didstop"), .screenSaverDidStop)
        observe(distributed, NSNotification.Name("com.apple.screenIsLocked"), .screenLocked)
        observe(distributed, NSNotification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)
    }

    /// `NSWorkspace.didWake` double le réveil IOKit ; il ne sert que si IOKit s'est tu.
    private func workspaceDidWake() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let last = lastIOKitWakeAt {
            let elapsed = clock.monotonic() - last
            if elapsed < Self.workspaceWakeDedupWindow {
                logDebug("NSWorkspace: réveil ignoré, réveil IOKit traité il y a "
                         + "\(String(format: "%.1f", elapsed)) s")
                return
            }
        }
        logDebug("événement système: \(SystemEvent.systemDidWake.rawValue) (NSWorkspace)")
        onEvent?(.systemDidWake)
    }

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name, _ event: SystemEvent) {
        observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.emit(event)
        })
    }

    private func emit(_ event: SystemEvent) {
        queue.async { [weak self] in
            logDebug("événement système: \(event.rawValue)")
            self?.onEvent?(event)
        }
    }
}
