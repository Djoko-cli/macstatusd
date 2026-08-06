import Foundation
import AppKit
import CoreGraphics
import IOKit

// MARK: - HID Idle Time

func hidIdleTimeSeconds() -> Double {
    var iterator: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator)
    let entry = IOIteratorNext(iterator)
    IOObjectRelease(iterator)
    guard entry != 0 else { return -1 }
    let key = "HIDIdleTime" as CFString
    let cfValue = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0)
    IOObjectRelease(entry)
    guard let number = cfValue?.takeRetainedValue() as? NSNumber else { return -1 }
    return Double(number.uint64Value) / 1_000_000_000.0
}

// MARK: - Lock State

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber { return lockedNum.boolValue }
    return false
}

// MARK: - Screensaver State (REAL, via AppKit User Agent)

var screensaverActive = false

let dist = DistributedNotificationCenter.default()

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstart"),
    object: nil,
    queue: .main
) { _ in
    screensaverActive = true
    print("🟥 Screensaver START")
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    screensaverActive = false
    print("🟩 Screensaver STOP")
}

// MARK: - Timestamp

let formatter = ISO8601DateFormatter()
formatter.timeZone = TimeZone.current

// MARK: - AppKit bootstrap

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no dock icon, no window

// MARK: - Timer for logging

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let ts = formatter.string(from: Date())
    let locked = isScreenLocked()
    let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    let hid = hidIdleTimeSeconds()

    print("t=\(ts) locked=\(locked) saver=\(screensaverActive) displayAsleep=\(displayAsleep) hidIdle=\(String(format: "%.2f", hid))")
    fflush(stdout)
}

// MARK: - RunLoop

app.run()
