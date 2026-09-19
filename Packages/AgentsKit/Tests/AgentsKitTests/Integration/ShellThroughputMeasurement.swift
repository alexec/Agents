import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Not a test. A measurement, run by hand, of the whole path a shell's output takes:
/// a real pty, the real daemon, a real Unix socket, a real client decoding at the far
/// end. Disabled, because it takes a second and asserts nothing; lift the trait and
/// run it when the numbers need checking again.
///
/// What it said the day the gathering went in, for five megabytes of short lines:
///
///                          before      after
///     notifications         ~5,100        ~37
///     client decode          48 ms    1.6 ms
///     time to last byte   0.6-1.4 s    0.56 s
///     time to first byte      1 ms      1 ms
///
/// The last row is the one that says the gathering is free: waiting eight milliseconds
/// before handing over does not make the first thing you typed arrive any later.
@Suite("Shell throughput, measured", .disabled("run by hand"))
struct ShellThroughputMeasurement {
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var notifications = 0
        private(set) var bytes = 0
        private(set) var decodeNanoseconds: UInt64 = 0
        private(set) var firstAt: DispatchTime?
        private(set) var lastAt: DispatchTime?

        func add(_ params: JSONValue?) {
            let started = DispatchTime.now()
            guard let params, let note = DaemonAPI.ShellOutputNotification(params: params) else { return }
            let spent = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            lock.lock()
            notifications += 1
            bytes += note.bytes.count
            decodeNanoseconds += spent
            if firstAt == nil { firstAt = started }
            lastAt = DispatchTime.now()
            lock.unlock()
        }

        /// Forget the shell starting up, so only the command being measured counts.
        func reset() {
            lock.lock()
            notifications = 0; bytes = 0; decodeNanoseconds = 0; firstAt = nil; lastAt = nil
            lock.unlock()
        }

        /// Something arrived, and then half a second of quiet.
        var settled: Bool {
            lock.lock(); defer { lock.unlock() }
            guard let lastAt, bytes > 1_000_000 else { return false }
            return DispatchTime.now().uptimeNanoseconds - lastAt.uptimeNanoseconds > 500_000_000
        }
    }

    @Test func throughShoreToShore() async throws {
        // Short, because a Unix socket path is 104 bytes and the temporary directory
        // plus a UUID is already past it.
        let root = URL(fileURLWithPath: "/tmp/agt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)

        let daemon = try Daemon(locations: locations,
                                discovery: .findsEverything,
                                launcher: FakeLauncher(script: FakeACPAgent.Script()))
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }

        // A real client, over the real socket, the way a window connects.
        let client = DaemonClient(link: SocketLink(locations: locations))
        try await client.connect(startIfNeeded: false)

        let tally = Tally()
        let notifications = client.notifications()
        let listening = Task {
            for await notification in notifications
            where notification.method == DaemonAPI.Notification.shellOutput {
                tally.add(notification.params)
            }
        }
        defer { listening.cancel() }

        let agentID = try await client.call(DaemonAPI.Method.agentsStart,
                                            DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "hello"),
                                            returning: UUID.self)
        _ = try await client.call(DaemonAPI.Method.shellAttach,
                                  DaemonAPI.ShellAttachRequest(agentID: agentID, rows: 40, cols: 120),
                                  returning: DaemonAPI.ShellAttachResponse.self)
        try await Task.sleep(for: .milliseconds(500))

        // Five megabytes, the way a build prints it: many short lines.
        let line = String(repeating: "a", count: 100)
        let command = "for i in $(seq 1 50000); do echo '\(line)'; done\n"
        tally.reset()
        let startedAt = DispatchTime.now()
        try await client.call(DaemonAPI.Method.shellInput,
                              DaemonAPI.ShellInputRequest(agentID: agentID, bytes: Data(command.utf8)))

        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !tally.settled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1e9

        print("""

        ── shell output, end to end ──────────────────────────────
        bytes            \(tally.bytes)
        notifications    \(tally.notifications)
        per notification \(tally.bytes / max(tally.notifications, 1)) bytes
        client decode    \(String(format: "%.1f", Double(tally.decodeNanoseconds) / 1e6)) ms total
        first byte at    \(String(format: "%.3f", Double((tally.firstAt?.uptimeNanoseconds ?? 0) &- startedAt.uptimeNanoseconds) / 1e9)) s
        last byte at     \(String(format: "%.3f", Double((tally.lastAt?.uptimeNanoseconds ?? 0) &- startedAt.uptimeNanoseconds) / 1e9)) s
        wall clock       \(String(format: "%.2f", elapsed)) s  (includes the half second of quiet)
        ──────────────────────────────────────────────────────────

        """)
    }
}
