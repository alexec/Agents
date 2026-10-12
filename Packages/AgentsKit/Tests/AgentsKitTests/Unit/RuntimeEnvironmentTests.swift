import Foundation
import Testing
@testable import AgentsKit

/// A runtime the daemon starts is the daemon's, and inherits no other session's idea
/// of who its parent is (2026-09-23).
@Suite("Runtime environment")
struct RuntimeEnvironmentTests {
    @Test func aParentSessionsVariablesAreDropped() {
        let inherited = ["HOME": "/Users/a", "PATH": "/usr/bin", "LANG": "en_US.UTF-8",
                         "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1",
                         "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/1.sock", "CLAUDE_PID": "1",
                         "CLAUDE_JOB_DIR": "/x", "ANTHROPIC_API_KEY": "kept-on-purpose"]
        let given = RuntimeEnvironment.forRuntimes(inherited)
        #expect(given == ["HOME": "/Users/a", "PATH": "/usr/bin", "LANG": "en_US.UTF-8",
                          "ANTHROPIC_API_KEY": "kept-on-purpose"])
    }

    /// The default reads the process's own environment, so a test that runs inside a
    /// Claude Code session sees the scrub work on the real thing.
    @Test func theDefaultIsTheProcessEnvironmentScrubbed() {
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
