import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Antigravity says a turn failed in words and then ends it with `end_turn` (049, R9).
/// These replay the exact lines `agy_acp_server` 1.2.1 sent on 2026-09-25.
@Suite("A turn Antigravity says failed", .timeLimit(.minutes(1)))
struct AntigravityTurnTests {
    static let refusedKey = #"Agent execution error: Agent execution terminated due to error. ("request failed (code 400): API key not valid. Please pass a valid API key.")"#

    // MARK: Reading the words

    @Test func theInnermostSentenceIsWhatTheRuntimeMeant() throws {
        let error = try #require(RuntimeLaunchCatalog.antigravity.turnError(in: Self.refusedKey))
        #expect(error.sentence == "API key not valid. Please pass a valid API key.")
    }

    @Test func aQuotaFailureReadsTheSameWay() throws {
        let text = #"Agent execution error: Agent execution terminated due to error. ("request failed (code 429): Resource has been exhausted (e.g. check quota).")"#
        let error = try #require(RuntimeLaunchCatalog.antigravity.turnError(in: text))
        #expect(error.sentence == "Resource has been exhausted (e.g. check quota).")
        #expect(RuntimeLaunchCatalog.antigravity.turnError(in: "Agent execution error: it broke")?.sentence == "it broke")
    }

    @Test func ordinaryWordsAndOtherRuntimesAreLeftAlone() {
        #expect(RuntimeLaunchCatalog.antigravity.turnError(in: "Here is the file you asked for.") == nil)
        #expect(RuntimeLaunchCatalog.antigravity.turnError(in: "I saw “Agent execution error:” in the log.") == nil)
        #expect(RuntimeLaunchCatalog.launch(for: "claude").turnError(in: Self.refusedKey) == nil)
    }

    @Test func aUsageLimitReachedMessageIsATurnError() {
        // Captured from “hi Antigravity”, 2026-09-27: chat text, then end_turn.
        let body = "You have reached your current quota for this period. Your limit will reset in 5 days, 14 hours."
        let text = "Usage Limit Reached\n\n" + body
        #expect(RuntimeLaunchCatalog.antigravity.turnError(in: text)?.sentence == body)
        #expect(RuntimeLaunchCatalog.antigravity.turnError(in: "Mentioning Usage Limit Reached mid-prose.") == nil)
    }

    // MARK: Through the daemon

    private func core(_ script: FakeACPAgent.Script) throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AntigravityTurn-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        // Antigravity runs only from the app's own copy, so it needs one: a whole
        // `current` in the daemon's tools, which discovery checks for `ok`.
        let current = locations.tools.appendingPathComponent("antigravity/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        var discovery = RuntimeDiscovery.findsEverything
        discovery.macToolsHome = locations.tools.path
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: FakeLauncher(script: script))
        return (core, work)
    }

    private static func said(_ text: String) -> JSONValue {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)]]
    }

    @Test func aFailureInWordsEndsTheTurnAsAnErrorNotAsDone() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [Self.said(Self.refusedKey)]
        script.updatesOnFirstTurnOnly = true
        let (core, work) = try core(script)
        let id = try await core.start(.init(runtimeID: "antigravity", cwd: work, prompt: "say hi"))
        await eventually("the turn ended as an error") {
            await core.agent(id)?.endedReason == .runtimeError
        }
        let page = try await core.transcript(.init(agentID: id))
        let notes = page.entries.compactMap { entry -> String? in
            if case .runtimeNote(let text) = entry.kind { return text } else { return nil }
        }
        #expect(notes.contains { $0 == "Antigravity could not do this turn: API key not valid. Please pass a valid API key." })
    }

    @Test func anotherFailureEndsAsARuntimeError() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [Self.said("Agent execution error: "), Self.said("the model is overloaded")]
        script.updatesOnFirstTurnOnly = true
        let (core, work) = try core(script)
        let id = try await core.start(.init(runtimeID: "antigravity", cwd: work, prompt: "say hi"))
        await eventually("the turn ended as an error") {
            await core.agent(id)?.endedReason == .runtimeError
        }
        #expect(EndedReason.runtimeError.summary == "The runtime reported an error")
    }

    @Test func theSameWordsFromAnotherRuntimeAreJustWords() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [Self.said(Self.refusedKey)]
        script.updatesOnFirstTurnOnly = true
        let (core, work) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "say hi"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .endTurn)
    }
}
