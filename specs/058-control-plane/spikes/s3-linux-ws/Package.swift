// swift-tools-version: 6.0
import PackageDescription

// Spike S3 (058, R7). A standalone package: nothing here is linked into the app.
// ws-dial is the thing measured: swift-nio + NIOHTTP1 + NIOWebSocket + NIOSSL, no swift-crypto.
// ws-echo is only the test server. print-base is the size baseline, built the same way.
let package = Package(
    name: "S3LinuxWS",
    products: [
        .executable(name: "ws-dial", targets: ["WSDial"]),
        .executable(name: "ws-echo", targets: ["WSEcho"]),
        .executable(name: "print-base", targets: ["PrintBase"]),
        .executable(name: "print-foundation", targets: ["PrintFoundation"]),
        .executable(name: "ws-dial-foundation", targets: ["WSDialFoundation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
    ],
    targets: [
        .executableTarget(name: "PrintBase"),
        .executableTarget(name: "PrintFoundation"),
        .executableTarget(
            name: "WSDialFoundation",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: [.define("KEEP_FOUNDATION")]),
        .executableTarget(
            name: "WSDial",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        .executableTarget(
            name: "WSEcho",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
    ],
    swiftLanguageModes: [.v5]
)
