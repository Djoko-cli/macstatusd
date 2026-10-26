import Foundation

/// Action déclenchée par HomeKit → OFF.
public enum OffAction: String {
    /// Démarre l'économiseur d'écran : le Mac reste éveillé et joignable (réversible).
    case screensaver
    /// Éteint l'écran : le Mac reste éveillé et joignable (réversible).
    case displaySleep = "display_sleep"
    /// Vraie veille système : le daemon est gelé, ON nécessite Wake‑on‑LAN.
    case systemSleep = "system_sleep"
}

/// Origine de la configuration chargée.
public enum ConfigOrigin: Equatable {
    /// Fichier lu et compris (des avertissements restent possibles).
    case file
    /// Fichier absent (`ENOENT`) : défauts, comportement permissif d'origine, sauf l'écoute,
    /// limitée à la boucle locale (Ruling R39).
    case defaultsAbsent
    /// Fichier illisible ou invalide : mode dégradé fermé (voir `Config.degraded`). `reason` est
    /// l'erreur POSIX ou celle de l'analyseur JSON, échappée ; jamais le contenu du fichier.
    case invalid(reason: String)
}

/// Sac de valeurs JSON tolérant : une clé absente garde le défaut ; une valeur d'un type
/// inattendu, hors bornes ou non reconnue garde le défaut (ou la borne), avec un avertissement
/// qui commence par le nom de la clé. Les valeurs citées sont échappées ; aucune n'est un secret
/// (`auth_token` et `webhook_base_url` sont traités à part).
private struct JSONBag {
    let raw: [String: Any]
    private(set) var warnings: [String] = []

    /// Que faire d'un entier hors bornes : le ramener à la borne la plus proche, ou garder le défaut.
    enum OutOfRange { case clamp, fallback }

    init(raw: [String: Any], known: Set<String>) {
        self.raw = raw
        let unknown = raw.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty {
            warnings.append("clés de config inconnues ignorées: "
                            + unknown.map { escapeForLog($0, limit: 64) }.joined(separator: ", "))
        }
    }

    mutating func warn(_ message: String) { warnings.append(message) }

    /// Nature d'une valeur JSON, pour les messages (jamais la valeur elle-même).
    static func kind(_ value: Any) -> String {
        switch value {
        case let n as NSNumber: return isBoolean(n) ? "booléen" : "nombre"
        case is String: return "chaîne"
        case is [Any]: return "liste"
        case is [String: Any]: return "objet"
        case is NSNull: return "null"
        default: return "valeur"
        }
    }

