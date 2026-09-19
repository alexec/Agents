// swift-tools-version: 6.2
import PackageDescription

// AgentsKit holds everything that decides anything. The app target is a window and
// a menu bar; the logic lives here, so `swift test` runs it with no Xcode and no
// app launch.
//
// Written as a string rather than `.macOS(.v27)`: this tools version has no `.v27`
// case and the enum form does not compile.
let package = Package(
    name: "AgentsKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AgentsKit", targets: ["AgentsKit"]),
    ],
    targets: [
        .target(name: "AgentsKit"),
        .testTarget(name: "AgentsKitTests", dependencies: ["AgentsKit"]),
    ]
)
