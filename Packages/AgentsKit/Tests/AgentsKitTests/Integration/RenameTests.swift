import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The person renames a session (#751): their title wins over the runtime's and a
/// derived one, and clearing it hands naming back.
@Suite("Renaming a session", .timeLimit(.minutes(1)))
struct RenameTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsRenameTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    /// A runtime that names the session on every turn, as Claude's adapter can.
    private func naming(_ title: String?) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(100)
        script.title = title
        return FakeLauncher(script: script)
    }

    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(5), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if let agent = await core.agent(id),
               !agent.state.hasTurnInFlight, agent.queuedPrompts.isEmpty,
               await core.live[id] == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func rename(_ core: DaemonCore, _ id: UUID, _ title: String) async throws -> Agent {
        let answer = await core.handle(method: DaemonAPI.Method.agentsRename,
                                       params: try JSONValue.encoding(DaemonAPI.RenameRequest(agentID: id, title: title)),
                                       connection: UUID())
        return try answer.get().decode(Agent.self)
    }

    @Test("A rename outlasts the runtime's next title, and clearing it gives the runtime's back")
    func renameOutlastsTheRuntime() async throws {
        let (locations, work) = try temporary()
        let core = try core(naming("Fix login redirect issue"), locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))
        await eventually("the runtime's title arrived") {
            await core.agent(id)?.title == "Fix login redirect issue"
        }
        try await settle(core, id)

        let renamed = try await rename(core, id, "  Login   work \n")
        #expect(renamed.title == "Login work")
        #expect(renamed.titleIsPersons)

        try await core.prompt(.init(agentID: id, text: "carry on"))
        await eventually("the runtime named it again, under the rename") {
            await core.agent(id)?.runtimeTitle == "Fix login redirect issue"
        }
        try await settle(core, id)
        let after = try #require(await core.agent(id))
        #expect(after.title == "Login work")
        #expect(after.runtimeTitle == "Fix login redirect issue")

        let cleared = try await rename(core, id, "   ")
        #expect(cleared.title == "Fix login redirect issue")
        #expect(!cleared.titleIsPersons)
        #expect(cleared.runtimeTitle == nil)
    }

    @Test("A rename outlasts the title derived when a turn ends")
    func renameOutlastsADerivedTitle() async throws {
        let (locations, work) = try temporary()
        let core = try core(naming(nil), locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))
        _ = try await rename(core, id, "Mine")
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.title == "Mine")
        #expect(agent.titleIsPersons)
    }

    @Test("Renaming an agent that is not here is refused")
    func noSuchAgent() async throws {
        let (locations, _) = try temporary()
        let core = try core(naming(nil), locations: locations)
        await #expect(throws: JSONRPCError.self) {
            try await core.renameSession(.init(agentID: UUID(), title: "Anything"))
        }
    }

    @Test("A renamed record keeps its rename through the disk")
    func roundTrip() throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp"), title: "Runtime's")
        agent.rename(to: "Person's")
        agent.takeRuntimeTitle("Runtime's next")
        let read = try JSONDecoder().decode(Agent.self, from: try JSONEncoder().encode(agent))
        #expect(read.title == "Person's")
        #expect(read.titleIsPersons)
        #expect(read.runtimeTitle == "Runtime's next")
        #expect(read.unknownFields.isEmpty)

        let plain = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp"), title: "Runtime's")
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("titleIsPersons"))
        #expect(!json.contains("runtimeTitle"))
    }
}
