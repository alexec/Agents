import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Once 052's carry-on (US1); since 065, the opposite: whatever each runtime says when
/// its allowance runs out, in its own words, the chat ends there and the runtime is
/// marked out. A pool still switched on moves nothing.
@Suite("A spent allowance moves nothing", .timeLimit(.minutes(1)))
struct PoolSwitchTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan"))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))
    private let copilot = PoolEntry(runtimeID: "copilot", payment: .allowance(label: nil))
    private let antigravity = PoolEntry(runtimeID: "antigravity", payment: .allowance(label: nil))
    private let grok = PoolEntry(runtimeID: "grok", payment: .allowance(label: nil))

    private func spent() throws -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        return script
    }

    /// Captured from “hi Grok”, 2026-09-27: top-level Internal error, real refusal under data.
    private func grokUsageBalanceExhausted() -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(
            code: -32603,
            message: "Internal error",
            data: .object([
                "http_status": .int(402),
                "message": .string("API error (status 402 Payment Required): Grok Build usage balance exhausted"),
            ]))
        return script
    }

    /// A daemon whose launches play `scripts` in order, then plain working turns.
    private func core(_ scripts: [FakeACPAgent.Script], pool: [PoolEntry]? = nil, isOn: Bool = true)
        async throws -> (DaemonCore, URL, FakeLauncher, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PoolSwitch-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        let current = locations.tools.appendingPathComponent("codex/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        let antigravityCurrent = locations.tools.appendingPathComponent("antigravity/current", isDirectory: true)
        try FileManager.default.createDirectory(at: antigravityCurrent, withIntermediateDirectories: true)
        try Data().write(to: antigravityCurrent.appendingPathComponent("ok"))
        discovery.macToolsHome = locations.tools.path
        let launcher = FakeLauncher(script: FakeACPAgent.Script(), then: scripts)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        _ = try await core.setPool(PoolSettings(isOn: isOn, entries: pool ?? [claude, codex, copilot]))
        return (core, work, launcher, locations)
    }

    private func kinds(_ core: DaemonCore, _ id: UUID) async throws -> [TranscriptEntry.Kind] {
        try await core.transcript(.init(agentID: id)).entries.map(\.kind)
    }

    @Test(.flakyUnderLoad) func copilotMonthlyQuotaInChatEndsTheChatOnCopilot() async throws {
        var script = FakeACPAgent.Script()
        script.updates = ["Info: Disabled tools: list_agents, read_agent, task, write_agent", "Error: You have exceeded your monthly ", "quota (Request ID: E423:33BD0C:51E9CCB:612237C:6AB86604)"].map {
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string($0)]]
        }
        let (core, work, launcher, _) = try await core([script], pool: [copilot, codex])
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "finish the change"))
        await eventually("the chat ran out") { await core.agent(id)?.endedReason == .allowanceSpent }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.agent(id)?.runtimeID == "copilot")
        #expect(launcher.launchCount == 1)
        #expect(await core.allowanceStates().contains { $0.credentialKey == "copilot:sign-in" && $0.isOut })
        #expect(!(try await kinds(core, id)).contains { if case .poolSwitch = $0 { true } else { false } })
    }

    @Test(.flakyUnderLoad) func antigravityUsageLimitInChatEndsTheChatOnAntigravity() async throws {
        // Captured from “hi Antigravity”, 2026-09-27: title + body as one agent message, then end_turn.
        var script = FakeACPAgent.Script()
        script.updates = [[
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": .string(
                "Usage Limit Reached\n\nYou have reached your current quota for this period. Your limit will reset in 5 days, 14 hours.")],
        ]]
        let (core, work, launcher, _) = try await core([script], pool: [antigravity, codex])
        let id = try await core.start(.init(runtimeID: "antigravity", cwd: work, prompt: "hi Antigravity"))
        await eventually("the chat ran out") { await core.agent(id)?.endedReason == .allowanceSpent }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.agent(id)?.runtimeID == "antigravity")
        #expect(launcher.launchCount == 1)
        #expect(await core.allowanceStates().contains { $0.credentialKey == "antigravity:sign-in" && $0.isOut })
    }

    @Test(.flakyUnderLoad) func grokUsageBalanceExhaustedEndsTheChatOnGrok() async throws {
        let (core, work, launcher, _) = try await core([grokUsageBalanceExhausted()], pool: [grok, codex])
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "hi Grok"))
        await eventually("the chat ran out") { await core.agent(id)?.endedReason == .allowanceSpent }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.agent(id)?.runtimeID == "grok")
        #expect(launcher.launchCount == 1)
        #expect(await core.allowanceStates().contains { $0.credentialKey == "grok:sign-in" && $0.isOut })
    }

    @Test(.flakyUnderLoad) func copilotQuotaWithPoolOffStopsWithoutClaimingSuccess() async throws {
        var script = FakeACPAgent.Script()
        // Captured from “hi Copilot”, 2026-09-27: a notice and six refusals,
        // each a separate chunk with no newline, followed by end_turn.
        script.updates = (["Info: Disabled tools: list_agents, read_agent, task, write_agent"]
            + Array(repeating: "Error: You have exceeded your monthly quota (Request ID: captured)", count: 6)).map {
                ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string($0)]]
            }
        let (core, work, launcher, _) = try await core([script], pool: [copilot, codex], isOn: false)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await eventually("the quota refusal stopped") { await core.agent(id)?.endedReason == .allowanceSpent }
        #expect(await core.agent(id)?.state != .finished)
        #expect(launcher.launchCount == 1)
        #expect(await core.agent(id)?.outcomeAsked == false)
        let entries = try await kinds(core, id)
        #expect(!entries.contains { if case .stateChanged(.finished, _) = $0 { true } else { false } })
        #expect(!entries.contains { if case .userMessage(_, _, .app) = $0 { true } else { false } })
    }

    /// A first turn that worked, and the app's own ask for a report after it (023), both
    /// over: the chat is quiet, with `launches` runtimes started so far.
    private func quiet(_ core: DaemonCore, _ id: UUID, _ launcher: FakeLauncher, launches: Int) async {
        // Both turns ended: the one asked for, and the app's ask for a report.
        await eventually("the chat is quiet", within: .seconds(30)) {
            let agent = await core.agent(id)
            let endings = (try? await core.transcript(.init(agentID: id)).entries.count {
                if case .stateChanged(.finished, _) = $0.kind { true } else { false }
            }) ?? 0
            return agent?.outcomeAsked == true && agent?.state == .finished && endings == 2
                && launcher.launchCount == launches
        }
    }

    @Test func nothingMovesWhenThePoolIsOff() async throws {
        let (core, work, launcher, _) = try await core([try spent()], isOn: false)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        #expect(launcher.launchCount == 1)
        #expect(try await kinds(core, id).contains {
            if case .runtimeNote(let t) = $0 { t.hasPrefix("Claude’s allowance ran out") } else { false }
        })
    }

    @Test(arguments: ["budget-exhausted", "auth-required", "overloaded"])
    func otherFailuresNeverMove(fixture: String) async throws {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture(fixture)
        let (core, work, launcher, _) = try await core([script])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launchCount == 1)
    }

    @Test func anUnrecognisedErrorNeverMoves() async throws {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(code: -32603, message: "Internal error")
        let (core, work, launcher, _) = try await core([script])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .processDied)
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launchCount == 1)
    }

    @Test func aChatsOwnSwitchOffKeepsItWhereItIs() async throws {
        let (core, work, launcher, _) = try await core([FakeACPAgent.Script(), FakeACPAgent.Script(), try spent()])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await quiet(core, id, launcher, launches: 2)
        await core.setSwitching(agentID: id, off: true)
        try await core.prompt(.init(agentID: id, text: "two"))
        await eventually("the turn ended spent") { await core.agent(id)?.endedReason == .allowanceSpent }
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launchCount == 3)
        #expect(try await kinds(core, id).contains {
            if case .runtimeNote(let t) = $0 { t.hasPrefix("Claude’s allowance ran out") } else { false }
        })
    }

    @Test func aPoolOfOneMovesNothing() async throws {
        let (core, work, launcher, _) = try await core([try spent()], pool: [claude])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launchCount == 1)
    }

    @Test func aPlainTurnFinishesAndMovesNothing() async throws {
        let (core, work, launcher, _) = try await core([])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .endTurn)
        #expect(await core.agent(id)?.state == .finished)
        #expect(launcher.launchCount == 1)
    }
}
