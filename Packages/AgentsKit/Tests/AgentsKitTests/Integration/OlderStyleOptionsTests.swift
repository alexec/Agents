import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A runtime that sends `models` and `modes` instead of `configOptions` (046: Gemini CLI).
/// The same two menus, set the older way, so a model chosen at the start is the one that
/// answers rather than silently "Auto".
@Suite("Models and modes the older way", .timeLimit(.minutes(1)))
struct OlderStyleOptionsTests {
    /// What Gemini CLI 0.61.0 answered `session/new` with on 2026-09-25, trimmed.
    static let geminiShape: [String: JSONValue] = [
        "modes": ["currentModeId": "default", "availableModes": [
            ["id": "default", "name": "Default", "description": "Prompts for approval"],
            ["id": "autoEdit", "name": "Auto Edit", "description": "Auto-approves edit tools"],
            ["id": "yolo", "name": "YOLO", "description": "Auto-approves all tools"],
            ["id": "plan", "name": "Plan", "description": "Read-only mode"]]],
        "models": ["currentModelId": "auto", "availableModels": [
            ["modelId": "auto", "name": "Auto"],
            ["modelId": "gemini-3-flash-preview", "name": "gemini-3-flash-preview"],
            ["modelId": "gemini-2.5-pro", "name": "gemini-2.5-pro"]]],
    ]

    @Test func theyBecomeTheModelAndModeMenus() throws {
        let options = ACPSession.olderStyleOptions(in: .object(Self.geminiShape))
        let model = try #require(options.first { $0.id == "model" })
        #expect(model.category == "model")
        #expect(model.currentValue == .string("auto"))
        #expect(model.options?.map(\.id) == ["auto", "gemini-3-flash-preview", "gemini-2.5-pro"])
        let mode = try #require(options.first { $0.id == "mode" })
        #expect(mode.category == "mode")
        #expect(mode.options?.map(\.id) == ["default", "autoEdit", "yolo", "plan"])
        #expect(ACPSession.olderStyleOptions(in: ["sessionId": "x"]).isEmpty)
    }

    @Test func aModelChosenAtTheStartIsSetTheOlderWay() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsOlderOptions-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var script = FakeACPAgent.Script()
        script.olderStyle = Self.geminiShape
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: StoreLocations(root: root)),
                              locations: StoreLocations(root: root), discovery: .findsEverything,
                              launcher: launcher)

        // Gemini on the Mac takes the key the window lends (046, D3).
        try await core.lendCredential(DaemonAPI.CredentialsLend(
            runtime: "gemini", secret: Secret("AQ." + "Ab8RN6FAKEOLDERSTYLEOPTIONSTEST00000")!), connection: UUID())
        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "go",
                                            startOptions: StartOptions(values: ["model": "gemini-3-flash-preview"])))
        await eventually("the turn ran") { await core.agent(id)?.state == .finished }
        let applied = await launcher.allAgents.first?.setOptions
        #expect(applied?.first?.id == "model")
        #expect(applied?.first?.value == .string("gemini-3-flash-preview"))
        // And the agent carries the menus, with the choice shown.
        let options = await core.agent(id)?.advertisedOptions ?? []
        #expect(options.contains { $0.id == "model" && $0.currentValue == .string("gemini-3-flash-preview") })
    }
}

/// Gemini refuses to load a conversation until `authenticate` has been called (046).
@Suite("Picking a Gemini conversation back up", .timeLimit(.minutes(1)))
struct GeminiContinueTests {
    @Test func itSignsInWhenRefusedAndLoads() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsGeminiContinue-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var script = FakeACPAgent.Script()
        script.loadNeedsAuthenticate = true
        let launcher = FakeLauncher(script: script)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        try await core.lendCredential(DaemonAPI.CredentialsLend(
            runtime: "gemini", secret: Secret("AQ." + "Ab8RN6FAKEGEMINICONTINUETEST000000")!), connection: UUID())

        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "first"))
        await eventually("the first turn ended") { await core.agent(id)?.state == .finished }
        try await core.stop(id)
        try await core.prompt(.init(agentID: id, text: "second"))
        await eventually("picked up and answered") {
            guard launcher.launchCount >= 2 else { return false }
            return await core.agent(id)?.state == .finished
        }

        var order: [String] = []
        for agent in launcher.allAgents {
            let received = await agent.received
            if received.contains(ACP.Method.loadSession) { order = received }
        }
        // Refused, signed in, loaded: the sign-in only once it was needed.
        let loads = order.indices.filter { order[$0] == ACP.Method.loadSession }
        let signedIn = try #require(order.firstIndex(of: ACP.Method.authenticate))
        #expect(loads.count == 2)
        #expect(loads.first! < signedIn && signedIn < loads.last!)
        let page = try await core.transcript(.init(agentID: id))
        let notes = page.entries.compactMap { if case .runtimeNote(let t) = $0.kind { t } else { nil } }
        #expect(!notes.contains { $0.contains("no longer has this conversation") }, "\(notes)")
    }

    /// Someone whose Gemini already loads is never signed in by the app, so its settings
    /// are left as they were (Alex, 2026-09-25).
    @Test func aLoadThatWorksIsNeverPrecededBySigningIn() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsGeminiContinue-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher(script: FakeACPAgent.Script())
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        try await core.lendCredential(DaemonAPI.CredentialsLend(
            runtime: "gemini", secret: Secret("AQ." + "Ab8RN6FAKEGEMINICONTINUETEST000000")!), connection: UUID())
        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "first"))
        await eventually("the first turn ended") { await core.agent(id)?.state == .finished }
        try await core.stop(id)
        try await core.prompt(.init(agentID: id, text: "second"))
        await eventually("picked up and answered") {
            guard launcher.launchCount >= 2 else { return false }
            return await core.agent(id)?.state == .finished
        }
        for agent in launcher.allAgents {
            #expect(!(await agent.received).contains(ACP.Method.authenticate))
        }
    }
}
