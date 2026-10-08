import AgentsKitCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// The app's own `agents` MCP server, served by the daemon itself over loopback
/// streamable http (#185): `http://127.0.0.1:<port>/mcp/agents`, with the session's token as
/// the bearer.
///
/// Until #185 every runtime started an `agentsd mcp` helper of its own that spoke MCP on a
/// pipe and relayed each call down its own `daemon.sock` connection. That was a process, a
/// pipe pair and a socket per session, owned by the runtime: one outlived a runtime that
/// died, and each held a descriptor on the socket whose exhaustion once made the app do
/// nothing. Here the daemon owns all of it, and ending a session is one `revoke`.
///
/// Every runtime takes http (the 054 probe), Copilot included, so there is one path.
/// Codex refuses SSE, so this is streamable http: POST answered with one JSON response,
/// 202 for a notification or a response, the GET event stream, `Mcp-Session-Id`, DELETE,
/// and 404 for a session id this server does not know, which tells the client to start
/// again.
///
/// Loopback only: bound to 127.0.0.1 and nothing else, on the Mac and on Linux hosts.
public final class AppToolsEndpoint: @unchecked Sendable {
    /// The path the one server is at.
    public static let path = "/mcp/agents"

    /// The largest request body taken. The same as the bridge's.
    static let bodyLimit = 16 << 20

    /// What a token may be offered. The daemon refuses the calls as well; this only keeps
    /// the menu honest (028, 053).
    public struct Grant: Equatable, Sendable {
        public var managesAgents: Bool
        public var movesItself: Bool

        public init(managesAgents: Bool = true, movesItself: Bool = true) {
            self.managesAgents = managesAgents
            self.movesItself = movesItself
        }
    }

    /// One token's server: the tools it was granted, and the MCP sessions its runtime opened.
    private final class Holder: @unchecked Sendable {
        let grant: Grant
        let service: AppService
        var sessions: Set<String> = []
        var streams: [String: [any Channel]] = [:]

        init(grant: Grant, service: AppService) {
            self.grant = grant
            self.service = service
        }
    }

    private let lock = NSLock()
    private let relay: AppService.Relay
    private let log: @Sendable (String) -> Void
    private var holders: [String: Holder] = [:]
    private var channel: (any Channel)?
    private var starting: Task<Int, any Error>?

    /// `relay` is the daemon's own `handle`: each tool's request goes there with the token,
    /// and what it answers goes back to the agent.
    public init(relay: @escaping AppService.Relay,
                log: @escaping @Sendable (String) -> Void = { DaemonLog.shared.write($0) }) {
        self.relay = relay
        self.log = log
    }

    // MARK: Grants

    /// Let `token`'s runtime in, with these tools. A token granted again keeps its sessions
    /// and takes the new tools from its next `tools/list`.
    public func grant(_ token: String, _ grant: Grant) {
        let service = AppService.relaying(token: token, managesAgents: grant.managesAgents,
                                          movesItself: grant.movesItself, relay: relay)
        lock.withLock {
            let holder = Holder(grant: grant, service: service)
            holder.sessions = holders[token]?.sessions ?? []
            holder.streams = holders[token]?.streams ?? [:]
            holders[token] = holder
        }
    }

    /// The session is over: its token is refused from now on, and its event streams end.
    public func revoke(_ token: String) {
        let gone = lock.withLock { holders.removeValue(forKey: token) }
        guard let gone else { return }
        for channel in gone.streams.values.flatMap({ $0 }) { Self.endStream(channel) }
        if !gone.sessions.isEmpty { log("app tools: \(gone.sessions.count) session(s) ended with their token") }
    }

    /// What `token` was granted, if it is still good.
    public func granted(_ token: String) -> Grant? {
        lock.withLock { holders[token]?.grant }
    }

    /// How many MCP sessions `token`'s runtime has open. For tests and the status.
    func openSessions(_ token: String) -> Int {
        lock.withLock { holders[token]?.sessions.count ?? 0 }
    }

