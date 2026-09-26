import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Having asked Claude and Codex for typed failures, a refused turn arrives as
/// `end_turn` with the failure under `_meta` (052, R1). Read as a plain `end_turn` it
/// would call the agent done. These are the whole of slice 1: every kind is said in the
/// conversation, and none of them is ever `finished`.
@Suite("A refused turn is never done", .timeLimit(.minutes(1)))
struct TypedFailureNeverFinishesTests {
    private func core(_ script: FakeACPAgent.Script) throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TypedFailure-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        return (core, work)
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry in
            if case .runtimeNote(let text) = entry.kind { return text } else { return nil }
        }
    }

    private func failing(_ fixture: String) throws -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture(fixture)
        return script
    }

    @Test(arguments: ["quota-exhausted", "rate-limited", "budget-exhausted", "auth-required", "overloaded"])
    func anErrorEndsTheTurnWithItsOwnSentence(fixture: String) async throws {
        let script = try failing(fixture)
        let title = try #require(SessionFailure.from(meta: script.promptResultMeta)).title
        let (core, work) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let agent = try #require(await core.agent(id))
        #expect(agent.state != .finished, "a refused turn is never done")
        #expect(agent.endedReason == .runtimeError)
        #expect(try await notes(core, id).contains("Claude: \(title)"))
    }

    @Test func aWarningIsSaidAndTheTurnStillEndsAsItSays() async throws {
        let (core, work) = try core(try failing("retry-warning"))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .endTurn)
        #expect(try await notes(core, id).contains { $0.hasPrefix("Claude: Retrying after an API error") })
    }

    @Test func aFailureSentAlongsideTheTurnIsTheTurnsFailure() async throws {
        var script = FakeACPAgent.Script()
        script.sessionInfoMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        let (core, work) = try core(script)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .runtimeError)
        #expect(await core.agent(id)?.state != .finished)
    }

    @Test func aPlainEndTurnStillFinishes() async throws {
        let (core, work) = try core(FakeACPAgent.Script())
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .endTurn)
    }

    @Test func theNewEndingsSaySomething() {
        #expect(EndedReason.allowanceSpent.summary == "Its allowance ran out")
        #expect(EndedReason.rateLimited.summary == "Rate limited, and still limited after retrying")
        #expect(EndedReason(stopReason: "allowanceSpent") == nil, "not a protocol stop reason")
    }
}
