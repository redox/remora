// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "siwc-spike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "siwc-spike",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
