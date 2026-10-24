import Foundation

/// Motif du refus d'un en-tête de requête. Le routeur répond 400 à chacun.
public enum ParseError: Error, Equatable {
    /// Ligne de requête absente, ou autre chose que `MÉTHODE SP cible SP version`.
    case malformedRequestLine
    /// Version autre que `HTTP/1.1` ou `HTTP/1.0`.
    case unsupportedVersion
    /// Méthode qui n'est pas faite de lettres majuscules ASCII (`get` est refusée).
    case invalidMethod
    /// Cible hors forme d'origine, caractère non imprimable, encodage `%` invalide,
    /// clé de requête vide ou en double.
    case invalidTarget
    /// HTTP/1.1 sans en-tête `Host`, ou avec un `Host` vide.
    case missingHost
    /// Ligne d'en-tête sans deux-points, nom invalide, valeur avec caractère de contrôle,
    /// `\r` ou `\n` isolé, ligne repliée, valeur non UTF-8, en-tête d'accès en double
    /// (`RequestParser.singletonHeaders`).
    case malformedHeader
}

/// Analyse stricte de l'en-tête d'une requête HTTP (sans le corps).
///
/// Règles (RFC 9112, appliquée sans tolérance) :
/// - lignes séparées par `\r\n` uniquement ; un `\r` ou un `\n` isolé est refusé ;
/// - ligne de requête en exactement trois éléments séparés par une seule espace ;
/// - méthode en lettres majuscules ASCII ; le routeur choisit ensuite entre 404 et 405 ;
/// - version `HTTP/1.1` ou `HTTP/1.0` ; en HTTP/1.1, `Host` obligatoire et non vide ;
/// - jamais en double : `Host`, `Origin`, `Sec-Fetch-Site`, `X-Auth-Token`, `Authorization`
///   (deux lectures possibles d'un même en-tête, par un relais et par le daemon) ; ailleurs,
///   le dernier gagne ;
/// - cible en forme d'origine (`/…`), caractères ASCII imprimables seulement, sans `#` ;
/// - requête (`?…`) décodée strictement : `%` suivi de deux chiffres hexadécimaux, UTF-8
///   valide, aucun caractère de contrôle après décodage, `+` littéral, clés non vides et
///   uniques ;
/// - le chemin reste brut (non décodé), mais ses `%` doivent être bien formés.
///
/// Écarts voulus, plus stricts que la RFC (qui admet ou conseille d'ignorer ces cas) :
/// - la forme absolue de la cible (`http://hôte/…`) est refusée, seule la forme d'origine passe ;
/// - une ligne vide avant la ligne de requête est refusée, au lieu d'être ignorée ;
/// - un `\n` seul comme fin de ligne est refusé, seul `\r\n` sépare les lignes.
///
/// L'en-tête peut se terminer ou non par `\r\n\r\n` ; ce qui suit cette fin est ignoré.
/// Aucune limite de taille ici : l'adaptateur borne déjà l'en-tête.
/// `peer` et `peerIsLoopback` sont à renseigner par l'appelant.
public enum RequestParser {
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let sp: UInt8 = 0x20
    private static let htab: UInt8 = 0x09

    /// En-têtes dont dépend la politique d'accès : un doublon est refusé (400), en minuscules.
    public static let singletonHeaders: Set<String> = ["host", "origin", "sec-fetch-site", "x-auth-token", "authorization"]

    public static func parse(head: Data) -> Result<HTTPRequest, ParseError> {
        var lines = splitLines(cutAtEndOfHead([UInt8](head)))
        // Une seule fin de ligne finale, sans ligne vide derrière, est tolérée.
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }

        var request = HTTPRequest()
        if let error = parseRequestLine(lines[0], into: &request) { return .failure(error) }

        for line in lines.dropFirst() {
            guard let (name, value) = parseHeaderLine(line) else { return .failure(.malformedHeader) }
            if singletonHeaders.contains(name), request.headers[name] != nil { return .failure(.malformedHeader) }
            request.headers[name] = value
        }

