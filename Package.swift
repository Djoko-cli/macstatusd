// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macstatusd",
    platforms: [.macOS(.v13)],
    targets: [
        // Bibliothèque testable : configuration, journal, puis (tâches suivantes) le moteur.
        .target(name: "MacStatusCore", path: "Sources/MacStatusCore"),
        // Exécutable : câblage du daemon (arguments, journal fichier, serveur HTTP).
        .executableTarget(name: "macstatusd", dependencies: ["MacStatusCore"], path: "Sources/macstatusd"),
        .testTarget(name: "MacStatusCoreTests", dependencies: ["MacStatusCore", "macstatusd"], path: "Tests/MacStatusCoreTests"),
    ]
)
