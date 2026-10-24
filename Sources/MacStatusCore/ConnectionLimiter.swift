import Foundation

// MARK: - Plafond de connexions

/// Plafond des connexions HTTP ouvertes en même temps : `maxTotal` en tout, `maxPerPeer` par
/// pair. Le pair est identifié comme pour les limites de débit (`peerIdentity`) : son adresse,
/// sans le port ni la zone, une IPv4 mappée valant l'IPv4.
///
/// `acquire` est appelé à l'acceptation de la connexion, avant toute lecture ; chaque `acquire`
/// réussi doit être suivi d'un seul `release`, à l'état final de la connexion. Un `release` sans
/// place prise est sans effet : il ne crée jamais de place en plus. Un pair sans connexion est
/// oublié : la table ne compte que des pairs connectés (au plus `maxTotal`). Protégé par un verrou.
public final class ConnectionLimiter {
    public static let defaultMaxTotal = 32
    public static let defaultMaxPerPeer = 8

    private let maxTotal: Int
    private let maxPerPeer: Int
    private let lock = NSLock()
    private var total = 0
    private var perPeer: [String: Int] = [:]

    public init(maxTotal: Int, maxPerPeer: Int) {
        self.maxTotal = max(1, maxTotal)
        self.maxPerPeer = max(1, maxPerPeer)
    }

    /// Prend une place pour `peer` ; `false` si le plafond total ou celui du pair est atteint.
    public func acquire(peer: String) -> Bool {
        let key = peerIdentity(peer)
        lock.lock(); defer { lock.unlock() }
        let current = perPeer[key] ?? 0
        guard total < maxTotal, current < maxPerPeer else { return false }
        perPeer[key] = current + 1
        total += 1
        return true
    }

    /// Rend une place prise par `peer`.
    public func release(peer: String) {
        let key = peerIdentity(peer)
        lock.lock(); defer { lock.unlock() }
        guard let current = perPeer[key], current > 0 else { return }
        if current == 1 { perPeer.removeValue(forKey: key) } else { perPeer[key] = current - 1 }
        total -= 1
    }

    /// Connexions ouvertes, tous pairs confondus.
    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    /// Connexions ouvertes par ce pair.
    public func count(peer: String) -> Int {
        let key = peerIdentity(peer)
        lock.lock(); defer { lock.unlock() }
        return perPeer[key] ?? 0
    }

    /// Pairs suivis (pour les tests).
    var trackedPeerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return perPeer.count
    }
}

// MARK: - Journal borné

/// Borne une famille de lignes de journal : une ligne au premier événement, puis au plus une
/// par `period` secondes. `note()` compte l'événement et renvoie, quand une ligne est due, le
/// nombre d'événements depuis la précédente (celui-ci compris) ; `nil` sinon. Une horloge qui
/// recule rend une ligne due. Protégé par un verrou.
public final class PeriodicLogGate {
    private let period: Double
    private let clock: Clock
    private let lock = NSLock()
    private var lastLineAt: Double?
    private var pending = 0

    public init(period: Double = 60, clock: Clock) {
        self.period = period
        self.clock = clock
    }

    public func note() -> Int? {
        lock.lock(); defer { lock.unlock() }
        pending += 1
        let now = clock.monotonic()
        let due = lastLineAt.map { now - $0 >= period || now < $0 } ?? true
        guard due else { return nil }
        lastLineAt = now
        defer { pending = 0 }
        return pending
    }
}
