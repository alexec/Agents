import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A send retried across a dropped connection happens once (037, FR-020).
@Suite("Sending once")
struct SendOnceTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSendOnceTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func settledAgent() async throws -> (DaemonCore, FakeLauncher, UUID) {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "first"))
        await eventually("the first turn is over") { await core.agent(id)?.state.holdsRuntime == false }
        return (core, launcher, id)
    }

    private func prompts(_ launcher: FakeLauncher) async -> Int {
        let all = await launcher.allAgents.asyncMap { await $0.received }
        return all.flatMap { $0 }.count { $0 == ACP.Method.prompt }
    }

    private func send(_ core: DaemonCore, _ agentID: UUID, sendID: UUID?) async throws {
        let request = DaemonAPI.PromptRequest(agentID: agentID, text: "again", sendID: sendID)
        _ = try await core.handle(method: DaemonAPI.Method.agentsPrompt,
                                  params: try JSONValue.encoding(request)).get()
    }

    @Test func theSameSendTwiceIsDeliveredOnce() async throws {
        let (core, launcher, id) = try await settledAgent()
        let before = await prompts(launcher)
        let sendID = UUID()
        try await send(core, id, sendID: sendID)
        try await send(core, id, sendID: sendID)
        await eventually("the send reached the runtime") { await prompts(launcher) == before + 1 }
        await eventually("and its turn ended") { await core.agent(id)?.state.holdsRuntime == false }
        #expect(await prompts(launcher) == before + 1)
    }

    @Test func withoutASendIDTwoSendsAreTwo() async throws {
        let (core, launcher, id) = try await settledAgent()
        let before = await prompts(launcher)
        try await send(core, id, sendID: nil)
        await eventually("the first turn ended") { await core.agent(id)?.state.holdsRuntime == false }
        try await send(core, id, sendID: nil)
        await eventually("both reached the runtime") { await prompts(launcher) == before + 2 }
    }

    @Test func aSendIDIsForgottenAfterFiveHundredAndTwelveOthers() async throws {
        let (core, _, _) = try await settledAgent()
        let counter = Counter()
        let first = UUID()
        _ = try await core.once(first) { await counter.bump(); return [:] }
        _ = try await core.once(first) { await counter.bump(); return [:] }
        #expect(await counter.value == 1)
        for _ in 0..<DaemonCore.sendMemory {
            _ = try await core.once(UUID()) { [:] }
        }
        _ = try await core.once(first) { await counter.bump(); return [:] }
        #expect(await counter.value == 2)
    }

    private actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for element in self { out.append(await transform(element)) }
        return out
    }
}
