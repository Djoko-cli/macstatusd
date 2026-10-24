import Foundation

/// Verrouillage et ouverture de session, tels que le système les rapporte.
public struct SessionState {
    public var locked: Bool
    public var loggedIn: Bool
    /// La session visible à la console est celle de l'utilisateur (et non celle
    /// d'un autre compte ou d'un daemon sans console).
    public var onConsole: Bool
    /// Provenance de la valeur `locked`, pour /status.
    public var evidence: String

    public init(locked: Bool = false, loggedIn: Bool = false, onConsole: Bool = false, evidence: String = "none") {
        self.locked = locked
        self.loggedIn = loggedIn
        self.onConsole = onConsole
        self.evidence = evidence
    }
}

/// État des écrans.
public struct DisplayState {
    public var asleep: Bool
    public var onlineCount: Int
    /// L'énumération des écrans en ligne a réussi : sinon `onlineCount` ne prouve rien.
    public var enumerationOK: Bool

    public init(asleep: Bool = false, onlineCount: Int = 0, enumerationOK: Bool = false) {
        self.asleep = asleep
        self.onlineCount = onlineCount
        self.enumerationOK = enumerationOK
    }
}

/// Une fenêtre d'économiseur couvre-t-elle l'écran ? `unavailable` : le système
/// ne permet pas de trancher (hors session graphique, permission manquante).
public enum WindowVerdict {
    case visible, notVisible, unavailable
}

/// Tout ce que le moteur lit du système. L'implémentation réelle vit dans
/// l'exécutable (IOKit, CoreGraphics, Carbon) ; les tests injectent un faux.
public protocol SystemSignals: AnyObject {
    func session() -> SessionState
    func display() -> DisplayState
    /// Secondes depuis la dernière activité clavier ou souris, -1 si indisponible.
    func hidIdleSeconds() -> Double
    func secureInputActive() -> Bool
    /// PID du process `ScreenSaverEngine`, 0 s'il n'existe pas.
    func saverEnginePID() -> Int32
    func saverWindow() -> WindowVerdict
    /// Le daemon tourne-t-il dans une session graphique (Aqua) ?
    func hasAquaSession() -> Bool
}
