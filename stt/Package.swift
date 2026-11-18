// swift-tools-version: 6.2
// Poinky's optional local speech recognizer (Settings → Voice → Speech recognition). Built only when you install
// it (stt/install.sh), so the app itself keeps building with no dependencies.
import PackageDescription

let package = Package(
    name: "poinky-stt",
    platforms: [.macOS("26.0")],
    dependencies: [
        // FluidAudio (Apache-2.0): Parakeet TDT on the Neural Engine. ASR only (no TTS / diarization).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: []),
    ],
    targets: [
        .executableTarget(name: "poinky-stt", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
