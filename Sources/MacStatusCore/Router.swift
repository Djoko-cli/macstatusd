import Foundation

/// Ce que le routeur demande au moteur. `EngineRunner` l'adopte côté exécutable ;
/// les tests y mettent un faux. `statusSnapshot()` et `currentState` bloquent le
/// temps d'une lecture sur la file du moteur : ne jamais les appeler depuis cette file.
public protocol EngineFacade: AnyObject {
    var currentState: Bool { get }
    func statusSnapshot() -> [String: Any]
    /// Commandes HomeKit. `peer` : l'adresse du client qui les envoie, pour le journal du moteur seulement.
    func requestOff(peer: String)
    func requestOn(peer: String)
    func resync()
    /// Vrai une fois l'arrêt commencé : le moteur n'agit plus, le routeur répond 503 aux commandes.
    /// Lecture sans verrou de file ; `false` par défaut (faux moteurs des tests).
    var isShuttingDown: Bool { get }
}

extension EngineFacade {
    public var isShuttingDown: Bool { false }
}

/// Routage des requêtes HTTP, dans cet ordre :
/// 1. 400 pour toute requête refusée par l'analyseur ;
/// 2. 404 pour un chemin inconnu, quelle que soit la méthode, sans autre contrôle : la même
///    réponse sort pour tout le monde ;
/// 2 bis. en mode dégradé (config `.invalid`), 503 `config invalide` pour les commandes et
///    `/health`, pour tout le monde et avant tout autre contrôle : aucune commande n'atteint le
///    moteur, et la supervision voit la panne. Les lectures continuent ci-dessous, soumises à la
///    politique d'accès, et `/status` y ajoute `config_error` ;
/// 3. 429 pour un pair interdit par le traqueur des échecs (`/health` compris) ; le pair y est
///    compté par `peerIdentity` (une IPv6 par son /64, Ruling R29) ;
/// 4. `AccessPolicy.decide` : un refus donne 401, 403 ou 405 (avec `Allow`) ; un 401 ou un 403
///    compte comme un échec du pair (10 en 60 s : interdit pendant 60 s) ;
/// 5. 405 avec `Allow` pour `/health` demandé autrement qu'en GET ou HEAD ;
/// 5 bis. 503 `arrêt en cours` pour une commande autorisée reçue pendant l'arrêt du daemon (le moteur
///    est verrouillé : elle n'aurait aucun effet) ; les lectures et `/health` restent servies ;
/// 6. 429 pour une commande autorisée quand le seau global des commandes est vide
///    (5 par seconde, rafale de 10) ; les lectures et `/health` n'y passent pas ;
/// 7. la route.
///
/// Journal borné : pour un pair, une ligne au premier refus, une au début de chaque interdiction,
/// puis au plus une par minute (avec le nombre d'échecs). Ces lignes passent en outre par un seau
/// global (rafale de 30, puis une toutes les 2 s), et la ligne suivante dit combien ont été omises ;
/// seule la ligne qui ouvre une interdiction y échappe : elle est toujours écrite, une fois par
/// pair et par interdiction. Le seau des commandes écrit une ligne à son premier refus, puis au plus une par minute.
/// Aucune ligne pour un 429 d'interdiction. Le chemin écrit est celui de la route (`Route`), jamais
/// la cible reçue ; toute autre donnée du client passe par `escapeForLog`.
///
/// Appelé depuis la file série du serveur HTTP ; le seau et le traqueur ont leur propre verrou.
public final class Router {
    /// Méthodes servies par les lectures et `/health`, pour l'en-tête `Allow` des 405.
    public static let allowedMethods = "GET, HEAD"
    /// Méthodes servies par les commandes.
    public static let commandAllowedMethods = "GET"

    /// Seau global des commandes autorisées.
    public static let commandRate = 5.0
    public static let commandBurst = 10
    /// Échecs d'accès tolérés par pair dans la fenêtre, puis durée de l'interdiction.
    public static let failureLimit = 10
    public static let failureWindow = 60.0
    public static let banDuration = 60.0

    private let engine: EngineFacade
    private let policy: AccessPolicy
    /// Raison de l'invalidité de la config (mode dégradé), ou `nil`.
    private let configError: String?
    private let clock: Clock
    private let commandBucket: TokenBucket
    private let failures: AuthFailureTracker
    /// Débit global des lignes de refus d'accès, tous pairs confondus.
    private let refusalLogBucket: TokenBucket

    private let logLock = NSLock()
    private var omittedRefusalLines = 0
    private var lastBucketLogAt: Double?
    private var bucketRefusalsSinceLog = 0

