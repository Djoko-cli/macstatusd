import Foundation

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
/// Les instants sont des secondes monotones (`Clock.monotonic()`), pas des dates.
/// À n'utiliser que depuis la file série du moteur d'état.
public final class ScreenSaverOracle {
    public struct Verdict {
        /// Économiseur seul à l'écran (ce qui décide de l'état OFF).
        public var active: Bool
        /// Économiseur en cours, panneau par‑dessus ou non.
        public var running: Bool
        /// Il tourne, mais une activité utilisateur l'a recouvert.
        public var dismissed: Bool
        public var evidence: String
    }

    private var notificationSaysActive = false
    private var pendingRearm = false
    /// Instant où l'économiseur a commencé à occuper l'écran.
    private var occupyingSince: Double?
    private var lastSaverPID: Int32 = 0
    private var lastWindowVerdict = WindowVerdict.unavailable
    private var lastWindowCheck = -Double.infinity

    private let minimumInterval: Double
    private let dismissOnInput: Bool
    private let dismissGrace: Double
    private let redisplayIdle: Double
    private let signals: SystemSignals

    public init(minimumInterval: Double = 1.0,
                dismissOnInput: Bool = true,
                dismissGrace: Double = 1.5,
                redisplayIdle: Double = 90,
                signals: SystemSignals) {
        self.minimumInterval = minimumInterval
        self.dismissOnInput = dismissOnInput
        self.dismissGrace = dismissGrace
        self.redisplayIdle = redisplayIdle
        self.signals = signals
    }

    /// Une notification `didstart` signifie que l'économiseur (re)prend l'écran :
    /// on réarme la fenêtre d'observation de l'activité.
    public func noteNotification(active: Bool) {
        if active && !notificationSaysActive { pendingRearm = true }
        notificationSaysActive = active
        lastWindowCheck = -Double.infinity
    }

    /// `now` est un instant monotone en secondes (voir `Clock.monotonic()`).
    public func verdict(now: Double, hidIdle: Double) -> Verdict {
        var evidence: [String] = []
        var running = false

        let saverPID = signals.saverEnginePID()
        if saverPID != 0 {
            running = true
            evidence.append("process")
        }

        // Vérification des fenêtres à chaque cycle tant qu'un indice existe,
        // sinon en filet de sécurité une fois par `minimumInterval`.
        if notificationSaysActive || now - lastWindowCheck >= minimumInterval {
            lastWindowVerdict = signals.saverWindow()
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
            let lastInput = now - hidIdle
            if lastInput > since + dismissGrace {
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
}
