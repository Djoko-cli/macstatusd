import Foundation
import AppKit
import CoreGraphics

// MARK: - State flags (instantaneous)

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

// MARK: - Loginwindow watchers (ON/OFF, OFF prioritaire)

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

        // --- OFF PRIORITAIRE ---

        // Shield OFF
        if chunk.contains("lowerLockUI")
            || chunk.contains("_setStatusViewHidden")
            || chunk.contains("closeAuthAndReset")
            || chunk.contains("screenLockUIIsHidden") {
            shieldRaised = false
        }

        // Auth UI OFF
        if chunk.contains("screenLockUIIsHidden")
            || chunk.contains("closeAuthAndReset")
            || chunk.contains("_setPasswordTextFieldHidden")
            || chunk.contains("setPasswordFieldPlaceholderString: \"\"") {
            authUIActive = false
        }

        // Status UI OFF
        if chunk.contains("WiFi pause")
            || chunk.contains("Battery pause")
            || chunk.contains("_setStatusViewHidden") {
            statusUIVisible = false
        }

        // Unlock OFF
        if chunk.contains("handleUnlockResult") && chunk.contains("Exit")
            || chunk.contains("cancelPressed")
            || chunk.contains("resetAfterScreenLock") {
            unlockInProgress = false
        }

        // Lock-from-screensaver OFF
        if chunk.contains("screenSaverStopNow")
            || chunk.contains("startUnlock") {
            lockRequestedByScreensaver = false
        }

        // --- ON (appliqué seulement si OFF n’a pas déjà gagné) ---

        // Shield ON
        if chunk.contains("shieldWindowRaised")
            || chunk.contains("Raising shield window")
            || chunk.contains("creating shield window") {
            shieldRaised = true
        }

        // Auth UI ON
        if chunk.contains("set password field placeholder")
            || chunk.contains("updatePlaceholderString")
            || chunk.contains("updateFocus")
            || chunk.contains("CGSSetSecureEventInput") {
            authUIActive = true
        }

        // Status UI ON
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
        }

        // Lock-from-screensaver ON
        if chunk.contains("kLWLockFromScreenSaverOtherLaunch")
            || chunk.contains("startScreenLock") {
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

print("macstatusd DEBUG MINIMAL CHIRURGICAL started.")
RunLoop.main.run()
