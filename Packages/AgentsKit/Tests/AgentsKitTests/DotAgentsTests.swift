import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A project added is laid out the dotagents way, with `.agents` holding the one real
/// copy and Claude's names linked to it — and nothing the person already wrote is lost.
@Suite("DotAgents", .timeLimit(.minutes(1)))
struct DotAgentsTests {
    private let fileManager = FileManager.default

    private func project() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DotAgentsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func link(_ project: URL, _ path: String) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: project.appending(path: path).path)
    }

    private func read(_ project: URL, _ path: String) throws -> String {
        try String(contentsOf: project.appending(path: path), encoding: .utf8)
    }

    private func write(_ project: URL, _ path: String, _ contents: String) throws {
        let url = project.appending(path: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func anEmptyFolderGetsTheWholeLayout() throws {
        let work = try project()
        try write(work, "README.md", "# Work\n")

        DotAgents.apply(to: work)

        var isDirectory: ObjCBool = false
        #expect(fileManager.fileExists(atPath: work.appending(path: ".agents/skills").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(fileManager.fileExists(atPath: work.appending(path: ".agents/personas").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let router = try read(work, "AGENTS.md")
        #expect(router.contains("`README.md`"))
        #expect(!router.contains("CONTRIBUTING.md"), "routes only to what is there")
        #expect(link(work, "CLAUDE.md") == "AGENTS.md")
        #expect(link(work, ".claude/skills") == "../.agents/skills")
        // Followed, the links land on the real copies.
        #expect(try read(work, "CLAUDE.md") == router)
        try write(work, ".agents/skills/x/SKILL.md", "x")
        #expect(try read(work, ".claude/skills/x/SKILL.md") == "x")
    }

    @Test func anExistingClaudeFileMovesToAgentsAndIsLinkedBack() throws {
        let work = try project()
        try write(work, "CLAUDE.md", "Be careful.\n")

        DotAgents.apply(to: work)

        #expect(try read(work, "AGENTS.md") == "Be careful.\n")
        #expect(link(work, "CLAUDE.md") == "AGENTS.md")
    }

    @Test func existingClaudeSkillsMoveIntoAgents() throws {
        let work = try project()
        try write(work, ".claude/skills/deploy/SKILL.md", "deploy")
        try write(work, ".claude/settings.json", "{}")

        DotAgents.apply(to: work)

        #expect(try read(work, ".agents/skills/deploy/SKILL.md") == "deploy")
        #expect(link(work, ".claude/skills") == "../.agents/skills")
        #expect(try read(work, ".claude/settings.json") == "{}", "the rest of .claude is untouched")
    }

    @Test func whatThePersonWroteOnBothSidesIsLeftAlone() throws {
        let work = try project()
        try write(work, "AGENTS.md", "agents")
        try write(work, "CLAUDE.md", "claude")
        try write(work, ".agents/skills/deploy/SKILL.md", "ours")
        try write(work, ".claude/skills/deploy/SKILL.md", "theirs")

        DotAgents.apply(to: work)

        #expect(try read(work, "AGENTS.md") == "agents")
        #expect(try read(work, "CLAUDE.md") == "claude")
        #expect(link(work, "CLAUDE.md") == nil)
        #expect(link(work, ".claude/skills") == nil)
        #expect(try read(work, ".claude/skills/deploy/SKILL.md") == "theirs")
    }

    @Test func applyingTwiceChangesNothing() throws {
        let work = try project()
        DotAgents.apply(to: work)
        try write(work, "AGENTS.md", "edited")

        DotAgents.apply(to: work)

        #expect(try read(work, "AGENTS.md") == "edited")
        #expect(link(work, "CLAUDE.md") == "AGENTS.md")
    }

    @Test func addingAProjectLaysItOut() async throws {
        let root = try project()
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appending(path: "store", directoryHint: .isDirectory))
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()

        _ = try await core.addProject(work)

        #expect(fileManager.fileExists(atPath: work.appending(path: "AGENTS.md").path))
        #expect(link(work, "CLAUDE.md") == "AGENTS.md")
    }
}
