import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `personal/shared` against a home with one of everything in it (054,
/// contracts/personal-shared.md).
@Suite("What every agent shares")
struct PersonalSnapshotTests {
    private let fileManager = FileManager.default
    private let secret = "SENTINEL-5e7d-not-for-the-window"

    private func home() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersonalSnapshotTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fileManager.createDirectory(at: url.appending(path: ".agents"), withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ relative: String, in home: URL) throws {
        let url = home.appending(path: relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func skill(_ name: String, at relative: String, in home: URL) throws {
        try write("---\nname: \(name)\ndescription: The \(name) skill.\n---\nBody.\n", "\(relative)/\(name)/SKILL.md", in: home)
    }

    /// A home with instructions, skills (one clashing), servers (one clashing, one sse, one
    /// carrying secrets), a plugin, other files, and servers in runtimes' own configs.
    private func fullHome() throws -> URL {
        let home = try home()
        try write("# Mine\n", ".agents/AGENTS.md", in: home)
        try skill("dataviz", at: ".agents/skills", in: home)
        try skill("review", at: ".agents/skills", in: home)
        try skill("review", at: ".claude/skills", in: home)  // a real one: a clash
        try write("""
            {"mcpServers": {
              "github": {"command": "npx", "args": ["-y", "server-github", "--token=\(secret)", "\(secret)"], "env": {"GITHUB_TOKEN": "\(secret)"}},
              "linear": {"url": "https://mcp.linear.app/mcp?key=\(secret)#\(secret)", "headers": {"Authorization": "Bearer \(secret)"}},
              "old": {"type": "sse", "url": "https://user:\(secret)@old.example/sse"}
            }}
            """, ".agents/mcp.json", in: home)
        try write("\n[mcp_servers.github]\ncommand = \"gh\"\n\n[mcp_servers.figma]\nurl = \"https://figma\"\n[mcp_servers.figma.env]\nX = \"y\"\n",
                  ".codex/config.toml", in: home)
        try write("{\"mcpServers\": {\"notes\": {\"command\": \"notes\"}}}", ".cursor/mcp.json", in: home)
        try write("{\"name\":\"heron-plugin\",\"version\":\"1.0.0\"}", ".agents/plugins/heron-plugin/.claude-plugin/plugin.json", in: home)
        try skill("plover-skill", at: ".agents/plugins/heron-plugin/skills", in: home)
        try write("{\"mcpServers\":{\"plover-mcp\":{\"command\":\"python3\"}}}", ".agents/plugins/heron-plugin/.mcp.json", in: home)
        try write("A reviewer.", ".agents/personas/reviewer.md", in: home)
        try write("{}", ".agents/.skill-lock.json", in: home)
        try write("Notes.", ".agents/README.md", in: home)
        try fileManager.createDirectory(at: home.appending(path: ".agents/.git"), withIntermediateDirectories: true)
        var record = PersonalDotAgents.Record(home: home.path)
        PersonalDotAgents.reconcile(home: home, installed: ["claude", "codex", "cursor", "copilot"], record: &record)
        return home
    }

    private func snapshot(_ home: URL, installed: Set<String> = ["claude", "codex", "cursor", "copilot"])
        -> DaemonAPI.SharedSnapshot {
        PersonalDotAgents.snapshot(home: home, installed: installed,
                                   record: .init(home: home.path))
    }

    @Test func reachHasAKeyForEachInstalledRuntimeOnly() throws {
        let shot = snapshot(try fullHome())
        #expect(shot.runtimes.map(\.id) == ["claude", "codex", "cursor", "copilot"])
        #expect(Set(shot.instructions?.reach.keys ?? [:].keys) == ["claude", "codex", "cursor", "copilot"])
        for skill in shot.skills { #expect(Set(skill.reach.keys) == ["claude", "codex", "cursor", "copilot"]) }
        for server in shot.mcp.servers { #expect(!server.reach.keys.contains("grok")) }
    }

    @Test func instructionsSayWhichFileEachReads() throws {
        let shot = snapshot(try fullHome())
        #expect(shot.instructions?.exists == true)
        #expect(shot.instructions?.reach["claude"] == .gets("~/.claude/CLAUDE.md → link"))
        #expect(shot.instructions?.reach["cursor"]?.gets == false)
        #expect(shot.needsALook.contains { $0.kind == .noFile && $0.item == "Cursor" })
    }

    @Test func aSkillClashNamesBothPaths() throws {
        let home = try fullHome()
        let shot = snapshot(home)
        let review = try #require(shot.skills.first { $0.name == "review" && $0.source == .personal })
        #expect(review.path == home.appending(path: ".agents/skills/review").path)
        #expect(review.clash == home.appending(path: ".claude/skills/review").path)
        #expect(review.reach["claude"] == .ownCopy(home.appending(path: ".claude/skills/review").path))
        #expect(review.reach["codex"] == .gets("reads ~/.agents/skills"))
        #expect(shot.needsALook.contains { $0.kind == .clash && $0.page == .skills && $0.item == "review" })

        let dataviz = try #require(shot.skills.first { $0.name == "dataviz" })
        #expect(dataviz.description == "The dataviz skill.")
        #expect(dataviz.reach["claude"] == .gets("through a link in ~/.claude/skills"))
    }

    @Test func aPluginsSkillsSayWhichPlugin() throws {
        let shot = snapshot(try fullHome())
        let plover = try #require(shot.skills.first { $0.name == "plover-skill" })
        #expect(plover.source == .plugin("heron-plugin"))
        #expect(plover.reach["cursor"]?.gets == false)

        let plugin = try #require(shot.plugins.first)
        #expect(plugin.name == "heron-plugin")
        #expect(plugin.contents.skills == 1)
        #expect(plugin.serverNames == ["plover-mcp"])
        #expect(plugin.files.contains(".mcp.json"))
        #expect(plugin.reach["claude"]?.gets == true)
        #expect(plugin.reach["codex"]?.gets == false)  // not added yet
        #expect(shot.needsALook.contains { $0.kind == .noWay && $0.page == .plugins })
    }

    @Test func serversSayWhatEachRuntimeDoesWithThem() throws {
        let home = try fullHome()
        let shot = snapshot(home)
        #expect(shot.mcp.servers.map(\.name) == ["github", "linear", "old"])
        let github = try #require(shot.mcp.servers.first { $0.name == "github" })
        #expect(github.envNames == ["GITHUB_TOKEN"])
        #expect(github.reach["claude"] == .gets("sent at start"))
        #expect(github.reach["codex"] == .ownCopy(home.appending(path: ".codex/config.toml").path))
        #expect(github.reach["copilot"] == .gets("through the bridge"))
        #expect(shot.mcp.servers.first { $0.name == "linear" }?.reach["copilot"] == .gets("sent at start"))
        #expect(shot.mcp.servers.first { $0.name == "old" }?.reach["codex"]?.gets == false)
        #expect(shot.mcp.app.first?.reach["copilot"] == .gets("through the bridge"))
        #expect(shot.needsALook.contains { $0.kind == .clash && $0.item == "github" })
        #expect(shot.needsALook.contains { $0.kind == .leftOut && $0.item == "Codex" })

        let runtimeOnly = shot.mcp.runtimeOnly.map { "\($0.runtimeID)/\($0.name)" }
        #expect(runtimeOnly == ["codex/figma", "cursor/notes"])
    }

    // A link not placed yet is placed before the runtime's next agent; only one the app
    // placed and the person removed is left out (FR-009).
    @Test func aLinkNotYetPlacedIsNotOneThatWasRemoved() throws {
        let home = try home()
        try skill("dataviz", at: ".agents/skills", in: home)
        var record = PersonalDotAgents.Record(home: home.path)

        let before = PersonalDotAgents.snapshot(home: home, installed: ["claude"], record: record)
        #expect(before.skills.first?.reach["claude"]?.gets == true)

        PersonalDotAgents.reconcile(home: home, installed: ["claude"], record: &record)
        try fileManager.removeItem(at: home.appending(path: ".claude/skills/dataviz"))
        let after = PersonalDotAgents.snapshot(home: home, installed: ["claude"], record: record)
        #expect(after.skills.first?.reach["claude"] == .leftOut("its link in ~/.claude/skills was removed"))
    }

    @Test func otherFilesAreSorted() throws {
        let kinds = snapshot(try fullHome()).otherFiles.map { "\($0.kind.rawValue) \($0.path)" }
        #expect(kinds == ["git .git", "managed .skill-lock.json", "unused README.md", "persona personas/reviewer.md"])
    }

    @Test func aProblemFileIsNeedsALookAndNoServers() throws {
        let home = try home()
        try write("{\"mcpServers\": {\"a\": {\"command\": \"\(secret)\",,}}}", ".agents/mcp.json", in: home)
        let shot = snapshot(home)
        #expect(shot.mcp.servers.isEmpty)
        #expect(shot.mcp.problem?.line == 1)
        #expect(shot.needsALook.contains { $0.kind == .problem })
        #expect(!String(decoding: try JSONEncoder().encode(shot), as: UTF8.self).contains(secret))
    }

    // FR-023
    @Test func noValueFromMcpJsonIsInTheResult() throws {
        let shot = snapshot(try fullHome())
        let encoded = String(decoding: try JSONEncoder().encode(shot), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains("SENTINEL"))
        let github = try #require(shot.mcp.servers.first { $0.name == "github" })
        #expect(github.summary == "npx -y server-github ••••")
        #expect(shot.mcp.servers.first { $0.name == "linear" }?.summary == "https://mcp.linear.app/mcp")
    }

    @Test func noHomeIsNotLaidOutAndEmpty() {
        let shot = PersonalDotAgents.snapshot(home: nil, installed: ["claude"], record: .init(home: ""))
        #expect(!shot.laidOut)
        #expect(shot.runtimes.isEmpty && shot.skills.isEmpty && shot.mcp.servers.isEmpty && shot.plugins.isEmpty)
    }

    @Test func theWireShapeIsTheContracts() throws {
        let reach: [String: DaemonAPI.Reach] = ["a": .gets("x"), "b": .unchecked(nil), "c": .unchecked("n")]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reach)) as? [String: Any]
        #expect((json?["a"] as? [String: String]) == ["gets": "x"])
        #expect(json?["b"] as? String == "unchecked")
        #expect(try JSONDecoder().decode([String: DaemonAPI.Reach].self, from: JSONEncoder().encode(reach)) == reach)
        let source = try JSONEncoder().encode([DaemonAPI.Skill.Source.personal, .plugin("p")])
        #expect(String(decoding: source, as: UTF8.self) == #"["personal",{"plugin":"p"}]"#)
    }

    // T039: a person's (the window's, and since #111 a paired client's), and nobody else's.
    @Test func onlyAPersonMayAsk() async throws {
        #expect(ConnectionRole.control.allows(DaemonAPI.Method.personalShared))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.personalShared))
        for role in [ConnectionRole.agent, .pairing, .stranger] {
            #expect(!role.allows(DaemonAPI.Method.personalShared), "\(role)")
        }
        let root = try home()
        var locations = StoreLocations(root: root.appending(path: "root"))
        locations.personalHome = try fullHome()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        let answer = await core.handle(method: DaemonAPI.Method.personalShared, params: nil)
        let shot = try answer.get().decode(DaemonAPI.SharedSnapshot.self)
        #expect(shot.laidOut)
        #expect(shot.skills.contains { $0.name == "dataviz" })
    }
}
