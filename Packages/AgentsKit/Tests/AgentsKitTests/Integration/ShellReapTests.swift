#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import AgentsKit

/// A shell that is ended is gone, not a zombie kept for the helper's whole life (#442).
///
/// A zombie still answers `kill(pid, 0)`; only a reaped process is `ESRCH`.
@Suite("An ended shell is reaped", .timeLimit(.minutes(1)))
struct ShellReapTests {
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsShellReapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func isGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    @Test func aClosedTabsShellIsReaped() async throws {
        let host = ShellHost()
        let id = UUID()
        _ = try host.attach(agentID: id, folder: try folder(), rows: 24, cols: 80)
        let pid = try #require(host.session(for: id)?.pid)
        #expect(kill(pid, 0) == 0)

        host.close(agentID: id, shell: 0)
        #expect(await isGone(pid))
    }

    @Test func aShellLetGoWhenIdleIsReaped() async throws {
        let host = ShellHost()
        let id = UUID()
        _ = try host.attach(agentID: id, folder: try folder(), rows: 24, cols: 80)
        let session = try #require(host.session(for: id))
        let pid = try #require(session.pid)

        session.release(reason: "idle")
        #expect(await isGone(pid))
    }

    @Test func aShellEndedForShutDownIsReaped() async throws {
        let host = ShellHost()
        let id = UUID()
        _ = try host.attach(agentID: id, folder: try folder(), rows: 24, cols: 80)
        let pid = try #require(host.session(for: id)?.pid)

        host.shutDown()
        #expect(await isGone(pid))
    }
}
