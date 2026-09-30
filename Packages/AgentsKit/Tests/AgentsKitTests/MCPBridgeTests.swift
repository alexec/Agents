#if canImport(Network) && canImport(Security)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The bridge that serves a stdio MCP server over loopback http to a runtime that takes
/// none from the client (054, contracts/mcp-bridge.md). Every row of the contract's HTTP
/// table, against a real process and a real socket.
@Suite("MCP bridge", .timeLimit(.minutes(1)))
struct MCPBridgeTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appending(path: "Fixtures/mcp/echo-server.py").path
    private let secret = "SENTINEL-4d2a-bridge"

    private func echo(env: [String: String] = [:], args: [String] = []) -> MCPServer {
        MCPServer(name: "echo", transport: .stdio(command: "python3", args: [Self.script] + args, env: env))
    }

    private struct Target {
        var port: UInt16
        var path: String
        var bearer: String
    }

    private func target(_ server: MCPServer) throws -> Target {
        guard case .http(let url, let headers) = server.transport, let parts = URLComponents(string: url),
              let port = parts.port, let bearer = headers["Authorization"] else {
            throw TestFailure("not an http route: \(server.transport)")
        }
        return Target(port: UInt16(port), path: parts.path, bearer: bearer)
    }

    private func call(_ id: Int, _ arguments: [String: Any] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                                     "params": ["name": "echo", "arguments": arguments]])
    }

    private func post(_ target: Target, _ body: Data, bearer: String? = nil, path: String? = nil) async throws -> RawHTTP.Response {
        try await RawHTTP.send(port: target.port, "POST \(path ?? target.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                               + "Authorization: \(bearer ?? target.bearer)\r\nContent-Type: application/json\r\n"
                               + "Content-Length: \(body.count)\r\n\r\n", body: body)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func pid(_ response: RawHTTP.Response) -> Int32? {
        ((json(response.body)["result"] as? [String: Any])?["pid"] as? NSNumber)?.int32Value
    }

    private func gone(_ pid: Int32) async -> Bool {
        await eventually("process \(pid) ended") { kill(pid, 0) != 0 }
    }

    @Test func aRequestIsAnsweredWithItsOwnIDAndANotificationWith202() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))

        let answer = try await post(route, call(7, ["say": "hi"]))
        #expect(answer.status == 200)
        #expect(answer.headers["content-type"] == "application/json")
        #expect(json(answer.body)["id"] as? Int == 7)
        #expect(((json(answer.body)["result"] as? [String: Any])?["echo"] as? [String: String]) == ["say": "hi"])

        let note = try await post(route, Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(note.status == 202)
        #expect(note.body.isEmpty)
    }

    @Test func anUnknownRouteAWrongBearerAndAnEndedRouteAllLookTheSame() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))

        let unknown = try await post(route, call(1), path: "/mcp/nothing-here")
        let wrongBearer = try await post(route, call(1), bearer: "Bearer not-the-key")
        let noBearer = try await RawHTTP.send(port: route.port, "POST \(route.path) HTTP/1.1\r\nContent-Length: 2\r\n\r\n",
                                              body: Data("{}".utf8))
        bridge.endRoutes(for: "t")
        let ended = try await post(route, call(1))

        for answer in [unknown, wrongBearer, noBearer, ended] {
            #expect(answer.status == 404)
            #expect(answer.body.isEmpty)
        }
    }

    @Test func getChunkedAndOversizedAreRefused() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))

        let get = try await RawHTTP.send(port: route.port, "GET \(route.path) HTTP/1.1\r\nAuthorization: \(route.bearer)\r\n\r\n")
        #expect(get.status == 405)

        let chunked = try await RawHTTP.send(port: route.port, "POST \(route.path) HTTP/1.1\r\nAuthorization: \(route.bearer)\r\n"
                                             + "Transfer-Encoding: chunked\r\n\r\n", body: Data("2\r\n{}\r\n0\r\n\r\n".utf8))
        #expect(chunked.status == 411)

        let huge = try await RawHTTP.send(port: route.port, "POST \(route.path) HTTP/1.1\r\nAuthorization: \(route.bearer)\r\n"
                                          + "Content-Length: \(MCPBridge.bodyLimit + 1)\r\n\r\n")
        #expect(huge.status == 413)
    }

    @Test func twoRequestsKeptAliveOnOneConnectionAreBothAnswered() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))
        func head(_ body: Data) -> String {
            "POST \(route.path) HTTP/1.1\r\nAuthorization: \(route.bearer)\r\nContent-Length: \(body.count)\r\n\r\n"
        }
        let first = call(1), second = call(2)
        let both = Data(head(first).utf8) + first + Data(head(second).utf8) + second

        let answers = try await RawHTTP.send(port: route.port, "", body: both, responses: 2)
        #expect(answers.map(\.status) == [200, 200])
        #expect(answers.map { json($0.body)["id"] as? Int } == [1, 2])
    }

    @Test func overlappingCallsAreAnsweredAsTheirAnswersComeBack() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))
        _ = try await post(route, call(0))  // started, so neither call below waits on a cold start

        // No clock: under load a quick answer can take a while, but it still comes back
        // while the slow one is waiting.
        let slowDone = Flag()
        async let slow = { () async throws -> RawHTTP.Response in
            let answer = try await post(route, call(1, ["sleep": 10]))
            slowDone.set()
            return answer
        }()
        try await Task.sleep(for: .milliseconds(100))
        let quick = try await post(route, call(2))
        #expect(!slowDone.isSet)
        #expect(json(quick.body)["id"] as? Int == 2)
        bridge.endRoutes(for: "t")
        let slowAnswer = try await slow
        #expect(json(slowAnswer.body)["id"] as? Int == 1)
    }

    @Test func endingARouteStopsItsProcessAndFailsTheCallWaitingOnIt() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))
        let pid = try #require(pid(try await post(route, call(1))))

        async let waiting = post(route, call(2, ["sleep": 30]))
        try await Task.sleep(for: .milliseconds(200))
        bridge.endRoutes(for: "t")
        let answer = try await waiting

        let error = json(answer.body)["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32000)
        #expect(error?["message"] as? String == "The agent's session has ended.")
        #expect(json(answer.body)["id"] as? Int == 2)
        #expect(await gone(pid))
    }

    @Test func aServerThatExitsFailsItsWaitingCallsAndTheNextPostStartsItAgain() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))
        let first = try #require(pid(try await post(route, call(1))))

        async let waiting = post(route, call(2, ["sleep": 30]))
        try await Task.sleep(for: .milliseconds(200))
        let exit = try await post(route, call(3, ["exit": true]))
        let failed = try await waiting

        for answer in [exit, failed] {
            let error = json(answer.body)["error"] as? [String: Any]
            #expect(error?["code"] as? Int == -32000)
            #expect(error?["message"] as? String == "The server stopped.")
        }
        let again = try #require(pid(try await post(route, call(4))))
        #expect(again != first)
    }

    @Test func whatTheServerStartsIsNotPassedOnAndARequestIsTurnedAway() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let route = try target(try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory))

        let answer = try await post(route, call(1, ["ask": true]))
        let asked = ((json(answer.body)["result"] as? [String: Any])?["echo"] as? [String: Any])?["asked"] as? [String: Any]
        #expect((asked?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(asked?["id"] as? String == "srv-1")
    }

    // FR-023
    @Test func nothingARouteCarriesIsLogged() async throws {
        let lines = LogLines()
        let bridge = MCPBridge(log: { lines.add($0) })
        defer { bridge.stopAll() }
        let server = echo(env: ["KEY": secret], args: ["--token=\(secret)"])
        let route = try target(try await bridge.route(for: server, token: "t", cwd: FileManager.default.temporaryDirectory))

        _ = try await post(route, call(1, ["say": secret]))
        _ = try await post(route, call(2, ["exit": true]))
        _ = try await post(route, call(3))
        bridge.endRoutes(for: "t")

        #expect(!lines.all.isEmpty)
        #expect(!lines.all.contains(secret))
        #expect(!lines.all.contains("python3"))
        #expect(!lines.all.contains(Self.script))
        #expect(!lines.all.contains(route.bearer))
    }

    @Test func aStdioServerBecomesAnHttpRouteAndTheRestAreLeftAlone() async throws {
        let bridge = MCPBridge(log: { _ in })
        defer { bridge.stopAll() }
        let http = MCPServer(name: "docs", transport: .http(url: "https://docs.example", headers: [:]))

        let routed = try await bridge.route(for: echo(), token: "t", cwd: FileManager.default.temporaryDirectory)
        #expect(routed.name == "echo")
        guard case .http(let url, let headers) = routed.transport else {
            Issue.record("still stdio")
            return
        }
        #expect(url.hasPrefix("http://127.0.0.1:"))
        #expect(headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(try await bridge.route(for: http, token: "t", cwd: FileManager.default.temporaryDirectory) == http)
    }

    @Test func bearerCompareRejectsNearMisses() {
        #expect(MCPBridge.bearer("Bearer secret", matches: "secret"))
        #expect(!MCPBridge.bearer("Bearer secret", matches: "Secret"))
        #expect(!MCPBridge.bearer("Bearer secre", matches: "secret"))
        #expect(!MCPBridge.bearer(nil, matches: "secret"))
        #expect(!MCPBridge.bearer("secret", matches: "secret"))
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: String { lock.withLock { lines.joined(separator: "\n") } }
}

