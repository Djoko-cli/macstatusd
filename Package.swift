// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macstatusd",
    platforms: [.macOS(.v13)],
    targets: [
        // Bibliothèque testable : configuration, moteur d'état, serveur HTTP sans réseau. Aucun
        // framework système (ni CoreGraphics, ni IOKit, ni AppKit, ni Network).
        .target(name: "MacStatusCore", path: "Sources/MacStatusCore"),
        // Journal fichier (Foundation et os) : séparé de l'exécutable pour que ses tests n'embarquent
        // ni AppKit ni IOKit.
        .target(name: "MacStatusLog", dependencies: ["MacStatusCore"], path: "Sources/MacStatusLog"),
        // Signature du chemin réseau (Foundation et Network) : séparée pour la même raison.
        .target(name: "MacStatusNet", path: "Sources/MacStatusNet"),
        // Exécutable : câblage du daemon (arguments, serveur HTTP, signaux système).
        .executableTarget(name: "macstatusd",
                          dependencies: ["MacStatusCore", "MacStatusLog", "MacStatusNet"],
                          path: "Sources/macstatusd"),
        .testTarget(name: "MacStatusCoreTests",
                    dependencies: ["MacStatusCore", "MacStatusLog", "MacStatusNet"],
                    path: "Tests/MacStatusCoreTests"),
    ]
)
