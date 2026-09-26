import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The person's plugins in `~/.agents/plugins`, handed to each runtime as research R12
/// settles: Claude and Grok in `_meta`, Grok's servers in `mcpServers`, Gemini by a link,
/// Codex by its own `plugin add` whenever a plugin changes.
@Suite("Personal plugins", .timeLimit(.minutes(1)))
struct PersonalPluginsTests {
    private let fileManager = FileManager.default

    private func folders() throws -> (locations: StoreLocations, home: URL, work: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersonalPluginsTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let home = base.appending(path: "home")
        let work = base.appending(path: "work")
        for url in [base.appending(path: "root"), home.appending(path: ".agents"), work] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var locations = StoreLocations(root: base.appending(path: "root"))
        locations.personalHome = home
        return (locations, home, work)
    }

    private func core(_ locations: StoreLocations, _ launcher: FakeLauncher = FakeLauncher()) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    /// A plugin in `<under>/.agents/plugins/<name>`: a manifest, a skill, and, when asked,
    /// one stdio MCP server that names its own folder.
    @discardableResult
    private func plugin(_ name: String, under folder: URL, server: String? = nil) throws -> URL {
        let url = folder.appending(path: ".agents/plugins/\(name)")
        try fileManager.createDirectory(at: url.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.appending(path: "skills/\(name)-skill"), withIntermediateDirectories: true)
        try "{\"name\":\"\(name)\",\"version\":\"1.0.0\"}".write(to: url.appending(path: ".claude-plugin/plugin.json"),
                                                               atomically: true, encoding: .utf8)
        try "---\nname: \(name)-skill\n---\n".write(to: url.appending(path: "skills/\(name)-skill/SKILL.md"),
                                                    atomically: true, encoding: .utf8)
        if let server {
            try "{\"mcpServers\":{\"\(server)\":{\"command\":\"${CLAUDE_PLUGIN_ROOT}/run\",\"args\":[\"x\"]}}}"
                .write(to: url.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        }
        return url
    }

    private func reconcile(_ home: URL, installed: Set<String>, record: inout PersonalDotAgents.Record) {
        PersonalDotAgents.reconcile(home: home, installed: installed, record: &record)
    }

    // MARK: Claude and Grok

    @Test func claudeGetsTheProjectsPluginsThenThePersonsBesideItsScoping() async throws {
        let (locations, home, work) = try folders()
        let project = try plugin("proj", under: work)
        let personal = try plugin("mine", under: home)
        let core = try core(locations)

        let meta = await core.sessionMeta(runtimeID: "claude", cwd: work)
        let options = meta?["claudeCode"]?["options"]
        let paths = options?["plugins"]?.arrayValue?.compactMap { $0["path"]?.stringValue }
        #expect(paths == [project.path, personal.path])
        #expect(options?["disallowedTools"]?.arrayValue?.isEmpty == false)
    }

    @Test func grokGetsBothFoldersAndThePluginsServers() async throws {
        let (locations, home, work) = try folders()
        let project = try plugin("proj", under: work)
        let personal = try plugin("mine", under: home, server: "plover-mcp")
        let core = try core(locations)

        let meta = await core.sessionMeta(runtimeID: "grok", cwd: work)
        #expect(meta?["pluginDirs"]?.arrayValue?.compactMap(\.stringValue) == [project.path, personal.path])

        let grok = await core.sessionServers(runtimeID: "grok", chosen: [], token: "t", managesAgents: true,
                                             cwd: work, capabilities: nil)
        #expect(grok.map(\.name) == ["agents", "plover-mcp"])
        #expect(grok.last?.transport == .stdio(command: "\(personal.path)/run", args: ["x"], env: [:]))

        for runtime in ["claude", "codex", "cursor"] {
            let servers = await core.sessionServers(runtimeID: runtime, chosen: [], token: "t", managesAgents: true,
                                                    cwd: work, capabilities: nil)
            #expect(servers.map(\.name) == ["agents"], "\(runtime)")
        }
    }

    @Test func aPluginsContentsAreCounted() throws {
        let (_, home, _) = try folders()
        let url = try plugin("mine", under: home, server: "plover-mcp")
        try fileManager.createDirectory(at: url.appending(path: "commands"), withIntermediateDirectories: true)
        try "Say hi.".write(to: url.appending(path: "commands/hi.md"), atomically: true, encoding: .utf8)

        let info = PersonalDotAgents.pluginInfo(url)
        #expect(info.name == "mine")
        #expect(info.version == "1.0.0")
        #expect(info.contents.skills == 1)
        #expect(info.contents.commands == 1)
        #expect(info.contents.mcpServers == 1)
    }

    // MARK: Gemini

    @Test func geminiGetsARecordedRelativeLinkThatStaysGoneOnceDeleted() throws {
        let (_, home, _) = try folders()
        try plugin("mine", under: home)
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, installed: ["gemini"], record: &record)
        let link = home.appending(path: ".gemini/extensions/mine")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: link.path) == "../../.agents/plugins/mine")
        #expect(record.links[".gemini/extensions/mine"] == "../../.agents/plugins/mine")

        try fileManager.removeItem(at: link)
        reconcile(home, installed: ["gemini"], record: &record)
        #expect(!DotAgents.exists(link))
    }

    @Test func noGeminiNoLink() throws {
        let (_, home, _) = try folders()
        try plugin("mine", under: home)
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, installed: ["claude", "codex"], record: &record)
        #expect(!DotAgents.exists(home.appending(path: ".gemini")))
    }

    @Test func aPluginThatGoesTakesItsGeminiLinkWithIt() throws {
        let (_, home, _) = try folders()
        let url = try plugin("mine", under: home)
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, installed: ["gemini"], record: &record)

        try fileManager.removeItem(at: url)
        reconcile(home, installed: ["gemini"], record: &record)

        #expect(!DotAgents.exists(home.appending(path: ".gemini/extensions/mine")))
        #expect(record.links[".gemini/extensions/mine"] == nil)
    }

    @Test func theGeminiManifestIsWrittenOnceAndNeverOverwritten() throws {
        let (_, home, _) = try folders()
        let written = try plugin("mine", under: home, server: "plover-mcp")
        let theirs = try plugin("theirs", under: home)
        let own = Data("{\"name\":\"their-own\"}".utf8)
        try own.write(to: theirs.appending(path: "gemini-extension.json"))
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, installed: ["gemini"], record: &record)
        let manifest = DotAgents.json(at: written.appending(path: "gemini-extension.json"))
        #expect(manifest?["name"] as? String == "mine")
        #expect((manifest?["mcpServers"] as? [String: Any])?["plover-mcp"] != nil)
        #expect(try Data(contentsOf: theirs.appending(path: "gemini-extension.json")) == own)
    }

    // MARK: Codex

    /// A `codex` that writes each command line it is given to `calls`, and fails when
    /// `fails` exists.
    private func fakeCodex(in folder: URL) throws -> (codex: URL, calls: URL, fails: URL) {
        let codex = folder.appending(path: "codex")
        let calls = folder.appending(path: "calls")
        let fails = folder.appending(path: "fails")
        try """
            #!/bin/sh
            echo "$HOME $*" >> '\(calls.path)'
            [ -e '\(fails.path)' ] && exit 3
            exit 0
            """.write(to: codex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        return (codex, calls, fails)
    }

    private func calls(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func codexIsGivenAnIndexAndAddsOnlyWhatChanged() async throws {
        let (locations, home, _) = try folders()
        let mine = try plugin("mine", under: home)
        let fake = try fakeCodex(in: locations.root)
        let core = try core(locations)
        await core.useCodexCLI(fake.codex)

        await core.syncCodexPlugins()
        let index = try #require(DotAgents.json(at: home.appending(path: ".agents/plugins/marketplace.json")))
        #expect(index["name"] as? String == "agents-personal")
        #expect((index["metadata"] as? [String: Any])?["description"] as? String == DotAgents.indexMarker)
        #expect((index["plugins"] as? [[String: Any]])?.first?["source"] as? String == "./.agents/plugins/mine")
        #expect(calls(fake.calls) == ["\(home.path) plugin add mine@agents-personal"])
        let recorded = PersonalDotAgents.Record.load(from: locations.personalLayout, home: home).codexPlugins["mine"]
        #expect(recorded == PersonalDotAgents.fingerprint(mine))

        // Nothing changed: nothing run.
        await core.syncCodexPlugins(before: "codex")
        #expect(calls(fake.calls).count == 1)

        // A file touched: added again.
        let skill = mine.appending(path: "skills/mine-skill/SKILL.md")
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: skill.path)
        await core.syncCodexPlugins(before: "codex")
        #expect(calls(fake.calls).last == "\(home.path) plugin add mine@agents-personal")
        #expect(calls(fake.calls).count == 2)

        // Only before a Codex session.
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: skill.path)
        await core.syncCodexPlugins(before: "claude")
        #expect(calls(fake.calls).count == 2)

        // Gone: removed, and forgotten.
        try fileManager.removeItem(at: mine)
        await core.syncCodexPlugins(before: "codex")
        #expect(calls(fake.calls).last == "\(home.path) plugin remove mine@agents-personal")
        #expect(PersonalDotAgents.Record.load(from: locations.personalLayout, home: home).codexPlugins.isEmpty)
    }

    @Test func anIndexThePersonWroteIsNeverTouched() async throws {
        let (locations, home, _) = try folders()
        try plugin("mine", under: home)
        let fake = try fakeCodex(in: locations.root)
        let index = home.appending(path: ".agents/plugins/marketplace.json")
        let theirs = Data("{\"name\":\"their-own\",\"plugins\":[]}".utf8)
        try theirs.write(to: index)
        let core = try core(locations)
        await core.useCodexCLI(fake.codex)

        await core.syncCodexPlugins()

        #expect(try Data(contentsOf: index) == theirs)
        #expect(calls(fake.calls).isEmpty)
    }

    // FR-012
    @Test func aFailingCodexIsLoggedAndTheAgentStillStarts() async throws {
        let (locations, home, work) = try folders()
        try plugin("mine", under: home)
        let fake = try fakeCodex(in: locations.root)
        try Data().write(to: fake.fails)
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)
        await core.useCodexCLI(fake.codex)

        let id = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "go"))
        _ = await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        #expect(await core.agent(id) != nil)
        #expect(calls(fake.calls) == ["\(home.path) plugin add mine@agents-personal"])
        // Not recorded, so the next Codex start tries again.
        #expect(PersonalDotAgents.Record.load(from: locations.personalLayout, home: home).codexPlugins.isEmpty)
    }
}
