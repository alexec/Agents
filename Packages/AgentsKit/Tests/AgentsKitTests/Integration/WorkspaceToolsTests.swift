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
        let names = AppService.tools().compactMap { $0["name"]?.stringValue }
        for tool in AppTool.workspaceTools { #expect(names.contains(tool)) }
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

    /// DigitalOcean, which makes and deletes, with devbox linked; and Docker, which does neither.
    private static let listing = (try? JSONValue.encoding(DaemonAPI.AgentWorkspaces(providers: [
        .init(id: ProviderID(rawValue: "do"), name: "DigitalOcean", canMake: true, canDelete: true,
              workspaces: [.init(id: "1", name: "devbox", state: "stopped", host: "devbox", hostState: "stopped")]),
        .init(id: ProviderID(rawValue: "dk"), name: "Docker", canMake: false, canDelete: false,
              workspaces: [.init(id: "c1", name: "box", state: "running", host: "box", hostState: "online")]),
    ]))) ?? [:]

    /// The listing for `workspacesForAgent`, and `answer` for everything else.
    private static func listing(else answer: JSONValue) -> @Sendable (DaemonAPI.HostWorkspaceCall) -> JSONValue {
        { $0.method == DaemonAPI.Method.workspacesForAgent ? listing : answer }
    }

    private func changes(_ asked: Asked) -> [String] {
        asked.all.map(\.method).filter { $0 != DaemonAPI.Method.workspacesForAgent }
    }

    @Test func makeAsksFirstAndMakesNothingWithoutAYes() async throws {
        let asked = Asked()
        let created = (try? JSONValue.encoding(DaemonAPI.ProviderCreated(
            workspace: .init(id: "ws-b", name: "b-2", state: "starting"), joining: true))) ?? [:]
        let core = try await core(token: "t2", asked: asked, answer: Self.listing(else: created))
        let saidNo = Task { try await core.workspaceTool(.init(token: "t2", action: .make, provider: "digitalocean", name: "b-2")) }
        await eventually("the question is on the card") { await !core.pendingElicitations().isEmpty }
        #expect(changes(asked).isEmpty)
        let first = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: first.id, action: .accept, content: ["go": "no"]))
        #expect(try await saidNo.value.hasPrefix("Nothing was made"))
        #expect(changes(asked).isEmpty)

        let saidYes = Task { try await core.workspaceTool(.init(token: "t2", action: .make, provider: "DigitalOcean", name: "b-2",
                                                                options: ["size": "big"])) }
        await eventually("asked again") { await !core.pendingElicitations().isEmpty }
        let second = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: second.id, action: .accept, content: ["go": "yes"]))
        #expect(try await saidYes.value.hasPrefix("Made b-2"))
        #expect(changes(asked) == [DaemonAPI.Method.providersCreate])
        #expect(asked.all.last?.params["id"] == "do")
        #expect(asked.all.last?.params["options"] == ["size": "big"])
    }

    @Test func deleteAsksFirstToo() async throws {
        let asked = Asked()
        let core = try await core(token: "t3", asked: asked, answer: Self.listing(else: [:]))
        let skipped = Task { try await core.workspaceTool(.init(token: "t3", action: .delete, host: "DevBox")) }
        await eventually("the question is on the card") { await !core.pendingElicitations().isEmpty }
        let form = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: form.id, action: .decline))
        #expect(try await skipped.value.hasPrefix("Nothing was deleted"))
        #expect(changes(asked).isEmpty)
    }

    /// What can't be done is refused at once, and nobody is asked about it (#855).
    @Test func whatCannotBeDoneIsRefusedWithoutACard() async throws {
        let asked = Asked()
        let core = try await core(token: "t5", asked: asked, answer: Self.listing(else: [:]))
        let refusals: [(DaemonAPI.WorkspaceToolRequest, String)] = [
            (.init(token: "t5", action: .make, provider: "Hetzner", name: "b-2"), "no provider is called Hetzner. There are DigitalOcean, Docker."),
            (.init(token: "t5", action: .make, provider: "Docker", name: "b-2"), "Docker can’t make workspaces."),
            (.init(token: "t5", action: .make, provider: "do", name: "DEVBOX"), "has a workspace called DEVBOX already."),
            (.init(token: "t5", action: .delete, host: "no-such-host"), "no workspace runs a host called no-such-host."),
            (.init(token: "t5", action: .delete, host: "box"), "runs on Docker, which can’t delete workspaces."),
        ]
        for (request, said) in refusals {
            do {
                _ = try await core.workspaceTool(request)
                Issue.record("\(request.action) went ahead")
            } catch let error as JSONRPCError {
                #expect(error.message.contains(said), "\(error.message)")
            }
        }
        #expect(await core.pendingElicitations().isEmpty)
        #expect(changes(asked).isEmpty)
    }

    @Test func withoutProvidersNothingIsMadeOrAsked() async throws {
        let asked = Asked()
        let core = try await core(token: "t6", asked: asked) { _ in
            (try? JSONValue.encoding(DaemonAPI.AgentWorkspaces(providers: []))) ?? [:]
        }
        await #expect(throws: JSONRPCError.self) {
            try await core.workspaceTool(.init(token: "t6", action: .make, provider: "x", name: "y"))
        }
        #expect(await core.pendingElicitations().isEmpty)
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
