import Foundation
import IOKit
import CoreGraphics
import Carbon
import MacStatusCore

/// Lecture des signaux bruts du système.
///
/// Chaque signal a une source primaire déterministe et, quand c'est possible,
/// une source de repli indépendante :
///
/// - verrouillage : IORegistry (`IOConsoleLocked` / `IOConsoleUsers`) — disponible
///   même hors session graphique — puis `CGSessionCopyCurrentDictionary`.
/// - écran éteint : `CGDisplayIsAsleep` sur l'écran principal, avec repli sur
///   « tous les écrans en ligne endormis ».
/// - champ d'authentification : `IsSecureEventInputEnabled`.
/// - économiseur : `SACScreenSaverIsRunning` (login.framework, chargé une fois) ; `ScreenSaverEngine` et
///   ses hôtes se cherchent dans les process de l'utilisateur seulement, jamais ceux des autres comptes.
final class LiveSystemSignals: SystemSignals {
    private let registryRoot: io_registry_entry_t

    init() {
        registryRoot = IORegistryGetRootEntry(kIOMainPortDefault)
        if registryRoot == 0 {
            logWarn("IORegistryGetRootEntry a échoué : repli sur CGSession pour le verrouillage")
        }
    }

    deinit {
        if registryRoot != 0 { IOObjectRelease(registryRoot) }
    }

    // MARK: - Verrouillage / session

    func session() -> SessionState {
        var state = SessionState()
        var evidence: [String] = []
        var consoleUsers: [[String: Any]]?
        let cgSession = CGSessionCopyCurrentDictionary() as? [String: Any]

        // 1. IORegistry : fonctionne aussi depuis un LaunchDaemon hors session.
        if registryRoot != 0 {
            if let value = registryProperty("IOConsoleLocked") as? NSNumber, value.boolValue {
                state.locked = true
                evidence.append("IOConsoleLocked")
            }
            consoleUsers = registryProperty("IOConsoleUsers") as? [[String: Any]]
            if let console = consoleUsers?.first(where: {
                ($0[ConsoleOwnership.onConsoleKey] as? NSNumber)?.boolValue == true
            }) {
                if (console["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue == true {
                    state.loggedIn = true
                }
                if (console["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
                    state.locked = true
                    evidence.append("IOConsoleUsers")
                }
            }
        }

        // 2. Session graphique courante : disponible quand on tourne dans Aqua.
        if let dict = cgSession {
            if (dict["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue == true {
                state.loggedIn = true
            }
            if (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
                state.locked = true
                evidence.append("CGSession")
            }
        }

        // 3. La session est-elle à la console ? Décision pure du cœur : le registre d'abord, puis la
        //    session graphique, puis le laisser-passer (un registre muet ne doit pas bloquer la publication).
        let console = ConsoleOwnership.decide(consoleUsers: consoleUsers, cgSession: cgSession, uid: getuid())
        state.onConsole = console.onConsole
        noteConsoleSource(console)

        if !evidence.isEmpty { state.evidence = evidence.joined(separator: "+") }
        else if state.locked { state.evidence = "unknown" }
        else { state.evidence = "unlocked" }
        return state
    }

    /// Dernier verdict de console journalisé : une ligne par changement de source ou de valeur, pas une
    /// par scrutation.
    private var lastConsoleVerdict: ConsoleOwnership.Verdict?

    private func noteConsoleSource(_ verdict: ConsoleOwnership.Verdict) {
        guard verdict != lastConsoleVerdict else { return }
        lastConsoleVerdict = verdict
        switch verdict.source {
        case .registry:
            logDebug("console : IOConsoleUsers répond (session \(verdict.onConsole ? "à la console" : "hors console"))")
        case .cgSession:
            logDebug("console : IOConsoleUsers muet, repli sur CGSession "
                     + "(session \(verdict.onConsole ? "à la console" : "hors console"))")
        case .none:
            logDebug("console : ni IOConsoleUsers ni CGSession ne répondent → session tenue pour la console")
        }
    }

    private func registryProperty(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(registryRoot, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    // MARK: - Écrans

    func display() -> DisplayState {
        var state = DisplayState()

        let main = CGMainDisplayID()
        state.asleep = CGDisplayIsAsleep(main) != 0

        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return state }
        state.enumerationOK = true
        state.onlineCount = Int(count)
        guard count > 0 else { return state }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return state }
        state.onlineCount = Int(count)

        // Repli : si l'écran principal ne rapporte rien mais que tous les écrans
        // en ligne dorment, l'affichage est bien éteint.
        if !state.asleep, count > 0 {
            let allAsleep = ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
            if allAsleep { state.asleep = true }
        }
        return state
    }

    // MARK: - Saisie sécurisée

    func secureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: - Activité matérielle

    /// Secondes depuis la dernière activité clavier/souris, -1 si indisponible.
    ///
    /// Mesuré au niveau HID, donc lisible même session verrouillée : c'est le
    /// seul signal qui distingue « économiseur seul à l'écran » de « panneau
    /// d'authentification par‑dessus l'économiseur », les deux états étant
    /// identiques pour le process, les fenêtres et les notifications.
    func hidIdleSeconds() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDSystem"),
                                           &iterator) == KERN_SUCCESS else { return -1 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return -1 }
        defer { IOObjectRelease(entry) }

        guard let value = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return -1 }
        return Double(value.uint64Value) / 1_000_000_000
    }

