import Foundation
import Testing
@testable import AgentsKitCore

/// Every client waits the same way before it dials again, and none of them storms (#172).
@Suite("Reconnect schedule")
struct ReconnectScheduleTests {
    // MARK: The schedule

    @Test func waitsDoubleFromTheFirstToTheLongest() {
        let schedule = ReconnectSchedule(first: .seconds(1), longest: .seconds(30))
        #expect((1...8).map { schedule.nominal(afterFailures: $0) } == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(schedule.nominal(afterFailures: 0) == .seconds(1))
        #expect(schedule.nominal(afterFailures: 10_000) == .seconds(30), "no overflow however long it has failed")
    }

    @Test func jitterTakesBetweenHalfAndAllOfTheWait() {
        #expect(ReconnectSchedule.jittered(.seconds(8), 0) == .seconds(4))
        #expect(ReconnectSchedule.jittered(.seconds(8), 1) == .seconds(8))
        #expect(ReconnectSchedule.jittered(.seconds(8), 0.5) == .seconds(6))
        #expect(ReconnectSchedule.jittered(.seconds(8), -3) == .seconds(4), "clamped")
        #expect(ReconnectSchedule.jittered(.seconds(8), 9) == .seconds(8), "clamped")
        var seen = Set<Duration>()
        for _ in 0..<200 {
            let wait = ReconnectSchedule.jittered(.seconds(8), ReconnectSchedule.randomJitter())
            #expect(wait >= .seconds(4) && wait <= .seconds(8))
            seen.insert(wait)
        }
        #expect(seen.count > 100, "twenty windows that lost a host together don't come back in step")
    }

    /// Agents Host's link (#168) waits by the same schedule.
    @Test func agentsHostsLinkIsTheSameSchedule() {
        let start = Date(timeIntervalSince1970: 0)
        for jitter in [0.0, 0.3, 1.0] {
            var policy = HostLinkPolicy()
            for failures in 1...8 {
                policy.failed(at: start, jitter: jitter)
                let expected = ReconnectSchedule.jittered(HostLinkPolicy.schedule.nominal(afterFailures: failures), jitter)
                #expect(abs(policy.notBefore!.timeIntervalSince(start) - Self.seconds(expected)) < 0.000_001)
            }
        }
    }

    // MARK: Backoff

