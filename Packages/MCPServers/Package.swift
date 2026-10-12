// swift-tools-version: 6.2
import PackageDescription

// The MCP servers Agents ships (#700): each a single static binary, built in Swift for macOS
// and, by scripts/build-linux-agentsd.sh, for Linux (musl), so a host that runs one needs no
// Node or other runtime. MCPServerKit is what they share: newline-delimited JSON-RPC on
// stdio, the MCP methods every server answers, argument checks, event cursors and running a
// command. The CI watcher (#383) is the first; the workspace command provider (#691) is next.
//
// Nothing here depends on AgentsKit, so a server stays small and builds on Linux on its own.
let package = Package(
    name: "MCPServers",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MCPServerKit", targets: ["MCPServerKit"]),
        // For project.yml's ci-watcher tool, which Agents Host carries (#700).
        .library(name: "CIWatcher", targets: ["CIWatcher"]),
        .executable(name: "ci-watcher", targets: ["ci-watcher"]),
    ],
    targets: [
        .target(name: "MCPServerKit", swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(name: "CIWatcher", dependencies: ["MCPServerKit"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .executableTarget(name: "ci-watcher", dependencies: ["CIWatcher", "MCPServerKit"],
                          swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "MCPServerKitTests", dependencies: ["MCPServerKit"]),
        .testTarget(name: "CIWatcherTests", dependencies: ["CIWatcher", "MCPServerKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
