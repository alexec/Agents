// swift-tools-version: 6.2
import PackageDescription

// The web remote's protocol types, generated from the Swift source (071, research R6).
//
// `agents-webtypes` reads DaemonAPI, the control types and the models they reach in
// AgentsKitCore's source, and writes Web/src/protocol/generated.ts. A package apart so
// swift-syntax, which is large and slow to build, is never in the apps' or the hosts' graph.
// It reads the Swift as text and does not link AgentsKit.
let package = Package(
    name: "WebTypes",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "agents-webtypes", targets: ["agents-webtypes"]),
        .library(name: "WebTypesKit", targets: ["WebTypesKit"]),
    ],
    dependencies: [
        // Matches the toolchain's Swift (6.4); move with it.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .target(
            name: "WebTypesKit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .executableTarget(
            name: "agents-webtypes",
            dependencies: ["WebTypesKit"],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "WebTypesTests",
            dependencies: ["WebTypesKit"],
            swiftSettings: [.treatAllWarnings(as: .error)]),
    ]
)
