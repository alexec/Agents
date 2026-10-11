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

    /// A daemon launched by launchd has no `/opt/homebrew/bin`, so a server whose command
    /// is `node` exited 127 (#623). It gets the shell's PATH, scrubbed, with its own env last.
    @Test func anMCPServerGetsTheShellsPathAndItsOwnEnv() {
        let shell = ["HOME": "/Users/a", "PATH": "/opt/homebrew/bin:/usr/bin", "CLAUDECODE": "1",
                     "TOKEN": "daemon"]
        let given = RuntimeEnvironment.forMCPServers(["TOKEN": "server"], onto: shell)
        #expect(given == ["HOME": "/Users/a", "PATH": "/opt/homebrew/bin:/usr/bin", "TOKEN": "server"])
        #expect(RuntimeEnvironment.forMCPServers(["PATH": "/mine"], onto: shell)["PATH"] == "/mine")
    }

    @Test func theDefaultIsTheLoginShellsPath() {
        let given = RuntimeEnvironment.forMCPServers([:])
        #expect(given["PATH"] == LoginShellPath.directories().joined(separator: ":"))
        #expect(!given.keys.contains { $0.hasPrefix("CLAUDE") })
    }
}
