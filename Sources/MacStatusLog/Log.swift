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
/// - Rotation en 5 générations (`.1` à `.5`) de 2 Mio, toutes en mode 600. Une rotation qui échoue
///   (dossier en lecture seule, disque plein) laisse les générations intactes, se signale une seule fois
///   par épisode et n'est retentée qu'après `maxBytes` octets de plus ou 60 s. Si elle échoue
///   durablement et que le fichier atteint 4 × `maxBytes`, l'écriture fichier cesse (un seul
///   signalement) ; elle reprend à la rotation réussie suivante, dont la première ligne dit combien
///   de rotations ont été ratées (et combien de lignes n'ont pas été écrites).
/// - Le fichier n'occupe jamais un descripteur standard (0, 1, 2), même si l'un d'eux était fermé.
/// - Après un EPIPE (lecteur du tube fermé), l'écho sur la sortie standard est coupé pour de bon.
///
/// C'est le récepteur de `MacStatusCore` : `main.swift` le branche sur `CoreLog.sink`.
public final class Log: LogSink {
    public static let shared = Log()

    /// Variable d'environnement de test : taille de rotation réduite (en octets, 4096 au moins).
    /// Elle sert au selftest, qui ne peut pas écrire plusieurs fois 2 Mio en un temps raisonnable.
    static let maxBytesEnvironmentKey = "MACSTATUSD_LOG_MAX_BYTES"
    static let defaultMaxBytes = 2 * 1024 * 1024
    static let generations = 5
    static let checkEveryWrites = 100
    /// Plafond du fichier tant que la rotation échoue : `rotationFailureCapFactor × maxBytes`.
    static let rotationFailureCapFactor = 4
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
    /// Descripteur de l'écho : la sortie standard, ou la sortie d'erreur pour `--once` et `--watch`.
    private var echoDescriptor: Int32 = STDOUT_FILENO
    /// Un échec a déjà été signalé pour l'épisode en cours (remis à faux par une ouverture réussie).
    private var failureReported = false
    /// Instant monotone (ns) avant lequel l'ouverture n'est pas retentée.
    private var nextOpenAttempt: UInt64 = 0
    /// Une rotation a échoué : tant qu'elle n'a pas réussi, elle n'est retentée qu'à `rotationRetryBytes`
    /// octets ou à `rotationRetryAt` (le premier des deux).
    private var rotationFailed = false
    private var rotationRetryBytes = 0
    private var rotationRetryAt: UInt64 = 0
    /// L'échec de rotation de l'épisode en cours a déjà été signalé (remis à faux par une rotation réussie).
    private var rotationFailureReported = false
    /// Rotations ratées depuis la dernière réussie (remis à zéro par une rotation réussie).
    private var rotationFailureCount = 0
    /// Le fichier a atteint le plafond : plus aucune écriture fichier jusqu'à une rotation réussie.
    private var capped = false
    /// Le plafond de l'épisode en cours a déjà été signalé.
    private var capReported = false
    /// Lignes non écrites dans le fichier depuis le plafond.
    private var linesDroppedAtCap = 0