    static func isBoolean(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    /// Booléen : `true`/`false`, `0`/`1`, ou une chaîne parmi 1/true/yes/on et 0/false/no/off
    /// (sans casse).
    mutating func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard let value = raw[key] else { return fallback }
        switch value {
        case let text as String:
            switch text.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default:
                warn("\(key)=\"\(escapeForLog(text, limit: 32))\" : booléen non reconnu "
                     + "(true/false, yes/no, on/off ou 1/0) → \(fallback)")
            }
        case let number as NSNumber:
            if Self.isBoolean(number) { return number.boolValue }
            if number.doubleValue == 0 { return false }
            if number.doubleValue == 1 { return true }
            warn("\(key)=\(number.stringValue) : booléen attendu (true/false ou 1/0) → \(fallback)")
        default:
            warn("\(key) : type inattendu (\(Self.kind(value))), booléen attendu → \(fallback)")
        }
        return fallback
    }

    /// Entier : un nombre entier, ou une chaîne qui en contient un (compatibilité).
    mutating func int(_ key: String, _ fallback: Int, min lower: Int, max upper: Int,
                      outOfRange: OutOfRange = .clamp) -> Int {
        guard let value = raw[key] else { return fallback }
        let parsed: Int?
        switch value {
        case let text as String:
            parsed = Int(text)
            if parsed == nil {
                warn("\(key)=\"\(escapeForLog(text, limit: 32))\" : entier attendu → \(fallback)")
            }
        case let number as NSNumber where !Self.isBoolean(number):
            let d = number.doubleValue
            if d.rounded() == d, abs(d) < 1e15 {
                parsed = Int(d)
            } else {
                parsed = nil
                warn("\(key)=\(number.stringValue) : entier attendu → \(fallback)")
            }
        default:
            parsed = nil
            warn("\(key) : type inattendu (\(Self.kind(value))), entier attendu → \(fallback)")
        }
        guard let parsed else { return fallback }
        guard parsed < lower || parsed > upper else { return parsed }
        let corrected = outOfRange == .clamp ? Swift.min(Swift.max(parsed, lower), upper) : fallback
        warn("\(key)=\(parsed) hors bornes (\(lower)…\(upper)) → \(corrected)")
        return corrected
    }

    /// Chaîne, et rien d'autre : un autre type garde le défaut (la valeur n'est pas citée).
    mutating func string(_ key: String, _ fallback: String) -> String {
        guard let value = raw[key] else { return fallback }
        if let text = value as? String { return text }
        warn("\(key) : type inattendu (\(Self.kind(value))), chaîne attendue → défaut")
        return fallback
    }

    /// Liste de chaînes, et rien d'autre (`nil` si la clé est absente ou d'un autre type).
    func stringList(_ key: String) -> [String]? {
        raw[key] as? [String]
    }

    /// Commande : tableau argv, ou chaîne passée à `/bin/sh -c`. Un `argv[0]` qui n'est pas un
    /// chemin absolu est gardé, avec un avertissement : `Process` ne cherche pas dans le `PATH`.
    mutating func command(_ key: String, _ fallback: [String]) -> [String] {
        guard let value = raw[key] else { return fallback }
        switch value {
        case let argv as [String]:
            if let first = argv.first, !first.hasPrefix("/") {
                warn("\(key) : argv[0]=\"\(escapeForLog(first, limit: 64))\" n'est pas un chemin absolu "
                     + "(le PATH n'est pas consulté, la commande échouera sans doute)")
            }
            return argv
        case let text as String:
            return text.isEmpty ? fallback : ["/bin/sh", "-c", text]
        default:
            warn("\(key) : type inattendu (\(Self.kind(value))), liste de chaînes ou chaîne attendue → défaut")
            return fallback
        }
    }
}

/// Destinataire d'un webhook : Homebridge (http-webhooks, GET), Home Assistant (POST), ou tout
/// récepteur HTTP qui confirme par un 2xx.
///
/// - `GET` : l'URL reçoit `?accessoryId=<id>&state=true|false` (ou `&…` si elle a déjà une requête) ;
/// - `POST` : l'URL telle quelle, corps JSON `{"accessoryId": <id>, "state": <booléen>}`.
///
/// `headers` peut porter un secret (jeton, clé) : ses valeurs ne sont jamais journalisées ni
/// montrées dans `/status`, l'URL n'y paraît que masquée (`redactURL`).
public struct WebhookTarget: Equatable {
    public var url: String
    /// "GET" ou "POST", en majuscules.
    public var method: String
    public var headers: [String: String]

