import Foundation

/// Niveau de journalisation, du plus grave au plus bavard.
public enum LogLevel: Int, Comparable {
    case error = 0, warn = 1, info = 2, debug = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func parse(_ s: String) -> LogLevel {
        switch s.lowercased() {
        case "error": return .error
        case "warn", "warning": return .warn
        case "debug", "trace": return .debug
        default: return .info
        }
    }

    public var tag: String {
        switch self {
        case .error: return "ERROR"
        case .warn: return "WARN "
        case .info: return "INFO "
        case .debug: return "DEBUG"
        }
    }
}

/// Destination des messages de la bibliothèque. L'exécutable branche son journal
/// fichier ; les tests branchent un récepteur en mémoire.
public protocol LogSink: AnyObject {
    func log(_ level: LogLevel, _ message: String)
}

public enum CoreLog {
    /// Récepteur courant. À fixer une fois, au démarrage, avant le premier message.
    /// Sans récepteur (`nil`), les messages sont simplement perdus.
    public static var sink: LogSink?
}

public func logError(_ m: String) { CoreLog.sink?.log(.error, m) }
public func logWarn(_ m: String) { CoreLog.sink?.log(.warn, m) }
public func logInfo(_ m: String) { CoreLog.sink?.log(.info, m) }
public func logDebug(_ m: String) { CoreLog.sink?.log(.debug, m) }
