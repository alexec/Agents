import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// A Claude toolset small enough to install in a test (043).
///
/// The fake server's `curl` (Fixtures/ssh/bin/curl) serves `https://nodejs.org/dist/…` from
/// `mirror`, where this puts a Node "tarball" whose `node` prints a version and whose `npm`
/// lays down the adapter's folder, or fails the way `FAKE_NPM_FAIL` says: `integrity` as npm
/// does for a package that does not match its lock, anything else as a network error. The
/// manifest carries the tarball's real SHA-256, so the install script's own check runs.
struct FakeToolset {
    let toolset: Toolset
    let mirror: URL

    static let nodeVersion = "v24.0.0-fake"

    init(in folder: URL, corruptTarball: Bool = false) throws {
        let fm = FileManager.default
        mirror = folder.appendingPathComponent("mirror", isDirectory: true)
        let bundle = folder.appendingPathComponent("toolset", isDirectory: true)
        let staging = folder.appendingPathComponent("node-staging", isDirectory: true)
        let top = staging.appendingPathComponent("node-\(Self.nodeVersion)-linux-arm64/bin", isDirectory: true)
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: mirror.appendingPathComponent(Self.nodeVersion), withIntermediateDirectories: true)

        try Self.script(at: top.appendingPathComponent("node"), """
            #!/bin/sh
            echo \(Self.nodeVersion)
            """)
        try Self.script(at: top.appendingPathComponent("npm"), """
            #!/bin/sh
            # npm ci --prefix DIR …
            prefix=""; while [ $# -gt 0 ]; do [ "$1" = --prefix ] && { shift; prefix="$1"; }; shift; done
            case "$FAKE_NPM_FAIL" in
                "") ;;
                integrity) echo "npm ERR! code EINTEGRITY" >&2
                           echo "npm ERR! sha512-abc integrity checksum failed" >&2; exit 1 ;;
                *) echo "npm ERR! code ECONNREFUSED" >&2
                   echo "npm ERR! network request failed" >&2; exit 1 ;;
            esac
            d="$prefix/node_modules/@agentclientprotocol/claude-agent-acp/dist"
            mkdir -p "$d" && echo "// fake adapter" > "$d/index.js"
            """)

        let tarball = mirror.appendingPathComponent("\(Self.nodeVersion)/node-\(Self.nodeVersion)-linux-arm64.tar.xz")
        try Self.run("/usr/bin/tar", ["-cJf", tarball.path, "-C", staging.path, "node-\(Self.nodeVersion)-linux-arm64"],
                     environment: ["COPYFILE_DISABLE": "1"])
        let sha = try Self.sha256(tarball)
        if corruptTarball {
            let handle = try FileHandle(forWritingTo: tarball)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("x".utf8))
            try handle.close()
        }

        let manifest = Toolset.Manifest(
            runtimeID: "claude",
            node: .init(version: Self.nodeVersion, sha256: ["aarch64": sha, "x86_64": sha]),
            package: "@agentclientprotocol/claude-agent-acp", packageVersion: "0.0.0-fake",
            entry: "dist/index.js", minFreeBytes: 1024)
        let manifestData = try JSONEncoder().encode(manifest)
        let lock = Data(#"{"name":"agents-claude-toolset","lockfileVersion":3,"packages":{}}"#.utf8)
        try manifestData.write(to: bundle.appendingPathComponent(Toolset.manifestFile))
        try lock.write(to: bundle.appendingPathComponent(Toolset.lockFile))
        try Data(#"{"name":"agents-claude-toolset","private":true}"#.utf8)
            .write(to: bundle.appendingPathComponent(Toolset.packageFile))
        toolset = try Toolset.load(from: bundle)
    }

    /// What the fake server needs in its environment: its own curl and no npx of the Mac's.
    func environment(npmFail: String? = nil, curlFail: String? = nil, ldd: String? = nil) -> [String: String] {
        var env = ["FAKE_TOOLS_MIRROR": mirror.path, "FAKE_SSH_PATH": "/usr/bin:/bin"]
        if let npmFail { env["FAKE_NPM_FAIL"] = npmFail }
        if let curlFail { env["FAKE_CURL_FAIL"] = curlFail }
        if let ldd { env["FAKE_SSH_LDD"] = ldd }
        return env
    }

    private static func script(at url: URL, _ text: String) throws {
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func run(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func sha256(_ file: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
    }
}
