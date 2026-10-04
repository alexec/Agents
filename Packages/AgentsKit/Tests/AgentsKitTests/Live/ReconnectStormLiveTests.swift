import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore
import ControlDial

/// Twenty windows on one control plane while its host restarts (#172): how many times
/// they dial, and how long until all of them are back.
///
///     AGENTS_STORM_CODES='agents-control:2:c:… agents-control:2:c:…' \
///     AGENTS_STORM_READY=/tmp/run-storm/ready swift test --filter ReconnectStormLiveTests
///
/// Each code pairs one window. Every window connects as the window does: a client for
/// this Mac's host through the control plane, which goes back for another connection with
/// the window's own backoff when it loses the one it has, and the control plane's own
/// client, which hears `control/hostChanged`. Once all twenty are connected it writes the
/// ready file; restart the host then (by its root's daemon.lock pid). From the first loss
/// it counts, for `AGENTS_STORM_SECONDS` (60 by default), every connection attempt and
/// every `control/hostChanged`, and says when the last window was back.
@Suite("Reconnect storm on a scratch control plane",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_STORM_CODES"] != nil),
       .serialized, .timeLimit(.minutes(10)))
struct ReconnectStormLiveTests {
    static let dial: ControlCodeUse.Dial = { url, pin in try await WebSocketLink.connect(url, pin: pin) }

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [Date] = []
        private var notes: [Date] = []
        private var lost: [Int: Date] = [:]
        private var back: [Int: Date] = [:]

        func attempt() { lock.withLock { attempts.append(Date()) } }
        func hostChanged() { lock.withLock { notes.append(Date()) } }
        func lost(_ window: Int) { lock.withLock { if lost[window] == nil { lost[window] = Date() } } }
        func back(_ window: Int) { lock.withLock { if lost[window] != nil, back[window] == nil { back[window] = Date() } } }

        var firstLoss: Date? { lock.withLock { lost.values.min() } }
        var lostCount: Int { lock.withLock { lost.count } }
        var backCount: Int { lock.withLock { back.count } }
        var lastBack: Date? { lock.withLock { back.values.max() } }
        func attempts(from start: Date, for seconds: Double) -> Int {
            lock.withLock { attempts.filter { $0 >= start && $0.timeIntervalSince(start) < seconds }.count }
        }
        func notes(from start: Date, for seconds: Double) -> Int {
            lock.withLock { notes.filter { $0 >= start && $0.timeIntervalSince(start) < seconds }.count }
        }
    }

    /// Counts each `transport()`: one connection attempt, as the control plane sees it.
    struct Counted: DaemonLink {
        let inner: any DaemonLink
        let tally: Tally
        func transport() async throws -> any LineTransport {
            tally.attempt()
            return try await inner.transport()
        }
        func start() async throws { try await inner.start() }
    }

    @Test func twentyWindowsThroughAHostRestart() async throws {
        let environment = ProcessInfo.processInfo.environment
        let codes = (environment["AGENTS_STORM_CODES"] ?? "").split(separator: " ").compactMap { ControlCode(text: String($0)) }
        try #require(!codes.isEmpty, "AGENTS_STORM_CODES holds no codes")
        let seconds = environment["AGENTS_STORM_SECONDS"].flatMap(Double.init) ?? 60
        let tally = Tally()

        var windows: [Task<Void, Never>] = []
        for (index, code) in codes.enumerated() {
            let key = ControlAgreement.generate()
            let membership = try await ControlCodeUse.pairClient(code, privateKey: key.privateKey, id: UUID(),
                                                                 name: "storm \(index)", kind: .mac, dial: Self.dial)
            let dial = try ControlCodeUse.clientDial(membership, privateKey: key.privateKey, kind: "mac", dial: Self.dial)
            let link = ControlLink(dial: dial)
            windows.append(Task { await Self.window(index, link: link, tally: tally) })
        }
        print("storm: \(codes.count) windows paired")

        // All connected before the restart.
        let connected = Date()
        while await !Self.everyoneUp(windows.count) {
            try await Task.sleep(for: .milliseconds(200))
            if Date().timeIntervalSince(connected) > 60 { Issue.record("not every window connected"); return }
        }
        if let ready = environment["AGENTS_STORM_READY"] { try Data("ready\n".utf8).write(to: URL(fileURLWithPath: ready)) }
        print("storm: all \(codes.count) connected; restart the host now")

        while tally.firstLoss == nil { try await Task.sleep(for: .milliseconds(100)) }
        let start = tally.firstLoss!
        try await Task.sleep(until: .now + .seconds(seconds), clock: .continuous)
        let attempts = tally.attempts(from: start, for: seconds)
        let notes = tally.notes(from: start, for: seconds)
        let allBack = tally.backCount == codes.count ? tally.lastBack.map { $0.timeIntervalSince(start) } : nil
        print("STORM windows=\(codes.count) lost=\(tally.lostCount) back=\(tally.backCount) "
              + "attempts=\(attempts) in \(Int(seconds)) s, hostChanged=\(notes), "
              + "all back after \(allBack.map { String(format: "%.1f s", $0) } ?? "never")")
        for window in windows { window.cancel() }
    }

    static let up = Up()
    final class Up: @unchecked Sendable {
        let lock = NSLock()
        var windows: Set<Int> = []
    }
    static func everyoneUp(_ count: Int) async -> Bool { up.lock.withLock { up.windows.count == count } }

    /// One window: `AppModel.connect` and `reconnect`, and its control-plane watch.
    static func window(_ index: Int, link: ControlLink, tally: Tally) async {
        let mac = DaemonClient(link: Counted(inner: link.link(for: .mac), tally: tally))
        let backoff = Backoff()
        let control = DaemonClient(link: link.controlLink)
        let watching = Task {
            while !Task.isCancelled {
                if (try? await control.connect(startIfNeeded: false, timeout: .seconds(3))) != nil {
                    for await note in control.notifications() where note.method == DaemonAPI.Notification.controlHostChanged {
                        tally.hostChanged()
                        // `AppModel.hostCameOnline`.
                        if await !mac.isConnected, note.params?["state"]?.stringValue == "online" { backoff.nudge() }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { watching.cancel() }
        var first = true
        while !Task.isCancelled {
            if first {
                first = false
                try? await mac.connect()
            }
            if await !mac.isConnected {
                backoff.trying()
                while !Task.isCancelled {
                    await backoff.wait()
                    if (try? await mac.connect()) != nil { break }
                }
                backoff.connected()
            }
            tally.back(index)
            _ = up.lock.withLock { up.windows.insert(index) }
            for await _ in mac.notifications() {}
            guard !Task.isCancelled else { return }
            tally.lost(index)
        }
    }
}
