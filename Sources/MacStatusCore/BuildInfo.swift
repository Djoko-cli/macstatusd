import Foundation

/// Provenance du binaire : `Contents/Resources/build-info.json` du paquet `.app`, écrit à la construction
/// (`{"version": "0.6.0-dev", "git": "v0.5.0-90-g1234567", "built_at": "2026-11-07"}`).
///
/// La version affichée reste `macstatusdVersion` (source unique) ; `version` ne sert qu'à repérer un fichier
/// qui n'est pas celui du binaire. Un fichier absent ou illisible donne des chaînes vides : la provenance est
/// alors inconnue, jamais inventée.
public struct BuildInfo: Equatable {
    public let version: String
    public let git: String
    public let builtAt: String

    public init(version: String = "", git: String = "", builtAt: String = "") {
        self.version = version
        self.git = git
        self.builtAt = builtAt
    }

    /// Provenance inconnue.
    public static let unknown = BuildInfo()

    /// Lit le contenu de `build-info.json` ; `nil`, un JSON invalide ou autre chose qu'un objet donnent `unknown`.
    /// Une valeur qui n'est pas une chaîne compte pour absente.
    public static func parse(_ data: Data?) -> BuildInfo {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        return BuildInfo(version: object["version"] as? String ?? "",
                         git: object["git"] as? String ?? "",
                         builtAt: object["built_at"] as? String ?? "")
    }

    /// Le `build-info.json` du paquet principal (`unknown` hors d'un paquet `.app`).
    public static func current() -> BuildInfo {
        guard let url = Bundle.main.url(forResource: "build-info", withExtension: "json") else { return .unknown }
        return parse(try? Data(contentsOf: url))
    }

    /// « macstatusd 0.6.0-dev (git v0.5.0-90-g1234567, 2026-11-07) », ou « … (compilation inconnue) ».
    public var versionLine: String {
        var parts: [String] = []
        if !git.isEmpty { parts.append("git " + git) }
        if !builtAt.isEmpty { parts.append(builtAt) }
        return "macstatusd \(macstatusdVersion) (" + (parts.isEmpty ? "compilation inconnue" : parts.joined(separator: ", ")) + ")"
    }

    /// Le champ `build` de `/status` : `null` pour ce qui est inconnu.
    var statusDictionary: [String: Any] {
        func valueOrNull(_ text: String) -> Any { text.isEmpty ? NSNull() : text }
        return ["git": valueOrNull(git), "built_at": valueOrNull(builtAt)]
    }
}
