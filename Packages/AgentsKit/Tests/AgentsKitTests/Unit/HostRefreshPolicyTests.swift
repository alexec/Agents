import Foundation
import Testing
@testable import AgentsKitCore

/// When Agents Host's window starts processes to look, and when it doesn't (#134).
@Suite("Agents Host's refresh policy")
struct HostRefreshPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Ticks every 5 s for `seconds`, counting the full looks.
    private func fulls(_ policy: inout HostRefreshPolicy, from: Double, for seconds: Double,
                       visible: Bool = true, key: Bool = true, missing: Bool = false) -> Int {
        var count = 0
        for t in stride(from: from, to: from + seconds, by: 5) {
            let now = start.addingTimeInterval(t)
            if policy.look(at: now, visible: visible, key: key, lost: false, missing: missing) == .full {
                policy.lookedFully(at: now)
                count += 1
            }
        }
        return count
    }

    @Test func theFirstLookIsFullAndThenCheapForAMinute() {
        var policy = HostRefreshPolicy()
        #expect(policy.look(at: start, visible: true, key: true, lost: false, missing: false) == .full)
        policy.lookedFully(at: start)
        for t in stride(from: 5.0, to: 60, by: 5) {
            #expect(policy.look(at: start.addingTimeInterval(t), visible: true, key: true, lost: false, missing: false) == .cheap)
        }
        #expect(policy.look(at: start.addingTimeInterval(60), visible: true, key: true, lost: false, missing: false) == .full)
    }

    @Test func outOfSightItLooksAtNothingAndLooksFullyOnComingBack() {
        var policy = HostRefreshPolicy()
        _ = fulls(&policy, from: 0, for: 5)
        for t in stride(from: 5.0, to: 600, by: 5) {
            #expect(policy.look(at: start.addingTimeInterval(t), visible: false, key: false, lost: false, missing: false) == .none)
        }
        // Back in view after a second only: still a full look, since it may have missed anything.
        var quick = HostRefreshPolicy()
        _ = fulls(&quick, from: 0, for: 5)
        _ = quick.look(at: start.addingTimeInterval(5), visible: false, key: false, lost: false, missing: false)
        #expect(quick.look(at: start.addingTimeInterval(10), visible: true, key: true, lost: false, missing: false) == .full)
    }

    @Test func aProcessThatDiesIsLookedAtOnTheNextTick() {
        var policy = HostRefreshPolicy()
        _ = fulls(&policy, from: 0, for: 5)
        #expect(policy.look(at: start.addingTimeInterval(5), visible: true, key: true, lost: true, missing: false) == .full)
    }

    @Test func aWindowBehindLooksFullyEveryFiveMinutes() {
        var policy = HostRefreshPolicy()
        #expect(fulls(&policy, from: 0, for: 600, key: false) == 2)
    }

    @Test func aMissingJobBacksOff() {
        var policy = HostRefreshPolicy()
        // 0, then 5, 10, 20, 40 s after each, then every minute: 0, 5, 15, 35, 75, 135, 195.
        #expect(fulls(&policy, from: 0, for: 200, missing: true) == 7)
        // Running again, the next time it goes missing starts at 5 s.
        _ = fulls(&policy, from: 200, for: 60)
        #expect(policy.look(at: start.addingTimeInterval(265), visible: true, key: true, lost: true, missing: true) == .full)
        policy.lookedFully(at: start.addingTimeInterval(265))
        #expect(policy.look(at: start.addingTimeInterval(270), visible: true, key: true, lost: false, missing: true) == .full)
    }

    @Test func anOpenKeyWindowStartsAFewProcessesAnHourNotThousands() {
        var policy = HostRefreshPolicy()
        // A full look is four processes; before #134 every 5 s tick was one.
        #expect(fulls(&policy, from: 0, for: 3600) == 60)
    }
}
