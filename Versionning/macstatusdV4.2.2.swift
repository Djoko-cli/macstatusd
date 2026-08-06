import Foundation
import Network
import AppKit
import CoreGraphics

// MARK: - Debug

let debugLogging = CommandLine.arguments.contains("--debug")
func debug(_ msg: String) { if debugLogging { print("[DEBUG] \(msg)") } }

// MARK: - Config

struct Config: Codable {
    let enabled: Bool
    let webhook_base_url: String
    let accessory_id: String
    static var `default`: Config { Config(enabled: false, webhook_base_url: "", accessory_id: "mac") }
}

func loadConfig() -> Config {
    let url = URL(fileURLWithPath: "/opt/macstatusd/config.json")
    guard let data = try? Data(contentsOf: url),
          let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
        print("WARN: config.json missing or invalid → webhooks disabled")
        return .default
    }
    debug("Config loaded: \(cfg)")
    return cfg
}

let config = loadConfig()

// MARK: - Global state

var isAsleep = false
var screenSaverActive = false
var screenSaverEngineRunning = false

var shieldRaised = false
var authUIActive = false
var authUIVisible = false
var statusUIVisible = false
var unlockInProgress = false
var lockRequestedByScreensaver = false

// MARK: - System state

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let b = dict["CGSSessionScreenIsLocked"] as? Bool { return b }
    if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
    return false
}

func isDisplaySleeping() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

// MARK: - Webhook

func sendWebhook(state: Bool) {
    guard config.enabled, !config.webhook_base_url.isEmpty else { return }
    let value = state ? "true" : "false"
    let sep = config.webhook_base_url.contains("?") ? "&" : "?"
    let urlString = "\(config.webhook_base_url)\(sep)accessoryId=\(config.accessory_id)&state=\(value)"
    guard let url = URL(string: urlString) else { return }
    debug("Webhook → \(value) → \(url.absoluteString)")
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    URLSession.shared.dataTask(with: req).resume()
}

// MARK: - Machine d’état 4.3.2

enum MacState: String {
    case desktop
    case loginwindowOverlay
    case authVisible
    case unlockCycle
    case screensaverSoftLock
    case asleep
}

func deriveState(locked: Bool) -> MacState {

    if isAsleep { return .asleep }

    if !locked {
        return .desktop
    }

    if screenSaverEngineRunning && !authUIVisible {
        return .screensaverSoftLock
    }

    if screenSaverActive && !authUIVisible {
        return .loginwindowOverlay
    }

    if authUIVisible && !unlockInProgress {
        return .authVisible
    }

    if unlockInProgress {
        return .unlockCycle
    }

    return .screensaverSoftLock
}

// MARK: - Effective state

var lastEffectiveState: String? = nil

func effectiveState() -> String {
    let locked = isScreenLocked()
    let state = deriveState(locked: locked)

    let on: Bool = {
        switch state {
        case .desktop, .loginwindowOverlay, .authVisible:
            return true
        case .unlockCycle, .screensaverSoftLock, .asleep:
            return false
        }
    }()

    debug("deriveState → \(state.rawValue) | locked=\(locked) | saver=\(screenSaverActive) | engine=\(screenSaverEngineRunning) | authVisible=\(authUIVisible)")

    return on ? "1" : "0"
}

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

// MARK: - HTTP server

func sendHTTP(_ c: NWConnection, body: String) {
    let b = body.data(using: .utf8)!
    let resp = """
    HTTP/1.1 200 OK\r
    Content-Type: text/plain\r
    Content-Length: \(b.count)\r
    Connection: close\r
    \r
    \(body)
    """

    c.send(content: resp.data(using: .utf8),
           contentContext: .defaultMessage,
           isComplete: true,
           completion: .contentProcessed({ _ in
               c.cancel()
           }))
}

let listener = try! NWListener(using: .tcp, on: 9090)
listener.newConnectionHandler = { c in
    c.start(queue: .main)
    c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        guard let data = data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
        debug("HTTP Request: \(req.prefix(60))…")
        if req.contains("GET /state") { sendHTTP(c, body: effectiveState()); return }
        if req.contains("GET /sleep") { isAsleep = true; sendHTTP(c, body: "OK"); refreshStateAndNotify(); return }
        if req.contains("GET /wake") { isAsleep = false; sendHTTP(c, body: "OK"); forceRefreshState(); return }
        sendHTTP(c, body: "UNKNOWN")
    }
}

// MARK: - Sleep / wake

let ws = NSWorkspace.shared.notificationCenter

ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
    isAsleep = true
    debug("macOS → willSleep")
    refreshStateAndNotify()
}

ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    isAsleep = false
    debug("macOS → didWake")
    forceRefreshState()
}

// MARK: - Screensaver notifications

let dist = DistributedNotificationCenter.default()

dist.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { _ in
    screenSaverActive = true
    debug("Screensaver → START")
    refreshStateAndNotify()
}

dist.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { _ in
    screenSaverActive = false
    debug("Screensaver → STOP")
    refreshStateAndNotify()
}

// MARK: - ScreenSaverEngine detection

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
    if running != screenSaverEngineRunning {
        screenSaverEngineRunning = running
        debug("ScreenSaverEngine → \(running ? "RUNNING" : "STOPPED")")
        refreshStateAndNotify()
    }
}

// MARK: - Loginwindow watchers

let logProcess = Process()
logProcess.launchPath = "/usr/bin/log"
logProcess.arguments = ["stream", "--style", "compact", "--predicate", #"process == "loginwindow""#]

let logPipe = Pipe()
logProcess.standardOutput = logPipe
logProcess.launch()

let logHandle = logPipe.fileHandleForReading

DispatchQueue.global().async {
    while true {
        let data = logHandle.readData(ofLength: 4096)
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { continue }

        // OFF
        if chunk.contains("screenLockUIIsHidden")
            || chunk.contains("closeAuthAndReset")
            || chunk.contains("_setStatusViewHidden") {
            authUIVisible = false
            authUIActive = false
            shieldRaised = false
        }

        if chunk.contains("unlock failed") && chunk.contains("requested by screen saver") {
            unlockInProgress = false
        }

        if chunk.contains("resetAfterScreenLock") {
            unlockInProgress = false
        }

        // ON (préparation interne)
        if chunk.contains("set password field placeholder")
            || chunk.contains("updatePlaceholderString")
            || chunk.contains("updateFocus")
            || chunk.contains("CGSSetSecureEventInput") {
            authUIActive = true
        }

        // Auth UI visible (UI réelle)
        if chunk.contains("showScreenLock")
            || chunk.contains("created main window")
            || chunk.contains("windowDidBecomeKey")
            || chunk.contains("windowDidBecomeMain")
            || chunk.contains("LockUIController: showing UI") {
            authUIVisible = true
        }

        // Unlock réel
        if chunk.contains("startUnlock") && !chunk.contains("requested by screen saver") {
            unlockInProgress = true
        }
    }
}

// MARK: - Polling

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    _ = isScreenLocked()

    if isAsleep && !isDisplaySleeping() {
        isAsleep = false
        forceRefreshState()
    }

    refreshStateAndNotify()
}

// MARK: - Start

print("macstatusd 4.3.2 started.")
if debugLogging { print("Debug mode: ON") }

forceRefreshState()
listener.start(queue: .main)
RunLoop.main.run()
