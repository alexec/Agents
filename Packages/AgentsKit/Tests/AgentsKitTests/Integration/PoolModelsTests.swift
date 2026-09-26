import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// US6 of 052: what fills Matching models' menus, and Remember on Continue with.
@Suite("Models for Matching models", .timeLimit(.minutes(1)))
struct PoolModelsTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: nil))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: nil))

    private func offering(_ models: [String], current: String? = nil) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.configOptions = [
            ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                         currentValue: .string(current ?? models[0]),
                         options: models.map { ConfigChoice(value: .string($0), name: $0) }),
            ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select", currentValue: "default",
                         options: [ConfigChoice(value: "default", name: "default")]),
        ]
        return script
    }

    private func core(_ scripts: [FakeACPAgent.Script], default script: FakeACPAgent.Script = .init())
        async throws -> (DaemonCore, URL, FakeLauncher) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PoolModels-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        let current = locations.tools.appendingPathComponent("codex/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        discovery.macToolsHome = locations.tools.path
        let launcher = FakeLauncher(script: script, then: scripts)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        return (core, work, launcher)
    }

    @Test func itReadsWhatARuntimeOfferedAndStartsNothing() async throws {
        let (core, work, launcher) = try await core([offering(["opus", "sonnet"])])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it answered") { await core.agent(id)?.state == .finished }
        let launches = launcher.launchCount
        let models = await core.poolModels(["claude"])
        // Only the model (and effort, where there is one): not the mode.
        #expect(models["claude"]?.map(\.id) == ["model"])
        #expect(models["claude"]?.first?.options?.map(\.name) == ["opus", "sonnet"])
        #expect(launcher.launchCount == launches)
    }

    @Test func aRuntimeNeverSeenIsStartedOnceAndSentNothing() async throws {
        let (core, _, launcher) = try await core([offering(["gpt-5", "gpt-5-codex"])])
        let models = await core.poolModels(["codex"])
        #expect(models["codex"]?.first?.options?.map(\.name) == ["gpt-5", "gpt-5-codex"])
        #expect(launcher.launchCount == 1)
        #expect(await launcher.allAgents[0].prompts.isEmpty, "a handshake, never a prompt")
        // Remembered now: asking again starts nothing.
        _ = await core.poolModels(["codex"])
        #expect(launcher.launchCount == 1)
    }

    @Test func aRuntimeThatOffersNothingIsNotStartedAgainForTenMinutes() async throws {
        let (core, _, launcher) = try await core([])
        #expect(await core.poolModels(["codex"])["codex"]?.isEmpty != false)
        _ = await core.poolModels(["codex"])
        #expect(launcher.launchCount == 1)
    }

    @Test func rememberPutsThePairInALevel() async throws {
        let (core, work, _) = try await core([offering(["opus", "sonnet"], current: "opus"),
                                              offering(["opus", "sonnet"], current: "opus")],
                                             default: offering(["gpt-5", "gpt-5-codex"]))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the chat is quiet", within: .seconds(30)) {
            let agent = await core.agent(id)
            return agent?.outcomeAsked == true && agent?.state == .finished
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await core.continueWith(.init(agentID: id, runtimeID: "codex", choices: ["model": "gpt-5-codex"],
                                              confirmed: true, remember: .init(newLevelName: "Strongest")))
        let levels = await core.poolStatus().settings.levels
        #expect(levels.map(\.name) == ["Strongest"])
        #expect(levels.first?.cells["claude"]?.model == "opus")
        #expect(levels.first?.cells["codex"]?.model == "gpt-5-codex")
        try await core.poolStatus().settings.validate()
    }

    @Test func aPairedPhoneMayReadThem() {
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.poolModels))
    }
}
