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

/// Sac de valeurs JSON tolérant : une clé absente ou d'un type inattendu
/// retombe sur le défaut au lieu de faire échouer tout le fichier.
private struct JSONBag {
    let raw: [String: Any]
    private(set) var unknownKeys: [String] = []
    private let known: Set<String>

    init(raw: [String: Any], known: Set<String>) {
        self.raw = raw
        self.known = known
        self.unknownKeys = raw.keys.filter { !known.contains($0) }.sorted()
    }

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        switch raw[key] {
        case let v as Bool: return v
        case let v as NSNumber: return v.boolValue
        case let v as String: return ["1", "true", "yes", "on"].contains(v.lowercased())
        default: return fallback
        }
    }

    func int(_ key: String, _ fallback: Int, min lower: Int = Int.min, max upper: Int = Int.max) -> Int {
        let value: Int
        switch raw[key] {
        case let v as Int: value = v
        case let v as NSNumber: value = v.intValue
        case let v as String: value = Int(v) ?? fallback
        default: return fallback
        }
        return Swift.min(Swift.max(value, lower), upper)
    }

    func string(_ key: String, _ fallback: String) -> String {
        switch raw[key] {
        case let v as String: return v
        case let v as NSNumber: return v.stringValue
        default: return fallback
        }
    }

    /// Liste de chaînes, et rien d'autre (`nil` si la clé est absente ou d'un autre type).
    func stringList(_ key: String) -> [String]? {
        raw[key] as? [String]
    }

    func strings(_ key: String, _ fallback: [String]) -> [String] {
        switch raw[key] {
        case let v as [String]: return v
        case let v as String where !v.isEmpty: return ["/bin/sh", "-c", v]
        default: return fallback
        }
    }
}

public struct Config {
    // --- Webhook Homebridge (compatibilité avec les prototypes 4.x) ---
    public var enabled = false
    public var webhookBaseURL = ""
    public var accessoryID = "mac"
    public var webhookTimeoutMS = 4000
    public var webhookRetries = 3
    /// Re‑publication périodique de l'état courant : protège contre un webhook
    /// perdu ou un Homebridge redémarré (0 = désactivé).
    public var heartbeatSeconds = 60

