@testable import AgentsKitCore
import Foundation
import Testing

/// Cost ▸ Reports (#1811): rows added up by person, project, folder, machine or runtime, largest
/// first, as the web page's `model/reports.ts` does.
struct ReportTotalsTests {
    private func row(person: String = "bea", personName: String = "Bea", host: String = "H1",
                     hostName: String = "Bea's Mac", folder: String = "shop", runtime: String = "claude",
                     usd: Decimal? = nil, input: Int = 0, cachedRead: Int = 0, turns: Int = 0,
                     working: Double = 0) -> DaemonAPI.ReportRow {
        DaemonAPI.ReportRow(at: "2026-10-21", person: person, personName: personName, host: host, hostName: hostName,
                            folder: folder, runtime: runtime, cost: usd.map { ["USD": $0] } ?? [:],
                            inputTokens: input, cachedReadTokens: cachedRead, turns: turns, workingSeconds: working)
    }

    @Test func rowsAddUpByEachDimensionLargestFirst() throws {
        let rows = [
            row(usd: 1, input: 100, turns: 1, working: 60),
            row(person: "", personName: "", host: "H9", hostName: "Old box", folder: "", usd: 3, turns: 2),
            row(person: "al", personName: "Al", host: "H2", hostName: "Al's Mac", runtime: "codex", usd: 2, cachedRead: 999),
            row(usd: 0.5, input: 60),
        ]
        let people = ReportTotals(rows, by: .person)
        try #require(people.groups.map(\.name) == [ReportWords.removedOwner, "Al", "Bea"])
        #expect(people.total.cost["USD"] == 6.5)
        #expect(people.groups[2].tokens == 160)
        #expect(people.groups[1].tokens == 0, "cache reads are not fresh tokens")
        #expect(ReportTotals(rows, by: .folder).groups.map(\.name) == ["shop", ReportWords.noFolder])
        #expect(ReportTotals(rows, by: .machine).groups.map(\.name) == ["Old box", "Al's Mac", "Bea's Mac"])
        let runtimes = ReportTotals(rows, by: .runtime) { $0 == "claude" ? "Claude" : "Codex" }
        #expect(runtimes.groups.map(\.name) == ["Claude", "Codex"])
        #expect(people.share(of: people.groups[0]) == 1)
        #expect(people.share(of: people.groups[2]) == 0.5)
    }

    /// #2670: the same project on two machines adds up as one; a folder in no project is
    /// "No project".
    @Test func rowsAddUpByProjectAcrossMachines() throws {
        var mine = row(usd: 1), theirs = row(host: "H2", hostName: "Box", folder: "agents", usd: 2)
        let loose = row(folder: "tmp", usd: 4)
        (mine.project, mine.projectName) = ("p-agents", "Agents")
        (theirs.project, theirs.projectName) = ("p-agents", "Agents")
        let projects = ReportTotals([mine, theirs, loose], by: .project)
        try #require(projects.groups.map(\.name) == [ReportWords.noProject, "Agents"])
        #expect(projects.groups[1].cost["USD"] == 3)
        #expect(ReportTotals.Dimension.spend.contains(.project))
    }

    @Test func nothingPricedIsSharedOutByTokens() throws {
        let totals = ReportTotals([row(input: 10), row(folder: "b", input: 40)], by: .folder)
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

    /// Reports ▸ Spend is named only to an admin or a group's lead (#2200).
    @Test func theNoteNamesReportsSpendOnlyToSomeoneItOffersMore() {
        #expect(ReportWords.meNote(seesMore: true).contains("Reports ▸ Spend"))
        #expect(ReportWords.meNote(seesMore: false) == "Your machines. An admin or a group’s lead sees more.")
    }

    /// VoiceOver says a range's name, not its letter, and each page says what its bars measure (#2440).
    @Test func eachRangeHasASpokenNameAndEachPageABarCaption() {
        #expect(DaemonAPI.ReportRange.allCases.map(ReportWords.spoken) == ["Day", "Week", "Month", "3 months"])
        let captions = ReportOutcomes.Page.allCases.map(ReportOutcomeWords.barCaption) + [ReportWords.barCaption]
        #expect(Set(captions).count == captions.count)
        #expect(captions.allSatisfy { $0.hasPrefix("Each bar is") })
    }
}
