import Foundation

/// Exécuteur des lectures des écrans (`SystemSignals.displaySnapshot()`), sur une file à part de celle du moteur.
///
/// Pendant que macOS reconfigure les écrans (réveil), une lecture dure environ 1,5 s (banc 4, R85) : sur la file du
/// moteur, elle retardait le lissage de ON. Les signaux réels gardent un dictionnaire d'identités d'écrans
/// (`displayIdentities`) : **toute** lecture passe par cette file, jamais deux à la fois. Cette file ne rappelle
/// jamais la file du moteur de façon synchrone.
public protocol DisplayReadRunner: AnyObject {
    /// Lit tout de suite, sur la file des écrans, et rend le résultat (attend une lecture en cours).
    func readNow(_ work: () -> DisplaySnapshot) -> DisplaySnapshot
    /// Lance la lecture en arrière-plan, sur la même file.
    func readLater(_ work: @escaping () -> Void)
}

/// Exécuteur réel : une file série de GCD.
public final class DispatchDisplayReadRunner: DisplayReadRunner {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public func readNow(_ work: () -> DisplaySnapshot) -> DisplaySnapshot {
        queue.sync(execute: work)
    }

    public func readLater(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}
