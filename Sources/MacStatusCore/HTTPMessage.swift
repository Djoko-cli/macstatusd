import Foundation

/// Requête HTTP analysée. Les noms d'en-têtes sont en minuscules.
public struct HTTPRequest: Equatable {
    public var method: String
    /// Cible brute de la ligne de requête (chemin et requête), telle que reçue.
    public var target: String
    public var path: String
    public var version: String
    public var query: [String: String]
    public var headers: [String: String]
    /// Adresse du pair, pour le journal.
    public var peer: String
    /// Vrai si le pair est en boucle locale. Calculé par l'adaptateur réseau à partir
    /// du `NWEndpoint`, jamais à partir d'une chaîne (`isLoopbackAddress`). `AccessPolicy`
    /// s'en sert pour les lectures, et pour tout quand aucun jeton n'est configuré.
    public var peerIsLoopback: Bool

    public init(method: String = "GET", target: String = "/", path: String = "/", version: String = "",
                query: [String: String] = [:], headers: [String: String] = [:],
                peer: String = "?", peerIsLoopback: Bool = false) {
        self.method = method
        self.target = target
        self.path = path
        self.version = version
        self.query = query
        self.headers = headers
        self.peer = peer
        self.peerIsLoopback = peerIsLoopback
    }
}

/// Réponse HTTP à écrire. `headers` s'ajoute aux en-têtes fixes de l'adaptateur.
public struct HTTPResponse {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var headers: [String: String]

    public init(status: Int = 200, contentType: String = "text/plain; charset=utf-8",
                body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    public static func text(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    public static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    /// 405, avec l'en-tête `Allow`. `allow` doit être une constante du code
    /// (par exemple `"GET, HEAD"`), jamais une donnée reçue.
    public static func methodNotAllowed(allow: String) -> HTTPResponse {
        var response = HTTPResponse.text("method not allowed", status: 405)
        response.headers["Allow"] = allow
        return response
    }

    /// Ligne de statut et en-têtes, jusqu'à la ligne vide comprise. Les en-têtes fixes
    /// viennent d'abord, puis `headers` triés par nom. Par précaution, un en-tête dont le
    /// nom ou la valeur contient `\r` ou `\n` est écarté : il ne peut pas en injecter d'autres.
    public func serializedHead() -> String {
        var head = "HTTP/1.1 \(status) \(reasonPhrase)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key })
        where !Self.hasLineBreak(name) && !Self.hasLineBreak(value) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return head
    }

    private static func hasLineBreak(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
    }

    public var reasonPhrase: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
