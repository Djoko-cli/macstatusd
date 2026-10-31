import Foundation
import IOKit.pwr_mgt
import MacStatusCore

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
final class PowerActions: CommandActions {
    private let queue = DispatchQueue(label: "macstatusd.actions", qos: .userInitiated)
    // Tout l'état ci-dessous n'est touché que sur `queue` (série) : aucun verrou nécessaire, et
    // aucune de ces méthodes n'attend, donc ni /wake ni le moteur ne sont jamais ralentis.
    /// Assertion « utilisateur actif » posée par `wake()`, relâchée par `releaseWake()` (0 : aucune).
    private var userActivityAssertion = IOPMAssertionID(0)
    /// Le `caffeinate -u -t 2` du dernier réveil, gardé pour l'arrêter par son PID s'il tourne encore.
    private var caffeinateProcess: Process?
    /// Retenue d'écran en cours (0 : aucune) : jamais plus d'une à la fois.
    private var displayHoldAssertion = IOPMAssertionID(0)
    private var displayHoldTimer: DispatchSourceTimer?
    private let screenSaverAppPath = "/System/Library/CoreServices/ScreenSaverEngine.app"

    private let offCommandOverride: [String]
    private let wakeCommandOverride: [String]

    /// `SACScreenSaverStopNow` (login.framework) : arrête l'économiseur comme une frappe, sans argument. Rend 0
    /// (mesuré au banc). Résolue une fois à la création ; `nil` si le cadre ou le symbole manquent.
    private typealias SACStopNow = @convention(c) () -> Int32
    private static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
    private let sacStopNow: SACStopNow?

    /// Connu dès la création : natif si la fonction est résolue, sinon le repli `killall`.
    let screenSaverDismissal: ScreenSaverDismissal

    init(config: Config) {
        offCommandOverride = config.offCommand
        wakeCommandOverride = config.wakeCommand
        let stopNow = Self.resolveSACStopNow()
        sacStopNow = stopNow
        screenSaverDismissal = stopNow == nil ? .processKill : .native
    }

    /// Ouvre login.framework et résout la fonction, sans l'appeler. Le cadre reste ouvert jusqu'à la fin du
    /// process (le pointeur de fonction doit rester valide) ; `LiveSystemSignals` y résout déjà
    /// `SACScreenSaverIsRunning`. Un échec se journalise ici (WARN, la raison) ; le moteur annonce le repli au
    /// démarrage.
    private static func resolveSACStopNow() -> SACStopNow? {
        guard let framework = dlopen(loginFrameworkPath, RTLD_LAZY) else {
            let reason = dlerror().map { escapeForLog(String(cString: $0)) } ?? "raison inconnue"
            logWarn("SACScreenSaverStopNow indisponible : login.framework ne s'ouvre pas (\(reason))")
            return nil
        }
        guard let symbol = dlsym(framework, "SACScreenSaverStopNow") else {
            logWarn("SACScreenSaverStopNow indisponible : symbole absent de login.framework")
            return nil
        }
        return unsafeBitCast(symbol, to: SACStopNow.self)
    }

    var hasOffOverride: Bool { !offCommandOverride.isEmpty }
    var hasWakeOverride: Bool { !wakeCommandOverride.isEmpty }

    // MARK: - OFF

