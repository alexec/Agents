#if canImport(Network) && canImport(Security)
import AgentsKitCore
import Foundation
import Network
import Security

/// Stdio MCP servers, served over loopback http to a runtime that takes no stdio server
/// from the client (054, research R11).
///
/// Copilot refuses every stdio server an ACP client sends ("Rejecting non-http/sse MCP
/// server … from client", R9), the app's own `agents` server included. So for Copilot each
/// one is swapped for a route here: `http://127.0.0.1:<port>/mcp/<route>` with a bearer of its
/// own. The bridge starts the server on the route's first request, exactly as the runtime
/// would have, and passes JSON-RPC lines between the two.
///
/// The smallest piece of MCP's streamable http that the probe showed Copilot needs: a POST
/// answered with the one response, 202 for a notification, 405 for GET. What a server says
/// first (a notification, or a request of its own) is not passed on.
///
/// Nothing a route carries — command, arguments, environment, bodies — is ever logged:
/// a server's environment is where its secrets are (FR-023).
final class MCPBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mcp-bridge")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var starting: Task<UInt16, any Error>?
    private var routes: [String: Route] = [:]
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void = { DaemonLog.shared.write($0) }) {
        self.log = log
    }

    /// One stdio server, stood in for over http, for one session.
    final class Route: @unchecked Sendable {
        let id: String
        let key: String
        let token: String
        let name: String
        let command: String
        let args: [String]
        let env: [String: String]
        let cwd: URL
        var process: RouteProcess?

        init(id: String, key: String, token: String, name: String, command: String,
             args: [String], env: [String: String], cwd: URL) {
            self.id = id; self.key = key; self.token = token; self.name = name
            self.command = command; self.args = args; self.env = env; self.cwd = cwd
        }
    }

    // MARK: Routes

    /// The http server that stands in for `server` in a session carrying `token`. Anything
    /// that is not stdio is given back as it is.
    func route(for server: MCPServer, token: String, cwd: URL) async throws -> MCPServer {
        guard case .stdio(let command, let args, let env) = server.transport else { return server }
        let port = try await start()
        let route = Route(id: Self.random(16), key: Self.random(32), token: token, name: server.name,
                          command: command, args: args, env: env, cwd: cwd)
        lock.withLock { routes[route.id] = route }
        log("bridge: route \(route.id.prefix(6)) for \(server.name) made")
        return MCPServer(name: server.name,
                         transport: .http(url: "http://127.0.0.1:\(port)/mcp/\(route.id)",
                                          headers: ["Authorization": "Bearer \(route.key)"]))
    }

    /// End every route a session's token was given, and stop what they started.
    func endRoutes(for token: String) {
        let ended = lock.withLock {
            let gone = routes.values.filter { $0.token == token }
            for route in gone { routes.removeValue(forKey: route.id) }
            return gone
        }
        for route in ended {
            route.process?.end(reason: "The agent's session has ended.")
            log("bridge: route \(route.id.prefix(6)) for \(route.name) ended (session over)")
        }
    }

    /// The processes running for a token's routes. Each was started only by a request
    /// carrying its route's bearer, which only the agent's runtime was given, so they speak
    /// for that agent as a helper the runtime started itself would.
    func processIdentifiers(for token: String) -> [Int32] {
        lock.withLock {
            routes.values.filter { $0.token == token }
                .compactMap { $0.process?.isRunning == true ? $0.process?.processIdentifier : nil }
        }
    }

    func stopAll() {
        let all = lock.withLock { () -> [Route] in
            let all = Array(routes.values)
            routes.removeAll()
            listener?.cancel()
            listener = nil
            port = 0
            starting = nil
            return all
        }
        for route in all { route.process?.end(reason: "The app is stopping.") }
    }

    // MARK: Listening

    /// The port, once one start has made the listener: two sessions made at once share it.
    private func start() async throws -> UInt16 {
        let task = lock.withLock { () -> Task<UInt16, any Error> in
            if let starting { return starting }
            let task = Task { try await self.listen() }
            starting = task
            return task
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { starting = nil }
            throw error
        }
    }

    private func listen() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        let ready: UInt16 = try await withCheckedThrowingContinuation { done in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { done.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.take() { done.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock {
            self.listener = listener
            self.port = ready
        }
        log("bridge: listening on 127.0.0.1:\(ready)")
        return ready
    }

    /// The largest request body taken (contracts/mcp-bridge.md).
    static let bodyLimit = 16 << 20

    private func receive(_ connection: NWConnection, buffer: Data) {
        // What is already here may be a whole request: a client that sent two back to
        // back on a kept-alive connection.
        if !buffer.isEmpty, handle(connection, buffer: buffer, done: false) { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if self.handle(connection, buffer: buffer, done: done || error != nil) { return }
            self.receive(connection, buffer: buffer)
        }
    }

    /// Answer the request at the front of `buffer`, if it is all here. False when more is
    /// needed and the connection can still send it.
    private func handle(_ connection: NWConnection, buffer: Data, done: Bool) -> Bool {
        // Refused from the head alone: nothing about a body this bridge will not take is
        // worth waiting for.
        if let head = Self.head(of: buffer) {
            if head.chunked {
                reply(connection, status: "411 Length Required", body: Data(), close: true)
                return true
            }
            if head.length > Self.bodyLimit {
                reply(connection, status: "413 Content Too Large", body: Data(), close: true)
                return true
            }
        }
        switch HTTPRequest.parse(buffer) {
        case .complete(let request):
            let used = (Self.head(of: buffer)?.size ?? buffer.count) + request.body.count
            let rest = used < buffer.count ? Data(buffer[(buffer.startIndex + used)...]) : Data()
            Task {
                let (status, body) = await self.answer(request)
                self.reply(connection, status: status, body: body)
                // Keep-alive: the same connection carries the next request.
                self.receive(connection, buffer: rest)
            }
            return true
        case .incomplete where !done:
            return false
        default:
            connection.cancel()
            return true
        }
    }

    /// The request head's length (through the blank line), its `Content-Length`, and
    /// whether the body is chunked. Nil until the head has all arrived.
    static func head(of buffer: Data) -> (size: Int, length: Int, chunked: Bool)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        var length = 0
        var chunked = false
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) ?? 0 }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }
        return (buffer.distance(from: buffer.startIndex, to: end.upperBound), length, chunked)
    }

    private func answer(_ request: HTTPRequest) async -> (String, Data) {
        let parts = request.pathOnly.split(separator: "/")
        let bearer = request.headers.first { $0.name.lowercased() == "authorization" }?.value
        guard parts.count == 2, parts[0] == "mcp",
              let route = lock.withLock({ routes[String(parts[1])] }),
              Self.bearer(bearer, matches: route.key) else {
            return ("404 Not Found", Data())
        }
        switch request.method {
        case "POST":
            let process = lock.withLock { () -> RouteProcess in
                if let running = route.process, running.isRunning { return running }
                let started = RouteProcess(route: route, log: log)
                route.process = started
                return started
            }
            guard let reply = await process.send(request.body) else { return ("202 Accepted", Data()) }
            return ("200 OK", reply)
        case "DELETE":
            endRoute(route)
            log("bridge: route \(route.id.prefix(6)) for \(route.name) ended (closed by the runtime)")
            return ("200 OK", Data())
        default:
            return ("405 Method Not Allowed", Data())
        }
    }

    private func endRoute(_ route: Route) {
        lock.withLock { _ = routes.removeValue(forKey: route.id) }
        route.process?.end(reason: "The route was closed.")
    }

    private func reply(_ connection: NWConnection, status: String, body: Data, close: Bool = false) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        if close { head += "Connection: close\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time compare of `Authorization: Bearer <key>` (security review S5).
    static func bearer(_ header: String?, matches key: String) -> Bool {
        guard let header else { return false }
        let expected = Array("Bearer \(key)".utf8)
        let got = Array(header.utf8)
        guard got.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in got.indices { diff |= got[i] ^ expected[i] }
        return diff == 0
    }
}

