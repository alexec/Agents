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
        // The control plane's WebSocket, both ends (058): hosts dial with it and the
        // service in Packages/ControlPlane serves with it. Never linked by the apps.
        .library(name: "ControlDial", targets: ["ControlDial"]),
    ],
    dependencies: [
        // The control plane's WebSocket (058): `ControlDial`, linked by `agentsd` on the Mac
        // and on Linux. `swift-crypto` is not a dependency: its BoringSSL would be a second
        // copy.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        // Tests only. See the target below.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "AgentsKitCore", swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(
            name: "ControlDial",
            dependencies: [
                "AgentsKitCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        // Nothing here, deliberately. `agentsd` links this library, and the daemon
        // moves terminal bytes without parsing them. SwiftTerm belongs to the app,
        // where it is declared against the app target in `project.yml`. It dials the
        // control plane with `ControlDial`; the phone links only `AgentsKitCore`.
        .target(
            name: "AgentsKit",
            dependencies: [
                "AgentsKitCore",
                "CShims",
                "ControlDial",
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        // Three one-line C wrappers the Linux build of `agentsd` needs, because Swift
        // cannot call a variadic C function there (037). The Mac uses them too, so there
        // is one path rather than two.
        .target(name: "CShims"),
        // The test target may have it, because a test target is not linked into any
        // product: the daemon is still free of it. The replay test needs a real
        // emulator to prove the property `shell.attach` rests on, which is that the
        // same bytes in any chunking give the same screen.
        .testTarget(
            name: "AgentsKitTests",
            dependencies: ["ControlDial", "AgentsKit", "AgentsKitCore", "accept-probe",
                           .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        // Tests only, and no product: a daemon socket in a process of its own with few
        // descriptors (#201). Out of descriptors is the whole process's state, so it
        // cannot be done to a server inside the test process beside every other test.
        .executableTarget(
            name: "accept-probe",
            dependencies: ["AgentsKit"],
            path: "Tests/AcceptProbe",
            swiftSettings: [.treatAllWarnings(as: .error)]),
    ]
)