    /// `localNames` : noms du Mac acceptés dans l'en-tête `Host` (par exemple son nom `.local`),
    /// lus une fois au démarrage par l'exécutable. `clock` : horloge du seau et du traqueur.
    /// `origin` : `.invalid` met le routeur en mode dégradé (voir l'étape 2 bis).
    public init(config: Config, engine: EngineFacade, localNames: [String] = [], clock: Clock = SystemClock(),
                origin: ConfigOrigin = .file) {
        self.engine = engine
        if case .invalid(let reason) = origin { configError = reason } else { configError = nil }
        self.policy = AccessPolicy(authToken: config.authToken, allowQueryToken: config.allowQueryToken,
                                   allowedHosts: config.allowedHosts, localNames: localNames)
        self.clock = clock
        self.commandBucket = TokenBucket(rate: Self.commandRate, burst: Self.commandBurst, clock: clock)
        self.failures = AuthFailureTracker(limit: Self.failureLimit, window: Self.failureWindow,
                                           banFor: Self.banDuration, clock: clock)
        self.refusalLogBucket = TokenBucket(rate: 0.5, burst: 30, clock: clock)
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
        if configError != nil, routeClass == .command || routeClass == .health {
            return Self.configInvalid
        }
        let peer = peerIdentity(request.peer)

        if failures.isBanned(peer: peer) { return Self.tooManyRequests }

        if case .deny(let status, let reason) = policy.decide(request) {
            if status == 401 || status == 403 {
                recordFailure(request, route: route, peer: peer, status: status, reason: reason)
            }
            return Self.denial(status: status, routeClass: routeClass)
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            return .methodNotAllowed(allow: Self.allow(for: routeClass))
        }

        if routeClass == .command, engine.isShuttingDown {
            return Self.shuttingDown
        }

        if routeClass == .command, !commandBucket.take() {
            noteBucketRefusal(request, route: route)
            return Self.tooManyRequests
        }

        switch route {
        case .state:
            return .text(engine.currentState ? "1" : "0")

        case .status:
            var snapshot = engine.statusSnapshot()
            if let configError { snapshot["config_error"] = configError }
            return .json(snapshot)

        case .health:
            return .text("OK")

        case .sleep, .off:
            engine.requestOff(peer: request.peer)
            return .text("OK")

        case .wake, .on:
            engine.requestOn(peer: request.peer)
            return .text("OK")

        case .resync:
            engine.resync()
            return .text("OK")
        }
    }

    private static var tooManyRequests: HTTPResponse { .text("too many requests", status: 429) }
    private static var shuttingDown: HTTPResponse { .text("arrêt en cours", status: 503) }
    private static var configInvalid: HTTPResponse { .text("config invalide", status: 503) }

    // MARK: - Journal borné

    /// Note un refus d'accès et l'écrit au journal si le traqueur le demande. Jamais le jeton,
    /// la cible ni les en-têtes : seulement le motif (constante du code), la méthode, la route
    /// (valeur de `Route`, jamais le chemin reçu) et le pair.
    private func recordFailure(_ request: HTTPRequest, route: Route, peer: String, status: Int, reason: String) {
        let result = failures.recordFailure(peer: peer)
        guard result.shouldLog else { return }
        let omitted: Int
        if result.banStarted {
            omitted = takeOmittedRefusalLines()
        } else {
            guard let slot = takeRefusalLogSlot() else { return }
            omitted = slot
        }
        let suffix = omitted > 0 ? " (\(omitted) ligne(s) de refus omise(s))" : ""
        if result.banned {
            logWarn("HTTP pair \(Self.peerForLog(request.peer, key: peer)) interdit pendant \(Int(Self.banDuration)) s : "
                    + "\(Self.failureCount(result.count)) en \(Int(Self.failureWindow)) s, dernier refus \(status) "
                    + "(\(escapeForLog(reason))) sur \(route.rawValue)\(suffix)")
        } else {
            logWarn("HTTP refusée \(status) (\(escapeForLog(reason))) : \(loggableMethod(request.method)) "
                    + "\(route.rawValue) depuis \(escapeForLog(request.peer)) — "
                    + "\(Self.failureCount(result.count)) en \(Int(Self.failureWindow)) s\(suffix)")
        }
    }

    /// Adresse reçue (échappée), suivie de la clé du traqueur quand elle en diffère (un /64).
    private static func peerForLog(_ address: String, key: String) -> String {
        let escaped = escapeForLog(address)
        return key.hasSuffix("/64") ? "\(escaped) (\(escapeForLog(key)))" : escaped
    }

    private static func failureCount(_ count: Int) -> String { "\(count) échec\(count > 1 ? "s" : "")" }

    /// Une place dans le seau global des lignes de refus : `nil` si la ligne est à omettre (elle
    /// est alors comptée), sinon le nombre de lignes omises depuis la dernière écrite.
    private func takeRefusalLogSlot() -> Int? {
        logLock.lock(); defer { logLock.unlock() }
        guard refusalLogBucket.take() else {
            omittedRefusalLines += 1
            return nil
        }
        defer { omittedRefusalLines = 0 }
        return omittedRefusalLines
    }

    /// Ligne écrite hors du seau global (début d'une interdiction) : rend et remet à zéro le
    /// nombre de lignes omises, qu'elle annonce à son tour.
    private func takeOmittedRefusalLines() -> Int {
        logLock.lock(); defer { logLock.unlock() }
        defer { omittedRefusalLines = 0 }
        return omittedRefusalLines
    }

    /// Commande refusée par le seau : une ligne au premier refus, puis au plus une par minute,
    /// avec le nombre de commandes refusées depuis la précédente. La route, jamais la cible.
    private func noteBucketRefusal(_ request: HTTPRequest, route: Route) {
        logLock.lock()
        bucketRefusalsSinceLog += 1
        let now = clock.monotonic()
        let due = lastBucketLogAt.map { now - $0 >= 60 || now < $0 } ?? true
        let count = bucketRefusalsSinceLog
        if due {
            lastBucketLogAt = now
            bucketRefusalsSinceLog = 0
        }
        logLock.unlock()
        guard due else { return }
        logWarn("HTTP 429 : débit des commandes dépassé (\(Int(Self.commandRate))/s, rafale de \(Self.commandBurst)), "
                + "\(count) commande(s) refusée(s) depuis la dernière ligne ; dernière : "
                + "\(route.rawValue) depuis \(escapeForLog(request.peer))")
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
