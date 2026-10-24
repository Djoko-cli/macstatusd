import Foundation

/// Source du temps, injectable pour que les tests maîtrisent les durées.
public protocol Clock: AnyObject {
    /// Instant monotone, en secondes. Il ne recule jamais et compte aussi le
    /// temps passé en veille : l'écart entre deux lectures mesure une durée réelle.
    func monotonic() -> Double
    /// Heure murale, pour ce qui s'affiche ou se journalise.
    func wall() -> Date
}

/// Horloge du système.
public final class SystemClock: Clock {
    public init() {}

    public func monotonic() -> Double {
        // CLOCK_MONOTONIC_RAW continue de compter pendant la veille du Mac,
        // contrairement à `ProcessInfo.systemUptime`.
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    public func wall() -> Date { Date() }
}
