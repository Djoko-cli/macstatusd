import Foundation
import Network
import AppKit
import IOKit.pwr_mgt

// MARK: - Debug mode

let debugLogging: Bool = CommandLine.arguments.contains("--debug")

func debug(_ msg: String) {
    if debugLogging { print("[DEBUG] \(msg)") }
}

// MARK: - Global state

var isLocked = false
var isAsleep = false

// MARK: - Lock state (CGSession)

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }

    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber { return lockedNum.boolValue }

    return false
}

// MARK: - Sleep state (IOKit)

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

// MARK: - Effective State + change detection

func effectiveState() -> String {
    let locked = isScreenLocked()
    let asleep = isSystemAsleep()
    return (locked || asleep) ? "0" : "1"
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

        debug("HTTP Request: \(request.prefix(40))…")

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

// MARK: - Notifications

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

// MARK: - Lock polling léger

Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    refreshStateAndNotify()
}

// MARK: - Start

print("MacAgent started.")
if debugLogging { print("Debug mode: ON") }

refreshStateAndNotify()

listener.start(queue: .main)

// MARK: - Status Bar Dynamique

let spinnerFrames = ["|", "/", "-", "\\"]
var spinnerIndex = 0

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let frame = spinnerFrames[spinnerIndex % spinnerFrames.count]
    spinnerIndex += 1
    
    let locked = isScreenLocked()
    let asleep = isSystemAsleep()
    let state = effectiveState() == "1" ? "Awake" : (asleep ? "Asleep" : "Locked")
    
    let line = "State: \(state) | Locked: \(locked) | Asleep: \(asleep) \(frame)"
    
    
    // Efface la ligne précédente et réécrit
    FileHandle.standardOutput.write(Data("\r\(line)".utf8))
}


RunLoop.main.run()
