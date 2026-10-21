// swift-tools-version: 6.2
import PackageDescription

// The #1800 spike's demo, on its own manifest, out of the app: a wake phrase heard by
// the on-device SpeechAnalyzer. It needs no package and no model of its own.
let package = Package(
    name: "WakeDemo",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "wake-demo")]
)
