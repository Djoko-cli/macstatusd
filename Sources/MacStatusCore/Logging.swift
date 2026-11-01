import Foundation

/// Niveau de journalisation, du plus grave au plus bavard.
public enum LogLevel: Int, Comparable {
    case error = 0, warn = 1, info = 2, debug = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func parse(_ s: String) -> LogLevel {
        switch s.lowercased() {
        case "error": return .error
        case "warn", "warning": return .warn
        case "debug", "trace": return .debug
        default: return .info
        }
    }

    public var tag: String {
        switch self {
        case .error: return "ERROR"
        case .warn: return "WARN "
        case .info: return "INFO "
        case .debug: return "DEBUG"
        }
    }
}

/// Destination des messages de la bibliothèque. L'exécutable branche son journal
/// fichier ; les tests branchent un récepteur en mémoire.
public protocol LogSink: AnyObject {
    func log(_ level: LogLevel, _ message: String)
}

public enum CoreLog {
    /// Récepteur courant. À fixer une fois, au démarrage, avant le premier message.
    /// Sans récepteur (`nil`), les messages sont simplement perdus.
    public static var sink: LogSink?
    /// Les messages DEBUG sont-ils écrits quelque part ? Vrai par défaut (les tests voient tout). L'exécutable le
    /// fixe une fois, avant de démarrer les files, d'après le niveau du journal : coupé, `logDebug` ne construit
    /// même pas son message.
    public static var debugEnabled = true
}

public func logError(_ m: String) { CoreLog.sink?.log(.error, m) }
public func logWarn(_ m: String) { CoreLog.sink?.log(.warn, m) }
public func logInfo(_ m: String) { CoreLog.sink?.log(.info, m) }
/// Message DEBUG. Le texte n'est construit que s'il va quelque part : niveau DEBUG actif (`CoreLog.debugEnabled`)
/// et récepteur branché. Une ligne de faits ou une liste d'écrans ne coûte donc rien en production.
public func logDebug(_ m: @autoclosure () -> String) {
    guard CoreLog.debugEnabled, let sink = CoreLog.sink else { return }
    sink.log(.debug, m())
}

/// Rend une donnée reçue (chemin, ligne de requête…) sûre pour le journal.
///
/// Deviennent `\u{..}` (hexadécimal en majuscules, au moins deux chiffres) :
/// - les caractères de contrôle C0 sauf la tabulation, `U+007F`–`U+009F`, `U+2028` et `U+2029` ;
/// - les marques bidirectionnelles `U+202A`–`U+202E` et `U+2066`–`U+2069`, qui réordonnent
///   l'affichage d'une ligne dans un terminal ou un éditeur.
///
/// L'antislash littéral est doublé (`\` devient `\\`) : un `\u{0A}` reçu tel quel ne peut donc pas
/// passer pour l'échappement d'une vraie fin de ligne. Une donnée ne peut ni couper une ligne du
/// journal, ni y glisser une séquence de terminal, ni tromper le lecteur sur ce qui a été reçu.
/// Le résultat garde au plus `limit` caractères, suivis de `…` s'il a fallu couper ; un
/// échappement n'est jamais coupé en deux.
public func escapeForLog(_ s: String, limit: Int = 200) -> String {
    var out = String.UnicodeScalarView()
    var count = 0
    for scalar in s.unicodeScalars {
        let v = scalar.value
        let escaped = (v < 0x20 && v != 0x09) || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029
            || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
        let piece: String.UnicodeScalarView
        if escaped {
            piece = "\\u{\(String(format: "%02X", v))}".unicodeScalars
        } else if v == 0x5C {
            piece = "\\\\".unicodeScalars
        } else {
            piece = String(scalar).unicodeScalars
        }
        guard count + piece.count <= limit else {
            out.append("…")
            return String(out)
        }
        out.append(contentsOf: piece)
        count += piece.count
    }
    return String(out)
}

// MARK: - URL configurées

