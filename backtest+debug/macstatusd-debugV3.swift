import Foundation
import AppKit
import CoreGraphics

// MARK: - State flags

var screenSaverActive = false
var shieldRaised = false
var authUIActive = false
var statusUIVisible = false
var unlockInProgress = false
var lockRequestedByScreensaver = false

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
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    screenSaverActive = false
}

// MARK: - Loginwindow watchers (minimal, based on real logs)

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
        guard let line = String(data: data, encoding: .utf8) else { continue }

        // Shield raised
        if line.contains("shieldWindowRaised")
            || line.contains("Raising shield window")
            || line.contains("creating shield window") {
            shieldRaised = true
        }

        // Auth UI (invisible but real)
        if line.contains("set password field placeholder")
            || line.contains("updatePlaceholderString")
            || line.contains("updateFocus")
            || line.contains("CGSSetSecureEventInput")
            || line.contains("screenLockUIIsHidden") {
            authUIActive = true
        }

        // Status UI
        if line.contains("WiFi viewDidLoad")
            || line.contains("Battery _updateViews")
            || line.contains("Status viewDidLoad") {
            statusUIVisible = true
        }

        // Unlock pipeline
        if line.contains("startUnlock")
            || line.contains("unlock failed")
            || line.contains("resetAfterScreenLock") {
            unlockInProgress = true
        }

        // Lock requested by screensaver
        if line.contains("kLWLockFromScreenSaverOtherLaunch")
            || line.contains("startScreenLock") {
            lockRequestedByScreensaver = true
        }
    }
}

// MARK: - Polling output

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let locked = isScreenLocked()
    let displaySleep = isDisplaySleeping()

    print("""
    locked=\(locked) \
    displaySleep=\(displaySleep) \
    screensaverActive=\(screenSaverActive) \
    shield=\(shieldRaised) \
    authUI=\(authUIActive) \
    statusUI=\(statusUIVisible) \
    unlockInProgress=\(unlockInProgress) \
    lockRequestedByScreensaver=\(lockRequestedByScreensaver)
    """)
}

// MARK: - Start

print("macstatusd DEBUG MINIMAL started.")
RunLoop.main.run()
