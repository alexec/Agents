import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Once 052's carry-on (US1); since 065, the opposite: whatever each runtime says when
/// its allowance runs out, in its own words, the chat ends there and the runtime is
/// marked out. Nothing moves the chat.
@Suite("A runtime's own words that its allowance is spent", .timeLimit(.minutes(1)))
struct InChatRefusalTests {

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
    private func core(_ scripts: [FakeACPAgent.Script])
        async throws -> (DaemonCore, URL, FakeLauncher, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InChatRefusal-\(UUID().uuidString)", isDirectory: true)
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
        let (core, work, launcher, _) = try await core([script])
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
        let (core, work, launcher, _) = try await core([script])
        let id = try await core.start(.init(runtimeID: "antigravity", cwd: work, prompt: "hi Antigravity"))
        await eventually("the chat ran out") { await core.agent(id)?.endedReason == .allowanceSpent }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.agent(id)?.runtimeID == "antigravity")
        #expect(launcher.launchCount == 1)
        #expect(await core.allowanceStates().contains { $0.credentialKey == "antigravity:sign-in" && $0.isOut })
    }

    @Test(.flakyUnderLoad) func grokUsageBalanceExhaustedEndsTheChatOnGrok() async throws {
        let (core, work, launcher, _) = try await core([grokUsageBalanceExhausted()])
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
        let (core, work, launcher, _) = try await core([script])
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await eventually("the quota refusal stopped") { await core.agent(id)?.endedReason == .allowanceSpent }
        #expect(await core.agent(id)?.state != .finished)
        #expect(launcher.launchCount == 1)
        #expect(await core.agent(id)?.outcomeAsked == false)
        let entries = try await kinds(core, id)
        #expect(!entries.contains { if case .stateChanged(.finished, _) = $0 { true } else { false } })
        #expect(!entries.contains { if case .userMessage(_, _, .app) = $0 { true } else { false } })
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

    @Test func aPlainTurnFinishesAndMovesNothing() async throws {
        let (core, work, launcher, _) = try await core([])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .endTurn)
        #expect(await core.agent(id)?.state == .finished)
        #expect(launcher.launchCount == 1)
    }
}
