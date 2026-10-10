import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A Cursor turn that ends on `Error: RetriableError: …` is carried on, not left done (#513).
@Suite("A turn that ended on a retried error", .timeLimit(.minutes(1)))
struct RetriedErrorTurnTests {
    static let blip = "Error: RetriableError: [unavailable] getaddrinfo ENOTFOUND api2.cursor.sh"

    // MARK: Reading the words

    @Test func endsOnOnlyTheLastLine() {
        #expect(IntermittentError.endsOn(Self.blip))
        #expect(IntermittentError.endsOn("Looking now.\n\n\(Self.blip)\n"))
        #expect(!IntermittentError.endsOn("\(Self.blip)\nGot past it: here is the file."))
        #expect(!IntermittentError.endsOn("Here is the file."))
    }

    @Test func theTriesRunOut() {
        let policy = RetriedErrorPolicy(delays: [5, 30])
        #expect(policy.delay(forAttempt: 0) == 5)
        #expect(policy.delay(forAttempt: 1) == 30)
        #expect(policy.delay(forAttempt: 2) == nil)
    }

    // MARK: Through the daemon

    private func core(_ script: FakeACPAgent.Script) async throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RetriedErrorTurn-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.useRetriedErrorPolicy(RetriedErrorPolicy(delays: [0, 0]))
        return (core, work)
    }

    private static func said(_ text: String) -> JSONValue {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)]]
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry -> String? in
            if case .runtimeNote(let text) = entry.kind { return text } else { return nil }
        }
    }

    private func prompts(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry -> String? in
            if case .userMessage(let text, _, _) = entry.kind { return text } else { return nil }
        }
    }

    @Test func aBlipItGetsPastOnTheNextTryEndsDone() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [Self.said("Reading the file.\n\n"), Self.said(Self.blip)]
        script.updatesOnFirstTurnOnly = true
        let (core, work) = try await core(script)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "read it"))
        await eventually("carried on and finished") {
            guard await core.agent(id)?.endedReason == .endTurn else { return false }
            return (try? await prompts(core, id)) == ["read it", DaemonCore.carryOn]
        }
        #expect(try await notes(core, id).contains { $0.hasPrefix("Cursor stopped on a network error.") })
    }

    @Test func aBlipThatKeepsComingStopsAsAnError() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [Self.said(Self.blip)]
        let (core, work) = try await core(script)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "read it"))
        await eventually("gave up") {
            (try? await notes(core, id).contains { $0.hasPrefix("Cursor could not get past a network error after 2 tries") }) == true
        }
        #expect(await core.agent(id)?.endedReason == .runtimeError)
        await eventually("tried twice") {
            (try? await prompts(core, id)) == ["read it", DaemonCore.carryOn, DaemonCore.carryOn]
        }
    }

    @Test func aBlipTheAgentWentOnPastIsJustWords() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [Self.said(Self.blip + "\n"), Self.said("Got past it: here is the file.")]
        let (core, work) = try await core(script)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "read it"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        #expect(await core.agent(id)?.endedReason == .endTurn)
        await eventually("only the person's prompt") { (try? await prompts(core, id)) == ["read it"] }
    }
}
