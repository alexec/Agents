// swift-tools-version: 6.2
import PackageDescription

// Spike S1 (058, R8). Not part of the AgentsKit package: swift-nio-ssl and
// swift-crypto stay out of the Mac and the phone until this says they can dial.
let package = Package(
    name: "ControlUplinkLinux",
    products: [
        .executable(name: "psk-dial", targets: ["PSKDial"]),
        .executable(name: "psk-listen", targets: ["PSKListen"]),
        .executable(name: "spike-base", targets: ["SpikeBase"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.0"),
    ],
    targets: [
        .executableTarget(name: "SpikeBase"),
        .executableTarget(
            name: "PSKDial",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .executableTarget(name: "PSKListen"),
    ]
)
