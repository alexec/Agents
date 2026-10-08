import AgentsKitCore
import Foundation

/// The daemon's connections for servers' events (#383, research R3), apart from the views
/// pool: a poll has to keep going all day, where a view's connection idles out.
///
/// - **one connection per server** on this host, shared by its subscriptions;
/// - at most `limit`; the next is refused rather than ending one in use;
/// - **stdio allowed**: the daemon runs its own copy of the server, with the environment
///   and secrets a session would give it, because for events that copy is the integration;
/// - kept while some subscription names it (`keep(only:)`), ended when none does;
/// - each call within `timeout` (15 s, the draft's poll budget).
///
/// Who may be connected to — approved, secrets filled, signed in — is decided before this
/// is asked (`DaemonCore.mcpServer`). Logged: the server's name and a word.
actor MCPEventClients {
    typealias Key = MCPClientPool.Key

    static let limit = 8
    static let timeout: Duration = .seconds(15)
    static let tooMany = "Too many servers with events on this host (\(limit))."

    enum Refusal: Error, Equatable {
        /// The host already holds `limit` connections.
        case tooMany
    }

    private var held: [Key: MCPClient] = [:]
    private var starting: [Key: Task<MCPClient, any Error>] = [:]
    private let http: MCPClient.HTTPSend?
    private let timeout: Duration
    private var listChanged: (@Sendable (Key) -> Void)?

    init(http: MCPClient.HTTPSend? = nil, timeout: Duration = MCPEventClients.timeout) {
        self.http = http
        self.timeout = timeout
    }

    /// Told which server said its events changed.
    func onListChanged(_ handler: @escaping @Sendable (Key) -> Void) { listChanged = handler }

    var count: Int { held.count }

    /// Run `body` with a connected client of `server`, connecting first if none is. A
    /// session the server has forgotten is opened again, once.
    func with<T: Sendable>(_ key: Key, server: MCPServer, cwd: URL,
                           _ body: @Sendable (MCPClient) async throws -> T) async throws -> T {
        let client = try await client(key, server: server, cwd: cwd)
        do {
            return try await body(client)
        } catch MCPClient.Failure.sessionExpired {
            await drop(key)
            return try await body(try await self.client(key, server: server, cwd: cwd))
        }
    }

    /// The server's `events` capability, connecting first if need be: nil when it has none.
    func capability(_ key: Key, server: MCPServer, cwd: URL) async throws -> EventsCapability? {
        let client = try await client(key, server: server, cwd: cwd)
        return await client.eventsCapability
    }

    private func client(_ key: Key, server: MCPServer, cwd: URL) async throws -> MCPClient {
        if let client = held[key] { return client }
        if let task = starting[key] { return try await task.value }
        guard held.count + starting.count < Self.limit else { throw Refusal.tooMany }
        let http = self.http
        let timeout = self.timeout
        let listChanged = self.listChanged
        let task = Task<MCPClient, any Error> {
            let client = MCPClient(server: server, cwd: cwd, timeout: timeout, http: http,
                                   offering: MCPEventsWire.protocolVersions,
                                   onNotification: { method in
                                       if method == MCPEventsWire.listChanged { listChanged?(key) }
                                   })
            do {
                try await client.connect()
            } catch {
                await client.end()
                throw error
            }
            return client
        }
        starting[key] = task
        do {
            let client = try await task.value
            starting[key] = nil
            held[key] = client
            return client
        } catch {
            starting[key] = nil
            throw error
        }
    }

    /// End one connection: it failed, or its entry changed.
    func drop(_ key: Key) async {
        guard let client = held.removeValue(forKey: key) else { return }
        await client.end()
    }

    /// End every connection no subscription names any more.
    func keep(only keys: Set<Key>) async {
        for key in held.keys where !keys.contains(key) { await drop(key) }
    }

    /// End every connection: the daemon is stopping.
    func endAll() async {
        let all = held.values
        held = [:]
        for client in all { await client.end() }
    }
}
