import Foundation

/// Classe d'une route, qui fixe les règles d'accès qui s'y appliquent.
public enum RouteClass: Equatable {
    /// `/health` : toujours servi, pour la supervision.
    case health
    /// `/state`, `/status` : lectures.
    case read
    /// `/sleep`, `/off`, `/wake`, `/on`, `/resync` : commandes qui agissent sur le Mac.
    case command
    /// Tout autre chemin : 404 pour tout le monde.
    case unknown

    /// Classe d'un chemin brut, comparé tel quel (sensible à la casse, sans `/` final).
    public static func classify(path: String) -> RouteClass {
        Route(rawValue: path)?.routeClass ?? .unknown
    }
}

/// Table unique des routes servies : le chemin (valeur brute) et sa classe. Le routeur et la
/// politique d'accès en dérivent tous deux ; ajouter une route, c'est ajouter un cas ici, et le
/// compilateur désigne alors le routeur à compléter.
public enum Route: String, CaseIterable {
    case health = "/health"
    case state = "/state"
    case status = "/status"
    case sleep = "/sleep"
    case off = "/off"
    case wake = "/wake"
    case on = "/on"
    case resync = "/resync"

    public var routeClass: RouteClass {
        switch self {
        case .health: return .health
        case .state, .status: return .read
        case .sleep, .off, .wake, .on, .resync: return .command
        }
    }
}

/// Verdict de `AccessPolicy.decide`. `reason` est une constante courte du code, faite pour
/// le journal, jamais une donnée reçue.
public enum AccessDecision: Equatable {
    case allow
    case deny(status: Int, reason: String)
}

/// Règles d'accès du serveur HTTP. Elles protègent les commandes contre une page web
/// ouverte sur le Mac (requête du navigateur vers 127.0.0.1) et contre le DNS rebinding
/// (nom de l'attaquant qui se met à pointer vers le Mac), tout en laissant passer l'appel
/// réel de Home Assistant : `GET /wake`, `Host: <IPv4 du Mac>:9090`, `X-Auth-Token`.
///
/// `decide` applique ces règles, dans l'ordre :
/// 1. `.health` → `allow` ;
/// 2. `Host` (sans le port ni les crochets IPv6) : littéral IPv4 ou IPv6 (hors `0.0.0.0` et `::`), `localhost`,
///    un des `localNames` ou un des `allowedHosts`, sans casse ; sinon 403 `host`.
///    Un `Host` absent (HTTP/1.0) passe ; un `Host` vide ou mal formé est refusé ;
/// 3. en-tête `Origin` présent, ou `Sec-Fetch-Site` présent et autre que `none` → 403 `origin` ;
/// 4. méthode : GET seulement pour une commande, GET ou HEAD pour une lecture ; sinon 405 `method` ;
/// 5. jeton, pris dans le premier présent de : `X-Auth-Token`, `Authorization: Bearer <jeton>`
///    (schéma sans casse), `?token=` si `allowQueryToken`.
///    - Sans jeton configuré : `allow` si le pair est en boucle locale, sinon 403 `no-token-configured`.
///    - Avec jeton : une commande exige le bon jeton (sinon 401 `token`) ; une lecture passe
///      en boucle locale ou avec le bon jeton (sinon 401 `token`).
///
/// Un chemin `.unknown` n'est pas censé arriver ici (le routeur répond 404 avant) ; s'il
/// arrive, il est refusé (404 `unknown`).
public struct AccessPolicy {
    private let authToken: String
    private let allowQueryToken: Bool
    /// `localhost`, les noms du Mac et les hôtes autorisés, en minuscules.
    private let acceptedNames: Set<String>

