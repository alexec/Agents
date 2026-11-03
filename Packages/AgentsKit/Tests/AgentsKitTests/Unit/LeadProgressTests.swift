import Foundation
import Testing
@testable import AgentsKitCore

/// A lead's sidebar row (#3270), as `Web/test/lead-progress.test.mjs` has it on the web page.
@Suite("Lead progress")
struct LeadProgressTests {
    typealias Node = DaemonAPI.LineageNode
    let day = Date(timeIntervalSince1970: 1_793_000_000)
    let lead = UUID()

    func issue(_ n: Int) -> Node { Node(kind: "issue", ref: "github:alexec/Agents#\(n)") }

    func link(from: Node, to: Node, rel: String = "works-on", at: TimeInterval = 0, ended: Bool = false) -> DaemonAPI.LineageLink {
        .init(from: from, to: to, rel: rel, source: "start", at: day.addingTimeInterval(at),
              endedAt: ended ? day.addingTimeInterval(at + 1) : nil)
    }

    @Test func theEpicIsTheNewestIssueTheSessionWorksOn() {
        let me = LineageList.node(ofSession: lead)
        let lowered = Node(kind: "session", ref: me.ref.lowercased())
        let other = LineageList.node(ofSession: UUID())
        let links = [
            link(from: me, to: issue(1), at: 0),
            link(from: lowered, to: issue(2), at: 10),
            link(from: me, to: issue(3), at: 20, ended: true),
            link(from: other, to: issue(4), at: 30),
            link(from: me, to: Node(kind: "pr", ref: "github:alexec/Agents#5"), at: 40),
            link(from: me, to: issue(6), rel: "mentions", at: 50),
        ]
        #expect(LeadProgress.epic(of: lead, in: links) == issue(2))
        #expect(LeadProgress.epic(of: lead, in: []) == nil)
    }

    @Test func theWordsAreTheChildrenClosedOfAll() {
        func child(_ n: Int, _ state: String) -> DaemonAPI.ForgePlanChild {
            .init(item: .init(node: issue(n), title: "Issue \(n)", state: state, updatedAt: day), step: 1)
        }
        let epic = DaemonAPI.ForgeItem(node: issue(1), title: "Epic", state: "open", updatedAt: day)
        #expect(LeadProgress.words(.init(item: epic)) == nil)
        let plan = DaemonAPI.ForgePlan(item: epic, children: [child(2, "closed"), child(3, "open"), child(4, "closed")])
        #expect(LeadProgress.words(plan) == "2/3")
        #expect(LeadProgress.spoken("2/3") == "2 of 3 done")
    }
}
