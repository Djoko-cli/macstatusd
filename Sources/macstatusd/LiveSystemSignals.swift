import Foundation
import IOKit
import CoreGraphics
import Carbon
import MacStatusCore

/// Lecture des signaux bruts du système.
///
/// Chaque signal a une source primaire déterministe et, quand c'est possible,
/// une source de repli indépendante :
///
/// - verrouillage : IORegistry (`IOConsoleLocked` / `IOConsoleUsers`) — disponible
///   même hors session graphique — puis `CGSessionCopyCurrentDictionary`.
/// - écran éteint : `CGDisplayIsAsleep` sur l'écran principal, avec repli sur
///   « tous les écrans en ligne endormis ».
/// - champ d'authentification : `IsSecureEventInputEnabled`.
final class LiveSystemSignals: SystemSignals {
    private let registryRoot: io_registry_entry_t

    init() {
        registryRoot = IORegistryGetRootEntry(kIOMainPortDefault)
        if registryRoot == 0 {
            logWarn("IORegistryGetRootEntry a échoué : repli sur CGSession pour le verrouillage")
        }
    }

    deinit {
        if registryRoot != 0 { IOObjectRelease(registryRoot) }
    }

    // MARK: - Verrouillage / session

    func session() -> SessionState {
        var state = SessionState()
        var evidence: [String] = []

        // 1. IORegistry : fonctionne aussi depuis un LaunchDaemon hors session.
        if registryRoot != 0 {
            if let value = registryProperty("IOConsoleLocked") as? NSNumber, value.boolValue {
                state.locked = true
                evidence.append("IOConsoleLocked")
            }
            if let sessions = registryProperty("IOConsoleUsers") as? [[String: Any]] {
                let console = sessions.first { ($0["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true }
                if let console {
                    state.onConsole = true
                    if (console["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue == true {
                        state.loggedIn = true
                    }
                    if (console["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
                        state.locked = true
                        evidence.append("IOConsoleUsers")
                    }
                }
            }
        }

        // 2. Session graphique courante : disponible quand on tourne dans Aqua.
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (dict["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue == true {
                state.loggedIn = true
            }
            if (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
                state.locked = true
                evidence.append("CGSession")
            }
        }

        if !evidence.isEmpty { state.evidence = evidence.joined(separator: "+") }
        else if state.locked { state.evidence = "unknown" }
        else { state.evidence = "unlocked" }
        return state
    }

    private func registryProperty(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(registryRoot, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    // MARK: - Écrans

    func display() -> DisplayState {
        var state = DisplayState()

        let main = CGMainDisplayID()
        state.asleep = CGDisplayIsAsleep(main) != 0

        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return state }
        state.enumerationOK = true
        state.onlineCount = Int(count)
        guard count > 0 else { return state }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return state }
        state.onlineCount = Int(count)

        // Repli : si l'écran principal ne rapporte rien mais que tous les écrans
        // en ligne dorment, l'affichage est bien éteint.
        if !state.asleep, count > 0 {
            let allAsleep = ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
            if allAsleep { state.asleep = true }
        }
        return state
    }

    // MARK: - Saisie sécurisée

    func secureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: - Activité matérielle

    /// Secondes depuis la dernière activité clavier/souris, -1 si indisponible.
    ///
    /// Mesuré au niveau HID, donc lisible même session verrouillée : c'est le
    /// seul signal qui distingue « économiseur seul à l'écran » de « panneau
    /// d'authentification par‑dessus l'économiseur », les deux états étant
    /// identiques pour le process, les fenêtres et les notifications.
    func hidIdleSeconds() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDSystem"),
                                           &iterator) == KERN_SUCCESS else { return -1 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return -1 }
        defer { IOObjectRelease(entry) }

        guard let value = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return -1 }
        return Double(value.uint64Value) / 1_000_000_000
    }

    // MARK: - Économiseur d'écran

    /// `p_comm` est tronqué à 16 caractères par le noyau : « ScreenSaverEngine »
    /// devient « ScreenSaverEngin ».
    private let engineCommPrefix = "ScreenSaverEngin"

    func saverEnginePID() -> Int32 {
        for process in runningProcesses() where process.name.hasPrefix(engineCommPrefix) {
            return process.pid
        }
        return 0
    }

    func saverWindow() -> WindowVerdict {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              !list.isEmpty else {
            return .unavailable
        }

        let screen = CGDisplayBounds(CGMainDisplayID())
        let screenArea = Double(screen.width * screen.height)
        let saverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= saverLevel else { continue }
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner.lowercased().contains("screensaver") else { continue }

            // Écarte l'aperçu miniature des Réglages Système : on exige une
            // fenêtre qui couvre réellement l'écran.
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
            if screenArea <= 0 || (width * height) >= 0.5 * screenArea {
                return .visible
            }
        }
        return .notVisible
    }

    // MARK: - Session graphique

    func hasAquaSession() -> Bool {
        CGSessionAvailable()
    }
}

/// Indique si le process voit une session graphique (LaunchAgent Aqua) ou non
/// (LaunchDaemon) : utile pour diagnostiquer les signaux disponibles.
func CGSessionAvailable() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return dict["kCGSSessionUserIDKey"] != nil
}

/// Liste des process (`p_comm` est tronqué à 16 caractères par le noyau).
/// Utilisable depuis n'importe quel contexte, y compris hors session graphique.
func runningProcesses() -> [(pid: Int32, name: String)] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var length = 0
    guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] as [(pid: Int32, name: String)] }

    // Marge : la table peut grandir entre les deux appels.
    let capacity = length / MemoryLayout<kinfo_proc>.stride + 32
    let buffer = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
    defer { buffer.deallocate() }

    var size = capacity * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, buffer, &size, nil, 0) == 0 else { return [] }

    let count = size / MemoryLayout<kinfo_proc>.stride
    var processes: [(pid: Int32, name: String)] = []
    processes.reserveCapacity(count)
    for index in 0..<count {
        var comm = buffer[index].kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        if !name.isEmpty { processes.append((buffer[index].kp_proc.p_pid, name)) }
    }
    return processes
}
