import AgentsKit
@testable import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

#if canImport(CryptoKit)
/// `hosts/install` puts Claude's toolset on the server (#1268), against an "ssh" that runs
/// the script here in a home of its own, with a Node small enough to install in a test.
@Suite("Install over ssh: Claude's toolset", .timeLimit(.minutes(1)))
struct HostToolsetsTests {
    static let nodeVersion = "v24.0.0-fake"

    struct Setup {
        let folder: URL
        let home: URL
        let toolsets: URL
        let mirror: URL
        let ssh: SSHCommand
        let toolset: Toolset

        var claude: URL { home.appendingPathComponent(".agents-server/tools/claude") }

        /// A glibc server with no curl, wget or xz on its PATH.
        func facts(toolsetID: String? = nil) -> ServerFacts {
            ServerFacts(system: "Linux", architecture: .aarch64, home: home.path, freeBytes: 1 << 40,
                        installedVersion: nil, streamLocalForwarding: true,
                        libc: .glibc(major: 2, minor: 36), downloader: nil, toolsetID: toolsetID)
        }
    }

    static func setUp(sha: String? = nil) throws -> Setup {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("agents-toolsets-\(UUID().uuidString)")
        let home = folder.appendingPathComponent("home"), bin = folder.appendingPathComponent("bin")
        let mirror = folder.appendingPathComponent("mirror"), staging = folder.appendingPathComponent("staging")
        let top = staging.appendingPathComponent("node-\(nodeVersion)-linux-arm64/bin")
        let claude = folder.appendingPathComponent("toolsets/claude")
        for made in [home, bin, mirror.appendingPathComponent(nodeVersion), top, claude] {
            try fm.createDirectory(at: made, withIntermediateDirectories: true)
        }
        try script(top.appendingPathComponent("node"), "#!/bin/sh\necho \(nodeVersion)")
        try script(top.appendingPathComponent("npm"), """
            #!/bin/sh
            prefix=""; while [ $# -gt 0 ]; do [ "$1" = --prefix ] && { shift; prefix="$1"; }; shift; done
            d="$prefix/node_modules/@agentclientprotocol/claude-agent-acp/dist"; mkdir -p "$d" && echo "// fake" > "$d/index.js"
            """)
        let tarball = mirror.appendingPathComponent("\(nodeVersion)/node-\(nodeVersion)-linux-arm64.tar.xz")
        try run("/usr/bin/tar", ["-cJf", tarball.path, "-C", staging.path, "node-\(nodeVersion)-linux-arm64"])
        let real = try run("/usr/bin/shasum", ["-a", "256", tarball.path]).split(separator: " ")[0]
        let manifest = Toolset.Manifest(runtimeID: "claude", node: .init(version: nodeVersion, sha256: ["aarch64": sha ?? String(real)]),
                                        package: "@agentclientprotocol/claude-agent-acp", packageVersion: "0.0.0-fake",
                                        entry: "dist/index.js", minFreeBytes: 1024)
        try JSONEncoder().encode(manifest).write(to: claude.appendingPathComponent(Toolset.manifestFile))
        try Data(#"{"lockfileVersion":3,"packages":{}}"#.utf8).write(to: claude.appendingPathComponent(Toolset.lockFile))
        try Data(#"{"private":true}"#.utf8).write(to: claude.appendingPathComponent(Toolset.packageFile))
        // ssh: the last argument, run by sh in the fake home, with no curl, wget or xz.
        let fakeSSH = bin.appendingPathComponent("ssh")
        try script(fakeSSH, "#!/bin/sh\nfor a; do last=$a; done\nexec /bin/sh -c \"$last\"")
        let ssh = SSHCommand(executable: fakeSSH, name: "devbox", controlPath: nil,
                             environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        return Setup(folder: folder, home: home, toolsets: claude.deletingLastPathComponent(), mirror: mirror, ssh: ssh,
                     toolset: try Toolset.load(from: claude))
    }

    static func installs(_ setup: Setup) -> HostToolsets {
        HostToolsets(folder: setup.toolsets, nodeDist: setup.mirror)
    }

    @Test func aServerWithNoDownloaderOrXZGetsNodeFromTheControlPlane() async throws {
        let setup = try Self.setUp()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        try await Self.installs(setup).install(setup.toolset, over: setup.ssh, facts: setup.facts())

        let whole = setup.claude.appendingPathComponent(setup.toolset.id)
        #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent("ok").path))
        #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent("node/bin/node").path))
        #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent(
            "lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: setup.claude.appendingPathComponent("current").path) == setup.toolset.id)
        let shim = try await setup.ssh.run(setup.ssh.runArguments("\"$HOME/.agents-server/tools/claude/current/bin/npx\""))
        #expect(shim.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == Self.nodeVersion)
    }

    @Test func aToolsetAlreadyCurrentIsNotFetchedAgain() async throws {
        let setup = try Self.setUp()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let installs = Self.installs(setup)
        try await installs.install(setup.toolset, over: setup.ssh, facts: setup.facts())
        try FileManager.default.removeItem(at: setup.mirror)
        try await installs.install(setup.toolset, over: setup.ssh, facts: setup.facts(toolsetID: setup.toolset.id))
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: setup.claude.appendingPathComponent("current").path) == setup.toolset.id)
    }

    @Test func aNodeThatDoesNotMatchItsPinIsNeverSent() async throws {
        let setup = try Self.setUp(sha: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        await #expect(throws: HostProblem.toolsetChecksum) {
            try await Self.installs(setup).install(setup.toolset, over: setup.ssh, facts: setup.facts())
        }
        #expect(!FileManager.default.fileExists(atPath: setup.claude.appendingPathComponent("current").path))
    }

    /// A failure is logged and the host still starts: install says nothing back.
    @Test func aFailureIsLoggedNotThrown() async throws {
        let setup = try Self.setUp(sha: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let lines = Lines()
        await HostToolsets(folder: setup.toolsets, nodeDist: setup.mirror) { lines.add($0) }
            .install(over: setup.ssh, facts: setup.facts(), name: "devbox")
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.hasPrefix("hosts/install: Claude on devbox: ") == true)
    }

    @Test func theFolderIsFoundFromTheEnvironment() throws {
        let setup = try Self.setUp()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        #expect(HostToolsets.folder(environment: ["AGENTS_CONTROL_TOOLSETS": setup.toolsets.path])?.standardizedFileURL
                == setup.toolsets.standardizedFileURL)
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private static func script(_ url: URL, _ text: String) throws {
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
