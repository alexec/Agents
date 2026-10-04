import Foundation
import Testing
@testable import AgentsKitCore

/// The Remote's reconnect loop (#208): it never waits on itself, every wait on it is
/// bounded, and a stopped one stays stopped. The attempt and both clocks are the test's,
/// so none of it needs a device or a Mac.
@MainActor
@Suite("Reconnect loop", .timeLimit(.minutes(1)))
struct ReconnectLoopTests {
    typealias FakeClock = ReconnectTriggerTests.FakeClock

    /// Attempts the test answers one at a time.
    @MainActor
    final class Attempts {
        private var waiting: [CheckedContinuation<ReconnectLoop.Outcome, Never>] = []
        private(set) var count = 0
        /// Run inside each attempt before it waits for its answer.
        var during: (@MainActor () async -> Void)?

        func attempt() async -> ReconnectLoop.Outcome {
            count += 1
            await during?()
            return await withCheckedContinuation { waiting.append($0) }
        }

        func answer(_ outcome: ReconnectLoop.Outcome) {
            waiting.removeFirst().resume(returning: outcome)
        }

        func waitForAttempt(_ number: Int) async {
            while count < number || waiting.isEmpty { await Task.yield() }
        }
    }

    /// A backoff whose waits end only when its clock lets them.
    private func backoff(_ clock: FakeClock) -> Backoff {
        Backoff(first: .seconds(1), longest: .seconds(30), sleep: { try await clock.sleep($0) }, jitter: { 1 })
    }

    private func loop(_ attempts: Attempts, backoff: FakeClock = FakeClock(),
                      patience: FakeClock = FakeClock()) -> ReconnectLoop {
        ReconnectLoop(backoff: self.backoff(backoff), sleep: { try await patience.sleep($0) }) {
            await attempts.attempt()
        }
    }

    // MARK: 1. It never waits on itself

    /// The hang: an attempt catches up, the catch-up sends, the send loses the link and
    /// waits for the reconnect, which is the loop it is running in. Now it hears false
    /// at once, from the attempt itself and from a task the attempt started, and the loop
    /// goes on to connect.
    @Test func aWaitFromInsideTheLoopsOwnAttemptIsFalseAtOnce() async {
        let attempts = Attempts()
        var heardInside: [Bool] = []
        let reconnect = loop(attempts)
        attempts.during = { [weak reconnect] in
            guard let reconnect else { return }
            // As `sendOnce` from `settleUnsettledStart`, directly…
            heardInside.append(await reconnect.waitForHost(within: .seconds(20)))
            // …and from the catch-up's own task, which `catchUp()` starts.
            let child = Task { await reconnect.waitForHost(within: .seconds(20)) }
            heardInside.append(await child.value)
        }
        let running = Task { await reconnect.run() }
        await attempts.waitForAttempt(1)
        #expect(heardInside == [false, false])
        attempts.answer(.connected)
        await running.value
        #expect(!reconnect.isRunning)
        // A later loop is not mistaken for that one: a send outside it waits as it should.
        attempts.during = nil
        let send = Task { await reconnect.waitForHost(within: .seconds(20)) }
        await attempts.waitForAttempt(2)
        attempts.answer(.connected)
        #expect(await send.value)
    }

    /// A send from outside waits for the loop it did not start, and hears it connected.
    @Test func aSendOutsideTheLoopHearsItConnect() async {
        let attempts = Attempts()
        let backoffClock = FakeClock()
        let reconnect = loop(attempts, backoff: backoffClock)
        let running = Task { await reconnect.run() }
        await attempts.waitForAttempt(1)
        let send = Task { await reconnect.waitForHost(within: .seconds(20)) }
        attempts.answer(.failed)
        await backoffClock.waitForNap(1)
        backoffClock.elapse()
        await attempts.waitForAttempt(2)
        attempts.answer(.connected)
        #expect(await send.value)
        await running.value
    }

    /// A second `run` while one loop is going is not a second loop, and does not wait.
    @Test func runWhileRunningReturnsAtOnce() async {
        let attempts = Attempts()
        let reconnect = loop(attempts)
        let first = Task { await reconnect.run() }
        await attempts.waitForAttempt(1)
        await reconnect.run()
        #expect(attempts.count == 1)
        attempts.answer(.connected)
        await first.value
    }

    // MARK: 2. Every wait is bounded

    /// A Mac that stays away: the send hears false once its patience is up, and the loop
    /// carries on looking without it.
    @Test func aSendWaitsNoLongerThanItsPatience() async {
        let attempts = Attempts()
        let patience = FakeClock()
        let reconnect = loop(attempts, patience: patience)
        let send = Task { await reconnect.waitForHost(within: .seconds(20)) }
        await attempts.waitForAttempt(1)
        await patience.waitForNap(1)
        #expect(patience.waits == [.seconds(20)])
        patience.elapse()
        #expect(await send.value == false)
        #expect(reconnect.isRunning)
        reconnect.stop()
        attempts.answer(.failed)
    }

    /// A send with no loop running starts one, rather than waiting on nothing.
    @Test func aSendWithNoLoopStartsOne() async {
        let attempts = Attempts()
        let reconnect = loop(attempts)
        #expect(!reconnect.isRunning)
        let send = Task { await reconnect.waitForHost(within: .seconds(20)) }
        await attempts.waitForAttempt(1)
        #expect(reconnect.isRunning)
        attempts.answer(.connected)
        #expect(await send.value)
    }

    /// Forgotten by the control plane: the loop ends, and a waiting send hears false.
    @Test func forgottenEndsTheLoopAndTheWaits() async {
        let attempts = Attempts()
        let reconnect = loop(attempts)
        let send = Task { await reconnect.waitForHost(within: .seconds(20)) }
        await attempts.waitForAttempt(1)
        attempts.answer(.forgotten)
        #expect(await send.value == false)
        #expect(!reconnect.isRunning)
    }

    // MARK: 3. Stopped is for good

    /// A new pairing stops the old model: its wait in progress hears false, the attempt
    /// in flight ends the loop when it returns, and nothing starts it again.
    @Test func stopEndsTheLoopForGood() async {
        let attempts = Attempts()
        let backoffClock = FakeClock()
        let reconnect = loop(attempts, backoff: backoffClock)
        let running = Task { await reconnect.run() }
        await attempts.waitForAttempt(1)
        let send = Task { await reconnect.waitForHost(within: .seconds(20)) }
        await Task.yield()
        reconnect.stop()
        #expect(await send.value == false)
        #expect(reconnect.isStopped)
        // The attempt in flight comes back failed: no backoff, no next attempt.
        attempts.answer(.failed)
        await running.value
        #expect(backoffClock.waits.isEmpty)
        // As the listener's end, a network change or a send would: nothing dials.
        await reconnect.run()
        #expect(await reconnect.waitForHost(within: .seconds(20)) == false)
        for _ in 0..<20 { await Task.yield() }
        #expect(attempts.count == 1)
        #expect(!reconnect.isRunning)
    }

    /// Stopped while waiting out a backoff: the wait ends, and no attempt follows it.
    @Test func stopDuringTheBackoffEndsIt() async {
        let attempts = Attempts()
        let backoffClock = FakeClock()
        let reconnect = loop(attempts, backoff: backoffClock)
        let running = Task { await reconnect.run() }
        await attempts.waitForAttempt(1)
        attempts.answer(.failed)
        await backoffClock.waitForNap(1)
        reconnect.stop()
        await running.value
        #expect(attempts.count == 1)
    }
}
