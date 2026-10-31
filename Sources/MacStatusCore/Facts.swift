import Foundation

/// Instantané des faits observables. Aucune interprétation ici : uniquement ce
/// que le système rapporte, avec la provenance de chaque valeur pour /status.
public struct Facts {
    /// Veille système confirmée par IOKit (kIOMessageSystemWillSleep).
    public var systemAsleep = false
    /// Écran physiquement éteint (display sleep).
    public var displayAsleep = false
    /// Écrans physiques en ligne : l'écran fantôme du système ne compte pas.
    public var onlineDisplays = 0
    public var displayEnumerationOK = false
    /// Ce qui fonde `displayAsleep` : `main`, `all`, `screensDidSleep`, `awake`, ou `none` (aucun écran physique).
    public var displayEvidence = "none"
    /// Tous les écrans en ligne, fantôme compris (résumé dans `asDictionary`).
    public var displays: [DisplayInfo] = []
    /// Économiseur seul à l'écran. Faux dès qu'une activité utilisateur l'a
    /// recouvert du panneau d'authentification (voir `ScreenSaverOracle`).
    public var screenSaverActive = false
    public var screenSaverEvidence = "none"
    /// Économiseur en cours d'exécution, panneau de login par‑dessus ou non.
    public var screenSaverRunning = false
    /// L'économiseur tourne mais une activité utilisateur l'a écarté.
    public var screenSaverDismissed = false
    /// Secondes depuis la dernière activité clavier/souris matérielle
    /// (`IOHIDSystem.HIDIdleTime`), -1 si indisponible.
    public var hidIdleSeconds: Double = -1
    public var sessionLocked = false
    public var lockEvidence = "none"
    /// Un utilisateur est ouvert sur la console (false = fenêtre de login).
    public var consoleUserLoggedIn = false
    /// La session de la console est celle de l'utilisateur (lu dans `SessionState`).
    public var onConsole = false
    /// Saisie sécurisée active : sur session verrouillée, signe que le champ
    /// mot de passe de l'écran de verrouillage a le focus.
    public var secureInputActive = false

    public init() {}

    public var asDictionary: [String: Any] {
        [
            "system_asleep": systemAsleep,
            "display_asleep": displayAsleep,
            "online_displays": onlineDisplays,
            "display_enumeration_ok": displayEnumerationOK,
            "display_evidence": displayEvidence,
            "displays": DisplayTopology.summary(displays),
            "screensaver_active": screenSaverActive,
            "screensaver_evidence": screenSaverEvidence,
            "screensaver_running": screenSaverRunning,
            "screensaver_dismissed": screenSaverDismissed,
            "hid_idle_seconds": (hidIdleSeconds * 10).rounded() / 10,
            "session_locked": sessionLocked,
            "lock_evidence": lockEvidence,
            "console_user_logged_in": consoleUserLoggedIn,
            "on_console": onConsole,
            "secure_input_active": secureInputActive,
        ]
    }
}
