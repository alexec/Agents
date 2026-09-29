import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Slice 2 of 052: the daemon knows which credential is out and until when, retries a
/// rate limit, and treats paid overage as out. Chats still stop rather than move.
@Suite("Recognising a spent allowance, through the daemon", .timeLimit(.minutes(1)))
struct AllowanceRecognitionTests {
    private func core(_ script: FakeACPAgent.Script, then: [FakeACPAgent.Script] = []) throws -> (DaemonCore, URL, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AllowanceRecognition-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        // Gemini and Codex run only from the app's own copy, so each needs one (046, 047).
        for runtime in ["gemini", "codex"] {
            let current = locations.tools.appendingPathComponent("\(runtime)/current", isDirectory: true)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            try Data().write(to: current.appendingPathComponent("ok"))
        }
        discovery.macToolsHome = locations.tools.path
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: FakeLauncher(script: then.last ?? script, then: then.isEmpty ? [] : [script] + then.dropLast()))
        return (core, work, locations)
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry in
            if case .runtimeNote(let text) = entry.kind { return text } else { return nil }
        }
    }

    private func userMessages(_ core: DaemonCore, _ id: UUID) async throws -> Int {
        try await core.transcript(.init(agentID: id)).entries.count {
            if case .userMessage = $0.kind { return true } else { return false }
        }
    }

    @Test func aSpentPlanIsOutUntilThePlanWindowSaysAndTheChatSaysSo() async throws {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        script.usageMeta = try SessionFailureDecodingTests.fixture("claude-rate-limit-rejected")
        let (core, work, locations) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        #expect(await core.agent(id)?.state != .finished)
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        #expect(state.isOut)
        #expect(state.returnsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try await notes(core, id).contains { $0.hasPrefix("Claude’s allowance ran out. Its provider says it resets at") })
        // Written where the daemon keeps it, so a restart remembers.
        #expect(AllowanceStore(locations: locations).loadAllowances().contains { $0.isOut })
    }

    @Test func geminisSpentFreeTierIsOutUntilMidnightPacific() async throws {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(code: 429, message: "You have exhausted your daily quota on this model.")
        let (core, work, _) = try core(script)
        // Gemini on this Mac is lent a key from Settings (046).
        try await core.lendCredential(.init(runtime: "gemini", secret: try #require(Secret(LendTests.geminiKey))),
                                      connection: nil)
        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        let state = try #require(await core.allowanceStates().first { $0.credentialKey.hasPrefix("gemini:") })
        let back = try #require(state.returnsAt)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(pacific.component(.hour, from: back) == 0)
        #expect(try await notes(core, id).contains { $0.hasPrefix("Gemini’s allowance ran out. Its provider says it resets at") })
    }

    @Test func aRateLimitIsRetriedOnTheSameRuntimeAndThenWorks() async throws {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("rate-limited")
        // Each try is a fresh runtime; the second one works.
        let (core, work, _) = try core(script, then: [FakeACPAgent.Script()])
        await core.useRateLimitPolicy(RateLimitPolicy(delays: [0.05], window: 600, persistsAfter: 3))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the retry worked") { await core.agent(id)?.endedReason == .endTurn }
        #expect(try await notes(core, id).contains { $0.hasPrefix("Claude is rate limited. Trying again at") })
        // Sent again, not typed again: the conversation shows the person's words once.
        #expect(try await userMessages(core, id) >= 1)
        let firstPrompt = try await core.transcript(.init(agentID: id)).entries.filter {
            if case .userMessage(let text, _, _) = $0.kind { return text == "go" } else { return false }
        }
        #expect(firstPrompt.count == 1)
        let state = await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" }
        #expect(state?.isOut != true, "a rate limit is not out")
    }

    @Test func aRateLimitThatKeepsComingIsOut() async throws {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("rate-limited")
        let (core, work, _) = try core(script)
        await core.useRateLimitPolicy(RateLimitPolicy(delays: [0.05], window: 600, persistsAfter: 3))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it gave up") {
            (try? await notes(core, id).contains { $0.hasPrefix("Claude is still rate limited") }) == true
        }
        #expect(await core.agent(id)?.endedReason == .rateLimited)
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        guard case .out(nil, _?, .rateLimitPersisted) = state.status else { Issue.record("\(state.status)"); return }
    }

    @Test func paidOverageMarksThePlanOutEvenThoughTheTurnWorked() async throws {
        var script = FakeACPAgent.Script()
        script.usageMeta = try SessionFailureDecodingTests.fixture("claude-rate-limit-overage")
        let (core, work, _) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the plan is out") {
            await core.allowanceStates().contains { $0.credentialKey == "claude:sign-in" && $0.isOut }
        }
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        guard case .out(_, _, .overage) = state.status else { Issue.record("\(state.status)"); return }
        #expect(try await notes(core, id).contains { $0.contains("started using paid extra usage") })
    }

    @Test func anUnrecognisedRefusalWithNoPoolStopsTheChatAndMarksTheRuntimeFailed() async throws {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(code: -32603, message: "Internal error")
        let (core, work, _) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .processDied)
        #expect(try await notes(core, id).contains("Claude stopped answering."))
        // Every runtime is tracked and checked, pool or none (065, US4 scenario 5).
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        guard case .out(_, _?, .runtimeFailed) = state.status else { Issue.record("\(state.status)"); return }
    }

    @Test func anUnrecognisedRefusalStopsTheTurnAndTakesItOutOfThePool() async throws {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(code: -32603, message: "Internal error")
        let (core, work, _) = try core(script)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [
            PoolEntry(runtimeID: "claude", payment: .allowance(label: nil)),
            PoolEntry(runtimeID: "codex", payment: .allowance(label: nil)),
        ]))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .processDied)
        #expect(try await notes(core, id).contains("Claude stopped answering."))
        // Not a spent allowance, but out all the same until a check or a turn works.
        await eventually("it left the pool") {
            await core.allowanceStates().contains { $0.credentialKey == "claude:sign-in" && $0.isOut }
        }
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        guard case .out(nil, _?, .runtimeFailed) = state.status else { Issue.record("\(state.status)"); return }
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_out" && $0.details["reason"] == "runtime failed" })
    }

    @Test func aKeysCreditGoneIsOutAndStaysOut() async throws {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(code: 400, message: "Error code: 429 - insufficient_quota")
        let (core, work, _) = try core(script)
        let id = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        #expect(try await notes(core, id).contains("Codex’s credit is used up."))
    }

    @Test func groksUsageBalanceExhaustedIsOutEvenWhenNestedUnderInternalError() async throws {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(
            code: -32603,
            message: "Internal error",
            data: .object([
                "http_status": .int(402),
                "message": .string("API error (status 402 Payment Required): Grok Build usage balance exhausted"),
            ]))
        let (core, work, _) = try core(script)
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        #expect(try await notes(core, id).contains { $0.hasPrefix("Grok’s allowance ran out") })
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "grok:sign-in" })
        #expect(state.isOut)
    }
}
