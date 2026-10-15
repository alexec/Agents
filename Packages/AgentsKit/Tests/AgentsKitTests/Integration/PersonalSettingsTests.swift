import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The person's settings in `~/.agents/settings`, one file each (#1033).
@Suite("Personal settings", .timeLimit(.minutes(1)))
struct PersonalSettingsTests {
    private func temporary() throws -> StoreLocations {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersonalSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var locations = StoreLocations(root: root)
        locations.personalHome = nil
        return locations
    }

    @Test func aHomeKeepsThemInItsAgentsFolder() {
        var locations = StoreLocations(root: URL(fileURLWithPath: "/tmp/agents-scratch-root"))
        locations.personalHome = URL(fileURLWithPath: "/tmp/probe-home")
        #expect(locations.personalSettings.path == "/tmp/probe-home/.agents/settings")
        #expect(locations.limits.path == "/tmp/probe-home/.agents/settings/limits.json")
        #expect(locations.sandbox.lastPathComponent == "sandbox.json")
    }

    @Test func noHomeKeepsThemInTheRoot() {
        var locations = StoreLocations(root: URL(fileURLWithPath: "/tmp/agents-scratch-root"))
        locations.personalHome = nil
        #expect(locations.personalSettings.path == "/tmp/agents-scratch-root/settings")
        locations.personalSettingsOverride = URL(fileURLWithPath: "/tmp/server-home/.agents/settings")
        #expect(locations.person.path == "/tmp/server-home/.agents/settings/person.json")
    }

    @Test func theRetentionClockStaysWithTheMachine() throws {
        let locations = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = RetentionStore(locations: locations)
        var file = store.load()
        file.settings.keepFor = .forever
        try store.save(file)
        #expect(FileManager.default.fileExists(atPath: locations.retention.path))
        #expect(FileManager.default.fileExists(atPath: locations.retentionClock.path))
        #expect(locations.retentionClock.deletingLastPathComponent().path == locations.root.path)
        #expect(store.load().settings == file.settings)
    }

    @Test func aFileEditedByHandIsReadAgain() async throws {
        let locations = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        _ = try await core.setPerson(PersonSettings(name: "Sam"))
        try Data(#"{"name": "Ash", "pronouns": "they/them"}"#.utf8).write(to: locations.person)
        await core.personalSettingsChanged()
        #expect(await core.personState().name == "Ash")
        #expect(await core.personState().pronouns == "they/them")
    }
}
