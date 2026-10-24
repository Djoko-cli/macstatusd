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

/// Routage des requêtes HTTP, dans cet ordre :
/// 1. 400 pour toute requête refusée par l'analyseur ;
/// 2. 404 pour un chemin inconnu, quelle que soit la méthode, sans autre contrôle : la même
///    réponse sort pour tout le monde ;
/// 3. `AccessPolicy.decide` : un refus donne 401, 403 ou 405 (avec `Allow`) et une ligne WARN ;
/// 4. 405 avec `Allow` pour `/health` demandé autrement qu'en GET ou HEAD ;
/// 5. la route.
public final class Router {
    /// Méthodes servies par les lectures et `/health`, pour l'en-tête `Allow` des 405.
    public static let allowedMethods = "GET, HEAD"
    /// Méthodes servies par les commandes.
    public static let commandAllowedMethods = "GET"

    private let engine: EngineFacade
    private let policy: AccessPolicy

    /// `localNames` : noms du Mac acceptés dans l'en-tête `Host` (par exemple son nom `.local`),
    /// lus une fois au démarrage par l'exécutable.
    public init(config: Config, engine: EngineFacade, localNames: [String] = []) {
        self.engine = engine
        self.policy = AccessPolicy(authToken: config.authToken, allowQueryToken: config.allowQueryToken,
                                   allowedHosts: config.allowedHosts, localNames: localNames)
    }

    /// Résultat de `RequestParser.parse` : 400 pour toute `ParseError`, sinon routage.
    public func handle(_ parsed: Result<HTTPRequest, ParseError>) -> HTTPResponse {
        switch parsed {
        case .success(let request): return handle(request)
        case .failure: return .text("bad request", status: 400)
        }
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard let route = Route(rawValue: request.path) else { return .text("not found", status: 404) }
        let routeClass = route.routeClass

        if case .deny(let status, let reason) = policy.decide(request) {
            // Jamais le jeton ni les en-têtes : seulement le motif, constante du code.
            logWarn("HTTP refusée \(status) (\(escapeForLog(reason))) : \(escapeForLog(request.method, limit: 16)) "
                    + "\(escapeForLog(request.path)) depuis \(escapeForLog(request.peer))")
            return Self.denial(status: status, routeClass: routeClass)
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            return .methodNotAllowed(allow: Self.allow(for: routeClass))
        }

        switch route {
        case .state:
            return .text(engine.currentState ? "1" : "0")

        case .status:
            return .json(engine.statusSnapshot())

        case .health:
            return .text("OK")

        case .sleep, .off:
            engine.requestOff(source: request.peer)
            return .text("OK")

        case .wake, .on:
            engine.requestOn(source: request.peer)
            return .text("OK")

        case .resync:
            engine.resync()
            return .text("OK")
        }
    }

    private static func allow(for routeClass: RouteClass) -> String {
        routeClass == .command ? commandAllowedMethods : allowedMethods
    }

    private static func denial(status: Int, routeClass: RouteClass) -> HTTPResponse {
        switch status {
        case 401: return .text("unauthorized", status: 401)
        case 404: return .text("not found", status: 404)
        case 405: return .methodNotAllowed(allow: allow(for: routeClass))
        default: return .text("forbidden", status: 403)
        }
    }
}