    // MARK: - Économiseur d'écran : process

    /// Horloge de la politique de balayage : l'horloge monotone du moteur, jamais l'heure murale.
    private let clock: Clock = SystemClock()
    private var scanPolicy = SaverProcessScanPolicy()
    /// PID de `ScreenSaverEngine` trouvé par le dernier balayage, revalidé à chaque lecture (0 : aucun).
    private var cachedEnginePID: Int32 = 0

    func saverProcessHint() {
        scanPolicy.noteHint()
    }

    /// Le PID gardé est relu à chaque appel (un appel système) ; sans PID valide, la table des process
    /// de l'utilisateur n'est balayée que si la politique l'accorde : au premier appel, après un indice,
    /// ou toutes les 5 s.
    func saverEnginePID() -> Int32 {
        if cachedEnginePID != 0 {
            if isOwnSaverEngine(pid: cachedEnginePID) { return cachedEnginePID }
            cachedEnginePID = 0
        }
        guard scanPolicy.shouldScan(now: clock.monotonic()) else { return 0 }
        for process in ownProcesses() where SaverHostRule.isEngine(shortName: Self.shortName(process.kp_proc.p_comm)) {
            cachedEnginePID = process.kp_proc.p_pid
            return cachedEnginePID
        }
        return 0
    }

    /// Process de l'utilisateur qui hébergent un économiseur, avec leur âge. Un balayage complet à
    /// chaque appel : c'est le repli d'un système sans `SACScreenSaverIsRunning`, pas le chemin ordinaire.
    func saverHosts() -> [SaverHost] {
        let now = Date().timeIntervalSince1970
        return ownProcesses().compactMap { process -> SaverHost? in
            let pid = process.kp_proc.p_pid
            guard let path = executablePath(pid: pid), SaverHostRule.isHost(path: path) else { return nil }
            // `p_starttime` est une heure murale (`timeval`) : l'âge se mesure à l'heure murale.
            let started = process.kp_proc.p_starttime
            let launchedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
            return SaverHost(pid: pid, launchedSecondsAgo: max(0, now - launchedAt))
        }
    }

    /// Le PID est-il encore un `ScreenSaverEngine` de l'utilisateur ? Le noyau réutilise les PID : un
    /// process disparu peut avoir cédé le sien à un autre.
    private func isOwnSaverEngine(pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == getuid() && SaverHostRule.isEngine(shortName: Self.shortName(info.pbi_comm))
    }

    /// Les process de l'utilisateur courant (`KERN_PROC_UID`), zombies exclus : ceux des autres comptes
    /// ne sont jamais lus. Vide si la table est illisible. Utilisable depuis n'importe quel contexte, y
    /// compris hors session graphique.
    private func ownProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var margin = 32
        for _ in 0..<4 {
            var length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }

