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

    private func run(_ script: String, rows: Int = 24, cols: Int = 80,
                     saying: String? = nil) async throws -> (String, Int32?) {
        let collector = try await collect(script, rows: rows, cols: cols, saying: saying)
        return (collector.text, collector.status)
    }

    /// Run a script on a pty and gather what it said.
    ///
    /// `saying` is what the caller is about to assert, waited for rather than assumed.
    /// The exit is reported when the child is reaped, and the last of its output is
    /// read off the pty on a source of its own, so reading the text the moment the
    /// exit arrives reads it short now and then.
    private func collect(_ script: String, rows: Int = 24, cols: Int = 80,
                         saying: String? = nil) async throws -> Collector {
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
        if let saying {
            await eventually("the program's output reached us") { collector.text.contains(saying) }
        }
        return collector
    }

    @Test func theChildGetsARealControllingTerminal() async throws {
        // The whole reason this is not `Process`. A pipe would make `tty` say "not a
        // tty", and programs would switch to their batch behaviour.
        let (output, status) = try await run("tty", saying: "/dev/ttys")
        #expect(output.contains("/dev/ttys"))
        #expect(status == 0)
    }

    @Test func theWindowSizeReachesTheChild() async throws {
        let (output, _) = try await run("stty size", rows: 40, cols: 120, saying: "40 120")
        #expect(output.contains("40 120"))
    }

    @Test(.flakyUnderLoad) func aProgramSeesATerminalOnItsOutput() async throws {
        let (output, _) = try await run("test -t 1 && echo yes || echo no", saying: "yes")
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
        let (output, status) = try await run("echo one; echo two; echo three", saying: "three")
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
        await eventually("every line came back") { collector.bytes.count == lines * 102 }

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

    @Test func theLastThingAProgramSaidSurvivesASlowReader() async throws {
        // macOS throws away whatever is still sitting in a tty's queue at the last
        // close of the slave. Letting go of our side the moment the child had been
        // given its own made the child's exit that last close, so a program that
        // printed and went before the reader had been scheduled had every byte it
        // wrote discarded by the kernel — and the pty reported a clean exit with
        // nothing in front of it. It only showed on a loaded machine, which is
        // exactly when it matters, and it looked like a flaky test for weeks.
        //
        // Held rather than raced for. `onOutput` runs on the reader's own queue, so
        // blocking in it stops the pty reading; the shell is then made to close its
        // tty and say so, in that order, before the reader is let go again. Against
        // the old code this reads back "BEGIN" and nothing else, every time.
        let marker = URL(filePath: NSTemporaryDirectory())
            .appending(path: "pty-let-go-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: marker) }

        let collector = Collector()
        let gate = DispatchSemaphore(value: 0)
        let pty = try PTY(executable: URL(filePath: "/bin/sh"),
                          arguments: ["-c", """
                              echo BEGIN; read gate; echo one; echo two; echo three; \
                              exec 3>/dev/null; exec 0<&3 1>&3 2>&3; : > \(marker.path)
                              """],
                          cwd: URL(filePath: "/tmp"),
                          environment: ["PATH": "/usr/bin:/bin"],
                          onOutput: {
                              collector.append($0)
                              // Everything after the first handover waits here, which
                              // is what makes the reader late on purpose.
                              gate.wait(); gate.signal()
                          },
                          onExit: { collector.finish($0) })

        await eventually("the shell said hello") { collector.text.contains("BEGIN") }
        // The reader is now parked inside its own callback. Nothing the shell says
        // from here can be read until this test says so.
        pty.write(Data("\n".utf8))
        await eventually("the shell printed and let go of its tty") {
            FileManager.default.fileExists(atPath: marker.path)
        }
        gate.signal()

        _ = await collector.waitForExit()
        await eventually("the last of the output reached us") { collector.text.contains("three") }
        #expect(collector.text.contains("one"))
        #expect(collector.text.contains("three"))
        #expect(collector.status == 0)
        withExtendedLifetime(pty) {}
    }

    @Test func theBytesComeBackInTheOrderTheyWereWritten() async throws {
        // Gathering reads together must not reorder them, and a terminal is exactly
        // the place where that would show.
        let collector = try await collect("for i in $(seq 1 5000); do echo $i; done")
        @Sendable func numbersSoFar() -> [Int] {
            collector.text
                .split(whereSeparator: \.isNewline)
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        await eventually("every line came back") { numbersSoFar().count == 5000 }
        #expect(numbersSoFar() == Array(1...5000))
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
        // Setup, not an assertion: give the shell time to reach its `read`. Writing
        // earlier would not be lost — the tty buffers it — so this is belt and braces
        // rather than a race the test depends on.
        try await Task.sleep(for: .milliseconds(200))
        pty.write(Data("hello\n".utf8))
        _ = await collector.waitForExit()
        await eventually("the echo reached us") { collector.text.contains("got:hello") }
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
        // As above. The resize applies to the pty itself whether or not the child has
        // got as far as `read`, so this only makes the intent plain.
        try await Task.sleep(for: .milliseconds(200))
        pty.resize(rows: 50, cols: 132)
        pty.write(Data("\n".utf8))
        _ = await collector.waitForExit()
        await eventually("the size reached us") { collector.text.contains("50 132") }
        #expect(collector.text.contains("50 132"))
    }
}