        if request.version == "HTTP/1.1", (request.headers["host"] ?? "").isEmpty {
            return .failure(.missingHost)
        }
        return .success(request)
    }

    // MARK: - Lignes

    /// Garde ce qui précède le premier `\r\n\r\n` (tout, s'il est absent).
    private static func cutAtEndOfHead(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == cr, bytes[i + 1] == lf, bytes[i + 2] == cr, bytes[i + 3] == lf { return bytes[..<i] }
            i += 1
        }
        return bytes[...]
    }

    /// Découpe sur `\r\n` seulement : un `\r` ou un `\n` isolé reste dans sa ligne, où il
    /// provoque un refus. Renvoie toujours au moins une ligne (éventuellement vide).
    private static func splitLines(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] == cr, i + 1 < bytes.endIndex, bytes[i + 1] == lf {
                lines.append(bytes[start..<i])
                i += 2
                start = i
            } else {
                i += 1
            }
        }
        lines.append(bytes[start..<bytes.endIndex])
        return lines
    }

    // MARK: - Ligne de requête

    /// Remplit `method`, `target`, `path`, `version` et `query`, ou renvoie le motif du refus.
    private static func parseRequestLine(_ line: ArraySlice<UInt8>, into request: inout HTTPRequest) -> ParseError? {
        let parts = line.split(separator: sp, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), !line.contains(cr), !line.contains(lf) else {
            return .malformedRequestLine
        }

        let method = parts[0], target = parts[1], version = parts[2]
        guard method.allSatisfy({ (0x41...0x5A).contains($0) }) else { return .invalidMethod }

        let versionText = String(decoding: version, as: UTF8.self)
        guard versionText == "HTTP/1.1" || versionText == "HTTP/1.0" else { return .unsupportedVersion }

        guard let (path, query) = parseTarget(target) else { return .invalidTarget }

        request.method = String(decoding: method, as: UTF8.self)
        request.target = String(decoding: target, as: UTF8.self)
        request.path = path
        request.version = versionText
        request.query = query
        return nil
    }

    private static func parseTarget(_ target: ArraySlice<UInt8>) -> (String, [String: String])? {
        guard target.first == UInt8(ascii: "/"),
              target.allSatisfy({ (0x21...0x7E).contains($0) && $0 != UInt8(ascii: "#") }) else { return nil }

        var pathBytes = target
        var query: [String: String] = [:]
        if let questionMark = target.firstIndex(of: UInt8(ascii: "?")) {
            pathBytes = target[..<questionMark]
            for pair in target[(questionMark + 1)...].split(separator: UInt8(ascii: "&")) {
                let kv = pair.split(separator: UInt8(ascii: "="), maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = percentDecode(kv[0]), !key.isEmpty,
                      let value = kv.count > 1 ? percentDecode(kv[1]) : "",
                      query[key] == nil else { return nil }
                query[key] = value
            }
        }
        guard percentDecode(pathBytes) != nil else { return nil }
        return (String(decoding: pathBytes, as: UTF8.self), query)
    }

    /// Décodage `%XX` strict ; `+` reste littéral. `nil` si un `%` est mal formé, si le
    /// résultat n'est pas de l'UTF-8 ou s'il contient un caractère de contrôle (C0, DEL, C1).
    private static func percentDecode(_ bytes: ArraySlice<UInt8>) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] == UInt8(ascii: "%") {
                guard i + 2 < bytes.endIndex, let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) else {
                    return nil
                }
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        guard let text = utf8String(out[...]), !text.unicodeScalars.contains(where: isControl) else { return nil }
        return text
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    /// C0, DEL et C1.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Décodage UTF-8 validant (`nil` si les octets ne sont pas de l'UTF-8 bien formé).
    private static func utf8String(_ bytes: ArraySlice<UInt8>) -> String? {
        var scalars = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    // MARK: - En-têtes

    /// `nom: valeur`. Le nom est fait de caractères de jeton (RFC 9110 `tchar`) et collé
    /// aux deux-points (une ligne repliée commence donc par un caractère refusé). La
    /// valeur, débarrassée de ses espaces de bord, ne contient aucun caractère de
    /// contrôle hormis la tabulation et doit être de l'UTF-8 valide.
    private static func parseHeaderLine(_ line: ArraySlice<UInt8>) -> (String, String)? {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let name = line[..<colon]
        guard !name.isEmpty, name.allSatisfy(isTokenChar) else { return nil }

        var value = line[(colon + 1)...]
        while let first = value.first, first == sp || first == htab { value = value.dropFirst() }
        while let last = value.last, last == sp || last == htab { value = value.dropLast() }
        guard let valueText = utf8String(value),
              !valueText.unicodeScalars.contains(where: { $0 != "\t" && isControl($0) }) else { return nil }

        return (String(decoding: name, as: UTF8.self).lowercased(), valueText)
    }

    private static func isTokenChar(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}
