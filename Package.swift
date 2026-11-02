// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Poinky",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Poinky",
            path: "Sources/Poinky"
        )
    ]
)