    public init(authToken: String, allowQueryToken: Bool, allowedHosts: [String], localNames: [String]) {
        self.authToken = authToken
        self.allowQueryToken = allowQueryToken
        self.acceptedNames = Set((["localhost"] + allowedHosts + localNames).map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    public func decide(_ request: HTTPRequest) -> AccessDecision {
        let routeClass = RouteClass.classify(path: request.path)
        switch routeClass {
        case .health: return .allow
        case .unknown: return .deny(status: 404, reason: "unknown")
        case .read, .command: break
        }

        if let host = request.headers["host"], !isAcceptedHost(host) {
            return .deny(status: 403, reason: "host")
        }

        if request.headers["origin"] != nil {
            return .deny(status: 403, reason: "origin")
        }
        if let site = request.headers["sec-fetch-site"], site.lowercased() != "none" {
            return .deny(status: 403, reason: "origin")
        }

        let methodAllowed = routeClass == .command
            ? request.method == "GET"
            : request.method == "GET" || request.method == "HEAD"
        guard methodAllowed else { return .deny(status: 405, reason: "method") }

        guard !authToken.isEmpty else {
            return request.peerIsLoopback ? .allow : .deny(status: 403, reason: "no-token-configured")
        }
        let tokenMatches = providedToken(request).map { constantTimeEquals($0, authToken) } ?? false
        if tokenMatches || (routeClass == .read && request.peerIsLoopback) { return .allow }
        return .deny(status: 401, reason: "token")
    }

    /// Premier jeton présent : `X-Auth-Token`, puis `Authorization: Bearer`, puis `?token=`
    /// (seulement si l'option est active). Un `Authorization` d'un autre schéma est ignoré.
    private func providedToken(_ request: HTTPRequest) -> String? {
        if let token = request.headers["x-auth-token"] { return token }
        if let authorization = request.headers["authorization"], let token = Self.bearerToken(authorization) {
            return token
        }
        if allowQueryToken, let token = request.query["token"] { return token }
        return nil
    }

    /// `Bearer <jeton>` : schéma sans casse, une espace au moins, jeton non vide.
    /// L'analyseur a déjà ôté les espaces de bord de la valeur.
    static func bearerToken(_ value: String) -> String? {
        guard let space = value.firstIndex(of: " "), value[..<space].lowercased() == "bearer" else { return nil }
        let token = value[space...].drop { $0 == " " }
        return token.isEmpty ? nil : String(token)
    }

    // MARK: - Host

    /// Vrai si `Host` désigne le Mac par une adresse littérale ou par un nom connu.
    /// Aucune résolution DNS : un nom inconnu est refusé, quelle que soit son adresse.
    /// Une adresse non spécifiée (`0.0.0.0`, `[::]`) ne désigne aucun hôte : refusée.
    func isAcceptedHost(_ value: String) -> Bool {
        guard let host = Self.hostWithoutPort(value) else { return false }
        let specified: ([UInt8]) -> Bool = { $0.contains { $0 != 0 } }
        switch host {
        case .ipv6Literal(let text):
            return ipv6Bytes(text).map(specified) ?? false
        case .name(let text):
            if let bytes = ipv4Bytes(text) { return specified(bytes) }
            return acceptedNames.contains(text.lowercased())
        }
    }

    enum HostPart: Equatable {
        /// Contenu des crochets de `[…]`.
        case ipv6Literal(String)
        /// Nom ou IPv4, sans deux-points.
        case name(String)
    }

    /// Valide `Host` comme `uri-host[:port]` et sépare l'hôte du port (`nil` si la forme est
    /// mauvaise). Port facultatif, un seul, fait de chiffres seulement (éventuellement vide,
    /// comme le permet la RFC 3986). Une IPv6 n'est admise qu'entre crochets : un hôte non
    /// crocheté contenant `:` est refusé, comme un hôte vide ou un caractère hors nom DNS.
    static func hostWithoutPort(_ value: String) -> HostPart? {
        func isPort<S: StringProtocol>(_ s: S) -> Bool { s.allSatisfy { $0.isASCII && $0.isNumber } }

        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let inside = value[value.index(after: value.startIndex)..<close]
            let rest = value[value.index(after: close)...]
            guard !inside.isEmpty, rest.isEmpty || (rest.first == ":" && isPort(rest.dropFirst())) else { return nil }
            return .ipv6Literal(String(inside))
        }

        var host = Substring(value)
        if let colon = value.firstIndex(of: ":") {
            host = value[..<colon]
            let port = value[value.index(after: colon)...]
            guard isPort(port) else { return nil }
        }
        // `uri-host` réduit aux noms DNS et aux IPv4 : lettres et chiffres ASCII, `-`, `.`, `_`.
        // Ni espace, ni virgule, ni `@`, ni rien qui ne puisse figurer dans un nom réel.
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
            return nil
        }
        return .name(String(host))
    }
}

// MARK: - Comparaison du jeton

/// Égalité de deux chaînes (octets UTF-8) en temps indépendant de la position de la première
/// différence : tous les octets de la plus longue sont parcourus, et la différence de longueur
/// compte. Seule la longueur maximale peut transparaître dans la durée.
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var difference = UInt(bitPattern: x.count ^ y.count)
    for i in 0..<max(x.count, y.count) {
        let p: UInt8 = i < x.count ? x[i] : 0
        let q: UInt8 = i < y.count ? y[i] : 0
        difference |= UInt(p ^ q)
    }
    return difference == 0
}

// MARK: - Adresses

/// Vrai si l'adresse, donnée par ses octets (4 pour IPv4, 16 pour IPv6, ordre réseau),
/// est une boucle locale : IPv4 127.0.0.0/8, IPv6 `::1`, ou IPv4 mappée `::ffff:127.x.y.z`.
/// Toute autre adresse, et toute autre taille, donne false (Ruling R21).
public func isLoopbackAddress(_ bytes: [UInt8]) -> Bool {
    switch bytes.count {
    case 4:
        return bytes[0] == 127
    case 16:
        let prefix = bytes[0..<10]
        guard prefix.allSatisfy({ $0 == 0 }) else { return false }
        if bytes[10] == 0, bytes[11] == 0 {
            return bytes[12..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
        }
        return bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
    default:
        return false
    }
}

/// Vrai si `bind_address` limite l'écoute à la boucle locale : `localhost`, ou une adresse
/// littérale de boucle locale. Vide (toutes les interfaces), `0.0.0.0`, `::` ou un nom → false.
public func bindAddressIsLoopbackOnly(_ address: String) -> Bool {
    if address.lowercased() == "localhost" { return true }
    if let bytes = ipv4Bytes(address) ?? ipv6Bytes(address) { return isLoopbackAddress(bytes) }
    return false
}

/// Octets d'une IPv4 en notation décimale pointée stricte : quatre nombres de 1 à 3 chiffres,
/// chacun ≤ 255. `nil` pour toute autre forme.
func ipv4Bytes(_ text: String) -> [UInt8]? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var bytes: [UInt8] = []
    for part in parts {
        guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt8(part) else { return nil }
        bytes.append(value)
    }
    return bytes
}

/// Octets d'une IPv6 littérale, selon `inet_pton`. Seuls les chiffres hexadécimaux, `:` et
/// `.` sont admis : le `inet_pton` de macOS accepte aussi une zone (`fe80::1%en0`), refusée ici.
func ipv6Bytes(_ text: String) -> [UInt8]? {
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }) else { return nil }
    var address = in6_addr()
    guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
}
