// swift-tools-version: 6.2
import PackageDescription

// `agentsd` for Linux (037). On the Mac, `project.yml` builds this same `Sources/` as an
// Xcode tool and nothing reads this file. It exists so `swift build --swift-sdk
// <arch>-swift-linux-musl` has an executable to build: one `main.swift`, two platforms,
// no fork. `scripts/build-linux-agentsd.sh` is the only thing expected to use it.
let package = Package(
    name: "agentsd",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../Packages/AgentsKit"),
    ],
    targets: [
        .executableTarget(
            name: "agentsd",
            dependencies: [.product(name: "AgentsKit", package: "AgentsKit")],
            path: "Sources"),
    ]
)
