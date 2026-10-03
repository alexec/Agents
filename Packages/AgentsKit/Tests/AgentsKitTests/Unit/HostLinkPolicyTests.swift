import Foundation
import Testing
@testable import AgentsKitCore

/// How Agents Host's window keeps its connection to this Mac's host, and how the daemon
/// says a line it would otherwise say every few seconds (#168).
@Suite("Agents Host's link and repeated log lines")
struct HostLinkPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func aRefusalIsNotALoss() {
        let refused = JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "agents/list is not open")
        #expect(HostLinkPolicy.failure(refused) == .refused)
        #expect(HostLinkPolicy.failure(JSONRPCError(code: -32603, message: "internal")) == .gone)
        #expect(HostLinkPolicy.failure(CancellationError()) == .gone)
    }

    @Test func itDialsAtOnceUntilSomethingFails() {
        let policy = HostLinkPolicy()
        #expect(policy.mayDial(at: start))
        #expect(policy.notBefore == nil)
    }

    /// 5 s, 10, 20, 40, … up to 5 minutes, each between half and all of that.
    @Test func failuresBackOffDoublingToFiveMinutes() {
        var policy = HostLinkPolicy()
        var waits: [TimeInterval] = []
        for _ in 0..<10 {
            policy.failed(at: start, jitter: 1)
            waits.append(policy.notBefore!.timeIntervalSince(start))
        }
        #expect(waits == [5, 10, 20, 40, 80, 160, 300, 300, 300, 300])
        #expect(!policy.mayDial(at: start.addingTimeInterval(299)))
        #expect(policy.mayDial(at: start.addingTimeInterval(300)))
    }

    @Test func jitterSpreadsTheWaitOverItsUpperHalf() {
        var low = HostLinkPolicy(), high = HostLinkPolicy(), wild = HostLinkPolicy()
        low.failed(at: start, jitter: 0)
        high.failed(at: start, jitter: 1)
        wild.failed(at: start, jitter: 7)
        #expect(low.notBefore == start.addingTimeInterval(2.5))
        #expect(high.notBefore == start.addingTimeInterval(5))
        #expect(wild.notBefore == high.notBefore, "jitter is clamped")
        var random = Set<TimeInterval>()
        for _ in 0..<20 {
            var policy = HostLinkPolicy()
            policy.failed(at: start)
            let wait = policy.notBefore!.timeIntervalSince(start)
            #expect(wait >= 2.5 && wait <= 5)
            random.insert(wait)
        }
        #expect(random.count > 1, "two windows that lost the host together don't come back in step")
    }

    @Test func connectingStartsTheWaitOver() {
        var policy = HostLinkPolicy()
        for _ in 0..<5 { policy.failed(at: start, jitter: 1) }
        policy.connected()
        #expect(policy.mayDial(at: start))
        policy.failed(at: start, jitter: 1)
        #expect(policy.notBefore == start.addingTimeInterval(5))
    }

    /// A host down all hour, looked at every 5 s: before, every tick dialled, 720 times;
    /// now 17 at the longest waits, and more only by jitter's shorter ones.
    @Test func anHourOfTicksAgainstADownHostDialsSeventeenTimes() {
        var policy = HostLinkPolicy()
        var dials = 0
        for t in stride(from: 0.0, to: 3600, by: 5) {
            let now = start.addingTimeInterval(t)
            guard policy.mayDial(at: now) else { continue }
            dials += 1
            policy.failed(at: now, jitter: 1)
        }
        #expect(dials == 17)
    }

    @Test func aRepeatedLineIsSaidOnceThenCounted() {
        var notice = RepeatedNotice(every: 3600)
        let line = "socket: pid 3928 connected as stranger"
        #expect(notice.note(line, at: start) == .first)
        var said = 0
        for t in stride(from: 5.0, to: 3600, by: 5) where notice.note(line, at: start.addingTimeInterval(t)) != nil {
            said += 1
        }
        #expect(said == 0, "nothing more within the hour")
        #expect(notice.note(line, at: start.addingTimeInterval(3600)) == .again(times: 720, since: start))
        #expect(notice.note(line, at: start.addingTimeInterval(3605)) == nil)
        #expect(notice.note("socket: pid 4000 connected as stranger", at: start.addingTimeInterval(3605)) == .first,
                "another pid is another line")
    }

    @Test func itRemembersABoundedNumberOfLines() {
        var notice = RepeatedNotice(every: 3600, keep: 4)
        for pid in 0..<10 {
            #expect(notice.note("pid \(pid)", at: start.addingTimeInterval(Double(pid))) == .first)
        }
        #expect(notice.note("pid 9", at: start.addingTimeInterval(20)) == nil, "the newest is still known")
        #expect(notice.note("pid 0", at: start.addingTimeInterval(21)) == .first, "the oldest was forgotten")
    }
}
