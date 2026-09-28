import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// US1 of 052: a chat whose allowance runs out carries on with the next entry in the
/// pool, with the conversation handed over and its prompt sent again once.
@Suite("A chat carries on by itself", .timeLimit(.minutes(1)))
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

    /// Every prompt a fake runtime was sent, flattened to its text.
    private func promptText(_ agent: FakeACPAgent) async -> [String] {
        await agent.prompts.map { prompt in
            (prompt.arrayValue ?? []).compactMap { $0["text"]?.stringValue ?? $0["resource"]?["text"]?.stringValue }
                .joined(separator: "\n")
        }
    }

    @Test(.flakyUnderLoad) func copilotMonthlyQuotaInChatMovesToTheNextRuntime() async throws {
        var script = FakeACPAgent.Script()
        script.updates = ["Info: Disabled tools: list_agents, read_agent, task, write_agent", "Error: You have exceeded your monthly ", "quota (Request ID: E423:33BD0C:51E9CCB:612237C:6AB86604)"].map {
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string($0)]]
        }
        let (core, work, launcher, _) = try await core([script], pool: [copilot, codex])
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "finish the change"))
        await eventually("Copilot handed over to Codex") { await core.agent(id)?.runtimeID == "codex" }
        await eventually("Codex answered") { await core.agent(id)?.endedReason == .endTurn }
        #expect(launcher.launches.prefix(2).map(\.runtime) == ["copilot", "codex"])
        #expect(await core.allowanceStates().contains { $0.credentialKey == "copilot:sign-in" && $0.isOut })
        let switches = try await kinds(core, id).compactMap { if case .poolSwitch(let r) = $0 { r } else { nil } }
        #expect(switches.count == 1)
        #expect(switches.first?.reason == .allowanceSpent)
        let next = try #require(launcher.allAgents.dropFirst().first)
        let prompts = await promptText(next)
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("# Conversation so far") == true)
        #expect(prompts.first?.contains("finish the change") == true)
    }

    @Test(.flakyUnderLoad) func antigravityUsageLimitInChatMovesToTheNextRuntime() async throws {
        // Captured from “hi Antigravity”, 2026-09-27: title + body as one agent message, then end_turn.
        var script = FakeACPAgent.Script()
        script.updates = [[
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": .string(
                "Usage Limit Reached\n\nYou have reached your current quota for this period. Your limit will reset in 5 days, 14 hours.")],
        ]]
        let (core, work, launcher, _) = try await core([script], pool: [antigravity, codex])
        let id = try await core.start(.init(runtimeID: "antigravity", cwd: work, prompt: "hi Antigravity"))
        await eventually("Antigravity handed over to Codex") { await core.agent(id)?.runtimeID == "codex" }
        await eventually("Codex answered") { await core.agent(id)?.endedReason == .endTurn }
        #expect(launcher.launches.prefix(2).map(\.runtime) == ["antigravity", "codex"])
        #expect(await core.allowanceStates().contains { $0.credentialKey == "antigravity:sign-in" && $0.isOut })
        let switches = try await kinds(core, id).compactMap { if case .poolSwitch(let r) = $0 { r } else { nil } }
        #expect(switches.count == 1)
        #expect(switches.first?.reason == .allowanceSpent)
    }

    @Test(.flakyUnderLoad) func grokUsageBalanceExhaustedMovesToTheNextRuntime() async throws {
        let (core, work, launcher, _) = try await core([grokUsageBalanceExhausted()], pool: [grok, codex])
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "hi Grok"))
        await eventually("Grok handed over to Codex") { await core.agent(id)?.runtimeID == "codex" }
        await eventually("Codex answered") { await core.agent(id)?.endedReason == .endTurn }
        #expect(launcher.launches.prefix(2).map(\.runtime) == ["grok", "codex"])
        #expect(await core.allowanceStates().contains { $0.credentialKey == "grok:sign-in" && $0.isOut })
        let switches = try await kinds(core, id).compactMap { if case .poolSwitch(let r) = $0 { r } else { nil } }
        #expect(switches.count == 1)
        #expect(switches.first?.reason == .allowanceSpent)
        let next = try #require(launcher.allAgents.dropFirst().first)
        let prompts = await promptText(next)
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("hi Grok") == true)
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

    @Test func aSpentAllowanceMovesTheChatWithItsConversation() async throws {
        let (core, work, launcher, locations) = try await core([try spent()])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))
        let before = try #require(await core.agent(id))
        await eventually("it moved to Codex") { await core.agent(id)?.runtimeID == "codex" }
        await eventually("Codex answered") { await core.agent(id)?.endedReason == .endTurn }

        let agent = try #require(await core.agent(id))
        #expect(agent.poolEntryID == codex.id)
        let kinds = try await kinds(core, id)
        let switchAt = try #require(kinds.firstIndex { if case .poolSwitch = $0 { true } else { false } })
        let handoffAt = try #require(kinds.firstIndex { if case .handoff = $0 { true } else { false } })
        #expect(switchAt < handoffAt)
        guard case .poolSwitch(let record) = kinds[switchAt] else { return }
        #expect(record.from.runtimeID == "claude" && record.to.runtimeID == "codex")
        #expect(record.reason == .allowanceSpent)
        // Typed once: the person's words are on the record once, not again for the switch.
        #expect(kinds.count { if case .userMessage(let t, _, _) = $0 { t == "fix the login redirect" } else { false } } == 1)

        // One runtime each: Claude's, then Codex's.
        #expect(launcher.launches.map(\.runtime) == ["claude", "codex"])
        // Codex was sent the handoff and the prompt, once, in one turn.
        let codexRuntime = try #require(launcher.allAgents.dropFirst().first)
        let sent = await promptText(codexRuntime)
        #expect(sent.first?.contains("# Conversation so far") == true)
        #expect(sent.first?.contains("fix the login redirect") == true)
        #expect(sent.filter { $0.hasSuffix("fix the login redirect") || $0.contains("\nfix the login redirect") }.count >= 1)

        // Claude is out, and the switch was written down.
        #expect(await core.allowanceStates().contains { $0.credentialKey == "claude:sign-in" && $0.isOut })
        #expect(PoolStore(locations: locations).switches(since: .distantPast).count == 1)
        let claudeState = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        #expect(claudeState.returnsAt != nil)

        // On the Mac's event log, with what the catalogue promises.
        let events = await core.eventLog.events
        let switched = try #require(events.first { $0.name == "agent.runtime_switched" })
        #expect(switched.details["from"] == "claude" && switched.details["to"] == "codex")
        #expect(switched.details["reason"] == "allowanceSpent")
        #expect(switched.details["agent"] == id.uuidString)
        #expect(events.contains { $0.name == "cost.allowance_out" && $0.details["runtime"] == "claude" })

        // The same chat: only what it runs on changed.
        #expect(agent.id == before.id && agent.title == before.title && agent.cwd == before.cwd)
        #expect(agent.worktree == before.worktree && agent.projectFolder == before.projectFolder)
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

    @Test func anotherChatOnTheSpentRuntimeMovesBeforeItsNextTurn() async throws {
        // The first chat's turn and the ask for its report work; the second finds Claude
        // spent and moves.
        let (core, work, launcher, _) = try await core([FakeACPAgent.Script(), FakeACPAgent.Script(), try spent()])
        let first = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await quiet(core, first, launcher, launches: 2)
        let second = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "two"))
        await eventually("the second moved") { await core.agent(second)?.runtimeID == "codex" }
        await eventually("the second answered") { await core.agent(second)?.endedReason == .endTurn }
        #expect(launcher.launches.prefix(4).map(\.runtime) == ["claude", "claude", "claude", "codex"])

        // The first chat's next turn goes straight to Codex: Claude is never asked again.
        try await core.prompt(.init(agentID: first, text: "again"))
        await eventually("the first moved") { await core.agent(first)?.runtimeID == "codex" }
        await eventually("the first answered on Codex") {
            guard launcher.launchCount >= 5 else { return false }
            let prompted = await !launcher.allAgents[4].prompts.isEmpty
            let state = await core.agent(first)?.state
            return prompted && state == .finished
        }
        #expect(launcher.launches[4].runtime == "codex")
        let sent = await promptText(launcher.allAgents[4])
        #expect(sent.first?.contains("# Conversation so far") == true)
        // The handoff first, then the words typed, then anything the app adds.
        let text = try #require(sent.first)
        let handoffAt = try #require(text.range(of: "# Conversation so far"))
        let againAt = try #require(text.range(of: "\n\nagain\n"))
        #expect(handoffAt.lowerBound < againAt.lowerBound)
        #expect(sent.count == 1)
        let kinds = try await kinds(core, first)
        #expect(kinds.contains { if case .poolSwitch(let r) = $0 { r.reason == .allowanceSpent } else { false } })
        // Never failed first, so nothing says it ran out in this chat's own turn.
        #expect(!kinds.contains { if case .runtimeNote(let t) = $0 { t.hasPrefix("Claude’s allowance ran out") } else { false } })
    }

    @Test func itNeverGoesBackToOneAlreadyTriedForTheSamePrompt() async throws {
        let (core, work, _, _) = try await core([try spent(), try spent()])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it reached Copilot") { await core.agent(id)?.runtimeID == "copilot" }
        await eventually("Copilot answered") { await core.agent(id)?.endedReason == .endTurn }
        let switches = try await kinds(core, id).compactMap { if case .poolSwitch(let r) = $0 { r } else { nil } }
        #expect(switches.map(\.to.runtimeID) == ["codex", "copilot"])
    }

    @Test func everyoneOutStopsWithASentence() async throws {
        let (core, work, _, _) = try await core([try spent(), try spent(), try spent()])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it gave up") {
            (try? await kinds(core, id).contains {
                if case .runtimeNote(let t) = $0 { t.hasPrefix("Every other runtime in the pool is out") } else { false }
            }) == true
        }
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        #expect(await core.agent(id)?.state != .finished)
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