/// A route's stdio server: started on the route's first request, and a table of the
/// requests waiting for their answers, matched by JSON-RPC `id`.
final class RouteProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var waiting: [String: CheckedContinuation<Data?, Never>] = [:]
    private var partial = Data()
    private var dropped = 0
    private var ended = false
    private var endReason = "The server stopped."
    private let name: String
    private let log: @Sendable (String) -> Void

    init(route: MCPBridge.Route, log: @escaping @Sendable (String) -> Void) {
        self.name = route.name
        self.log = log
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [route.command] + route.args
        // Same scrubbing a runtime launch gets: never the daemon's full environment
        // (security review S5).
        process.environment = RuntimeEnvironment.forRuntimes().merging(route.env) { $1 }
        process.currentDirectoryURL = RuntimeProcess.folderURL(route.cwd)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty is the end of the pipe, which is otherwise reported again and again.
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.read(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.end(reason: "The server stopped.")
        }
        do {
            try process.run()
            log("bridge: \(name) started (pid \(process.processIdentifier))")
        } catch {
            log("bridge: \(name) could not start")
            ended = true
        }
    }

    var isRunning: Bool { lock.withLock { !ended } && process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    /// Write one message; for a request, wait for the answer with the same `id`. Nil for a
    /// notification, which has no answer.
    func send(_ body: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Self.error(id: nil, code: -32700, message: "The request was not JSON.")
        }
        guard let id = message["id"].flatMap(Self.key) else {
            write(body)
            return nil
        }
        let original = message["id"]
        return await withCheckedContinuation { done in
            // Checked and registered together, so a server that stops in between still
            // answers this call.
            let stopped = lock.withLock { () -> String? in
                if ended { return endReason }
                waiting[id] = done
                return nil
            }
            if let stopped {
                done.resume(returning: Self.error(id: original, code: -32000, message: stopped))
            } else {
                write(body)
            }
        }
    }

    func end(reason: String) {
        let pending = lock.withLock { () -> [String: CheckedContinuation<Data?, Never>] in
            if !ended { endReason = reason }
            ended = true
            let pending = waiting
            waiting.removeAll()
            return pending
        }
        output.fileHandleForReading.readabilityHandler = nil
        for (id, done) in pending {
            done.resume(returning: Self.error(idKey: id, code: -32000, message: reason))
        }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func write(_ body: Data) {
        var line = body
        if line.last != UInt8(ascii: "\n") { line.append(UInt8(ascii: "\n")) }
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    private func read(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [Data] = lock.withLock {
            partial.append(data)
            var lines: [Data] = []
            while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(partial[partial.startIndex..<newline]))
                partial.removeSubrange(partial.startIndex...newline)
            }
            return lines
        }
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if message["method"] != nil {
            // The server speaking first. A request is told no, so it does not wait forever;
            // a notification is counted and dropped (v1, contracts/mcp-bridge.md).
            if let id = message["id"] {
                write(Self.error(id: id, code: -32601, message: "Not passed on by the app's bridge."))
            } else {
                let count = lock.withLock { dropped += 1; return dropped }
                if count == 1 || count % 100 == 0 { log("bridge: \(name) sent \(count) notification(s) not passed on") }
            }
            return
        }
        guard let id = message["id"].flatMap(Self.key),
              let done = lock.withLock({ waiting.removeValue(forKey: id) }) else { return }
        done.resume(returning: line)
    }

    /// A JSON-RPC id as a key: a number and a string of the same digits are different ids.
    static func key(_ id: Any) -> String? {
        if let number = id as? NSNumber { return "n:\(number)" }
        if let string = id as? String { return "s:\(string)" }
        return nil
    }

    static func error(id: Any?, code: Int, message: String) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(),
                                     "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func error(idKey: String, code: Int, message: String) -> Data {
        let id: Any = idKey.hasPrefix("n:") ? (Int(idKey.dropFirst(2)) ?? 0) as Any : String(idKey.dropFirst(2))
        return error(id: id, code: code, message: message)
    }
}
#endif
