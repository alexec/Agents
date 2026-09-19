import Darwin
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("A program on a pseudo-terminal")
struct PTYTests {
    /// Collects output until the program exits, or until time runs out.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var exitStatus: Int32?
        /// How many times output was handed over, as against how many bytes came. The
        /// difference between the two is what `gathered` exists for.
        private var handovers = 0
        /// Bytes that arrived after the program was said to be over. Should be none:
        /// output that lands after its own exit is output a listener has stopped
        /// listening for.
        private var bytesAfterExit = 0

        func append(_ new: Data) {
            lock.lock()
            data.append(new)
            handovers += 1
            if exitStatus != nil { bytesAfterExit += new.count }
            lock.unlock()
        }
        func finish(_ status: Int32) { lock.lock(); exitStatus = status; lock.unlock() }

        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
        var status: Int32? { lock.lock(); defer { lock.unlock() }; return exitStatus }
        var handoverCount: Int { lock.lock(); defer { lock.unlock() }; return handovers }
        var lateBytes: Int { lock.lock(); defer { lock.unlock() }; return bytesAfterExit }

        func waitForExit(within seconds: TimeInterval = 10) async -> Int32? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let status { return status }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return status
        }
    }

    private func run(_ script: String, rows: Int = 24, cols: Int = 80) async throws -> (String, Int32?) {
        let collector = try await collect(script, rows: rows, cols: cols)
        return (collector.text, collector.status)
    }

    private func collect(_ script: String, rows: Int = 24, cols: Int = 80) async throws -> Collector {
        let collector = Collector()
        let pty = try PTY(executable: URL(filePath: "/bin/sh"),
                          arguments: ["-c", script],
                          cwd: URL(filePath: "/tmp"),
                          environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"],
                          rows: rows,
                          cols: cols,
                          onOutput: { collector.append($0) },
                          onExit: { collector.finish($0) })
        _ = pty
        _ = await collector.waitForExit()
        return collector
    }

    @Test func theChildGetsARealControllingTerminal() async throws {
        // The whole reason this is not `Process`. A pipe would make `tty` say "not a
        // tty", and programs would switch to their batch behaviour.
        let (output, status) = try await run("tty")
        #expect(output.contains("/dev/ttys"))
        #expect(status == 0)
    }

    @Test func theWindowSizeReachesTheChild() async throws {
        let (output, _) = try await run("stty size", rows: 40, cols: 120)
        #expect(output.contains("40 120"))
    }

    @Test func aProgramSeesATerminalOnItsOutput() async throws {
        let (output, _) = try await run("test -t 1 && echo yes || echo no")
        #expect(output.contains("yes"))
    }

    @Test func theExitStatusComesBack() async throws {
        let (_, status) = try await run("exit 3")
        #expect(status == 3)
    }

    @Test func aSignalledChildReportsAsAShellDoes() async throws {
        // 128 plus the signal, which is what every shell reports and what anyone
        // reading the number will expect.
        let (_, status) = try await run("kill -TERM $$")
        #expect(status == 128 + SIGTERM, "got \(String(describing: status))")
    }

    @Test func outputArrivesAsItIsProduced() async throws {
        let (output, status) = try await run("echo one; echo two; echo three")
        #expect(output.contains("one"))
        #expect(output.contains("three"))
        #expect(status == 0)
    }

    @Test func aTorrentOfOutputIsHandedOverInArmfuls() async throws {
        // A pty master does not hand back what you ask for. Measured on this Mac, a
        // shell printing 4.9MB came back in 38,057 reads averaging 128 bytes, because
        // the kernel's tty queue is small and the shell refills it as fast as it
        // drains. Every one of those used to become its own notification: encoded to
        // JSON three times, sent over a socket, and decoded twice on the app's main
        // actor. That, and not the bytes, is what made the terminal slow.
        let lines = 5_000
        let collector = try await collect("for i in $(seq 1 \(lines)); do echo '\(String(repeating: "a", count: 100))'; done")

        // Each line is 100 a's, a newline, and the carriage return the tty adds.
        #expect(collector.bytes.count == lines * 102)
        #expect(collector.status == 0)
        // How many handovers this would have been before, at the 128 bytes a read
        // actually comes back with. How fast the machine is decides where in between
        // the real number lands, so the bar is set an order of magnitude away from the
        // old behaviour rather than at any particular count.
        let readByRead = collector.bytes.count / 128
        #expect(collector.handoverCount * 10 < readByRead,
                "handed over \(collector.handoverCount) times where reading alone would have been \(readByRead)")
    }

    @Test func nothingIsStillBeingGatheredWhenTheProgramIsSaidToBeOver() async throws {
        // Output that lands after its own exit lands on nobody: a pane that has been
        // told the shell is gone has stopped feeding its emulator. So whatever is
        // gathered goes first, and the last line a command printed is the last line
        // anyone sees.
        let collector = try await collect("echo first; echo last")
        #expect(collector.lateBytes == 0)
        #expect(collector.text.contains("last"))
    }

    @Test func theBytesComeBackInTheOrderTheyWereWritten() async throws {
        // Gathering reads together must not reorder them, and a terminal is exactly
        // the place where that would show.
        let collector = try await collect("for i in $(seq 1 5000); do echo $i; done")
        let numbers = collector.text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        #expect(numbers == Array(1...5000))
    }

    @Test func aFolderThatIsNotThereIsNamedRatherThanBeingAGenericFailure() throws {
        let missing = "/nowhere-at-all-\(UUID().uuidString)"
        do {
            _ = try PTY(executable: URL(filePath: "/bin/sh"),
                        cwd: URL(filePath: missing),
                        environment: [:],
                        onOutput: { _ in },
                        onExit: { _ in })
            Issue.record("expected it to refuse")
        } catch PTY.Failure.folderGone(let path) {
            // Named, so the pane can say which folder rather than "it did not work".
            #expect(path == missing)
        }
    }

    @Test func aShellThatIsNotThereIsNamed() throws {
        do {
            _ = try PTY(executable: URL(filePath: "/bin/no-such-shell"),
                        cwd: URL(filePath: "/tmp"),
                        environment: [:],
                        onOutput: { _ in },
                        onExit: { _ in })
            Issue.record("expected it to refuse")
        } catch PTY.Failure.shellMissing(let path) {
            #expect(path == "/bin/no-such-shell")
        }
    }

    @Test func writingReachesTheProgram() async throws {
        let collector = Collector()
        let pty = try PTY(executable: URL(filePath: "/bin/sh"),
                          arguments: ["-c", "read line; echo got:$line"],
                          cwd: URL(filePath: "/tmp"),
                          environment: ["PATH": "/usr/bin:/bin"],
                          onOutput: { collector.append($0) },
                          onExit: { collector.finish($0) })
        try await Task.sleep(for: .milliseconds(200))
        pty.write(Data("hello\n".utf8))
        _ = await collector.waitForExit()
        #expect(collector.text.contains("got:hello"))
    }

    @Test func resizingAfterTheFactReachesTheProgram() async throws {
        let collector = Collector()
        let pty = try PTY(executable: URL(filePath: "/bin/sh"),
                          arguments: ["-c", "read line; stty size"],
                          cwd: URL(filePath: "/tmp"),
                          environment: ["PATH": "/usr/bin:/bin"],
                          rows: 24, cols: 80,
                          onOutput: { collector.append($0) },
                          onExit: { collector.finish($0) })
        try await Task.sleep(for: .milliseconds(200))
        pty.resize(rows: 50, cols: 132)
        pty.write(Data("\n".utf8))
        _ = await collector.waitForExit()
        #expect(collector.text.contains("50 132"))
    }
}
