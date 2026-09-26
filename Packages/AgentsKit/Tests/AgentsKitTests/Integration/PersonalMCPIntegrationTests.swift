import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `~/.agents/mcp.json` reaching the sessions the daemon makes (054, Story 6, research R10):
/// read fresh for each one, never kept on the agent, and never written anywhere else.
@Suite("Personal MCP servers, through the daemon", .timeLimit(.minutes(1)))
struct PersonalMCPIntegrationTests {
    private let fileManager = FileManager.default
    private let secret = "SENTINEL-9b1e-never-anywhere"

    private func folders() throws -> (locations: StoreLocations, home: URL, work: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersonalMCPIntegrationTests-\(UUID().uuidString)", isDirectory: true)
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

    private func core(_ locations: StoreLocations, _ launcher: FakeLauncher) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    private func write(_ text: String, to home: URL) throws {
        try text.write(to: PersonalDotAgents.mcpURL(home: home), atomically: true, encoding: .utf8)
    }

    private func names(_ params: JSONValue?) -> [String] {
        params?["mcpServers"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(5), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if let agent = await core.agent(id), !agent.state.hasTurnInFlight,
               agent.queuedPrompts.isEmpty, await core.live[id] == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // Story 6 scenario 1
    @Test func aNewAgentIsGivenThePersonsServers() async throws {
        let (locations, home, work) = try folders()
        try write(#"{"mcpServers": {"heron": {"command": "heron-mcp", "args": ["--x"]}}}"#, to: home)
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)

        let chosen = MCPServer(name: "chosen", transport: .http(url: "https://chosen.example", headers: [:]))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go", mcpServers: [chosen]))
        _ = await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        #expect(names(await launcher.lastAgent?.newSessionParams) == ["agents", "chosen", "heron"])
        // Kept to what the person chose for this agent: the file is read again next time.
        #expect(await core.agent(id)?.mcpServers == [chosen])
    }

    // Story 6 scenario 2, R10
    @Test func anEditReachesAnAgentPickedBackUp() async throws {
        let (locations, home, work) = try folders()
        try write(#"{"mcpServers": {"heron": {"command": "heron-mcp"}}}"#, to: home)
        var script = FakeACPAgent.Script()
        script.supportsResume = true
        let launcher = FakeLauncher(script: script)
        let core = try core(locations, launcher)

        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        try await settle(core, id)
        try write(#"{"mcpServers": {"heron": {"command": "heron-mcp"}, "egret": {"url": "http://127.0.0.1:1/mcp"}}}"#,
                  to: home)
        try await core.prompt(.init(agentID: id, text: "carry on"))
        _ = await eventually("the conversation was picked back up") {
            await launcher.lastAgent?.continuedSessionParams != nil
        }

        #expect(names(await launcher.lastAgent?.continuedSessionParams) == ["agents", "heron", "egret"])
        #expect(await core.agent(id)?.mcpServers == [])
    }

    // R10: a draft made before an edit never heard of the new server.
    @Test func aDraftMadeBeforeAnEditIsNotUsed() async throws {
        let (locations, home, work) = try folders()
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)

        let draft = try await core.options(.init(runtimeID: "cursor", cwd: work))
        try write(#"{"mcpServers": {"heron": {"command": "heron-mcp"}}}"#, to: home)
        _ = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go", draftID: draft.draftID))

        #expect(launcher.launchCount == 2)
        #expect(names(await launcher.lastAgent?.newSessionParams) == ["agents", "heron"])
    }

    @Test func anUnchangedFileKeepsTheDraft() async throws {
        let (locations, home, work) = try folders()
        try write(#"{"mcpServers": {"heron": {"command": "heron-mcp"}}}"#, to: home)
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)

        let draft = try await core.options(.init(runtimeID: "cursor", cwd: work))
        _ = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go", draftID: draft.draftID))

        #expect(launcher.launchCount == 1)
    }

    // Story 6 scenario 4
    @Test func aBrokenFileStillStartsTheAgent() async throws {
        let (locations, home, work) = try folders()
        try write("{\"mcpServers\": {\"heron\": {\"command\": ,}}}", to: home)
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)

        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        _ = await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        #expect(names(await launcher.lastAgent?.newSessionParams) == ["agents"])
        #expect(await core.agent(id) != nil)
    }

    // R9, R11: Copilot takes no stdio server from the client, so each goes through the
    // bridge, the app's own included; an http server goes as it is.
    @Test func aCopilotSessionIsGivenEveryStdioServerThroughTheBridge() async throws {
        let (locations, home, work) = try folders()
        try write(#"{"mcpServers": {"heron": {"command": "heron-mcp"}, "egret": {"url": "https://egret.example/mcp"}}}"#,
                  to: home)
        let launcher = FakeLauncher()
        let core = try core(locations, launcher)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = await eventually("the session was made") { await launcher.lastAgent?.newSessionParams != nil }

        let sent = await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue ?? []
        #expect(sent.compactMap { $0["name"]?.stringValue } == ["agents", "heron", "egret"])
        #expect(sent.allSatisfy { $0["type"]?.stringValue == "http" })
        #expect(sent.prefix(2).allSatisfy { $0["url"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true })
        #expect(sent.last?["url"]?.stringValue == "https://egret.example/mcp")
        #expect(sent.allSatisfy { $0["command"] == nil })

        // Its routes go with its token.
        await core.dropAppTokens(for: id)
        await core.shutDown()
    }

    // FR-023
    @Test func aSecretInTheFileGoesNowhereButTheRuntime() async throws {
        let (locations, home, work) = try folders()
        // The log is one for the whole process, and a `Daemon` made by another suite
        // points it at its own root; what lands here is checked, whatever else lands.
        let log = locations.root.appending(path: "secret-test.log")
        DaemonLog.shared.setDestination(log)
        defer { DaemonLog.shared.setDestination(nil) }
        try write("""
            {"mcpServers": {
              "heron": {"command": "heron-mcp", "args": ["--token=\(secret)"], "env": {"KEY": "\(secret)"}},
              "egret": {"url": "https://e.example/?k=\(secret)", "headers": {"Authorization": "Bearer \(secret)"}},
              "old": {"type": "sse", "url": "https://o.example/\(secret)"}
            }}
            """, to: home)
        var script = FakeACPAgent.Script()
        script.agentCapabilities = ["mcpCapabilities": ["http": true, "sse": false]]
        let launcher = FakeLauncher(script: script)
        let core = try core(locations, launcher)
        let heard = HeardLines()
        await core.setBroadcaster { method, params in heard.add("\(method) \(String(describing: params))") }

        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        try await settle(core, id)

        // It did reach the runtime; that is the one place it goes.
        let sent = String(describing: await launcher.lastAgent?.newSessionParams)
        #expect(sent.contains(secret))

        // And nowhere else: the log, the store, the events, the broadcasts, and what a
        // phone is answered.
        let phone = await core.handle(method: DaemonAPI.Method.agentsList,
                                      params: ["includeArchived": false], role: .device)
        heard.add(String(describing: phone))
        #expect(!heard.all.contains(secret))
        var files = [log, locations.events]
        if let walker = fileManager.enumerator(at: locations.root, includingPropertiesForKeys: nil) {
            files += walker.compactMap { $0 as? URL }
        }
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!text.contains(secret), "found in \(file.lastPathComponent)")
        }
    }
}

private final class HeardLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: String { lock.withLock { lines.joined(separator: "\n") } }
}
