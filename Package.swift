// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macstatusd",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "macstatusd", path: "Sources/macstatusd")
    ]
)
