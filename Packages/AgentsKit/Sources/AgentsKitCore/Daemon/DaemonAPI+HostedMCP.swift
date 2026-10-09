import Foundation

/// MCP servers the daemon hosts (#488): an `mcp.json` entry with `"hosted": true` is run
/// once on the host, shared by every agent and by the workflows that hear its events.
extension DaemonAPI.Method {
    /// Every hosted server this host knows of, for a client that has just connected. Kept
    /// up to date after that by `mcp/hostedChanged`.
    public static let mcpHosted = "mcp/hosted"
}

extension DaemonAPI.Notification {
    /// A hosted server started, idled, stopped or is restarting: the whole
    /// `HostedMCPSnapshot`, which clients replace rather than merge.
    public static let mcpHostedChanged = "mcp/hostedChanged"
}

extension DaemonAPI {
    /// What a hosted server is doing.
    public enum HostedMCPState: String, Codable, Sendable, Hashable {
        /// Nothing uses it, so its process was let go. The next call starts it.
        case idle
        case starting
        case running
        /// It stopped while in use, and is started again at `retryAt`.
        case restarting
    }

    /// One hosted server on this host.
    public struct HostedMCPStatus: Codable, Sendable, Hashable, Identifiable {
        /// The server's name in `mcp.json`.
        public var name: String
        /// The project folder whose `.agents/mcp.json` names it, or nil for the person's own.
        public var project: String?
        public var state: HostedMCPState
        /// Running since, while it runs.
        public var since: Date?
        /// When a restarting server is started again.
        public var retryAt: Date?
        /// Why it last stopped, in words, with the last line it wrote to stderr when it
        /// wrote one.
        public var lastError: String?
        /// How many times it has been started again since the daemon started.
        public var restarts: Int
        /// Sessions and event subscriptions using it now.
        public var users: Int

        public var id: String { (project ?? "~") + "|" + name }

        public init(name: String, project: String?, state: HostedMCPState, since: Date? = nil,
                    retryAt: Date? = nil, lastError: String? = nil, restarts: Int = 0, users: Int = 0) {
            self.name = name; self.project = project; self.state = state; self.since = since
            self.retryAt = retryAt; self.lastError = lastError; self.restarts = restarts; self.users = users
        }
    }

    /// Every hosted server, and the daemon's time when it was read.
    public struct HostedMCPSnapshot: Codable, Sendable, Hashable {
        public var servers: [HostedMCPStatus]
        public var at: Date

        public init(servers: [HostedMCPStatus], at: Date) {
            self.servers = servers
            self.at = at
        }

        public static let empty = HostedMCPSnapshot(servers: [], at: .distantPast)
    }
}
