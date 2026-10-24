import Foundation

/// Requête HTTP analysée. Les noms d'en-têtes sont en minuscules.
public struct HTTPRequest {
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
    /// du `NWEndpoint`, jamais à partir d'une chaîne. Le routeur ne s'en sert pas encore.
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

    public var reasonPhrase: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}
