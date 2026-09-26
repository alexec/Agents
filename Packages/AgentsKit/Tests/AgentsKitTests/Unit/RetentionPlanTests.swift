import Foundation
import Testing
@testable import AgentsKitCore

/// The retention rules (051, research R5), with the clock, the sizes and the holds as
/// plain values.
@Suite("Retention plan")
struct RetentionPlanTests {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let mb = 1_000_000

    private func agent(_ daysAgo: Double, size: Int = 1_000_000, idle: Double? = nil,
                       id: UUID = UUID()) -> RetentionPlan.Candidate {
        RetentionPlan.Candidate(id: id,
                                archivedAt: now.addingTimeInterval(-daysAgo * day),
                                lastActivityAt: now.addingTimeInterval(-(idle ?? daysAgo) * day),
                                sizeOnDisk: size)
    }

    private func decide(_ archived: [RetentionPlan.Candidate], holds: [UUID: Hold] = [:],
                        _ settings: RetentionSettings = RetentionSettings(),
                        at sane: Date? = nil) -> RetentionPlan.Decision {
        RetentionPlan.decide(archived: archived, holds: holds, settings: settings, saneNow: sane ?? now)
    }

    // MARK: Off

    @Test func foreverWithNoLimitRetiresNothingAndSaysNothing() {
        let old = agent(400, size: 50_000 * mb)
        let decision = decide([old], RetentionSettings(keepFor: .forever, cap: .none))
        #expect(decision.retire.isEmpty)
        #expect(decision.notes.isEmpty)
        #expect(decision.overCap == nil)
    }

    // MARK: Age

    @Test func thirtyDaysRetiresAndTwentyNineDoesNot() {
        let gone = agent(30), kept = agent(29)
        let decision = decide([gone, kept])
        #expect(decision.retire == [.init(id: gone.id, because: .age)])
    }

    @Test func theTimeIsThePersonsChoice() {
        let eight = agent(8)
        #expect(decide([eight], RetentionSettings(keepFor: .days7)).retire.map(\.id) == [eight.id])
        #expect(decide([eight], RetentionSettings(keepFor: .days14)).retire.isEmpty)
        #expect(decide([agent(400)], RetentionSettings(keepFor: .forever, cap: .gb10)).retire.isEmpty)
    }

    @Test func anArchiveTimeInTheFutureCountsAsNow() {
        let future = agent(-40)
        #expect(decide([future], RetentionSettings(keepFor: .days7, cap: .none)).retire.isEmpty)
    }

    // MARK: Cap

    @Test func theCapRetiresTheOldestFirstUntilUnderIt() {
        let a = agent(10, size: 400 * mb), b = agent(9, size: 400 * mb)
        let c = agent(8, size: 400 * mb), d = agent(2, size: 400 * mb)
        let decision = decide([d, c, a, b], RetentionSettings(keepFor: .days30, cap: .gb1))
        #expect(decision.retire == [.init(id: a.id, because: .cap), .init(id: b.id, because: .cap)])
        #expect(decision.overCap == nil)
    }

    @Test func theCapBreaksTiesByTheLongestIdle() {
        let busy = agent(5, size: 600 * mb, idle: 5)
        let idle = agent(5, size: 600 * mb, idle: 40)
        let decision = decide([busy, idle], RetentionSettings(keepFor: .days30, cap: .gb1))
        #expect(decision.retire.map(\.id) == [idle.id])
    }

    @Test func ageGoesFirstAndTheCapCountsWhatIsLeft() {
        let old = agent(31, size: 900 * mb), mid = agent(10, size: 900 * mb)
        let decision = decide([old, mid], RetentionSettings(keepFor: .days30, cap: .gb1))
        #expect(decision.retire == [.init(id: old.id, because: .age)])
    }

    // MARK: The first day

    @Test func nothingGoesOnItsFirstDayByAgeCapOrClock() {
        let fresh = agent(0.5, size: 5_000 * mb)
        let decision = decide([fresh], RetentionSettings(keepFor: .days7, cap: .gb1))
        #expect(decision.retire.isEmpty)
        #expect(decision.overCap?.holding[.firstDay] == 1)
        #expect(decision.overCap?.bytesOver == 4_000 * mb)
    }

    // MARK: Holds

    @Test func aHeldAgentIsNeverPickedAndSaysWhy() {
        let held = agent(40), free = agent(35)
        let decision = decide([held, free], holds: [held.id: .worktreeHasWork])
        #expect(decision.retire.map(\.id) == [free.id])
        #expect(decision.notes[held.id] == .held(.worktreeHasWork))
    }

    @Test func overTheCapWithOnlyHeldAgentsLeftSaysSo() {
        let held = agent(20, size: 1_500 * mb), fresh = agent(0.2, size: 800 * mb)
        let decision = decide([held, fresh], holds: [held.id: .workflowRunning],
                              RetentionSettings(keepFor: .days30, cap: .gb1))
        #expect(decision.retire.isEmpty)
        #expect(decision.overCap == OverCap(bytesOver: 1_300 * mb,
                                            holding: [.workflowRunning: 1, .firstDay: 1]))
        #expect(decision.notes[held.id] == .held(.workflowRunning))
    }

    // MARK: Notes

    @Test func aRetirementWithinAWeekIsNotedAndOneFurtherOffIsNot() {
        let soon = agent(27), later = agent(20)
        let decision = decide([soon, later], RetentionSettings(keepFor: .days30, cap: .none))
        #expect(decision.notes[soon.id] == .at(soon.archivedAt.addingTimeInterval(30 * day)))
        #expect(decision.notes[later.id] == nil)
    }

    @Test func theNextUnderTheCapIsNotedOnceAndOnlyWhenCloseToIt() {
        let a = agent(10, size: 300 * mb), b = agent(9, size: 300 * mb), c = agent(8, size: 300 * mb)
        let close = decide([a, b, c], RetentionSettings(keepFor: .days90, cap: .gb1))
        #expect(close.retire.isEmpty)
        #expect(close.notes == [a.id: .nextUnderCap])

        let far = decide([a], RetentionSettings(keepFor: .days90, cap: .gb10))
        #expect(far.notes.isEmpty)
        let none = decide([a, b, c], RetentionSettings(keepFor: .days90, cap: .none))
        #expect(none.notes.isEmpty)
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
