import Foundation
import IOKit

func hidIdleTimeSeconds() -> Double {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceMatching("IOHIDSystem"),
                                              &iterator)
    if result != KERN_SUCCESS { return -1 }

    let entry = IOIteratorNext(iterator)
    IOObjectRelease(iterator)
    if entry == 0 { return -1 }

    let key = "HIDIdleTime" as CFString
    let cfValue = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0)
    IOObjectRelease(entry)

    guard let number = cfValue?.takeRetainedValue() as? NSNumber else {
        return -1
    }

    let nanoseconds = number.uint64Value
    return Double(nanoseconds) / 1_000_000_000.0
}

print("HIDIdleTime backtest (seconds). CTRL+C to stop.\n")

while true {
    let idle = hidIdleTimeSeconds()
    print(String(format: "%.3f", idle))
    usleep(200_000)
}
