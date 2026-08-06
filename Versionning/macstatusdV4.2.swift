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

// MARK: - Global state (sleep + loginwindow signals)

var isAsleep = false

var screenSaverActive = false
var shieldRaised = false
var authUIActive = false
var statusUIVisible = false
var unlockInProgress = false
var lockRequestedByScreensaver = false

// MARK: - Lock state

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }

    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber { return lockedNum.boolValue }

    return false
}

func isDisplaySleeping() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

// MARK: - Webhook push (compatible with v3.4.7)

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

// MARK: - Machine d’état 4.3

enum MacState: String {
    case desktop
    case screensaverSoftLock
    case authInvisible
    case unlockCycle
    case fullLock
    case asleep
}

func deriveState(locked: Bool) -> MacState {
    if isAsleep {
        return .asleep
    }

    if !locked {
        return .desktop
    }

    // Locked = true à partir d’ici

    if screenSaverActive && !authUIActive {
        return .screensaverSoftLock
    }

    if screenSaverActive && authUIActive && !unlockInProgress {
        return .authInvisible
    }

    if unlockInProgress {
        return .unlockCycle
    }

    if !screenSaverActive && authUIActive {
        return .fullLock
    }

    return .screensaverSoftLock
}

// MARK: - Effective State (ON/OFF) exposé à Homebridge

func effectiveState() -> String {
    let locked = isScreenLocked()
    let state = deriveState(locked: locked)

    let on = (state == .desktop)

    debug("deriveState → \(state.rawValue) (locked=\(locked), saver=\(screenSaverActive), asleep=\(isAsleep))")

    return on ? "1" : "0"
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

// MARK: - System Commands (compat v3.4.7)

func putMacToSleep() {
    isAsleep = true
    debug("putMacToSleep()")

    let task = Process()
    task.launchPath = "/usr/bin/pmset"
    task.arguments = ["sleepnow"]
    task.launch()

    refreshStateAndNotify()
}

func wakeMac() {
    isAsleep = false
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

// MARK: - HTTP Server (same endpoints as 3.4.7)

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

// MARK: - Notifications (sleep / wake)

let ws = NSWorkspace.shared.notificationCenter

ws.addObserver(forName: NSWorkspace.willSleepNotification,
               object: nil, queue: .main) { _ in
    isAsleep = true
    debug("macOS → willSleep")
    refreshStateAndNotify()
}

ws.addObserver(forName: NSWorkspace.didWakeNotification,
               object: nil, queue: .main) { _ in
    isAsleep = false
    debug("macOS → didWake")
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

// MARK: - Loginwindow watchers (ON/OFF, OFF prioritaire)

let logProcess = Process()
logProcess.launchPath = "/usr/bin/log"
logProcess.arguments = [
    "stream",
    "--style", "compact",
    "--predicate", #"process == "loginwindow""#
]

let logPipe = Pipe()
logProcess.standardOutput = logPipe
logProcess.launch()

let logHandle = logPipe.fileHandleForReading

DispatchQueue.global().async {
    while true {
        let data = logHandle.readData(ofLength: 4096)
        if data.isEmpty { continue }
        guard let chunk = String(data: data, encoding: .utf8) else { continue }

        // OFF prioritaire

        if chunk.contains("lowerLockUI")
            || chunk.contains("_setStatusViewHidden")
            || chunk.contains("closeAuthAndReset")
            || chunk.contains("screenLockUIIsHidden") {
            shieldRaised = false
        }

        if chunk.contains("screenLockUIIsHidden")
            || chunk.contains("closeAuthAndReset")
            || chunk.contains("_setPasswordTextFieldHidden")
            || chunk.contains("setPasswordFieldPlaceholderString: \"\"") {
            authUIActive = false
        }

        if chunk.contains("WiFi pause")
            || chunk.contains("Battery pause")
            || chunk.contains("_setStatusViewHidden") {
            statusUIVisible = false
        }

        if (chunk.contains("handleUnlockResult") && chunk.contains("Exit"))
            || chunk.contains("cancelPressed")
            || chunk.contains("resetAfterScreenLock") {
            unlockInProgress = false
        }

        if chunk.contains("screenSaverStopNow")
            || chunk.contains("startUnlock") {
            lockRequestedByScreensaver = false
        }

        // ON

        if chunk.contains("shieldWindowRaised")
            || chunk.contains("Raising shield window")
            || chunk.contains("creating shield window") {
            shieldRaised = true
        }

        if chunk.contains("set password field placeholder")
            || chunk.contains("updatePlaceholderString")
            || chunk.contains("updateFocus")
            || chunk.contains("CGSSetSecureEventInput") {
            authUIActive = true
        }

        if chunk.contains("WiFi viewDidLoad")
            || chunk.contains("Battery _updateViews")
            || chunk.contains("Status viewDidLoad") {
            statusUIVisible = true
        }

        if chunk.contains("startUnlock")
            || chunk.contains("unlock failed")
            || chunk.contains("resetAfterScreenLock") {
            unlockInProgress = true
        }

        if chunk.contains("kLWLockFromScreenSaverOtherLaunch")
            || chunk.contains("startScreenLock") {
            lockRequestedByScreensaver = true
        }
    }
}

// MARK: - Polling léger + status line

let spinnerFrames = ["|", "/", "-", "\\"]
var spinnerIndex = 0

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let locked = isScreenLocked()
    let displayAsleep = isDisplaySleeping()
    let state = deriveState(locked: locked)

    if isAsleep && !displayAsleep {
        debug("Display wake détecté avec isAsleep=true → resync ON")
        isAsleep = false
        forceRefreshState()
    }

    refreshStateAndNotify()

    let frame = spinnerFrames[spinnerIndex % spinnerFrames.count]
    spinnerIndex += 1

    let line = "[macstatusd 4.3] State: \(state.rawValue) | Locked: \(locked) | Screensaver: \(screenSaverActive) | Asleep: \(isAsleep)  \(frame)"
    FileHandle.standardOutput.write(Data("\r\(line)".utf8))
}

// MARK: - Start

print("macstatusd 4.3 started.")
if debugLogging { print("Debug mode: ON") }

forceRefreshState()

listener.start(queue: .main)
RunLoop.main.run()
