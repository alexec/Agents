import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The shell in a project's own folder, opened with Control-` (#418).
///
/// No agent: it goes by the id made from the project's folder, and starts there.
@Suite("A project's own shell", .timeLimit(.minutes(1)))
struct ProjectShellTests {
    private func core() async throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsProjectShellTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.connectShells()
        await core.setConnectionCount(1)
        return (core, work)
    }

    @Test func theIDIsTheFoldersAndNoOtherFolders() {
        let one = URL(filePath: "/work/api")
        #expect(ProjectShell.id(for: one) == ProjectShell.id(for: URL(filePath: "/work/api")))
        #expect(ProjectShell.id(for: one) != ProjectShell.id(for: URL(filePath: "/work/web")))
    }

    @Test func aProjectWithNoAgentHasAShellInItsFolder() async throws {
        let (core, work) = try await core()
        let summary = try await core.addProject(work)
        let id = ProjectShell.id(for: summary.folder)

        let attached = try await core.attachShell(.init(agentID: id, folder: summary.folder))
        #expect(attached.state.isLive)
        #expect(attached.folder.map(Project.standardize) == Project.standardize(work))

        // Ended and started again, it is still in the project's folder.
        await core.shells.session(for: id)?.release(reason: "test")
        let restarted = try await core.restartShell(.init(agentID: id, folder: summary.folder))
        #expect(restarted.folder.map(Project.standardize) == Project.standardize(work))
        await core.closeShell(.init(agentID: id))
    }

    @Test func aProjectsShellsHaveTabsInItsFolder() async throws {
        let (core, work) = try await core()
        let summary = try await core.addProject(work)
        let id = ProjectShell.id(for: summary.folder)
        _ = try await core.attachShell(.init(agentID: id, folder: summary.folder))

        let opened = try await core.openShell(.init(agentID: id, folder: summary.folder))
        #expect(opened.shell == 1)
        #expect(await core.listShells(id).shells == [0, 1])
        let second = await core.shells.session(for: id, shell: 1)
        #expect(second.map { Project.standardize($0.folder) } == Project.standardize(work))

        // Without the folder there is no agent by that id to open one for.
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.openShell(.init(agentID: id))
        }
        await core.closeShell(.init(agentID: id, shell: 1))
        await core.closeShell(.init(agentID: id))
    }

    @Test func aFolderThatIsNotAProjectGetsNoShell() async throws {
        let (core, work) = try await core()
        let stranger = work.appendingPathComponent("not-a-project", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.attachShell(.init(agentID: ProjectShell.id(for: stranger), folder: stranger))
        }
    }

    @Test func anotherIDCannotStartOneInTheProject() async throws {
        let (core, work) = try await core()
        let summary = try await core.addProject(work)
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.attachShell(.init(agentID: UUID(), folder: summary.folder))
        }
    }
}
