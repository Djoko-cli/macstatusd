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

// v3.4.7 — wake + post-interaction + polling écran + resync display wake + cycles infinis + config JSON générique
var wakePending = false
var wakeTimeoutTimer: Timer?
var idleTimeoutTimer: Timer?
var idlePollTimer: Timer?
var idleMonitoringActive = false

// MARK: - Lock state

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }

    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber { return lockedNum.boolValue }

    return false
}

// MARK: - Sleep state

func isSystemAsleep() -> Bool {
    return isAsleep
}

// MARK: - Webhook push (generic client)

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

// MARK: - Effective State (ON/OFF)

func effectiveState() -> String {
    let asleep = isSystemAsleep()
    let saver = screenSaverActive

    if asleep || saver {
        return "0"   // OFF
    } else {
        return "1"   // ON
    }
}

var lastEffectiveState: String? = nil

func refreshStateAndNotify() {
    let current = effectiveState()

    if current != lastEffectiveState {
        lastEffectiveState = current
        sendWebhook(state: current == "1")
        debug("State changed → \(current) (asleep=\(isAsleep), screensaver=\(screenSaverActive))")
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

// MARK: - v3.4.7 Wake + Idle Timeout + Polling

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

// MARK: - Notifications (sleep / wake)

let ws = NSWorkspace.shared.notificationCenter

ws.addObserver(forName: NSWorkspace.willSleepNotification,
               object: nil, queue: .main) { _ in
    isAsleep = true
    wakePending = false
    wakeTimeoutTimer?.invalidate()
    stopIdleMonitoring()

    debug("macOS → willSleep")
    refreshStateAndNotify()
}

ws.addObserver(forName: NSWorkspace.didWakeNotification,
               object: nil, queue: .main) { _ in
    stopIdleMonitoring()
    isAsleep = false
    wakePending = true

    debug("macOS → didWake (start wake timeout)")
    scheduleWakeTimeout()
    forceRefreshState()
}

// MARK: - Notifications (screensaver)

let dist = DistributedNotificationCenter.default()

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstart"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = true
    debug("Screensaver → START")
    refreshStateAndNotify()
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = false
    debug("Screensaver → STOP")
    refreshStateAndNotify()
}

// MARK: - Polling léger

Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    refreshStateAndNotify()
}

// MARK: - Status Bar + détection display wake + HID

let spinnerFrames = ["|", "/", "-", "\\"]
var spinnerIndex = 0

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let frame = spinnerFrames[spinnerIndex % spinnerFrames.count]
    spinnerIndex += 1

    let locked = isScreenLocked()
    let asleep = isSystemAsleep()
    let saver = screenSaverActive
    let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID())

    if isAsleep && displayAsleep == 0 {
        debug("Display wake détecté avec isAsleep=true → resync ON + réarmement idleTimeout")
        isAsleep = false
        stopIdleMonitoring()
        forceRefreshState()
        if locked {
            scheduleIdleTimeout()
        }
    }

    if wakePending && !locked {
        debug("Unlock détecté → annulation wakePending")
        wakePending = false
        wakeTimeoutTimer?.invalidate()
        stopIdleMonitoring()
    }

    if locked && displayAsleep == 0 {
        if idleMonitoringActive {
            idleTimeoutTimer?.invalidate()
            scheduleIdleTimeout()
            debug("HID activity → idleTimeout réarmé")
        }
    }

    let state: String
    if asleep {
        state = "Asleep"
    } else if saver {
        state = "Screensaver"
    } else {
        state = "Awake"
    }

    let line = "[macstatusd] State: \(state) | Locked: \(locked) | Screensaver: \(saver) | Asleep: \(asleep)  \(frame)"

    FileHandle.standardOutput.write(Data("\r\(line)".utf8))
}

// MARK: - Start

print("macstatusd started.")
if debugLogging { print("Debug mode: ON") }

forceRefreshState()

listener.start(queue: .main)
RunLoop.main.run()
