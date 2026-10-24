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
/// toujours au début d'une interdiction.
///
/// Mémoire bornée : un pair dont la fenêtre, la période de journal et l'interdiction sont
/// écoulées est oublié (balayage au plus une fois par minute, ou quand la table est pleine) ;
/// la table ne dépasse jamais `maxPeers` entrées, le pair à l'activité la plus ancienne étant
/// évincé au besoin. Protégé par un verrou.
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

    /// Note un échec. `banned` : le pair est interdit après cet échec ; `count` : échecs dans la
    /// fenêtre, celui-ci compris ; `shouldLog` : cette ligne de journal est à écrire.
    public func recordFailure(peer: String) -> (banned: Bool, shouldLog: Bool, count: Int) {
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
        if !banned, count >= limit {
            banned = true
            entry.bannedUntil = now + banFor
            entry.failures.removeAll()
            shouldLog = true
        }
        if shouldLog { entry.lastLoggedAt = now }
        entries[peer] = entry
        return (banned, shouldLog, count)
    }

    /// Oublie les pairs échus au plus une fois par minute, ou quand la table est pleine et qu'un
    /// pair arrive ; puis, si elle l'est toujours, évince le pair à l'activité la plus ancienne.
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
        if adding, entries.count >= maxPeers,
           let oldest = entries.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}

// MARK: - Identité du pair

/// Clé d'un pair pour les limites : son adresse, sans le port ni la zone IPv6. Une IPv4 mappée
/// (`::ffff:a.b.c.d`, sous toute écriture) devient `a.b.c.d` ; une IPv6 prend sa forme canonique
/// (`inet_ntop`, minuscules). Une chaîne qui n'est pas une adresse est gardée telle quelle,
/// bornée à 128 caractères.
public func peerIdentity(_ peer: String) -> String {
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
        var raw = in6_addr()
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: v6) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil {
            return String(cString: buffer)
        }
    }
    return String(peer.prefix(128))
}
