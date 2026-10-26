import Foundation
import os
import MacStatusCore

/// Journalisation sérialisée : fichier avec rotation + os_log + sortie standard.
///
/// Aucune écriture ne peut faire tomber le daemon ni lever d'exception : le fichier s'ouvre par
/// `open(2)` et s'écrit par `write(2)` (jamais `FileHandle`, dont les erreurs sont des exceptions
/// Objective-C), la sortie standard et la sortie d'erreur de même.
///
/// - Un échec d'ouverture ou d'écriture ferme le fichier et se signale une seule fois par `os_log`
///   par épisode d'échec ; l'ouverture est retentée au plus toutes les 60 s (horloge monotone).
/// - Toutes les 100 écritures, l'inode du chemin est comparé à celui du fichier ouvert : un fichier
///   supprimé, renommé ou remplacé est rouvert.
/// - Rotation en 5 générations (`.1` à `.5`) de 2 Mio, toutes en mode 600.
/// - Après un EPIPE (lecteur du tube fermé), l'écho sur la sortie standard est coupé pour de bon.
///
/// C'est le récepteur de `MacStatusCore` : `main.swift` le branche sur `CoreLog.sink`.
final class Log: LogSink {
    static let shared = Log()

    /// Variable d'environnement de test : taille de rotation réduite (en octets, 4096 au moins).
    /// Elle sert au selftest, qui ne peut pas écrire plusieurs fois 2 Mio en un temps raisonnable.
    static let maxBytesEnvironmentKey = "MACSTATUSD_LOG_MAX_BYTES"
    static let defaultMaxBytes = 2 * 1024 * 1024
    static let generations = 5
    static let checkEveryWrites = 100
    static let reopenDelayNanoseconds: UInt64 = 60 * 1_000_000_000

