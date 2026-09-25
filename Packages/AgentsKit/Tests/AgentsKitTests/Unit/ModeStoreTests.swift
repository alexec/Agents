import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The mode last chosen for each runtime, held once on the Mac so a window and a phone
/// offer the same one first (029).
@Suite("The mode each runtime is started in, remembered on the Mac", .timeLimit(.minutes(1)))
struct ModeStoreTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsModeTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    /// A runtime that offers a mode and a model, the two a start form draws first.
    private func offering() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.configOptions = [
            ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select",
                         currentValue: "default",
                         options: [ConfigChoice(value: "default", name: "Default"),
                                   ConfigChoice(value: "plan", name: "Plan")]),
            ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                         currentValue: "opus",
                         options: [ConfigChoice(value: "opus", name: "Opus"),
                                   ConfigChoice(value: "sonnet", name: "Sonnet")]),
        ]
        return FakeLauncher(script: script)
    }

    private func core(_ locations: StoreLocations, _ launcher: FakeLauncher? = nil) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher ?? offering())
    }

    private func start(_ core: DaemonCore, in work: URL, _ values: [String: JSONValue]) async throws -> UUID {
        try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go",
                                   startOptions: StartOptions(values: values)))
    }

    @Test func aStartInAModeRemembersIt() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        let heard = ModesHeard()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.modesChanged,
                  let modes = try? params?.decode(DaemonAPI.RememberedModes.self) else { return }
            heard.add(modes)
        }

        _ = try await start(core, in: work, ["mode": "plan", "model": "sonnet"])

        #expect(await core.rememberedModes() == ["claude": "plan"], "the mode, and not the model")
        #expect(await eventually("the windows were told") { heard.last == ["claude": "plan"] })
    }

    @Test func aStartThatChoseNoModeRemembersNothing() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        _ = try await start(core, in: work, ["model": "sonnet"])
        #expect(await core.rememberedModes().isEmpty)
    }

    @Test func changingAnAgentsModeRemembersItAndChangingItsModelDoesNot() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        let id = try await start(core, in: work, [:])

        _ = try await core.setOption(.init(agentID: id, optionID: "model", value: "sonnet"))
        #expect(await core.rememberedModes().isEmpty)

        _ = try await core.setOption(.init(agentID: id, optionID: "mode", value: "plan"))
        #expect(await core.rememberedModes() == ["claude": "plan"])
    }

    @Test func importingFillsGapsAndNeverOverwrites() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        _ = try await start(core, in: work, ["mode": "plan"])

        let after = await core.importModes(.init(modes: ["claude": "default", "codex": "auto"]))

        #expect(after == ["claude": "plan", "codex": "auto"],
                "a window's old memory must not undo a choice made since on another device")
    }

    @Test func anEntryThatNoLongerReadsIsAbsentAndLeftInTheFile() async throws {
        let (locations, _) = try temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let written = #"{"claude":"not an entry","codex":{"mode":"auto","chosenAt":"2026-09-24T10:00:00Z"}}"#
        try Data(written.utf8).write(to: locations.modes)
        let core = try core(locations)

        #expect(await core.rememberedModes() == ["codex": "auto"])

        _ = await core.importModes(.init(modes: ["grok": "fast"]))
        let file = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: locations.modes))
        #expect(file["claude"] == "not an entry", "a later version may read it; it is not ours to throw away")
        #expect(file["grok"] != nil)
    }

    @Test func eachRootKeepsItsOwn() async throws {
        let (first, work) = try temporary()
        let (second, _) = try temporary()
        _ = try await start(try core(first), in: work, ["mode": "plan"])
        #expect(await (try core(second)).rememberedModes().isEmpty)
        #expect(await (try core(first)).rememberedModes() == ["claude": "plan"], "and it is still there after a restart")
    }
}

private final class ModesHeard: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [DaemonAPI.RememberedModes] = []

    func add(_ modes: DaemonAPI.RememberedModes) {
        lock.lock(); defer { lock.unlock() }
        heard.append(modes)
    }

    var last: DaemonAPI.RememberedModes? {
        lock.lock(); defer { lock.unlock() }
        return heard.last
    }
}