    /// The server a session is handed for `token`.
    public static func server(port: Int, token: String) -> MCPServer {
        MCPServer(name: AppTool.serverName,
                  transport: .http(url: "http://127.0.0.1:\(port)\(path)",
                                   headers: ["Authorization": "Bearer \(token)"]))
    }

    // MARK: Requests

    /// An answer, before it is http.
    public struct Reply: Equatable, Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        /// A GET that became an event stream: the head is sent and the connection kept.
        public var stream: Bool

        init(_ status: Int, headers: [String: String] = [:], body: Data = Data(), stream: Bool = false) {
            self.status = status
            self.headers = headers
            self.body = body
            self.stream = stream
        }

        static func json(_ value: JSONValue, session: String? = nil) -> Reply {
            var headers = ["Content-Type": "application/json"]
            if let session { headers["Mcp-Session-Id"] = session }
            // Sorted, so the same tools are the same bytes after a restart (#465).
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return Reply(200, headers: headers, body: (try? encoder.encode(value)) ?? Data())
        }
    }

    /// One request, answered. Pure apart from the token table and what the tools do, so
    /// every row of the transport is a test without a socket.
    public func answer(method: String, path: String, headers: [String: String], body: Data) async -> Reply {
        let header = { (name: String) in
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        // A page in a browser can reach loopback. Nothing here is for one.
        if let origin = header("Origin"), !Self.isLoopbackOrigin(origin) { return Reply(403) }
        guard (path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path) == Self.path else {
            return Reply(404)
        }
        // A token nobody holds, or one whose session is over, is a server that is not
        // there: 404, not 401, which some clients take as a cue to start signing in.
        guard let token = Self.bearer(header("Authorization")),
              let holder = lock.withLock({ holders[token] }) else { return Reply(404) }
        let session = header("Mcp-Session-Id")
        if let session, !lock.withLock({ holder.sessions.contains(session) }) {
            // Over, or never here: the client is told to initialize again.
            return Reply(404)
        }
        switch method {
        case "POST":
            return await post(body, holder: holder, session: session)
        case "GET":
            guard let session else { return Reply(400) }
            guard header("Accept")?.contains("text/event-stream") ?? false else { return Reply(406) }
            return Reply(200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                                        "Mcp-Session-Id": session], stream: true)
        case "DELETE":
            guard let session else { return Reply(400) }
            let streams = lock.withLock { () -> [any Channel] in
                holder.sessions.remove(session)
                return holder.streams.removeValue(forKey: session) ?? []
            }
            for channel in streams { Self.endStream(channel) }
            return Reply(200)
        default:
            return Reply(405, headers: ["Allow": "GET, POST, DELETE"])
        }
    }

    private func post(_ body: Data, holder: Holder, session: String?) async -> Reply {
        guard let parsed = try? JSONValue.parse(body) else {
            return .json(Self.failure(id: nil, JSONRPCError(code: JSONRPCError.parseError, message: "not JSON")))
        }
        // A batch, which the 2025-03-26 revision allowed, or the one message every client sends now.
        let batch = parsed.arrayValue
        var opened: String?
        var answers: [JSONValue] = []
        for message in batch ?? [parsed] {
            guard let object = message.objectValue else {
                answers.append(Self.failure(id: nil, JSONRPCError(code: JSONRPCError.invalidRequest,
                                                                  message: "not a JSON-RPC message")))
                continue
            }
            // A notification, or the client answering something: nothing to say back.
            guard let method = object["method"]?.stringValue, let id = object["id"], id != .null else { continue }
            let result = await holder.service.handle(method: method, params: object["params"])
            if method == "initialize", case .success = result, session == nil {
                let fresh = UUID().uuidString
                lock.withLock { _ = holder.sessions.insert(fresh) }
                opened = fresh
            }
            switch result {
            case .success(let value): answers.append(["jsonrpc": "2.0", "id": id, "result": value])
            case .failure(let error): answers.append(Self.failure(id: id, error))
            }
        }
        guard !answers.isEmpty else { return Reply(202) }
        return .json(batch == nil ? answers[0] : .array(answers), session: opened)
    }

    static func failure(id: JSONValue?, _ error: JSONRPCError) -> JSONValue {
        var shape: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
        if let data = error.data { shape["data"] = data }
        return ["jsonrpc": "2.0", "id": id ?? .null, "error": .object(shape)]
    }

    /// The token in `Authorization: Bearer <token>`.
    static func bearer(_ header: String?) -> String? {
        guard let header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return nil }
        let token = header.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Keep a GET's connection as the session's event stream, until the session or its
    /// token ends or the client goes.
    fileprivate func keep(_ channel: any Channel, token: String?, session: String?) {
        guard let token, let session else { return Self.endStream(channel) }
        let kept = lock.withLock { () -> Bool in
            guard let holder = holders[token], holder.sessions.contains(session) else { return false }
            holder.streams[session, default: []].append(channel)
            return true
        }
        guard kept else { return Self.endStream(channel) }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock {
                guard let holder = self?.holders[token] else { return }
                holder.streams[session]?.removeAll { $0 === channel }
            }
        }
    }

    private static func endStream(_ channel: any Channel) {
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    // MARK: Listening

    /// The port, once one start has bound it: two sessions made at once share it.
    public func start() async throws -> Int {
        let task = lock.withLock { () -> Task<Int, any Error> in
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

    private func listen() async throws -> Int {
        let bound = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandlers([
                        NIOHTTPServerRequestAggregator(maxContentLength: Self.bodyLimit),
                        EndpointHandler(endpoint: self),
                    ])
                }
            }
            // Never any other interface (#185).
            .bind(host: "127.0.0.1", port: 0).get()
        let port = bound.localAddress?.port ?? 0
        lock.withLock { channel = bound }
        log("app tools: serving on 127.0.0.1:\(port)\(Self.path)")
        return port
    }

    /// Everything ends: every token, every stream, the listener.
    public func stop() {
        let (all, listening) = lock.withLock { () -> ([Holder], (any Channel)?) in
            let all = Array(holders.values)
            holders.removeAll()
            let listening = channel
            channel = nil
            starting = nil
            return (all, listening)
        }
        for channel in all.flatMap({ $0.streams.values.flatMap { $0 } }) { Self.endStream(channel) }
        listening?.close(promise: nil)
    }
}

