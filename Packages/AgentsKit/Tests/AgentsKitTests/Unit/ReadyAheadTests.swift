import Foundation
import Synchronization
import Testing
@testable import AgentsKitCore

/// Voice mode's echo cancellation, set up ahead of the press without stopping the window
/// (P20261029-1): it took about a second on the main thread as the first prompt bar drew.
@Suite("Set-up ahead does not hold the main thread")
@MainActor
struct ReadyAheadTests {
    struct Refused: Error {}

    /// The work runs on a thread of its own, and `start` returns before it ends.
    @Test func theWorkRunsOffTheMainThread() async {
        let onMain = Mutex<Bool?>(nil)
        let ahead = ReadyAhead {
            onMain.withLock { $0 = Thread.isMainThread }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let started = ContinuousClock.now
        ahead.start()
        let held = ContinuousClock.now - started
        #expect(held < .milliseconds(100), "start held the main thread \(held)")
        #expect(await ahead.wait())
        #expect(onMain.withLock { $0 } == false)
        #expect(ahead.state == .ready)
    }

    /// A press while it runs waits for that run rather than starting a second one.
    @Test func aRunningSetUpIsWaitedFor() async {
        let runs = Mutex(0)
        let ahead = ReadyAhead {
            runs.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        ahead.start()
        ahead.start()
        #expect(await ahead.wait())
        ahead.start()
        #expect(await ahead.wait())
        #expect(runs.withLock { $0 } == 1)
    }

    /// A failure is not tried again by every new prompt bar: only after `retry`.
    @Test func aFailureWaitsForRetry() async {
        let runs = Mutex(0)
        let ahead = ReadyAhead {
            runs.withLock { $0 += 1 }
            throw Refused()
        }
        ahead.start()
        #expect(await ahead.wait() == false)
        #expect(ahead.state == .failed)
        #expect(ahead.error is Refused)
        ahead.start()
        #expect(await ahead.wait() == false)
        #expect(runs.withLock { $0 } == 1)
        ahead.retry()
        ahead.start()
        #expect(await ahead.wait() == false)
        #expect(runs.withLock { $0 } == 2)
    }

    /// Waiting starts nothing.
    @Test func waitingStartsNothing() async {
        let runs = Mutex(0)
        let ahead = ReadyAhead { runs.withLock { $0 += 1 } }
        #expect(await ahead.wait() == false)
        #expect(ahead.state == .idle)
        #expect(runs.withLock { $0 } == 0)
    }
}