    /// A recorded sleep that ends at once, on a clock the test moves.
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var slept: [Duration] = []
        var now = ContinuousClock.now
        func advance(_ by: Duration) { lock.withLock { now += by } }
        func sleep(_ duration: Duration) async throws { lock.withLock { slept.append(duration) } }
        var instant: ContinuousClock.Instant { lock.withLock { now } }
    }

    func backoff(_ clock: Clock, jitter: @escaping @Sendable () -> Double = ReconnectSchedule.randomJitter) -> Backoff {
        Backoff(first: .seconds(1), longest: .seconds(30), healthyAfter: .seconds(10),
                sleep: { try await clock.sleep($0) }, jitter: jitter, now: { clock.instant })
    }

    @Test func everyWaitIsSpreadOverItsUpperHalf() async {
        let clock = Clock()
        let backoff = backoff(clock)
        backoff.trying()
        for _ in 0..<8 { await backoff.wait() }
        let nominal: [Duration] = [1, 2, 4, 8, 16, 30, 30, 30].map { .seconds($0) }
        for (slept, whole) in zip(clock.slept, nominal) {
            #expect(slept >= whole / 2 && slept <= whole, "\(slept) for \(whole)")
        }
        #expect(Set(clock.slept).count > 1)
    }

    /// Up and straight down again, round after round: a host still starting, or a control
    /// plane that admits and drops. The waits keep growing.
    @Test func aConnectionDroppedAtOnceDoesNotStartTheWaitsAgain() async {
        let clock = Clock()
        let backoff = backoff(clock, jitter: { 1 })
        for _ in 0..<6 {
            backoff.trying()
            await backoff.wait()
            backoff.connected()
            clock.advance(.milliseconds(500))
        }
        #expect(clock.slept == [1, 2, 4, 8, 16, 30].map { Duration.seconds($0) })
    }

    @Test func aConnectionThatLastedStartsTheWaitsAgain() async {
        let clock = Clock()
        let backoff = backoff(clock, jitter: { 1 })
        backoff.trying()
        for _ in 0..<4 { await backoff.wait() }
        backoff.connected()
        clock.advance(.seconds(10))
        // Lost: whether the loop says `trying()` or goes straight to `wait()`.
        await backoff.wait()
        #expect(clock.slept.last == .seconds(1))
        backoff.connected()
        clock.advance(.seconds(60))
        backoff.trying()
        #expect(backoff.nextWait == .seconds(1))
    }

    // MARK: Connecting

    /// Something to connect to that never answers, and counts every try.
    final class Down: DaemonLink, @unchecked Sendable {
        let lock = NSLock()
        var tries = 0
        var starts = 0
        let starting: Bool
        init(starting: Bool) { self.starting = starting }
        func transport() async throws -> any LineTransport {
            lock.withLock { tries += 1 }
            throw DaemonClient.ConnectError.couldNotConnect
        }
        func start() async throws { lock.withLock { starts += 1 } }
        var startsSomething: Bool { starting }
    }

    /// The window's client through a control plane with its host down: one try, and the
    /// window's backoff decides the next, not a dial every 100 ms for 8 s (#172).
    @Test func aLinkWithNothingToStartIsTriedOnce() async {
        let link = Down(starting: false)
        let client = DaemonClient(link: link)
        let started = ContinuousClock.now
        await #expect(throws: DaemonClient.ConnectError.self) { try await client.connect() }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(link.lock.withLock { (link.tries, link.starts) } == (1, 0))
    }

    /// A server's daemon, started over ssh: waited for, but backing off, not every 100 ms.
    @Test func aLinkThatStartsSomethingIsWaitedForWithBackoff() async {
        let link = Down(starting: true)
        let client = DaemonClient(link: link)
        await #expect(throws: DaemonClient.ConnectError.self) { try await client.connect(timeout: .seconds(3)) }
        let (tries, starts) = link.lock.withLock { (link.tries, link.starts) }
        #expect(starts == 1)
        // 100 ms doubling to 2 s, each half to all: at most 1 + 7 in 3 s, against 31 before;
        // and at least one after the start (a loaded machine may manage no more).
        #expect(tries >= 2 && tries <= 9, "\(tries) tries in 3 s")
    }

    // MARK: The relay's notices

    func item(_ device: UUID, _ need: NeedID, envelope: Bool, at seconds: TimeInterval) -> MailboxItem {
        MailboxItem(needID: need, device: device, envelope: nil, alert: envelope,
                    postedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func aNoticeThatDidNotPostIsKeptOncePerNeed() {
        var pending = PendingPosts()
        let phone = UUID(), need = NeedID.permission(UUID())
        pending.keep(item(phone, need, envelope: true, at: 1))
        pending.keep(item(phone, need, envelope: false, at: 2))
        #expect(pending.count == 1)
        #expect(pending.waiting.first?.postedAt == Date(timeIntervalSince1970: 2), "the withdrawal replaced the need")
        // An older word that failed late does not put back what was withdrawn.
        pending.keep(item(phone, need, envelope: true, at: 1))
        #expect(pending.waiting.first?.postedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func aLaterPostThatWorkedClearsWhatWasWaiting() {
        var pending = PendingPosts()
        let phone = UUID(), need = NeedID.permission(UUID())
        pending.keep(item(phone, need, envelope: true, at: 1))
        pending.posted(item(phone, need, envelope: false, at: 3))
        #expect(pending.isEmpty)
        // But a post older than what is waiting leaves it to be posted.
        pending.keep(item(phone, need, envelope: false, at: 5))
        pending.posted(item(phone, need, envelope: true, at: 4))
        #expect(pending.count == 1)
    }

    @Test func aRetrySnapshotIsReplacedByAWithdrawalBeforeItIsPosted() {
        var pending = PendingPosts()
        let phone = UUID(), need = NeedID.permission(UUID())
        let offered = item(phone, need, envelope: true, at: 1)
        pending.keep(offered)
        pending.keep(item(phone, need, envelope: false, at: 2))
        #expect(pending.current(offered)?.envelope == nil)
        #expect(pending.current(item(phone, need, envelope: false, at: 2))?.envelope == nil)
    }

    @Test func whatIsKeptIsBounded() {
        var pending = PendingPosts(limit: 3)
        let phone = UUID()
        let needs = (0..<5).map { _ in NeedID.permission(UUID()) }
        var dropped: [MailboxItem] = []
        for (index, need) in needs.enumerated() {
            if let gone = pending.keep(item(phone, need, envelope: true, at: Double(index))) { dropped.append(gone) }
        }
        #expect(pending.count == 3)
        #expect(dropped.map(\.needID) == Array(needs.prefix(2)), "the oldest go first")
        #expect(pending.waiting.map(\.needID) == Array(needs.suffix(3)))
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18
    }
}