    /// Instant monotone (ns) ; remplaçable par les tests.
    var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    /// Signalement d'un échec : `os_log`, et la sortie d'erreur si l'écho est actif. Remplaçable par les tests.
    var report: ((String) -> Void)?
    /// Nombre de rotations tentées (réussies ou non), pour les tests.
    private(set) var rotationAttempts = 0
    /// Ouverture du fichier de journal ; remplaçable par les tests.
    var opener: (String) -> Int32 = { open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600) }
    /// Plus petit descripteur que le fichier peut occuper : au-delà des trois descripteurs standard.
    /// Les tests le relèvent pour jouer le déplacement sans fermer le moindre descripteur du processus.
    var firstAllowedDescriptor: Int32 = STDERR_FILENO + 1

    init() {}

    /// Chemin du journal quand la config n'en donne pas : `~/Library/Logs/<nom>/macstatusd.log`
    /// (`SupportPaths.logs`).
    public static func defaultLogFile() -> URL {
        URL(fileURLWithPath: SupportPaths.current().logs + "/macstatusd.log")
    }

    /// Faut-il écrire aussi le journal sur la sortie ? Oui dans un terminal ou avec `--foreground`. `--debug` seul n'y
    /// ajoute rien pour le daemon : sous launchd, l'écho doublerait le journal fichier dans le journal de sortie du
    /// service. Mais `--once` et `--watch` (`diagnosticMode`) sont des modes de diagnostic lancés à la main, sans
    /// journal fichier, dont l'écho va sur la sortie d'erreur (leur sortie standard ne porte que le JSON ou le
    /// tableau) : `--debug` y demande le journal détaillé, même quand la sortie standard est redirigée.
    public static func echoesToOutput(isTTY: Bool, foreground: Bool, debug: Bool, diagnosticMode: Bool) -> Bool {
        isTTY || foreground || (debug && diagnosticMode)
    }

    /// `maxBytes` : taille de rotation imposée par l'appelant (tests) ; sinon la variable d'environnement
    /// d'essai, sinon 2 Mio. `echoDescriptor` : où va l'écho (`echoToStdout`) ; la sortie d'erreur pour
    /// `--once` et `--watch`, dont la sortie standard ne porte que leur propre affichage.
    public func configure(level: LogLevel, file: URL?, echoToStdout: Bool,
                          echoDescriptor: Int32 = STDOUT_FILENO, maxBytes: Int? = nil) {
        queue.sync {
            self.level = level
            self.echoToStdout = echoToStdout
            self.echoDescriptor = echoDescriptor
            var size = maxBytes
            var notice: (LogLevel, String)?
            if size == nil, let text = ProcessInfo.processInfo.environment[Log.maxBytesEnvironmentKey] {
                if let value = Int(text), value >= 4096 {
                    size = value
                    notice = (.info, "journal : taille de rotation réduite à \(value) octets "
                              + "(\(Log.maxBytesEnvironmentKey), variable d'essai)")
                } else {
                    notice = (.warn, "\(Log.maxBytesEnvironmentKey) ignorée (entier d'au moins 4096 attendu) "
                              + "→ rotation à \(Log.defaultMaxBytes) octets")
                }
            }
            self.maxBytes = size ?? Log.defaultMaxBytes
            closeFile()
            self.fileURL = file
            self.failureReported = false
            self.nextOpenAttempt = 0
            self.rotationFailed = false
            self.rotationFailureReported = false
            self.rotationFailureCount = 0
            self.capped = false
            self.capReported = false
            self.linesDroppedAtCap = 0
            if file != nil { openFile() }
            if let notice { log(notice.0, notice.1) }
        }
    }

    /// Descripteur du fichier ouvert (`-1` : aucun), pour les tests.
    var openDescriptor: Int32 {
        queue.sync { fd }
    }

    public var currentLogPath: String? {
        queue.sync { fileURL?.path }
    }

    // MARK: - Fichier

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
        nextOpenAttempt = now() + Log.reopenDelayNanoseconds
        guard !failureReported else { return }
        failureReported = true
        let path = fileURL?.path ?? "?"
        let detail = "journal fichier indisponible (\(path)) : \(what) : \(String(cString: strerror(code)))"
        reportFailure(detail)
    }

    private func reportFailure(_ detail: String) {
        if let report { report(detail); return }
        os_log("%{public}@", log: osLog, type: .error, detail)
        if echoToStdout { Log.safeWrite(STDERR_FILENO, Data("macstatusd: \(detail)\n".utf8)) }
    }

    /// Ouvre (ou rouvre) le fichier. Crée le dossier au besoin. Un fichier existant garde son contenu
    /// (écriture en fin de fichier) ; ses droits sont ramenés à 600 s'ils sont plus larges.
    ///
    /// Le fichier n'occupe jamais le descripteur 0, 1 ou 2 : si l'un d'eux était fermé, `open` le
    /// rendrait, et l'écho (sortie standard) comme la fermeture de la rotation le brouilleraient.
    /// Le descripteur est alors déplacé au-delà de 2 (`firstAllowedDescriptor`), et le créneau standard
    /// laissé libre comme avant.
    private func openFile() {
        guard let url = fileURL else { return }
        let directory = url.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var descriptor = opener(url.path)
        guard descriptor >= 0 else {
            fileFailed("ouverture impossible", code: errno)
            return
        }
        if descriptor < firstAllowedDescriptor {
            let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, firstAllowedDescriptor)
            let code = errno
            close(descriptor)
            guard moved >= firstAllowedDescriptor else {
                fileFailed("descripteur standard refusé", code: code)
                return
            }
            descriptor = moved
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
    }

    /// Vrai si le chemin ne désigne plus le fichier ouvert (supprimé, renommé, remplacé).
    private func fileWasReplaced() -> Bool {
        guard let url = fileURL, fd >= 0 else { return false }
        var onDisk = stat()
        var opened = stat()
        guard stat(url.path, &onDisk) == 0, fstat(fd, &opened) == 0 else { return true }
        return onDisk.st_ino != opened.st_ino || onDisk.st_dev != opened.st_dev
    }

    /// Fait tourner les générations : `.4` devient `.5`, …, le journal courant devient `.1`.
    ///
    /// Le journal courant est écarté d'abord (`.rotating`) : si ce premier pas échoue, aucune génération
    /// n'a bougé et rien n'est perdu. Renvoie faux si la rotation n'a pas eu lieu ; le journal courant
    /// est alors rouvert et continue de grossir (voir `writeToFile`).
    private func rotate() -> Bool {
        rotationAttempts += 1
        guard let url = fileURL else { return true }
        let size = bytes
        closeFile()
        defer { openFile() }
        let path = url.path
        let staging = path + ".rotating"
        func generation(_ n: Int) -> String { path + ".\(n)" }
        guard rename(path, staging) == 0 else {
            noteRotationFailure("écartement du journal courant", code: errno, size: size)
            return false
        }
        unlink(generation(Log.generations))
        for n in stride(from: Log.generations - 1, through: 1, by: -1) {
            rename(generation(n), generation(n + 1))
        }
        guard rename(staging, generation(1)) == 0 else {
            // Rare : le courant revient à sa place plutôt que de rester sous un nom provisoire.
            let code = errno
            rename(staging, path)
            noteRotationFailure("passage du journal courant en .1", code: code, size: size)
            return false
        }
        for n in 1...Log.generations { chmod(generation(n), 0o600) }
        rotationFailed = false
        rotationFailureReported = false
        return true
    }

    /// Tente une rotation. À la réussite, l'épisode d'échec est clos : le plafond est levé et la première
    /// ligne du nouveau fichier dit combien de rotations ont été ratées (et de lignes non écrites).
    private func rotateAndClose() {
        let failures = rotationFailureCount
        let dropped = linesDroppedAtCap
        guard rotate() else { return }
        rotationFailureCount = 0
        capped = false
        capReported = false
        linesDroppedAtCap = 0
        guard failures > 0 else { return }
        var text = "journal : rotation réussie après \(failures) rotation(s) ratée(s)"
        if dropped > 0 { text += ", \(dropped) ligne(s) non écrite(s) au plafond" }
        let line = "\(formatter.string(from: Date())) \(LogLevel.warn.tag) \(text)\n"
        if let data = line.data(using: .utf8), fd >= 0, Log.writeAll(fd, data) == nil { bytes += data.count }
    }

    /// Une rotation a échoué : prochaine tentative après `maxBytes` octets de plus ou 60 s. Un seul
    /// signalement par épisode.
    private func noteRotationFailure(_ what: String, code: Int32, size: Int) {
        rotationFailureCount += 1
        rotationFailed = true
        rotationRetryBytes = size + maxBytes
        rotationRetryAt = now() + Log.reopenDelayNanoseconds
        guard !rotationFailureReported else { return }
        rotationFailureReported = true
        let path = fileURL?.path ?? "?"
        reportFailure("rotation du journal impossible (\(path)) : \(what) : \(String(cString: strerror(code))) "
                      + "→ retentée après \(maxBytes) octets de plus ou 60 s")
    }

    /// Signale une seule fois par épisode que le fichier a atteint son plafond.
    private func reportCap() {
        guard !capReported else { return }
        capReported = true
        let path = fileURL?.path ?? "?"
        reportFailure("journal fichier au plafond (\(path)) : \(bytes) octets, rotation toujours impossible "
                      + "→ plus aucune écriture fichier jusqu'à une rotation réussie (retentée toutes les 60 s)")
    }

    /// Écrit une ligne dans le fichier, sans lever d'exception ni bloquer sur un fichier absent.
    private func writeToFile(_ data: Data) {
        guard fileURL != nil else { return }
        if fd < 0 {
            guard now() >= nextOpenAttempt else { return }
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
        if rotationFailed, bytes >= Log.rotationFailureCapFactor * maxBytes {
            // Rotation ratée durablement et fichier au plafond : plus d'écriture fichier. La rotation
            // reste retentée toutes les 60 s ; à sa réussite la ligne en cours est écrite normalement.
            if !capped {
                capped = true
                reportCap()
            }
            if now() >= rotationRetryAt { rotateAndClose() }
            guard !capped, fd >= 0 else {
                linesDroppedAtCap += 1
                return
            }
        }
        if let code = Log.writeAll(fd, data) {
            fileFailed("écriture impossible", code: code)
            return
        }
        failureReported = false   // une écriture réussie clôt l'épisode d'échec
        bytes += data.count
        if bytes > maxBytes {
            // Après une rotation ratée, on ne la retente pas à chaque ligne.
            if rotationFailed, bytes < rotationRetryBytes, now() < rotationRetryAt { return }
            rotateAndClose()
        }
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

    /// Écho sur `echoDescriptor` (la sortie standard par défaut). Un lecteur de tube parti (EPIPE) ou un
    /// descripteur fermé coupe l'écho pour de bon ; un tube plein (EAGAIN) fait seulement perdre la ligne.
    private func echo(_ data: Data) {
        guard let code = Log.writeAll(echoDescriptor, data) else { return }
        if code != EAGAIN { echoToStdout = false }
    }

    // MARK: - LogSink

    public func log(_ level: LogLevel, _ message: String) {
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

    public func flush() {
        queue.sync {
            if fd >= 0 { fsync(fd) }
        }
    }
}