            // Marge : des process naissent entre les deux appels. Si elle ne suffit pas (ENOMEM), on
            // recommence avec une marge plus large.
            let capacity = length / MemoryLayout<kinfo_proc>.stride + margin
            let buffer = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            var size = capacity * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, UInt32(mib.count), buffer, &size, nil, 0) == 0 {
                let count = size / MemoryLayout<kinfo_proc>.stride
                return UnsafeBufferPointer(start: buffer, count: count).filter { Int32($0.kp_proc.p_stat) != SZOMB }
            }
            guard errno == ENOMEM else { return [] }
            margin *= 4
        }
        return []
    }

    /// Chemin de l'exécutable d'un process (`proc_pidpath`), `nil` s'il a disparu ou n'est pas lisible.
    private func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Nom court d'un process (`p_comm` : 16 caractères au plus ; `pbi_comm` : 15, tronqué plus court que
    /// `p_comm`). Lu jusqu'au premier NUL ou à la fin du tableau, jamais au-delà.
    private static func shortName<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: - Économiseur d'écran : SACScreenSaverIsRunning (login.framework)

    private static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
    private typealias SACIsRunning = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int32

    /// Fonction résolue une seule fois (`loadSACFunction`) ; `nil` si login.framework ou le symbole manquent.
    private var sacIsRunning: SACIsRunning?
    private var sacLoadAttempted = false
    /// Codes de retour inattendus déjà signalés : une ligne par valeur, pas une par scrutation. Plafonné,
    /// pour qu'une fonction qui rendrait n'importe quoi ne remplisse ni le journal ni la mémoire.
    private var reportedSACCodes = Set<Int32>()
    private static let maxReportedSACCodes = 8

    /// `SACScreenSaverIsRunning` rend sa valeur par son code de retour : 1 pendant toute une session
    /// d'économiseur, panneau de connexion compris ; 0 hors session, y compris sur un simple verrouillage
    /// (`SaverSessionFlag`). C'est une lecture : elle n'agit ni sur l'écran ni sur l'économiseur.
    func saverSessionFlag() -> Bool? {
        guard let isRunning = loadSACFunction() else { return nil }
        // La signature veut un pointeur valide ; la valeur utile passe par le code de retour (au banc,
        // l'octet n'est jamais écrit).
        var unused: UInt8 = 0
        let code = withUnsafeMutablePointer(to: &unused) { isRunning($0) }
        if let flag = SaverSessionFlag.from(returnCode: code) { return flag }
        if reportedSACCodes.count < Self.maxReportedSACCodes, reportedSACCodes.insert(code).inserted {
            logWarn("SACScreenSaverIsRunning a rendu le code inattendu \(code) : drapeau de session ignoré")
        }
        return nil
    }

    /// Ouvre login.framework et résout la fonction, une seule fois. Un échec se journalise une seule fois
    /// (WARN) et `saverSessionFlag()` rend alors `nil`. Le cadre reste ouvert jusqu'à la fin du process :
    /// le pointeur de fonction doit rester valide.
    private func loadSACFunction() -> SACIsRunning? {
        if sacLoadAttempted { return sacIsRunning }
        sacLoadAttempted = true
        guard let framework = dlopen(Self.loginFrameworkPath, RTLD_LAZY) else {
            let reason = dlerror().map { escapeForLog(String(cString: $0)) } ?? "raison inconnue"
            logWarn("SACScreenSaverIsRunning indisponible : login.framework ne s'ouvre pas (\(reason))")
            return nil
        }
        guard let symbol = dlsym(framework, "SACScreenSaverIsRunning") else {
            logWarn("SACScreenSaverIsRunning indisponible : symbole absent de login.framework")
            return nil
        }
        sacIsRunning = unsafeBitCast(symbol, to: SACIsRunning.self)
        return sacIsRunning
    }

    // MARK: - Économiseur d'écran : fenêtres

    func saverWindow() -> WindowVerdict {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              !list.isEmpty else {
            return .unavailable
        }

        let screen = CGDisplayBounds(CGMainDisplayID())
        let screenArea = Double(screen.width * screen.height)
        let saverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= saverLevel else { continue }
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner.lowercased().contains("screensaver") else { continue }

            // Écarte l'aperçu miniature des Réglages Système : on exige une
            // fenêtre qui couvre réellement l'écran.
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
            if screenArea <= 0 || (width * height) >= 0.5 * screenArea {
                return .visible
            }
        }
        return .notVisible
    }

    // MARK: - Session graphique

    func hasAquaSession() -> Bool {
        CGSessionAvailable()
    }
}

/// Indique si le process voit une session graphique (LaunchAgent Aqua) ou non
/// (LaunchDaemon) : utile pour diagnostiquer les signaux disponibles.
func CGSessionAvailable() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return dict["kCGSSessionUserIDKey"] != nil
}
