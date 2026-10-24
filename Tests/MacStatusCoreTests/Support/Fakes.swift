import Foundation
@testable import MacStatusCore

/// Récepteur de journal pour les tests : garde les lignes (niveau, message) en mémoire.
/// Protégé par un verrou, car le moteur écrira depuis plusieurs files.
final class CaptureLog: LogSink {
    private let verrou = NSLock()
    private var stockage: [(LogLevel, String)] = []

    var lines: [(LogLevel, String)] {
        get { verrou.lock(); defer { verrou.unlock() }; return stockage }
        set { verrou.lock(); defer { verrou.unlock() }; stockage = newValue }
    }

    func log(_ level: LogLevel, _ message: String) {
        verrou.lock(); defer { verrou.unlock() }
        stockage.append((level, message))
    }
}