/// HTTP/1.1 over a plain socket, so a test controls every byte: a chunked body, a head
/// that promises more than it sends, two requests in one write.
enum RawHTTP {
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    static func send(port: UInt16, _ head: String, body: Data = Data()) async throws -> Response {
        try await send(port: port, head, body: body, responses: 1)[0]
    }

    static func send(port: UInt16, _ head: String, body: Data, responses: Int) async throws -> [Response] {
        // Off the pool, not detached onto it: the read blocks until the bridge answers, and
        // the bridge needs the pool to answer. Six of these at once in a full run held six
        // of its threads and starved everything else.
        try await offThePool { Result { try blockingSend(port: port, head, body: body, responses: responses) } }.get()
    }

    private static func blockingSend(port: UInt16, _ head: String, body: Data, responses: Int) throws -> [Response] {
        try {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TestFailure("no socket") }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw TestFailure("could not connect") }
            let bytes = [UInt8](Data(head.utf8) + body)
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }

            var buffer = Data()
            var answers: [Response] = []
            var chunk = [UInt8](repeating: 0, count: 65536)
            while answers.count < responses {
                if let (response, used) = parse(buffer) {
                    answers.append(response)
                    buffer.removeFirst(used)
                    continue
                }
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { throw TestFailure("closed after \(answers.count) answer(s)") }
                buffer.append(contentsOf: chunk[0..<count])
            }
            return answers
        }()
    }

    private static func parse(_ buffer: Data) -> (Response, Int)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let status = Int(lines.removeFirst().split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let start = buffer.distance(from: buffer.startIndex, to: end.upperBound)
        guard buffer.count >= start + length else { return nil }
        let body = Data(buffer.dropFirst(start).prefix(length))
        return (Response(status: status, headers: headers, body: body), start + length)
    }
}
#endif
