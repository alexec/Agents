import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The app's own MCP server, served by the daemon over loopback streamable http (#185):
/// each row of the transport through `answer`, then the whole of it over a real socket.
@Suite("App tools endpoint", .timeLimit(.minutes(1)))
struct AppToolsEndpointTests {
    /// Every call the tools relayed, with what the daemon was asked.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(String, JSONValue)] = []
        var all: [(String, JSONValue)] { lock.withLock { seen } }
        func add(_ method: String, _ params: JSONValue) { lock.withLock { seen.append((method, params)) } }
    }

    private func endpoint(_ calls: Calls = Calls()) -> AppToolsEndpoint {
        AppToolsEndpoint(relay: { method, params in
            calls.add(method, params)
            return .success(["note": "Noted by the daemon."])
        }, log: { _ in })
    }

    private func body(_ method: String, id: Int? = 1, params: JSONValue = [:]) -> Data {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": params]
        if let id { message["id"] = .int(id) }
        return try! JSONEncoder().encode(JSONValue.object(message))
    }

    private func post(_ endpoint: AppToolsEndpoint, _ data: Data, token: String = "tok",
                      session: String? = nil) async -> AppToolsEndpoint.Reply {
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json, text/event-stream"]
        if let session { headers["Mcp-Session-Id"] = session }
        return await endpoint.answer(method: "POST", path: AppToolsEndpoint.path, headers: headers, body: data)
    }

    private func opened(_ endpoint: AppToolsEndpoint) async throws -> String {
        let reply = await post(endpoint, body("initialize", params: ["protocolVersion": "2025-06-18"]))
        #expect(reply.status == 200)
        return try #require(reply.headers["Mcp-Session-Id"])
    }

    private func toolNames(_ reply: AppToolsEndpoint.Reply) throws -> [String] {
        let value = try JSONValue.parse(reply.body)
        return value["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    @Test func aTokenNobodyWasGrantedFindsNothingThere() async {
        let endpoint = endpoint()
        #expect(await post(endpoint, body("initialize")).status == 404)
        let unsigned = await endpoint.answer(method: "POST", path: AppToolsEndpoint.path, headers: [:],
                                             body: body("initialize"))
        #expect(unsigned.status == 404)
    }

    @Test func initializeOpensASessionAndTheToolsAreListedInIt() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        let session = try await opened(endpoint)
        let list = await post(endpoint, body("tools/list", id: 2), session: session)
        #expect(list.status == 200)
        #expect(list.headers["Content-Type"] == "application/json")
        let names = try toolNames(list)
        #expect(names.contains(AppService.finishTurnToolName))
        #expect(names.contains("start_agent"))
        #expect(endpoint.openSessions("tok") == 1)
    }

    @Test func theGrantDecidesTheMenu() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init(managesAgents: false, movesItself: false))
        let session = try await opened(endpoint)
        let names = try toolNames(await post(endpoint, body("tools/list", id: 2), session: session))
        #expect(names.contains(AppService.finishTurnToolName))
        #expect(!names.contains("start_agent"))
    }

    @Test func aToolCallGoesToTheDaemonWithTheToken() async throws {
        let calls = Calls()
        let endpoint = endpoint(calls)
        endpoint.grant("tok", .init())
        let session = try await opened(endpoint)
        let reply = await post(endpoint, body("tools/call", id: 3, params: [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "All of it."],
        ]), session: session)
        #expect(reply.status == 200)
        let call = try #require(calls.all.first)
        #expect(call.0 == DaemonAPI.Method.agentsFinishTurn)
        #expect(call.1["token"]?.stringValue == "tok")
        #expect(String(decoding: reply.body, as: UTF8.self).contains("Noted by the daemon."))
    }

    @Test func aNotificationIsAcceptedWithNothingSaid() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        let session = try await opened(endpoint)
        let reply = await post(endpoint, body("notifications/initialized", id: nil), session: session)
        #expect(reply.status == 202)
        #expect(reply.body.isEmpty)
    }

    @Test func aSessionThisServerDoesNotKnowIsNotFound() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        #expect(await post(endpoint, body("tools/list"), session: "made-up").status == 404)
    }

    @Test func getIsTheSessionsEventStream() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        let session = try await opened(endpoint)
        let auth = ["Authorization": "Bearer tok"]
        let none = await endpoint.answer(method: "GET", path: AppToolsEndpoint.path,
                                         headers: auth.merging(["Accept": "text/event-stream"]) { a, _ in a }, body: Data())
        #expect(none.status == 400, "a stream belongs to a session")
        let stream = await endpoint.answer(method: "GET", path: AppToolsEndpoint.path,
                                           headers: auth.merging(["Accept": "text/event-stream",
                                                                  "Mcp-Session-Id": session]) { a, _ in a },
                                           body: Data())
        #expect(stream.status == 200)
        #expect(stream.stream)
        #expect(stream.headers["Content-Type"] == "text/event-stream")
    }

    @Test func deleteEndsTheSession() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        let session = try await opened(endpoint)
        let ended = await endpoint.answer(method: "DELETE", path: AppToolsEndpoint.path,
                                          headers: ["Authorization": "Bearer tok", "Mcp-Session-Id": session],
                                          body: Data())
        #expect(ended.status == 200)
        #expect(await post(endpoint, body("tools/list"), session: session).status == 404)
    }

    @Test func aRevokedTokenIsRefusedMidSession() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        let session = try await opened(endpoint)
        endpoint.revoke("tok")
        #expect(await post(endpoint, body("tools/list"), session: session).status == 404)
        #expect(endpoint.granted("tok") == nil)
    }

    @Test func otherMethodsPathsAndOriginsAreTurnedAway() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        let put = await endpoint.answer(method: "PUT", path: AppToolsEndpoint.path,
                                        headers: ["Authorization": "Bearer tok"], body: Data())
        #expect(put.status == 405)
        let elsewhere = await endpoint.answer(method: "POST", path: "/mcp/other",
                                              headers: ["Authorization": "Bearer tok"], body: body("initialize"))
        #expect(elsewhere.status == 404)
        let page = await endpoint.answer(method: "POST", path: AppToolsEndpoint.path,
                                         headers: ["Authorization": "Bearer tok", "Origin": "https://example.com"],
                                         body: body("initialize"))
        #expect(page.status == 403)
    }

    @Test func aBatchIsAnsweredAsOne() async throws {
        let endpoint = endpoint()
        endpoint.grant("tok", .init())
        let session = try await opened(endpoint)
        let batch = "[\(String(decoding: body("ping", id: 7), as: UTF8.self)),"
            + "\(String(decoding: body("notifications/initialized", id: nil), as: UTF8.self))]"
        let reply = await post(endpoint, Data(batch.utf8), session: session)
        let answers = try JSONValue.parse(reply.body).arrayValue
        #expect(answers?.count == 1)
        #expect(answers?.first?["id"]?.intValue == 7)
    }

    /// The whole of it as a runtime meets it: loopback only, the bearer, a session id kept
    /// between requests, and keep-alive.
    @Test func overARealSocket() async throws {
        let calls = Calls()
        let endpoint = endpoint(calls)
        defer { endpoint.stop() }
        let port = try await endpoint.start()
        #expect(try await endpoint.start() == port, "one listener")
        endpoint.grant("tok", .init())
        let server = AppToolsEndpoint.server(port: port, token: "tok")
        guard case .http(let address, let headers) = server.transport else {
            Issue.record("not http: \(server.transport)")
            return
        }
        #expect(address == "http://127.0.0.1:\(port)/mcp/agents")

        func send(_ data: Data, session: String?) async throws -> (HTTPURLResponse, Data) {
            var request = URLRequest(url: URL(string: address)!)
            request.httpMethod = "POST"
            request.httpBody = data
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            let (body, response) = try await URLSession.shared.data(for: request)
            return (try #require(response as? HTTPURLResponse), body)
        }
        let (opened, _) = try await send(body("initialize"), session: nil)
        #expect(opened.statusCode == 200)
        let session = try #require(opened.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (listed, list) = try await send(body("tools/list", id: 2), session: session)
        #expect(listed.statusCode == 200)
        #expect(String(decoding: list, as: UTF8.self).contains(AppService.finishTurnToolName))
        let (called, _) = try await send(body("tools/call", id: 3, params: [
            "name": "show_file", "arguments": ["path": "/tmp/README.md"],
        ]), session: session)
        #expect(called.statusCode == 200)
        #expect(calls.all.map(\.0) == [DaemonAPI.Method.agentsShowFile])

        endpoint.revoke("tok")
        let (refused, _) = try await send(body("tools/list", id: 4), session: session)
        #expect(refused.statusCode == 404)
    }
}

