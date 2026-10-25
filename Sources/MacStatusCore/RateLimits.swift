import Foundation

// MARK: - Seau à jetons

/// Seau à jetons : `burst` jetons au plus, rechargés à `rate` par seconde d'horloge monotone.
/// `take()` prend un jeton s'il en reste un entier. Une horloge qui recule (tests) ne crée
/// aucun jeton. Protégé par un verrou : appelable depuis n'importe quelle file.
public final class TokenBucket {
    private let rate: Double
    private let burst: Double
    private let clock: Clock
    private let lock = NSLock()
    private var tokens: Double
    private var last: Double

    public init(rate: Double, burst: Int, clock: Clock) {
        self.rate = max(0, rate)
        self.burst = Double(max(1, burst))
        self.clock = clock
        self.tokens = self.burst
        self.last = clock.monotonic()
    }

    public func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock.monotonic()
        // `last` ne recule jamais : seul le temps au-delà du plus grand instant vu recharge.
        if now > last {
            tokens = min(burst, tokens + (now - last) * rate)
            last = now
        }
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

// MARK: - Traqueur des échecs d'accès

/// Compte les refus d'accès (401, 403) par pair, sur une fenêtre glissante, et interdit un pair
/// qui en accumule `limit` en `window` secondes, pendant `banFor` secondes. Les échecs d'avant
/// une interdiction sont oubliés quand elle commence.
///
/// Journal : `shouldLog` vaut vrai au plus une fois par pair et par minute (`logPeriod`), et
/// toujours au début d'une interdiction (`banStarted`).
///
/// Mémoire bornée : un pair dont la fenêtre, la période de journal et l'interdiction sont
/// écoulées est oublié (balayage au plus une fois par minute, ou quand la table est pleine) ;
/// la table ne dépasse jamais `maxPeers` entrées. Pour faire place, on évince d'abord le pair
/// non interdit à l'activité la plus ancienne ; si tous sont interdits, celui dont l'interdiction
/// finit le plus tôt. Un flot de nouveaux pairs ne lève donc jamais une interdiction tant qu'il
/// reste un pair non interdit à évincer. Protégé par un verrou.
///
/// La clé d'un pair est celle de `peerIdentity` (le /64 pour une IPv6), à calculer par
/// l'appelant.
public final class AuthFailureTracker {
    public static let logPeriod: Double = 60

    private struct Entry {
        /// Instants des échecs encore dans la fenêtre, du plus ancien au plus récent (≤ `limit`).
        var failures: [Double] = []
        var bannedUntil: Double?
        var lastLoggedAt: Double?
        var lastActivity: Double
    }

    private let limit: Int
    private let window: Double
    private let banFor: Double
    private let maxPeers: Int
    private let clock: Clock
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var lastSweep: Double

    public init(limit: Int, window: Double, banFor: Double, clock: Clock, maxPeers: Int = 1024) {
        self.limit = max(1, limit)
        self.window = window
        self.banFor = banFor
        self.maxPeers = max(1, maxPeers)
        self.clock = clock
        self.lastSweep = clock.monotonic()
    }

    /// Nombre de pairs suivis (pour les tests).
    var peerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func isBanned(peer: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = entries[peer]?.bannedUntil else { return false }
        return clock.monotonic() < until
    }

    /// Note un échec. `banned` : le pair est interdit après cet échec ; `banStarted` : cet échec
    /// ouvre l'interdiction ; `count` : échecs dans la fenêtre, celui-ci compris ; `shouldLog` :
    /// cette ligne de journal est à écrire.
    public func recordFailure(peer: String) -> (banned: Bool, banStarted: Bool, shouldLog: Bool, count: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = clock.monotonic()
        sweepIfNeeded(now: now, adding: entries[peer] == nil)

        var entry = entries[peer] ?? Entry(lastActivity: now)
        entry.lastActivity = now
        if let until = entry.bannedUntil, now >= until { entry.bannedUntil = nil }
        entry.failures.removeAll { now - $0 >= window }
        entry.failures.append(now)
        if entry.failures.count > limit { entry.failures.removeFirst(entry.failures.count - limit) }
        let count = entry.failures.count

        var shouldLog = entry.lastLoggedAt.map { now - $0 >= Self.logPeriod } ?? true
        var banned = entry.bannedUntil != nil
        var banStarted = false
        if !banned, count >= limit {
            banned = true
            banStarted = true
            entry.bannedUntil = now + banFor
            entry.failures.removeAll()
            shouldLog = true
        }
        if shouldLog { entry.lastLoggedAt = now }
        entries[peer] = entry
        return (banned, banStarted, shouldLog, count)
    }

