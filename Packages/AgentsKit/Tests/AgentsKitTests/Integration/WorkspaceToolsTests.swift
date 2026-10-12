import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Agents use workspaces (#691 US6): the five tools are offered, list and start go to the
/// control plane as asked, and make and delete ask the person on the card first, doing
/// nothing without their yes (FR-051).
@Suite("Workspace tools", .timeLimit(.minutes(1)))
struct WorkspaceToolsTests {
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [DaemonAPI.HostWorkspaceCall] = []
        func add(_ params: JSONValue) {
            if let call = try? params.decode(DaemonAPI.HostWorkspaceCall.self) { lock.withLock { calls.append(call) } }
        }
        var all: [DaemonAPI.HostWorkspaceCall] { lock.withLock { calls } }
    }

    /// A core with an agent mid-turn, bound to `token`, whose control plane is `answer`.
    private func core(token: String, asked: Asked,
                      answer: @escaping @Sendable (DaemonAPI.HostWorkspaceCall) -> JSONValue) async throws -> DaemonCore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkspaceTools-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(20)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script, capabilities: .app))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await core.bindAppToken(token, to: id)
        await eventually("the turn is running") { await core.turnTasks[id] != nil }
        await core.deliverControlAsks { method, params in
            #expect(method == DaemonAPI.Method.hostWorkspaces)
            asked.add(params)
            let call = try params.decode(DaemonAPI.HostWorkspaceCall.self)
            return answer(call)
        }
        return core
    }

    @Test func theFiveAreOfferedToEveryAgent() {
        for manages in [true, false] {
            let names = AppService.tools(managesAgents: manages).compactMap { $0["name"]?.stringValue }
            for tool in AppTool.workspaceTools { #expect(names.contains(tool)) }
        }
        #expect(AppTool.isServedByTheApp("mcp__agents__make_workspace"))
    }

    @Test func callsAreReadWithTheirArguments() throws {
        let start = try #require(AppService.workspaceCall(named: "mcp__agents__start_workspace", ["host": "devbox"]))
        #expect(try start.get().action == .start)
        #expect(try start.get().host == "devbox")
        let missing = try #require(AppService.workspaceCall(named: "stop_workspace", [:]))
        #expect(throws: (any Error).self) { try missing.get() }
        let make = try #require(AppService.workspaceCall(named: "make_workspace",
                                                          ["provider": "DigitalOcean", "name": "b-2", "options": ["size": "big"]]))
        #expect(try make.get().options == ["size": "big"])
        #expect(AppService.workspaceCall(named: "list_sessions", nil) == nil)
    }

    @Test func listAndStartGoAsAsked() async throws {
        let asked = Asked()
        let core = try await core(token: "t1", asked: asked) { call in
            if call.method == DaemonAPI.Method.workspacesForAgent {
                return (try? JSONValue.encoding(DaemonAPI.AgentWorkspaces(providers: [
                    .init(id: ProviderID(rawValue: "do"), name: "DigitalOcean", canMake: true, canDelete: false,
                          workspaces: [.init(id: "1", name: "devbox", state: "stopped", host: "devbox", hostState: "stopped")]),
                ]))) ?? [:]
            }
            return ["id": "devbox01", "state": "starting"]
        }
        let listed = try await core.workspaceTool(.init(token: "t1", action: .list))
        #expect(listed.contains("devbox: stopped — host devbox, stopped"))
        #expect(listed.contains("can make workspaces"))
        let started = try await core.workspaceTool(.init(token: "t1", action: .start, host: "devbox"))
        #expect(started.contains("server.online"))
        #expect(asked.all.map(\.method) == [DaemonAPI.Method.workspacesForAgent, DaemonAPI.Method.hostsStart])
        #expect(asked.all.last?.params == ["host": "devbox"])
        #expect(asked.all.last?.agent.hasPrefix("Cursor") == true)
    }

    @Test func makeAsksFirstAndMakesNothingWithoutAYes() async throws {
        let asked = Asked()
        let core = try await core(token: "t2", asked: asked) { _ in
            (try? JSONValue.encoding(DaemonAPI.ProviderCreated(
                workspace: .init(id: "ws-b", name: "b-2", state: "starting"), joining: true))) ?? [:]
        }
        let saidNo = Task { try await core.workspaceTool(.init(token: "t2", action: .make, provider: "DigitalOcean", name: "b-2")) }
        await eventually("the question is on the card") { await !core.pendingElicitations().isEmpty }
        #expect(asked.all.isEmpty)
        let first = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: first.id, action: .accept, content: ["go": "no"]))
        #expect(try await saidNo.value.hasPrefix("Nothing was made"))
        #expect(asked.all.isEmpty)

        let saidYes = Task { try await core.workspaceTool(.init(token: "t2", action: .make, provider: "DigitalOcean", name: "b-2",
                                                                options: ["size": "big"])) }
        await eventually("asked again") { await !core.pendingElicitations().isEmpty }
        let second = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: second.id, action: .accept, content: ["go": "yes"]))
        #expect(try await saidYes.value.hasPrefix("Made b-2"))
        #expect(asked.all.map(\.method) == [DaemonAPI.Method.providersCreate])
        #expect(asked.all.first?.params["options"] == ["size": "big"])
    }

    @Test func deleteAsksFirstToo() async throws {
        let asked = Asked()
        let core = try await core(token: "t3", asked: asked) { _ in [:] }
        let skipped = Task { try await core.workspaceTool(.init(token: "t3", action: .delete, host: "devbox")) }
        await eventually("the question is on the card") { await !core.pendingElicitations().isEmpty }
        let form = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: form.id, action: .decline))
        #expect(try await skipped.value.hasPrefix("Nothing was deleted"))
        #expect(asked.all.isEmpty)
    }

    @Test func offAControlPlaneThereAreNoWorkspaces() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentsWorkspaceTools-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: .init(), capabilities: .app))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await core.bindAppToken("t4", to: id)
        await #expect(throws: JSONRPCError.self) { _ = try await core.workspaceTool(.init(token: "t4", action: .list)) }
    }
}
