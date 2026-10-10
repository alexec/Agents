import AgentsKitCore
import Foundation

/// MCP servers the daemon hosts (#488): one copy per host of an `mcp.json` stdio entry with
/// `"hosted": true`, shared by every agent and by the workflows that hear its events.
///
/// - **One process per entry**, in a process group of its own (`RuntimeProcess`), with the
///   environment and secrets a session would give it. Ended with the daemon.
/// - **Served over the app's own loopback endpoint** (#185) at `/mcp/hosted/<route>`, with
///   each session's token as the bearer. A runtime is handed it as an http server, so every
///   runtime, Copilot included, takes it as it is.
/// - **Many clients, one server:** a stdio server speaks to one client, so the daemon is that
///   client. It initializes the server once and answers each client's `initialize` with what
///   the server said (the protocol version the client asked for, when it asked for one);
///   requests go through with ids of the daemon's own, and their answers come back with the
///   client's. A client's notifications (`initialized`, `cancelled`) stop here.
/// - **Idles like a session:** in use while a session holding its route or an event
///   subscription naming it is open. When the last one ends the process is let go; the next
///   call starts it again.
/// - **Restarted with backoff** when it stops while in use: 1 s, 2 s, 4 s … up to a minute,
///   back to 1 s once it has run a minute. Its last error is kept for the status.
/// - **stderr to a file of its own**, `<root>/mcp-logs/<name>-<scope digest>.log`, rolled at 1 MB.
///   The status keeps its last line.
///
/// Logged: the server's name and a word, never its command, arguments, environment or
/// any body (054 FR-023).
actor HostedMCPServers {
    typealias Key = MCPClientPool.Key

    /// Hosted servers in use at once on a host: the same bound as events' connections.
    static let limit = 8
    static let pathPrefix = "/mcp/hosted/"
    /// What a call may take before the client is told it timed out. Long: a tool may be slow.
    static let callTimeout: Duration = .seconds(300)
    static let startTimeout: Duration = .seconds(60)
    static let backoffCeiling: TimeInterval = 60
    /// A server that ran this long before it stopped starts its backoff again from 1 s.
    static let steadyAfter: TimeInterval = 60
    static let logLimit = 1 << 20

    enum Refusal: Error, Equatable {
        /// `limit` other hosted servers are in use.
        case tooMany
    }

    /// One hosted entry and what it is doing.
    private final class Hosted {
        let key: Key
        let route: String
        /// The project folder whose file names it; nil for the person's own.
        let project: String?
        var server: MCPServer
        var cwd: URL
        var users: Set<String> = []
        /// MCP sessions opened by clients. Kept across restarts: the daemon is the
        /// server's one client, and it initializes the server again itself.
        var sessions: Set<String> = []
        var state: DaemonAPI.HostedMCPState = .idle
        var process: RuntimeProcess?
        /// Which start the process is: an exit from an older one is not this one's.
        var generation = 0
        var starting: Task<JSONValue, any Error>?
        /// The server's answer to the daemon's `initialize`.
        var initialized: JSONValue?
        var waiting: [String: CheckedContinuation<JSONValue, Never>] = [:]
        var since: Date?
        var retryAt: Date?
        var retry: Task<Void, Never>?
        var lastError: String?
        var lastStderr: String?
        var restarts = 0
        /// Stops in a row that came soon after a start.
        var failures = 0
        var log: DaemonLog?

        init(key: Key, route: String, project: String?, server: MCPServer, cwd: URL) {
            self.key = key; self.route = route; self.project = project; self.server = server; self.cwd = cwd
        }
    }

    private var hosted: [Key: Hosted] = [:]
    private var byRoute: [String: Key] = [:]
    private var nextID = 0
    private let logFolder: URL?
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private var onChange: (@Sendable () -> Void)?
    private var onNotification: (@Sendable (Key, String) -> Void)?
    private var stopped = false

    init(logFolder: URL?, log: @escaping @Sendable (String) -> Void = { DaemonLog.shared.write($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.logFolder = logFolder
        self.log = log
        self.now = now
    }

    /// Told whenever a server's status changes.
    func onChange(_ handler: @escaping @Sendable () -> Void) { onChange = handler }

    /// Told the method of each notification a server sends (#383's `list_changed`).
    func onNotification(_ handler: @escaping @Sendable (Key, String) -> Void) { onNotification = handler }

    // MARK: Users

    /// `user` (a session's token, or an event subscription's) uses `server`: the path it is
    /// served at. Nothing starts until the first call.
    func use(_ server: MCPServer, key: Key, project: String?, cwd: URL, user: String) throws -> String {
        if let held = hosted[key] {
            if held.users.isEmpty, inUse >= Self.limit { throw Refusal.tooMany }
            held.server = server
            held.cwd = cwd
            if held.users.insert(user).inserted { changed() }
            return Self.pathPrefix + held.route
        }
        guard inUse < Self.limit else { throw Refusal.tooMany }
        // The same server under an entry since changed, unused: forgotten, so the list
        // holds what the files say now (bound data).
        for (old, held) in hosted where old.scope == key.scope && old.name == key.name && held.users.isEmpty {
            hosted.removeValue(forKey: old)
            byRoute.removeValue(forKey: held.route)
        }
        let route = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let held = Hosted(key: key, route: route, project: project, server: server, cwd: cwd)
        held.users.insert(user)
        hosted[key] = held
        byRoute[route] = key
        changed()
        return Self.pathPrefix + route
    }

    /// `user` is over: its session ended, or no subscription names the server any more. A
    /// server nobody uses is let go.
    func release(_ user: String) {
        for held in hosted.values where held.users.remove(user) != nil {
            if held.users.isEmpty { idle(held) }
            changed()
        }
    }

    /// Release `user` from every server but `keys`.
    func release(_ user: String, except keys: Set<Key>) {
        for held in hosted.values where !keys.contains(held.key) && held.users.remove(user) != nil {
            if held.users.isEmpty { idle(held) }
            changed()
        }
    }

    private var inUse: Int { hosted.values.filter { !$0.users.isEmpty }.count }

    /// Who uses the server: for tests.
    func users(_ key: Key) -> Set<String> { hosted[key]?.users ?? [] }

    func pid(_ key: Key) -> Int32? { hosted[key]?.process?.processIdentifier }

    // MARK: Status

    func snapshot() -> DaemonAPI.HostedMCPSnapshot {
        let servers = hosted.values.map { held in
            DaemonAPI.HostedMCPStatus(name: held.key.name, project: held.project, state: held.state,
                                      since: held.since, retryAt: held.retryAt,
                                      lastError: held.lastError, restarts: held.restarts, users: held.users.count)
        }.sorted { ($0.project ?? "", $0.name) < ($1.project ?? "", $1.name) }
        return DaemonAPI.HostedMCPSnapshot(servers: servers, at: now())
    }

    func status(_ key: Key) -> DaemonAPI.HostedMCPStatus? {
        guard let held = hosted[key] else { return nil }
        return DaemonAPI.HostedMCPStatus(name: held.key.name, project: held.project, state: held.state,
                                         since: held.since, retryAt: held.retryAt, lastError: held.lastError,
                                         restarts: held.restarts, users: held.users.count)
    }

    private func changed() { onChange?() }

    // MARK: http

    /// One request to `/mcp/hosted/<route>`, from the app's endpoint. A token that does not
    /// use the route, or a session it does not know, is 404: a server that is not there.
    func answer(path: String, token: String?, session: String?, method: String,
                body: Data) async -> AppToolsEndpoint.Reply {
        let route = String(path.split(separator: "?", maxSplits: 1).first.map(String.init)?
            .dropFirst(Self.pathPrefix.count) ?? "")
        guard let token, let key = byRoute[route], let held = hosted[key], held.users.contains(token) else {
            return AppToolsEndpoint.Reply(404)
        }
        if let session, !held.sessions.contains(session) { return AppToolsEndpoint.Reply(404) }
        switch method {
        case "POST":
            return await post(body, held: held, session: session)
        case "DELETE":
            guard let session else { return AppToolsEndpoint.Reply(400) }
            held.sessions.remove(session)
            return AppToolsEndpoint.Reply(200)
        default:
            // No stream: what the server says first does not reach a client (as the bridge).
            return AppToolsEndpoint.Reply(405, headers: ["Allow": "POST, DELETE"])
        }
    }

    private func post(_ body: Data, held: Hosted, session: String?) async -> AppToolsEndpoint.Reply {
        guard let parsed = try? JSONValue.parse(body) else {
            return .json(AppToolsEndpoint.failure(id: nil, JSONRPCError(code: JSONRPCError.parseError,
                                                                        message: "not JSON")))
        }
        let batch = parsed.arrayValue
        var opened: String?
        var answers: [JSONValue] = []
        for message in batch ?? [parsed] {
            guard let object = message.objectValue else {
                answers.append(AppToolsEndpoint.failure(id: nil, JSONRPCError(code: JSONRPCError.invalidRequest,
                                                                              message: "not a JSON-RPC message")))
                continue
            }
            // A notification, or the client answering something: it stops here.
            guard let method = object["method"]?.stringValue, let id = object["id"], id != .null else { continue }
            switch await call(held, method: method, params: object["params"]) {
            case .success(var result):
                if method == "initialize" {
                    if let asked = object["params"]?["protocolVersion"]?.stringValue, case .object(var shape) = result {
                        shape["protocolVersion"] = .string(asked)
                        result = .object(shape)
                    }
                    if session == nil {
                        let fresh = UUID().uuidString
                        held.sessions.insert(fresh)
                        opened = fresh
                    }
                }
                answers.append(["jsonrpc": "2.0", "id": id, "result": result])
            case .failure(let error):
                answers.append(AppToolsEndpoint.failure(id: id, error))
            }
        }
        guard !answers.isEmpty else { return AppToolsEndpoint.Reply(202) }
        return .json(batch == nil ? answers[0] : .array(answers), session: opened)
    }

    /// One request to the server, started first when it is not running.
    private func call(_ held: Hosted, method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        let initialized: JSONValue
        do {
            initialized = try await ready(held)
        } catch let error as JSONRPCError {
            return .failure(error)
        } catch {
            return .failure(JSONRPCError(code: -32000, message: "\(held.key.name) could not be started."))
        }
        switch method {
        case "initialize": return .success(initialized)
        case "ping": return .success([:])
        default: return await send(held, method: method, params: params, timeout: Self.callTimeout)
        }
    }

    // MARK: The process

    /// The server's `initialize` result, starting it first if need be.
    private func ready(_ held: Hosted) async throws -> JSONValue {
        if held.state == .running, let initialized = held.initialized { return initialized }
        if let starting = held.starting { return try await starting.value }
        if held.state == .restarting {
            throw JSONRPCError(code: -32000, message: "\(held.key.name) is restarting"
                               + (held.lastError.map { ": \($0)" } ?? "."))
        }
        guard !stopped else { throw JSONRPCError(code: -32000, message: "The app is stopping.") }
        let task = Task { try await self.start(held) }
        held.starting = task
        defer { held.starting = nil }
        return try await task.value
    }

    private func start(_ held: Hosted) async throws -> JSONValue {
        guard case .stdio(let command, let args, let env) = held.server.transport else {
            throw JSONRPCError(code: -32000, message: "\(held.key.name) is not a local server.")
        }
        held.generation += 1
        let generation = held.generation
        held.state = .starting
        held.initialized = nil
        changed()
        let key = held.key
        let stderr = stderrLog(held)
        let process: RuntimeProcess
        do {
            process = try RuntimeProcess(
                executable: URL(filePath: "/usr/bin/env"), arguments: [command] + args, cwd: held.cwd,
                environment: RuntimeEnvironment.forRuntimes().merging(env) { $1 },
                onStandardError: { [weak self] text in
                    stderr?.write(text.trimmingCharacters(in: .newlines))
                    Task { await self?.heard(stderr: text, key: key) }
                },
                onExit: { [weak self] code in Task { await self?.exited(key, generation: generation, code: code) } })
        } catch {
            log("hosted mcp: \(held.key.name) could not start")
            stoppedWhileInUse(held, why: "It could not be started.")
            throw JSONRPCError(code: -32000, message: "\(held.key.name) could not be started.")
        }
        held.process = process
        log("hosted mcp: \(held.key.name) started (pid \(process.processIdentifier))")
        let lines = process.transport.lines()
        Task { [weak self] in
            do {
                for try await line in lines { await self?.heard(line: line, key: key, generation: generation) }
            } catch {}
        }
        let params: JSONValue = [
            "protocolVersion": .string(MCPEventsWire.protocolVersions[0]),
            "capabilities": ["extensions": MCPClient.extensions],
            "clientInfo": ["name": "Agents", "version": "1"],
        ]
        switch await send(held, method: "initialize", params: params, timeout: Self.startTimeout) {
        case .success(let result) where held.generation == generation:
            write(held, ["jsonrpc": "2.0", "method": "notifications/initialized"])
            held.initialized = result
            held.state = .running
            held.since = now()
            held.retryAt = nil
            changed()
            return result
        case .success:
            throw JSONRPCError(code: -32000, message: "\(held.key.name) stopped as it started.")
        case .failure(let error):
            if held.generation == generation, held.state == .starting {
                held.process?.terminate()
                stoppedWhileInUse(held, why: "It did not answer initialize: \(error.message)")
            }
            throw error
        }
    }

    /// Send one request with an id of the daemon's own, and wait for its answer.
    private func send(_ held: Hosted, method: String, params: JSONValue?,
                      timeout: Duration) async -> Result<JSONValue, JSONRPCError> {
        guard let process = held.process, process.isRunning else {
            return .failure(JSONRPCError(code: -32000, message: "\(held.key.name) is not running."))
        }
        nextID += 1
        let id = "h\(nextID)"
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method)]
        if let params { message["params"] = params }
        let answer: JSONValue = await withCheckedContinuation { done in
            held.waiting[id] = done
            if !write(held, .object(message)) {
                held.waiting.removeValue(forKey: id)?.resume(returning: Self.stoppedAnswer(held))
                return
            }
            let key = held.key
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timedOut(key, id: id)
            }
        }
        if let error = answer["error"]?.objectValue {
            return .failure(JSONRPCError(code: error["code"]?.intValue ?? -32000,
                                         message: error["message"]?.stringValue ?? "The server refused.",
                                         data: error["data"]))
        }
        return .success(answer["result"] ?? .null)
    }

    private static func stoppedAnswer(_ held: Hosted) -> JSONValue {
        ["error": ["code": -32000, "message": .string(held.lastError ?? "\(held.key.name) stopped.")]]
    }

    private func timedOut(_ key: Key, id: String) {
        guard let held = hosted[key], let done = held.waiting.removeValue(forKey: id) else { return }
        done.resume(returning: ["error": ["code": -32001, "message": .string("\(key.name) did not answer in time.")]])
    }

    @discardableResult
    private func write(_ held: Hosted, _ message: JSONValue) -> Bool {
        guard let process = held.process,
              let data = try? JSONEncoder().encode(message),
              let line = String(data: data, encoding: .utf8) else { return false }
        do {
            try process.transport.write(line: line)
            return true
        } catch {
            return false
        }
    }

    private func heard(line: String, key: Key, generation: Int) {
        guard let held = hosted[key], held.generation == generation,
              let message = try? JSONValue.parse(Data(line.utf8)), let object = message.objectValue else { return }
        if let method = object["method"]?.stringValue {
            // The server asking something of its client: told no, so it does not wait.
            if let id = object["id"], id != .null {
                write(held, ["jsonrpc": "2.0", "id": id,
                             "error": ["code": .int(JSONRPCError.methodNotFound), "message": "Not passed on by the app."]])
            } else {
                onNotification?(key, method)
            }
            return
        }
        guard let id = object["id"]?.stringValue, let done = held.waiting.removeValue(forKey: id) else { return }
        done.resume(returning: message)
    }

    private func heard(stderr text: String, key: Key) {
        guard let held = hosted[key],
              let last = text.split(whereSeparator: \.isNewline).last(where: {
                  !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        held.lastStderr = String(last.prefix(300))
    }

    private func exited(_ key: Key, generation: Int, code: Int32) {
        guard let held = hosted[key], held.generation == generation else { return }
        held.process?.cleanUp()
        held.process = nil
        held.initialized = nil
        let pending = held.waiting
        held.waiting = [:]
        // `env` says 127 when it found no such command.
        let why = code == 127 ? "The command was not found." : "It stopped (exit code \(code))."
        let answer: JSONValue = ["error": ["code": -32000, "message": .string("\(key.name) stopped: \(why)")]]
        for done in pending.values { done.resume(returning: answer) }
        guard held.state != .idle else { return }
        log("hosted mcp: \(key.name) stopped (exit \(code))")
        stoppedWhileInUse(held, why: why)
    }

    /// It stopped, or never started, while something used it: started again after a
    /// wait that doubles with each quick failure.
    private func stoppedWhileInUse(_ held: Hosted, why: String) {
        held.process = nil
        held.initialized = nil
        held.lastError = held.lastStderr.map { "\(why) \($0)" } ?? why
        held.lastStderr = nil
        let ran = held.since.map { now().timeIntervalSince($0) } ?? 0
        held.failures = ran >= Self.steadyAfter ? 1 : held.failures + 1
        held.since = nil
        guard !held.users.isEmpty, !stopped else {
            held.state = .idle
            changed()
            return
        }
        let wait = min(Self.backoffCeiling, pow(2, Double(held.failures - 1)))
        held.state = .restarting
        held.retryAt = now().addingTimeInterval(wait)
        held.retry?.cancel()
        let key = held.key
        held.retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.restart(key)
        }
        changed()
    }

    private func restart(_ key: Key) async {
        guard let held = hosted[key], held.state == .restarting, !held.users.isEmpty, !stopped else { return }
        held.state = .idle
        held.retryAt = nil
        held.restarts += 1
        _ = try? await ready(held)
    }

    /// Let the process go: nothing uses it.
    private func idle(_ held: Hosted) {
        held.retry?.cancel()
        held.retry = nil
        held.retryAt = nil
        held.state = .idle
        held.since = nil
        held.sessions = []
        held.initialized = nil
        guard let process = held.process else { return }
        held.process = nil
        held.generation += 1
        for done in held.waiting.values {
            done.resume(returning: ["error": ["code": -32000, "message": .string("\(held.key.name) is no longer in use.")]])
        }
        held.waiting = [:]
        process.terminate()
        Self.killLater(process)
        log("hosted mcp: \(held.key.name) idle")
    }

    private static func killLater(_ process: RuntimeProcess) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { process.kill() }
            try? await Task.sleep(for: .seconds(1))
            process.cleanUp()
        }
    }

    /// Every server ends: the daemon is stopping.
    func stopAll() {
        stopped = true
        for held in hosted.values {
            held.users = []
            idle(held)
        }
    }

    /// The same file for the same server in the same place, run after run.
    static func logName(_ key: Key) -> String {
        let safe = String(key.name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.scope.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "\(safe)-\(String(hash, radix: 16).prefix(8)).log"
    }

    private func stderrLog(_ held: Hosted) -> DaemonLog? {
        if let log = held.log { return log }
        guard let logFolder else { return nil }
        try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        let log = DaemonLog(limit: Self.logLimit)
        log.setDestination(logFolder.appending(path: Self.logName(held.key)))
        held.log = log
        return log
    }
}