    /// Oublie les pairs échus au plus une fois par minute, ou quand la table est pleine et qu'un
    /// pair arrive ; puis, si elle l'est toujours, évince un pair (voir `evictionCandidate`).
    private func sweepIfNeeded(now: Double, adding: Bool) {
        let full = adding && entries.count >= maxPeers
        if full || now - lastSweep >= Self.logPeriod || now < lastSweep {
            let horizon = max(window, Self.logPeriod)
            entries = entries.filter { _, entry in
                let banActive = entry.bannedUntil.map { now < $0 } ?? false
                return banActive || now - entry.lastActivity < horizon
            }
            lastSweep = now
        }
        if adding, entries.count >= maxPeers, let victim = evictionCandidate(now: now) {
            entries.removeValue(forKey: victim)
        }
    }

    /// Le pair non interdit à l'activité la plus ancienne ; à défaut (tous interdits), celui dont
    /// l'interdiction finit le plus tôt.
    private func evictionCandidate(now: Double) -> String? {
        func banEnd(_ entry: Entry) -> Double? { entry.bannedUntil.flatMap { now < $0 ? $0 : nil } }
        let free = entries.filter { banEnd($0.value) == nil }
        if let oldest = free.min(by: { $0.value.lastActivity < $1.value.lastActivity }) { return oldest.key }
        return entries.min(by: { (banEnd($0.value) ?? now) < (banEnd($1.value) ?? now) })?.key
    }
}

// MARK: - Identité du pair

/// Adresse d'un pair, sans le port ni la zone IPv6, sous forme canonique. Une IPv4 mappée
/// (`::ffff:a.b.c.d`, sous toute écriture) devient `a.b.c.d` ; une IPv6 prend sa forme canonique
/// (`inet_ntop`, minuscules). Une chaîne qui n'est pas une adresse est gardée telle quelle,
/// bornée à 128 caractères. Sert à `bind_address` ; pour les limites, voir `peerIdentity`.
public func canonicalAddress(_ peer: String) -> String {
    var text = Substring(peer)
    if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
        text = text[text.index(after: text.startIndex)..<close]
    } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
        text = text[..<colon]   // a.b.c.d:port
    }
    if let percent = text.firstIndex(of: "%") { text = text[..<percent] }
    let address = String(text)

    if let v4 = ipv4Bytes(address) { return v4.map(String.init).joined(separator: ".") }
    if let v6 = ipv6Bytes(address) {
        if v6[0..<10].allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF {
            return v6[12..<16].map(String.init).joined(separator: ".")
        }
        if let text = ipv6Text(v6) { return text }
    }
    return String(peer.prefix(128))
}

/// Clé d'un pair pour les limites (traqueur des échecs, plafond de connexions), Ruling R29.
/// Une IPv6 non mappée compte pour son préfixe /64, zone ôtée (`2001:db8:0:1::/64`) : un hôte
/// du LAN dispose de tout son /64 et peut changer d'adresse à chaque connexion. Une IPv4, une
/// IPv4 mappée et toute autre chaîne gardent `canonicalAddress`. C'est une clé, pas une adresse :
/// un journal écrit l'adresse reçue (échappée), éventuellement suivie de cette clé.
public func peerIdentity(_ peer: String) -> String {
    let address = canonicalAddress(peer)
    guard var v6 = ipv6Bytes(address) else { return address }
    for i in 8..<16 { v6[i] = 0 }
    return ipv6Text(v6).map { $0 + "/64" } ?? address
}

/// Forme canonique (`inet_ntop`) de 16 octets IPv6.
private func ipv6Text(_ bytes: [UInt8]) -> String? {
    var raw = in6_addr()
    withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: bytes) }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
    return String(cString: buffer)
}
