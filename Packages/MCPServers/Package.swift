// swift-tools-version: 6.2
import PackageDescription

// The MCP servers Agents ships (#700): each a single static binary, built in Swift for macOS
// and, by scripts/build-linux-agentsd.sh, for Linux (musl), so a host that runs one needs no
// Node or other runtime. MCPServerKit is what they share: newline-delimited JSON-RPC on
// stdio, the MCP methods every server answers, argument checks, event cursors and running a
// command. The workspace command provider (#691) is the one here now; the CI watcher (#383)
// was the first, and the github server in Go (#1232) took its place (#1231).
//
// Nothing here depends on AgentsKit, so a server stays small and builds on Linux on its own.
let package = Package(
    name: "MCPServers",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MCPServerKit", targets: ["MCPServerKit"]),
        .library(name: "WorkspaceCommands", targets: ["WorkspaceCommands"]),
        .executable(name: "workspace-commands", targets: ["workspace-commands"]),
    ],
    targets: [
        .target(name: "MCPServerKit", swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(name: "WorkspaceCommands", dependencies: ["MCPServerKit"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .executableTarget(name: "workspace-commands", dependencies: ["WorkspaceCommands", "MCPServerKit"],
                          swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "MCPServerKitTests", dependencies: ["MCPServerKit"]),
        .testTarget(name: "WorkspaceCommandsTests", dependencies: ["WorkspaceCommands", "MCPServerKit"]),
    ]
)
