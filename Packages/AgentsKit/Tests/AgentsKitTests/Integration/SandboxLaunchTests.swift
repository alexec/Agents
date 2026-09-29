import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every start and every turn launches its runtime with the sandbox choice it resolves to
/// (064, FR-003a–c, FR-011, FR-012): the agent's own, else its runtime's default, else as
/// configured, with a helper never looser than its caller.
@Suite("Sandbox at launch", .timeLimit(.minutes(1)))
struct SandboxLaunchTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSandbox-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func makeCore(_ locations: StoreLocations, _ launcher: FakeLauncher) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    private func letGo(_ core: DaemonCore, _ id: UUID) async {
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        await eventually("its runtime was handed back") { await core.live[id] == nil }
    }

    /// Every choice a runtime was launched with, in order. A turn that ends saying
    /// nothing is followed by the app's own question, which launches again.
    private func launched(_ launcher: FakeLauncher, _ runtimeID: String) -> Set<SandboxChoice> {
        Set(zip(launcher.launches.map(\.runtime), launcher.sandboxes).filter { $0.0 == runtimeID }.map(\.1))
    }

    private func claudeSandbox(_ params: JSONValue?) -> JSONValue? {
        params?["_meta"]?["claudeCode"]?["options"]?["sandbox"]?["enabled"]
    }

    @Test func asConfiguredAddsNothing() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "hi"))
        await letGo(core, id)
        #expect(launched(launcher, "claude") == [.runtime])
        #expect(claudeSandbox(await launcher.lastAgent?.newSessionParams) == nil)
        #expect(await core.agent(id)?.effectiveSandbox?.state == .runtimeControlled)
        #expect(await core.agent(id)?.sandboxOverride == nil)
    }

    @Test func aRuntimeDefaultReachesNewAgentsAndNotOtherRuntimes() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        _ = try await core.setSandboxSettings(SandboxSettings(defaults: ["claude": .off, "grok": .on]))
        let claude = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "hi"))
        await letGo(core, claude)
        #expect(claudeSandbox(await launcher.lastAgent?.newSessionParams) == .bool(false))
        #expect(await core.agent(claude)?.effectiveSandbox?.state == .off)
        let cursor = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "hi"))
        await letGo(core, cursor)
        #expect(launched(launcher, "claude") == [.off])
        #expect(launched(launcher, "cursor") == [.runtime])
        #expect(await core.agent(cursor)?.effectiveSandbox?.state == .runtimeControlled)
    }

    @Test func aChoiceTheCatalogLacksIsDropped() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        let saved = try await core.setSandboxSettings(SandboxSettings(defaults: ["gemini": .on, "cursor": .off, "grok": .off]))
        #expect(saved.defaults == ["grok": .off])
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "hi"))
        await letGo(core, id)
        #expect(launched(launcher, "grok") == [.off])
        let cursor = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "hi"))
        await letGo(core, cursor)
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.setSandbox(.init(agentID: cursor, choice: .off))
        }
    }

    @Test func anOverrideWinsAndClearingItInheritsFromTheNextTurn() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.supportsResume = true
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        _ = try await core.setSandboxSettings(SandboxSettings(defaults: ["grok": .off]))

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "first", sandbox: .on))
        await letGo(core, id)
        await settled(core, id)
        await letGo(core, id)
        #expect(await core.agent(id)?.sandboxOverride == .on)
        #expect(await core.agent(id)?.effectiveSandbox?.state == .on)

        _ = try await core.setSandbox(.init(agentID: id, choice: nil))
        try await core.prompt(.init(agentID: id, text: "second"))
        await eventually("the runtime was started again") { launcher.sandboxes.last == .off }
        await letGo(core, id)
        #expect(launcher.sandboxes.first == .on)
        #expect(launcher.sandboxes.last == .off, "the default from the next turn")
        #expect(await core.agent(id)?.effectiveSandbox?.state == .off)
    }

    @Test func claudePickedBackUpCarriesItsChoice() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.supportsResume = true
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "first"))
        await letGo(core, id)
        // The app's own question after a silent turn launches too; it goes first.
        await settled(core, id)
        await letGo(core, id)
        _ = try await core.setSandbox(.init(agentID: id, choice: .on))
        let before = launcher.launchCount
        try await core.prompt(.init(agentID: id, text: "second"))
        await eventually("the runtime was started again") { launcher.launchCount > before }
        await letGo(core, id)
        #expect(claudeSandbox(await launcher.lastAgent?.continuedSessionParams) == .bool(true))
    }

    @Test func codexOffStartsInFullAccessAndAModeChoiceIsTheAgentsOwn() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        _ = try await core.setSandboxSettings(SandboxSettings(defaults: ["codex": .off]))
        let id = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "hi",
                                            startOptions: StartOptions(values: ["mode": "read-only"])))
        await letGo(core, id)
        #expect(await core.agent(id)?.startOptions.values["mode"] == "agent-full-access")
        #expect(await core.agent(id)?.effectiveSandbox?.state == .off)

        _ = try await core.setOption(.init(agentID: id, optionID: "mode", value: "agent"))
        #expect(await core.agent(id)?.sandboxOverride == .on, "a mode picked by hand is this agent's choice")
        #expect(await core.sandboxSettings.choice(for: "codex") == .off, "the default is untouched")

        _ = try await core.setSandbox(.init(agentID: id, choice: .off))
        #expect(await core.agent(id)?.startOptions.values["mode"] == "agent-full-access")
        _ = try await core.setSandbox(.init(agentID: id, choice: .on))
        #expect(await core.agent(id)?.startOptions.values["mode"] == "read-only", "On from Full access asks again")
    }

    @Test func aHelperIsNeverLooserThanItsCaller() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        _ = try await core.setSandboxSettings(SandboxSettings(defaults: ["grok": .off]))
        let lead = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "lead", sandbox: .on))
        await letGo(core, lead)
        #expect(await core.agent(lead)?.effectiveSandbox?.state == .on)

        let helper = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "help"), startedBy: lead)
        await letGo(core, helper)
        #expect(launched(launcher, "grok") == [.runtime])
        #expect(await core.agent(helper)?.effectiveSandbox?.reason == "Limited by the agent that started it")

        let free = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "alone"))
        await letGo(core, free)
        #expect(launched(launcher, "grok") == [.runtime, .off], "an agent the person started is not capped")
    }
}
