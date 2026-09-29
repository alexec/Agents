// swift-tools-version: 6.2
import PackageDescription

// The control plane as a service of its own (058, research R3): one program,
// `agents-control`, that runs as a single copy in Agents Host on a Mac or as several
// copies in a container on Linux, over one store.
//
// A package apart from AgentsKit so no App Store target can link a server by accident,
// and so it builds on Linux without the Xcode project. It needs only AgentsKitCore:
// the router, the wire, the records and ControlAgreement's keys.
let package = Package(
    name: "ControlPlane",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "agents-control", targets: ["agents-control"]),
        .library(name: "ControlPlaneKit", targets: ["ControlPlaneKit"]),
    ],
    dependencies: [
        .package(path: "../AgentsKit"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.25.0"),
    ],
    targets: [
        .target(
            name: "ControlPlaneKit",
            dependencies: [
                .product(name: "AgentsKitCore", package: "AgentsKit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]),
        .executableTarget(name: "agents-control", dependencies: ["ControlPlaneKit"]),
        .testTarget(name: "ControlPlaneKitTests", dependencies: ["ControlPlaneKit"]),
    ]
)
