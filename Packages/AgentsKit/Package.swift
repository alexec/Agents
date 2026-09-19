// swift-tools-version: 6.2
import PackageDescription

// Two targets, split by platform, because the phone needs the model and the protocol
// and cannot have `Process`, `posix_spawn` or a PTY.
//
// `AgentsKitCore` is everything both platforms can hold: the record, the JSON-RPC
// line protocol, the daemon's method names, and the client that speaks them over any
// transport. `AgentsKit` is the Mac's half — the daemon itself, the stores, the
// terminal and the runtimes it spawns — and re-exports Core, so every file that says
// `import AgentsKit` today keeps working unchanged.
//
// Written as a string rather than `.macOS(.v27)`: this tools version has no `.v27`
// case and the enum form does not compile.
let package = Package(
    name: "AgentsKit",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "AgentsKit", targets: ["AgentsKit"]),
        // The phone links this one. It is the only product that builds for iOS.
        .library(name: "AgentsKitCore", targets: ["AgentsKitCore"]),
    ],
    dependencies: [
        // Tests only. See the target below.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "AgentsKitCore"),
        // Nothing here, deliberately. `agentsd` links this library, and the daemon
        // moves terminal bytes without parsing them. SwiftTerm belongs to the app,
        // where it is declared against the app target in `project.yml`.
        .target(name: "AgentsKit", dependencies: ["AgentsKitCore"]),
        // The test target may have it, because a test target is not linked into any
        // product: the daemon is still free of it. The replay test needs a real
        // emulator to prove the property `shell.attach` rests on, which is that the
        // same bytes in any chunking give the same screen.
        .testTarget(
            name: "AgentsKitTests",
            dependencies: ["AgentsKit", "AgentsKitCore",
                           .product(name: "SwiftTerm", package: "SwiftTerm")]),
    ]
)
