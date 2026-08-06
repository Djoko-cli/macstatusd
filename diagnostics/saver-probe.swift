// Sonde de diagnostic : enregistre tous les signaux candidats permettant de
// distinguer « économiseur en train de dessiner » de « process ScreenSaverEngine
// survivant derrière l'écran de verrouillage ».
//
//   swiftc -O -o /tmp/saver-probe diagnostics/saver-probe.swift
//   /tmp/saver-probe [durée_secondes] [port_macstatusd]
//
// Écrit sur la sortie standard et dans /tmp/macstatusd-saver-probe.log.
// N'exige aucun privilège.

import Foundation
import IOKit
import CoreGraphics
import Carbon

let duration = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "90") ?? 90
let daemonPort = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "9090"
let outputPath = "/tmp/macstatusd-saver-probe.log"

// MARK: - Sortie

FileManager.default.createFile(atPath: outputPath, contents: nil)
let sink = FileHandle(forWritingAtPath: outputPath)
func emit(_ line: String) {
    print(line)
    sink?.write(Data((line + "\n").utf8))
}

// MARK: - login.framework (API privée, chargée dynamiquement)

typealias SACIsRunning = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int32
var sacIsRunning: SACIsRunning?
let loginFramework = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)
if let loginFramework, let symbol = dlsym(loginFramework, "SACScreenSaverIsRunning") {
    sacIsRunning = unsafeBitCast(symbol, to: SACIsRunning.self)
}

/// Appelé avec un pointeur valide : couvre les deux signatures plausibles
/// (`OSStatus f(Boolean*)` ou `Boolean f(void)` qui ignorerait l'argument).
func screenSaverIsRunningViaSAC() -> (available: Bool, ret: Int32, out: UInt8) {
    guard let sacIsRunning else { return (false, -1, 0xAA) }
    var out: UInt8 = 0xAA
    let ret = withUnsafeMutablePointer(to: &out) { sacIsRunning($0) }
    return (true, ret, out)
}

// MARK: - Signaux publics

let registryRoot = IORegistryGetRootEntry(kIOMainPortDefault)

func registryProperty(_ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(registryRoot, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func lockSignals() -> String {
    var parts: [String] = []
    parts.append("ioLocked=" + (((registryProperty("IOConsoleLocked") as? NSNumber)?.boolValue ?? false) ? "1" : "0"))
    if let sessions = registryProperty("IOConsoleUsers") as? [[String: Any]] {
        let console = sessions.first { ($0["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true }
        parts.append("usersLocked=" + (((console?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false) ? "1" : "0"))
        // Toute clé inconnue apparue pendant l'économiseur est intéressante.
        let known: Set<String> = ["CGSSessionUniqueSessionUUID", "kCGSSessionAuditIDKey", "kCGSSessionGroupIDKey",
                                  "kCGSSessionIDKey", "kCGSSessionLoginwindowSafeLogin", "kCGSSessionOnConsoleKey",
                                  "kCGSSessionSystemSafeBoot", "kCGSSessionUserIDKey", "kCGSSessionUserNameKey",
                                  "kCGSessionLoginDoneKey", "kCGSessionLongUserNameKey", "kSCSecuritySessionID",
                                  "CGSSessionScreenIsLocked"]
        if let securePID = (console?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value {
            parts.append("secureInputPid=\(securePID)")
        } else {
            parts.append("secureInputPid=-")
        }
        let extra = (console?.keys.filter { !known.contains($0) && $0 != "kCGSSessionSecureInputPID" } ?? []).sorted()
        if !extra.isEmpty { parts.append("clésInattendues=\(extra)") }
    }
    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
        parts.append("cgLocked=" + (((dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false) ? "1" : "0"))
    } else {
        parts.append("cgLocked=nil")
    }
    return parts.joined(separator: " ")
}

/// PID des process intéressants : l'économiseur, son hôte moderne, et
/// loginwindow (pour comparer avec le détenteur de la saisie sécurisée).
func interestingProcesses() -> (saver: Int32, legacy: Int32, loginwindow: Int32) {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var length = 0
    guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0, 0) }
    let capacity = length / MemoryLayout<kinfo_proc>.stride + 32
    let buffer = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
    defer { buffer.deallocate() }
    var size = capacity * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, buffer, &size, nil, 0) == 0 else { return (0, 0, 0) }
    var result: (saver: Int32, legacy: Int32, loginwindow: Int32) = (0, 0, 0)
    for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
        var comm = buffer[index].kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let pid = buffer[index].kp_proc.p_pid
        if name.hasPrefix("ScreenSaverEngin") { result.saver = pid }
        else if name.hasPrefix("legacyScreenSav") { result.legacy = pid }
        else if name == "loginwindow" { result.loginwindow = pid }
    }
    return result
}

/// Détaille les fenêtres de loginwindow / économiseur, avec l'alpha et le
/// numéro de fenêtre : c'est là qu'on s'attend à voir l'overlay de verrouillage
/// apparaître, se masquer (Échap) et réapparaître.
func windowSurvey() -> String {
    var parts: [String] = []

    for (label, option) in [("écran", CGWindowListOption.optionOnScreenOnly),
                            ("toutes", CGWindowListOption.optionAll)] {
        guard let list = CGWindowListCopyWindowInfo([option], kCGNullWindowID) as? [[String: Any]] else {
            parts.append("\(label)=nil")
            continue
        }
        var details: [String] = []
        for window in list {
            let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let lowered = owner.lowercased()
            let saverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
            let interesting = lowered.contains("screensaver") || lowered.contains("login")
                || lowered.contains("securityagent")
            // « toutes » ne garde que les acteurs du verrouillage ; « écran » y
            // ajoute ce qui flotte au niveau économiseur ou au‑dessus.
            guard interesting || (option == .optionOnScreenOnly && layer >= saverLevel) else { continue }
            guard owner != "Window Server" else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = (bounds["Width"] as? NSNumber)?.intValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.intValue ?? 0
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
            let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
            let onscreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            details.append("[\(owner) n=\(number) l=\(layer) \(width)x\(height) "
                           + "a=\(String(format: "%.2f", alpha)) vis=\(onscreen ? 1 : 0)]")
        }
        parts.append("\(label)=\(list.count) " + (details.isEmpty ? "—" : details.joined(separator: " ")))
    }
    return parts.joined(separator: " | ")
}

func hidIdleSeconds() -> Double {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS
    else { return -1 }
    defer { IOObjectRelease(iterator) }
    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return -1 }
    defer { IOObjectRelease(entry) }
    guard let value = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return -1 }
    return Double(value.uint64Value) / 1_000_000_000
}

// MARK: - Notifications distribuées

var notificationTrace: [String] = []
let started = Date()
func stamp() -> String { String(format: "%6.2f", Date().timeIntervalSince(started)) }

for name in ["com.apple.screensaver.didstart", "com.apple.screensaver.didstop",
             "com.apple.screensaver.willstop", "com.apple.screenIsLocked",
             "com.apple.screenIsUnlocked"] {
    DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name(name), object: nil, queue: .main
    ) { _ in
        notificationTrace.append("\(stamp()) NOTIFICATION \(name)")
        emit("\(stamp()) ── NOTIFICATION \(name)")
    }
}

