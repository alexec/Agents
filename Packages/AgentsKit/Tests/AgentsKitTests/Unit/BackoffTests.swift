import Foundation
import Testing
@testable import AgentsKitCore

/// `holdOff` (#2235): a refusal (suspended, over a plan's limit) is not silence, and
/// trying again soon would only be refused again, so the next wait jumps straight to
/// the longest rather than climbing to it.
@Suite("Backing off")
struct BackoffTests {
    @Test func holdOffJumpsStraightToTheLongestWait() {
        let backoff = Backoff(first: .seconds(1), longest: .seconds(30))
        #expect(backoff.nextWait == .seconds(1))
        backoff.holdOff()
        #expect(backoff.nextWait == .seconds(30))
    }

    @Test func holdOffDuringATryIsStillTheNextWait() {
        let backoff = Backoff(first: .seconds(1), longest: .seconds(30))
        backoff.trying()
        backoff.holdOff()
        #expect(backoff.nextWait == .seconds(30))
    }
}