    func runOff(_ action: OffAction) {
        if !offCommandOverride.isEmpty {
            launch(offCommandOverride, label: "off_command", masked: true)
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
    ///
    /// L'assertion posée dure jusqu'à `releaseWake()` (appelé par le moteur dès que le ON est
    /// confirmé par les faits) : laissée à elle-même, elle garderait l'écran allumé plusieurs
    /// minutes. Avec une surcharge `wake_command`, rien n'est posé.
    func wake() {
        if !wakeCommandOverride.isEmpty {
            launch(wakeCommandOverride, label: "wake_command", masked: true)
            return
        }
        queue.async { [self] in
            // Un ID déjà valide est renouvelé par le système au lieu d'en créer un second.
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
            // Ceinture et bretelles : réveille l'écran même si l'assertion n'a pas suffi. Lancé
            // sans attendre ; le processus est gardé pour pouvoir l'arrêter par son PID.
            startCaffeinate()
        }
    }

    /// Relâche l'assertion « utilisateur actif » et arrête le `caffeinate` du réveil s'il tourne encore
    /// (par son PID, jamais par son nom). Sans effet si rien n'est posé ni avec `wake_command`.
    func releaseWake() {
        guard wakeCommandOverride.isEmpty else { return }
        queue.async { [self] in
            if userActivityAssertion != IOPMAssertionID(0) {
                let result = IOPMAssertionRelease(userActivityAssertion)
                userActivityAssertion = IOPMAssertionID(0)
                if result == kIOReturnSuccess {
                    logInfo("réveil: assertion d'activité utilisateur relâchée")
                } else {
                    logWarn("IOPMAssertionRelease (activité utilisateur) a échoué (0x\(String(result, radix: 16)))")
                }
            }
            stopCaffeinate(raison: "réveil relâché")
        }
    }

    /// Plafond d'une retenue d'écran, aligné sur la borne de `wake_hold_seconds`.
    private static let maxHoldSeconds = 600.0

    /// Retient l'écran allumé `seconds` secondes (`kIOPMAssertPreventUserIdleDisplaySleep`). Une
    /// nouvelle retenue remplace l'ancienne ; `seconds <= 0` la relâche. L'assertion a son propre
    /// délai (minuterie sur la file, doublée d'un filet côté système juste après) : elle ne dépend ni
    /// du moteur ni d'un appel ultérieur. Avec `wake_command`, rien n'est posé.
    func holdDisplay(seconds: Double) {
        guard wakeCommandOverride.isEmpty else { return }
        queue.async { [self] in
            releaseDisplayHold(raison: seconds > 0 ? "remplacée" : "levée")
            guard seconds > 0 else { return }
            let duree = min(seconds, Self.maxHoldSeconds)

            let proprietes: [String: Any] = [
                kIOPMAssertionTypeKey as String: kIOPMAssertPreventUserIdleDisplaySleep as String,
                // ASCII : `pmset -g assertions` affichait mal l'accent.
                kIOPMAssertionNameKey as String: "macstatusd retenue d'ecran",
                kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
                // Filet : le système la relâche lui-même, quelques secondes après notre minuterie.
                kIOPMAssertionTimeoutKey as String: duree + 3,
                kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
            ]
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithProperties(proprietes as CFDictionary, &id)
            guard result == kIOReturnSuccess else {
                logWarn("retenue d'écran: IOPMAssertionCreateWithProperties a échoué (0x\(String(result, radix: 16)))")
                return
            }
            displayHoldAssertion = id
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + duree)
            timer.setEventHandler { [weak self] in
                // Une retenue remplacée entre-temps a un autre identifiant : on ne touche pas à la nouvelle.
                guard let self, self.displayHoldAssertion == id else { return }
                self.releaseDisplayHold(raison: "échue")
            }
            displayHoldTimer = timer
            timer.resume()
            logInfo("retenue d'écran: posée pour \(Int(duree)) s")
        }
    }

    /// À appeler sur `queue`. Relâche la retenue et sa minuterie, s'il y en a.
    private func releaseDisplayHold(raison: String) {
        displayHoldTimer?.cancel()
        displayHoldTimer = nil
        guard displayHoldAssertion != IOPMAssertionID(0) else { return }
        let result = IOPMAssertionRelease(displayHoldAssertion)
        displayHoldAssertion = IOPMAssertionID(0)
        if result == kIOReturnSuccess {
            logInfo("retenue d'écran: \(raison)")
        } else {
            logWarn("retenue d'écran: IOPMAssertionRelease après \(raison) a échoué (0x\(String(result, radix: 16)))")
        }
    }

    /// À appeler sur `queue`. Arrête le `caffeinate` du dernier réveil s'il tourne encore, par son PID, jamais
    /// par son nom. Sans effet s'il n'y en a pas.
    private func stopCaffeinate(raison: String) {
        guard let process = caffeinateProcess else { return }
        caffeinateProcess = nil
        guard process.isRunning else { return }
        logInfo("réveil: caffeinate (pid \(process.processIdentifier)) arrêté (\(raison))")
        process.terminate()
    }

    /// À appeler sur `queue`. Lance `caffeinate -u -t 2` sans attendre, ni tuyau. Un seul à la fois (R52) :
    /// celui du réveil précédent, s'il tourne encore, est d'abord arrêté par son PID. Sans cela, deux /wake
    /// rapprochés en laissaient un orphelin, hors de portée de `releaseWake()`.
    private func startCaffeinate() {
        stopCaffeinate(raison: "remplacé par un nouveau réveil")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "2"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            caffeinateProcess = process
            logInfo("caffeinate: lancé (/usr/bin/caffeinate -u -t 2)")
        } catch {
            logError("caffeinate: lancement impossible — \(error)")
        }
    }

    /// Écarte l'économiseur par `screenSaverDismissal`. Le moyen natif est appelé sur la file des actions, jamais
    /// sur celle du moteur ; son code est journalisé, 0 attendu. Le repli lance `killall ScreenSaverEngine`
    /// sans attendre.
    func dismissScreenSaver() {
        switch screenSaverDismissal {
        case .native:
            queue.async { [self] in
                guard let stopNow = sacStopNow else { return }
                let code = stopNow()
                if code == 0 {
                    logInfo("économiseur: SACScreenSaverStopNow appelé (code 0)")
                } else {
                    logWarn("économiseur: SACScreenSaverStopNow a rendu le code \(code) (0 attendu)")
                }
            }
        case .processKill:
            launch(["/usr/bin/killall", "ScreenSaverEngine"], label: "arrêt économiseur")
        }
    }

    // MARK: - Exécution

    /// Lance sans attendre et sans tuyau : ne peut ni bloquer ni fuir. `masked` (commandes de la
    /// config) : le journal ne montre que l'exécutable et le nombre d'arguments.
    private func launch(_ argv: [String], label: String, masked: Bool = false) {
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
                let shown = masked ? commandSummaryForLog(argv) : argv.joined(separator: " ")
                logInfo("\(label): lancé (\(shown))")
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
