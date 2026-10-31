import Foundation

/// Every MCP server a host's `mcp.json` files name, and how each is doing (#753): the
/// person's own on Activity ▸ MCP Servers, a folder's on its own MCP Servers page.
///
/// A hosted server (#488) says what its one copy is doing. Any other is checked by the
/// host as a session would reach it, `initialize` then `tools/list`, as it starts, when its
/// entry changes, every four hours, and on Check Now.
extension DaemonAPI.Method {
    /// Every server and its health, for a client that has just connected. Kept up to date
    /// after that by `mcp/healthChanged`.
    public static let mcpHealth = "mcp/health"
    /// Check Now: check again the servers of one file, the person's (no folder) or a
    /// folder's. Answers with the snapshot, the checks under way.
    public static let mcpHealthCheck = "mcp/health/check"
}

extension DaemonAPI.Notification {
    /// A server was added, removed, checked or changed state: the whole
    /// `MCPHealthSnapshot`, which clients replace rather than merge.
    public static let mcpHealthChanged = "mcp/healthChanged"
}

extension DaemonAPI {
    public enum MCPTransportName: String, Codable, Sendable, Hashable {
        case stdio, http, sse
    }

    /// How a server not hosted is doing, as its last check found it, or why it is not checked.
    public enum MCPCheckState: String, Codable, Sendable, Hashable {
        /// Not checked yet: it is next.
        case unchecked
        case checking
        /// It answered `initialize` and `tools/list`.
        case answered
        /// It did not answer; `lastError` says why.
        case failed
        /// A folder's server not yet approved here, so it is never started.
        case waiting
        /// It needs a secret that is not set, so it is never started.
        case missingSecret
        /// An http server that wants a sign-in first.
        case signIn
        /// The old sse transport, which the host's client does not speak.
        case oldTransport
    }

    /// One server in one `mcp.json`.
    public struct MCPServerHealth: Codable, Sendable, Hashable, Identifiable {
        /// The server's name in `mcp.json`.
        public var name: String
        /// The folder whose `.agents/mcp.json` names it, or nil for the person's own.
        public var folder: String?
        public var transport: MCPTransportName
        /// Hosted (#488): `live` says what its one copy is doing, and it is not checked.
        public var hosted: Bool
        /// A hosted server's copy, once something has used it; nil before.
        public var live: HostedMCPStatus?
        /// For a server not hosted.
        public var check: MCPCheckState
        /// When its last check ended.
        public var checkedAt: Date?
        /// Why its last check failed, in words.
        public var lastError: String?
        /// How many tools it listed when it last answered.
        public var tools: Int?
        /// The five levels it reaches (#1428), from what it declared when it last answered.
        public var levels: MCPLevels?

        public var id: String { (folder ?? "~") + "|" + name }

        public init(name: String, folder: String?, transport: MCPTransportName, hosted: Bool = false,
                    live: HostedMCPStatus? = nil, check: MCPCheckState = .unchecked, checkedAt: Date? = nil,
                    lastError: String? = nil, tools: Int? = nil, levels: MCPLevels? = nil) {
            self.name = name; self.folder = folder; self.transport = transport; self.hosted = hosted
            self.live = live; self.check = check; self.checkedAt = checkedAt; self.lastError = lastError
            self.tools = tools; self.levels = levels
        }
    }

    /// The five levels a connector reaches (#1428): tools, events and views from what the
    /// server declares; workflows when a ready-made workflow names one of its events; tested
    /// when it was tested on a real account. Never from who made it.
    public struct MCPLevels: Codable, Sendable, Hashable {
        public var tools: Bool
        public var events: Bool
        public var views: Bool
        public var workflows: Bool
        public var tested: Bool

        public init(tools: Bool = false, events: Bool = false, views: Bool = false,
                    workflows: Bool = false, tested: Bool = false) {
            self.tools = tools; self.events = events; self.views = views
            self.workflows = workflows; self.tested = tested
        }

        /// Each level in order, with its name and whether it is reached.
        public var each: [(name: String, reached: Bool)] {
            [("Tools", tools), ("Events", events), ("Views", views), ("Workflows", workflows), ("Tested", tested)]
        }
    }

    /// An `mcp.json` that could not be read, so none of its servers are listed.
    public struct MCPHealthFileProblem: Codable, Sendable, Hashable {
        /// The folder, or nil for the person's own file.
        public var folder: String?
        public var message: String

        public init(folder: String?, message: String) {
            self.folder = folder
            self.message = message
        }
    }

    /// Every server on a host, in each file's order (the person's first, then each folder
    /// by its path), and the daemon's time when it was read.
    public struct MCPHealthSnapshot: Codable, Sendable, Hashable {
        public var servers: [MCPServerHealth]
        public var problems: [MCPHealthFileProblem]
        public var at: Date

        public init(servers: [MCPServerHealth], problems: [MCPHealthFileProblem] = [], at: Date) {
            self.servers = servers
            self.problems = problems
            self.at = at
        }

        public static let empty = MCPHealthSnapshot(servers: [], at: .distantPast)

        /// The person's own servers, for Activity.
        public var personal: [MCPServerHealth] { servers.filter { $0.folder == nil } }

        /// One folder's, for its page in the sidebar.
        public func servers(in folder: String) -> [MCPServerHealth] {
            servers.filter { $0.folder == folder }
        }

        public func problem(in folder: String?) -> String? {
            problems.first { $0.folder == folder }?.message
        }
    }

    /// Check Now on one file's servers.
    public struct MCPHealthCheckRequest: Codable, Sendable, Hashable {
        /// The folder, or nil for the person's own servers.
        public var folder: String?

        public init(folder: String?) { self.folder = folder }
    }
}