// MARK: - Boucle

emit("sonde macstatusd — économiseur d'écran")
emit("durée=\(Int(duration))s  SACScreenSaverIsRunning \(sacIsRunning == nil ? "INDISPONIBLE" : "chargée")")
emit("séquence attendue: t≈4 déclenchement OFF (économiseur), ne rien toucher ~10 s,")
emit("frappe 1 → overlay de verrouillage, frappe 2 → champ mot de passe,")
emit("Échap → overlay masqué (ne plus rien toucher ~10 s), puis déverrouiller.")
emit("")

var previousKey = ""
var triggered = false

let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
    let elapsed = Date().timeIntervalSince(started)
    if elapsed >= duration {
        emit("")
        emit("=== fin. Trace des notifications:")
        notificationTrace.forEach { emit("   \($0)") }
        emit("=== fichier: \(outputPath)")
        exit(0)
    }

    if !triggered && elapsed >= 4 {
        triggered = true
        emit("\(stamp()) ── déclenchement de la commande OFF (GET /sleep sur le port \(daemonPort))")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-fsS", "--max-time", "3", "http://127.0.0.1:\(daemonPort)/sleep"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    let process = interestingProcesses()
    let sac = screenSaverIsRunningViaSAC()
    let locks = lockSignals()
    let windows = windowSurvey()
    let secure = IsSecureEventInputEnabled()
    let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

    let key = "\(process.saver)|\(sac.ret)|\(sac.out)|\(locks)|\(windows)|\(secure)|\(displayAsleep)"
    let changed = key != previousKey
    let heartbeat = Int(elapsed * 4) % 8 == 0
    guard changed || heartbeat else { return }
    previousKey = key

    emit("\(stamp()) \(changed ? "*" : " ") "
         + "ssPid=\(process.saver) legacyPid=\(process.legacy) loginwindowPid=\(process.loginwindow) "
         + "SAC(ret=\(sac.ret) out=\(sac.out == 0xAA ? "nonÉcrit" : String(sac.out))) "
         + "écranÉteint=\(displayAsleep ? 1 : 0) "
         + "secureInput=\(secure ? 1 : 0) "
         + "hidIdle=\(String(format: "%.1f", hidIdleSeconds())) "
         + "\(locks) \(windows)")
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
