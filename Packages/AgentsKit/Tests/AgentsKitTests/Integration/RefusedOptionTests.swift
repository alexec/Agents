import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A remembered choice the runtime will not take as the agent starts: never silent (049).
@Suite("A refused start option", .timeLimit(.minutes(1)))
struct RefusedOptionTests {
    @Test func aModelOfAnUnsignedProviderIsSaidAsASignInAndForgotten() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RefusedOption-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        // As OpenCode 1.18.33 refused it (research R6).
        script.setOptionErrors["model"] = JSONRPCError(
            code: -32602, message: "Invalid params: model not found: anthropic/claude-haiku-4-5",
            data: ["providerId": .string("anthropic"), "modelId": .string("anthropic/claude-haiku-4-5")])
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        let id = try await core.start(.init(runtimeID: "opencode", cwd: work, prompt: "hi",
                                            startOptions: StartOptions(values: ["model": "anthropic/claude-haiku-4-5",
                                                                                "mode": "build"])))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let page = try await core.transcript(.init(agentID: id))
        let notes = page.entries.compactMap { if case .runtimeNote(let text) = $0.kind { text } else { nil } }
        #expect(notes.contains("OpenCode isn’t signed in to anthropic, so it can’t use anthropic/claude-haiku-4-5. "
                               + "Sign it in from the runtime menu, then pick the model again."))
        #expect(await core.agent(id)?.startOptions.values["model"] == nil, "forgotten, so it is said once")
        #expect(await core.agent(id)?.startOptions.values["mode"] == "build", "the choices it took are kept")
    }
}
