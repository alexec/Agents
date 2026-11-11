import Foundation
import Testing
@testable import AgentsKitCore

/// What a folder's Archived Sessions and Archived Workflows pages show (#4448): loading,
/// a silent host and a capped page are not an empty archive (#664), and the rows go by day.
@Suite("The Archived pages")
struct ArchivedPageTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    /// Monday 10 November 2025, 14:00 in London.
    private var now: Date { calendar.date(from: DateComponents(year: 2025, month: 11, day: 10, hour: 14))! }

    private func archived(_ hoursAgo: Double) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp/f"), state: .archived)
        agent.archivedAt = now.addingTimeInterval(-hoursAgo * 3600)
        return agent
    }

    @Test func anEmptyListIsLoadingUntilTheHostAnswers() {
        #expect(ArchivedPage.state(held: 0, filtering: false, answered: nil, hostOffline: false) == .loading)
        #expect(ArchivedPage.state(held: 0, filtering: false, answered: true, hostOffline: false) == .empty)
        #expect(ArchivedPage.state(held: 0, filtering: true, answered: true, hostOffline: false) == .noMatch)
        #expect(ArchivedPage.state(held: 3, filtering: false, answered: nil, hostOffline: false) == .rows(stale: false))
    }

    @Test func aFailedAskOrAnOfflineHostIsNotAnEmptyArchive() {
        #expect(ArchivedPage.state(held: 0, filtering: false, answered: false, hostOffline: false) == .hostSilent)
        #expect(ArchivedPage.state(held: 0, filtering: false, answered: nil, hostOffline: true) == .hostSilent)
        #expect(ArchivedPage.state(held: 4, filtering: false, answered: true, hostOffline: true) == .rows(stale: true))
    }

    @Test func theFooterSaysHowManyThereAre() {
        #expect(ArchivedPage.footer(shown: 50, total: 128) == "50 of 128 archived sessions")
        #expect(ArchivedPage.hasMore(shown: 50, total: 128))
        #expect(ArchivedPage.footer(shown: 128, total: 128) == "128 archived sessions")
        #expect(!ArchivedPage.hasMore(shown: 128, total: 128))
        #expect(ArchivedPage.footer(shown: 1, total: 1) == "1 archived session")
        #expect(ArchivedPage.workflowCount(4) == "4 archived workflows")
        #expect(ArchivedPage.nextLimit(held: 50) == 100)
    }

    @Test func rowsGoByTheDayTheyWereArchivedInTheHostsOrder() {
        let agents = [archived(2), archived(5), archived(20), archived(24 * 3 + 2)]
        let days = ArchivedPage.days(agents, now: now, calendar: calendar)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Friday 7 November"])
        #expect(days.map(\.agents.count) == [2, 1, 1])
        #expect(days[0].agents.map(\.id) == [agents[0].id, agents[1].id])
        #expect(days.map(\.isToday) == [true, false, false])
    }

    @Test func anotherYearsDayHasItsYear() {
        let then = calendar.date(from: DateComponents(year: 2024, month: 12, day: 24, hour: 9))!
        #expect(ArchivedPage.dayTitle(then, now: now, calendar: calendar) == "Tuesday 24 December 2024")
    }

    @Test func aRowsTimeIsAgoTodayAndTheClockOnAnotherDay() {
        #expect(ArchivedPage.time(now.addingTimeInterval(-2 * 3600), now: now, calendar: calendar) == "2 h ago")
        #expect(ArchivedPage.time(now.addingTimeInterval(-12 * 60), now: now, calendar: calendar) == "12 min ago")
        #expect(ArchivedPage.time(now.addingTimeInterval(-10), now: now, calendar: calendar) == "now")
        #expect(ArchivedPage.time(now.addingTimeInterval(-(19 * 3600 + 20 * 60)), now: now, calendar: calendar) == "18:40")
    }
}
