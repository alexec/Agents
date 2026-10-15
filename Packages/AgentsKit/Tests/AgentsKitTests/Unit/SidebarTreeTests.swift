import Foundation
import Testing
@testable import AgentsKitCore

/// Sessions under the session that started them (#835), as the window and the Remote draw
/// them; the web's `sidebarTree` keeps the same rules.
@MainActor
@Suite("The sidebar's tree")
struct SidebarTreeTests {
    private let api = URL(filePath: "/tmp/work/api")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ state: AgentState, _ title: String, at offset: Double, by starter: Agent? = nil,
                         unread: Bool = false) -> Agent {
        var made = Agent(runtimeID: "claude", cwd: api, title: title, state: state,
                         createdAt: t0.addingTimeInterval(offset), lastActivityAt: t0.addingTimeInterval(offset),
                         isUnread: unread)
        if state == .finished { made.endedReason = .endTurn }
        made.startedByAgent = starter?.id
        return made
    }

    /// One indent whatever the depth: a lane's helper sits under the lead with the lane,
    /// oldest first, and the list's own order holds for the rows at the top.
    @Test func everyDescendantSitsOneIndentUnderTheTopSession() throws {
        let lead = session(.finished, "lead", at: 1)
        let lane = session(.finished, "lane", at: 2, by: lead)
        let helper = session(.finished, "helper", at: 3, by: lane)
        let other = session(.finished, "other", at: 4)
        let list = [other, helper, lane, lead]
        let nested = SidebarTree.nest(list) { _ in nil }
        try #require(nested.map(\.agent.id) == [other.id, lead.id])
        #expect(nested[1].children.map(\.id) == [lane.id, helper.id])
    }

    /// A tree in each list (#587): a child stands on its own where its parent is not
    /// listed, and is found under a listed grandparent through a starter listed elsewhere.
    @Test func aChildWithoutItsParentInTheListStandsAlone() throws {
        let lead = session(.finished, "lead", at: 1)
        let lane = session(.running, "lane", at: 2, by: lead)
        let helper = session(.finished, "helper", at: 3, by: lane)
        let alone = SidebarTree.nest([helper]) { _ in nil }
        try #require(alone.map(\.agent.id) == [helper.id])
        #expect(alone[0].children.isEmpty)
        let starters = [lane.id: lead.id]
        let through = SidebarTree.nest([helper, lead]) { starters[$0] }
        try #require(through.map(\.agent.id) == [lead.id])
        #expect(through[0].children.map(\.id) == [helper.id])
    }

    /// A chain that loops is followed once and ends.
    @Test func aLoopEnds() {
        var first = session(.finished, "first", at: 1)
        let second = session(.finished, "second", at: 2, by: first)
        first.startedByAgent = second.id
        let nested = SidebarTree.nest([first, second]) { _ in nil }
        #expect(nested.flatMap { [$0.agent.id] + $0.children.map(\.id) }.count == 2)
    }

    /// Folded by default, the fold kept per row and across launches.
    @Test func aParentStartsFoldedAndKeepsItsFold() throws {
        let defaults = MemoryDefaults()
        let folds = SidebarFolds(defaults: defaults, scope: "")
        let model = AgentsModel()
        let lead = session(.finished, "lead", at: 1)
        let lane = session(.finished, "lane", at: 2, by: lead)
        model.replaceAgents([lead, lane])

        let folded = SidebarTree.rows([lane, lead], in: model, folds: folds)
        try #require(folded.map(\.id) == [lead.id])
        #expect(folded[0].children == 1 && !folded[0].isUnfolded)

        folds.set(session: lead.id, open: true)
        let open = SidebarTree.rows([lane, lead], in: model, folds: SidebarFolds(defaults: defaults, scope: ""))
        #expect(open.map(\.id) == [lead.id, lane.id])
        #expect(open.map(\.isChild) == [false, true])
    }

    /// Only the last opened are kept, so the defaults stay small.
    @Test func openSessionsAreBounded() throws {
        let defaults = MemoryDefaults()
        let folds = SidebarFolds(defaults: defaults, scope: "")
        let ids = (0...SidebarFolds.sessionsKept).map { _ in UUID() }  // index-ok: one more than is kept, never none
        for id in ids { folds.set(session: id, open: true) }
        #expect(folds.openSessions.count == SidebarFolds.sessionsKept)
        #expect(!folds.isOpen(session: ids[0]))
        #expect(folds.isOpen(session: ids.last!))
    }

    /// A folded parent's mark is the most urgent of its own and its live descendants',
    /// the parent's on a tie, and none from an archived one.
    @Test func aFoldedParentShowsTheMostUrgentMark() {
        let model = AgentsModel()
        let lead = session(.finished, "lead", at: 1)
        let lane = session(.running, "lane", at: 2, by: lead)
        let helper = session(.waitingOnUser, "helper", at: 3, by: lane)
        let gone = session(.archived, "gone", at: 4, by: lead)
        model.replaceAgents([lead, lane, helper, gone])

        #expect(Set(model.liveDescendants(of: lead.id).map(\.id)) == [lane.id, helper.id])
        #expect(SidebarTree.markAgent(of: lead, in: model).id == helper.id)

        model.upsert(session(.finished, "helper", at: 3, by: lane).with(id: helper.id))
        #expect(SidebarTree.markAgent(of: lead, in: model).id == lane.id)

        let idle = session(.finished, "idle", at: 5)
        model.upsert(idle)
        #expect(SidebarTree.markAgent(of: idle, in: model).id == idle.id)
    }

    /// The index follows sessions as they go.
    @Test func descendantsLeaveWhenTheyAreForgotten() {
        let model = AgentsModel()
        let lead = session(.finished, "lead", at: 1)
        let lane = session(.finished, "lane", at: 2, by: lead)
        model.replaceAgents([lead, lane])
        #expect(model.starter(of: lane.id) == lead.id)
        model.forget([lane.id])
        #expect(model.liveDescendants(of: lead.id).isEmpty)
        #expect(model.starter(of: lane.id) == nil)
    }
}

private extension Agent {
    func with(id: UUID) -> Agent {
        var copy = self
        copy.id = id
        return copy
    }
}
