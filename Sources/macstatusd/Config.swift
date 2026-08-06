import Foundation

/// Action déclenchée par HomeKit → OFF.
enum OffAction: String {
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

    func strings(_ key: String, _ fallback: [String]) -> [String] {
        switch raw[key] {
        case let v as [String]: return v
        case let v as String where !v.isEmpty: return ["/bin/sh", "-c", v]
        default: return fallback
        }
    }
}

struct Config {
    // --- Webhook Homebridge (compatibilité v4) ---
    var enabled = false
    var webhookBaseURL = ""
    var accessoryID = "mac"
    var webhookTimeoutMS = 4000
    var webhookRetries = 3
    /// Re‑publication périodique de l'état courant : protège contre un webhook
    /// perdu ou un Homebridge redémarré (0 = désactivé).
    var heartbeatSeconds = 60

    // --- Serveur HTTP ---
    var port: UInt16 = 9090
    /// "" = toutes les interfaces, "127.0.0.1" = loopback uniquement.
    var bindAddress = ""
    /// Si non vide, exigé sur /sleep, /wake et /resync (?token=… ou en‑tête X-Auth-Token).
    var authToken = ""

    // --- Moteur d'état ---
    var pollIntervalMS = 500
    /// Durée de stabilité exigée avant de publier un changement (anti‑flap).
    var settleOnMS = 300
    var settleOffMS = 800
    /// Si true : verrouillé + écran allumé mais sans champ d'authentification
    /// (secure input inactif) → OFF. Par défaut false : l'écran de verrouillage
    /// visible est une UI accessible, donc ON. Attention, `loginwindow` peut
    /// conserver la saisie sécurisée après un déverrouillage : signal peu fiable.
    var requireAuthUIWhenLocked = false

    /// Une activité clavier/souris postérieure au démarrage de l'économiseur
    /// signifie que le panneau d'authentification le recouvre → ON.
    var saverDismissOnInput = true
    /// Marge après le démarrage de l'économiseur avant de prendre l'activité en
    /// compte (absorbe l'activité qui a précédé la commande OFF).
    var saverDismissGraceMS = 1500
    /// Inactivité au‑delà de laquelle on considère que macOS est revenu à
    /// l'économiseur après un panneau resté sans réponse.
    var saverRedisplayIdleSeconds = 90

    // --- Commandes ON/OFF ---
    var offAction: OffAction = .screensaver
    /// Si l'action OFF n'est pas confirmée par les faits observés, on escalade
    /// vers l'extinction de l'écran.
    var offEscalateToDisplaySleep = true
    /// Délai laissé à une commande pour être confirmée par les faits observés.
    var commandConfirmTimeoutMS = 12000
    /// Délai avant d'escalader une commande dont les faits ne montrent aucun effet.
    var commandEscalateAfterMS = 2500
    var stopScreensaverOnWake = true
    /// Surcharges facultatives : tableau argv, ou chaîne passée à /bin/sh -c.
    var offCommand: [String] = []
    var wakeCommand: [String] = []

    // --- Journalisation ---
    var logLevel = "info"
    /// "" = automatique (/opt/macstatusd/logs si root, ~/Library/Logs sinon).
    var logFile = ""

    static let knownKeys: Set<String> = [
        "enabled", "webhook_base_url", "accessory_id", "webhook_timeout_ms", "webhook_retries",
        "heartbeat_seconds", "port", "bind_address", "auth_token", "poll_interval_ms",
        "settle_on_ms", "settle_off_ms", "require_auth_ui_when_locked", "off_action",
        "off_escalate_to_display_sleep", "command_confirm_timeout_ms", "command_escalate_after_ms",
        "stop_screensaver_on_wake", "off_command", "wake_command", "log_level", "log_file",
        "saver_dismiss_on_input", "saver_dismiss_grace_ms", "saver_redisplay_idle_seconds",
    ]

    /// Charge la configuration. Un fichier absent ou illisible n'est pas fatal :
    /// on repart des défauts (webhooks désactivés) et on le signale.
    static func load(path: String) -> (config: Config, warnings: [String]) {
        var warnings: [String] = []
        var cfg = Config()

        guard let data = FileManager.default.contents(atPath: path) else {
            warnings.append("config \(path) introuvable → défauts, webhooks désactivés")
            return (cfg, warnings)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [String: Any] else {
            warnings.append("config \(path) illisible (JSON invalide) → défauts, webhooks désactivés")
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
}
