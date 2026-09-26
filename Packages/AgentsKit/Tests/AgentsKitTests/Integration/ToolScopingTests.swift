import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the daemon actually sends a runtime it is scoping.
///
/// The unit tests hold the shape of a policy. These hold the thing that matters more
/// and is easier to lose: that the shape leaves the building. There are four doors into
/// a conversation — starting one, picking one back up, being handed one a runtime has
/// forgotten, and branching — and scoping applied at three of them is scoping that
/// lapses the first time somebody resumes an agent.
@Suite("Scoping an agent's tools", .timeLimit(.minutes(1)))
struct ToolScopingTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsScopingTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Wait until the turn is over, nothing is queued, and the runtime has been let go
    /// — all three, so the next prompt picks a conversation back up rather than landing
    /// in the session that is still open. `SuggestedPromptTests` explains the window.
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

    /// The names in a `session/new` the policy took away, whatever the runtime.
    private func denied(_ params: JSONValue?) -> [String] {
        params?["_meta"]?["claudeCode"]?["options"]?["disallowedTools"]?
            .arrayValue?.compactMap(\.stringValue) ?? []
    }

    @Test func aNewConversationCarriesThePolicy() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        let sent = denied(await launcher.lastAgent?.newSessionParams)
        #expect(sent == ToolPolicyCatalog.claude.removed.map(\.name))
    }

    /// The door that would have been left open. An agent picked back up after its
    /// runtime went away is the same agent, and a wider set of tools on the second
    /// conversation than the first is exactly the kind of thing nobody would notice.
    @Test func andSoDoesOnePickedBackUp() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.supportsResume = true
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        try await settle(core, id)
        try await core.prompt(.init(agentID: id, text: "carry on"))
        await eventually("the conversation was picked back up") {
            await launcher.lastAgent?.continuedSessionParams != nil
        }

        let sent = denied(await launcher.lastAgent?.continuedSessionParams)
        #expect(sent == ToolPolicyCatalog.claude.removed.map(\.name))
    }

    /// A runtime with no lever is sent nothing at all, rather than an empty something.
    /// Cursor is the one runtime this app cannot scope, and pretending otherwise on the
    /// wire would be the first lie in the table.
    @Test func aRuntimeWithNoLeverIsSentNoMetaAtAll() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        let params = await launcher.lastAgent?.newSessionParams
        #expect(params?["_meta"] == nil)
        #expect(params?["cwd"]?.stringValue == work.standardizedFileURL.path)
    }

    /// And the briefing that goes with it is the one for that runtime. Cursor keeps its
    /// goal tools, so it is told about them; Claude loses its scheduling tools, so the
    /// sentence forbidding cron entries is not spent on it.
    @Test func theBriefingIsTheOneForThatRuntime() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await eventually("the prompt reached the runtime") {
            await launcher.allAgents.first?.promptContent != nil
        }

        let sent = await launcher.allAgents.first?.promptContent?.arrayValue ?? []
        #expect(sent.last?["text"]?.stringValue == Briefing.text(for: ToolPolicyCatalog.cursor))
        #expect(sent.last?["text"]?.stringValue?.contains("CreateGoal") == true)
    }

    /// The other shape making it out of the building. An allow list is a different
    /// claim from a deny list, and the only thing that proves both reach a runtime is
    /// sending both.
    @Test func anAllowListLeavesTheBuildingToo() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        let params = await launcher.lastAgent?.newSessionParams
        let tools = params?["_meta"]?["agentProfile"]?["tools"]?.arrayValue?.compactMap(\.stringValue)
        #expect(tools?.contains("ask_user_question") == true)
        #expect(tools?.contains("spawn_subagent") == false)
    }
}