/// One connection's requests, each answered by the endpoint off the event loop.
private final class EndpointHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOHTTPServerRequestFull
    typealias OutboundOut = HTTPServerResponsePart

    private let endpoint: AppToolsEndpoint

    init(endpoint: AppToolsEndpoint) {
        self.endpoint = endpoint
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = unwrapInboundIn(data)
        let channel = context.channel
        var headers: [String: String] = [:]
        for (name, value) in request.head.headers { headers[name] = value }
        let body = request.body.map { Data($0.readableBytesView) } ?? Data()
        let head = request.head
        let endpoint = endpoint
        Task {
            let reply = await endpoint.answer(method: head.method.rawValue, path: head.uri,
                                              headers: headers, body: body)
            var out = HTTPHeaders()
            for (name, value) in reply.headers { out.add(name: name, value: value) }
            if !reply.stream { out.add(name: "Content-Length", value: "\(reply.body.count)") }
            let response = HTTPResponseHead(version: head.version,
                                            status: HTTPResponseStatus(statusCode: reply.status),
                                            headers: out)
            channel.eventLoop.execute {
                channel.write(HTTPServerResponsePart.head(response), promise: nil)
                if reply.stream {
                    channel.flush()
                    endpoint.keep(channel, token: AppToolsEndpoint.bearer(headers.first {
                        $0.key.lowercased() == "authorization" }?.value),
                                  session: headers.first { $0.key.lowercased() == "mcp-session-id" }?.value)
                    return
                }
                if !reply.body.isEmpty {
                    channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: reply.body))), promise: nil)
                }
                channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Too large, or not http: the aggregator has already answered where it could.
        context.close(promise: nil)
    }
}
