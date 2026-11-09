import Foundation

/// Mesure la durée de chaque lecture du système faite par le moteur (R85). Une lecture qui dure au moins
/// `threshold` secondes est comptée, et signalée par un WARN au plus une fois par nom et par `warnEvery`
/// secondes. Le coût d'une lecture non lente : deux lectures de l'horloge d'éveil et un verrou.
///
/// Les durées se mesurent sur `clock.awake()`, veille exclue (un gel du processus, Mac éveillé, compte), avant
/// et après l'appel. Le WARN passe par `logWarn`, comme tout le moteur. `snapshot` alimente le champ
/// `slow_calls` de `/status`.
public final class SlowCallMonitor {
    private let clock: Clock
    private let threshold: Double
    private let warnEvery: Double
    private let verrou = NSLock()
    private var counts: [String: Int] = [:]
    private var maxSeconds: [String: Double] = [:]
    private var lastWarnAt: [String: Double] = [:]

    public init(clock: Clock, threshold: Double = 1.0, warnEvery: Double = 60) {
        self.clock = clock
        self.threshold = threshold
        self.warnEvery = warnEvery
    }

    /// Exécute `body` et note sa durée.
    public func measure<T>(_ name: String, _ body: () -> T) -> T {
        let start = clock.awake()
        let result = body()
        let end = clock.awake()
        let elapsed = end - start
        if elapsed >= threshold { note(name, elapsed: elapsed, at: end) }
        return result
    }

    private func note(_ name: String, elapsed: Double, at now: Double) {
        verrou.lock()
        counts[name, default: 0] += 1
        maxSeconds[name] = max(maxSeconds[name] ?? 0, elapsed)
        let shouldWarn = lastWarnAt[name].map { now - $0 >= warnEvery } ?? true
        if shouldWarn { lastWarnAt[name] = now }
        verrou.unlock()
        if shouldWarn {
            logWarn("appel lent : \(name) \(String(format: "%.1f", elapsed)) s "
                    + "(seuil \(String(format: "%.1f", threshold)) s)")
        }
    }

    /// `{"<nom>": {"count": n, "max_seconds": x}}` pour les appels qui ont atteint le seuil.
    public var snapshot: [String: [String: Any]] {
        verrou.lock(); defer { verrou.unlock() }
        var result: [String: [String: Any]] = [:]
        for (name, count) in counts {
            result[name] = ["count": count, "max_seconds": ((maxSeconds[name] ?? 0) * 1000).rounded() / 1000]
        }
        return result
    }
}
