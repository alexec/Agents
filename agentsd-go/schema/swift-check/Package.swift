// swift-tools-version: 6.2
// Stage 3's check (#1125): the Swift types quicktype made from schema/daemon.schema.json
// against today's AgentsKitCore encoder. No change to the product's Swift: it is only a
// dependency here.
import PackageDescription

let package = Package(
    name: "WireCheck",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../../../Packages/AgentsKit")],
    targets: [
        .target(name: "WireTypes", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "WireCheckTests", dependencies: [
            "WireTypes", .product(name: "AgentsKitCore", package: "AgentsKit"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
