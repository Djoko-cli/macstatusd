import Foundation
import CoreGraphics

/// Détermine si l'économiseur d'écran **occupe seul l'écran**.
///
/// Deux questions distinctes, et c'est toute la subtilité :
///
/// 1. *L'économiseur tourne‑t‑il ?* Trois sources indépendantes :
///    - le process `ScreenSaverEngine` (il n'existe que pendant l'économiseur,
///      contrairement à `legacyScreenSaver` qui rend aussi le fond d'écran) ;
///    - une fenêtre à l'écran au niveau `kCGScreenSaverWindowLevel` ou au‑dessus
///      appartenant à un process d'économiseur (couvre les économiseurs modernes
///      hébergés par `legacyScreenSaver`) ;
///    - les notifications `com.apple.screensaver.didstart/didstop`.
///
/// 2. *Est‑il encore seul à l'écran ?* Sur macOS, une frappe ou un mouvement fait
///    apparaître le panneau d'authentification **par‑dessus un économiseur qui
///    continue de tourner**. Mesuré sur macOS 26.5 : le process reste vivant,
///    `SACScreenSaverIsRunning` renvoie toujours 1, `didstop` n'est posté qu'au
///    déverrouillage, et la liste des fenêtres est identique. Le seul signal qui
///    change est l'activité matérielle (`HIDIdleTime`), lisible même session
///    verrouillée. Donc : une activité postérieure au démarrage de l'économiseur
///    signifie que le panneau est affiché, c'est‑à‑dire une UI accessible → ON.
///
/// Aucun état ne peut rester bloqué : les sources sont relues à chaque cycle, et
/// une inactivité prolongée (`redisplayIdle`) réarme l'économiseur, macOS
/// revenant à l'économiseur quand le panneau reste sans réponse.
///
/// À n'utiliser que depuis la file série du moteur d'état.
final class ScreenSaverOracle {
    enum WindowVerdict { case visible, notVisible, unavailable }

    struct Verdict {
        /// Économiseur seul à l'écran (ce qui décide de l'état OFF).
        var active: Bool
        /// Économiseur en cours, panneau par‑dessus ou non.
        var running: Bool
        /// Il tourne, mais une activité utilisateur l'a recouvert.
        var dismissed: Bool
        var evidence: String
    }

    private var notificationSaysActive = false
    private var pendingRearm = false
    /// Instant où l'économiseur a commencé à occuper l'écran.
    private var occupyingSince: Date?
    private var lastSaverPID: Int32 = 0
    private var lastWindowVerdict = WindowVerdict.unavailable
    private var lastWindowCheck = Date.distantPast

    private let minimumInterval: TimeInterval
    private let dismissOnInput: Bool
    private let dismissGrace: TimeInterval
    private let redisplayIdle: TimeInterval
    /// `p_comm` est tronqué à 16 caractères par le noyau : « ScreenSaverEngine »
    /// devient « ScreenSaverEngin ».
    private let engineCommPrefix = "ScreenSaverEngin"

    /// `processProbe` et `windowProbe` ne servent qu'à `--check-rules` : ils
    /// permettent de vérifier la règle de décision sans économiseur réel.
    private let processProbe: (() -> Int32)?
    private let windowProbe: (() -> WindowVerdict)?

    init(minimumInterval: TimeInterval = 1.0,
         dismissOnInput: Bool = true,
         dismissGrace: TimeInterval = 1.5,
         redisplayIdle: TimeInterval = 90,
         processProbe: (() -> Int32)? = nil,
         windowProbe: (() -> WindowVerdict)? = nil) {
        self.minimumInterval = minimumInterval
        self.dismissOnInput = dismissOnInput
        self.dismissGrace = dismissGrace
        self.redisplayIdle = redisplayIdle
        self.processProbe = processProbe
        self.windowProbe = windowProbe
    }

    /// Une notification `didstart` signifie que l'économiseur (re)prend l'écran :
    /// on réarme la fenêtre d'observation de l'activité.
    func noteNotification(active: Bool) {
        if active && !notificationSaysActive { pendingRearm = true }
        notificationSaysActive = active
        lastWindowCheck = .distantPast
    }

    func verdict(now: Date = Date(), hidIdle: Double) -> Verdict {
        var evidence: [String] = []
        var running = false

        let saverPID = enginePID()
        if saverPID != 0 {
            running = true
            evidence.append("process")
        }

        // Vérification des fenêtres à chaque cycle tant qu'un indice existe,
        // sinon en filet de sécurité une fois par `minimumInterval`.
        if notificationSaysActive || now.timeIntervalSince(lastWindowCheck) >= minimumInterval {
            lastWindowVerdict = windowVerdict()
            lastWindowCheck = now
        }
        if lastWindowVerdict == .visible {
            running = true
            evidence.append("window")
        }
        if notificationSaysActive {
            evidence.append("notification")
            // La notification ne fait foi que si l'oracle fenêtres ne peut pas
            // trancher (hors session graphique, permissions manquantes…).
            if lastWindowVerdict == .unavailable { running = true }
        }

        guard running else {
            occupyingSince = nil
            lastSaverPID = 0
            pendingRearm = false
            return Verdict(active: false, running: false, dismissed: false, evidence: "none")
        }

        // Nouveau démarrage : process différent, première détection, ou didstart.
        if occupyingSince == nil || pendingRearm || (saverPID != 0 && saverPID != lastSaverPID) {
            occupyingSince = now
            pendingRearm = false
        }
        lastSaverPID = saverPID

        var dismissed = false
        if dismissOnInput, hidIdle >= 0, let since = occupyingSince {
            let lastInput = now.addingTimeInterval(-hidIdle)
            if lastInput > since.addingTimeInterval(dismissGrace) {
                if hidIdle >= redisplayIdle {
                    // Personne n'a touché la machine depuis longtemps : macOS est
                    // revenu à l'économiseur, on réarme au lieu de rester à ON.
                    occupyingSince = now
                    evidence.append("réaffiché")
                } else {
                    dismissed = true
                    evidence.append("écarté-par-activité")
                }
            }
        }

        return Verdict(active: !dismissed,
                       running: true,
                       dismissed: dismissed,
                       evidence: evidence.joined(separator: "+"))
    }

    // MARK: - Sources

    private func enginePID() -> Int32 {
        if let processProbe { return processProbe() }
        for process in runningProcesses() where process.name.hasPrefix(engineCommPrefix) {
            return process.pid
        }
        return 0
    }

    private func windowVerdict() -> WindowVerdict {
        if let windowProbe { return windowProbe() }
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
}
