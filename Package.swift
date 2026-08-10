// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AILimit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AILimit",
            path: "Sources/AILimit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
