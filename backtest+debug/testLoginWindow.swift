import Foundation
import CoreGraphics

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber { return lockedNum.boolValue }
    return false
}

func isScreenSaverActive() -> Bool {
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

func isLoginWindowVisible() -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }

    for win in infoList {
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        let layer = win[kCGWindowLayer as String] as? Int ?? 0

        // loginwindow visible en premier plan
        if (owner == "loginwindow" || owner == "Login Window") && layer == 0 {
            return true
        }
    }

    return false
}

print("LoginWindow / ScreenSaver Backtest started.")
print("Press CTRL+C to exit.\n")

while true {
    let locked = isScreenLocked()
    let saver = isScreenSaverActive()
    let loginVisible = isLoginWindowVisible()

    let hybrid = saver && locked && loginVisible

    print("""
    locked=\(locked) \
    saver=\(saver) \
    loginVisible=\(loginVisible) \
    hybrid=\(hybrid)
    """)

    usleep(200_000) // 200 ms
}
