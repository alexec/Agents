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
    dependencies: [
        // Tests only. See the target below.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // Nothing here, deliberately. `agentsd` links this library, and the daemon
        // moves terminal bytes without parsing them. SwiftTerm belongs to the app,
        // where it is declared against the app target in `project.yml`.
        .target(name: "AgentsKit"),
        // The test target may have it, because a test target is not linked into any
        // product: the daemon is still free of it. The replay test needs a real
        // emulator to prove the property `shell.attach` rests on, which is that the
        // same bytes in any chunking give the same screen.
        .testTarget(
            name: "AgentsKitTests",
            dependencies: ["AgentsKit", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    ]
)