    public init(url: String, method: String = "GET", headers: [String: String] = [:]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

public struct Config {
    // --- Webhook Homebridge (compatibilité avec les prototypes 4.x) ---
    public var enabled = false
    public var webhookBaseURL = ""
    /// Cibles du webhook. Lues de `webhook_targets` quand la clé est présente ; à défaut,
    /// `webhook_base_url` non vide donne une cible unique `{url, "GET", [:]}`. Une valeur affectée
    /// (même vide) l'emporte sur `webhookBaseURL`.
    public var webhookTargets: [WebhookTarget] {
        get {
            if let explicitWebhookTargets { return explicitWebhookTargets }
            return webhookBaseURL.isEmpty ? [] : [WebhookTarget(url: webhookBaseURL, method: "GET", headers: [:])]
        }
        set { explicitWebhookTargets = newValue }
    }
    private var explicitWebhookTargets: [WebhookTarget]?
    public var accessoryID = "mac"
    public var webhookTimeoutMS = 4000
    public var webhookRetries = 3
    /// Re‑publication périodique de l'état courant : protège contre un webhook
    /// perdu ou un Homebridge redémarré (0 = désactivé).
    public var heartbeatSeconds = 60
    /// Publie OFF avant de quitter (SIGTERM, SIGINT, SIGHUP), sauf redémarrage prévu (marqueur
    /// `restart-pending`) ou mode dégradé. À `false`, l'arrêt ne publie rien.
    public var publishOffOnExit = true

    // --- Serveur HTTP ---
    public var port: UInt16 = 9090
    /// Adresse d'écoute, sous forme canonique (voir `ListenAddress`) : "" ou "::" = toutes les
    /// interfaces en IPv4 et IPv6, "0.0.0.0" = toutes les interfaces en IPv4 seulement, sinon une
    /// adresse littérale ("127.0.0.1" = boucle locale uniquement). `localhost` vaut "127.0.0.1".
    public var bindAddress = ""
    /// Jeton d'accès. Exigé sur les commandes, et sur les lectures venues d'ailleurs que de
    /// la boucle locale ; passé par l'en-tête `X-Auth-Token` ou `Authorization: Bearer …`.
    /// Vide : seules les requêtes de la boucle locale sont servies (voir `AccessPolicy`).
    public var authToken = ""
    /// Accepte aussi le jeton dans l'URL (`?token=…`). Désactivé par défaut : une URL finit
    /// dans les journaux, l'historique et les en-têtes `Referer`.
    public var allowQueryToken = false
    /// Noms d'hôte acceptés dans l'en-tête `Host`, en plus des adresses littérales, de
    /// `localhost` et des noms `.local` du Mac (comparaison sans casse, sans le port).
    public var allowedHosts: [String] = []

    // --- Moteur d'état ---
    public var pollIntervalMS = 500
    /// Durée de stabilité exigée avant de publier un changement (anti‑flap).
    public var settleOnMS = 300
    public var settleOffMS = 800
    /// Si true : verrouillé + écran allumé mais sans champ d'authentification
    /// (secure input inactif) → OFF. Par défaut false : l'écran de verrouillage
    /// visible est une UI accessible, donc ON. Attention, `loginwindow` peut
    /// conserver la saisie sécurisée après un déverrouillage : signal peu fiable.
    public var requireAuthUIWhenLocked = false

    /// Une activité clavier/souris postérieure au démarrage de l'économiseur
    /// signifie que le panneau d'authentification le recouvre → ON.
    public var saverDismissOnInput = true
    /// Marge après le démarrage de l'économiseur avant de prendre l'activité en
    /// compte (absorbe l'activité qui a précédé la commande OFF).
    public var saverDismissGraceMS = 1500
    /// Inactivité au‑delà de laquelle on considère que macOS est revenu à
    /// l'économiseur après un panneau resté sans réponse.
    public var saverRedisplayIdleSeconds = 90

    // --- Commandes ON/OFF ---
    public var offAction: OffAction = .screensaver
    /// Si l'action OFF n'est pas confirmée par les faits observés, on escalade
    /// vers l'extinction de l'écran.
    public var offEscalateToDisplaySleep = true
    /// Délai laissé à une commande pour être confirmée par les faits observés.
    public var commandConfirmTimeoutMS = 12000
    /// Délai avant d'escalader une commande dont les faits ne montrent aucun effet.
    public var commandEscalateAfterMS = 2500
    public var stopScreensaverOnWake = true
    /// Surcharges facultatives : tableau argv, ou chaîne passée à /bin/sh -c.
    public var offCommand: [String] = []
    public var wakeCommand: [String] = []

    // --- Journalisation ---
    public var logLevel = "info"
    /// "" = automatique (/opt/macstatusd/logs si root, ~/Library/Logs sinon).
    public var logFile = ""

    public init() {}

    static let knownKeys: Set<String> = [
        "enabled", "webhook_base_url", "accessory_id", "webhook_timeout_ms", "webhook_retries",
        "heartbeat_seconds", "publish_off_on_exit", "port", "bind_address", "auth_token", "allow_query_token", "allowed_hosts",
        "poll_interval_ms",
        "settle_on_ms", "settle_off_ms", "require_auth_ui_when_locked", "off_action",
        "off_escalate_to_display_sleep", "command_confirm_timeout_ms", "command_escalate_after_ms",
        "stop_screensaver_on_wake", "off_command", "wake_command", "log_level", "log_file",
        "saver_dismiss_on_input", "saver_dismiss_grace_ms", "saver_redisplay_idle_seconds",
        "webhook_targets",
    ]

    /// Nombre maximal de cibles du webhook ; les suivantes sont écartées.
    public static let maxWebhookTargets = 8

    /// Résultat d'un chargement : la config, son origine et les avertissements (sans secret).
    public typealias Loaded = (config: Config, origin: ConfigOrigin, warnings: [String])

    /// Taille maximale d'un fichier de configuration : au-delà, il est tenu pour invalide.
    static let maxFileBytes = 1 << 20

    /// Charge la configuration depuis un fichier.
    /// - absent (`ENOENT`) : défauts, origine `.defaultsAbsent` (comportement d'origine, permissif,
    ///   mais écoute sur `127.0.0.1` seulement : Ruling R39) ;
    /// - illisible (droits, dossier, trop gros…) ou invalide : `.invalid`, mode dégradé fermé ;
    /// - sinon : `.file`.
    /// Les avertissements « introuvable » et « illisible » citent le chemin.
    public static func load(path: String) -> Loaded {
        switch readFile(path: path) {
        case .success(let data): return parse(data: data, source: path)
        case .failure(.absent): return parse(data: nil, source: path)
        case .failure(.unreadable(let reason)): return invalid(reason: reason, source: path)
        }
    }

    /// Interprète le contenu d'un fichier de configuration (`nil` = fichier absent).
    /// Sans effet de bord : ne lit rien, ne journalise rien, renvoie les avertissements.
    public static func parse(data: Data?) -> Loaded {
        parse(data: data, source: nil)
    }

    /// Configuration du mode dégradé : les défauts, écoute sur la boucle locale seulement, aucun
    /// envoi (ni webhook, ni réessai, ni battement de cœur), aucun jeton lu. Le routeur y répond
    /// 503 aux commandes et à `/health` (voir `Router`).
    public static func degraded() -> Config {
        var cfg = Config()
        cfg.bindAddress = "127.0.0.1"
        cfg.enabled = false
        cfg.webhookBaseURL = ""
        cfg.webhookTargets = []
        cfg.webhookRetries = 0
        cfg.heartbeatSeconds = 0
        cfg.authToken = ""
        return cfg
    }

    /// Argument de `--port` : un entier décimal de 1 à 65535, sans signe ni espace ; sinon `nil`.
    public static func portArgument(_ text: String) -> UInt16? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), (1...65_535).contains(value) else { return nil }
        return UInt16(value)
    }

