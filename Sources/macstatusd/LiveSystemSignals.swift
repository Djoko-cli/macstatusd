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
///   même hors session graphique. `CGSessionCopyCurrentDictionary` (un aller-retour avec le serveur de fenêtres)
///   n'est lue que si le registre ne suffit pas, selon `ConsoleOwnership.cgSessionRole`.
/// - écrans : les écrans en ligne et leur veille (`CGGetOnlineDisplayList`, `CGDisplayIsAsleep`), avec leur
///   fournisseur et leur modèle (lus une fois par identifiant) pour que le cœur reconnaisse l'écran fantôme.
/// - inactivité : `HIDIdleTime` du service `IOHIDSystem`, résolu une fois et gardé.
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
        if hidService != 0 { IOObjectRelease(hidService) }
    }

    // MARK: - Verrouillage / session

    func session() -> SessionState {
        var state = SessionState()
        var evidence: [String] = []
        var consoleUsers: [[String: Any]]?

        // 1. IORegistry : fonctionne aussi depuis un LaunchDaemon hors session.
        if registryRoot != 0 {
            if let value = registryProperty("IOConsoleLocked") as? NSNumber, value.boolValue {
                state.locked = true
                evidence.append("IOConsoleLocked")
            }
            consoleUsers = registryProperty("IOConsoleUsers") as? [[String: Any]]
            if let console = ConsoleOwnership.consoleEntry(in: consoleUsers) {
                if (console["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue == true {
                    state.loggedIn = true
                }
                if (console["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
                    state.locked = true
                    evidence.append("IOConsoleUsers")
                }
            }
        }

        // 2. Session graphique courante, disponible quand on tourne dans Aqua. Un aller-retour avec le serveur de
        //    fenêtres à chaque lecture : la règle pure du cœur dit si elle est lue, et pour quoi faire. Session à la
        //    console (le cas courant) : jamais lue.
        let role = ConsoleOwnership.cgSessionRole(consoleUsers: consoleUsers)
        var cgSession: [String: Any]?
        if role != .notRead {
            cgSession = CGSessionCopyCurrentDictionary() as? [String: Any]
        }
        // Source complète (verrouillage, ouverture de session) seulement si le registre ne répond pas. Quand il répond
        // sans entrée à la console (fenêtre de connexion d'un changement rapide d'utilisateur), cette session est celle de
        // l'agent, passée en arrière-plan : elle ne sert qu'à la décision de console ci-dessous, et donnerait la session
        // de la console pour ouverte à tort.
        if role == .fullFallback, let dict = cgSession {
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

    /// Fournisseur et modèle de chaque écran en ligne, lus une fois par identifiant plutôt qu'à chaque
    /// scrutation. Un identifiant qui sort de la liste en ligne est oublié, pour que le système puisse le rendre
    /// à un autre écran.
    private var displayIdentities: [CGDirectDisplayID: (vendor: UInt32, model: UInt32)] = [:]

    /// Les écrans en ligne, chacun avec son état de veille, et le principal. Aucune interprétation ici : le
    /// cœur (`DisplayTopology`) reconnaît l'écran fantôme et décide de l'extinction. Une énumération qui échoue
    /// rend une liste vide et `enumerationOK` faux : rien n'est prouvé.
    func displaySnapshot() -> DisplaySnapshot {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
            return DisplaySnapshot(displays: [], enumerationOK: false)
        }
        guard count > 0 else { return DisplaySnapshot(displays: [], enumerationOK: true) }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return DisplaySnapshot(displays: [], enumerationOK: false)
        }
        let online = Array(ids.prefix(Int(count)))

        let main = CGMainDisplayID()
        let displays = online.map { id -> DisplayInfo in
            let identity = displayIdentities[id] ?? (vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id))
            displayIdentities[id] = identity
            return DisplayInfo(id: id, vendor: identity.vendor, model: identity.model,
                               asleep: CGDisplayIsAsleep(id) != 0, isMain: id == main)
        }
        displayIdentities = displayIdentities.filter { online.contains($0.key) }
        return DisplaySnapshot(displays: displays, enumerationOK: true)
    }

    // MARK: - Saisie sécurisée

    func secureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: - Activité matérielle

    /// Le service `IOHIDSystem`, résolu une fois puis gardé (0 : à résoudre), libéré au `deinit` : c'est le même d'une
    /// lecture à l'autre, inutile de le chercher dans le registre à chacune.
    private var hidService: io_service_t = 0

    /// Secondes depuis la dernière activité clavier/souris, -1 si indisponible.
    ///
    /// Mesuré au niveau HID, donc lisible même session verrouillée : c'est le
    /// seul signal du système qui distingue « économiseur seul à l'écran » de
    /// « panneau d'authentification par‑dessus l'économiseur », les deux états
    /// étant identiques pour SAC, le process, les fenêtres et les notifications.
    ///
    /// Le service gardé qui ne répond plus est lâché et résolu de nouveau, une fois dans le même appel. Un service
    /// tout juste résolu qui ne répond pas n'est pas gardé : l'appel suivant recommence.
    func hidIdleSeconds() -> Double {
        if hidService != 0 {
            if let seconds = Self.hidIdleTime(of: hidService) { return seconds }
            IOObjectRelease(hidService)
            hidService = 0
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return -1 }
        guard let seconds = Self.hidIdleTime(of: service) else {
            IOObjectRelease(service)
            return -1
        }
        hidService = service
        return seconds
    }

    /// `HIDIdleTime` (nanosecondes) du service, en secondes ; `nil` si la propriété ne se lit pas.
    private static func hidIdleTime(of service: io_service_t) -> Double? {
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
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

    /// `int SACScreenSaverIsRunning(void)` : aucun argument (désassemblage de login.framework) ; la valeur passe par
    /// le code de retour.
    private typealias SACIsRunning = @convention(c) () -> Int32

    /// Fonction résolue une seule fois (`loadSACFunction`) ; `nil` si login.framework ou le symbole manquent.
    private var sacIsRunning: SACIsRunning?
    private var sacLoadAttempted = false
    /// Garde contre un changement futur de la fonction : sur macOS 27 elle ne rend que 0 ou 1, jamais un autre code.
    /// Si elle en rendait un, le WARN le nomme, une fois par valeur et au plus `maxReportedSACCodes` valeurs, pour
    /// qu'une fonction qui rendrait n'importe quoi ne remplisse ni le journal ni la mémoire.
    private var reportedSACCodes = Set<Int32>()
    private static let maxReportedSACCodes = 8

    /// `SACScreenSaverIsRunning` : 1 pendant toute une session d'économiseur, panneau de connexion compris ; 0 hors
    /// session, y compris sur un simple verrouillage (`SaverSessionFlag`). C'est une lecture : elle n'agit ni sur
    /// l'écran ni sur l'économiseur. Elle part en appel XPC synchrone vers l'agent de session.
    ///
    /// **0 aussi quand l'agent de session ne répond pas** : une liaison XPC en échec rend 0, indiscernable de « hors
    /// session ». Le repli sur l'hôte (`nil`) ne couvre que l'absence de la fonction, pas cette panne ; le WARN
    /// « didstart non corroboré », à chaque économiseur, en est alors le seul signe.
    func saverSessionFlag() -> Bool? {
        guard let isRunning = loadSACFunction() else { return nil }
        let code = isRunning()
        if let flag = SaverSessionFlag.from(returnCode: code) { return flag }
        if reportedSACCodes.count < Self.maxReportedSACCodes, reportedSACCodes.insert(code).inserted {
            logWarn("SACScreenSaverIsRunning a rendu le code inattendu \(code) : drapeau de session ignoré")
        }
        return nil
    }

    /// Résout la fonction (login.framework s'ouvre une seule fois pour tout le process : `LoginFramework`), une
    /// seule fois. Un échec se journalise une seule fois (WARN) et `saverSessionFlag()` rend alors `nil`.
    private func loadSACFunction() -> SACIsRunning? {
        if sacLoadAttempted { return sacIsRunning }
        sacLoadAttempted = true
        guard let symbol = LoginFramework.symbol("SACScreenSaverIsRunning") else { return nil }
        sacIsRunning = unsafeBitCast(symbol, to: SACIsRunning.self)
        return sacIsRunning
    }

    // MARK: - Session graphique

    func hasAquaSession() -> Bool {
        isAquaSession()
    }
}

/// Indique si le process voit une session graphique (LaunchAgent Aqua) ou non (LaunchDaemon) : utile pour
/// diagnostiquer les signaux disponibles. Lue une seule fois, au premier appel (le journal de démarrage), puis
/// gardée : la session d'un process ne change pas pendant sa vie, et la lire est un aller-retour avec launchd et le
/// serveur de fenêtres, que `/status` paierait à chaque requête.
func isAquaSession() -> Bool { cachedAquaSession }

private let cachedAquaSession: Bool = {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return dict["kCGSSessionUserIDKey"] != nil
}()
