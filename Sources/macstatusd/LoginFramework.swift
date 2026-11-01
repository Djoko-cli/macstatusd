import Foundation
import MacStatusCore

/// login.framework : cadre privé du système qui porte `SACScreenSaverIsRunning` (lecture de la session
/// d'économiseur, `LiveSystemSignals`) et `SACScreenSaverStopNow` (écartement de l'économiseur, `PowerActions`).
///
/// Il s'ouvre **une seule fois** pour tout le process : un seul chemin à tenir à jour si Apple déplace le cadre, un
/// seul avertissement s'il ne s'ouvre pas. Il reste ouvert jusqu'à la fin du process, pour que les pointeurs de
/// fonction qu'on y résout restent valides. Ce fichier ne fait que résoudre des symboles : aucune fonction n'est
/// appelée ici.
enum LoginFramework {
    static let path = "/System/Library/PrivateFrameworks/login.framework/login"

    /// Poignée du cadre, ouverte au premier accès (l'initialisation d'un global statique est sûre entre fils) ;
    /// `nil` s'il ne s'ouvre pas. L'avertissement part ici, une fois pour les deux fonctions.
    private static let handle: UnsafeMutableRawPointer? = {
        guard let framework = dlopen(path, RTLD_LAZY) else {
            let reason = dlerror().map { escapeForLog(String(cString: $0)) } ?? "raison inconnue"
            logWarn("login.framework ne s'ouvre pas (\(reason)) : SACScreenSaverIsRunning et SACScreenSaverStopNow "
                    + "indisponibles")
            return nil
        }
        return framework
    }()

    /// Résout le symbole `name`, sans l'appeler. `nil` si le cadre ne s'ouvre pas (déjà signalé, une fois) ou si le
    /// symbole manque (WARN, nommant le symbole). Chaque appelant ne résout qu'une fois, au démarrage.
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        guard let symbol = dlsym(handle, name) else {
            logWarn("\(name) indisponible : symbole absent de login.framework")
            return nil
        }
        return symbol
    }
}
