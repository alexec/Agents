import Foundation
import Testing
@testable import AgentsKit

/// A runtime that dies by itself gives everything back (#163).
///
/// The daemon only forgets a runtime that exits on its own; it never `end`s it. So
/// nothing called `cleanUp`, the stderr handler stayed on a pipe at its end and was
/// called again and again with nothing (about a core per dead runtime, ~950 % after
/// ten), and seven descriptors stayed open per death.
///
/// The descriptors are found by what they are, not by number: the pipe ends this side
/// held, by device and inode. Tests running beside this one open and close whatever
/// they like, and a number can be handed to one of them the moment it is let go.
@Suite("A runtime that dies")
struct RuntimeExitTests {
    /// A runtime that says something on stderr and exits, mid-nothing.
    private static let dies = (URL(filePath: "/bin/sh"), ["-c", "echo going >&2; exit 3"])

    @Test func itsStandardErrorHandlerGoesAtTheEndOfThePipe() async throws {
        let exited = AsyncStream<Int32>.makeStream()
        let process = try RuntimeProcess(executable: Self.dies.0, arguments: Self.dies.1,
                                         cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
                                         environment: [:],
                                         onExit: { exited.continuation.yield($0) })
        for await _ in exited.stream { break }
        // Nobody calls cleanUp: that was the whole of the bug.
        try await eventually("the stderr handler took itself away at the end of the pipe") {
            !process.watchesStandardError
        }
        process.cleanUp()
    }

    @Test func aSessionWhoseRuntimeDiesGivesBackEveryDescriptor() async throws {
        let session = try ACPSession.launch(executable: Self.dies.0, arguments: Self.dies.1,
                                            cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
                                            environment: [:])
        let process = try #require(await session.runtimeProcess)
        let held = Self.identities(of: process.heldDescriptors)
        // Five descriptors, three pipe ends: the transport's two are duplicates.
        #expect(held.count == 3, "this side's three pipe ends were open at launch")

        var status: Int32?
        for await event in session.eventStream() {
            if case .processExited(let code) = event { status = code }
        }
        #expect(status == 3)

        // Nobody ends the session, as the daemon does not for a runtime that died.
        try await eventually("every pipe end was closed") { Self.open(held) == 0 }
        #expect(!process.watchesStandardError)
    }

    /// Ten in a row, the review's measurement: nothing accumulates.
    @Test func tenDeathsLeaveNothingBehind() async throws {
        var all: Set<Identity> = []
        for _ in 0..<10 {
            let session = try ACPSession.launch(executable: Self.dies.0, arguments: Self.dies.1,
                                                cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
                                                environment: [:])
            let process = try #require(await session.runtimeProcess)
            all.formUnion(Self.identities(of: process.heldDescriptors))
            for await _ in session.eventStream() {}
        }
        try await eventually("all ten runtimes' pipes were closed") { Self.open(all) == 0 }
    }

    // MARK: Helpers

    private struct Identity: Hashable { let device: dev_t; let inode: ino_t }

    private static func identity(_ fd: Int32) -> Identity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private static func identities(of fds: [Int32]) -> Set<Identity> {
        Set(fds.compactMap(identity))
    }

    /// How many of this process's descriptors are one of `wanted`.
    private static func open(_ wanted: Set<Identity>) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.compactMap(Int32.init).filter { fd in identity(fd).map(wanted.contains) ?? false }.count
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
