import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The daemon keeps the person's `~/.agents` laid out as agents start (054): a skill
/// added while it runs is there for the next agent, and a daemon with no personal home
/// touches none.
@Suite("Personal layout, through the daemon", .timeLimit(.minutes(1)))
struct PersonalLayoutTests {
    private let fileManager = FileManager.default

    private func folders() throws -> (root: URL, home: URL, work: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersonalLayoutTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let folders = (root: base.appending(path: "root"), home: base.appending(path: "home"),
                       work: base.appending(path: "work"))
        for url in [folders.root, folders.home, folders.work] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return folders
    }

    private func core(_ locations: StoreLocations, _ launcher: FakeLauncher) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    private func addSkill(_ name: String, to home: URL) throws {
        let url = home.appending(path: ".agents/skills/\(name)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: A skill.\n---\n".write(to: url.appending(path: "SKILL.md"),
                                                                    atomically: true, encoding: .utf8)
    }

    // US1 scenario 3, FR-010
    @Test func aSkillAddedWhileTheDaemonRunsIsThereForTheNextAgent() async throws {
        let (root, home, work) = try folders()
        var locations = StoreLocations(root: root)
        locations.personalHome = home
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)
        await core.reconcileHome()  // as the daemon does when it starts

        try addSkill("grill-me", to: home)
        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        _ = await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        let link = try? fileManager.destinationOfSymbolicLink(atPath: home.appending(path: ".claude/skills/grill-me").path)
        #expect(link == "../../.agents/skills/grill-me")
        let record = PersonalDotAgents.Record.load(from: locations.personalLayout, home: home)
        #expect(record.links[".claude/skills/grill-me"] == "../../.agents/skills/grill-me")
    }

    // FR-015, SC-006
    @Test func aDaemonWithNoPersonalHomeLaysOutNone() async throws {
        let (root, home, work) = try folders()
        var locations = StoreLocations(root: root)
        locations.personalHome = nil
        try addSkill("grill-me", to: home)
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)

        await core.reconcileHome()
        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        _ = await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        #expect(!fileManager.fileExists(atPath: home.appending(path: ".claude").path))
        #expect(!fileManager.fileExists(atPath: locations.personalLayout.path))
    }
}
