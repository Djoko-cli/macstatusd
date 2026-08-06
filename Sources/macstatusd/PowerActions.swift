import Foundation
import IOKit.pwr_mgt

/// Primitives d'extinction / réveil.
///
/// Chaque primitive rapporte seulement son succès de *lancement* ; la
/// confirmation réelle vient toujours des faits observés par le moteur d'état,
/// jamais de la commande elle‑même.
///
/// Aucune commande ne peut bloquer la file : les commandes dont on n'a pas
/// besoin du code retour sont lancées détachées, sans tuyau hérité (un enfant
/// mis en arrière‑plan par un `off_command` garderait sinon le tuyau ouvert et
/// retarderait toutes les commandes suivantes).
final class PowerActions {
    private let queue = DispatchQueue(label: "macstatusd.actions", qos: .userInitiated)
    private var userActivityAssertion = IOPMAssertionID(0)
    private let screenSaverAppPath = "/System/Library/CoreServices/ScreenSaverEngine.app"

    private let offCommandOverride: [String]
    private let wakeCommandOverride: [String]

    init(config: Config) {
        offCommandOverride = config.offCommand
        wakeCommandOverride = config.wakeCommand
    }

    var hasOffOverride: Bool { !offCommandOverride.isEmpty }

    // MARK: - OFF

    func runOff(_ action: OffAction) {
        if !offCommandOverride.isEmpty {
            launch(offCommandOverride, label: "off_command")
            return
        }
        switch action {
        case .screensaver: startScreenSaver()
        case .displaySleep: displaySleep()
        case .systemSleep: systemSleep()
        }
    }

    func startScreenSaver() {
        launch(["/usr/bin/open", "-a", screenSaverAppPath], label: "démarrage économiseur")
    }

    func displaySleep() {
        launch(["/usr/bin/pmset", "displaysleepnow"], label: "extinction écran")
    }

    func systemSleep() {
        queue.async { [self] in
            let status = runAndWait(["/usr/bin/pmset", "sleepnow"], label: "veille système")
            guard status != 0 else { return }
            logWarn("pmset sleepnow a échoué (code \(status)) → tentative via osascript")
            _ = runAndWait(["/usr/bin/osascript", "-e", "tell application \"System Events\" to sleep"],
                           label: "veille système (osascript)")
        }
    }

    // MARK: - ON

    /// Réveille l'écran en déclarant une activité utilisateur — API publique
    /// prévue pour ça, plus fiable qu'un `caffeinate` seul.
    func wake() {
        if !wakeCommandOverride.isEmpty {
            launch(wakeCommandOverride, label: "wake_command")
            return
        }
        queue.async { [self] in
            let result = IOPMAssertionDeclareUserActivity(
                "macstatusd wake" as CFString,
                kIOPMUserActiveLocal,
                &userActivityAssertion
            )
            if result == kIOReturnSuccess {
                logInfo("réveil: activité utilisateur déclarée")
            } else {
                logWarn("IOPMAssertionDeclareUserActivity a échoué (0x\(String(result, radix: 16)))")
            }
        }
        // Ceinture et bretelles, sans bloquer la file : réveille l'écran même si
        // l'assertion n'a pas suffi.
        launch(["/usr/bin/caffeinate", "-u", "-t", "2"], label: "caffeinate")
    }

    func stopScreenSaver() {
        launch(["/usr/bin/killall", "ScreenSaverEngine"], label: "arrêt économiseur")
    }

    // MARK: - Exécution

    /// Lance sans attendre et sans tuyau : ne peut ni bloquer ni fuir.
    private func launch(_ argv: [String], label: String) {
        queue.async {
            guard let executable = argv.first else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(argv.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                logInfo("\(label): lancé (\(argv.joined(separator: " ")))")
            } catch {
                logError("\(label): lancement impossible — \(error)")
            }
        }
    }

    /// Attend la fin du process direct, avec garde‑fou. Réservé aux commandes
    /// courtes dont le code retour pilote une décision.
    private func runAndWait(_ argv: [String], label: String, timeout: TimeInterval = 8) -> Int32 {
        guard let executable = argv.first else { return -1 }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logError("\(label): lancement impossible — \(error)")
            return -1
        }

        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            logWarn("\(label): délai dépassé → terminate")
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        let status = process.terminationStatus
        if status == 0 { logInfo("\(label): ok") } else { logWarn("\(label): code \(status)") }
        return status
    }
}
