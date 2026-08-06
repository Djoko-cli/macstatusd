import Foundation
import AppKit
import CoreGraphics

// MARK: - State flags

var screenSaverActive = false
var shieldRaised = false
var authUIActive = false
var statusUIVisible = false

// MARK: - Basic signals

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let b = dict["CGSSessionScreenIsLocked"] as? Bool { return b }
    if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
    return false
}

func isDisplaySleeping() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

// MARK: - Screensaver notifications

let dist = DistributedNotificationCenter.default()

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstart"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = true
    print("\n[SIGNAL] screensaver START")
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = false
    print("\n[SIGNAL] screensaver STOP")
}

// MARK: - Loginwindow log stream

let process = Process()
process.launchPath = "/usr/bin/log"
process.arguments = [
    "stream",
    "--style", "compact",
    "--predicate",
    #"process == "loginwindow" && subsystem == "com.apple.loginwindow""#
]

let pipe = Pipe()
process.standardOutput = pipe
process.launch()

let handle = pipe.fileHandleForReading

DispatchQueue.global().async {
    while let line = String(data: handle.availableData, encoding: .utf8) {
        if line.isEmpty { continue }

        // Shield
        if line.contains("ShieldWindow") && line.contains("raised") {
            shieldRaised = true
            print("[LOGINWINDOW] shield RAISED")
        }
        if line.contains("ShieldWindow") && line.contains("lowered") {
            shieldRaised = false
            print("[LOGINWINDOW] shield LOWERED")
        }

        // Auth UI
        if line.contains("AuthUI") && line.contains("appear") {
            authUIActive = true
            print("[LOGINWINDOW] authUI APPEAR")
        }
        if line.contains("AuthUI") && line.contains("disappear") {
            authUIActive = false
            print("[LOGINWINDOW] authUI DISAPPEAR")
        }

        // Status / UIController
        if line.contains("UIController") && line.contains("init") {
            statusUIVisible = true
            print("[LOGINWINDOW] status UI INIT")
        }
        if line.contains("UIController") && line.contains("dealloc") {
            statusUIVisible = false
            print("[LOGINWINDOW] status UI DEALLOC")
        }
    }
}

// MARK: - Polling

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let locked = isScreenLocked()
    let displaySleep = isDisplaySleeping()

    print("""
    locked=\(locked) \
    displaySleep=\(displaySleep) \
    screensaverActive=\(screenSaverActive) \
    shield=\(shieldRaised) \
    authUI=\(authUIActive) \
    statusUI=\(statusUIVisible)
    """)
}

// MARK: - Start

print("macstatusd DEBUG LOGINWINDOW started.")
RunLoop.main.run()
