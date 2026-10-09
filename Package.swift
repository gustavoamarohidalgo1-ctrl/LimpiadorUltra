// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LimpiadorMac",
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LimpiadorMac",
            path: "Sources/LimpiadorMac"
        )
    ]
)