/// Rend une URL configurée (ou lue d'un message d'erreur) sûre pour le journal et pour `/status`.
///
/// - le mot de passe d'URL devient `***` ; un identifiant seul (`https://<jeton>@hôte`) devient `***` ;
/// - toute la partie requête devient `<masqué>` (`?accessoryId=…&state=…` donne `?<masqué>`), comme
///   le fragment ;
/// - le segment qui suit `/api/webhook/` devient `<masqué>` : c'est l'identifiant secret du webhook
///   de Home Assistant ;
/// - le schéma, l'hôte, le port et le reste du chemin restent visibles, pour le diagnostic ;
/// - une chaîne qui ne se lit pas comme une URL (sans schéma ni hôte, avec des espaces…) donne
///   `<url invalide>` : on ne sait pas ce qu'elle contient, rien n'en est gardé.
public func redactURL(_ s: String) -> String {
    guard let parts = URLComponents(string: s),
          let scheme = parts.scheme, !scheme.isEmpty,
          let host = parts.host, !host.isEmpty else {
        return "<url invalide>"
    }
    var out = scheme + "://"
    if let user = parts.user, !user.isEmpty {
        out += parts.password == nil ? "***@" : "\(user):***@"
    } else if parts.password != nil {
        out += ":***@"
    }
    out += host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    if let port = parts.port { out += ":\(port)" }

    // On cherche « api », « webhook », puis l'identifiant, sans tenir compte de la casse des deux premiers.
    var segments = parts.percentEncodedPath.components(separatedBy: "/")
    if let k = segments.indices.first(where: { k in
        k + 2 < segments.count && segments[k].lowercased() == "api" && segments[k + 1].lowercased() == "webhook"
    }) {
        segments[k + 2] = "<masqué>"
    }
    out += segments.joined(separator: "/")
    if parts.percentEncodedQuery != nil { out += "?<masqué>" }
    if parts.percentEncodedFragment != nil { out += "#<masqué>" }
    return out
}

// MARK: - Requêtes reçues

/// Méthodes HTTP que le journal reproduit telles quelles.
private let loggableMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE", "CONNECT"]

/// Méthode d'une requête telle qu'elle peut entrer au journal : une méthode HTTP connue, sinon `autre`.
/// La méthode est une donnée du client (des lettres majuscules, sans autre contrainte de l'analyseur) :
/// elle pourrait porter un jeton en capitales. Liste blanche, donc, au lieu d'une simple coupe.
func loggableMethod(_ method: String) -> String {
    loggableMethods.contains(method) ? method : "autre"
}

/// Chemin d'une requête tel qu'il peut entrer au journal : une route servie (`Route`), sinon
/// `<inconnu>`. Un chemin inconnu est une donnée du client, qui peut porter le jeton (`/wake%3Ftoken=…`,
/// `/<jeton>`) : il n'est jamais écrit.
func loggablePath(_ path: String) -> String {
    Route(rawValue: path)?.rawValue ?? "<inconnu>"
}

/// Ligne DEBUG d'une requête reçue par l'adaptateur réseau.
/// - Acceptée par l'analyseur : méthode (`loggableMethod`) et chemin s'il est une route connue, sinon
///   `<inconnu>` (`loggablePath`).
/// - Refusée : le motif (`ParseError`), la méthode seulement si elle est valide (lettres
///   majuscules ASCII suivies d'une espace) et connue (`loggableMethod`, sinon `autre`), la longueur de la ligne de requête en
///   octets et le pair. Ni la cible, ni la ligne reçue : une première ligne peut être un en-tête
///   (`X-Auth-Token: …`) ou une cible que nulle coupe ne reconnaît.
/// Le jeton ne peut donc y figurer, ni par la cible, ni par un en-tête.
public func logReceivedRequest(_ parsed: Result<HTTPRequest, ParseError>, head: Data, peer: String) {
    switch parsed {
    case .success(let request):
        logDebug("HTTP \(loggableMethod(request.method)) \(loggablePath(request.path)) "
                 + "depuis \(escapeForLog(peer))")
    case .failure(let error):
        var firstLine = head.prefix { $0 != 0x0A }
        if firstLine.last == 0x0D { firstLine = firstLine.dropLast() }
        let methodBytes = firstLine.prefix { $0 != 0x20 }
        let methodValid = !methodBytes.isEmpty && methodBytes.count < firstLine.count
            && methodBytes.allSatisfy { (0x41...0x5A).contains($0) }
        let method = methodValid ? loggableMethod(String(decoding: methodBytes, as: UTF8.self)) : "invalide"
        logDebug("HTTP refusée (\(error)) : méthode \(method), ligne de requête de \(firstLine.count) octets, "
                 + "depuis \(escapeForLog(peer))")
    }
}
