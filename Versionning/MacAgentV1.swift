import Foundation
import Network
import AppKit

var isLocked = false
var isAsleep = false

// MARK: - Send HTTP Response (corrected)

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
            let state = (isLocked || isAsleep) ? "0" : "1"
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

ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
               object: nil, queue: .main) { _ in
    isLocked = false
}

ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
               object: nil, queue: .main) { _ in
    isLocked = true
}

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
