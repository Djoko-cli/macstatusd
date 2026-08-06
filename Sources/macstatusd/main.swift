import Foundation
import CoreGraphics

// MARK: - Arguments

struct Options {
    var configPath = macstatusdConfigPath
    var portOverride: UInt16?
    var debug = false
    var foreground = false
    var once = false
    var watch = false
    var disableWebhook = false
    var checkRules = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--config":
            if let value = arguments.first { options.configPath = value; arguments.removeFirst() }
        case "--port":
            if let value = arguments.first, let port = UInt16(value) { options.portOverride = port; arguments.removeFirst() }
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
        case "--check-rules":
            options.checkRules = true
        case "--version", "-v":
            print("macstatusd \(macstatusdVersion)")
            exit(0)
        case "--help", "-h":
            print("""
            macstatusd \(macstatusdVersion) — état ON/OFF du Mac pour Homebridge / HomeKit

            Usage: macstatusd [options]

              --config <chemin>   configuration JSON (défaut: \(macstatusdConfigPath))
              --port <n>          surcharge le port HTTP
              --debug             journalisation détaillée
              --foreground, -f    écrit aussi sur la sortie standard
              --once              affiche l'état et les faits en JSON, puis quitte
              --watch             affiche l'état en continu (diagnostic)
              --check-rules       vérifie la règle de décision de l'économiseur
              --no-webhook        n'envoie rien à Homebridge (tests)
              --version, -v       version
              --help, -h          cette aide

            Endpoints HTTP:
              GET /state    "1" (ON) ou "0" (OFF)  — état publié
              GET /status   diagnostic JSON complet (faits, oracles, webhook)
              GET /health   "OK"
              GET /sleep    HomeKit OFF   (alias /off)
              GET /wake     HomeKit ON    (alias /on)
              GET /resync   republie l'état courant vers Homebridge
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

if options.checkRules {
    print("macstatusd \(macstatusdVersion) — vérification des règles de décision")
    exit(RuleCheck.run())
}

// MARK: - Configuration et journalisation

var (config, configWarnings) = Config.load(path: options.configPath)
if let port = options.portOverride { config.port = port }
if options.disableWebhook { config.enabled = false }

let isTTY = isatty(STDOUT_FILENO) == 1
let logLevel: LogLevel = options.debug ? .debug : LogLevel.parse(config.logLevel)
let logFile: URL? = {
    if options.once || options.watch { return nil }
    if config.logFile.isEmpty { return Log.defaultLogFile() }
    return URL(fileURLWithPath: config.logFile)
}()
Log.shared.configure(level: logLevel, file: logFile, echoToStdout: isTTY || options.foreground || options.debug)

// MARK: - Modes de diagnostic

let webhook = WebhookClient(config: config)
let actions = PowerActions(config: config)
let engine = StateEngine(config: config, webhook: webhook, actions: actions)

if options.once {
    let snapshot = engine.inspect()
    var output = snapshot.facts.asDictionary
    output["state"] = snapshot.state ? "1" : "0"
    output["reason"] = snapshot.reason
    output["session_context"] = CGSessionAvailable() ? "aqua" : "headless"
    output["version"] = macstatusdVersion
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
logInfo("configuration: port=\(config.port) bind=\(config.bindAddress.isEmpty ? "0.0.0.0" : config.bindAddress) "
        + "off_action=\(config.offAction.rawValue) webhook=\(config.enabled ? config.webhookBaseURL : "désactivé") "
        + "poll=\(config.pollIntervalMS)ms settle_on=\(config.settleOnMS)ms settle_off=\(config.settleOffMS)ms "
        + "heartbeat=\(config.heartbeatSeconds)s")
if !CGSessionAvailable() {
    logWarn("aucune session graphique visible : l'économiseur d'écran et l'état des écrans "
            + "peuvent être indétectables. Installer macstatusd comme LaunchAgent (session Aqua).")
}
if let path = Log.shared.currentLogPath { logInfo("journal: \(path)") }

// SIGPIPE tuerait le process lors d'une écriture réseau interrompue.
signal(SIGPIPE, SIG_IGN)

let powerWatcher = PowerWatcher(queue: engine.queue)
engine.attach(to: powerWatcher)
powerWatcher.start()
engine.start()

// MARK: - Routes HTTP

func isAuthorized(_ request: HTTPRequest) -> Bool {
    guard !config.authToken.isEmpty else { return true }
    let provided = request.query["token"] ?? request.headers["x-auth-token"] ?? ""
    guard provided.utf8.count == config.authToken.utf8.count else { return false }
    return provided == config.authToken
}

let server = HTTPServer(port: config.port, bindAddress: config.bindAddress) { request in
    guard request.method == "GET" || request.method == "HEAD" else {
        return .text("method not allowed", status: 405)
    }

    switch request.path {
    case "/state":
        return .text(engine.currentState ? "1" : "0")

    case "/status":
        return .json(engine.statusSnapshot())

    case "/health":
        return .text("OK")

    case "/sleep", "/off":
        guard isAuthorized(request) else { return .text("unauthorized", status: 401) }
        engine.requestOff(source: request.peer)
        return .text("OK")

    case "/wake", "/on":
        guard isAuthorized(request) else { return .text("unauthorized", status: 401) }
        engine.requestOn(source: request.peer)
        return .text("OK")

    case "/resync":
        guard isAuthorized(request) else { return .text("unauthorized", status: 401) }
        engine.resync()
        return .text("OK")

    default:
        return .text("not found", status: 404)
    }
}
server.start()

// MARK: - Arrêt propre

let signalQueue = DispatchQueue(label: "macstatusd.signals")
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        logInfo("signal \(number) reçu → arrêt")
        server.stop()
        Log.shared.flush()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

RunLoop.main.run()
