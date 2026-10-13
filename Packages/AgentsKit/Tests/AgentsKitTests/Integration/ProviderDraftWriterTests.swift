import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The agent that writes a provider's map (#858): started with a purpose, it has only the
/// writer's tools and none of its runtime's, works in a folder of its own, is in no list a
/// client sees, and its tools go to the control plane with its id.
@Suite("The writer agent", .timeLimit(.minutes(1)))
struct ProviderDraftWriterTests {
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [DaemonAPI.HostProviderDraftCall] = []
        func add(_ params: JSONValue) {
            if let call = try? params.decode(DaemonAPI.HostProviderDraftCall.self) { lock.withLock { calls.append(call) } }
        }
        var all: [DaemonAPI.HostProviderDraftCall] { lock.withLock { calls } }
    }

    struct Made {
        let core: DaemonCore
        let launcher: FakeLauncher
        let root: URL
        let work: URL
    }

    private func make(turnDelay: Duration = .seconds(20)) async throws -> Made {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWriter-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        script.turnDelay = turnDelay
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        return Made(core: core, launcher: launcher, root: root, work: work)
    }

    @Test func onlyClaudeCanWriteAndItKeepsNoToolOfItsOwn() throws {
        #expect(ToolPolicyCatalog.writerRuntimes == ["claude"])
        let meta = try #require(ToolPolicyCatalog.writerMeta(for: "claude"))
        let options = try #require(meta["claudeCode"]?["options"])
        #expect(options["tools"] == [])
        #expect(options["strictMcpConfig"] == true)
        let denied = options["disallowedTools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for tool in ["Bash", "Read", "Grep", "Glob", "Write", "Edit", "WebFetch", "WebSearch", "Agent", "Task"] {
            #expect(denied.contains(tool), "\(tool) is denied")
        }
        for runtime in RuntimeCatalog.builtIn where runtime.id != "claude" {
            #expect(ToolPolicyCatalog.writerMeta(for: runtime.id) == nil)
        }
    }

    @Test func theWritersServerOffersItsToolsAndNothingElse() async throws {
        final class Called: @unchecked Sendable {
            var tool: String?
        }
        let called = Called()
        let service = AppService(transport: nil, writer: true, draft: { tool, _ in
            called.tool = tool
            return .shown("Passed: listed 2.")
        })
        let listed = try await service.handle(method: "tools/list", params: nil).get()
        #expect(listed["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == AppTool.writerTools)
        let shown = await service.handle(method: "tools/call", params: ["name": "mcp__agents__show_file", "arguments": ["path": "/etc/hosts"]])
        #expect((try? shown.get()) == nil)
        let checked = try await service.handle(method: "tools/call", params: ["name": "mcp__agents__check_draft", "arguments": ["draft": [:]]]).get()
        #expect(called.tool == AppTool.checkDraft)
        #expect(checked["content"]?.arrayValue?.first?["text"]?.stringValue == "Passed: listed 2.")
        // And an ordinary agent's server offers none of them.
        let ordinary = AppService.tools().compactMap { $0["name"]?.stringValue }
        for tool in AppTool.writerTools { #expect(!ordinary.contains(tool)) }
    }

    @Test func aWriterRunsAloneWithItsToolsAndIsInNoList() async throws {
        let made = try await make()
        let core = made.core
        let draft = UUID()
        // A person's agent, for the lists to have something in them.
        _ = try await core.start(.init(runtimeID: "claude", cwd: made.work, prompt: "hello"))
        let id = try await core.start(.init(runtimeID: "claude", cwd: made.work, prompt: "write a map",
                                            mcpServers: [MCPServer(name: "other", transport: .http(url: "https://x.example/mcp", headers: [:]))],
                                            purpose: .providerDraft(id: draft)))
        let agent = try #require(await core.agent(id))
        #expect(agent.purpose == .providerDraft(id: draft))
        #expect(agent.cwd.path.contains("/provider-drafts/"))
        #expect(agent.cwd.lastPathComponent == draft.uuidString.lowercased())
        #expect(agent.mcpServers.isEmpty)

        let fake = try #require(await eventuallySome("the writer's session") { () async -> FakeACPAgent? in
            for each in made.launcher.allAgents where await each.sessionID == agent.runtimeSessionID { return each }
            return nil
        })
        let tools = await eventuallySome("the writer listed its tools") { await fake.newSessionAppTools } ?? []
        #expect(tools == AppTool.writerTools)
        let params = try #require(await fake.newSessionParams)
        #expect(params["mcpServers"]?.arrayValue?.count == 1)
        #expect(params["_meta"]?["claudeCode"]?["options"]?["tools"] == [])

        let listed = await core.listAgents(.init())
        #expect(!listed.contains { $0.id == id })
        #expect(listed.count == 1)
        #expect(await core.listAgents(.init(agentID: id)).map(\.id) == [id])
        #expect(!(await core.allProjects()).contains { $0.folder.path.contains("provider-drafts") })
    }

    @Test func itsToolsGoToTheControlPlaneWithItsIdAndNoOneElsesDo() async throws {
        let made = try await make()
        let core = made.core
        let draft = UUID()
        let writer = try await core.start(.init(runtimeID: "claude", cwd: made.work, prompt: "write", purpose: .providerDraft(id: draft)))
        let person = try await core.start(.init(runtimeID: "claude", cwd: made.work, prompt: "hello"))
        await core.bindAppToken("writer-token", to: writer)
        await core.bindAppToken("person-token", to: person)
        let asked = Asked()
        await core.deliverControlAsks { method, params in
            #expect(method == DaemonAPI.Method.hostProviderDraft)
            asked.add(params)
            return ["note": "Passed: listed 2."]
        }
        let note = try await core.providerDraftTool(.init(token: "writer-token", tool: AppTool.checkDraft, arguments: ["draft": [:]]))
        #expect(note == "Passed: listed 2.")
        #expect(asked.all.first == .init(agentID: writer, draft: draft, tool: AppTool.checkDraft, arguments: ["draft": [:]]))
        await #expect(throws: JSONRPCError.self) {
            try await core.providerDraftTool(.init(token: "person-token", tool: AppTool.checkDraft))
        }
        #expect(asked.all.count == 1)
    }

    @Test func aWriterWhoseTurnEndsIsArchivedAndTheControlPlaneTold() async throws {
        let made = try await make(turnDelay: .milliseconds(50))
        let core = made.core
        let asked = Asked()
        await core.deliverControlAsks { _, params in
            asked.add(params)
            return [:]
        }
        let draft = UUID()
        let id = try await core.start(.init(runtimeID: "claude", cwd: made.work, prompt: "write", purpose: .providerDraft(id: draft)))
        await eventually("the control plane was told") { asked.all.contains { $0.tool == "turn_ended" && $0.draft == draft } }
        await eventually("it was archived") { await core.agent(id)?.state == .archived }
        let folder = try #require(await core.agent(id)?.cwd)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!(await core.listAgents(.init(includeArchived: true))).contains { $0.id == id })
    }

    @Test func aRuntimeThatCantWriteIsRefused() async throws {
        let made = try await make()
        await #expect(throws: JSONRPCError.self) {
            try await made.core.start(.init(runtimeID: "cursor", cwd: made.work, prompt: "write", purpose: .providerDraft(id: UUID())))
        }
        #expect(made.launcher.launchCount == 0)
    }
}
