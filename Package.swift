// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenBuddy",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ScreenBuddy",
            path: "Sources/ScreenBuddy"
        )
    ]
)
