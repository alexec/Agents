@testable import AgentsKitCore
import Foundation
import Testing

/// Outcomes, Time, Runtimes, Adoption and Workflows at the Me scope (#2183), added up and said
/// as the web page's `model/reports.ts` does.
struct ReportOutcomesTests {
    private func row(at: String = "2026-10-21", person: String = "bea", runtime: String = "claude",
                     workflow: String? = nil, usd: Decimal? = nil, turns: Int = 1, working: Double = 0,
                     waiting: Double = 0, counts: DaemonAPI.ReportCounts? = nil) -> DaemonAPI.ReportRow {
        DaemonAPI.ReportRow(at: at, person: person, personName: person.capitalized, host: "H1", hostName: "Mac",
                            folder: "shop", runtime: runtime, workflow: workflow, cost: usd.map { ["USD": $0] } ?? [:],
                            turns: turns, workingSeconds: working, waitingSeconds: waiting, counts: counts)
    }

    @Test func outcomesPutTheMostMergedFirstAndSayTheCostOfEach() throws {
        let rows = [
            row(usd: 10, counts: .init(sessions: 3, prsOpened: 2, prsMerged: 1, mergeSeconds: 3600)),
            row(person: "al", usd: 6, counts: .init(sessions: 2, prsOpened: 3, prsMerged: 3, prsReverted: 1, mergeSeconds: 900)),
            row(person: "cy", usd: 1),
        ]
        let outcomes = ReportOutcomes(rows, page: .outcomes, by: .person)
        try #require(outcomes.groups.map(\.name) == ["Al", "Bea", "Cy"])
        #expect(outcomes.total.merged == 4)
        #expect(outcomes.bar(outcomes.groups[0]) == 1)
        #expect(outcomes.line(outcomes.groups[0]) == "3 merged of 3 opened · 1 revert · $2.00 a merged pull request · 5m from start to merge · 2 sessions")
        #expect(outcomes.line(outcomes.groups[2]) == "0 merged of 0 opened · 0 sessions")
        #expect(!outcomes.isEmpty)
        #expect(ReportOutcomes([row()], page: .outcomes, by: .person).isEmpty, "a machine before #2019 sends no counts")
    }

    @Test func timePutsTheMostWaitingFirstWithTheMiddleWait() throws {
        let rows = [
            row(working: 300, waiting: 100, counts: .init(waits: 3, waitBuckets: [1, 0, 2, 0, 0, 0])),
            row(person: "al", working: 100, waiting: 100, counts: .init(waits: 1, waitBuckets: [0, 0, 0, 0, 0, 1])),
        ]
        let time = ReportOutcomes(rows, page: .time, by: .person)
        try #require(time.groups.map(\.name) == ["Al", "Bea"])
        #expect(time.bar(time.groups[0]) == 0.5)
        #expect(ReportOutcomeWords.timeLine(time.groups[1]).hasPrefix("Waiting for a person 25% of the time · 3 waits, the middle one 5 to 15 minutes"))
        #expect(ReportOutcomeWords.medianWait([0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test func runtimesSayFailedSessionsAndUnpricedTurns() throws {
        var unpriced = row(runtime: "codex", usd: 2, counts: .init(sessions: 4, failedSessions: 1))
        unpriced.unpricedTurns = 3
        let runtimes = ReportOutcomes([row(usd: 9, counts: .init(sessions: 1)), unpriced], page: .runtimes, by: .runtime) { $0.capitalized }
        try #require(runtimes.groups.map(\.name) == ["Claude", "Codex"])
        #expect(runtimes.line(runtimes.groups[1]) == "$2.00 · 0 merged · 1 of 4 sessions failed (25%) · 3 turns not priced")
    }

    @Test func workflowsReadOnlyTheirOwnRowsFailingFirst() throws {
        let rows = [
            row(workflow: "nightly", usd: 4, working: 600, counts: .init(workflowRuns: 2)),
            row(workflow: "triage", usd: 1, working: 60, counts: .init(workflowRuns: 4, workflowFailures: 1)),
            row(usd: 50, counts: .init(sessions: 9)),
        ]
        let workflows = ReportOutcomes(rows, page: .workflows, by: .workflow)
        try #require(workflows.groups.map(\.name) == ["triage", "nightly"])
        #expect(workflows.total.cost["USD"] == 5, "a person's agents are not a workflow's")
        #expect(workflows.bar(workflows.groups[0]) == 0.25)
        #expect(workflows.line(workflows.groups[1]) == "0 of 2 runs failed · $2.00 a run · 5m working a run")
        #expect(ReportOutcomes.Page.workflows.ways.first == .workflow)
    }

    @Test func adoptionCountsEachWeekFromMonday() throws {
        let rows = [
            row(at: "2026-10-19T09", counts: .init(sessions: 2)),
            row(at: "2026-10-25", person: "al", runtime: "codex", workflow: "nightly", counts: .init(sessions: 3)),
            row(at: "2026-10-18", turns: 0),
        ]
        let weeks = ReportAdoptionWeek.weeks(rows)
        try #require(weeks.map(\.week) == ["2026-10-19", "2026-10-12"])
        #expect(weeks[0].line == "2 active people · 2.5 sessions a person · 2 runtimes · 1 workflow")
        #expect(weeks[0].title == "The week of 19 Oct")
        #expect(weeks[1].line == "0 active people · 0 runtimes · 0 workflows", "a row with no turn is nobody active")
        #expect(ReportAdoptionWeek.weeks(rows, hidden: true).first?.line == "5 sessions · 2 runtimes · 1 workflow")
    }

    @Test func countsDecodeFromTheWire() throws {
        let json = """
        {"at":"2026-10-21","person":"p","personName":"P","host":"h","hostName":"H","folder":"","runtime":"claude",
         "workflow":"nightly","cost":{},"inputTokens":0,"outputTokens":0,"thoughtTokens":0,"cachedReadTokens":0,
         "cachedWriteTokens":0,"turns":0,"unpricedTurns":0,"workingSeconds":0,"waitingSeconds":0,
         "counts":{"sessions":1,"failedSessions":0,"prsOpened":2,"prsMerged":1,"prsReverted":0,"mergeSeconds":60,
                   "waits":1,"waitBuckets":[1,0,0,0,0,0],"workflowRuns":1,"workflowFailures":0}}
        """
        let row = try JSONDecoder().decode(DaemonAPI.ReportRow.self, from: Data(json.utf8))
        #expect(row.workflow == "nightly")
        #expect(row.counts?.prsOpened == 2)
    }
}