    /// Message du mode dégradé fermé. `adjective` : « illisible » (lecture ou JSON en échec) ou
    /// « invalide » (JSON lu, mais une valeur interdit de s'en servir).
    ///
    /// `port` : celui du fichier, quand le JSON a été lu (Ruling R43) ; `nil` (fichier illisible ou JSON
    /// invalide) garde le défaut 9090.
    private static func invalid(reason: String, source: String?, adjective: String = "illisible",
                                port: UInt16? = nil) -> Loaded {
        let lieu = source.map { "config \($0)" } ?? "config"
        var config = degraded()
        if let port { config.port = port }
        let warning = "\(lieu) \(adjective) (\(reason)) → mode dégradé fermé : écoute sur "
            + "\(config.bindAddress) seulement, commandes et /health en 503, webhooks coupés"
        return (config, .invalid(reason: reason), [warning])
    }

    private enum ReadError: Error {
        case absent
        case unreadable(String)
    }

    /// Erreur POSIX lisible : « Permission denied (errno 13) ».
    private static func posixReason(_ code: Int32) -> String {
        "\(String(cString: strerror(code))) (errno \(code))"
    }

    /// Lit un fichier ordinaire d'au plus `maxFileBytes` octets. Seul `ENOENT` vaut « absent ».
    private static func readFile(path: String) -> Result<Data, ReadError> {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            return .failure(code == ENOENT ? .absent : .unreadable(posixReason(code)))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable(posixReason(errno))) }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: return .failure(.unreadable(posixReason(EISDIR)))
        default: return .failure(.unreadable("pas un fichier ordinaire"))
        }
        guard Int(info.st_size) <= maxFileBytes else {
            return .failure(.unreadable("fichier trop gros (\(info.st_size) octets, \(maxFileBytes) au plus)"))
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.unreadable(posixReason(errno)))
            }
            data.append(buffer, count: count)
            guard data.count <= maxFileBytes else {
                return .failure(.unreadable("fichier trop gros (plus de \(maxFileBytes) octets)"))
            }
        }
        return .success(data)
    }

    /// Variante interne : `source` (chemin du fichier) est cité dans les avertissements
    /// « introuvable » et « illisible » quand l'appelant le connaît.
    static func parse(data: Data?, source: String?) -> Loaded {
        var cfg = Config()
        let lieu = source.map { "config \($0)" } ?? "config"

        guard let data else {
            // Ruling R39 : sans fichier, aucun jeton, donc le LAN est déjà refusé (sauf `/health`) ;
            // l'écoute se limite à la boucle locale, le reste du comportement permissif est gardé.
            cfg.bindAddress = "127.0.0.1"
            return (cfg, .defaultsAbsent, ["\(lieu) introuvable → défauts, webhooks désactivés",
                                           "config absente : écoute limitée à la boucle locale"])
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            // L'erreur de l'analyseur (position, nature), jamais le contenu du fichier.
            let ns = error as NSError
            let detail = (ns.userInfo["NSDebugDescription"] as? String) ?? ns.localizedDescription
            return invalid(reason: "JSON invalide : \(escapeForLog(detail, limit: 120))", source: source)
        }
        guard let raw = object as? [String: Any] else {
            return invalid(reason: "JSON invalide : objet {…} attendu, \(JSONBag.kind(object)) trouvé",
                           source: source)
        }

        // Un `auth_token` présent qui n'est pas une chaîne (null, nombre, booléen, liste, objet) :
        // mode dégradé fermé. L'ignorer ouvrirait l'écoute sans jeton et laisserait passer les
        // commandes locales sans jeton ; le convertir (`true` → "1") donnerait un jeton faible.
        // La raison ne cite jamais la valeur.
        //
        // Limites connues (à documenter dans le README, plan 4) :
        // - une clé `auth_token` en double garde la dernière valeur, sans avertissement :
        //   `JSONSerialization` ne signale pas les doublons ;
        // - un `auth_token: ""` explicite vaut « aucun jeton » : seule la boucle locale est servie.
        if let token = raw["auth_token"], !(token is String) {
            // Le JSON a été lu : le `port` du fichier est gardé (sans avertissement ici, le mode dégradé
            // en porte déjà un), sinon le défaut ; jamais de repli sur une valeur hors bornes.
            var portBag = JSONBag(raw: raw, known: knownKeys)
            let port = UInt16(portBag.int("port", Int(Config().port), min: 1, max: 65_535, outOfRange: .fallback))
            return invalid(reason: "auth_token doit être une chaîne JSON", source: source, adjective: "invalide",
                           port: port)
        }

        var bag = JSONBag(raw: raw, known: knownKeys)

        cfg.enabled = bag.bool("enabled", cfg.enabled)
        cfg.webhookBaseURL = bag.string("webhook_base_url", cfg.webhookBaseURL)
        cfg.accessoryID = bag.string("accessory_id", cfg.accessoryID)
        cfg.webhookTimeoutMS = bag.int("webhook_timeout_ms", cfg.webhookTimeoutMS, min: 500, max: 60_000)
        cfg.webhookRetries = bag.int("webhook_retries", cfg.webhookRetries, min: 0, max: 10)
        cfg.heartbeatSeconds = bag.int("heartbeat_seconds", cfg.heartbeatSeconds, min: 0, max: 3600)
        cfg.publishOffOnExit = bag.bool("publish_off_on_exit", cfg.publishOffOnExit)

        cfg.port = UInt16(bag.int("port", Int(cfg.port), min: 1, max: 65_535, outOfRange: .fallback))
        if let value = bag.raw["bind_address"] {
            if let text = value as? String, let address = ListenAddress(bindAddress: text) {
                cfg.bindAddress = text.isEmpty ? "" : address.canonical
            } else {
                // Repli fermé (Ruling R32) : une faute de frappe n'ouvre jamais l'écoute à tout le LAN.
                let shown: String
                switch value {
                case let text as String: shown = "\"\(escapeForLog(text, limit: 64))\""
                case let number as NSNumber where !JSONBag.isBoolean(number): shown = number.stringValue
                default: shown = "(\(JSONBag.kind(value)))"
                }
                cfg.bindAddress = "127.0.0.1"
                bag.warn("bind_address=\(shown) invalide (attendu 0.0.0.0, :: ou une adresse IP littérale) → "
                         + "repli fermé, écoute sur \(ListenAddress.ipv4(cfg.bindAddress).description(port: cfg.port)) seulement")
            }
        }
        // Un jeton qui n'est pas une chaîne a déjà donné le mode dégradé (plus haut).
        cfg.authToken = (bag.raw["auth_token"] as? String) ?? cfg.authToken
        for warning in authTokenWarnings(bag.raw["auth_token"]) { bag.warn(warning) }
        cfg.allowQueryToken = bag.bool("allow_query_token", cfg.allowQueryToken)
        if let hosts = bag.stringList("allowed_hosts") {
            cfg.allowedHosts = hosts
        } else if bag.raw["allowed_hosts"] != nil {
            bag.warn("allowed_hosts doit être une liste de noms → []")
        }

        cfg.pollIntervalMS = bag.int("poll_interval_ms", cfg.pollIntervalMS, min: 100, max: 5_000)
        cfg.settleOnMS = bag.int("settle_on_ms", cfg.settleOnMS, min: 0, max: 10_000)
        cfg.settleOffMS = bag.int("settle_off_ms", cfg.settleOffMS, min: 0, max: 10_000)
        cfg.requireAuthUIWhenLocked = bag.bool("require_auth_ui_when_locked", cfg.requireAuthUIWhenLocked)
        cfg.saverDismissOnInput = bag.bool("saver_dismiss_on_input", cfg.saverDismissOnInput)
        cfg.saverDismissGraceMS = bag.int("saver_dismiss_grace_ms", cfg.saverDismissGraceMS, min: 0, max: 60_000)
        cfg.saverRedisplayIdleSeconds = bag.int("saver_redisplay_idle_seconds", cfg.saverRedisplayIdleSeconds, min: 5, max: 3600)

        let offRaw = bag.string("off_action", cfg.offAction.rawValue)
        if let action = OffAction(rawValue: offRaw) {
            cfg.offAction = action
        } else {
            bag.warn("off_action=\"\(escapeForLog(offRaw, limit: 32))\" inconnu → \(cfg.offAction.rawValue)")
        }
        cfg.offEscalateToDisplaySleep = bag.bool("off_escalate_to_display_sleep", cfg.offEscalateToDisplaySleep)
        cfg.commandConfirmTimeoutMS = bag.int("command_confirm_timeout_ms", cfg.commandConfirmTimeoutMS, min: 1_000, max: 60_000)
        cfg.commandEscalateAfterMS = bag.int("command_escalate_after_ms", cfg.commandEscalateAfterMS, min: 500, max: 30_000)
        if cfg.commandEscalateAfterMS >= cfg.commandConfirmTimeoutMS {
            let corrected = cfg.commandConfirmTimeoutMS / 2
            bag.warn("command_escalate_after_ms=\(cfg.commandEscalateAfterMS) ≥ command_confirm_timeout_ms="
                     + "\(cfg.commandConfirmTimeoutMS) → \(corrected)")
            cfg.commandEscalateAfterMS = corrected
        }
        cfg.stopScreensaverOnWake = bag.bool("stop_screensaver_on_wake", cfg.stopScreensaverOnWake)
        cfg.offCommand = bag.command("off_command", cfg.offCommand)
        cfg.wakeCommand = bag.command("wake_command", cfg.wakeCommand)

        cfg.logLevel = bag.string("log_level", cfg.logLevel)
        if !["error", "warn", "warning", "info", "debug", "trace"].contains(cfg.logLevel.lowercased()) {
            bag.warn("log_level=\"\(escapeForLog(cfg.logLevel, limit: 32))\" inconnu → info")
        }
        cfg.logFile = bag.string("log_file", cfg.logFile)

        if let value = bag.raw["webhook_targets"] {
            // `webhook_targets` présent : lui seul décide des cibles, même s'il est illisible.
            cfg.webhookTargets = webhookTargets(from: value, bag: &bag)
            if !cfg.webhookBaseURL.isEmpty {
                bag.warn("webhook_targets et webhook_base_url présents : webhook_targets l'emporte, "
                         + "webhook_base_url ignoré")
            }
            if cfg.enabled && cfg.webhookTargets.isEmpty {
                bag.warn("enabled=true mais aucune cible valide dans webhook_targets → aucun push")
            }
        } else {
            if !cfg.webhookBaseURL.isEmpty {
                let masked = redactURL(cfg.webhookBaseURL)
                if !isUsableWebhookURL(cfg.webhookBaseURL) {
                    // URL masquée : son identifiant de webhook et sa requête n'entrent jamais au journal.
                    bag.warn("webhook_base_url=\(masked) : URL http:// ou https:// attendue, les envois échoueront")
                }
            }
            if cfg.enabled && cfg.webhookBaseURL.isEmpty {
                bag.warn("enabled=true mais webhook_base_url vide → aucun push vers Homebridge")
            }
        }
        return (cfg, .file, bag.warnings)
    }

    /// Vrai pour une URL `http://` ou `https://` lisible, avec un hôte. `redactURL` la lit aussi :
    /// sinon elle ne pourrait même pas être citée au journal.
    static func isUsableWebhookURL(_ text: String) -> Bool {
        guard redactURL(text) != "<url invalide>", let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, URL(string: text) != nil else { return false }
        return true
    }

    /// Lit `webhook_targets` : une liste d'objets `{url, method?, headers?}`. Une cible invalide est
    /// écartée, avec un avertissement « webhook_targets : cible <n> … » (n compté à partir de 1).
    /// Les messages ne citent jamais une valeur d'en-tête, et l'URL seulement masquée.
    private static func webhookTargets(from value: Any, bag: inout JSONBag) -> [WebhookTarget] {
        guard let list = value as? [Any] else {
            bag.warn("webhook_targets : type inattendu (\(JSONBag.kind(value))), liste d'objets attendue → aucune cible")
            return []
        }
        var targets: [WebhookTarget] = []
        for (index, element) in list.enumerated() {
            let label = "webhook_targets : cible \(index + 1)"
            guard targets.count < maxWebhookTargets else {
                bag.warn("webhook_targets : \(list.count) cibles, \(maxWebhookTargets) au plus → les suivantes sont écartées")
                break
            }
            guard let object = element as? [String: Any] else {
                bag.warn("\(label) : type inattendu (\(JSONBag.kind(element))), objet {url, method, headers} attendu → écartée")
                continue
            }
            let unknown = object.keys.filter { !["url", "method", "headers"].contains($0) }.sorted()
            if !unknown.isEmpty {
                bag.warn("\(label) : clés inconnues ignorées: " + unknown.map { escapeForLog($0, limit: 32) }.joined(separator: ", "))
            }
            guard let url = object["url"] as? String, !url.isEmpty else {
                bag.warn("\(label) : url absente ou pas une chaîne → écartée")
                continue
            }
            guard isUsableWebhookURL(url) else {
                bag.warn("\(label) : url=\(redactURL(url)) : URL http:// ou https:// attendue → écartée")
                continue
            }
            var method = "GET"
            if let raw = object["method"] {
                guard let text = raw as? String, ["GET", "POST"].contains(text.uppercased()) else {
                    let shown = (raw as? String).map { "« \(escapeForLog($0, limit: 16)) »" } ?? "(\(JSONBag.kind(raw)))"
                    bag.warn("\(label) : méthode \(shown) non prise en charge (GET ou POST) → écartée")
                    continue
                }
                method = text.uppercased()
            }
            var headers: [String: String] = [:]
            if let raw = object["headers"] {
                guard let dict = raw as? [String: Any] else {
                    bag.warn("\(label) : headers de type \(JSONBag.kind(raw)), objet {nom: valeur} attendu → écartée")
                    continue
                }
                var problem: String?
                for name in dict.keys.sorted() {
                    guard isHeaderName(name) else {
                        problem = "nom d'en-tête « \(escapeForLog(name, limit: 32)) » invalide"
                        break
                    }
                    guard let text = dict[name] as? String else {
                        problem = "valeur de l'en-tête « \(name) » pas une chaîne"
                        break
                    }
                    guard text.count <= 4096, !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                        problem = "valeur de l'en-tête « \(name) » invalide (caractère de contrôle ou plus de 4096 caractères)"
                        break
                    }
                    headers[name] = text
                }
                if let problem {
                    bag.warn("\(label) : \(problem) → écartée")
                    continue
                }
            }
            targets.append(WebhookTarget(url: url, method: method, headers: headers))
        }
        return targets
    }

    /// Nom d'en-tête HTTP : un « token » (RFC 9110) d'au plus 64 caractères.
    private static func isHeaderName(_ name: String) -> Bool {
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !name.isEmpty && name.count <= 64 && name.allSatisfy { allowed.contains($0) }
    }

    /// Avertissements sur `auth_token`, sans jamais citer sa valeur : espaces de bord
    /// (l'analyseur les ôte de l'en-tête reçu : un tel jeton ne correspondrait jamais), moins de
    /// 16 caractères. Absent ou vide : rien ici (traité au démarrage). Pas une chaîne : mode
    /// dégradé, décidé par `parse` avant cet appel.
    static func authTokenWarnings(_ raw: Any?) -> [String] {
        guard let text = raw as? String, !text.isEmpty else { return [] }
        var warnings: [String] = []
        if text.first.map({ $0.isWhitespace }) == true || text.last.map({ $0.isWhitespace }) == true {
            warnings.append("auth_token commence ou finit par une espace : l'en-tête reçu en est débarrassé, "
                            + "aucune requête ne correspondra")
        }
        if text.count < 16 {
            warnings.append("auth_token trop court (\(text.count) caractères, 16 au moins conseillés)")
        }
        return warnings
    }
}

