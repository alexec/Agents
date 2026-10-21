// swift-tools-version: 6.2
import PackageDescription

// The #1792 spike's demo, on its own manifest, out of the app and AgentsKit:
// FluidAudio is a large download and a beta model, and the spike builds no feature.
let package = Package(
    name: "VoiceDemo",
    platforms: [.macOS(.v15)],
    dependencies: [
        // 0.17.7 is the first with Paradee-8M (beta).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(name: "Speakable"),
        .executableTarget(
            name: "voice-demo",
            dependencies: [
                "Speakable",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "SpeakableTests", dependencies: ["Speakable"]),
    ]
)
