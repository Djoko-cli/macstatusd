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

    static var `default`: Config {
        Config(enabled: false, webhook_base_url: "", accessory_id: "mac")
    }
}

func loadConfig() -> Config {
    let path = "/opt/macstatusd/config.json"
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        print("WARN: config.json missing or invalid → webhooks disabled (\(error))")
        return .default
    }
}

let config = loadConfig()

// MARK: - Global state

var systemSleeping = false
var screenSaverActive = false
var screensaverStartDate: Date? = nil
var loginwindowVisible = false

var lastState: Bool? = nil

// MARK: - Signals

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let b = dict["CGSSessionScreenIsLocked"] as? Bool { return b }
    if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
    return false
}

func isDisplaySleeping() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

func computeDesktopVisible() -> Bool {
    let locked = isScreenLocked()
    return !locked && !screenSaverActive && !systemSleeping && !isDisplaySleeping()
}

func updateLoginwindowVisible() {
    // Si la session n’est pas verrouillée, loginwindow ne compte jamais
    if !isScreenLocked() {
        loginwindowVisible = false
        return
    }
    
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        loginwindowVisible = false
        return
    }
    
    var visible = false
    
    for win in list {
        guard let owner = win[kCGWindowOwnerName as String] as? String else { continue }
        if owner != "loginwindow" { continue }
        
        let alpha = win[kCGWindowAlpha as String] as? Double ?? 1.0
        if alpha > 0.01 {
            visible = true
            break
        }
    }
    
    loginwindowVisible = visible
}

// MARK: - Engine 4.1.1

func macstatusOn() -> Bool {
    if systemSleeping || isDisplaySleeping() {
        return false
    }
    
    if screenSaverActive {
        return loginwindowVisible
    }
    
    let desktopVisible = computeDesktopVisible()
    if desktopVisible { return true }
    if loginwindowVisible { return true }
    
    return false
}


// MARK: - Webhook

func sendWebhook(state: Bool) {
    guard config.enabled else { return }
    guard !config.webhook_base_url.isEmpty else { return }

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
        URLSession.shared.dataTask(with: req).resume()
    }
}

func refreshState(reason: String) {
    let current = macstatusOn()
    if current != lastState {
        lastState = current
        debug("State changed (\(reason)) → \(current ? "ON" : "OFF")")
        sendWebhook(state: current)
    }
}

// MARK: - System commands

func putMacToSleep() {
    debug("putMacToSleep()")
    let task = Process()
    task.launchPath = "/usr/bin/pmset"
    task.arguments = ["sleepnow"]
    task.launch()
}

func wakeMac() {
    debug("wakeMac()")
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = [
        "-c",
        "/usr/bin/pmset sleepnow; /bin/sleep 0.1; /usr/bin/caffeinate -u -t 1"
    ]
    task.launch()
}

// MARK: - HTTP server

func sendHTTP(_ c: NWConnection, body: String) {
    let bodyData = body.data(using: .utf8)!
    let response = """
    HTTP/1.1 200 OK\r
    Content-Type: text/plain\r
    Content-Length: \(bodyData.count)\r
    Connection: close\r
    \r
    \(body)
    """

    c.send(
        content: response.data(using: .utf8),
        contentContext: .defaultMessage,
        isComplete: true,
        completion: .contentProcessed { _ in
            c.cancel()
        }
    )
}

let listener = try! NWListener(using: .tcp, on: 9090)

listener.newConnectionHandler = { conn in
    conn.start(queue: .main)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        guard let data = data,
              let req = String(data: data, encoding: .utf8) else {
            conn.cancel()
            return
        }

        if req.contains("GET /state") {
            let body = macstatusOn() ? "1" : "0"
            sendHTTP(conn, body: body)
            return
        }

        if req.contains("GET /sleep") {
            putMacToSleep()
            sendHTTP(conn, body: "OK")
            return
        }

        if req.contains("GET /wake") {
            wakeMac()
            sendHTTP(conn, body: "OK")
            return
        }

        sendHTTP(conn, body: "UNKNOWN")
    }
}

// MARK: - Notifications

let ws = NSWorkspace.shared.notificationCenter

ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
    systemSleeping = true
    debug("macOS → willSleep")
    refreshState(reason: "willSleep")
}

ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    systemSleeping = false
    debug("macOS → didWake")
    refreshState(reason: "didWake")
}

let dist = DistributedNotificationCenter.default()

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstart"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = true
    screensaverStartDate = Date()
    debug("Screensaver → START")
    refreshState(reason: "screensaver start")
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = false
    screensaverStartDate = nil
    debug("Screensaver → STOP")
    refreshState(reason: "screensaver stop")
}

// MARK: - Polling

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    updateLoginwindowVisible()
    refreshState(reason: "poll")
}

// MARK: - Start

print("macstatusd 4.1.1 started.")
if debugLogging { print("Debug mode ON") }

refreshState(reason: "startup")

listener.start(queue: .main)
RunLoop.main.run()
