// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RTMPControl",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "RTMPControl",
            path: "Sources/RTMPControl"
        )
    ]
)
