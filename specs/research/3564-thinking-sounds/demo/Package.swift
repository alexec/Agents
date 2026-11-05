// swift-tools-version: 6.2
import PackageDescription

// The #3564 spike's demo: Kokoro says the fillers, on its own manifest, out of the app.
let package = Package(
    name: "Fillers",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The version the app pins (project.yml).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(name: "fillers", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
