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
        #expect(fileManager.fileExists(atPath: work.appending(path: ".agents/plugins").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let router = try read(work, "AGENTS.md")
        #expect(router.contains("`README.md`"))
        #expect(!router.contains("CONTRIBUTING.md"), "routes only to what is there")
        #expect(link(work, "CLAUDE.md") == "AGENTS.md")
        #expect(link(work, ".claude/skills") == "../.agents/skills")
        #expect(link(work, ".claude/plugins") == "../.agents/plugins")
        #expect(router.contains("`.agents/plugins/`"))
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

    @Test func anOlderLayoutGetsOnlyWhatWasAddedSince() throws {
        let work = try project()
        DotAgents.apply(to: work)
        // As the first layout left it, less what the person has since deleted.
        try fileManager.removeItem(at: work.appending(path: ".agents/plugins"))
        try fileManager.removeItem(at: work.appending(path: ".claude/plugins"))
        try fileManager.removeItem(at: work.appending(path: "CLAUDE.md"))
        try fileManager.removeItem(at: work.appending(path: ".agents/personas"))

        DotAgents.apply(to: work, from: 1)

        #expect(link(work, ".claude/plugins") == "../.agents/plugins")
        #expect(fileManager.fileExists(atPath: work.appending(path: ".agents/plugins").path))
        #expect(link(work, "CLAUDE.md") == nil)
        #expect(!fileManager.fileExists(atPath: work.appending(path: ".agents/personas").path))
    }

    @Test func existingClaudePluginsMoveIntoAgents() throws {
        let work = try project()
        try write(work, ".claude/plugins/deploy/.claude-plugin/plugin.json", "{}")

        DotAgents.apply(to: work)

        #expect(try read(work, ".agents/plugins/deploy/.claude-plugin/plugin.json") == "{}")
        #expect(link(work, ".claude/plugins") == "../.agents/plugins")
    }

    @Test func pluginsAreEveryFolderInTheProjectsPluginsFolder() throws {
        let work = try project()
        DotAgents.apply(to: work)
        try write(work, ".agents/plugins/b/plugin.json", "{}")
        try write(work, ".agents/plugins/a/.claude-plugin/plugin.json", "{}")
        try write(work, ".agents/plugins/.hidden/plugin.json", "{}")
        try write(work, ".agents/plugins/README.md", "not a plugin")
        let worktree = work.appending(path: "\(WorktreeName.folder)/lane", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)

        let expected = ["a", "b"].map { work.appending(path: ".agents/plugins/\($0)").path }
        #expect(DotAgents.pluginFolders(for: work).map(\.path) == expected)
        #expect(DotAgents.pluginFolders(for: worktree).map(\.path) == expected,
                "a worktree has no untracked layout, so its project's plugins are handed over")
    }

    @Test func claudeAndGrokAreHandedThePluginsAndNobodyElse() throws {
        let plugin = URL(filePath: "/work/.agents/plugins/deploy", directoryHint: .isDirectory)

        #expect(DotAgents.sessionMeta(runtimeID: "claude", plugins: [plugin])
                == .object(["claudeCode": .object(["options": .object(["plugins": .array([
                    .object(["type": .string("local"), "path": .string(plugin.path)])])])])]))
        #expect(DotAgents.sessionMeta(runtimeID: "grok", plugins: [plugin])
                == .object(["pluginDirs": .array([.string(plugin.path)])]))
        for runtimeID in ["codex", "cursor", "copilot"] {
            #expect(DotAgents.sessionMeta(runtimeID: runtimeID, plugins: [plugin]) == nil)
        }
        #expect(DotAgents.sessionMeta(runtimeID: "claude", plugins: []) == nil)
    }

    @Test func claudesPluginsSitBesideItsToolScoping() async throws {
        let (core, work, _) = try await world()
        DotAgents.apply(to: work)
        try write(work, ".agents/plugins/deploy/plugin.json", "{}")

        let meta = await core.sessionMeta(runtimeID: "claude", cwd: work)

        guard case .object(let top) = meta, case .object(let claudeCode) = top["claudeCode"],
              case .object(let options) = claudeCode["options"] else {
            Issue.record("no claudeCode.options in \(String(describing: meta))"); return
        }
        #expect(options["disallowedTools"] != nil, "the scoping is still there")
        #expect(options["plugins"] != nil)
    }

    @Test func theHomeFolderIsNeverLaidOut() throws {
        let home = fileManager.homeDirectoryForCurrentUser
        let before = link(home, "CLAUDE.md")
        DotAgents.apply(to: home)
        DotAgents.apply(to: URL(fileURLWithPath: "/"))
        #expect(link(home, "CLAUDE.md") == before)
        #expect(!fileManager.fileExists(atPath: "/AGENTS.md"))
    }

    /// A project somewhere, with a core that has not laid it out.
    private func world() async throws -> (DaemonCore, URL, StoreLocations) {
        let root = try project()
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appending(path: "store", directoryHint: .isDirectory))
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return (core, Project.standardize(work), locations)
    }

    @Test func aProjectFromBeforeIsLaidOutWhenAnAgentStartsInIt() async throws {
        let (core, work, locations) = try await world()

        _ = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "hello"))

        #expect(link(work, "CLAUDE.md") == "AGENTS.md")
        #expect(ProjectStore(locations: locations).load().first { $0.folder == work }?.laidOutAt != nil)
    }

    @Test func aProjectIsLaidOutOnlyOnce() async throws {
        let (core, work, _) = try await world()
        _ = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "one"))
        // The person did not want Claude's link, and said so by deleting it.
        try fileManager.removeItem(at: work.appending(path: "CLAUDE.md"))

        _ = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "two"))

        #expect(link(work, "CLAUDE.md") == nil)
    }

    @Test func aProjectFromTheFirstLayoutGetsPluginsOnce() async throws {
        let (_, work, locations) = try await world()
        DotAgents.apply(to: work, from: 0)
        try fileManager.removeItem(at: work.appending(path: ".claude/plugins"))
        try fileManager.removeItem(at: work.appending(path: "CLAUDE.md"))
        // A record from before layouts had a version, read by a daemon starting up.
        try ProjectStore(locations: locations).save([Project(folder: work, laidOutAt: Date())])
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()

        _ = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "hello"))

        #expect(link(work, ".claude/plugins") == "../.agents/plugins")
        #expect(link(work, "CLAUDE.md") == nil, "the first layout's steps are not put back")
        #expect(ProjectStore(locations: locations).load().first { $0.folder == work }?.layoutVersion == DotAgents.version)
    }

    @Test func addingAProjectLaysItOut() async throws {
        let (core, work, _) = try await world()

        _ = try await core.addProject(work)

        #expect(fileManager.fileExists(atPath: work.appending(path: "AGENTS.md").path))
        #expect(link(work, "CLAUDE.md") == "AGENTS.md")
    }
}
