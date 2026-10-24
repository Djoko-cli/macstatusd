import Foundation

/// Analyse de l'en-tête d'une requête HTTP (sans le corps).
public enum RequestParser {
    /// Comportement historique, conservé tel quel : tolérant sur les fins de ligne
    /// (`\r\n` ou `\n`), sur la version (ignorée si absente) et sur les lignes
    /// d'en-tête sans deux-points (ignorées). Renvoie `nil` si l'en-tête n'est pas
    /// de l'UTF-8, s'il est vide ou si la ligne de requête a moins de deux éléments.
    /// `peer` et `peerIsLoopback` sont à renseigner par l'appelant.
    public static func parse(head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" })
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var request = HTTPRequest()
        request.method = String(parts[0]).uppercased()

        let target = String(parts[1])
        request.target = target
        request.version = parts.count > 2 ? String(parts[2]) : ""
        if let questionMark = target.firstIndex(of: "?") {
            request.path = String(target[target.startIndex..<questionMark])
            let queryString = String(target[target.index(after: questionMark)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                request.query[String(key).removingPercentEncoding ?? String(key)] =
                    value.removingPercentEncoding ?? value
            }
        } else {
            request.path = target
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            request.headers[name] = value
        }
        return request
    }
}
