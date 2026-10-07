import Foundation

// Views drawn from `ui://` resources (#187, MCP Apps) on the wire.
//
// A view talks to its host, and the host to the server the view came from. The server is
// the daemon, so every client — the Mac's window, the phone, the web page — passes what a
// view asks for through these, naming the conversation the view is in.

public extension DaemonAPI.Method {
    /// A view's resource, read for drawing: its HTML and the policy it is drawn under.
    static let viewsRead = "views/read"
    /// A view's `tools/call`: only a tool of the same server that the view may call.
    static let viewsCall = "views/call"
    /// A view's `notifications/message`, into the daemon's log.
    static let viewsLog = "views/log"
    /// A view's `ui/update-model-context`: kept, and told to the agent with the person's
    /// next message. Empty content takes it back.
    static let viewsContext = "views/context"
    /// An agent calling one of the `agents` server's tools that has a view, relayed by
    /// the endpoint with the agent's token. Answered with the whole `CallToolResult`.
    static let viewsToolCall = "views/toolCall"
    /// The person's Show or Don't Show for a third-party server's view (#191).
    static let viewsShow = "views/show"
}

public extension DaemonAPI.Failure {
    /// A view asked for something the app will not do for it. The message says what.
    static let viewRefused = -32062
    /// A third-party server's view the person has not said Show to (#191). The error's
    /// `data` is a `ViewAsk`: what to ask, and the hash to answer for.
    static let viewNeedsShow = -32063
}

public extension DaemonAPI {
    /// The view's resource, read for the conversation it is drawn in.
    struct ViewReadRequest: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var uri: String
        /// The server whose view it is (#191). Nil is the app's own, `agents`.
        public var server: String?
        /// A pinned view's project, which has no agent (#189, #191).
        public var project: URL?

        public init(agentID: UUID, uri: String, server: String? = nil, project: URL? = nil) {
            self.agentID = agentID
            self.uri = uri
            self.server = server
            self.project = project
        }
    }

    /// What a third-party server's view waits on before it is drawn: the person's Show.
    struct ViewAsk: Codable, Sendable, Hashable {
        public var server: String
        public var uri: String
        /// The resource as it was read, so the answer is for this version of it.
        public var hash: String
        /// Never asked before, rather than changed since the last answer.
        public var isNew: Bool

        public init(server: String, uri: String, hash: String, isNew: Bool) {
            self.server = server
            self.uri = uri
            self.hash = hash
            self.isNew = isNew
        }
    }

    /// The person's answer to a `ViewAsk`.
    struct ViewShowRequest: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var project: URL?
        public var server: String
        public var uri: String
        public var hash: String
        public var show: Bool

        public init(agentID: UUID, project: URL? = nil, server: String, uri: String, hash: String, show: Bool) {
            self.agentID = agentID
            self.project = project
            self.server = server
            self.uri = uri
            self.hash = hash
            self.show = show
        }
    }

    /// What a client draws a view from.
    struct ViewResource: Codable, Sendable, Hashable {
        public var uri: String
        public var mimeType: String
        public var html: String
        /// What the view may reach, already narrowed to what was declared and allowed.
        public var policy: AppViewPolicy
        /// Whether the view asked for a border and background of the host's.
        public var prefersBorder: Bool?
        /// The app's look as the spec's CSS variables (`AppViewTheme`), for the web page,
        /// which has no copy of its own.
        public var variables: [String: String]

        public init(uri: String, mimeType: String = AppViewResourceType.html, html: String,
                    policy: AppViewPolicy, prefersBorder: Bool? = nil,
                    variables: [String: String] = AppViewTheme.variables) {
            self.uri = uri
            self.mimeType = mimeType
            self.html = html
            self.policy = policy
            self.prefersBorder = prefersBorder
            self.variables = variables
        }
    }

    /// A view's `tools/call`.
    struct ViewCallRequest: Codable, Sendable, Hashable {
        public var agentID: UUID
        /// A standalone project view has no agent. The host supplies its project.
        public var project: URL?
        /// The call whose view it is.
        public var viewID: UUID
        public var name: String
        public var arguments: JSONValue?
        /// The host's own call that feeds a pinned view (#189), not the view's: allowed
        /// only for a tool a view may call and that changes nothing (`readOnlyHint`).
        public var feed: Bool?
        /// The server whose view is calling (#191): the one the host holds the call of,
        /// never one the view names. Nil is the app's own, `agents`.
        public var server: String?

        public init(agentID: UUID, viewID: UUID, name: String, arguments: JSONValue? = nil,
                    project: URL? = nil, feed: Bool? = nil, server: String? = nil) {
            self.server = server
            self.agentID = agentID
            self.project = project
            self.viewID = viewID
            self.name = name
            self.arguments = arguments
            self.feed = feed
        }
    }

    /// A view's log line.
    struct ViewLogRequest: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var viewID: UUID
        public var level: String?
        public var data: JSONValue?

        public init(agentID: UUID, viewID: UUID, level: String? = nil, data: JSONValue? = nil) {
            self.agentID = agentID
            self.viewID = viewID
            self.level = level
            self.data = data
        }
    }

    /// A view's `ui/update-model-context`, whole: each replaces the view's last.
    struct ViewContextRequest: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var viewID: UUID
        /// The view's resource, for its name in what the agent is told.
        public var uri: String?
        public var content: JSONValue?
        public var structuredContent: JSONValue?

        public init(agentID: UUID, viewID: UUID, uri: String? = nil, content: JSONValue? = nil,
                    structuredContent: JSONValue? = nil) {
            self.agentID = agentID
            self.viewID = viewID
            self.uri = uri
            self.content = content
            self.structuredContent = structuredContent
        }
    }

    /// An agent's call of a tool with a view, relayed with its token.
    struct ViewToolCallRequest: Codable, Sendable, Hashable {
        public var token: String
        public var name: String
        public var arguments: JSONValue?

        public init(token: String, name: String, arguments: JSONValue? = nil) {
            self.token = token
            self.name = name
            self.arguments = arguments
        }
    }
}

/// The one kind of view there is so far.
public enum AppViewResourceType {
    public static let html = "text/html;profile=mcp-app"
}