    private let queue = DispatchQueue(label: "macstatusd.log", qos: .utility)
    private let osLog = OSLog(subsystem: "com.djoko.macstatusd", category: "daemon")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private var level: LogLevel = .info
    private var maxBytes = Log.defaultMaxBytes
    private var fileURL: URL?
    private var fd: Int32 = -1
    private var bytes = 0
    private var writesSinceCheck = 0
    private var echoToStdout = true
    /// Un échec a déjà été signalé pour l'épisode en cours (remis à faux par une ouverture réussie).
    private var failureReported = false
    /// Instant monotone (ns) avant lequel l'ouverture n'est pas retentée.
    private var nextOpenAttempt: UInt64 = 0

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
            if let text = ProcessInfo.processInfo.environment[Log.maxBytesEnvironmentKey],
               let value = Int(text), value >= 4096 {
                self.maxBytes = value
            }
            closeFile()
            self.fileURL = file
            self.failureReported = false
            self.nextOpenAttempt = 0
            if file != nil { openFile() }
        }
    }

    var currentLogPath: String? {
        queue.sync { fileURL?.path }
    }

    // MARK: - Fichier

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func closeFile() {
        if fd >= 0 { close(fd) }
        fd = -1
        bytes = 0
        writesSinceCheck = 0
    }

    /// Signale un échec une seule fois par épisode : `os_log`, et la sortie d'erreur si l'écho est
    /// actif (premier plan). Ferme le fichier et reporte la prochaine ouverture de 60 s.
    private func fileFailed(_ what: String, code: Int32) {
        closeFile()
        nextOpenAttempt = Log.now() + Log.reopenDelayNanoseconds
        guard !failureReported else { return }
        failureReported = true
        let path = fileURL?.path ?? "?"
        let detail = "journal fichier indisponible (\(path)) : \(what) : \(String(cString: strerror(code)))"
        os_log("%{public}@", log: osLog, type: .error, detail)
        if echoToStdout { Log.safeWrite(STDERR_FILENO, Data("macstatusd: \(detail)\n".utf8)) }
    }

    /// Ouvre (ou rouvre) le fichier. Crée le dossier au besoin. Un fichier existant garde son contenu
    /// (écriture en fin de fichier) ; ses droits sont ramenés à 600 s'ils sont plus larges.
    private func openFile() {
        guard let url = fileURL else { return }
        let directory = url.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            fileFailed("ouverture impossible", code: errno)
            return
        }
        var info = stat()
        if fstat(descriptor, &info) == 0 {
            if info.st_mode & 0o177 != 0 { fchmod(descriptor, 0o600) }
            bytes = Int(info.st_size)
        } else {
            bytes = 0
        }
        fd = descriptor
        writesSinceCheck = 0
        failureReported = false
    }

    /// Vrai si le chemin ne désigne plus le fichier ouvert (supprimé, renommé, remplacé).
    private func fileWasReplaced() -> Bool {
        guard let url = fileURL, fd >= 0 else { return false }
        var onDisk = stat()
        var opened = stat()
        guard stat(url.path, &onDisk) == 0, fstat(fd, &opened) == 0 else { return true }
        return onDisk.st_ino != opened.st_ino || onDisk.st_dev != opened.st_dev
    }

    private func rotate() {
        guard let url = fileURL else { return }
        closeFile()
        let fm = FileManager.default
        func generation(_ n: Int) -> String { url.path + ".\(n)" }
        try? fm.removeItem(atPath: generation(Log.generations))
        for n in stride(from: Log.generations - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: generation(n), toPath: generation(n + 1))
        }
        try? fm.moveItem(atPath: url.path, toPath: generation(1))
        for n in 1...Log.generations { chmod(generation(n), 0o600) }
        openFile()
    }

    /// Écrit une ligne dans le fichier, sans lever d'exception ni bloquer sur un fichier absent.
    private func writeToFile(_ data: Data) {
        guard fileURL != nil else { return }
        if fd < 0 {
            guard Log.now() >= nextOpenAttempt else { return }
            openFile()
            guard fd >= 0 else { return }
        }
        writesSinceCheck += 1
        if writesSinceCheck >= Log.checkEveryWrites {
            writesSinceCheck = 0
            if fileWasReplaced() {
                closeFile()
                openFile()
                guard fd >= 0 else { return }
            }
        }
        if let code = Log.writeAll(fd, data) {
            fileFailed("écriture impossible", code: code)
            return
        }
        bytes += data.count
        if bytes > maxBytes { rotate() }
    }

    // MARK: - Écriture bas niveau

    /// Écrit tout `data` sur `descriptor` par `write(2)`. Reprend sur EINTR et sur écriture partielle.
    /// Renvoie le code d'erreur en cas d'échec (EPIPE, ENOSPC, EAGAIN…), `nil` sinon.
    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Int32? {
        var failure: Int32?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                if written == 0 { failure = EIO; return }
                pointer += written
                remaining -= written
            }
        }
        return failure
    }

    /// Écriture sans suite : l'erreur est ignorée.
    private static func safeWrite(_ descriptor: Int32, _ data: Data) {
        _ = writeAll(descriptor, data)
    }

    /// Écho sur la sortie standard. Un lecteur de tube parti (EPIPE) ou un descripteur fermé coupe
    /// l'écho pour de bon ; un tube plein (EAGAIN) fait seulement perdre la ligne.
    private func echo(_ data: Data) {
        guard let code = Log.writeAll(STDOUT_FILENO, data) else { return }
        if code != EAGAIN { echoToStdout = false }
    }

    // MARK: - LogSink

    func log(_ level: LogLevel, _ message: String) {
        queue.async { [self] in
            guard level <= self.level else { return }
            let line = "\(formatter.string(from: Date())) \(level.tag) \(message)\n"
            if let data = line.data(using: .utf8) {
                writeToFile(data)
                if echoToStdout { echo(data) }
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
            if fd >= 0 { fsync(fd) }
        }
    }
}
