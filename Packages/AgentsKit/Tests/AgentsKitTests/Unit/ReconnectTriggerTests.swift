import Foundation
import Testing
@testable import AgentsKitCore

/// Going back at once on a wake or a network change, not when the backoff says (#82).
@Suite("Reconnect triggers")
struct ReconnectTriggerTests {
    /// A clock that never passes by itself. Each wait is recorded, and lasts until the
    /// test lets it end or something cancels it.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var naps: [Duration] = []
        private var endings: [CheckedContinuation<Void, Never>] = []
        private(set) var now = Duration.zero

        var waits: [Duration] { lock.withLock { naps } }

        func sleep(_ duration: Duration) async throws {
            lock.withLock { naps.append(duration) }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let cancelled = lock.withLock { () -> Bool in
                        if Task.isCancelled { return true }
                        endings.append(continuation)
                        return false
                    }
                    if cancelled { continuation.resume() }
                }
            } onCancel: {
                self.endAll()
            }
            try Task.checkCancellation()
            lock.withLock { now += duration }
        }

        /// Let the wait in progress run its whole length.
        func elapse() { endAll() }

        private func endAll() {
            let ending = lock.withLock { defer { endings = [] }; return endings }
            for continuation in ending { continuation.resume() }
        }

        /// Until a wait has started.
        func waitForNap(_ count: Int) async {
            while lock.withLock({ naps.count < count || endings.isEmpty }) { await Task.yield() }
        }
    }

    func backoff(_ clock: FakeClock) -> Backoff {
        Backoff(first: .seconds(1), longest: .seconds(30)) { try await clock.sleep($0) }
    }

    @Test func waitsDoubleUpToTheLongest() async {
        let clock = FakeClock()
        let backoff = backoff(clock)
        backoff.trying()
        for count in 1...7 {
            let wait = Task { await backoff.wait() }
            await clock.waitForNap(count)
            clock.elapse()
            await wait.value
        }
        #expect(clock.waits == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(clock.now == .seconds(91))
    }

    @Test func aNudgeEndsTheWaitAtOnceAndStartsAgainFromASecond() async {
        let clock = FakeClock()
        let backoff = backoff(clock)
        backoff.trying()
        for count in 1...5 {
            let wait = Task { await backoff.wait() }
            await clock.waitForNap(count)
            clock.elapse()
            await wait.value
        }
        #expect(backoff.nextWait == .seconds(30))
        // Thirty seconds to go, and the Mac wakes.
        let wait = Task { await backoff.wait() }
        await clock.waitForNap(6)
        #expect(backoff.nudge() == .cutShort)
        await wait.value
        // None of the half minute passed: the try is now.
        #expect(clock.now == .seconds(31))
        #expect(backoff.nextWait == .seconds(1))
    }

    @Test func aNudgeDuringATryDoesNotStackASecondTry() async {
        let clock = FakeClock()
        let backoff = backoff(clock)
        backoff.trying()
        // A network change while a dial is in flight: nothing starts beside it.
        #expect(backoff.nudge() == .afterThisTry)
        // That dial failed: the wait after it is skipped, once.
        await backoff.wait()
        #expect(clock.waits.isEmpty)
        let next = Task { await backoff.wait() }
        await clock.waitForNap(1)
        #expect(clock.waits == [.seconds(1)])
        next.cancel()
        await next.value
    }

    @Test func aNudgeWithNothingGoingOnIsIdle() async {
        let clock = FakeClock()
        let backoff = backoff(clock)
        #expect(backoff.nudge() == .idle)
        // Connected: a nudge kept from a try does not skip the first wait of a later loss.
        backoff.trying()
        _ = backoff.nudge()
        backoff.settle()
        #expect(backoff.nudge() == .idle)
        backoff.trying()
        let wait = Task { await backoff.wait() }
        await clock.waitForNap(1)
        #expect(clock.waits == [.seconds(1)])
        wait.cancel()
        await wait.value
    }

    @Test func settlingStartsTheNextLossFromASecond() async {
        let clock = FakeClock()
        let backoff = backoff(clock)
        backoff.trying()
        for count in 1...3 {
            let wait = Task { await backoff.wait() }
            await clock.waitForNap(count)
            clock.elapse()
            await wait.value
        }
        #expect(backoff.nextWait == .seconds(8))
        backoff.settle()
        #expect(backoff.nextWait == .seconds(1))
    }

    // MARK: Paths

    let wifi = PathChange.Path(satisfied: true, route: ["en0", "192.168.1.1:0"])
    let cellular = PathChange.Path(satisfied: true, route: ["pdp_ip0"])
    let none = PathChange.Path(satisfied: false, route: [])

    @Test func theFirstReportIsHowThingsWere() {
        var change = PathChange()
        let up = change.retries(after: wifi)
        var other = PathChange()
        let down = other.retries(after: none)
        #expect(!up)
        #expect(!down)
    }

    @Test func aPathBecomingUsableRetries() {
        var change = PathChange()
        let verdicts = [wifi, none, none, wifi, wifi].map { change.retries(after: $0) }
        #expect(verdicts == [false, false, false, true, false])
    }

    @Test func aUsablePathGoingAnotherWayRetries() {
        var change = PathChange()
        let otherWifi = PathChange.Path(satisfied: true, route: ["en0", "10.0.0.1:0"])
        let verdicts = [wifi, cellular, cellular, otherWifi].map { change.retries(after: $0) }
        #expect(verdicts == [false, true, false, true])
    }

    @Test func triggersSayWhyAndFireForPathsAndWakes() async {
        final class Heard: @unchecked Sendable {
            let lock = NSLock()
            var reasons: [ReconnectTriggers.Reason] = []
        }
        let heard = Heard()
        let center = NotificationCenter()
        let wake = Notification.Name("test.wake")
        let triggers = ReconnectTriggers(wakes: [.init(center: center, name: wake)], watchesPaths: false) { reason in
            heard.lock.withLock { heard.reasons.append(reason) }
        }
        triggers.pathChanged(wifi)
        triggers.pathChanged(none)
        triggers.pathChanged(cellular)
        triggers.start()
        center.post(name: wake, object: nil)
        // Observers are on the main queue.
        await MainActor.run {}
        triggers.stop()
        center.post(name: wake, object: nil)
        await MainActor.run {}
        #expect(heard.lock.withLock { heard.reasons } == [.network, .wake])
    }
}
