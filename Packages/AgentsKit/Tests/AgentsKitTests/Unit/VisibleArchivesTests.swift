import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Archives that stay in the list")
struct VisibleArchivesTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// 15:00 UTC on 26 September 2026.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 15))!
    }

    private func archived(_ title: String, at: Date?) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp/work"),
                          title: title, state: .archived, endedReason: .endTurn)
        agent.archivedAt = at
        return agent
    }

    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func yesterdaysArchivesStayHidden() {
        let yesterday = archived("yesterday", at: at(day: 25, hour: 23, minute: 59))
        let split = VisibleArchives.split([yesterday], now: now, calendar: calendar)
        #expect(split.kept.isEmpty)
        #expect(split.hidden.map(\.title) == ["yesterday"])
    }

    @Test func anArchiveWithNoTimeStaysHidden() {
        let undated = archived("undated", at: nil)
        let split = VisibleArchives.split([undated], now: now, calendar: calendar)
        #expect(split.kept.isEmpty)
        #expect(split.hidden.map(\.id) == [undated.id])
    }

    @Test func theThreeLatestFromTodayStayAndTheRestDoNot() {
        let early = archived("early", at: at(day: 26, hour: 1))
        let mid = archived("mid", at: at(day: 26, hour: 9))
        let late = archived("late", at: at(day: 26, hour: 14))
        let fourth = archived("fourth", at: at(day: 26, hour: 8))
        let fifth = archived("fifth", at: at(day: 26, hour: 12))
        let yesterday = archived("yesterday", at: at(day: 25, hour: 18))
        let justAfterMidnight = archived("midnight", at: at(day: 26, hour: 0, minute: 1))

        // Given out of recency order, so the result is the sort and not the input.
        let split = VisibleArchives.split(
            [yesterday, early, fifth, mid, fourth, late, justAfterMidnight],
            now: now, calendar: calendar)

        #expect(split.kept.map(\.title) == ["late", "fifth", "mid"])
        #expect(split.hidden.map(\.title) == ["yesterday", "early", "fourth", "midnight"])
    }

    @Test func fewerThanThreeTodayAllStay() {
        let one = archived("one", at: at(day: 26, hour: 11))
        let two = archived("two", at: at(day: 26, hour: 10))
        let split = VisibleArchives.split([one, two], now: now, calendar: calendar)
        #expect(split.kept.map(\.title) == ["one", "two"])
        #expect(split.hidden.isEmpty)
    }
}
