import Foundation

/// Ce que le routeur demande au moteur. `EngineRunner` l'adopte côté exécutable ;
/// les tests y mettent un faux. `statusSnapshot()` et `currentState` bloquent le
/// temps d'une lecture sur la file du moteur : ne jamais les appeler depuis cette file.
public protocol EngineFacade: AnyObject {
    var currentState: Bool { get }
    func statusSnapshot() -> [String: Any]
    func requestOff(source: String)
    func requestOn(source: String)
    func resync()
}

/// Routage des requêtes HTTP. Depuis la tâche 7 : 400 pour toute requête refusée par
/// l'analyseur, 404 pour un chemin inconnu quelle que soit la méthode, 405 avec `Allow`
/// pour un chemin connu demandé autrement qu'en GET ou HEAD. La politique d'accès
/// (jeton, lectures publiques) reste celle d'origine.
public final class Router {
    /// Méthodes servies, pour l'en-tête `Allow` des 405.
    public static let allowedMethods = "GET, HEAD"
    private static let knownPaths: Set<String> = ["/state", "/status", "/health", "/sleep", "/off", "/wake", "/on", "/resync"]

    private let config: Config
    private let engine: EngineFacade

    public init(config: Config, engine: EngineFacade) {
        self.config = config
        self.engine = engine
    }

    /// Résultat de `RequestParser.parse` : 400 pour toute `ParseError`, sinon routage.
    public func handle(_ parsed: Result<HTTPRequest, ParseError>) -> HTTPResponse {
        switch parsed {
        case .success(let request): return handle(request)
        case .failure: return .text("bad request", status: 400)
        }
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard Self.knownPaths.contains(request.path) else {
            return .text("not found", status: 404)
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            return .methodNotAllowed(allow: Self.allowedMethods)
        }

        switch request.path {
        case "/state":
            return .text(engine.currentState ? "1" : "0")

        case "/status":
            return .json(engine.statusSnapshot())

        case "/health":
            return .text("OK")

        case "/sleep", "/off":
            guard isAuthorized(request) else { return .text("unauthorized", status: 401) }
            engine.requestOff(source: request.peer)
            return .text("OK")

        case "/wake", "/on":
            guard isAuthorized(request) else { return .text("unauthorized", status: 401) }
            engine.requestOn(source: request.peer)
            return .text("OK")

        case "/resync":
            guard isAuthorized(request) else { return .text("unauthorized", status: 401) }
            engine.resync()
            return .text("OK")

        default:
            return .text("not found", status: 404)
        }
    }

    /// Comportement historique : sans jeton configuré, tout passe ; sinon le jeton
    /// vient de `?token=` ou, à défaut, de `X-Auth-Token`.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard !config.authToken.isEmpty else { return true }
        let provided = request.query["token"] ?? request.headers["x-auth-token"] ?? ""
        guard provided.utf8.count == config.authToken.utf8.count else { return false }
        return provided == config.authToken
    }
}
