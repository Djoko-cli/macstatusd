import Foundation
import Network
import AppKit
import CoreGraphics

// MARK: - Debug mode

let debugLogging: Bool = CommandLine.arguments.contains("--debug")

func debug(_ msg: String) {
    if debugLogging { print("[DEBUG] \(msg)") }
}

// MARK: - Config

struct Config: Codable {
    let enabled: Bool
    let webhook_base_url: String
    let accessory_id: String

    static var `default`: Config {
        return Config(
            enabled: false,
            webhook_base_url: "",
            accessory_id: "mac"
        )
    }
}

func loadConfig() -> Config {
    let path = "/opt/macstatusd/config.json"
    let url = URL(fileURLWithPath: path)

    do {
        let data = try Data(contentsOf: url)
        let cfg = try JSONDecoder().decode(Config.self, from: data)
        debug("Config loaded: \(cfg)")
        return cfg
    } catch {
        print("WARN: config.json missing or invalid → webhooks disabled (\(error))")
        return Config.default
    }
}

let config = loadConfig()

// MARK: - Global state

var isAsleep = false
var screenSaverActive = false

// Événements loginwindow (éphémères)
var event_shield = false
var event_authUI = false
var event_statusUI = false
var event_unlock = false
var event_lockFromSaver = false

// Buffer d’événements (rempli par le watcher)
var loginwindowEventBuffer = [String]()

// v4.4 — wake + idle logic from 3.4.7
var wakePending = false
var wakeTimeoutTimer: Timer?
var idleTimeoutTimer: Timer?
var idlePollTimer: Timer?
var idleMonitoringActive = false

// MARK: - Session / basic signals

func sessionDict() -> [String: Any]? {
    return CGSessionCopyCurrentDictionary() as? [String: Any]
}

func isScreenLocked() -> Bool {
    guard let dict = sessionDict() else { return false }

    if let b = dict["CGSSessionScreenIsLocked"] as? Bool { return b }
    if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
    return false
}

func isDisplaySleeping() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

func isSystemAsleep() -> Bool {
    return isAsleep
}

// MARK: - Screensaver notifications

let dist = DistributedNotificationCenter.default()

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstart"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = true
    debug("Screensaver → START")
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = false
    debug("Screensaver → STOP")
}

// MARK: - Loginwindow watcher (thread dédié, non bloquant)

let lwProcess = Process()
lwProcess.launchPath = "/usr/bin/log"
lwProcess.arguments = [
    "stream",
    "--style", "compact",
    "--predicate", #"process == "loginwindow""#
]

let lwPipe = Pipe()
lwProcess.standardOutput = lwPipe
lwProcess.launch()

let lwHandle = lwPipe.fileHandleForReading

DispatchQueue.global(qos: .utility).async {
    while true {
        let data = lwHandle.readData(ofLength: 4096)
        if data.isEmpty { continue }
        guard let line = String(data: data, encoding: .utf8) else { continue }

        // On stocke juste les lignes pertinentes dans le buffer
        if line.contains("shieldWindowRaised")
            || line.contains("Raising shield window")
            || line.contains("creating shield window") {
            loginwindowEventBuffer.append("shield")
        }

        if line.contains("set password field placeholder")
            || line.contains("updatePlaceholderString")
            || line.contains("updateFocus")
            || line.contains("CGSSetSecureEventInput")
            || line.contains("screenLockUIIsHidden") {
            loginwindowEventBuffer.append("authUI")
        }

        if line.contains("WiFi viewDidLoad")
            || line.contains("Battery _updateViews")
            || line.contains("Status viewDidLoad") {
            loginwindowEventBuffer.append("statusUI")
        }

        if line.contains("startUnlock")
            || line.contains("unlock failed")
            || line.contains("resetAfterScreenLock") {
            loginwindowEventBuffer.append("unlock")
        }

        if line.contains("kLWLockFromScreenSaverOtherLaunch")
            || line.contains("startScreenLock") {
            loginwindowEventBuffer.append("lockFromSaver")
        }
    }
}

// MARK: - Webhook push

