import Foundation

/// Tâche différée que l'on peut annuler avant son exécution.
public protocol Cancellable {
    func cancel()
}

/// Exécution différée d'un travail, injectable pour que les tests n'attendent jamais.
public protocol Scheduler: AnyObject {
    /// Exécute `work` dans `seconds` secondes. Le résultat peut être ignoré.
    @discardableResult
    func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable
}

/// Planificateur réel : le travail s'exécute sur la file donnée.
public final class DispatchScheduler: Scheduler {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    private final class Tache: Cancellable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    @discardableResult
    public func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        return Tache(item)
    }
}
