import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The saved defaults, the agent's own choice, and what an older or newer file reads as (064).
@Suite("Sandbox settings")
struct SandboxSettingsTests {
    @Test func aRuntimeNotSavedIsAsConfigured() {
        let settings = SandboxSettings()
        #expect(settings.choice(for: "claude") == .runtime)
        #expect(settings.setting(.off, for: "grok").choice(for: "grok") == .off)
        #expect(settings.setting(.off, for: "grok").setting(.runtime, for: "grok").defaults.isEmpty)
    }

    @Test func unknownValuesNeverWidenAccess() throws {
        let json = #"{"defaults":{"grok":"sideways","claude":"off"},"future":1}"#
        let settings = try JSONDecoder().decode(SandboxSettings.self, from: Data(json.utf8))
        #expect(settings.choice(for: "grok") == .runtime)
        #expect(settings.choice(for: "claude") == .off)
        let state = try JSONDecoder().decode(SandboxState.self, from: Data(#""vm""#.utf8))
        #expect(state == .runtimeControlled)
        let record = try JSONDecoder().decode(SandboxFailureRecord.self, from: Data(
            #"{"runtimeID":"codex","detail":"x","hang":false,"recoveryOffered":true,"completedToolCalls":0,"resolution":"later"}"#.utf8))
        #expect(record.resolution == .keptStopped)
    }

    @Test func theStoreSetsAnUnreadableFileAside() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SandboxSettingsStore(locations: StoreLocations(root: root))
        #expect(store.load() == SandboxSettings())
        try store.save(SandboxSettings(defaults: ["claude": .on]))
        #expect(store.load().choice(for: "claude") == .on)
        try Data("not json".utf8).write(to: root.appendingPathComponent("sandbox-settings.json"))
        #expect(store.load() == SandboxSettings())
    }

    @Test func anOlderAgentHasNoChoiceOfItsOwn() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp"))
        var data = try JSONEncoder().encode(agent)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["sandboxOverride"] == nil)
        object["sandboxOverride"] = "off"
        object["effectiveSandbox"] = ["state": "off", "requested": "off"]
        data = try JSONSerialization.data(withJSONObject: object)
        let read = try JSONDecoder().decode(Agent.self, from: data)
        #expect(read.sandboxOverride == .off)
        #expect(read.effectiveSandbox?.state == .off)
        #expect(read.unknownFields["sandboxOverride"] == nil)
    }

    @Test func transcriptEntryRoundTrips() throws {
        let record = SandboxFailureRecord(runtimeID: "grok", detail: "Refusing to start", recoveryOffered: true)
        let entry = TranscriptEntry(kind: .sandboxFailure(record))
        let read = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(entry))
        guard case .sandboxFailure(let back) = read.kind else { Issue.record("not a sandbox failure"); return }
        #expect(back == record)
    }
}
