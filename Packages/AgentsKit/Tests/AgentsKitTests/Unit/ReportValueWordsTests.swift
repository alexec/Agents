@testable import AgentsKitCore
import Foundation
import Testing

/// Reports ▸ Value's words (#2351), as the web page's `model/value.ts` says them.
struct ReportValueWordsTests {
    private func cost(_ usd: Decimal?, tokens: Int = 0) -> DaemonAPI.LineageCost {
        DaemonAPI.LineageCost(cost: usd.map { ["USD": $0] } ?? [:], inputTokens: tokens, turns: 1)
    }

    @Test func aNodeIsNamedWithoutItsTrackerAndAGitHubOneLinks() {
        #expect(ReportValueWords.name(.init(kind: "issue", ref: "github:alexec/agents#12")) == "alexec/agents#12")
        #expect(ReportValueWords.name(.init(kind: "issue", ref: "linear:ENG-4")) == "ENG-4")
        #expect(ReportValueWords.name(.init(kind: "milestone", ref: "github:alexec/agents/milestone/15")) == "alexec/agents milestone 15")
        #expect(ReportValueWords.name(.init(kind: "release", ref: "github:alexec/agents/release/v0.14.0")) == "alexec/agents release v0.14.0")
        #expect(ReportValueWords.url(.init(kind: "issue", ref: "github:alexec/agents#12"))?.absoluteString
            == "https://github.com/alexec/agents/issues/12")
        #expect(ReportValueWords.url(.init(kind: "milestone", ref: "github:alexec/agents/milestone/15"))?.absoluteString
            == "https://github.com/alexec/agents/milestone/15")
        #expect(ReportValueWords.url(.init(kind: "release", ref: "github:alexec/agents/release/v0.14.0"))?.absoluteString
            == "https://github.com/alexec/agents/releases/tag/v0.14.0")
        #expect(ReportValueWords.url(.init(kind: "issue", ref: "gitlab:g/p#3")) == nil)
    }

    @Test func theHeadlineTheWasteAndTheLeadTime() {
        let value = DaemonAPI.ReportValue(range: .month, scope: .init(kind: .me), total: cost(10), waste: cost(3),
                                          unlinked: cost(nil), perMergedPR: ["USD": 5], prsMerged: 2, prsClosed: 1,
                                          failedChecks: 2, leadTimeSeconds: 19 * 3600)
        #expect(ReportValueWords.headline(value) == "$10.00 on issues and pull requests · 2 merged · $5.00 a merged pull request")
        #expect(ReportValueWords.waste(value) == "$3.00 wasted: 1 closed without a merge · 2 failed CI rounds")
        var clean = value
        clean.prsClosed = 0
        clean.failedChecks = 0
        #expect(ReportValueWords.waste(clean) == "Nothing wasted")
        #expect(ReportValueWords.lead(value)?.hasPrefix("19h from the first work") == true)
        #expect(ReportValueWords.unlinked(value) == nil)
        clean.unlinked = cost(nil, tokens: 1200)
        #expect(ReportValueWords.unlinked(clean)?.contains("tokens on turns with no issue") == true)
        #expect(!ReportValueWords.isEmpty(value))
    }

    @Test func anIssuesLine() {
        var row = DaemonAPI.ReportValueRow(node: .init(kind: "issue", ref: "github:o/r#1"), total: cost(10), waste: cost(3),
                                           prsMerged: 1, prsClosed: 1, failedChecks: 1, leadTimeSeconds: 3600)
        #expect(ReportValueWords.line(row) == "$10.00 · 1 merged, 1 closed · $3.00 wasted · 1 failed CI round · 1h to merge")
        row = DaemonAPI.ReportValueRow(node: row.node, total: cost(10))
        #expect(ReportValueWords.line(row) == "$10.00 · Not merged yet")
    }
}
