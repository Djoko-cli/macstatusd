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

/// État des écrans, tiré d'un instantané par `DisplayTopology.state`.
public struct DisplayState {
    /// L'affichage est éteint. Jamais vrai sans écran physique.
    public var asleep: Bool
    /// Écrans physiques en ligne : l'écran fantôme du système ne compte pas.
    public var onlineCount: Int
    /// L'énumération des écrans en ligne a réussi : sinon `onlineCount` ne prouve rien.
    public var enumerationOK: Bool
    /// Ce qui fonde `asleep` : `main`, `all`, `screensDidSleep`, `awake`, ou `none` (aucun écran physique).
    public var evidence: String
    /// Tous les écrans en ligne, fantôme compris.
    public var displays: [DisplayInfo]

    public init(asleep: Bool = false, onlineCount: Int = 0, enumerationOK: Bool = false,
                evidence: String = "none", displays: [DisplayInfo] = []) {
        self.asleep = asleep
        self.onlineCount = onlineCount
        self.enumerationOK = enumerationOK
        self.evidence = evidence
        self.displays = displays
    }
}

/// Un process de l'utilisateur qui héberge un économiseur d'écran (`SaverHostRule`).
public struct SaverHost: Equatable {
    public var pid: Int32
    /// Secondes écoulées (temps réel) depuis le lancement du process.
    public var launchedSecondsAgo: Double

    public init(pid: Int32, launchedSecondsAgo: Double) {
        self.pid = pid
        self.launchedSecondsAgo = launchedSecondsAgo
    }
}

/// Tout ce que le moteur lit du système. L'implémentation réelle vit dans
/// l'exécutable (IOKit, CoreGraphics, Carbon) ; les tests injectent un faux.
public protocol SystemSignals: AnyObject {
    func session() -> SessionState
    /// Les écrans en ligne et leur veille, sans interprétation : `DisplayTopology` reconnaît le fantôme.
    func displaySnapshot() -> DisplaySnapshot
    /// Secondes depuis la dernière activité clavier ou souris, -1 si indisponible. Une lecture du registre à chaque
    /// appel : le moteur ne la demande que si l'oracle de l'économiseur est évalué, pendant une veille en cours, et
    /// pour `/status`.
    func hidIdleSeconds() -> Double
    func secureInputActive() -> Bool
    /// PID du process `ScreenSaverEngine` de l'utilisateur, 0 s'il n'existe pas ou n'est pas encore
    /// connu (voir `saverProcessHint()`). Les process des autres utilisateurs ne comptent pas.
    func saverEnginePID() -> Int32
    /// `SACScreenSaverIsRunning` : vrai pendant toute une session d'économiseur, panneau de connexion
    /// compris ; faux hors session, y compris sur un simple verrouillage ; `nil` seulement si la fonction manque
    /// (ou rendrait un jour un code autre que 0 et 1, ce qu'on n'a jamais vu).
    ///
    /// **Faux aussi quand l'agent de session ne répond pas** : l'appel passe par XPC et rend 0 s'il échoue,
    /// indiscernable de « hors session ». Le repli sur l'hôte (`nil`) ne couvre donc pas cette panne ; le WARN
    /// « didstart non corroboré », à chaque économiseur, en est alors le seul signe.
    func saverSessionFlag() -> Bool?
    /// Process de l'utilisateur qui hébergent un économiseur (`SaverHostRule.isHost(path:)`). Appelé
    /// seulement en repli, quand `saverSessionFlag()` rend `nil`.
    func saverHosts() -> [SaverHost]
    /// Indice qu'un process d'économiseur vient de naître ou de disparaître : la lecture suivante de
    /// `saverEnginePID()` refait un balayage complet des process, sans attendre l'échéance.
    func saverProcessHint()
    /// Le daemon tourne-t-il dans une session graphique (Aqua) ?
    func hasAquaSession() -> Bool
}
