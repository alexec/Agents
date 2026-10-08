import Foundation
import Testing
@testable import AgentsKitCore

/// The age rule (051, #398), with the clock and the holds as plain values.
@Suite("Retention plan")
struct RetentionPlanTests {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ daysAgo: Double, idle: Double? = nil) -> RetentionPlan.Candidate {
        RetentionPlan.Candidate(id: UUID(),
                                archivedAt: now.addingTimeInterval(-daysAgo * day),
                                lastActivityAt: now.addingTimeInterval(-(idle ?? daysAgo) * day),
                                sizeOnDisk: 1_000_000)
    }

    private func decide(_ archived: [RetentionPlan.Candidate], holds: [UUID: Hold] = [:],
                        _ settings: RetentionSettings = RetentionSettings()) -> [UUID] {
        RetentionPlan.decide(archived: archived, holds: holds, settings: settings, saneNow: now)
    }

    @Test func neverDeletesNothing() {
        #expect(decide([agent(400)], RetentionSettings(keepFor: .forever)).isEmpty)
    }

    @Test func thirtyDaysDeletesAndTwentyNineDoesNot() {
        let gone = agent(30), kept = agent(29)
        #expect(decide([gone, kept]) == [gone.id])
    }

    @Test func theTimeIsThePersonsChoice() {
        let eight = agent(8)
        #expect(decide([eight], RetentionSettings(keepFor: .days7)) == [eight.id])
        #expect(decide([eight], RetentionSettings(keepFor: .days14)).isEmpty)
    }

    @Test func anArchiveTimeInTheFutureCountsAsNow() {
        #expect(decide([agent(-40)], RetentionSettings(keepFor: .days7)).isEmpty)
    }

    @Test func theOldestGoFirstAndTiesByTheLongestIdle() {
        let busy = agent(40, idle: 40), idle = agent(40, idle: 60), older = agent(50)
        #expect(decide([busy, idle, older]) == [older.id, idle.id, busy.id])
    }

    @Test func aHeldAgentIsNeverPicked() {
        let held = agent(40), free = agent(35)
        #expect(decide([held, free], holds: [held.id: .worktreeHasWork]) == [free.id])
    }
}

/// The clock the rules are given (051, research R5): real time, unless the wall clock
/// jumped, when only the time that really passed counts for a day.
@Suite("Retention clock")
struct RetentionClockTests {
    let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theFirstEverCheckTrustsTheClock() {
        var clock = RetentionClock()
        #expect(clock.tick(now: start, uptime: 100) == start)
    }

    @Test func anOrdinaryHourIsAnHour() {
        var clock = RetentionClock()
        _ = clock.tick(now: start, uptime: 100)
        let later = start.addingTimeInterval(3_600)
        #expect(clock.tick(now: later, uptime: 3_700) == later)
    }

    @Test func aJumpForwardCountsOnlyRealTimeForADay() {
        var clock = RetentionClock()
        _ = clock.tick(now: start, uptime: 0)
        // The wall clock says forty days passed in an hour.
        let jumped = start.addingTimeInterval(40 * day)
        #expect(clock.tick(now: jumped, uptime: 3_600) == start.addingTimeInterval(3_600))
        // Twelve hours on, still counting real time.
        #expect(clock.tick(now: jumped.addingTimeInterval(12 * 3_600), uptime: 13 * 3_600)
                == start.addingTimeInterval(13 * 3_600))
        // A day of real time since the jump: the clock is believed again.
        let believed = jumped.addingTimeInterval(25 * 3_600)
        #expect(clock.tick(now: believed, uptime: 26 * 3_600) == believed)
    }

    @Test func aStartLongAfterTheLastCheckWaitsADayBeforeTrustingIt() {
        var before = RetentionClock()
        _ = before.tick(now: start, uptime: 0)
        // Only what is written down survives a restart.
        let data = try! JSONEncoder().encode(before)
        var clock = try! JSONDecoder().decode(RetentionClock.self, from: data)

        let wound = start.addingTimeInterval(40 * day)
        #expect(clock.tick(now: wound, uptime: 5) == start)
        let aDayOn = wound.addingTimeInterval(day + 60)
        #expect(clock.tick(now: aDayOn, uptime: day + 65) == aDayOn)
    }

    @Test func aStartSoonAfterTheLastCheckTrustsTheClock() {
        var before = RetentionClock()
        _ = before.tick(now: start, uptime: 0)
        var clock = try! JSONDecoder().decode(RetentionClock.self, from: JSONEncoder().encode(before))
        let overnight = start.addingTimeInterval(10 * 3_600)
        #expect(clock.tick(now: overnight, uptime: 5) == overnight)
    }

    @Test func aClockSetBackIsSimplyNow() {
        var clock = RetentionClock()
        _ = clock.tick(now: start, uptime: 0)
        let back = start.addingTimeInterval(-5 * day)
        #expect(clock.tick(now: back, uptime: 60) == back)
    }
}
