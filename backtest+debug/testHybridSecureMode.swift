import Foundation
import CoreGraphics

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber { return lockedNum.boolValue }
    return false
}

func isLoginWindowActive() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let onConsole = dict[kCGSessionOnConsoleKey as String] as? Bool {
        return onConsole == false
    }
    return false
}

func isScreenSaverActive() -> Bool {
    // On teste la présence du process ScreenSaverEngine
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["aux"]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    return output.contains("ScreenSaverEngine")
}

print("HybridSecureMode Backtest started.")
print("Press CTRL+C to exit.\n")

while true {
    let locked = isScreenLocked()
    let loginWindow = isLoginWindowActive()
    let saver = isScreenSaverActive()

    let hybrid = (!saver ? false : (locked && loginWindow))

    print("""
    locked=\(locked) \
    loginWindow=\(loginWindow) \
    saver=\(saver) \
    hybrid=\(hybrid)
    """)

    usleep(200_000) // 200 ms
}
