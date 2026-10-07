import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A person's own MCP server's views (#191): written into the chat from the runtime's
/// call, drawn only after Show, its calls passed only to its own server, and pinned.
@Suite("Third-party views", .timeLimit(.minutes(1)))
struct ThirdPartyViewsTests {
    struct Setup {
        var core: DaemonCore
        var project: URL
        var agentID: UUID
        var stand: ViewsServerStandIn
    }

    private func setUp(_ servers: String = #"{"mcpServers":{"kite":{"type":"http","url":"https://kite.example/mcp"},"local":{"command":"node","args":["x.js"]}}}"#)
        async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsViews-\(UUID().uuidString)", isDirectory: true)
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: project.appending(path: ".agents"), withIntermediateDirectories: true)
        try Data(servers.utf8).write(to: project.appending(path: ".agents/mcp.json"))
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let store = try AgentStore(locations: locations)
        let agent = Agent(runtimeID: "codex", cwd: project, title: "Lead", state: .finished, endedReason: .endTurn)
        try await store.save(agent)
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        _ = try await core.addProject(project)
        let stand = ViewsServerStandIn()
        await core.setViewClients(MCPClientPool(http: stand.send))
        return Setup(core: core, project: project, agentID: agent.id, stand: stand)
    }

    private func refusal(_ body: () async throws -> Any) async -> JSONRPCError? {
        do { _ = try await body(); return nil } catch let error as JSONRPCError { return error } catch {
            return JSONRPCError(code: 0, message: "\(error)")
        }
    }

    private func views(_ s: Setup) async throws -> [AppViewCall] {
        let page = try await s.core.transcript(.init(agentID: s.agentID, limit: 100))
        return page.entries.compactMap { if case .appView(let call) = $0.kind { call } else { nil } }
    }

    /// The runtime's call, as Codex tells it, and the view it leaves in the chat.
    private func codexCall(_ s: Setup, id: String = "exec-1", waitForStart: Bool = false) async throws -> AppViewCall {
        await s.core.noteThirdPartyToolCall(.toolCall(ToolCall(
            toolCallID: id, title: "mcp.kite.weather", status: "in_progress",
            rawInput: ["server": "kite", "tool": "weather", "arguments": ["city": "Paris"]])), agentID: s.agentID)
        if waitForStart {
            for _ in 0..<100 where try await views(s).last?.state != .running { try await Task.sleep(for: .milliseconds(20)) }
        }
        await s.core.noteThirdPartyToolCall(.toolCallUpdate(ToolCall(
            toolCallID: id, title: "Tool call", status: "completed",
            rawOutput: ["result": ["content": [["type": "text", "text": "Paris 21C"]], "structuredContent": ["c": 21]]])),
            agentID: s.agentID)
        for _ in 0..<100 {
            if let done = try await views(s).last, done.state == .done { return done }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    @Test func aCallOfAToolWithAViewIsWrittenRunningThenAnswered() async throws {
        let s = try await setUp()
        // The first call reads the server's catalog; one answered meanwhile is written once, done.
        _ = try await codexCall(s)
        #expect(try await views(s).map(\.state) == [.done])
        // With the catalog kept, a call is shown as it starts and again when answered.
        let view = try await codexCall(s, id: "exec-2", waitForStart: true)
        let all = try await views(s).dropFirst()
        #expect(all.map(\.state) == [.running, .done])
        #expect(Set(all.map(\.id)).count == 1)
        #expect(s.stand.connections == 1, "the catalog was read once")
        #expect(view.server == "kite" && view.tool == "weather" && view.resourceURI == "ui://kite/weather")
        #expect(view.arguments?["city"]?.stringValue == "Paris")
        #expect(view.result?["structuredContent"]?["c"]?.intValue == 21)
        #expect(view.pinnable == true)
    }

    @Test func aTextOnlyAnswerOfAJoinedTitleIsNotDrawnInline() async throws {
        let s = try await setUp()
        await s.core.noteThirdPartyToolCall(.toolCallUpdate(ToolCall(
            toolCallID: "c1", title: "kite_weather", status: "completed", rawInput: ["city": "Paris"],
            rawOutput: ["output": "Paris 21C"])), agentID: s.agentID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await views(s).isEmpty)
    }

    @Test func theViewAsksForShowFirstAndIsDrawnUnderItsDeclaredPolicy() async throws {
        let s = try await setUp()
        let view = try await codexCall(s)
        let read = DaemonAPI.ViewReadRequest(agentID: s.agentID, uri: view.resourceURI, server: "kite")
        let asked = try #require(await refusal { try await s.core.readView(read) })
        #expect(asked.code == DaemonAPI.Failure.viewNeedsShow)
        let ask = try #require(asked.data).decode(DaemonAPI.ViewAsk.self)
        #expect(ask.isNew && ask.server == "kite")

        try await s.core.answerViewShow(.init(agentID: s.agentID, server: "kite", uri: ask.uri, hash: ask.hash, show: true))
        let resource = try await s.core.readView(read)
        #expect(resource.html == "<p>weather</p>")
        #expect(resource.policy.header.contains("https://api.kite.example"))
        #expect(!resource.policy.header.contains("example.com "))

        // A changed view asks again.
        s.stand.changeHTML("<p>new</p>")
        let again = try #require(await refusal { try await s.core.readView(read) })
        #expect(again.code == DaemonAPI.Failure.viewNeedsShow)
        #expect(try #require(again.data).decode(DaemonAPI.ViewAsk.self).isNew == false)

        // Don't Show is kept, and Ask Again forgets it.
        let changed = try #require(again.data).decode(DaemonAPI.ViewAsk.self)
        try await s.core.answerViewShow(.init(agentID: s.agentID, server: "kite", uri: changed.uri, hash: changed.hash, show: false))
        let hidden = try #require(await refusal { try await s.core.readView(read) })
        #expect(hidden.code == DaemonAPI.Failure.viewRefused)
        try await s.core.forgetViewAnswers(.init(destination: .project(folder: s.project.path), name: "kite"))
        #expect(await refusal { try await s.core.readView(read) }?.code == DaemonAPI.Failure.viewNeedsShow)
    }

    @Test func aViewCallsOnlyItsOwnServersToolsThatAViewMayCall() async throws {
        let s = try await setUp()
        let view = try await codexCall(s)
        func call(_ name: String, server: String?, viewID: UUID) async throws -> JSONValue {
            try await s.core.callFromView(.init(agentID: s.agentID, viewID: viewID, name: name, server: server))
        }
        let answered = try await call("refresh", server: "kite", viewID: view.id)
        #expect(answered["structuredContent"]?["called"]?.stringValue == "refresh")
        // Only the model may call it.
        #expect(await refusal { try await call("secret_model_tool", server: "kite", viewID: view.id) }?.message
            .contains("may not call") == true)
        // Another view (the app's own test view, say) naming kite is refused.
        #expect(await refusal { try await call("refresh", server: "kite", viewID: UUID()) }?.message
            .contains("only its own server") == true)
        // kite's view naming the app's own tools is refused.
        #expect(await refusal { try await call("test_view_count", server: nil, viewID: view.id) }?.message
            .contains("only its own server") == true)
        #expect(!s.stand.seen.contains("tools/call") || s.stand.seen.filter { $0 == "tools/call" }.count == 1)
    }

    @Test func aStdioServersViewsAreNotShownYet() async throws {
        let s = try await setUp()
        let read = DaemonAPI.ViewReadRequest(agentID: s.agentID, uri: "ui://local/x", server: "local")
        let refused = try #require(await refusal { try await s.core.readView(read) })
        #expect(refused.message.contains("Views from local servers aren't shown yet"))
        #expect(await s.core.viewPinMissing(ViewPin(server: "local", uri: "ui://local/x", tool: "x"), project: s.project)
            == PinMissing.localServer)
    }

    @Test func aServerWaitingForApprovalShowsNothing() async throws {
        let s = try await setUp()
        await s.core.beginMCPApprovalsIfNeeded()
        // A server added after approval began waits.
        try Data(#"{"mcpServers":{"kite":{"type":"http","url":"https://other.example/mcp"}}}"#.utf8)
            .write(to: s.project.appending(path: ".agents/mcp.json"))
        let read = DaemonAPI.ViewReadRequest(agentID: s.agentID, uri: "ui://kite/weather", server: "kite")
        #expect(await refusal { try await s.core.readView(read) }?.message.contains("waiting for approval") == true)
        #expect(s.stand.connections == 0)
    }

    @Test func aViewIsPinnedAndFedByItsReadOnlyTool() async throws {
        let s = try await setUp()
        let view = try await codexCall(s)
        let pinned = try await s.core.pinByPerson(.init(folder: s.project, view: view.viewPin, title: "Weather"))
        let pin = try #require(pinned.first { $0.view?.server == "kite" })
        #expect(!pin.missing)
        let place = UUID()
        let fed = try await s.core.callFromView(.init(agentID: place, viewID: place, name: "weather",
                                                      arguments: ["city": "Paris"], project: s.project, feed: true, server: "kite"))
        #expect(fed["structuredContent"]?["called"]?.stringValue == "weather")
        #expect(await refusal {
            try await s.core.callFromView(.init(agentID: place, viewID: place, name: "refresh", project: s.project,
                                                feed: true, server: "kite"))
        }?.message.contains("not marked read-only") == true)
        // Another server, not pinned in the project, is not reached from a pinned page.
        #expect(await refusal {
            try await s.core.callFromView(.init(agentID: place, viewID: place, name: "x", project: s.project, server: "otter"))
        }?.message.contains("only its own server") == true)
    }
}
