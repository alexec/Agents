import Foundation
import Testing
@testable import AgentsKit

/// A runtime the daemon starts is given only what is named for it (#727), and inherits no
/// other session's idea of who its parent is (2026-09-23).
@Suite("Runtime environment")
struct RuntimeEnvironmentTests {
    static let inherited = ["HOME": "/Users/a", "PATH": "/usr/bin", "LANG": "en_US.UTF-8", "LC_ALL": "C",
                            "SSH_AUTH_SOCK": "/tmp/ssh", "AGENTS_ROOT": "/tmp/root",
                            "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1",
                            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/1.sock", "CLAUDE_PID": "1",
                            "CLAUDE_JOB_DIR": "/x", "ANTHROPIC_API_KEY": "claude-only",
                            "AWS_SECRET_ACCESS_KEY": "cloud", "GITHUB_TOKEN": "gh", "OPENAI_API_KEY": "codex-only"]

    @Test func onlyWhatEveryProgramNeedsGoesThrough() {
        #expect(RuntimeEnvironment.forRuntimes(Self.inherited)
            == ["HOME": "/Users/a", "PATH": "/usr/bin", "LANG": "en_US.UTF-8", "LC_ALL": "C",
                "SSH_AUTH_SOCK": "/tmp/ssh", "AGENTS_ROOT": "/tmp/root"])
    }

    @Test func aRuntimeGetsItsOwnKeysAndNoOtherSessionsVariables() {
        let given = RuntimeEnvironment.forRuntime("claude", Self.inherited)
        #expect(given["ANTHROPIC_API_KEY"] == "claude-only")
        #expect(given["OPENAI_API_KEY"] == nil)
        #expect(given["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(given["GITHUB_TOKEN"] == nil)
        #expect(!given.keys.contains { $0.hasPrefix("CLAUDECODE") || $0 == "CLAUDE_CODE_CHILD_SESSION" })
        #expect(RuntimeEnvironment.forRuntime("codex", Self.inherited)["OPENAI_API_KEY"] == "codex-only")
        #expect(RuntimeEnvironment.forRuntime("copilot", Self.inherited)["GITHUB_TOKEN"] == "gh")
    }

    @Test func thePersonPassesMoreThrough() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"passThrough": {"*": ["GITHUB_TOKEN"], "claude": ["AWS_*"]}}"#.utf8)
            .write(to: root.appendingPathComponent("runtime-environment.json"))
        let names = RuntimeEnvironmentStore(locations: StoreLocations(root: root)).load()
        let claude = RuntimeEnvironment.forRuntime("claude", Self.inherited, passing: names.names(for: "claude"))
        #expect(claude["AWS_SECRET_ACCESS_KEY"] == "cloud")
        #expect(claude["GITHUB_TOKEN"] == "gh")
        let codex = RuntimeEnvironment.forRuntime("codex", Self.inherited, passing: names.names(for: "codex"))
        #expect(codex["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(codex["GITHUB_TOKEN"] == "gh")
    }

    /// The default reads the process's own environment, so a test that runs inside a
    /// Claude Code session sees the scrub work on the real thing.
    @Test func theDefaultIsTheProcessEnvironmentCut() {
        let given = RuntimeEnvironment.forRuntimes()
        #expect(!given.keys.contains { $0.hasPrefix("CLAUDE") })
        #expect(given["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }

    /// The MCP servers Agents ships sit beside agentsd (#700): first on a server's PATH, so
    /// `"command": "ci-watcher"` is ours on any host; last on a runtime's, shadowing nothing.
    @Test func theShippedServersFolderGoesOnPath() {
        let folder = URL(filePath: "/Applications/Agents Host.app/Contents/Helpers")
        let given = ["PATH": "/opt/homebrew/bin:/Applications/Agents Host.app/Contents/Helpers:/usr/bin", "HOME": "/Users/a"]
        #expect(RuntimeEnvironment.withShippedServers(given, first: true, folder: folder)["PATH"]
            == "/Applications/Agents Host.app/Contents/Helpers:/opt/homebrew/bin:/usr/bin")
        #expect(RuntimeEnvironment.withShippedServers(given, first: false, folder: folder)["PATH"]
            == "/opt/homebrew/bin:/usr/bin:/Applications/Agents Host.app/Contents/Helpers")
        #expect(RuntimeEnvironment.withShippedServers(given, first: true, folder: nil) == given)
        #expect(RuntimeEnvironment.withShippedServers(["HOME": "/Users/a"], first: true, folder: folder)["PATH"]
            == "/Applications/Agents Host.app/Contents/Helpers")
    }
}
