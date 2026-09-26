import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Claude on a Mac with no Node: the app's pinned toolset, installed in the daemon's own
/// folder (048).
@Suite("Installing a toolset on this Mac", .timeLimit(.minutes(1)))
struct MacToolsetInstallerTests {
    @Test func aWholeInstallIsCurrentMarkedOkAndHasAnExecutableShim() async throws {
        let fake = try FakeMacToolset()
        defer { fake.remove() }
        let shim = try await fake.installer().install()

        let folder = fake.tools.appendingPathComponent("claude")
        let current = folder.appendingPathComponent("current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == fake.toolset.id)
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("ok").path))
        #expect(FileManager.default.isExecutableFile(atPath: shim))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent(
            fake.toolset.manifest.entryPath).path), "npm ci ran against the lock, in lib")
        let text = try String(contentsOfFile: shim, encoding: .utf8)
        #expect(text == fake.toolset.shimLines.joined(separator: "\n") + "\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == [fake.toolset.id, "current"].sorted(), "nothing half-built is left beside it")

        var discovery = RuntimeDiscovery(searchPaths: ["/nowhere"])
        discovery.macToolsHome = fake.tools.path
        #expect(discovery.locate(RuntimeCatalog.claude) == .available(path: "\(current.path)/bin/npx", supportsResume: false))
    }

    /// A second runtime's toolset (047) lands in its own folder, with its own shim, and says
    /// its own name when it fails.
    @Test func anotherRuntimesToolsetInstallsBesideClaudesUnderItsOwnName() async throws {
        let claude = try FakeMacToolset()
        defer { claude.remove() }
        let codex = try FakeMacToolset(runtimeID: "codex", package: "@agentclientprotocol/codex-acp")
        defer { codex.remove() }
        let installer = MacToolsetInstaller(toolset: codex.toolset, tools: claude.tools, nodeDist: codex.dist,
                                            architecture: FakeMacToolset.architecture,
                                            environment: ["PATH": "/usr/bin:/bin"])
        _ = try await claude.installer().install()
        let shim = try await installer.install()

        let current = claude.tools.appendingPathComponent("codex/current")
        #expect(shim.hasPrefix(MacToolsetInstaller.realPath(claude.tools.appendingPathComponent("codex")).path))
        #expect(shim.hasSuffix("/bin/\(codex.toolset.shimName)"))
        #expect(FileManager.default.isExecutableFile(atPath: shim))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent(
            "lib/node_modules/@agentclientprotocol/codex-acp/dist/index.js").path))
        #expect(FileManager.default.fileExists(atPath: claude.tools.appendingPathComponent("claude/current/ok").path),
                "Claude's is untouched")
        #expect(installer.runtimeName == (RuntimeCatalog.runtime(id: "codex")?.name ?? "codex"))
        #expect(MacToolsetInstaller.Failure.noInternet("").sentence(for: "Codex")
                == "Couldn’t reach the internet to download Codex.")
        #expect(MacToolsetInstaller.Failure.npm("E500").sentence(for: "Claude") == "Installing Claude failed: E500")
    }

    @Test func aChecksumMismatchInstallsNothing() async throws {
        let fake = try FakeMacToolset(wrongChecksum: true)
        defer { fake.remove() }
        await #expect(throws: MacToolsetInstaller.Failure.checksum) { try await fake.installer().install() }
        let folder = fake.tools.appendingPathComponent("claude")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "the .part folder is gone")
    }

    @Test func npmFailingSaysWhatNpmSaid() async throws {
        let fake = try FakeMacToolset()
        defer { fake.remove() }
        await #expect(throws: MacToolsetInstaller.Failure.npm("the registry said no")) {
            try await fake.installer(npmFail: "registry").install()
        }
        await #expect(throws: MacToolsetInstaller.Failure.checksum) {
            try await fake.installer(npmFail: "integrity").install()
        }
    }

    @Test func aHalfInstallIsNeverLocated() async throws {
        let fake = try FakeMacToolset()
        defer { fake.remove() }
        _ = try? await fake.installer(npmFail: "registry").install()
        // And one left behind by hand, with its shim and no `ok`, as a crash would.
        let set = fake.tools.appendingPathComponent("claude/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: set.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FakeMacToolset.script(at: set.appendingPathComponent("bin/npx"), "#!/bin/sh")
        try FileManager.default.createSymbolicLink(
            atPath: fake.tools.appendingPathComponent("claude/current").path, withDestinationPath: "abc")

        var discovery = RuntimeDiscovery(searchPaths: ["/nowhere"])
        discovery.macToolsHome = fake.tools.path
        #expect(discovery.locate(RuntimeCatalog.claude) == .missing(lookedIn: ["/nowhere"]))
    }

    @Test func aBuildWithNoMacPinSaysSo() async throws {
        let fake = try FakeMacToolset()
        defer { fake.remove() }
        var installer = fake.installer()
        installer.toolset.macNode = nil
        await #expect(throws: MacToolsetInstaller.Failure.noMacPin) { try await installer.install() }
    }

    @Test func theBundledPinNamesBothMacArchitectures() throws {
        let toolset = try Toolset.load(from: ToolsetTests.bundled)
        let node = try #require(toolset.macNode)
        #expect(node.version == toolset.manifest.node.version, "the same Node as the servers'")
        #expect(node.sha256["arm64"]?.count == 64)
        #expect(node.sha256["x64"]?.count == 64)
        #expect(node.tarball(for: "arm64") == "\(node.version)/node-\(node.version)-darwin-arm64.tar.gz")
    }

    @Test func theServerScriptWritesTheSameShimAndNpmArguments() throws {
        let toolset = try Toolset.load(from: ToolsetTests.bundled)
        var facts = ServerFacts(system: "Linux", architecture: .aarch64, home: "/home/agents", freeBytes: 1 << 40,
                                installedVersion: nil, installedSHA256: nil, streamLocalForwarding: true)
        facts.downloader = "curl"
        let script = ToolsetInstaller.installScript(toolset, facts)
        #expect(script.contains(#"npm ci --ignore-scripts --omit=dev --no-audit --no-fund --prefix "$P/lib""#))
        #expect(script.contains("printf '%s\\n' '#!/bin/sh' '# Agents: runs the @agentclientprotocol/claude-agent-acp this toolset was installed with.'"))
        #expect(script.contains(#"exec "$d/node/bin/node" "$d/lib/node_modules/@agentclientprotocol/claude-agent-acp/"#))
    }
}
