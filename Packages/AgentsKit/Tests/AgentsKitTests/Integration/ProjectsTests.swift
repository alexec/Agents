import Foundation
import Testing
@testable import AgentsKit

/// A project is a folder, and the list of them is worked out rather than kept. These
/// are the properties that make that safe: the union is right, the names are right, and
/// nothing about an agent has to be migrated for its folder to appear.
///
/// Agents are seeded by writing records and loading them, which is exactly how an agent
/// written by an older build arrives.
@Suite("Projects", .timeLimit(.minutes(1)))
struct ProjectsTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    /// Made on disk, and returned in the one form a project's folder is ever in, so a
    /// test compares canonical against canonical rather than against how it was typed.
    private func folder(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func agent(in folder: URL, title: String, state: AgentState = .finished,
                       role: AgentRole = .worker, activity: Date = Date(),
                       created: Date = Date()) -> Agent {
        Agent(runtimeID: "claude", cwd: folder, title: title, state: state,
              createdAt: created, lastActivityAt: activity, endedReason: .endTurn, role: role)
    }

    /// A core holding these agents, arrived at the way a restart arrives at them.
    private func core(_ locations: StoreLocations, seeded: [Agent] = []) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store,
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return core
    }

    @Test func aFolderWithAnAgentIsAProjectWithNothingStored() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [agent(in: work, title: "Fix the parser")])

        let projects = await core.allProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.folder == work)
        #expect(projects.first?.name == "api")
        #expect(projects.first?.exists == true)
    }

    @Test func agentsWrittenBeforeProjectsNeedNoMigration() async throws {
        // The whole of the migration story: an agent record carries its folder, so the
        // project is there the first time anybody asks. Nothing is written to make it
        // so, and the store holds no project record at all.
        let (locations, root) = try temporary()
        let work = try folder(root, "legacy")
        let core = try await core(locations, seeded: [agent(in: work, title: "From an older build")])

        #expect(await core.allProjects().count == 1)
        #expect(ProjectStore(locations: locations).load().isEmpty,
                "a derived project keeps no record")
    }

    @Test func aDerivedProjectIsAsOldAsItsOldestAgent() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let core = try await core(locations, seeded: [
            agent(in: work, title: "First", created: old),
            agent(in: work, title: "Second"),
        ])

        #expect(await core.allProjects().first?.project.addedAt == old)
    }

    @Test func eachAgentCountsInExactlyOneGroup() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Waiting", state: .waitingOnUser),
            agent(in: work, title: "Running", state: .running),
            agent(in: work, title: "Done", state: .finished),
            agent(in: work, title: "Stopped", state: .stopped),
        ])

        let counts = await core.allProjects().first?.counts ?? [:]
        #expect(counts[.needsInput] == 1)
        #expect(counts[.working] == 1)
        #expect(counts[.completed] == 2)
        #expect(counts.values.reduce(0, +) == 4)
    }

    @Test func twoFoldersWithOneNameAreToldApart() async throws {
        let (locations, root) = try temporary()
        let one = try folder(try folder(root, "work"), "api")
        let two = try folder(try folder(root, "side"), "api")
        let core = try await core(locations, seeded: [
            agent(in: one, title: "One"),
            agent(in: two, title: "Two"),
        ])

        #expect(Set(await core.allProjects().map(\.name)) == ["work/api", "side/api"])
    }

    @Test func aNestedFolderIsItsOwnProject() async throws {
        let (locations, root) = try temporary()
        let api = try folder(root, "api")
        let docs = try folder(api, "docs")
        let core = try await core(locations, seeded: [
            agent(in: api, title: "Outer"),
            agent(in: docs, title: "Inner"),
        ])

        let projects = await core.allProjects()
        #expect(projects.count == 2, "matched by exact folder, never by containment")
        #expect(Set(projects.map(\.name)) == ["api", "docs"])
    }

    @Test func aMissingFolderIsStillListedAndSaysSo() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "gone")
        let core = try await core(locations, seeded: [agent(in: work, title: "Its folder went")])
        try FileManager.default.removeItem(at: work)

        let project = await core.allProjects().first
        #expect(project != nil, "the agents and their transcripts are still the point")
        #expect(project?.exists == false)
    }

    @Test func projectsAreOrderedByNewestActivity() async throws {
        let (locations, root) = try temporary()
        let old = try folder(root, "old")
        let new = try folder(root, "new")
        let core = try await core(locations, seeded: [
            agent(in: old, title: "Old", activity: Date(timeIntervalSince1970: 1_700_000_000)),
            agent(in: new, title: "New", activity: Date(timeIntervalSince1970: 1_800_000_000)),
        ])

        #expect(await core.allProjects().map(\.name) == ["new", "old"])
    }

    @Test func aFolderAddedByHandIsAProjectWithNoAgents() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "empty")
        let core = try await core(locations)

        let added = try await core.addProject(work)
        #expect(added.folder == work)
        #expect(added.counts.values.reduce(0, +) == 0)
        #expect(ProjectStore(locations: locations).load().count == 1,
                "this one cannot be derived, so it is kept")
    }

    @Test func addingTheSameFolderTwiceIsNotAnError() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "twice")
        let core = try await core(locations)

        let first = try await core.addProject(work)
        let second = try await core.addProject(work)
        #expect(first.folder == second.folder)
        #expect(ProjectStore(locations: locations).load().count == 1)
    }

    @Test func addingAFolderThatIsNotThereIsRefused() async throws {
        let (locations, root) = try temporary()
        let core = try await core(locations)
        let missing = root.appendingPathComponent("never", isDirectory: true)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.addProject(missing)
        }
    }

    @Test func aTrailingSlashDoesNotMakeASecondProject() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [agent(in: work, title: "One")])
        _ = try await core.addProject(URL(filePath: work.path + "/"))

        #expect(await core.allProjects().count == 1)
    }
}
