import Foundation
import Testing
@testable import AgentsKitCore

/// #3560: the estimate on Work's issue and epic pages, as `Web/test/estimate.test.mjs` has it.
@Suite("Estimate words")
struct EstimateWordsTests {
    typealias Range = DaemonAPI.LineageEstimateRange
    static func issue(_ n: Int) -> DaemonAPI.LineageNode { .init(kind: "issue", ref: "github:alexec/Agents#\(n)") }

    let story = DaemonAPI.LineageEstimate(
        node: issue(1), type: "enhancement", level: "story", closedIssues: 40, matchedBy: "level", matches: 31,
        cost: ["USD": Range(median: 3.2, p10: 1.1, p90: 9.8)], outputTokens: Range(median: 45000, p10: 12000, p90: 140_000),
        workingSeconds: Range(median: 7800, p10: 1800, p90: 21600), leadTimeSeconds: Range(median: 36000, p10: 10800, p90: 144_000))

    @Test func anIssueSaysItsFiguresSourceAndRange() {
        #expect(EstimateWords.line(story) == "Estimate: about $3.20, 45K output tokens, 2h 10m of work (from 31 closed stories)")
        #expect(EstimateWords.rangeWords(story)
            == "8 in 10 like it: $1.10 to $9.80, 12K to 140K output tokens, 30m to 6h of work. Lead time 3h to 40h: it varies with the queue.")
        #expect(EstimateWords.spentWords(story) == nil)
        #expect(EstimateWords.shows(story))
        var bug = story
        bug.matchedBy = "type"
        bug.type = "bug"
        #expect(EstimateWords.source(bug) == "31 closed bugs")
        bug.matchedBy = "all"
        #expect(EstimateWords.source(bug) == "31 closed issues")
    }

    @Test func tooLittleHistorySaysSoAndNothingElse() {
        let none = DaemonAPI.LineageEstimate(node: Self.issue(2), closedIssues: 3)
        #expect(EstimateWords.line(none) == "Not enough past work to estimate")
        #expect(EstimateWords.rangeWords(none) == nil)
        #expect(EstimateWords.childWords(none) == nil)
    }

    @Test func anEpicAddsUpItsOpenChildrenAndSaysWhatTheClosedSpent() {
        var epic = DaemonAPI.LineageEstimate(
            node: Self.issue(3), closedIssues: 40, matches: 60, cost: ["USD": Range(median: 12, p10: 6, p90: 30)],
            workingSeconds: Range(median: 36000, p10: 18000, p90: 72000), openChildren: 3, closedChildren: 2,
            spent: .init(cost: ["USD": 4.1], turns: 2), children: [story])
        #expect(EstimateWords.line(epic) == "Estimate for 3 open children: about $12.00, 10h of work (from 60 closed issues)")
        #expect(EstimateWords.spentWords(epic) == "Spent $4.10 on 2 closed children")
        #expect(EstimateWords.childWords(story) == "est. $3.20 · 2h 10m")
        epic.openChildren = 0
        #expect(!EstimateWords.shows(epic))
    }

    @Test func aClosedIssueSaysTheEstimateAtItsStartAgainstTheActual() {
        var done = story
        #expect(EstimateWords.actualWords(done) == nil)
        done.kept = .init(at: Date(timeIntervalSince1970: 0), matchedBy: "level", matches: 31, cost: ["USD": 3.2],
                          workingSeconds: 7800)
        #expect(EstimateWords.actualWords(done) == nil)
        done.actual = .init(cost: ["USD": 4.1], workingSeconds: 10800)
        #expect(EstimateWords.actualWords(done) == "Estimated $3.20, 2h 10m of work; actual $4.10, 3h of work")
        done.kept = .init(at: Date(timeIntervalSince1970: 0), matches: 0)
        #expect(EstimateWords.actualWords(done) == nil)
    }
}