func sendWebhook(state: Bool) {
    guard config.enabled else {
        debug("Webhook disabled by config")
        return
    }

    guard !config.webhook_base_url.isEmpty else {
        debug("Webhook URL empty → skipping")
        return
    }

    let value = state ? "true" : "false"
    let sep = config.webhook_base_url.contains("?") ? "&" : "?"
    let urlString = "\(config.webhook_base_url)\(sep)accessoryId=\(config.accessory_id)&state=\(value)"

    guard let url = URL(string: urlString) else {
        debug("Invalid webhook URL: \(urlString)")
        return
    }

    debug("Webhook → \(value) → \(url.absoluteString)")

    DispatchQueue.global().async {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err = err { debug("Webhook ERROR: \(err)") }
            else { debug("Webhook OK: \(String(describing: resp))") }
        }.resume()
    }
}

// MARK: - Effective State (ON/OFF) — logique 4.4

func effectiveState() -> String {
    let asleep = isSystemAsleep()
    let locked = isScreenLocked()
    let displaySleep = isDisplaySleeping()
    let saver = screenSaverActive

    // 1. Extinction dure
    if asleep || displaySleep {
        return "0"
    }

    // 2. Bureau
    if !locked {
        return "1"
    }

    // 3. Session verrouillée

    // 3.a Screensaver seul → OFF
    if locked && saver && !event_unlock {
        return "0"
    }

    // 3.b Overlay / champ / unlock → ON
    if event_unlock || !saver {
        return "1"
    }

    return "0"
}

var lastEffectiveState: String? = nil

func refreshStateAndNotify() {
    let current = effectiveState()

    if current != lastEffectiveState {
        lastEffectiveState = current
        sendWebhook(state: current == "1")
        debug("State changed → \(current)")
    }
}

func forceRefreshState() {
    lastEffectiveState = nil
    refreshStateAndNotify()
}

// MARK: - HTTP Response

func sendHTTP(_ connection: NWConnection, body: String) {
    let bodyData = body.data(using: .utf8)!
    let response = """
    HTTP/1.1 200 OK\r
    Content-Type: text/plain\r
    Content-Length: \(bodyData.count)\r
    Connection: close\r
    \r
    \(body)
    """
    let responseData = response.data(using: .utf8)!

    connection.send(content: responseData, completion: .contentProcessed({ _ in
        connection.cancel()
    }))
}

// MARK: - System Commands

func putMacToSleep() {
    isAsleep = true
    wakePending = false
    wakeTimeoutTimer?.invalidate()
    idleTimeoutTimer?.invalidate()
    idlePollTimer?.invalidate()
    wakeTimeoutTimer = nil
    idleTimeoutTimer = nil
    idlePollTimer = nil
    idleMonitoringActive = false

    debug("putMacToSleep()")

    let task = Process()
    task.launchPath = "/usr/bin/pmset"
    task.arguments = ["sleepnow"]
    task.launch()

    refreshStateAndNotify()
}

func wakeMac() {
    isAsleep = false
    wakePending = false
    wakeTimeoutTimer?.invalidate()
    idleTimeoutTimer?.invalidate()
    idlePollTimer?.invalidate()
    wakeTimeoutTimer = nil
    idleTimeoutTimer = nil
    idlePollTimer = nil
    idleMonitoringActive = false

    debug("wakeMac()")

    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = [
        "-c",
        "/usr/bin/pmset sleepnow; /bin/sleep 0.1; /usr/bin/caffeinate -u -t 1"
    ]
    task.launch()

    forceRefreshState()
}

// MARK: - HTTP Server

let listener = try! NWListener(using: .tcp, on: 9090)

listener.newConnectionHandler = { connection in
    connection.start(queue: .main)

    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        guard let data = data,
              let request = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        debug("HTTP Request: \(request.prefix(60))…")

        if request.contains("GET /state") {
            sendHTTP(connection, body: effectiveState())
            return
        }

        if request.contains("GET /sleep") {
            putMacToSleep()
            sendHTTP(connection, body: "OK")
            return
        }

        if request.contains("GET /wake") {
            wakeMac()
            sendHTTP(connection, body: "OK")
            return
        }

        sendHTTP(connection, body: "UNKNOWN")
    }
}

// MARK: - v3.4.7 Wake + Idle Timeout + Polling (inchangé)

func stopIdleMonitoring() {
    idleTimeoutTimer?.invalidate()
    idlePollTimer?.invalidate()
    idleTimeoutTimer = nil
    idlePollTimer = nil
    idleMonitoringActive = false
}

