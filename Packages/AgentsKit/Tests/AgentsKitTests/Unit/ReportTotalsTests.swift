@testable import AgentsKitCore
import Foundation
import Testing

/// Cost ▸ Reports (#1811): rows added up by person, project, machine or runtime, largest
/// first, as the web page's `model/reports.ts` does.
struct ReportTotalsTests {
    private func row(person: String = "bea", personName: String = "Bea", host: String = "H1",
                     hostName: String = "Bea's Mac", project: String = "shop", runtime: String = "claude",
                     usd: Decimal? = nil, input: Int = 0, cachedRead: Int = 0, turns: Int = 0,
                     working: Double = 0) -> DaemonAPI.ReportRow {
        DaemonAPI.ReportRow(at: "2026-10-21", person: person, personName: personName, host: host, hostName: hostName,
                            project: project, runtime: runtime, cost: usd.map { ["USD": $0] } ?? [:],
                            inputTokens: input, cachedReadTokens: cachedRead, turns: turns, workingSeconds: working)
    }

    @Test func rowsAddUpByEachDimensionLargestFirst() throws {
        let rows = [
            row(usd: 1, input: 100, turns: 1, working: 60),
            row(person: "", personName: "", host: "H9", hostName: "Old box", project: "", usd: 3, turns: 2),
            row(person: "al", personName: "Al", host: "H2", hostName: "Al's Mac", runtime: "codex", usd: 2, cachedRead: 999),
            row(usd: 0.5, input: 60),
        ]
        let people = ReportTotals(rows, by: .person)
        try #require(people.groups.map(\.name) == [ReportWords.removedOwner, "Al", "Bea"])
        #expect(people.total.cost["USD"] == 6.5)
        #expect(people.groups[2].tokens == 160)
        #expect(people.groups[1].tokens == 0, "cache reads are not fresh tokens")
        #expect(ReportTotals(rows, by: .project).groups.map(\.name) == ["shop", ReportWords.noProject])
        #expect(ReportTotals(rows, by: .machine).groups.map(\.name) == ["Old box", "Al's Mac", "Bea's Mac"])
        let runtimes = ReportTotals(rows, by: .runtime) { $0 == "claude" ? "Claude" : "Codex" }
        #expect(runtimes.groups.map(\.name) == ["Claude", "Codex"])
        #expect(people.share(of: people.groups[0]) == 1)
        #expect(people.share(of: people.groups[2]) == 0.5)
    }

    @Test func nothingPricedIsSharedOutByTokens() throws {
        let totals = ReportTotals([row(input: 10), row(project: "b", input: 40)], by: .project)
        #expect(totals.currencies.isEmpty)
        try #require(totals.groups.count == 2)
        #expect(totals.share(of: totals.groups[1]) == 0.25)
        #expect(ReportWords.line(totals.groups[0]) == "40 tokens · 0 turns · 0s working")
    }

    @Test func anExportIsNamedByItsRangeAndDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!
        #expect(ReportWords.exportName(.week, .csv, day, calendar: calendar) == "report-week-2026-10-21.csv")
    }
}
