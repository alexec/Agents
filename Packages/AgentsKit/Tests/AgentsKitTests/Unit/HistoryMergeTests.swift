import Foundation
import Testing
@testable import AgentsKitCore

/// The charts add up every host's history in the viewer's own day (#1267): a server in
/// UTC and a Mac in PDT, as in the #1136 devbox walk.
@Suite("Histories from hosts in other time zones")
struct HistoryMergeTests {
    private let pacific: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func usd(_ amount: Decimal) -> UsageBucket { UsageBucket(cost: ["USD": amount], turns: 1) }

    /// The Mac: an hour of work on the morning of the 16th, its own day.
    private var mac: UsageHistory {
        UsageHistory(hours: ["2026-10-16T09": ["claude": usd(1)]], days: ["2026-10-16": ["claude": usd(1)]],
                     now: "2026-10-16T20", timeZone: "America/Los_Angeles")
    }

    /// The devbox: work at 02:41 UTC on the 17th, which was 19:41 on the 16th in PDT, and
    /// a day long before its oldest kept hour.
    private var devbox: UsageHistory {
        UsageHistory(hours: ["2026-10-17T02": ["codex": usd(2)]],
                     days: ["2026-10-17": ["codex": usd(2)], "2026-09-01": ["codex": usd(5)]],
                     now: "2026-10-17T03", timeZone: "UTC")
    }

    @Test("a server's hour goes in the viewer's hour and day, not its own")
    func aServersHourMoves() {
        let merged = UsageHistory.merged([mac, devbox], calendar: pacific)
        #expect(merged.hours["2026-10-16T19"]?["codex"]?.cost == ["USD": 2])
        #expect(merged.hours["2026-10-17T02"] == nil)
        #expect(merged.days["2026-10-16"]?["codex"]?.cost == ["USD": 2])
        #expect(merged.days["2026-10-16"]?["claude"]?.cost == ["USD": 1])
        #expect(merged.days["2026-10-17"] == nil)
        // Older than any hour kept: the day goes where its middle is here.
        #expect(merged.days["2026-09-01"]?["codex"]?.cost == ["USD": 5])
        // Now is the viewer's hour: the servers' hour, moved, and the latest of them.
        #expect(merged.now == "2026-10-16T20")
        #expect(merged.timeZone == "America/Los_Angeles")
    }

    @Test("the week chart counts the server's work on the 16th, as the issue saw it missing")
    func theWeekChartCountsIt() {
        let merged = UsageHistory.merged([mac, devbox], calendar: pacific)
        let week = UsageChart(merged, range: .week, metric: .cost, calendar: pacific)
        #expect(week.bars.last?.stamp == "2026-10-16")
        #expect(week.bars.last?.value == 3)
        #expect(week.total == 3)
        let today = UsageChart(merged, range: .day, metric: .cost, calendar: pacific)
        #expect(today.bars.first { $0.stamp == "2026-10-16T19" }?.value == 2)
    }

    @Test("once hours were dropped, the oldest day is its day total, and the rest are made from hours")
    func droppedHoursLeaveTheOldestDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var full = UsageHistory(now: "2026-10-17T23", timeZone: "UTC")
        var date = utc.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 0))!
        for _ in 0..<UsageHistory.hoursKept {
            full.add(usd(1), runtime: "codex", hour: UsageHistory.hourStamp(for: date, calendar: utc))
            date = utc.date(byAdding: .hour, value: 1, to: date)!
        }
        // Its oldest kept day held more than its hours say: two hours were dropped.
        full.days["2026-10-11"]?["codex"]?.add(usd(2))
        let merged = UsageHistory.merged([full], calendar: pacific)
        let total = merged.days.values.compactMap { $0["codex"]?.cost["USD"] }.reduce(0, +)
        #expect(total == Decimal(UsageHistory.hoursKept + 2))
        // The 11th's 26 went in its middle's day here; the 12th's first 7 hours went in the 11th.
        #expect(merged.days["2026-10-11"]?["codex"]?.cost == ["USD": 33])
        #expect(merged.days["2026-10-17"]?["codex"]?.cost == ["USD": 17])
    }

    @Test("a host in the viewer's zone, or one too old to say, is added as it is")
    func theSameZoneAddsAsItIs() {
        var old = mac
        old.timeZone = nil
        let merged = UsageHistory.merged([mac, old], calendar: pacific)
        #expect(merged.hours["2026-10-16T09"]?["claude"]?.cost == ["USD": 2])
        #expect(merged.days["2026-10-16"]?["claude"]?.turns == 2)
        #expect(merged.now == "2026-10-16T20")
    }

    @Test("time moves the same way, and the recap stays the home host's")
    func timeMovesToo() {
        let home = TimeHistory(hours: [:], days: [:], now: "2026-10-16T20", timeZone: "America/Los_Angeles",
                               recap: ["2026-10-16": DayRecap(peakAgents: 3)])
        let server = TimeHistory(hours: ["2026-10-17T02": ["codex": TimeBucket(agent: 600, turns: 1)]],
                                 days: ["2026-10-17": ["codex": TimeBucket(agent: 600, turns: 1)]],
                                 now: "2026-10-17T03", timeZone: "UTC",
                                 recap: ["2026-10-17": DayRecap(peakAgents: 9)])
        let merged = TimeHistory.merged([home, server], calendar: pacific)
        #expect(merged.days["2026-10-16"]?["codex"]?.agent == 600)
        #expect(merged.recap == home.recap)
        let week = TimeChart(merged, range: .week, calendar: pacific)
        #expect(week.bars.last?.stamp == "2026-10-16")
        #expect(week.bars.last?.total == 600)
    }
}