/// The daemon's side: what a session is handed, and what happens without http.
@Suite("App tools in sessions")
struct AppToolsInSessionsTests {
    private func core() throws -> DaemonCore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppToolsInSessions-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        return DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                          discovery: .findsEverything, launcher: FakeLauncher())
    }

    @Test func aRuntimeThatTakesNoHTTPIsRefusedRatherThanRunWithoutTheTools() async throws {
        let core = try core()
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.sessionServers(runtimeID: "claude", chosen: [], token: "t", managesAgents: true,
                                              cwd: work, capabilities: ACP.MCPCapabilities(http: false, sse: true))
        }
        #expect(await core.appTools.granted("t") == nil)
    }

    @Test func theAppsServerIsNeverLeftOutOfThePlan() {
        let app = AppToolsEndpoint.server(port: 1, token: "t")
        let plan = SessionServers.plan(app: app, chosen: [], personal: .success([]), http: false, sse: false)
        #expect(plan.servers == [app])
    }

    @Test func endingTheTokenEndsTheGrant() async throws {
        let core = try core()
        _ = try await core.appServer(token: "t", managesAgents: false)
        #expect(await core.appTools.granted("t") == .init(managesAgents: false, movesItself: true))
        await core.bindAppToken("t", to: UUID())
        let id = await core.appTokens["t"]!
        await core.dropAppTokens(for: id)
        #expect(await core.appTools.granted("t") == nil)
        await core.appTools.stop()
    }
}

extension AppToolsInSessionsTests {
    /// A call through the endpoint is an agent's, never the person's: anything outside the
    /// app's tools is refused before it reaches the daemon.
    @Test func onlyTheAppsToolsAreAnsweredThroughTheEndpoint() async throws {
        let core = try core()
        let refused = await core.appToolCall(method: DaemonAPI.Method.daemonQuit, params: [:])
        guard case .failure(let error) = refused else {
            Issue.record("daemon/quit was answered for an agent")
            return
        }
        #expect(error.code == JSONRPCError.methodNotFound)
        let ping = await core.appToolCall(method: DaemonAPI.Method.ping, params: [:])
        guard case .success = ping else {
            Issue.record("ping was refused")
            return
        }
    }
}
