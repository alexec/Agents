import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The app's own MCP client (#191, #305, T042): a real stdio server, and streamable http
/// through a stand-in that answers as a server would.
@Suite("MCP client", .timeLimit(.minutes(1)))
struct MCPClientTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/mcp/echo-server.py").path

    private func echo(_ name: String = "echo") -> MCPServer {
        MCPServer(name: name, transport: .stdio(command: "python3", args: [Self.script], env: [:]))
    }

    private var temp: URL { FileManager.default.temporaryDirectory }

    // MARK: stdio

    @Test func aStdioServerAnswersListsItsToolsAndIsCalled() async throws {
        let client = MCPClient(server: echo(), cwd: temp, log: { _ in })
        let info = try await client.connect()
        #expect(info.name == "echo")
        #expect(info.protocolVersion == "2025-06-18")
        #expect(try await client.listTools().map(\.name) == ["echo"])
        // resources/list is not a method there: none, rather than a failure.
        #expect(try await client.listResources().isEmpty)
        let result = try await client.callTool("echo", arguments: ["say": "hi"])
        #expect(result["echo"]?["say"]?.stringValue == "hi")
        await client.end()
    }

    @Test func aCommandThatIsNotThereSaysSo() async {
        let missing = MCPServer(name: "nope", transport: .stdio(command: "no-such-mcp-\(UUID().uuidString)", args: [], env: [:]))
        let client = MCPClient(server: missing, cwd: temp, timeout: .seconds(10), log: { _ in })
        await #expect(throws: MCPClient.Failure.stopped("The command was not found.")) {
            try await client.connect()
        }
        await client.end()
    }

    @Test func aCallThatTakesTooLongTimesOutAndTheClientGoesOn() async throws {
        let client = MCPClient(server: echo(), cwd: temp, timeout: .seconds(1), log: { _ in })
        try await client.connect()
        await #expect(throws: MCPClient.Failure.timedOut) {
            try await client.callTool("echo", arguments: ["sleep": 3])
        }
        #expect(try await client.listTools().map(\.name) == ["echo"])
        await client.end()
    }

    @Test func sseIsRefused() async {
        let old = MCPServer(name: "old", transport: .sse(url: "https://o.example/sse", headers: [:]))
        let client = MCPClient(server: old, cwd: temp, log: { _ in })
        await #expect(throws: MCPClient.Failure.transportNotSupported) { try await client.connect() }
    }

    // MARK: Streamable http

    @Test func httpKeepsItsSessionSendsItsHeadersAndReadsAnEventStream() async throws {
        let server = StandIn()
        let client = MCPClient(server: MCPServer(name: "remote", transport: .http(
            url: "https://mcp.example/mcp", headers: ["X-Key": "k1"])), cwd: temp, log: { _ in }, http: server.send)
        let info = try await client.connect()
        #expect(info.name == "stand-in")
        #expect(try await client.listTools().map(\.name) == ["a", "b"])
        await client.end()

        let seen = server.requests
        #expect(seen.map(\.method) == ["initialize", "notifications/initialized", "tools/list", "DELETE"])
        #expect(seen.allSatisfy { $0.headers["X-Key"] == "k1" })
        #expect(seen[0].headers["Mcp-Session-Id"] == nil)
        #expect(seen.dropFirst().allSatisfy { $0.headers["Mcp-Session-Id"] == "s-1" })
        #expect(seen[2].headers["MCP-Protocol-Version"] == "2025-06-18")
        // It says what it can show.
        #expect(seen[0].body?["params"]?["capabilities"]?["extensions"]?["io.modelcontextprotocol/ui"]?["mimeTypes"]?
            .arrayValue?.first?.stringValue == "text/html;profile=mcp-app")
    }

    @Test func a401IsAuthRequiredWithWhereItsMetadataIs() async {
        let server = StandIn(unauthorized: #"Bearer realm="mcp", resource_metadata="https://mcp.example/.well-known/oauth-protected-resource""#)
        let client = MCPClient(server: MCPServer(name: "locked", transport: .http(url: "https://mcp.example/mcp", headers: [:])),
                               cwd: temp, log: { _ in }, http: server.send)
        await #expect(throws: MCPClient.Failure.authRequired(
            resourceMetadata: "https://mcp.example/.well-known/oauth-protected-resource")) {
            try await client.connect()
        }
    }

    @Test func resourceMetadataIsReadQuotedOrNot() {
        #expect(MCPClient.resourceMetadata(#"Bearer resource_metadata="https://a/x""#) == "https://a/x")
        #expect(MCPClient.resourceMetadata("Bearer error=\"invalid_token\", resource_metadata=https://a/y, scope=x") == "https://a/y")
        #expect(MCPClient.resourceMetadata("Bearer realm=\"x\"") == nil)
        #expect(MCPClient.resourceMetadata(nil) == nil)
    }

    @Test func anotherStatusIsNotAnAnswer() async {
        let server = StandIn(status: 500)
        let client = MCPClient(server: MCPServer(name: "broken", transport: .http(url: "https://mcp.example/mcp", headers: [:])),
                               cwd: temp, log: { _ in }, http: server.send)
        await #expect(throws: MCPClient.Failure.httpStatus(500)) { try await client.connect() }
    }

    @Test func theAnswerIsFoundAmongOtherEvents() {
        let stream = Data("event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\n"
            .appending("data: {\"jsonrpc\":\"2.0\",\"id\":3,\r\ndata: \"result\":{}}\r\n\r\n").utf8)
        let answer = MCPClient.answer(3, inEvents: stream)
        #expect(answer.flatMap { try? JSONValue.parse($0) }?["id"]?.intValue == 3)
        #expect(MCPClient.answer(4, inEvents: stream) == nil)
    }

    // MARK: Typed on the sheet

    @Test func argumentsSplitAsAShellWould() {
        typealias Hand = DaemonAPI.MCPHandServer
        #expect(Hand.splitArguments("-y @scope/server@1.2 --dir \"/a b\" 'x y' c\\ d") ==
                ["-y", "@scope/server@1.2", "--dir", "/a b", "x y", "c d"])
        #expect(Hand.splitArguments("  ") == [])
        #expect(Hand.splitArguments("--empty ''") == ["--empty", ""])
        #expect(Hand.defaultSecretName(server: "my-api", value: "Authorization", header: true) == "MY_API_AUTHORIZATION")
        #expect(Hand.defaultSecretName(server: "x", value: "API_KEY", header: false) == "API_KEY")
    }
}