func startIdlePolling() {
    idlePollTimer?.invalidate()

    idleMonitoringActive = true

    idlePollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        if !idleMonitoringActive { return }

        if isScreenLocked() && !isAsleep {
            let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID())

            if displayAsleep != 0 {
                debug("Idle polling → écran éteint → OFF immédiat")
                isAsleep = true
                stopIdleMonitoring()
                refreshStateAndNotify()
            }
        } else {
            debug("Idle polling → annulé (unlock ou sleep normal)")
            stopIdleMonitoring()
        }
    }
}

func scheduleWakeTimeout() {
    wakeTimeoutTimer?.invalidate()
    stopIdleMonitoring()

    wakeTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.5, repeats: false) { _ in
        if wakePending && isScreenLocked() && !isAsleep {

            let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID())

            if displayAsleep != 0 {
                debug("Wake timeout → écran éteint → force OFF (pseudo-sleep)")
                isAsleep = true
                wakePending = false
                refreshStateAndNotify()
            } else {
                debug("Wake timeout → écran allumé → activité HID → bascule en idle monitoring")
                wakePending = false
                scheduleIdleTimeout()
            }

        } else {
            debug("Wake timeout annulé (unlock ou déjà asleep)")
            wakePending = false
        }
    }
}

func scheduleIdleTimeout() {
    idleTimeoutTimer?.invalidate()
    startIdlePolling()

    idleTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.5, repeats: false) { _ in
        if isScreenLocked() && !isAsleep {
            let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID())

            if displayAsleep != 0 {
                debug("Idle timeout → écran éteint après interaction → force OFF")
                isAsleep = true
                stopIdleMonitoring()
                refreshStateAndNotify()
            } else {
                debug("Idle timeout → écran allumé → aucune action")
                stopIdleMonitoring()
            }
        } else {
            debug("Idle timeout annulé (unlock ou sleep normal)")
            stopIdleMonitoring()
        }
    }
}

// MARK: - Status line + display wake + HID

let spinnerFrames = ["|", "/", "-", "\\"]
var spinnerIndex = 0

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let frame = spinnerFrames[spinnerIndex % spinnerFrames.count]
    spinnerIndex += 1

    let locked = isScreenLocked()
    let asleep = isSystemAsleep()
    let saver = screenSaverActive
    let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID())

    // 1. Reset des flags événementiels à chaque tick
    event_shield = false
    event_authUI = false
    event_statusUI = false
    event_unlock = false
    event_lockFromSaver = false

    // 2. Consommer le buffer d’événements
    if !loginwindowEventBuffer.isEmpty {
        for ev in loginwindowEventBuffer {
            switch ev {
            case "shield": event_shield = true
            case "authUI": event_authUI = true
            case "statusUI": event_statusUI = true
            case "unlock": event_unlock = true
            case "lockFromSaver": event_lockFromSaver = true
            default: break
            }
        }
        loginwindowEventBuffer.removeAll()
    }

    // 3. Gestion display wake
    if isAsleep && displayAsleep == 0 {
        debug("Display wake détecté avec isAsleep=true → resync ON + réarmement idleTimeout")
        isAsleep = false
        stopIdleMonitoring()
        forceRefreshState()
        if locked {
            scheduleIdleTimeout()
        }
    }

    // 4. Gestion wakePending
    if wakePending && !locked {
        debug("Unlock détecté → annulation wakePending")
        wakePending = false
        wakeTimeoutTimer?.invalidate()
        stopIdleMonitoring()
    }

    // 5. HID activity
    if locked && displayAsleep == 0 {
        if idleMonitoringActive {
            idleTimeoutTimer?.invalidate()
            scheduleIdleTimeout()
            debug("HID activity → idleTimeout réarmé")
        }
    }

    // 6. Affichage état
    let state: String
    if asleep {
        state = "Asleep"
    } else if saver {
        state = "Screensaver"
    } else {
        state = "Awake"
    }

    let line = "[macstatusd 4.4] State: \(state) | Locked: \(locked) | Screensaver: \(saver) | Asleep: \(asleep) | displaySleep: \(displayAsleep != 0) | unlockEvent: \(event_unlock) | shieldEvent: \(event_shield) | authEvent: \(event_authUI) | statusEvent: \(event_statusUI)  \(frame)"

    FileHandle.standardOutput.write(Data("\r\(line)".utf8))

    // 7. Mise à jour ON/OFF
    refreshStateAndNotify()
}

// MARK: - Start

print("macstatusd 4.4 started.")
if debugLogging { print("Debug mode: ON") }

forceRefreshState()

listener.start(queue: .main)
RunLoop.main.run()