// MARK: - Adresse d'écoute

/// Adresse d'écoute du serveur HTTP, tirée de `bind_address`.
public enum ListenAddress: Equatable {
    /// "" ou "::" : toutes les interfaces, IPv4 et IPv6 (une seule socket double pile).
    case dualStack
    /// "0.0.0.0" : toutes les interfaces, IPv4 seulement.
    case allIPv4
    /// Adresse IPv4 littérale, sous forme canonique.
    case ipv4(String)
    /// Adresse IPv6 littérale, sous forme canonique (`inet_ntop`, minuscules), sans zone.
    case ipv6(String)

    /// `nil` pour tout ce qui n'est ni vide, ni `localhost`, ni une adresse littérale stricte
    /// (un nom d'hôte, un port, des crochets, une zone IPv6, des espaces).
    public init?(bindAddress text: String) {
        if text.isEmpty { self = .dualStack; return }
        if text.lowercased() == "localhost" { self = .ipv4("127.0.0.1"); return }
        guard ipv4Bytes(text) != nil || ipv6Bytes(text) != nil else { return nil }
        // Forme canonique ; une IPv4 mappée (`::ffff:a.b.c.d`) devient l'IPv4.
        let canonical = canonicalAddress(text)
        if canonical == "::" {
            self = .dualStack
        } else if canonical == "0.0.0.0" {
            self = .allIPv4
        } else if ipv4Bytes(canonical) != nil {
            self = .ipv4(canonical)
        } else {
            self = .ipv6(canonical)
        }
    }

    /// Valeur de `Config.bindAddress` : "" garde son sens de défaut, les autres leur forme canonique.
    var canonical: String {
        switch self {
        case .dualStack: return "::"
        case .allIPv4: return "0.0.0.0"
        case .ipv4(let address), .ipv6(let address): return address
        }
    }

    /// Texte exact du message « à l'écoute sur … ».
    public func description(port: UInt16) -> String {
        switch self {
        case .dualStack: return "[::]:\(port) (IPv4+IPv6, toutes interfaces)"
        case .allIPv4: return "0.0.0.0:\(port) (IPv4 seulement, toutes interfaces)"
        case .ipv4(let address): return "\(address):\(port)"
        case .ipv6(let address): return "[\(address)]:\(port)"
        }
    }
}
