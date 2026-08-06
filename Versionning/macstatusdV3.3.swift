import Foundation
import Network
import AppKit

// MARK: - Debug mode

let debugLogging: Bool = CommandLine.arguments.contains("--debug")

func debug(_ msg: String) {
    if debugLogging { print("[DEBUG] \(msg)") }
}

// MARK: - Global state

var isAsleep = false
var screenSaverActive = false

// MARK: - Lock state (optionnel, pour affichage)

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

// MARK: - Webhook push (Homebridge)

func sendWebhook(state: Bool) {
    let value = state ? "true" : "false"
    guard let url = URL(string: "http://homebridge.local:51828/?accessoryId=mac&state=\(value)") else { return }

    debug("Webhook → \(value) → \(url.absoluteString)")

    DispatchQueue.global().async {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error { debug("Webhook ERROR: \(error)") }
            else { debug("Webhook OK: \(String(describing: response))") }
        }
        task.resume()
    }
}

// MARK: - Effective State (HomeKit ON/OFF)

func effectiveState() -> String {
    let asleep = isSystemAsleep()
    let saver = screenSaverActive

    // OFF si vraie veille OU screensaver (pseudo-veille)
    if asleep || saver {
        return "0"   // OFF
    } else {
        return "1"   // ON (awake ou locked)
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

    refreshStateAndNotify()
}

// MARK: - HTTP Server

let listener = try NWListener(using: .tcp, on: 9090)

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
    refreshStateAndNotify()
}

// MARK: - Notifications (screensaver start/stop)

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

// MARK: - Polling léger (sécurité)

Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    refreshStateAndNotify()
}

// MARK: - Status Bar Dynamique

let spinnerFrames = ["|", "/", "-", "\\"]
var spinnerIndex = 0

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let frame = spinnerFrames[spinnerIndex % spinnerFrames.count]
    spinnerIndex += 1

    let locked = isScreenLocked()
    let asleep = isSystemAsleep()
    let saver = screenSaverActive

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

refreshStateAndNotify()

listener.start(queue: .main)
RunLoop.main.run()
