import Foundation

/// Quels process hébergent un économiseur d'écran, sous macOS 27.
///
/// Mesuré au banc : `ScreenSaverEngine` n'existe que pour l'économiseur *commandé*. L'économiseur lancé
/// par l'inactivité tourne dans `legacyScreenSaver` (arm64, ou `-x86_64` sous Rosetta), ou dans
/// l'extension « Computer Name » pour « Message ». Le fond d'écran, lui, vit en permanence dans les
/// extensions `Wallpaper*` (`WallpaperAerialsExtension`…) : elles ne comptent jamais.
///
/// Le chemin vient de `proc_pidpath`, c'est celui de l'exécutable réellement lancé. `/System` est
/// protégé : un exécutable du même nom ailleurs (une copie, un dossier d'essai) n'est pas un hôte.
public enum SaverHostRule {
    private static let systemPrefix = "/System/Library/"
    /// Hôtes `legacyScreenSaver`, quelle que soit l'architecture.
    private static let frameworkPlugIns = "/ScreenSaver.framework/PlugIns/"
    private static let engine = "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine"
    /// Hôte de l'économiseur « Message ».
    private static let computerNameExtension = "/Computer Name.appex/Contents/MacOS/"
    /// Préfixe du nom court de `ScreenSaverEngine`. Le noyau tronque ce nom : à 16 caractères dans
    /// `p_comm` (table des process, « ScreenSaverEngin »), à 15 dans `pbi_comm` (`proc_pidinfo`,
    /// « ScreenSaverEngi »). Le préfixe de 15 caractères convient aux deux lectures.
    private static let engineShortNamePrefix = "ScreenSaverEngi"

    public static func isHost(path: String) -> Bool {
        guard path.hasPrefix(systemPrefix) else { return false }
        return path == engine || path.contains(frameworkPlugIns) || path.contains(computerNameExtension)
    }

    /// Le nom court d'un process (`p_comm` ou `pbi_comm`) est-il celui de `ScreenSaverEngine` ?
    public static func isEngine(shortName: String) -> Bool {
        shortName.hasPrefix(engineShortNamePrefix)
    }
}

/// Lecture du code de retour de `SACScreenSaverIsRunning` (login.framework).
///
/// La fonction n'a aucun argument : sa valeur passe par le code de retour. Mesuré au banc sous macOS 27 :
/// 1 pendant toute une session d'économiseur, panneau de connexion compris ; 0 hors session, y compris sur un
/// simple verrouillage, **et aussi quand l'agent de session ne répond pas** (la liaison XPC en échec rend 0 : ce
/// cas-là n'est pas un drapeau absent, le repli ne s'engage pas). Tout autre code montrerait que la fonction a
/// changé (jamais vu sur macOS 27) : le drapeau n'est pas disponible (`nil`), et l'appelant se rabat sur les hôtes
/// (`SaverHostRule`).
public enum SaverSessionFlag {
    public static func from(returnCode: Int32) -> Bool? {
        switch returnCode {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }
}

/// Cadence du balayage de la table des process qui cherche `ScreenSaverEngine`.
///
/// Un balayage complet n'est accordé que dans trois cas : au tout premier appel, après un indice
/// (lancement ou fin d'un process d'économiseur, annoncé par une notification), ou quand
/// `fullScanInterval` s'est écoulé depuis le dernier balayage accordé, filet de sécurité d'une
/// notification manquée. Entre deux, la lecture du PID se réduit à la vérification du PID gardé.
///
/// Les instants sont des secondes monotones (`Clock.monotonic()`). À n'utiliser que depuis la file série
/// du moteur d'état.
public struct SaverProcessScanPolicy {
    /// Secondes entre deux balayages complets quand aucun indice n'est venu.
    public static let fullScanInterval: Double = 5

    private var lastScanAt: Double?
    private var hintPending = false

    public init() {}

    /// Un process d'économiseur vient de naître ou de disparaître : le prochain `shouldScan` accorde un
    /// balayage. Plusieurs indices avant ce balayage n'en valent qu'un.
    public mutating func noteHint() {
        hintPending = true
    }

    /// Vrai si l'appelant doit balayer maintenant. Le balayage accordé est noté : l'échéance suivante
    /// court depuis lui, et l'indice en attente est consommé.
    public mutating func shouldScan(now: Double) -> Bool {
        if let last = lastScanAt, !hintPending, now - last < Self.fullScanInterval { return false }
        lastScanAt = now
        hintPending = false
        return true
    }
}
