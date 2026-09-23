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
}