    // --- Serveur HTTP ---
    public var port: UInt16 = 9090
    /// "" = toutes les interfaces, "127.0.0.1" = loopback uniquement.
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
        "heartbeat_seconds", "port", "bind_address", "auth_token", "allow_query_token", "allowed_hosts",
        "poll_interval_ms",
        "settle_on_ms", "settle_off_ms", "require_auth_ui_when_locked", "off_action",
        "off_escalate_to_display_sleep", "command_confirm_timeout_ms", "command_escalate_after_ms",
        "stop_screensaver_on_wake", "off_command", "wake_command", "log_level", "log_file",
        "saver_dismiss_on_input", "saver_dismiss_grace_ms", "saver_redisplay_idle_seconds",
    ]

    /// Charge la configuration depuis un fichier. Un fichier absent ou illisible n'est pas
    /// fatal : on repart des défauts (webhooks désactivés) et on le signale, chemin compris.
    public static func load(path: String) -> (config: Config, warnings: [String]) {
        parse(data: FileManager.default.contents(atPath: path), source: path)
    }

    /// Interprète le contenu d'un fichier de configuration (`nil` = fichier absent).
    /// Sans effet de bord : ne lit rien, ne journalise rien, renvoie les avertissements.
    public static func parse(data: Data?) -> (config: Config, warnings: [String]) {
        parse(data: data, source: nil)
    }

    /// Variante interne : `source` (chemin du fichier) est cité dans les avertissements
    /// « introuvable » et « illisible » quand l'appelant le connaît.
    static func parse(data: Data?, source: String?) -> (config: Config, warnings: [String]) {
        var warnings: [String] = []
        var cfg = Config()
        let lieu = source.map { "config \($0)" } ?? "config"

        guard let data else {
            warnings.append("\(lieu) introuvable → défauts, webhooks désactivés")
            return (cfg, warnings)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [String: Any] else {
            warnings.append("\(lieu) illisible (JSON invalide) → défauts, webhooks désactivés")
            return (cfg, warnings)
        }

        let bag = JSONBag(raw: raw, known: knownKeys)
        if !bag.unknownKeys.isEmpty {
            warnings.append("clés de config inconnues ignorées: \(bag.unknownKeys.joined(separator: ", "))")
        }

        cfg.enabled = bag.bool("enabled", cfg.enabled)
        cfg.webhookBaseURL = bag.string("webhook_base_url", cfg.webhookBaseURL)
        cfg.accessoryID = bag.string("accessory_id", cfg.accessoryID)
        cfg.webhookTimeoutMS = bag.int("webhook_timeout_ms", cfg.webhookTimeoutMS, min: 500, max: 60_000)
        cfg.webhookRetries = bag.int("webhook_retries", cfg.webhookRetries, min: 0, max: 10)
        cfg.heartbeatSeconds = bag.int("heartbeat_seconds", cfg.heartbeatSeconds, min: 0, max: 3600)

        cfg.port = UInt16(bag.int("port", Int(cfg.port), min: 1, max: 65_535))
        cfg.bindAddress = bag.string("bind_address", cfg.bindAddress)
        cfg.authToken = bag.string("auth_token", cfg.authToken)
        warnings += authTokenWarnings(bag.raw["auth_token"])
        cfg.allowQueryToken = bag.bool("allow_query_token", cfg.allowQueryToken)
        if let hosts = bag.stringList("allowed_hosts") {
            cfg.allowedHosts = hosts
        } else if bag.raw["allowed_hosts"] != nil {
            warnings.append("allowed_hosts doit être une liste de noms → []")
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
            warnings.append("off_action=\"\(offRaw)\" inconnu → \(cfg.offAction.rawValue)")
        }
        cfg.offEscalateToDisplaySleep = bag.bool("off_escalate_to_display_sleep", cfg.offEscalateToDisplaySleep)
        cfg.commandConfirmTimeoutMS = bag.int("command_confirm_timeout_ms", cfg.commandConfirmTimeoutMS, min: 1_000, max: 60_000)
        cfg.commandEscalateAfterMS = bag.int("command_escalate_after_ms", cfg.commandEscalateAfterMS, min: 500, max: 30_000)
        if cfg.commandEscalateAfterMS >= cfg.commandConfirmTimeoutMS {
            cfg.commandEscalateAfterMS = cfg.commandConfirmTimeoutMS / 2
        }
        cfg.stopScreensaverOnWake = bag.bool("stop_screensaver_on_wake", cfg.stopScreensaverOnWake)
        cfg.offCommand = bag.strings("off_command", cfg.offCommand)
        cfg.wakeCommand = bag.strings("wake_command", cfg.wakeCommand)

        cfg.logLevel = bag.string("log_level", cfg.logLevel)
        cfg.logFile = bag.string("log_file", cfg.logFile)

        if cfg.enabled && cfg.webhookBaseURL.isEmpty {
            warnings.append("enabled=true mais webhook_base_url vide → aucun push vers Homebridge")
        }
        return (cfg, warnings)
    }

    /// Avertissements sur `auth_token`, sans jamais citer sa valeur : pas une chaîne, espaces
    /// de bord (l'analyseur les ôte de l'en-tête reçu : un tel jeton ne correspondrait jamais),
    /// moins de 16 caractères. Absent ou vide : rien ici (traité au démarrage).
    static func authTokenWarnings(_ raw: Any?) -> [String] {
        guard let raw else { return [] }
        guard let text = raw as? String else {
            return ["auth_token doit être une chaîne JSON (entre guillemets)"]
        }
        guard !text.isEmpty else { return [] }
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
