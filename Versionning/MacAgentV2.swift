import Foundation
import Network
import AppKit
import IOKit.pwr_mgt

// MARK: - Global state

// On garde ces flags pour cohérence, mais l'état réel vient des APIs système.
var isLocked = false
var isAsleep = false

// MARK: - Lock state (CGSession)

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
        return locked
    }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber {
        return lockedNum.boolValue
    }
    return false
}

// MARK: - Sleep state (IOKit)

func isSystemAsleep() -> Bool {
    // On ne peut pas interroger directement "en temps réel" l'état de veille,
    // mais on maintient isAsleep via les notifications NSWorkspace.
    // Cette fonction existe pour centraliser la logique si on veut évoluer plus tard.
    return isAsleep
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

    connection.send(content: responseData,
                    completion: .contentProcessed({ _ in
        connection.cancel()
    }))
}

// MARK: - System Commands

func putMacToSleep() {
    isAsleep = true
    let task = Process()
    task.launchPath = "/usr/bin/pmset"
    task.arguments = ["sleepnow"]
    task.launch()
}

func wakeMac() {
    isAsleep = false
    let task = Process()
    task.launchPath = "/usr/bin/caffeinate"
    task.arguments = ["-u", "-t", "1"]
    task.launch()
}

// MARK: - Effective State

func effectiveState() -> String {
    // 1 = Mac réveillé ET déverrouillé
    // 0 = Mac verrouillé OU en veille
    let locked = isScreenLocked()
    let asleep = isSystemAsleep()
    return (locked || asleep) ? "0" : "1"
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

        if request.contains("GET /state") {
            let state = effectiveState()
            sendHTTP(connection, body: state)
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

// On ne se base plus sur sessionDidResignActive pour le lock,
// mais on garde les notifications de veille/réveil pour isAsleep.

ws.addObserver(forName: NSWorkspace.willSleepNotification,
               object: nil, queue: .main) { _ in
    isAsleep = true
}

ws.addObserver(forName: NSWorkspace.didWakeNotification,
               object: nil, queue: .main) { _ in
    isAsleep = false
}

// MARK: - Start

listener.start(queue: .main)
RunLoop.main.run()
