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

// MARK: - Loginwindow raw log stream + tee

let logPath = "/tmp/loginwindow_raw.log"
if !FileManager.default.fileExists(atPath: logPath) {
    FileManager.default.createFile(atPath: logPath, contents: nil)
}
let logFile = FileHandle(forWritingAtPath: logPath)!

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

        if let line = String(data: data, encoding: .utf8) {
            let stamped = "[\(Date())] \(line)"

            // Live output
            print("[LOGINWINDOW RAW] \(line)", terminator: "")

            // Tee to file
            if let fileData = stamped.data(using: .utf8) {
                logFile.write(fileData)
            }
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
print("Raw loginwindow logs → \(logPath)")
RunLoop.main.run()
