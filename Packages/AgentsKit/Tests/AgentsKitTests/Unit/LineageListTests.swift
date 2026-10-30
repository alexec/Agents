import Foundation
import Testing
@testable import AgentsKitCore

/// A session's Lineage pane (#2940), as `Web/test/lineage.test.mjs` has it on the web page.
@Suite("Lineage list")
struct LineageListTests {
    typealias Node = DaemonAPI.LineageNode
    static let s = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let t = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let session = LineageList.node(ofSession: s)
    let helper = LineageList.node(ofSession: t)
    let issue = Node(kind: "issue", ref: "github:alexec/agents#12")
    let pr = Node(kind: "pr", ref: "github:alexec/agents#34")
    let at = Date(timeIntervalSince1970: 0)

    var graph: DaemonAPI.LineageGraph {
        .init(nodes: [session, issue, helper, pr], links: [
            .init(from: session, to: issue, rel: "works-on", source: "branch", at: at),
            .init(from: session, to: helper, rel: "started", source: "helper", at: at),
            .init(from: helper, to: issue, rel: "works-on", source: "start", at: at),
            .init(from: pr, to: issue, rel: "fixes", source: "pr-body", at: at, endedAt: at),
        ])
    }

    static func cost(_ usd: Decimal, working: Double = 0) -> DaemonAPI.LineageCost {
        .init(cost: ["USD": usd], turns: 1, workingSeconds: working)
    }

    @Test func nodesInGroupsByKindWithoutTheSessionItself() {
        let groups = LineageList.groups(of: session, graph: graph, costs: [:]) { $0 == helper ? "Helper" : nil }
        let rows = groups.flatMap(\.rows)
        #expect(groups.map(\.title) == ["Issues", "Pull Requests", "Sessions"])
        #expect(groups.map { $0.rows.map(\.name) } == [["alexec/agents#12"], ["alexec/agents#34"], ["Helper"]])
        #expect(rows.map(\.links) == [
            ["This session works on it · from the branch", "Helper works on it · when it started",
             "alexec/agents#34 fixes it · from the PR's text · ended"],
            ["Fixes alexec/agents#12 · from the PR's text · ended"],
            ["This session started it · as a helper", "Works on alexec/agents#12 · when it started"],
        ])
        #expect(rows.map { $0.url?.absoluteString } == [
            "https://github.com/alexec/agents/issues/12", "https://github.com/alexec/agents/pull/34", nil,
        ])
        #expect(rows.map(\.session) == [nil, nil, Self.t])
        let run = Node(kind: "workflow-run", ref: "run:nightly")
        let started = LineageList.groups(of: session, graph: .init(nodes: [session, run], links: [
            .init(from: run, to: session, rel: "started", source: "start", at: at),
        ]), costs: [:]) { _ in nil }
        #expect(started.flatMap(\.rows).map(\.links) == [["Started this session · when it started"]])
    }

    @Test func anIssuesAndAPRsCostWithHowThePRsEnded() {
        let costs: [Node: DaemonAPI.LineageCostRollup] = [
            issue: .init(node: issue, total: Self.cost(10, working: 720), waste: Self.cost(3), prsMerged: 1, prsClosed: 1),
            pr: .init(node: pr, total: Self.cost(4), parts: [.init(node: pr, banked: Self.cost(4), outcome: "closed", lastAt: at)]),
        ]
        let groups = LineageList.groups(of: session, graph: graph, costs: costs) { _ in nil }
        #expect(groups.flatMap(\.rows).map(\.cost) == [
            "$10.00 · 12m working · 1 merged, 1 closed · $3.00 wasted", "$4.00 · closed without a merge: waste", nil,
        ])
        #expect(LineageList.costLine(.init(node: pr, total: Self.cost(1))) == "$1.00 · open")
        #expect(LineageList.costLine(.init(node: pr, total: Self.cost(0, working: 3))) == "3s working · open")
        #expect(LineageList.costLine(.init(node: issue, total: Self.cost(0))) == "Nothing banked yet")
    }

    @Test func onlyIssuesAndPRsAreCosted() {
        #expect(LineageList.costed(issue) && LineageList.costed(pr))
        #expect(!LineageList.costed(helper))
    }
}
