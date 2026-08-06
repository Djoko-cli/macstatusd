import Foundation
import AppKit
import CoreGraphics

// MARK: - State flags (raw, no interpretation)

var screenSaverActive = false
var authUIActive = false
var statusUIVisible = false
var unlockInProgress = false

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

// MARK: - Screensaver notifications

let dist = DistributedNotificationCenter.default()

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstart"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = true
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = false
}

// MARK: - Loginwindow watcher (raw events)

let process = Process()
process.launchPath = "/usr/bin/log"
process.arguments = [
    "stream",
    "--style", "compact",
    "--predicate", #"process == "loginwindow""#
]

let pipe = Pipe()
process.standardOutput = pipe
process.launch()

let handle = pipe.fileHandleForReading

DispatchQueue.global().async {
    while true {
        let data = handle.readData(ofLength: 4096)
        if data.isEmpty { continue }
        guard let chunk = String(data: data, encoding: .utf8) else { continue }

        // --- AUTH UI ---

        if chunk.contains("set password field placeholder")
            || chunk.contains("updatePlaceholderString")
            || chunk.contains("updateFocus")
            || chunk.contains("CGSSetSecureEventInput") {
            authUIActive = true
        }

        if chunk.contains("screenLockUIIsHidden")
            || chunk.contains("closeAuthAndReset")
            || chunk.contains("_setPasswordTextFieldHidden")
            || chunk.contains("setPasswordFieldPlaceholderString: \"\"") {
            authUIActive = false
        }

        // --- STATUS UI ---

        if chunk.contains("WiFi viewDidLoad")
            || chunk.contains("Battery _updateViews")
            || chunk.contains("Status viewDidLoad") {
            statusUIVisible = true
        }

        if chunk.contains("WiFi pause")
            || chunk.contains("Battery pause")
            || chunk.contains("_setStatusViewHidden") {
            statusUIVisible = false
        }

        // --- UNLOCK PIPELINE ---

        if chunk.contains("startUnlock")
            || chunk.contains("unlock failed")
            || chunk.contains("resetAfterScreenLock") {
            unlockInProgress = true
        }

        if (chunk.contains("handleUnlockResult") && chunk.contains("Exit"))
            || chunk.contains("cancelPressed")
            || chunk.contains("resetAfterScreenLock") {
            unlockInProgress = false
        }
    }
}

// MARK: - High‑frequency polling (100 ms)

let startTime = Date()

func msSinceStart() -> Int {
    return Int(Date().timeIntervalSince(startTime) * 1000)
}

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let locked = isScreenLocked()
    let displaySleep = isDisplaySleeping()

    print(String(format:
        "[%06d ms] locked=%@ displaySleep=%@ screensaver=%@ authUI=%@ statusUI=%@ unlock=%@",
        msSinceStart(),
        locked ? "1" : "0",
        displaySleep ? "1" : "0",
        screenSaverActive ? "1" : "0",
        authUIActive ? "1" : "0",
        statusUIVisible ? "1" : "0",
        unlockInProgress ? "1" : "0"
    ))
}

// MARK: - Start

print("macstatusd‑debugV5 started. High‑frequency logging active.")
RunLoop.main.run()
