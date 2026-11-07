import Foundation

/// Dossiers de macstatusd dans l'espace de l'utilisateur : réglages, marqueur de redémarrage, journal.
///
/// Rien ne vit sous `/opt` : le démon tourne dans la session de l'utilisateur, sans `sudo`. Le nom des dossiers
/// vient de la clé `MacstatusdSupportName` de l'Info.plist du paquet `.app` (une identité d'essai a donc ses
/// propres dossiers), sinon `macstatusd`.
public struct SupportPaths: Equatable {
    /// Variable d'environnement qui remplace le dossier de support (tests, essais hors installation).
    public static let supportDirectoryVariable = "MACSTATUSD_SUPPORT_DIR"
    /// Clé de l'Info.plist du paquet qui nomme les dossiers.
    public static let bundleKey = "MacstatusdSupportName"
    /// Nom des dossiers quand le paquet n'en donne pas un valable.
    public static let defaultName = "macstatusd"

    /// Nom des dossiers (`macstatusd`, ou celui du paquet).
    public let name: String
    /// Dossier de support : `config.json`, marqueur de redémarrage.
    public let support: String
    /// Fichier de configuration : `support + "/config.json"`.
    public let config: String
    /// Dossier du journal.
    public let logs: String

    /// - `bundleSupportName` : lu dans le paquet ; ignoré s'il est vide, contient un `/` ou vaut `.` ou `..`
    ///   (un nom ne doit jamais sortir de `Application Support` ni de `Logs`) ;
    /// - `MACSTATUSD_SUPPORT_DIR` non vide remplace le dossier de support seulement.
    public static func resolve(environment: [String: String], bundleSupportName: String?, home: String) -> SupportPaths {
        var name = defaultName
        if let candidate = bundleSupportName, !candidate.isEmpty, !candidate.contains("/"),
           candidate != ".", candidate != ".." {
            name = candidate
        }
        var support = home + "/Library/Application Support/" + name
        if let override = environment[supportDirectoryVariable], !override.isEmpty { support = override }
        return SupportPaths(name: name, support: support, config: support + "/config.json",
                            logs: home + "/Library/Logs/" + name)
    }

    /// Nom lu dans l'Info.plist du paquet principal (`nil` hors d'un paquet `.app`).
    public static var bundleSupportName: String? {
        Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String
    }

    /// Les dossiers du processus courant.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: String = NSHomeDirectory()) -> SupportPaths {
        resolve(environment: environment, bundleSupportName: bundleSupportName, home: home)
    }
}
