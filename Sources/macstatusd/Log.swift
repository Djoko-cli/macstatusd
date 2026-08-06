import Foundation
import os

enum LogLevel: Int, Comparable {
    case error = 0, warn = 1, info = 2, debug = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    static func parse(_ s: String) -> LogLevel {
        switch s.lowercased() {
        case "error": return .error
        case "warn", "warning": return .warn
        case "debug", "trace": return .debug
        default: return .info
        }
    }

    var tag: String {
        switch self {
        case .error: return "ERROR"
        case .warn: return "WARN "
        case .info: return "INFO "
        case .debug: return "DEBUG"
        }
    }
}

/// Journalisation sérialisée : fichier avec rotation + os_log + stdout.
/// Aucune écriture ne peut faire tomber le daemon (échecs silencieux mais signalés une fois).
final class Log {
    static let shared = Log()

    private let queue = DispatchQueue(label: "macstatusd.log", qos: .utility)
    private let osLog = OSLog(subsystem: "com.majid.macstatusd", category: "daemon")
    private let maxBytes = 2 * 1024 * 1024
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private var level: LogLevel = .info
    private var handle: FileHandle?
    private var fileURL: URL?
    private var bytes = 0
    private var echoToStdout = true
    private var fileFailureReported = false

    private init() {}

    /// Choisit le chemin de log : explicite, sinon /opt/macstatusd/logs pour root,
    /// sinon ~/Library/Logs/macstatusd.
    static func defaultLogFile() -> URL {
        if getuid() == 0 {
            return URL(fileURLWithPath: "/opt/macstatusd/logs/macstatusd.log")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/macstatusd/macstatusd.log")
    }

    func configure(level: LogLevel, file: URL?, echoToStdout: Bool) {
        queue.sync {
            self.level = level
            self.echoToStdout = echoToStdout
            self.handle?.closeFile()
            self.handle = nil
            self.fileURL = file
            if let file { openFile(file) }
        }
    }

    var currentLogPath: String? {
        queue.sync { fileURL?.path }
    }

    private func openFile(_ url: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            h.seekToEndOfFile()
            handle = h
            bytes = Int(h.offsetInFile)
        } catch {
            handle = nil
            if !fileFailureReported {
                fileFailureReported = true
                FileHandle.standardError.write(Data("macstatusd: log fichier indisponible (\(url.path)): \(error)\n".utf8))
            }
        }
    }

    private func rotateIfNeeded() {
        guard let url = fileURL, bytes > maxBytes else { return }
        let previous = url.appendingPathExtension("1")
        handle?.closeFile()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)
        bytes = 0
        openFile(url)
    }

    func log(_ level: LogLevel, _ message: String) {
        queue.async { [self] in
            guard level <= self.level else { return }
            let line = "\(formatter.string(from: Date())) \(level.tag) \(message)\n"
            if let data = line.data(using: .utf8) {
                if let handle {
                    handle.write(data)
                    bytes += data.count
                    rotateIfNeeded()
                }
                if echoToStdout {
                    FileHandle.standardOutput.write(data)
                }
            }
            switch level {
            case .error: os_log("%{public}@", log: osLog, type: .error, message)
            case .warn:  os_log("%{public}@", log: osLog, type: .default, message)
            case .info:  os_log("%{public}@", log: osLog, type: .info, message)
            case .debug: os_log("%{public}@", log: osLog, type: .debug, message)
            }
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }
}

func logError(_ m: String) { Log.shared.log(.error, m) }
func logWarn(_ m: String) { Log.shared.log(.warn, m) }
func logInfo(_ m: String) { Log.shared.log(.info, m) }
func logDebug(_ m: String) { Log.shared.log(.debug, m) }
