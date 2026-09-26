import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// A Claude toolset for this Mac small enough to install in a test (048).
///
/// `dist` is a `file://` stand-in for nodejs.org holding a Node "tarball" whose `npm` lays
/// down the adapter's folder, or fails the way `FAKE_NPM_FAIL` says. `mac-node.json`
/// carries the tarball's real SHA-256, or a wrong one, so the installer's own check runs.
struct FakeMacToolset {
    let toolset: Toolset
    let dist: URL
    let root: URL

    static let nodeVersion = "v24.0.0-fake"
    static let architecture = "arm64"

    init(wrongChecksum: Bool = false) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("mac-toolset-\(UUID().uuidString)", isDirectory: true)
        dist = root.appendingPathComponent("dist", isDirectory: true)
        let bundle = root.appendingPathComponent("toolset", isDirectory: true)
        let name = "node-\(Self.nodeVersion)-darwin-\(Self.architecture)"
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let bin = staging.appendingPathComponent("\(name)/bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: dist.appendingPathComponent(Self.nodeVersion), withIntermediateDirectories: true)

        try Self.script(at: bin.appendingPathComponent("node"), "#!/bin/sh\necho \(Self.nodeVersion)")
        try Self.script(at: bin.appendingPathComponent("npm"), """
            #!/bin/sh
            # npm ci … --prefix DIR …
            prefix=""; while [ $# -gt 0 ]; do [ "$1" = --prefix ] && { shift; prefix="$1"; }; shift; done
            case "$FAKE_NPM_FAIL" in
                "") ;;
                integrity) echo "npm ERR! code EINTEGRITY" >&2; exit 1 ;;
                *) echo "npm ERR! code E500" >&2
                   echo "npm ERR! the registry said no" >&2; exit 1 ;;
            esac
            [ -f "$prefix/package-lock.json" ] || { echo "no lock in $prefix" >&2; exit 1; }
            d="$prefix/node_modules/@agentclientprotocol/claude-agent-acp/dist"
            mkdir -p "$d" && echo "// fake adapter" > "$d/index.js"
            """)
        let tarball = dist.appendingPathComponent("\(Self.nodeVersion)/\(name).tar.gz")
        try Self.run("/usr/bin/tar", ["-czf", tarball.path, "-C", staging.path, name])
        let sha = wrongChecksum ? String(repeating: "0", count: 64) : try MacToolsetInstaller.sha256(of: tarball)

        let manifest = Toolset.Manifest(
            runtimeID: "claude", node: .init(version: Self.nodeVersion, sha256: [:]),
            package: "@agentclientprotocol/claude-agent-acp", packageVersion: "0.0.0-fake",
            entry: "dist/index.js", minFreeBytes: 1024)
        try JSONEncoder().encode(manifest).write(to: bundle.appendingPathComponent(Toolset.manifestFile))
        try Data(#"{"lockfileVersion":3,"packages":{}}"#.utf8).write(to: bundle.appendingPathComponent(Toolset.lockFile))
        try Data(#"{"private":true}"#.utf8).write(to: bundle.appendingPathComponent(Toolset.packageFile))
        try JSONEncoder().encode(Toolset.MacNode(version: Self.nodeVersion, sha256: [Self.architecture: sha]))
            .write(to: bundle.appendingPathComponent(Toolset.macNodeFile))
        toolset = try Toolset.load(from: bundle)
    }

    var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }

    func installer(npmFail: String? = nil) -> MacToolsetInstaller {
        var environment = ["PATH": "/usr/bin:/bin"]
        if let npmFail { environment["FAKE_NPM_FAIL"] = npmFail }
        return MacToolsetInstaller(toolset: toolset, tools: tools, nodeDist: dist,
                                   architecture: Self.architecture, environment: environment)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func script(at url: URL, _ text: String) throws {
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = ["COPYFILE_DISABLE": "1"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
