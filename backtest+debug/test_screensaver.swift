import Foundation

print("Listening for screensaver notifications…")

let dist = DistributedNotificationCenter.default()

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstart"),
    object: nil,
    queue: .main
) { _ in
    print("🟥 Screensaver START")
}

dist.addObserver(
    forName: NSNotification.Name("com.apple.screensaver.didstop"),
    object: nil,
    queue: .main
) { _ in
    print("🟩 Screensaver STOP")
}

RunLoop.main.run()
