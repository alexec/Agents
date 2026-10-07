import AgentsKitCore
import Foundation

/// The app's own connections to people's MCP servers, for their views (#191), on the host
/// that runs the project.
///
/// Bounded, per the "bound data" rule:
/// - **http servers only** (Alex, Q5, 2026-10-06). A stdio server would mean a second copy
///   of it beside the runtime's, so its views are not shown yet; `connect` refuses one.
/// - at most `limit` clients a host; the least recently used is ended first;
/// - at most one start in flight per server: a second asker waits on the first;
/// - each ended `idle` after it was last used;
/// - every call within the client's own timeout (60 s).
///
/// Who may be connected to — approved, secrets filled — is decided before this is asked
/// (`DaemonCore.viewServer`). Logged: the server's name and a word. Never its URL or headers.
actor MCPClientPool {
    struct Key: Hashable, Sendable {
        /// Where the entry is: a project's folder, or the person's own.
        var scope: String
        var name: String
        /// The entry's digest (`ServerViewCatalog.key`), so a changed entry is a new client.
        var entry: String
    }

    enum Refusal: Error, Equatable {
        /// A stdio server: views from local servers are not shown yet.
        case localServer
    }

    static let limit = 4
    static let idle: Duration = .seconds(120)

    private struct Held {
        var client: MCPClient
        var lastUsed: ContinuousClock.Instant
    }

    private var held: [Key: Held] = [:]
    private var starting: [Key: Task<MCPClient, any Error>] = [:]
    private var sweeper: Task<Void, Never>?
    private let timeout: Duration
    private let http: MCPClient.HTTPSend?
    private let idleAfter: Duration

    init(timeout: Duration = .seconds(60), idle: Duration = MCPClientPool.idle, http: MCPClient.HTTPSend? = nil) {
        self.timeout = timeout
        self.idleAfter = idle
        self.http = http
    }

    /// How many are connected, for tests and the log.
    var count: Int { held.count }

    /// Run `body` with a connected client of `server`, connecting first if none is. A
    /// session the server has forgotten is opened again, once.
    func with<T: Sendable>(_ key: Key, server: MCPServer, cwd: URL,
                           _ body: @Sendable (MCPClient) async throws -> T) async throws -> T {
        let client = try await client(key, server: server, cwd: cwd)
        do {
            let answer = try await body(client)
            touch(key)
            return answer
        } catch MCPClient.Failure.sessionExpired {
            await drop(key)
            let again = try await self.client(key, server: server, cwd: cwd)
            let answer = try await body(again)
            touch(key)
            return answer
        }
    }

    /// End every client: the daemon is stopping.
    func endAll() async {
        sweeper?.cancel()
        sweeper = nil
        let all = held.values.map(\.client)
        held = [:]
        for client in all { await client.end() }
    }

    // MARK: Inside

    private func client(_ key: Key, server: MCPServer, cwd: URL) async throws -> MCPClient {
        if let found = held[key] {
            touch(key)
            return found.client
        }
        if let waiting = starting[key] { return try await waiting.value }
        guard case .http = server.transport else { throw Refusal.localServer }
        let timeout = self.timeout
        let http = self.http
        let start = Task<MCPClient, any Error> {
            let client = MCPClient(server: server, cwd: cwd, timeout: timeout, http: http)
            do {
                try await client.connect()
            } catch {
                await client.end()
                throw error
            }
            return client
        }
        starting[key] = start
        defer { starting[key] = nil }
        let client = try await start.value
        await makeRoom()
        held[key] = Held(client: client, lastUsed: .now)
        DaemonLog.shared.write("mcp views: \(key.name) connected (\(held.count) of \(Self.limit))")
        scheduleSweep()
        return client
    }

    private func touch(_ key: Key) {
        held[key]?.lastUsed = .now
    }

    private func drop(_ key: Key) async {
        guard let gone = held.removeValue(forKey: key) else { return }
        await gone.client.end()
    }

    /// The least recently used, ended, until there is room for one more.
    private func makeRoom() async {
        while held.count >= Self.limit,
              let oldest = held.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            DaemonLog.shared.write("mcp views: \(oldest.name) ended to make room")
            await drop(oldest)
        }
    }

    private func scheduleSweep() {
        guard sweeper == nil else { return }
        let wait = idleAfter
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: wait / 4)
                guard let self, await self.sweep() else { return }
            }
        }
    }

    /// End every client idle for `idleAfter`. Whether any are left to watch.
    private func sweep() async -> Bool {
        let now = ContinuousClock.Instant.now
        for (key, entry) in held where now - entry.lastUsed >= idleAfter {
            DaemonLog.shared.write("mcp views: \(key.name) ended, idle")
            await drop(key)
        }
        if held.isEmpty { sweeper = nil }
        return !held.isEmpty
    }
}
