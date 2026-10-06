import AgentsKitCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app's own client of a person's MCP server: a connection of the daemon's, not the
/// runtime's (#191's views, #305's Verify, #306's sign-in).
///
/// - **stdio:** our own copy of the server, through `MCPStdioProcess`, with the same
///   scrubbed environment as the bridge and the runtimes, and stderr discarded.
/// - **http** (streamable http): a session of its own (`Mcp-Session-Id`), sending the
///   configured headers. An answer may be one JSON body or an event stream.
/// - **sse**, the old transport, is refused.
///
/// `initialize` advertises the MCP Apps extension, then `tools/list`, `resources/list`,
/// `resources/read` and `tools/call`, each with a timeout. A server that has no such method
/// (`-32601`) has none of the optional ones, rather than failing.
///
/// A 401 is its own result, `authRequired`, with the `resource_metadata` URL its
/// `WWW-Authenticate` names: #306 signs in from there.
///
/// Logged: the server's name and what happened in a word. Never its command, arguments,
/// environment, headers, URL or any body (FR-023, 054's sentinel test; T046).
actor MCPClient {
    static let protocolVersion = "2025-06-18"
    /// What `initialize` says the app can show (#187).
    static let extensions: JSONValue = ["io.modelcontextprotocol/ui": ["mimeTypes": ["text/html;profile=mcp-app"]]]
    /// Bounds on what a list keeps (bound data, not concurrency).
    static let pageLimit = 10
    static let itemLimit = 500

    enum Failure: Error, Equatable, Sendable {
        /// 401: the server wants a sign-in first. `resourceMetadata` is the URL its
        /// `WWW-Authenticate` named, when it named one.
        case authRequired(resourceMetadata: String?)
        /// Any other status that is not an answer.
        case httpStatus(Int)
        /// The server no longer knows this client's session (404 with `Mcp-Session-Id`).
        case sessionExpired
        /// Nothing answered at the address, or it was not one.
        case unreachable(String)
        /// The stdio server ended, or never started.
        case stopped(String)
        case timedOut
        /// A JSON-RPC error the server answered with.
        case refused(code: Int, message: String)
        /// What came back was not MCP.
        case notMCP
        /// sse, which the app's client does not speak.
        case transportNotSupported

        /// One word for the log: never the server's own text.
        var logWord: String {
            switch self {
            case .authRequired: "auth required"
            case .httpStatus(let status): "http \(status)"
            case .sessionExpired: "session expired"
            case .unreachable: "unreachable"
            case .stopped: "stopped"
            case .timedOut: "timed out"
            case .refused(let code, _): "refused \(code)"
            case .notMCP: "not MCP"
            case .transportNotSupported: "transport not supported"
            }
        }
    }

    struct ServerInfo: Equatable, Sendable {
        var name: String?
        var version: String?
        var protocolVersion: String?
        var instructions: String?
    }

    struct Tool: Equatable, Sendable {
        var name: String
        var title: String?
        var description: String?
        /// The whole of it, `_meta` and annotations included, for #191's catalog.
        var raw: JSONValue
    }

    typealias HTTPSend = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let server: MCPServer
    private let cwd: URL
    private let timeout: Duration
    private let log: @Sendable (String) -> Void
    private let http: HTTPSend
    private var stdio: MCPStdioProcess?
    private var sessionID: String?
    private var negotiated: String?
    private var nextID = 1
    private(set) var info: ServerInfo?

    /// `cwd` is where a stdio server runs: the project's folder, or the person's home.
    init(server: MCPServer, cwd: URL, timeout: Duration = .seconds(60),
         log: @escaping @Sendable (String) -> Void = { DaemonLog.shared.write($0) },
         http: HTTPSend? = nil) {
        self.server = server
        self.cwd = cwd
        self.timeout = timeout
        self.log = log
        self.http = http ?? MCPClient.urlSession
    }

    // MARK: Lifecycle

    /// Start the server or open the session, and `initialize`.
    @discardableResult
    func connect() async throws -> ServerInfo {
        do {
            switch server.transport {
            case .sse:
                throw Failure.transportNotSupported
            case .stdio(let command, let args, let env):
                let process = MCPStdioProcess(name: server.name, command: command, args: args, env: env,
                                              cwd: cwd, logPrefix: "mcp client", log: log)
                stdio = process
                if let why = process.stoppedBecause { throw Failure.stopped(why) }
            case .http:
                break
            }
            let params: JSONValue = [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": ["extensions": Self.extensions],
                "clientInfo": ["name": "Agents", "version": "1"],
            ]
            guard let result = try await request("initialize", params) else { throw Failure.notMCP }
            negotiated = result["protocolVersion"]?.stringValue
            let info = ServerInfo(name: result["serverInfo"]?["name"]?.stringValue,
                                  version: result["serverInfo"]?["version"]?.stringValue,
                                  protocolVersion: negotiated,
                                  instructions: result["instructions"]?.stringValue)
            self.info = info
            try await notify("notifications/initialized")
            log("mcp client: \(server.name) answered")
            return info
        } catch let failure as Failure {
            log("mcp client: \(server.name) did not answer (\(failure.logWord))")
            throw failure
        }
    }

    /// Stop the stdio server, or close the http session. Safe to call more than once.
    func end() async {
        if let stdio {
            stdio.end(reason: "The app's client has ended.")
            self.stdio = nil
        }
        if case .http(let url, let headers) = server.transport, let sessionID, let address = URL(string: url) {
            var request = URLRequest(url: address)
            request.httpMethod = "DELETE"
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            request.timeoutInterval = 5
            _ = try? await http(request)
            self.sessionID = nil
        }
        log("mcp client: \(server.name) ended")
    }

    // MARK: Methods

    /// Every tool, through `nextCursor`, up to `itemLimit`. None when the server has no tools.
    func listTools() async throws -> [Tool] {
        try await pages("tools/list", key: "tools").compactMap { raw in
            guard let name = raw["name"]?.stringValue else { return nil }
            return Tool(name: name, title: raw["title"]?.stringValue,
                        description: raw["description"]?.stringValue, raw: raw)
        }
    }

    /// Every resource, as the server described it. None when it has no resources.
    func listResources() async throws -> [JSONValue] {
        try await pages("resources/list", key: "resources")
    }

    /// `resources/read`'s `contents`.
    func readResource(_ uri: String) async throws -> [JSONValue] {
        guard let result = try await request("resources/read", ["uri": .string(uri)]) else { throw Failure.notMCP }
        return result["contents"]?.arrayValue ?? []
    }

    /// `tools/call`'s whole result.
    func callTool(_ name: String, arguments: JSONValue = [:]) async throws -> JSONValue {
        guard let result = try await request("tools/call", ["name": .string(name), "arguments": arguments]) else {
            throw Failure.notMCP
        }
        return result
    }

    private func pages(_ method: String, key: String) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var cursor: String?
        for _ in 0..<Self.pageLimit {
            let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
            guard let result = try await request(method, params, optional: true) else { return items }
            items += result[key]?.arrayValue ?? []
            cursor = result["nextCursor"]?.stringValue
            if cursor == nil || items.count >= Self.itemLimit { break }
        }
        return Array(items.prefix(Self.itemLimit))
    }

    // MARK: JSON-RPC

    /// The result of `method`. Nil only when `optional` and the server has no such method.
    private func request(_ method: String, _ params: JSONValue, optional: Bool = false) async throws -> JSONValue? {
        let id = nextID
        nextID += 1
        let body = try JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "id": .int(id),
                                                              "method": .string(method), "params": params]))
        let reply = try await exchange(body, id: id)
        guard let message = try? JSONValue.parse(reply), message["id"]?.intValue == id else { throw Failure.notMCP }
        if let error = message["error"] {
            let code = error["code"]?.intValue ?? 0
            if optional && code == -32601 { return nil }
            if code == -32000, let why = stdio?.stoppedBecause { throw Failure.stopped(why) }
            throw Failure.refused(code: code, message: error["message"]?.stringValue ?? "")
        }
        guard let result = message["result"] else { throw Failure.notMCP }
        return result
    }

    private func notify(_ method: String) async throws {
        let body = try JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "method": .string(method)]))
        switch server.transport {
        case .stdio:
            _ = await stdio?.send(body)
        case .http:
            _ = try await post(body, id: nil)
        case .sse:
            throw Failure.transportNotSupported
        }
    }

    /// One request out and its answer back, within `timeout`.
    private func exchange(_ body: Data, id: Int) async throws -> Data {
        switch server.transport {
        case .stdio:
            guard let process = stdio else { throw Failure.stopped("The server is not running.") }
            return try await timed(onTimeout: { process.abandon(NSNumber(value: id)) }) {
                guard let reply = await process.send(body) else { throw Failure.timedOut }
                return reply
            }
        case .http:
            return try await timed(onTimeout: {}) {
                guard let reply = try await self.post(body, id: id) else { throw Failure.notMCP }
                return reply
            }
        case .sse:
            throw Failure.transportNotSupported
        }
    }

    private func timed(onTimeout: @escaping @Sendable () -> Void,
                       _ work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let reply = first else {
                onTimeout()
                throw Failure.timedOut
            }
            return reply
        }
    }

    // MARK: Streamable http

    /// POST one message. The answer to `id`, or nil for a notification (202).
    private func post(_ body: Data, id: Int?) async throws -> Data? {
        guard case .http(let url, let headers) = server.transport else { throw Failure.transportNotSupported }
        guard let address = URL(string: url), ["http", "https"].contains(address.scheme?.lowercased() ?? "") else {
            throw Failure.unreachable("That is not an http or https address.")
        }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Double(timeout.components.seconds)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiated { request.setValue(negotiated, forHTTPHeaderField: "MCP-Protocol-Version") }

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http(request)
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreachable(Self.reason(error))
        }
        switch response.statusCode {
        case 401:
            throw Failure.authRequired(resourceMetadata:
                Self.resourceMetadata(response.value(forHTTPHeaderField: "WWW-Authenticate")))
        case 404 where sessionID != nil:
            sessionID = nil
            throw Failure.sessionExpired
        case 200..<300:
            break
        default:
            throw Failure.httpStatus(response.statusCode)
        }
        if let given = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !given.isEmpty { sessionID = given }
        guard let id else { return nil }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.hasPrefix("text/event-stream") {
            guard let answer = Self.answer(id, inEvents: data) else { throw Failure.notMCP }
            return answer
        }
        return data
    }

    /// The JSON-RPC answer to `id` among an event stream's `data:` events.
    static func answer(_ id: Int, inEvents data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for event in text.components(separatedBy: "\n\n") {
            let lines = event.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> Substring? in
                guard line.hasPrefix("data:") else { return nil }
                let rest = line.dropFirst(5)
                return rest.hasPrefix(" ") ? rest.dropFirst() : rest
            }
            guard !lines.isEmpty else { continue }
            let payload = Data(lines.joined(separator: "\n").utf8)
            guard let message = try? JSONValue.parse(payload), message["id"]?.intValue == id,
                  message["result"] != nil || message["error"] != nil else { continue }
            return payload
        }
        return nil
    }

    /// `resource_metadata` from a `WWW-Authenticate` header (RFC 9728), quoted or not.
    static func resourceMetadata(_ header: String?) -> String? {
        guard let header,
              let range = header.range(of: #"resource_metadata\s*=\s*("[^"]*"|[^,\s]+)"#, options: .regularExpression)
        else { return nil }
        let pair = header[range]
        guard let equals = pair.firstIndex(of: "=") else { return nil }
        let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return value.isEmpty ? nil : value
    }

    /// What went wrong reaching it, without the address (an `NSError`'s own description
    /// carries the URL).
    private static func reason(_ error: any Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .cannotFindHost, .dnsLookupFailed: return "Its host could not be found."
            case .cannotConnectToHost: return "Nothing answered at that address."
            case .timedOut: return "It did not answer in time."
            case .notConnectedToInternet: return "This Mac is offline."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "Its secure connection could not be made."
            default: return "It could not be reached."
            }
        }
        return "It could not be reached."
    }

    private static let session = URLSession(configuration: .ephemeral)

    /// The default `HTTPSend`: one request on an ephemeral session, cancelled with its task.
    static let urlSession: HTTPSend = { request in
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                let task = MCPClient.session.dataTask(with: request) { data, response, error in
                    if let error { return done.resume(throwing: error) }
                    guard let http = response as? HTTPURLResponse else {
                        return done.resume(throwing: URLError(.badServerResponse))
                    }
                    done.resume(returning: (data ?? Data(), http))
                }
                holder.set(task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func set(_ task: URLSessionDataTask) {
            let cancel = lock.withLock { self.task = task; return cancelled }
            if cancel { task.cancel() }
        }
        func cancel() {
            let task = lock.withLock { cancelled = true; return self.task }
            task?.cancel()
        }
    }
}
