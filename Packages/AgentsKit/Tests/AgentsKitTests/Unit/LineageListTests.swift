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

    @Test func aRowForEachNodeWithoutTheSessionItself() {
        let rows = LineageList.rows(of: session, graph: graph, costs: [:]) { $0 == helper ? "Helper" : nil }
        #expect(rows.map(\.name) == ["alexec/agents#12", "Helper", "alexec/agents#34"])
        #expect(rows.map(\.links) == [
            ["This session works on it · from the branch", "Helper works on it · when it started",
             "alexec/agents#34 fixes it · from the PR's text · ended"],
            ["This session started it · as a helper", "Works on alexec/agents#12 · when it started"],
            ["Fixes alexec/agents#12 · from the PR's text · ended"],
        ])
        #expect(rows.map { $0.url?.absoluteString } == [
            "https://github.com/alexec/agents/issues/12", nil, "https://github.com/alexec/agents/pull/34",
        ])
        #expect(rows.map(\.session) == [nil, Self.t, nil])
        let run = Node(kind: "workflow-run", ref: "run:nightly")
        let started = LineageList.rows(of: session, graph: .init(nodes: [session, run], links: [
            .init(from: run, to: session, rel: "started", source: "start", at: at),
        ]), costs: [:]) { _ in nil }
        #expect(started.map(\.links) == [["Started this session · when it started"]])
    }

    @Test func anIssuesAndAPRsCostWithHowThePRsEnded() {
        let costs: [Node: DaemonAPI.LineageCostRollup] = [
            issue: .init(node: issue, total: Self.cost(10, working: 720), waste: Self.cost(3), prsMerged: 1, prsClosed: 1),
            pr: .init(node: pr, total: Self.cost(4), parts: [.init(node: pr, banked: Self.cost(4), outcome: "closed", lastAt: at)]),
        ]
        let rows = LineageList.rows(of: session, graph: graph, costs: costs) { _ in nil }
        #expect(rows.map(\.cost) == [
            "$10.00 · 12m working · 1 merged, 1 closed · $3.00 wasted", nil, "$4.00 · closed without a merge: waste",
        ])
        #expect(LineageList.costLine(.init(node: pr, total: Self.cost(1))) == "$1.00 · open")
        #expect(LineageList.costLine(.init(node: pr, total: Self.cost(0, working: 3))) == "3s working · open")
        #expect(LineageList.costLine(.init(node: issue, total: Self.cost(0))) == "Nothing banked yet")
    }

    @Test func onlyIssuesAndPRsAreCosted() {
        #expect(LineageList.costed(issue) && LineageList.costed(pr))
        #expect(!LineageList.costed(helper))
    }

    /// #3089: a resolved node's real title is shown, and its state and labels alongside its
    /// cost, banked or not.
    @Test func aResolvedNodeShowsItsTitleStateAndLabels() {
        var resolved = graph
        resolved.resolved = [
            issue.ref: .init(title: "Fix the flaky test", state: "open", labels: ["bug", "area:lineage"]),
            pr.ref: .init(title: "Fix it", state: "merged"),
        ]
        let rows = LineageList.rows(of: session, graph: resolved, costs: [:]) { $0 == helper ? "Helper" : nil }
        #expect(rows.map(\.name) == ["Fix the flaky test", "Helper", "Fix it"])
        #expect(rows.map(\.resolved) == ["open · bug, area:lineage", nil, "merged"])

        let costs: [Node: DaemonAPI.LineageCostRollup] = [issue: .init(node: issue, total: Self.cost(10))]
        let withCost = LineageList.rows(of: session, graph: resolved, costs: costs) { $0 == helper ? "Helper" : nil }
        #expect(withCost.first?.resolved == "open · bug, area:lineage")
    }

    // The Lineage page (#3087): the graph from any start, as `Web/test/lineage.test.mjs` has it.

    @Test func anIssueAsTheStartHasItsOwnNameAndItsLinksNameIt() throws {
        let title = { (n: Node) -> String? in n == helper ? "Helper" : n == session ? "Fix it" : nil }
        let rows = LineageList.rows(of: issue, graph: graph, costs: [:], title: title)
        try #require(rows.map(\.name) == ["Fix it", "Helper", "alexec/agents#34"])
        #expect(rows[0].links == ["Works on alexec/agents#12 · from the branch", "Started Helper · as a helper"])
        #expect(rows.first { $0.node == pr }?.links == ["Fixes alexec/agents#12 · from the PR's text · ended"])
        let start = LineageList.start(issue, graph: graph, costs: [issue: .init(node: issue, total: Self.cost(2))], title: { _ in nil })
        #expect(start.name == "alexec/agents#12")
        #expect(start.cost == "$2.00")
        #expect(start.url?.absoluteString == "https://github.com/alexec/agents/issues/12")
        #expect(start.links.isEmpty)
        let g = LineageLayout.graph(of: issue, graph: graph, costs: [:], title: { _ in nil })
        #expect(g.nodes.filter(\.here).map(\.row.name) == ["alexec/agents#12"])
        #expect(LineageList.start(session, graph: graph, costs: [:], title: { _ in nil }).name == "This session")
    }

    @Test func aTypedStartIsAGitHubAddressOwnerRepoNumberOrASessionsID() {
        #expect(LineageList.node(typed: " https://github.com/alexec/Agents/issues/12 ") == Node(kind: "issue", ref: "github:alexec/Agents#12"))
        #expect(LineageList.node(typed: "https://github.com/alexec/Agents/pull/34/files") == Node(kind: "pr", ref: "github:alexec/Agents#34"))
        #expect(LineageList.node(typed: "https://github.com/alexec/Agents/milestone/15")
            == Node(kind: "milestone", ref: "github:alexec/Agents/milestone/15"))
        #expect(LineageList.node(typed: "https://github.com/alexec/Agents/releases/tag/v0.14.0")
            == Node(kind: "release", ref: "github:alexec/Agents/release/v0.14.0"))
        #expect(LineageList.node(typed: "alexec/Agents#12") == Node(kind: "issue", ref: "github:alexec/Agents#12"))
        #expect(LineageList.node(typed: "github:alexec/Agents#12") == Node(kind: "issue", ref: "github:alexec/Agents#12"))
        #expect(LineageList.node(typed: Self.s.uuidString.lowercased()) == session)
        #expect(LineageList.node(typed: "session:\(Self.s.uuidString)") == session)
        for no in ["", "#12", "alexec/Agents", "https://gitlab.com/a/b/-/issues/1", "https://github.com/alexec/Agents/issues/x", "a b/c#1"] {
            #expect(LineageList.node(typed: no) == nil, "\(no)")
        }
    }

    @Test func theBareFormMayAlsoBeAPullRequest() {
        #expect(LineageList.pullRequest(typed: "alexec/Agents#12") == Node(kind: "pr", ref: "github:alexec/Agents#12"))
        #expect(LineageList.pullRequest(typed: " github:alexec/Agents#12 ") == Node(kind: "pr", ref: "github:alexec/Agents#12"))
        for no in ["https://github.com/alexec/Agents/issues/12", "https://github.com/alexec/Agents/pull/12",
                   "https://github.com/alexec/Agents/milestone/15", "session:\(Self.s.uuidString)", "alexec/Agents"] {
            #expect(LineageList.pullRequest(typed: no) == nil, "\(no)")
        }
    }

    @Test func theStartsGoBackAndForwardAsABrowsers() {
        var h = LineageHistory<String>()
        #expect(h.current == nil)
        h.go("a"); h.go("b"); h.go("b")
        #expect(h.places == ["a", "b"] && h.at == 1)
        h.back()
        #expect(h.current == "a" && !h.canGoBack)
        h.go("c")
        #expect(h.places == ["a", "c"] && !h.canGoForward)
        for i in 0..<60 { h.go("n\(i)") }
        #expect(h.places.count == LineageHistory<String>.most)
        #expect(h.current == "n59")
    }
}