/// Streamable http as a server answers it: a session id on `initialize`, an event stream
/// for `tools/list`, 202 for a notification. Or one status for everything.
final class StandIn: @unchecked Sendable {
    struct Seen {
        var method: String
        var headers: [String: String]
        var body: JSONValue?
    }

    private let lock = NSLock()
    private var seen: [Seen] = []
    private let unauthorized: String?
    private let status: Int?
    var requests: [Seen] { lock.withLock { seen } }

    init(unauthorized: String? = nil, status: Int? = nil) {
        self.unauthorized = unauthorized
        self.status = status
    }

    var send: MCPClient.HTTPSend {
        { [self] request in try self.answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
        let method = request.httpMethod == "POST" ? body?["method"]?.stringValue ?? "?" : request.httpMethod ?? "?"
        lock.withLock { seen.append(Seen(method: method, headers: request.allHTTPHeaderFields ?? [:], body: body)) }
        func reply(_ status: Int, _ headers: [String: String] = [:], _ text: String = "") -> (Data, HTTPURLResponse) {
            (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        if let unauthorized { return reply(401, ["WWW-Authenticate": unauthorized]) }
        if let status { return reply(status) }
        let id = body?["id"]?.intValue ?? 0
        switch method {
        case "initialize":
            return reply(200, ["Content-Type": "application/json", "Mcp-Session-Id": "s-1"],
                         #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"stand-in","version":"2"}}}"#)
        case "tools/list":
            return reply(200, ["Content-Type": "text/event-stream"],
                         "data: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"tools\":[{\"name\":\"a\"},{\"name\":\"b\"}]}}\n\n")
        case "DELETE":
            return reply(200)
        default:
            return reply(body?["id"] == nil ? 202 : 404)
        }
    }
}
