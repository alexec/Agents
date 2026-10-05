import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A runtime and everything it starts go together, and its pipe is read only as its own
/// (#209). Claude runs through `npx`, whose node child is the runtime: ending only the
/// process the daemon started left that child orphaned, holding the pipes.
@Suite("A runtime's process group", .timeLimit(.minutes(1)))
struct RuntimeProcessGroupTests {
    /// A runtime that starts a child, says its pid on stderr, and then does `last`.
    private func launch(then last: String) throws -> (RuntimeProcess, ChildPid) {
        let child = ChildPid()
        let process = try RuntimeProcess(executable: URL(filePath: "/bin/sh"),
                                         arguments: ["-c", "sleep 300 & echo $! >&2; \(last)"],
                                         cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
                                         environment: [:],
                                         onStandardError: { child.heard($0) },
                                         onExit: { _ in })
        return (process, child)
    }

    @Test func endingTheRuntimeEndsWhatItStarted() async throws {
        let (process, child) = try launch(then: "wait")
        try await eventually("the runtime said its child's pid") { child.pid != nil }
        let pid = try #require(child.pid)
        #expect(kill(pid, 0) == 0, "the child is running")

        process.terminate()
        try await eventually("the runtime is gone") { !process.isRunning }
        try await eventually("and so is its child") { kill(pid, 0) != 0 }
        process.cleanUp()
    }

    /// A runtime that exits by itself leaves nothing behind it either.
    @Test func aRuntimeThatExitsTakesWhatItStartedWithIt() async throws {
        let (process, child) = try launch(then: "exit 0")
        try await eventually("the runtime said its child's pid") { child.pid != nil }
        let pid = try #require(child.pid)
        try await eventually("the runtime is gone") { !process.isRunning }
        try await eventually("and so is its child") { kill(pid, 0) != 0 }
        process.cleanUp()
    }

    /// Closing a transport over a pipe that something else still holds open — the
    /// grandchild that kept stdout — wakes the reading thread, which lets the pipe go.
    /// It used to be closed under that thread, which then read again from whatever the
    /// number had been given to since.
    @Test func closingAPipeTransportLetsItsReadEndGoAtOnce() async throws {
        var output: [Int32] = [-1, -1], input: [Int32] = [-1, -1]
        try #require(pipe(&output) == 0 && pipe(&input) == 0)
        defer { close(output[1]); close(input[0]) }
        let readEnd = try #require(Identity(output[0]))
        let transport = FDTransport(readFD: output[0], writeFD: input[1])
        #expect(Self.isOpen(readEnd))

        transport.close()
        try await eventually("the read end was closed by its reader") { !Self.isOpen(readEnd) }
        // The writer is still there, and what it writes now reaches nobody.
        _ = "late\n".withCString { write(output[1], $0, 5) }
        var lines = transport.lines().makeAsyncIterator()
        #expect(try await lines.next() == nil)
    }

    /// A runtime's line past the transport's limit arrives as a stand-in, and what
    /// follows it as ever.
    @Test func aPipeTransportCutsALongLine() async throws {
        var output: [Int32] = [-1, -1], input: [Int32] = [-1, -1]
        try #require(pipe(&output) == 0 && pipe(&input) == 0)
        defer { close(input[0]) }
        let transport = FDTransport(readFD: output[0], writeFD: input[1], maximumLine: 1024)
        let writer = output[1]
        let wrote = Task.detached {
            let long = Array(#"{"jsonrpc":"2.0","method":"session/update","params":""#.utf8)
                + [UInt8](repeating: UInt8(ascii: "x"), count: 200_000) + Array("\"}\n{\"next\":1}\n".utf8)
            long.withUnsafeBytes { all in
                var offset = 0
                while offset < all.count {
                    let n = write(writer, all.baseAddress! + offset, all.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
            close(writer)
        }
        var lines: [String] = []
        for try await line in transport.lines() { lines.append(line) }
        await wrote.value
        try #require(lines.count == 2)
        #expect(lines.first?.contains(LineSplitter.cutMethod) == true)
        #expect(lines.last == "{\"next\":1}")
        transport.close()
    }

    /// A runtime that stops reading its stdin cannot keep a write, or the close behind
    /// it, waiting for good: the write gives up once the transport is closed.
    @Test func closingAPipeTransportEndsAWriteNobodyReads() async throws {
        var output: [Int32] = [-1, -1], input: [Int32] = [-1, -1]
        try #require(pipe(&output) == 0 && pipe(&input) == 0)
        defer { close(output[1]); close(input[0]) }
        // As `RuntimeProcess` sets a runtime's stdin.
        _ = fcntl(input[1], F_SETFL, fcntl(input[1], F_GETFL) | O_NONBLOCK)
        let transport = FDTransport(readFD: output[0], writeFD: input[1])
        // Far more than a pipe holds, and nobody reads input[0].
        let big = String(repeating: "x", count: 4 << 20)
        let writing = Task.detached { () -> (any Error)? in
            do { try transport.write(line: big); return nil } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(200))
        let closed = Task.detached { transport.close() }
        await closed.value
        let failed = await writing.value
        guard case .closed? = failed as? JSONRPCTransportError else {
            Issue.record("the write gave up as closed: \(String(describing: failed))")
            return
        }
    }

    // MARK: Helpers

    final class ChildPid: @unchecked Sendable {
        private let lock = NSLock()
        private var said = ""
        func heard(_ text: String) { lock.withLock { said += text } }
        var pid: pid_t? {
            lock.withLock { said.split(separator: "\n").first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } }
        }
    }

    private struct Identity: Hashable {
        let device: dev_t, inode: ino_t
        init?(_ fd: Int32) {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// A pipe's read end, found by what it is, not by number: tests beside this one reuse
    /// numbers. Only read ends count, because on Linux both ends of a pipe are the one
    /// inode, and the write end this test keeps open is not the reader's.
    private static func isOpen(_ wanted: Identity) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.compactMap(Int32.init).contains { fd in
            Identity(fd) == wanted && fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY
        }
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("never happened: \(what)")
    }
}
