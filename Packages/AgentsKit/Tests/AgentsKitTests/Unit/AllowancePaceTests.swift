import Foundation
import Testing
@testable import AgentsKitCore

/// A plan's week against an even pace, and its past weeks (#3438).
@Suite("A week against an even pace")
struct AllowancePaceTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func week(_ used: Double, resetsIn days: Double, window: String = "seven_day") -> AllowanceReading {
        AllowanceReading(window: window, used: used, resetsAt: now.addingTimeInterval(days * 86400), at: now)
    }

    private func state(_ weeks: [AllowanceReading], reading: AllowanceReading? = nil) -> AllowanceState {
        AllowanceState(credentialKey: "claude:sign-in", entryID: UUID(), since: now, reading: reading, weeks: weeks)
    }

    @Test func aWeekUsedFasterThanAnEvenPaceSaysSo() {
        // 28% left with 3 of 7 days to go: an even pace leaves 43%.
        // 72% used in 4 days runs out in about 1.6 days: on course to run out too (#5000).
        let current = week(0.72, resetsIn: 3)
        let when = PoolWords.runsOut(now.addingTimeInterval(0.28 * 4 / 0.72 * 86400), now: now)
        #expect(PoolWords.pace(state([current], reading: current), now: now)
                == "3 days to go · used faster than an even pace (43% left) · runs out \(when) at this pace")
        #expect(AllowancePace(state([current]), now: now)?.verdict == .faster)
    }

    @Test func slowerAndEvenToo() {
        #expect(PoolWords.pace(state([week(0.2, resetsIn: 3)]), now: now)
                == "80% left this week · 3 days to go · used slower than an even pace (43% left)")
        #expect(PoolWords.pace(state([week(0.53, resetsIn: 3.4)]), now: now)
                == "47% left this week · 3 days to go · on an even pace")
        #expect(PoolWords.pace(state([week(0.9, resetsIn: 0.2)]), now: now)?.contains("5 hours to go") == true)
    }

    @Test func theReadingLineKeepsTheAmountWhenItIsTheSameWeek() {
        let current = week(0.5, resetsIn: 3)
        let fiveHour = AllowanceReading(window: "five_hour", used: 0.1, resetsAt: now.addingTimeInterval(3600), at: now)
        #expect(PoolWords.pace(state([current], reading: current), now: now)?.hasPrefix("3 days to go") == true)
        #expect(PoolWords.pace(state([current], reading: fiveHour), now: now)?.hasPrefix("50% left this week") == true)
    }

    @Test func pastWeeksAreTheirFinalShares() {
        let weeks = [week(0.62, resetsIn: -14), week(0.71, resetsIn: -7), week(0.9, resetsIn: -0.5),
                     week(0.3, resetsIn: 5), week(0.4, resetsIn: 5, window: "seven_day_opus")]
        let pace = AllowancePace(state(weeks), now: now)
        #expect(pace?.past.compactMap(\.used) == [0.62, 0.71, 0.9])
        #expect(pace?.current?.used == 0.3)
        #expect(PoolWords.pastWeeks(state(weeks), now: now) == "Past weeks: 62%, 71%, 90% used")
    }

    @Test func noWeeksSayNothing() {
        #expect(AllowancePace(state([]), now: now) == nil)
        #expect(PoolWords.pace(state([week(0.6, resetsIn: -1)]), now: now) == nil)
        #expect(PoolWords.pastWeeks(state([week(0.6, resetsIn: 2)]), now: now) == nil)
    }

    // On course to run out before it resets (#5000).

    @Test func dayTwoWithNearlyHalfUsedRunsOutOnDayFour() throws {
        // 2 of 7 days gone, 45% used: 158% at the reset, all used about 2.4 days from now.
        let pace = try #require(AllowancePace(state([week(0.45, resetsIn: 5)]), now: now))
        let runsOutAt = try #require(pace.runsOutAt)
        #expect(abs(runsOutAt.timeIntervalSince(now) - 0.55 * 2 / 0.45 * 86400) < 1)
        #expect(pace.onCourseToRunOut)
        #expect(PoolWords.pace(state([week(0.45, resetsIn: 5)]), now: now)
                == "55% left this week · 5 days to go · used faster than an even pace (71% left) · runs out \(PoolWords.runsOut(runsOutAt, now: now)) at this pace")
    }

    @Test func anEvenOrSlowPaceDoesNotRunOut() {
        #expect(AllowancePace(state([week(0.25, resetsIn: 5)]), now: now)?.onCourseToRunOut == false)
        #expect(PoolWords.pace(state([week(0.25, resetsIn: 5)]), now: now)?.contains("runs out") == false)
    }

    @Test func runningOutJustBeforeTheResetDoesNotWarn() throws {
        // 4 days gone, 58% used: all used about 2.4 hours before the reset, inside the 12-hour margin.
        let pace = try #require(AllowancePace(state([week(0.58, resetsIn: 3)]), now: now))
        #expect(try #require(pace.runsOutAt) < now.addingTimeInterval(3 * 86400))
        #expect(!pace.onCourseToRunOut)
    }

    @Test func theFirstDayAndALittleUsedDoNotWarn() {
        #expect(AllowancePace(state([week(0.3, resetsIn: 6.5)]), now: now)?.onCourseToRunOut == false)
        #expect(AllowancePace(state([week(0.08, resetsIn: 6.5 - 1)]), now: now)?.onCourseToRunOut == false)
    }

    @Test func underADayAwaySaysTheTime() {
        let soon = now.addingTimeInterval(5 * 3600)
        #expect(PoolWords.runsOut(soon, now: now) == soon.formatted(date: .omitted, time: .shortened))
        let later = now.addingTimeInterval(3 * 86400)
        #expect(PoolWords.runsOut(later, now: now) == later.formatted(.dateTime.weekday(.abbreviated)))
    }
}
