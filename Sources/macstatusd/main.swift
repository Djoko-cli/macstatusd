import Foundation
import CoreGraphics
import MacStatusCore

// SIGPIPE tuerait le process lors d'une écriture sur un tube ou un socket fermé (écho du journal
// vers `| head`, réponse réseau interrompue) : ignoré dès le départ, les écritures rendent EPIPE.
signal(SIGPIPE, SIG_IGN)

// Les messages de la bibliothèque passent par ce journal : à brancher avant tout le reste.
CoreLog.sink = Log.shared

// MARK: - Arguments

struct Options {
    var configPath = macstatusdConfigPath
    var portOverride: UInt16?
    var debug = false
    var foreground = false
    var once = false
    var watch = false
    var disableWebhook = false
}

/// Erreur d'usage : message sur stderr, code de sortie 2, avant toute lecture ou écoute.
func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("macstatusd: \(message) (--help pour l'aide)\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--config":
            // Une option à la place du chemin (`--config --once`) compte comme une valeur absente.
            guard let value = arguments.first, !value.isEmpty, !value.hasPrefix("-") else {
                usageError("--config attend un chemin de fichier")
            }
            options.configPath = value
            arguments.removeFirst()
        case "--port":
            guard let value = arguments.first else { usageError("--port attend un numéro de port (1 à 65535)") }
            guard let port = Config.portArgument(value) else {
                usageError("--port \"\(escapeForLog(value, limit: 32))\" invalide : entier de 1 à 65535 attendu")
            }
            options.portOverride = port
            arguments.removeFirst()
        case "--debug":
            options.debug = true
        case "--foreground", "-f":
            options.foreground = true
        case "--once":
            options.once = true
        case "--watch":
            options.watch = true
        case "--no-webhook":
            options.disableWebhook = true
        case "--version", "-v":
            print("macstatusd \(macstatusdVersion)")
            exit(0)
        case "--help", "-h":
            print("""
            macstatusd \(macstatusdVersion) — état ON/OFF du Mac pour Homebridge / HomeKit

            Usage: macstatusd [options]

              --config <chemin>   configuration JSON (défaut: \(macstatusdConfigPath))
              --port <n>          surcharge le port HTTP (1 à 65535)
              --debug             journalisation détaillée
              --foreground, -f    écrit aussi sur la sortie standard
              --once              affiche l'état et les faits en JSON, puis quitte
              --watch             affiche l'état en continu (diagnostic)
              --no-webhook        n'envoie aucun webhook (tests)
              --version, -v       version
              --help, -h          cette aide

            Endpoints HTTP:
              GET /state    "1" (ON) ou "0" (OFF)  — état publié
              GET /status   diagnostic JSON complet (faits, oracles, webhook)
              GET /health   "OK"
              GET /sleep    HomeKit OFF   (alias /off)
              GET /wake     HomeKit ON    (alias /on)
              GET /resync   republie l'état courant vers les cibles du webhook

            Accès : jeton par l'en-tête X-Auth-Token ou Authorization: Bearer (auth_token).
            Commandes : jeton exigé. Lectures : jeton exigé hors boucle locale.
            Sans jeton configuré : boucle locale seulement. /health est toujours servi.
            Config absente : écoute sur 127.0.0.1 seulement.
            Config illisible ou invalide : mode dégradé (écoute sur 127.0.0.1 seulement,
            commandes et /health en 503, aucun webhook, config_error dans /status).
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("macstatusd: option inconnue \(argument)\n".utf8))
            exit(2)
        }
    }
    return options
}

let options = parseOptions()

// Sortie ligne par ligne même quand elle est redirigée (journaux launchd, pipes).
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Configuration et journalisation

let loadedConfig = Config.load(path: options.configPath)
var config = loadedConfig.config
let configOrigin = loadedConfig.origin
let configWarnings = loadedConfig.warnings
if let port = options.portOverride { config.port = port }
if options.disableWebhook { config.enabled = false }
/// Raison du mode dégradé, ou `nil` si la config est utilisable.
let configError: String? = {
    if case .invalid(let reason) = configOrigin { return reason }
    return nil
}()
if configError != nil {
    // Mode dégradé fermé, quoi qu'aient fait les options : boucle locale, aucun envoi.
    config.bindAddress = "127.0.0.1"
    config.enabled = false
}

let isTTY = isatty(STDOUT_FILENO) == 1
let logLevel: LogLevel = options.debug ? .debug : LogLevel.parse(config.logLevel)
let logFile: URL? = {
    if options.once || options.watch { return nil }
    if config.logFile.isEmpty { return Log.defaultLogFile() }
    return URL(fileURLWithPath: config.logFile)
}()
Log.shared.configure(level: logLevel, file: logFile, echoToStdout: isTTY || options.foreground || options.debug)

// MARK: - Modes de diagnostic

// `--once` et `--watch` n'écrivent pas de journal : les avertissements de config vont sur stderr
// (la sortie standard de `--once` reste un JSON lisible par un script).
if options.once || options.watch {
    for warning in configWarnings {
        FileHandle.standardError.write(Data("macstatusd: config: \(warning)\n".utf8))
    }
}

let actions = PowerActions(config: config)
let engine = EngineRunner(config: config, actions: actions)

if options.once {
    let snapshot = engine.inspect()
    var output = snapshot.facts.asDictionary
    output["state"] = snapshot.state ? "1" : "0"
    output["reason"] = snapshot.reason
    output["session_context"] = CGSessionAvailable() ? "aqua" : "headless"
    output["version"] = macstatusdVersion
    if let configError { output["config_error"] = configError }
    let data = (try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

if options.watch {
    print("macstatusd \(macstatusdVersion) — surveillance (Ctrl-C pour quitter)")
    print("état raison                    veille écran_off saver                     idleHID verrou         login écrans")
    let interval = Double(config.pollIntervalMS) / 1000
    let watchTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macstatusd.watch"))
    watchTimer.schedule(deadline: .now(), repeating: interval)
    watchTimer.setEventHandler {
        let snapshot = engine.inspect()
        let facts = snapshot.facts
        func column(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : value.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        func yesNo(_ value: Bool) -> String { value ? "oui" : "non" }
        print(column(snapshot.state ? "ON" : "OFF", 5)
              + column(snapshot.reason, 26)
              + column(yesNo(facts.systemAsleep), 7)
              + column(yesNo(facts.displayAsleep), 10)
              + column("\(yesNo(facts.screenSaverActive)):\(facts.screenSaverEvidence)", 26)
              + column(String(format: "%.1f", facts.hidIdleSeconds), 8)
              + column("\(yesNo(facts.sessionLocked)):\(facts.lockEvidence)", 15)
              + column(yesNo(facts.consoleUserLoggedIn), 6)
              + "\(facts.onlineDisplays)")
    }
    watchTimer.resume()
    RunLoop.main.run()
    exit(0)
}

// MARK: - Démarrage du daemon

logInfo("macstatusd \(macstatusdVersion) démarrage — uid=\(getuid()) session=\(CGSessionAvailable() ? "aqua" : "headless") config=\(options.configPath)")
for warning in configWarnings { logWarn("config: \(warning)") }
if let configError {
    logError("mode dégradé : config \(options.configPath) invalide (\(configError)). Écoute sur 127.0.0.1 "
             + "seulement, commandes et /health → 503, aucun webhook ni battement de cœur. "
             + "Corriger le fichier, puis redémarrer macstatusd.")
}
let listenDescription = (ListenAddress(bindAddress: config.bindAddress) ?? .ipv4("127.0.0.1")).description(port: config.port)
/// Cibles du webhook pour le journal : méthode et URL masquée, noms d'en-têtes seulement.
let webhookDescription: String = {
    guard config.enabled else { return "désactivé" }
    let targets = config.webhookTargets
    guard !targets.isEmpty else { return "aucune cible" }
    return targets.map { target in
        let names = target.headers.keys.sorted()
        return "\(target.method) \(redactURL(target.url))" + (names.isEmpty ? "" : " (en-têtes : \(names.joined(separator: ", ")))")
    }.joined(separator: " | ")
}()
logInfo("configuration: port=\(config.port) écoute=\(listenDescription) "
        + "off_action=\(config.offAction.rawValue) webhook=\(webhookDescription) "
        + "poll=\(config.pollIntervalMS)ms settle_on=\(config.settleOnMS)ms settle_off=\(config.settleOffMS)ms "
        + "heartbeat=\(config.heartbeatSeconds)s")
if !CGSessionAvailable() {
    logWarn("aucune session graphique visible : l'économiseur d'écran et l'état des écrans "
            + "peuvent être indétectables. Installer macstatusd comme LaunchAgent (session Aqua).")
}
if let path = Log.shared.currentLogPath { logInfo("journal: \(path)") }

let powerWatcher = PowerWatcher(queue: engine.queue)
engine.attach(to: powerWatcher)
powerWatcher.start()
engine.start()

// Retour du réseau : renvoi immédiat aux cibles non confirmées (pas de surveillance sans cible).
let networkWatcher = NetworkWatcher()
if config.enabled && !config.webhookTargets.isEmpty {
    networkWatcher.onAvailable = { engine.networkBecameAvailable() }
    networkWatcher.start()
}

// MARK: - Serveur HTTP

let localNames = LocalNames.current()
// Ni les noms ni le jeton au journal : seulement leur nombre et la présence du jeton.
logInfo("contrôle de Host : \(localNames.count) nom(s) local(aux) du Mac, "
        + "\(config.allowedHosts.count) hôte(s) autorisé(s) par la config, "
        + "jeton dans l'URL \(config.allowQueryToken ? "accepté" : "refusé")")
if config.authToken.isEmpty {
    if bindAddressIsLoopbackOnly(config.bindAddress) {
        logWarn("aucun jeton configuré (auth_token) : seules les requêtes de la boucle locale sont servies")
    } else {
        logError("aucun jeton configuré (auth_token) alors que l'écoute est ouverte sur \(listenDescription) : "
                 + "toute requête venue du réseau sera refusée (403), Home Assistant et Homebridge compris. "
                 + "Définir auth_token, ou bind_address à 127.0.0.1.")
    }
}

let router = Router(config: config, engine: engine, localNames: localNames, origin: configOrigin)
let server = HTTPServer(port: config.port, bindAddress: config.bindAddress, router: router)
// Une seule instance publie : celle dont le serveur détient le port (et dont la session est à la console).
server.onListenerStatusChange = { engine.listenerStatusChanged($0) }
server.start()

// MARK: - Arrêt propre

/// Termine le processus : le journal est vidé d'abord. Appelé une seule fois par `ShutdownGuard`.
func quitDaemon() {
    Log.shared.flush()
    exit(0)
}

let signalQueue = DispatchQueue(label: "macstatusd.signals")
// Le filet (3 s) tourne sur la file des signaux, pas sur celle du moteur : il doit jouer
// aussi quand la file du moteur ne répond plus. Sous l'ExitTimeOut de 5 s du plist.
let shutdownGuard = ShutdownGuard(scheduler: DispatchScheduler(queue: signalQueue), terminate: quitDaemon)
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        logInfo("signal \(number) reçu → arrêt")
        shutdownGuard.begin { finished in
            // Le marqueur est consommé même en mode dégradé : un marqueur resté en place
            // ne doit pas survivre à cet arrêt.
            let marker = RestartMarker.consume(in: RestartMarker.supportDirectory())
            let decision = ShutdownPolicy.decide(degraded: configError != nil,
                                                 publishOffOnExit: config.publishOffOnExit,
                                                 marker: marker)
            logInfo("arrêt : \(decision.publishOff ? "OFF sera publié" : "rien ne sera publié") (\(decision.reason))")
            engine.shutdown(publishOff: decision.publishOff) {
                logInfo("arrêt terminé")
                finished()
            }
        }
    }
    source.resume()
    signalSources.append(source)
}

RunLoop.main.run()
