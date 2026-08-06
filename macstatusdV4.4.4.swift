import Foundation
import Network
import AppKit
import CoreGraphics

// MARK: - Debug

let debugLogging: Bool = CommandLine.arguments.contains("--debug")
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
        print("WARN: config.json missing or invalid → webhooks disabled")
        return .default
    }
}

let config = loadConfig()

// MARK: - Global state

var isAsleep = false
var screenSaverActive = false

// Oracle visuel (UI loginwindow visible)
var authUIActive = false        // champ mot de passe
var statusUIVisible = false     // overlay sans champ

// Oracle logique (pipeline d’unlock)
var unlockInProgress = false

// Anti‑glitch OFF→ON lors du verrouillage manuel
var lockTransition = false
var lockTransitionTimer: Timer?

// MARK: - Session

func sessionDict() -> [String: Any]? { CGSessionCopyCurrentDictionary() as? [String: Any] }

func isScreenLocked() -> Bool {
    guard let dict = sessionDict() else { return false }
    if let b = dict["CGSSessionScreenIsLocked"] as? Bool { return b }
    if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
    return false
}

func isDisplaySleeping() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
func isSystemAsleep() -> Bool { isAsleep }

// MARK: - Screensaver notifications

let dist = DistributedNotificationCenter.default()

dist.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"),
                 object: nil, queue: .main) { _ in
    screenSaverActive = true
    debug("Screensaver → START")
}

dist.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"),
                 object: nil, queue: .main) { _ in
    screenSaverActive = false
    debug("Screensaver → STOP")
}

// MARK: - Loginwindow watcher (V4-style ON/OFF)

let lwProcess = Process()
lwProcess.launchPath = "/usr/bin/log"
lwProcess.arguments = ["stream", "--style", "compact",
                       "--predicate", #"process == "loginwindow""#]

let lwPipe = Pipe()
lwProcess.standardOutput = lwPipe
lwProcess.launch()

DispatchQueue.global(qos: .utility).async {
    let handle = lwPipe.fileHandleForReading
    while true {
        let data = handle.readData(ofLength: 4096)
        if data.isEmpty { continue }
        guard let chunk = String(data: data, encoding: .utf8) else { continue }

        // --- OFF PRIORITAIRE ---

        // Auth UI OFF (champ disparu)
        if chunk.contains("screenLockUIIsHidden")
            || chunk.contains("closeAuthAndReset")
            || chunk.contains("_setPasswordTextFieldHidden")
            || chunk.contains("setPasswordFieldPlaceholderString: \"\"") {
            authUIActive = false
        }

        // Status UI OFF (overlay sans champ disparu)
        if chunk.contains("WiFi pause")
            || chunk.contains("Battery pause")
            || chunk.contains("_setStatusViewHidden") {
            statusUIVisible = false
        }

        // Unlock OFF
        if (chunk.contains("handleUnlockResult") && chunk.contains("Exit"))
            || chunk.contains("cancelPressed")
            || chunk.contains("resetAfterScreenLock") {
            unlockInProgress = false
            debug("loginwindow → unlockInProgress = false")
        }

        // --- ON ---

        // Auth UI ON (champ visible)
        if chunk.contains("set password field placeholder")
            || chunk.contains("updatePlaceholderString")
            || chunk.contains("updateFocus")
            || chunk.contains("CGSSetSecureEventInput") {
            authUIActive = true
        }

        // Status UI ON (overlay sans champ)
        if chunk.contains("WiFi viewDidLoad")
            || chunk.contains("Battery _updateViews")
            || chunk.contains("Status viewDidLoad") {
            statusUIVisible = true
        }

        // Unlock ON
        if chunk.contains("startUnlock")
            || chunk.contains("unlock failed")
            || chunk.contains("resetAfterScreenLock") {
            unlockInProgress = true
            debug("loginwindow → unlockInProgress = true")
        }
    }
}

// MARK: - Webhook

func sendWebhook(state: Bool) {
    guard config.enabled, !config.webhook_base_url.isEmpty else { return }

    let value = state ? "true" : "false"
    let sep = config.webhook_base_url.contains("?") ? "&" : "?"
    let urlString = "\(config.webhook_base_url)\(sep)accessoryId=\(config.accessory_id)&state=\(value)"

    guard let url = URL(string: urlString) else { return }

    debug("Webhook → \(value)")

    DispatchQueue.global().async {
        URLSession.shared.dataTask(with: url).resume()
    }
}

// MARK: - Effective State (4.4.3‑ter)

func effectiveState() -> String {
    let asleep = isSystemAsleep()
    let locked = isScreenLocked()
    let displaySleep = isDisplaySleeping()

    // Oracle visuel : UI visible = ON
    let overlayVisible = authUIActive || statusUIVisible

    // OFF dur
    if asleep || displaySleep { return "0" }

    // ON si bureau
    if !locked { return "1" }

    // ON si UI visible (overlay avec ou sans champ)
    if overlayVisible { return "1" }

    // ON si pipeline d’unlock actif (mais seulement si UI visible)
    if unlockInProgress && overlayVisible { return "1" }

    // ON si transition de verrouillage (anti‑glitch)
    if lockTransition { return "1" }

    // OFF si verrouillé sans UI
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

// MARK: - HTTP

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
    let responseData = response.data(using: .utf8)!

    c.send(
        content: responseData,
        contentContext: .defaultMessage,
        isComplete: true,
        completion: .contentProcessed({ _ in
            c.cancel()
        })
    )
}

let listener = try! NWListener(using: .tcp, on: 9090)

listener.newConnectionHandler = { connection in
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        guard let data = data,
              let req = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        if req.contains("GET /state") { sendHTTP(connection, body: effectiveState()); return }
        if req.contains("GET /sleep") { isAsleep = true; refreshStateAndNotify(); sendHTTP(connection, body: "OK"); return }
        if req.contains("GET /wake") { isAsleep = false; refreshStateAndNotify(); sendHTTP(connection, body: "OK"); return }

        sendHTTP(connection, body: "UNKNOWN")
    }
}

// MARK: - Status loop (0.1s)

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let locked = isScreenLocked()
    let overlayVisible = authUIActive || statusUIVisible

    // Reset unlockInProgress quand bureau visible
    if !locked && unlockInProgress {
        unlockInProgress = false
        debug("unlockInProgress → false (desktop)")
    }

    // Détection transition de verrouillage (anti‑glitch)
    if locked && !overlayVisible && !unlockInProgress && !screenSaverActive && lockTransition == false {
        lockTransition = true
        debug("lockTransition = true")
        lockTransitionTimer?.invalidate()
        lockTransitionTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            lockTransition = false
            debug("lockTransition = false")
        }
    }

    // ESC / retour screensaver seul
    if locked && screenSaverActive && !overlayVisible && !unlockInProgress {
        lockTransition = false
    }

    refreshStateAndNotify()
}

// MARK: - Start

print("macstatusd 4.4.3-ter started.")
if debugLogging { print("Debug mode: ON") }

forceRefreshState()
listener.start(queue: .main)
RunLoop.main.run()
