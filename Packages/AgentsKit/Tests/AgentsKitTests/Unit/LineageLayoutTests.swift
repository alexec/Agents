import Foundation
import Testing
@testable import AgentsKitCore

/// A session's Lineage pane as a graph (#3019), as `Web/test/lineage.test.mjs` has it.
@Suite("Lineage layout")
struct LineageLayoutTests {
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

    func title(_ n: Node) -> String? { n == helper ? "Helper" : nil }

    @Test func theGraphHasATierPerKindCentredOnTheWidest() throws {
        let g = LineageLayout.graph(of: session, graph: graph, costs: [:], title: title)
        try #require(g.edges.count == 4)
        let at = { (n: Node) in g.node(n.ref).map { [$0.x, $0.y] } }
        #expect(at(issue) == [114, 16])
        #expect(at(session) == [16, 124])
        #expect(at(helper) == [212, 124])
        #expect(at(pr) == [114, 232])
        #expect(g.nodes.filter(\.here).map(\.row.name) == ["This session"])
        #expect(g.width == 408 && g.height == 300)
        #expect(g.edges.map(\.label) == ["works on", "started", "works on", "fixes"])
        #expect(g.edges.map(\.ended) == [false, false, false, true])
        #expect(g.edges[3].from == pr.ref && g.edges[3].to == issue.ref)
        #expect(g.nodes.map(\.detail) == ["Issue", "Session", "Session", "Pull request"])
        #expect(LineageLayout.graph(of: session, graph: .init(nodes: [session]), costs: [:], title: title).nodes.isEmpty)
    }

    @Test func aLineGoesFromTierToTierOrBelowItsTier() throws {
        let g = LineageLayout.graph(of: session, graph: graph, costs: [
            pr: .init(node: pr, total: .init(cost: ["USD": 4], turns: 1)),
        ], title: title)
        try #require(g.edges.count == 4)
        typealias P = LineageLayout.Point
        // This session (below) works on the issue (above): from its top to the issue's bottom.
        #expect(g.curve(g.edges[0]) == .init(start: P(x: 106, y: 124), c1: P(x: 106, y: 96), c2: P(x: 204, y: 96),
                                             end: P(x: 204, y: 68), mid: P(x: 155, y: 96)))
        // This session started the helper, beside it in its tier: below them.
        #expect(g.curve(g.edges[1]) == .init(start: P(x: 106, y: 176), c1: P(x: 106, y: 216), c2: P(x: 302, y: 216),
                                             end: P(x: 302, y: 176), mid: P(x: 204, y: 206)))
        #expect(g.node(pr.ref)?.detail == "Pull request · $4.00 · open")
        // With no PR, the sessions are the last tier, and the bend needs room.
        let noPR = LineageLayout.graph(of: session, graph: .init(nodes: [session, helper], links: [
            .init(from: session, to: helper, rel: "started", source: "helper", at: at),
        ]), costs: [:], title: title)
        #expect(noPR.height == 16 + 52 + 40 + 16)
    }

    @Test func aReleaseSitsInItsOwnTierBelowThePR() throws {
        let release = Node(kind: "release", ref: "github:alexec/agents/release/v0.14.0")
        let g = LineageLayout.graph(of: session, graph: .init(nodes: graph.nodes + [release], links: graph.links + [
            .init(from: pr, to: release, rel: "part-of", source: "forge", at: at),
        ]), costs: [:], title: title)
        let at = { (n: Node) in g.node(n.ref)?.y }
        try #require(at(pr) != nil && at(release) != nil)
        #expect(at(release)! > at(pr)!)
        #expect(g.node(release.ref)?.detail == "Release")
    }

    @Test func aTierFollowsTheOrderOfTheBoxesAboveIt() {
        let other = Node(kind: "issue", ref: "github:alexec/agents#1")
        let otherPR = Node(kind: "pr", ref: "github:alexec/agents#2")
        // The walk gives #2 first, but it fixes #1, which is right of #12.
        let g = LineageLayout.graph(of: session, graph: .init(nodes: [session, issue, other, otherPR, pr], links: [
            .init(from: session, to: issue, rel: "works-on", source: "branch", at: at),
            .init(from: session, to: other, rel: "works-on", source: "branch", at: at),
            .init(from: otherPR, to: other, rel: "fixes", source: "pr-body", at: at),
            .init(from: pr, to: issue, rel: "fixes", source: "pr-body", at: at),
        ]), costs: [:], title: title)
        let prs = g.nodes.filter { $0.row.node.kind == "pr" }.sorted { $0.x < $1.x }.map(\.row.node)
        #expect(prs == [pr, otherPR])
    }
}
