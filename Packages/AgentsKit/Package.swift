// swift-tools-version: 6.2
import PackageDescription

// Two targets, split by platform, because the phone needs the model and the protocol
// and cannot have `Process`, `posix_spawn` or a PTY.
//
// `AgentsKitCore` is everything both platforms can hold: the record, the JSON-RPC
// line protocol, the daemon's method names, and the client that speaks them over any
// transport. `AgentsKit` is what Agents Host and agents-relay need beyond it (the daemon
// itself is Go since #1138, and its Swift sources went in #1314), and re-exports Core.
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
        // The control plane's WebSocket (058): agents-relay dials with it, and the tests
        // serve with it. Never linked by the apps.
        .library(name: "ControlDial", targets: ["ControlDial"]),
    ],
    dependencies: [
        // The control plane's WebSocket (058): `ControlDial`, linked by agents-relay.
        // `swift-crypto` is not a dependency: its BoringSSL would be a second copy.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
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
        // What Agents Host and agents-relay still link (#1314): the relay's dial to the control
        // plane with `ControlDial`, the move of a set-up, ssh, and the local socket's server.
        // The daemon is Go (#1138). SwiftTerm belongs to the app, declared in `project.yml`.
        .target(
            name: "AgentsKit",
            dependencies: ["AgentsKitCore", "ControlDial"],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "AgentsKitTests",
            dependencies: ["ControlDial", "AgentsKit", "AgentsKitCore", "accept-probe",
                           // A proxy and a server of the tests' own, for the dial (#2177).
                           .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOPosix", package: "swift-nio")],
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
