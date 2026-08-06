import Foundation
import CoreGraphics
import IOKit

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

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber { return lockedNum.boolValue }
    return false
}

func isScreenSaverActive() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let saver = dict["CGSSessionScreenSaverActive"] as? Bool { return saver }
    if let saverNum = dict["CGSSessionScreenSaverActive"] as? NSNumber { return saverNum.boolValue }
    return false
}

let formatter = ISO8601DateFormatter()
formatter.timeZone = TimeZone.current   // ← HORODATAGE LOCAL

while true {
    let ts = formatter.string(from: Date())
    let locked = isScreenLocked()
    let saver = isScreenSaverActive()
    let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    let hid = hidIdleTimeSeconds()

    print("t=\(ts) locked=\(locked) saver=\(saver) displayAsleep=\(displayAsleep) hidIdle=\(String(format: "%.2f", hid))")

    fflush(stdout)
    usleep(100_000) // 100 ms
}
