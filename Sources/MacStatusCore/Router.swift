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

/// Routage des requêtes HTTP. Caractérisation du comportement historique : aucune
/// règle de sécurité nouvelle ici (voir les tâches suivantes du plan).
public final class Router {
    private let config: Config
    private let engine: EngineFacade

    public init(config: Config, engine: EngineFacade) {
        self.config = config
        self.engine = engine
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return .text("method not allowed", status: 405)
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
