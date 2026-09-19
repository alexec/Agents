import Foundation
import Testing
@testable import AgentsKit

/// What a terminal is allowed to walk away with.
///
/// `CloseOnExecTests` already holds the consequences — that the next daemon can take
/// the lock, and that a window's connection reaches end of file — and it holds them by
/// spawning a plain `/bin/sh` with bare `posix_spawn`. This asks the same question of
/// the path the daemon actually uses, which is `PTY`, because that one carries its own
/// spawn attributes: `POSIX_SPAWN_CLOEXEC_DEFAULT` and a set of file actions naming the
/// tty. A descriptor marked to close and a spawn that honours the mark are two separate
/// claims, and this is the only test that exercises the second on the real terminal
/// path.
@Suite("What a terminal inherits", .timeLimit(.minutes(1)))
struct InheritedDescriptorTests {
    @Test func aTerminalIsGivenItsTtyAndNothingElseOfOurs() throws {
        // What a shell has open with the daemon holding nothing unusual, which is the
        // floor: its tty, and whatever `ls` opens to answer the question.
        let ordinary = try descriptorsInATerminal()

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inherit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let lock = try #require(DaemonLock(at: folder.appendingPathComponent("daemon.lock")))
        defer { lock.release() }
        let server = DaemonServer(url: folder.appendingPathComponent("d.sock")) { _, _ in
            .success(["ok": true])
        }
        try server.start()
        defer { server.stop() }

        let whileHolding = try descriptorsInATerminal()
        #expect(whileHolding == ordinary,
                "a terminal was handed something of the daemon's: \(whileHolding.subtracting(ordinary))")
    }

    /// The descriptors a shell on a pty actually has, asked of the shell itself.
    ///
    /// Written to a file rather than read back from the pty, so the answer does not
    /// depend on how the terminal's output happens to be chunked or flushed.
    private func descriptorsInATerminal() throws -> Set<String> {
        let answer = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fds-\(UUID().uuidString.prefix(8)).txt")
        defer { try? FileManager.default.removeItem(at: answer) }

        let done = DispatchSemaphore(value: 0)
        let terminal = try PTY(executable: URL(fileURLWithPath: "/bin/sh"),
                               arguments: ["-c", "ls /dev/fd > \(answer.path)"],
                               cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                               environment: ["PATH": "/usr/bin:/bin"],
                               onOutput: { _ in },
                               onExit: { _ in done.signal() })
        defer { terminal.terminate() }
        guard done.wait(timeout: .now() + .seconds(10)) == .success else {
            Issue.record("the shell never finished")
            return []
        }
        let text = try String(contentsOf: answer, encoding: .utf8)
        return Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
