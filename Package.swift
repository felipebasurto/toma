// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Toma",
    platforms: [.macOS("15.3")],
    targets: [
        .executableTarget(
            name: "Toma",
            path: "Sources/Toma",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
