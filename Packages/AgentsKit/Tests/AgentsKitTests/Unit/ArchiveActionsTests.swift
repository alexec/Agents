import Foundation
import Testing
@testable import AgentsKitCore

@MainActor
@Suite("Shared archive actions")
struct ArchiveActionsTests {
    private let folder = URL(filePath: "/tmp/archive-actions")

    private func agent(_ title: String, state: AgentState, startedBy: UUID? = nil) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: folder, title: title, state: state)
        agent.startedByAgent = startedBy
        return agent
    }

    @Test func archivesLiveDescendantsAndReturnsUndoState() async throws {
        let model = AgentsModel()
        let parent = agent("parent", state: .running)
        let child = agent("child", state: .finished, startedBy: parent.id)
        let grandchild = agent("grandchild", state: .finished, startedBy: child.id)
        let archived = agent("already archived", state: .archived, startedBy: parent.id)
        model.replaceAgents([parent, child, grandchild, archived])
        var archivedIDs: [UUID] = []

        let undo = try #require(await ArchiveActions.archiveWithChildren(parent.id, in: model, andLeave: false) { id, _ in
            archivedIDs.append(id)
            return true
        })
        #expect(archivedIDs == [parent.id, child.id, grandchild.id])
        #expect(undo.agentIDs == archivedIDs)
        #expect(undo.title == "parent")
        #expect(undo.stopped)
    }

    @Test func failedParentDoesNotArchiveDescendants() async {
        let model = AgentsModel()
        let parent = agent("parent", state: .finished)
        let child = agent("child", state: .running, startedBy: parent.id)
        model.replaceAgents([parent, child])
        var calls = 0

        let undo = await ArchiveActions.archiveWithChildren(parent.id, in: model, andLeave: false) { _, _ in
            calls += 1
            return false
        }

        #expect(undo == nil)
        #expect(calls == 1)
    }

    @Test func archivedSearchFiltersAndStampsItsPage() async throws {
        let request = DaemonAPI.ListRequest(archivedCommands: false, limit: 10, lean: true, query: "parser")
        let archived = agent("old", state: .archived)
        let finished = agent("current", state: .finished)

        let page = try #require(await ArchiveActions.searchArchived(request, on: MachineRef(rawValue: "devbox")) {
            [archived, finished]
        })

        #expect(page.agents.map(\.id) == [archived.id])
        #expect(page.agents.first?.host == MachineRef(rawValue: "devbox"))
        #expect(page.next == nil)
    }

    @Test func denialTargetsTheAgentFolder() {
        var archived = agent("old session", state: .archived)
        archived.host = MachineRef(rawValue: "devbox")

        let denial = ArchiveActions.denial(for: archived)

        #expect(denial.approval.kind == .archive)
        #expect(denial.approval.agentID == archived.id)
        #expect(denial.approval.actions == [.deny])
        #expect(denial.folder == FolderKey(host: archived.host, folder: archived.folderPath))
    }
}
