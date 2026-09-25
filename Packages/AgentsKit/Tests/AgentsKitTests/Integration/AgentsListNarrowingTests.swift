import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `agents/list` narrowed the way the phone asks: live agents at connect, and a
/// project's archived ones or a workflow's runs only when a page wants them.
@Suite("Agents list, narrowed", .timeLimit(.minutes(1)))
struct AgentsListNarrowingTests {
    private func temporary() throws -> (StoreLocations, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsListNarrowing-\(UUID().uuidString)", isDirectory: true)
        let one = root.appendingPathComponent("one", isDirectory: true)
        let two = root.appendingPathComponent("two", isDirectory: true)
        for folder in [one, two] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return (StoreLocations(root: root), one, two)
    }

    private func agent(_ folder: URL, _ state: AgentState, minutesAgo: Double,
                       workflow: String? = nil) -> Agent {
        var agent = Agent(runtimeID: "copilot", cwd: folder, title: "seed", state: state, endedReason: .endTurn)
        agent.lastActivityAt = Date(timeIntervalSinceNow: -minutesAgo * 60)
        agent.startedByWorkflow = workflow
        if state == .archived { agent.archivedReason = .byUser }
        agent.availableCommands = [SlashCommand(name: "review", description: "Run code review")]
        return agent
    }

    private func core(_ locations: StoreLocations, seeded: [Agent]) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: .init()))
        await core.loadFromDisk()
        return core
    }

    @Test func narrowsToWhatThePageAsksFor() async throws {
        let (locations, one, two) = try temporary()
        let live = agent(one, .finished, minutesAgo: 1)
        let oldest = agent(one, .archived, minutesAgo: 30)
        let newest = agent(one, .archived, minutesAgo: 10)
        let middle = agent(one, .archived, minutesAgo: 20, workflow: "nightly")
        let run = agent(one, .finished, minutesAgo: 2, workflow: "nightly")
        let elsewhere = agent(two, .archived, minutesAgo: 5, workflow: "nightly")
        let core = try await core(locations, seeded: [live, oldest, newest, middle, run, elsewhere])

        func ids(_ request: DaemonAPI.ListRequest) async -> [UUID] {
            await core.listAgents(request).map(\.id)
        }

        // What the phone asks for at connect: nothing archived.
        #expect(Set(await ids(.init(includeArchived: false))) == [live.id, run.id])
        // Everything, as the Mac and an older phone ask.
        #expect(await ids(.init()).count == 6)
        // One project's Archived section, newest first, a page at a time.
        #expect(await ids(.init(archivedOnly: true, folder: one)) == [newest.id, middle.id, oldest.id])
        #expect(await ids(.init(archivedOnly: true, folder: one, limit: 2)) == [newest.id, middle.id])
        // A workflow's runs in one project, archived ones too.
        #expect(await ids(.init(folder: one, startedByWorkflow: "nightly")) == [run.id, middle.id])
        #expect(await ids(.init(folder: one, startedByWorkflow: "nightly", limit: 1)) == [run.id])
    }

    @Test func aRequestFromBeforeTheNarrowingStillGetsEverything() throws {
        let request = try JSONDecoder().decode(DaemonAPI.ListRequest.self, from: Data(#"{"includeArchived":true}"#.utf8))
        #expect(request.includeArchived)
        #expect(request.archivedCommands)
        #expect(!request.archivedOnly)
        #expect(request.folder == nil)
        #expect(request.startedByWorkflow == nil)
        #expect(request.limit == nil)
    }
}
