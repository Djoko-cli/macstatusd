import Foundation
import AppKit
import IOKit

// iokit_common_msg(x) == 0xE0000000 | x — les macros IOMessage.h ne sont pas
// exposées à Swift, on les redéclare.
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
    enum Event: String {
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

    /// Appelé juste avant la veille. Le daemon doit invoquer `allow()` dès que
    /// l'état OFF est poussé ; un garde‑fou l'appelle de toute façon.
    var onWillSleep: ((_ allow: @escaping () -> Void) -> Void)?
    var onEvent: ((Event) -> Void)?

    private let queue: DispatchQueue
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pendingSleepAcknowledged = Set<Int>()
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

    fileprivate func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)

        switch messageType {
        case messageCanSystemSleep:
            // Jamais de veto : on laisse le système décider.
            IOAllowPowerChange(rootPort, notificationID)

        case messageSystemWillSleep:
            logInfo("IOKit: veille imminente")
            guard let onWillSleep else {
                IOAllowPowerChange(rootPort, notificationID)
                return
            }
            pendingSleepAcknowledged.remove(notificationID)
            let allow: () -> Void = { [weak self] in
                self?.queue.async { self?.acknowledgeSleep(notificationID) }
            }
            onWillSleep(allow)
            // Garde‑fou : ne jamais retenir la veille plus de 2 s.
            queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.acknowledgeSleep(notificationID)
            }

        case messageSystemWillPowerOn, messageSystemHasPoweredOn:
            logInfo("IOKit: réveil système")
            onEvent?(.systemDidWake)

        case messageSystemWillNotSleep:
            logInfo("IOKit: veille annulée")
            onEvent?(.systemDidWake)

        default:
            break
        }
    }

    private func acknowledgeSleep(_ notificationID: Int) {
        guard !pendingSleepAcknowledged.contains(notificationID) else { return }
        pendingSleepAcknowledged.insert(notificationID)
        if pendingSleepAcknowledged.count > 32 { pendingSleepAcknowledged.removeAll() }
        IOAllowPowerChange(rootPort, notificationID)
    }

    // MARK: - Notifications AppKit / distribuées

    private func startNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification, .systemDidWake)
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

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name, _ event: Event) {
        observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.emit(event)
        })
    }

    private func emit(_ event: Event) {
        queue.async { [weak self] in
            logDebug("événement système: \(event.rawValue)")
            self?.onEvent?(event)
        }
    }
}
