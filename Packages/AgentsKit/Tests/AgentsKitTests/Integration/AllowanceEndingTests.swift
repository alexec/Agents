import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A spent allowance ends the chat that was refused, on its runtime, and marks that
/// runtime out; nothing carries the chat on (065, US2). Another chat on the same runtime
/// is not held back by the mark, and its turn working brings the runtime back.
@Suite("A spent allowance ends that chat", .timeLimit(.minutes(1)))
struct AllowanceEndingTests {
    private func core(_ script: FakeACPAgent.Script, then: [FakeACPAgent.Script] = []) throws -> (DaemonCore, URL, StoreLocations, FakeLauncher) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AllowanceEnding-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        for runtime in ["gemini", "codex"] {
            let current = locations.tools.appendingPathComponent("\(runtime)/current", isDirectory: true)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            try Data().write(to: current.appendingPathComponent("ok"))
        }
        discovery.macToolsHome = locations.tools.path
        let launcher = FakeLauncher(script: then.last ?? script, then: then.isEmpty ? [] : [script] + then.dropLast())
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        return (core, work, locations, launcher)
    }

    private func spent() throws -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        return script
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry in
            if case .runtimeNote(let text) = entry.kind { return text } else { return nil }
        }
    }

    private func claudeState(_ core: DaemonCore) async -> AllowanceState? {
        await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" }
    }

    @Test func aSpentAllowanceStaysOnItsRuntime() async throws {
        let (core, work, _, launcher) = try core(try spent())
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        // Long enough for a carry-on to have started, had there been one.
        try await Task.sleep(for: .milliseconds(300))

        let agent = try #require(await core.agent(id))
        #expect(agent.runtimeID == "claude")
        #expect(agent.endedReason == .allowanceSpent)
        #expect(agent.allowanceWait == nil)
        #expect(launcher.launches.map(\.runtime) == ["claude"], "no second runtime was started")
        let words = try await notes(core, id)
        #expect(words.contains { $0.hasPrefix("Claude’s allowance ran out") })
        #expect(!words.contains { $0.contains("Carried on with") })
        #expect(await claudeState(core)?.isOut == true)
    }

    @Test func usedUpCreditEndsTheChatAndMarksTheRuntimeOut() async throws {
        var script = FakeACPAgent.Script()
        script.promptError = JSONRPCError(code: -32603, message: "Your credit balance is too low to access the Anthropic API.")
        let (core, work, _, launcher) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        try await Task.sleep(for: .milliseconds(300))

        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launches.count == 1)
        #expect(try await notes(core, id).contains { $0.contains("credit is used up") })
        #expect(await claudeState(core)?.isOut == true)
    }

    @Test func overageOnATurnThatWorkedKeepsItDoneAndMarksTheRuntimeOut() async throws {
        var script = FakeACPAgent.Script()
        script.usageMeta = try SessionFailureDecodingTests.fixture("claude-rate-limit-overage")
        let (core, work, _, launcher) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the plan is out") { await claudeState(core)?.isOut == true }
        await eventually("the turn ended") { await core.agent(id)?.state.hasTurnInFlight == false }
        try await Task.sleep(for: .milliseconds(300))

        #expect(await core.agent(id)?.endedReason == .endTurn, "the turn itself worked")
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launches.map(\.runtime).allSatisfy { $0 == "claude" })
        #expect(try await notes(core, id).contains { $0.contains("started using paid extra usage") })
    }

    @Test func anotherChatOnTheSameRuntimeIsPromptedAndBringsItBack() async throws {
        let (core, work, _, _) = try core(try spent(), then: [FakeACPAgent.Script()])
        let first = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the first ran out") { await core.agent(first)?.endedReason == .allowanceSpent }
        #expect(await claudeState(core)?.isOut == true)

        let second = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "again"))
        await eventually("the second turn worked") { await core.agent(second)?.endedReason == .endTurn }
        let agent = try #require(await core.agent(second))
        #expect(agent.runtimeID == "claude", "not moved first")
        #expect(agent.allowanceWait == nil)
        #expect(!(try await notes(core, second)).contains { $0.contains("allowance ran out") })
        await eventually("the runtime is back") { await claudeState(core)?.isOut == false }
    }

    @Test func aRateLimitIsRetriedOnTheSameChat() async throws {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("rate-limited")
        let (core, work, _, launcher) = try core(script, then: [FakeACPAgent.Script()])
        await core.useRateLimitPolicy(RateLimitPolicy(delays: [0.05], window: 600, persistsAfter: 3))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the retry worked") { await core.agent(id)?.endedReason == .endTurn }
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launches.map(\.runtime).allSatisfy { $0 == "claude" })
    }

    @Test func aWaitLeftFromBeforeIsClearedAtLaunchAndNothingStarts() async throws {
        let (core, work, locations, launcher) = try core(FakeACPAgent.Script())
        let store = try AgentStore(locations: locations)
        var agent = Agent(runtimeID: "claude", cwd: work, title: "Waiting from 052", state: .stopped,
                          endedReason: .allowanceSpent)
        agent.allowanceWait = AllowanceWait(resumeAt: Date(timeIntervalSinceNow: -60), entryID: UUID(),
                                            runtimeID: "codex", text: "go", blocks: [], from: .person)
        try await store.save(agent)

        await core.loadFromDisk()
        await core.tickWorkflows(now: Date())
        try await Task.sleep(for: .milliseconds(300))

        let loaded = try #require(await core.agent(agent.id))
        #expect(loaded.allowanceWait == nil)
        #expect(loaded.state == .stopped)
        #expect(launcher.launches.isEmpty, "nothing was started for it")
    }
}
