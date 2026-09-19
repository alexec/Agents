import Foundation

/// What the app asks the daemon, and what the daemon tells every window.
///
/// The same JSON-RPC as the runtimes, over a Unix socket instead of a pipe.
public enum DaemonAPI {
    public enum Method {
        public static let runtimesList = "runtimes/list"
        public static let agentsList = "agents/list"
        public static let agentsOptions = "agents/options"
        public static let agentsStart = "agents/start"
        public static let agentsPrompt = "agents/prompt"
        public static let agentsStop = "agents/stop"
        public static let agentsArchive = "agents/archive"
        public static let agentsUnarchive = "agents/unarchive"
        public static let agentsTranscript = "agents/transcript"
        public static let agentsSetOption = "agents/setOption"
        public static let permissionsPending = "permissions/pending"
        public static let permissionsAnswer = "permissions/answer"
        public static let ping = "daemon/ping"
    }

    public enum Notification {
        public static let agentChanged = "agent/changed"
        public static let agentEntry = "agent/entry"
        public static let agentPermission = "agent/permission"
        public static let runtimeChanged = "runtime/changed"
    }

    // MARK: Requests

    public struct OptionsRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        public init(runtimeID: String, cwd: URL) { self.runtimeID = runtimeID; self.cwd = cwd }
    }

    /// A session exists before the user has chosen anything, because the options are
    /// advertised by `session/new`. The draft is that session, waiting to be used by
    /// the start that follows, so the user sees one dialog and the runtime is started
    /// once.
    public struct OptionsResponse: Codable, Sendable {
        public var draftID: UUID
        public var options: [ConfigOption]
        public init(draftID: UUID, options: [ConfigOption]) {
            self.draftID = draftID
            self.options = options
        }
    }

    public struct StartRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        public var prompt: String
        public var startOptions: StartOptions
        public var draftID: UUID?

        public init(runtimeID: String, cwd: URL, prompt: String,
                    startOptions: StartOptions = .none, draftID: UUID? = nil) {
            self.runtimeID = runtimeID
            self.cwd = cwd
            self.prompt = prompt
            self.startOptions = startOptions
            self.draftID = draftID
        }
    }

    public struct AgentRequest: Codable, Sendable {
        public var agentID: UUID
        public init(agentID: UUID) { self.agentID = agentID }
    }

    public struct PromptRequest: Codable, Sendable {
        public var agentID: UUID
        public var text: String
        public init(agentID: UUID, text: String) { self.agentID = agentID; self.text = text }
    }

    public struct TranscriptRequest: Codable, Sendable {
        public var agentID: UUID
        public var before: Int?
        public var limit: Int

        public init(agentID: UUID, before: Int? = nil, limit: Int = 200) {
            self.agentID = agentID
            self.before = before
            self.limit = limit
        }
    }

    public struct SetOptionRequest: Codable, Sendable {
        public var agentID: UUID
        public var optionID: String
        public var value: JSONValue
        public init(agentID: UUID, optionID: String, value: JSONValue) {
            self.agentID = agentID
            self.optionID = optionID
            self.value = value
        }
    }

    public struct AnswerRequest: Codable, Sendable {
        public var permissionID: UUID
        public var optionID: String
        public init(permissionID: UUID, optionID: String) {
            self.permissionID = permissionID
            self.optionID = optionID
        }
    }

    public struct ListRequest: Codable, Sendable {
        public var includeArchived: Bool
        public init(includeArchived: Bool = true) { self.includeArchived = includeArchived }
    }

    // MARK: Notifications

    public struct EntryNotification: Codable, Sendable {
        public var agentID: UUID
        public var entry: TranscriptEntry
        public init(agentID: UUID, entry: TranscriptEntry) {
            self.agentID = agentID
            self.entry = entry
        }
    }

    public struct PermissionNotification: Codable, Sendable {
        public var agentID: UUID
        /// Nil when the question has been answered and is no longer waiting.
        public var request: PermissionRequest?
        public init(agentID: UUID, request: PermissionRequest?) {
            self.agentID = agentID
            self.request = request
        }
    }

    // MARK: Errors the app shows

    public enum Failure {
        public static let runtimeNotFound = -32001
        public static let runtimeWillNotStart = -32002
        public static let sessionGone = -32003
        public static let folderGone = -32004
        public static let noSuchAgent = -32005
        public static let alreadyRunning = -32006
    }
}
