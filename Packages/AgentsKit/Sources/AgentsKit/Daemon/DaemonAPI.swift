import Foundation

/// What the app asks the daemon, and what the daemon tells every window.
///
/// The same JSON-RPC as the runtimes, over a Unix socket instead of a pipe.
public enum DaemonAPI {
    public enum Method {
        public static let runtimesList = "runtimes/list"
        public static let runtimesAccounts = "runtimes/accounts"
        public static let runtimeAuthenticate = "runtimes/authenticate"
        public static let runtimeLogOut = "runtimes/logout"
        public static let runtimeSetProvider = "runtimes/setProvider"
        public static let sessionsList = "sessions/list"
        public static let sessionsAdopt = "sessions/adopt"
        public static let sessionsDelete = "sessions/delete"
        public static let agentsFork = "agents/fork"
        public static let agentsList = "agents/list"
        public static let agentsOptions = "agents/options"
        public static let agentsStart = "agents/start"
        public static let agentsPrompt = "agents/prompt"
        public static let agentsUnqueue = "agents/unqueue"
        public static let agentsStop = "agents/stop"
        public static let agentsArchive = "agents/archive"
        public static let agentsUnarchive = "agents/unarchive"
        public static let agentsTranscript = "agents/transcript"
        public static let agentsSetOption = "agents/setOption"
        /// Not the app's to call. This is how the MCP server we hand to every agent
        /// gets what the agent passed it back to the agent's own record.
        public static let agentsSuggestPrompts = "agents/suggestPrompts"
        /// Also not the app's to call. How a project lead's tool call, arriving on the
        /// same MCP server, reaches the agents it is allowed to work with.
        public static let agentsLeadTool = "agents/leadTool"
        /// Whether the agent behind a token leads a project, and so whether the helper
        /// may offer the lead's tools at all.
        public static let agentsIsLead = "agents/isLead"
        // A project is a folder. These four are everything that can be done to one,
        // which is to say: notice it, and put it away.
        public static let projectsList = "projects/list"
        public static let projectsAdd = "projects/add"
        public static let projectsArchive = "projects/archive"
        public static let projectsUnarchive = "projects/unarchive"

        public static let permissionsPending = "permissions/pending"
        public static let elicitationsPending = "elicitations/pending"
        public static let elicitationsAnswer = "elicitations/answer"
        public static let permissionsAnswer = "permissions/answer"
        public static let ping = "daemon/ping"

        // The user's own shell in an agent's folder. Deliberately not `terminal/*`,
        // which is 003's and belongs to the agent. Different owner, different
        // identifier space, different lifetime, and nothing crosses (FR-025).
        public static let shellAttach = "shell/attach"
        public static let shellDetach = "shell/detach"
        public static let shellInput = "shell/input"
        public static let shellResize = "shell/resize"
        public static let shellSignal = "shell/signal"
        public static let shellRestart = "shell/restart"
    }

    public enum Notification {
        public static let agentChanged = "agent/changed"
        public static let agentEntry = "agent/entry"
        public static let agentPermission = "agent/permission"
        public static let runtimeChanged = "runtime/changed"
        public static let runtimeAccountChanged = "runtime/account"
        public static let agentUsage = "agent/usage"
        public static let agentPlan = "agent/plan"
        public static let agentElicitation = "agent/elicitation"
        public static let agentTerminalOutput = "agent/terminalOutput"
        /// A project appeared, was archived, or its counts moved. Windows upsert by
        /// folder, the way they upsert agents by id.
        public static let projectChanged = "project/changed"
        /// The user's shell printed something. Raw bytes, base64. Not the agent's
        /// terminal, which is `agentTerminalOutput` above.
        public static let shellOutput = "shell/output"
        public static let shellStateChanged = "shell/stateChanged"
    }

    // MARK: Requests

    /// Which projects to list. Archived ones come back too by default, the same way
    /// archived agents do: the window decides what to draw, not us.
    public struct ProjectsListRequest: Codable, Sendable {
        public var includeArchived: Bool
        public init(includeArchived: Bool = true) { self.includeArchived = includeArchived }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? true
        }
    }

    /// What the MCP helper sends when a project lead calls one of its tools.
    ///
    /// The token, not an agent id, for the same reason the suggestion tool uses one:
    /// the helper is a process the runtime started, anything on this Mac can reach the
    /// daemon's socket, and a token minted for one session is the only thing that says
    /// which agent is calling.
    public struct LeadToolRequest: Codable, Sendable {
        public var token: String
        public var tool: String
        /// The agent being worked with, for the tools that name one.
        public var agentID: UUID?
        /// The instruction for `start_agent`, or the words for `prompt_agent`.
        public var text: String?
        public var title: String?
        public var runtimeID: String?
        public var limit: Int?
        public var before: Int?

        public init(token: String, tool: String, agentID: UUID? = nil, text: String? = nil,
                    title: String? = nil, runtimeID: String? = nil,
                    limit: Int? = nil, before: Int? = nil) {
            self.token = token
            self.tool = tool
            self.agentID = agentID
            self.text = text
            self.title = title
            self.runtimeID = runtimeID
            self.limit = limit
            self.before = before
        }
    }

    /// One project, named by its folder, because the folder is the identity.
    public struct ProjectRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }

    /// A project, plus the parts only the daemon can know.
    ///
    /// The name and the counts are worked out here rather than in the window, so that
    /// two windows cannot disagree and so a sidebar row can say a project needs you
    /// without that window having looked at the project's agents at all.
    public struct ProjectSummary: Codable, Hashable, Sendable, Identifiable {
        public var project: Project
        /// Disambiguated against every project in the same response.
        public var name: String
        /// Whether the directory is there, stamped when this was made.
        public var exists: Bool
        /// The newest activity of any agent in it, or `addedAt` when it has none.
        public var lastActivityAt: Date
        /// How many workers are in each group. The lead is in none of them, so it is
        /// not counted here.
        public var counts: [AgentGroup: Int]
        /// The project's lead, so the panel can pin it and selecting a project can
        /// open its conversation.
        public var leadID: UUID?
        /// Whether the lead is waiting on the user. Marked in the sidebar even though
        /// the lead sits in no group.
        public var leadNeedsInput: Bool

        public var id: URL { project.folder }
        public var folder: URL { project.folder }

        /// Whether anything in this project wants the user, the lead included.
        public var needsInput: Bool { (counts[.needsInput] ?? 0) > 0 || leadNeedsInput }

        public init(project: Project, name: String, exists: Bool, lastActivityAt: Date,
                    counts: [AgentGroup: Int], leadID: UUID? = nil,
                    leadNeedsInput: Bool = false) {
            self.project = project
            self.name = name
            self.exists = exists
            self.lastActivityAt = lastActivityAt
            self.counts = counts
            self.leadID = leadID
            self.leadNeedsInput = leadNeedsInput
        }
    }

    public struct OptionsRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        /// The servers chosen so far. The draft session this makes is the one the
        /// start that follows uses, and a server named after it was made would never
        /// reach the runtime, so they are sent now and checked again at the start.
        public var mcpServers: [MCPServer]

        public init(runtimeID: String, cwd: URL, mcpServers: [MCPServer] = []) {
            self.runtimeID = runtimeID
            self.cwd = cwd
            self.mcpServers = mcpServers
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeID = try c.decode(String.self, forKey: .runtimeID)
            cwd = try c.decode(URL.self, forKey: .cwd)
            mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        }
    }

    /// A session exists before the user has chosen anything, because the options are
    /// advertised by `session/new`. The draft is that session, waiting to be used by
    /// the start that follows, so the user sees one dialog and the runtime is started
    /// once.
    public struct OptionsResponse: Codable, Sendable {
        public var draftID: UUID
        public var options: [ConfigOption]
        public var commands: [SlashCommand]

        public init(draftID: UUID, options: [ConfigOption], commands: [SlashCommand] = []) {
            self.draftID = draftID
            self.options = options
            self.commands = commands
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            draftID = try c.decode(UUID.self, forKey: .draftID)
            options = try c.decodeIfPresent([ConfigOption].self, forKey: .options) ?? []
            commands = try c.decodeIfPresent([SlashCommand].self, forKey: .commands) ?? []
        }
    }

    public struct StartRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        public var prompt: String
        /// What was attached to the prompt: pictures, references to files, the
        /// contents of one. Empty is the ordinary case.
        public var attachments: [Attachment]
        public var startOptions: StartOptions
        public var draftID: UUID?
        public var additionalDirectories: [URL]
        public var mcpServers: [MCPServer]

        public init(runtimeID: String, cwd: URL, prompt: String,
                    attachments: [Attachment] = [],
                    startOptions: StartOptions = .none, draftID: UUID? = nil,
                    additionalDirectories: [URL] = [], mcpServers: [MCPServer] = []) {
            self.runtimeID = runtimeID
            self.cwd = cwd
            self.prompt = prompt
            self.attachments = attachments
            self.startOptions = startOptions
            self.draftID = draftID
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
        }

        /// Fields with a sensible default may be left out. A caller that wants an
        /// agent started with whatever the runtime offers should not have to send an
        /// empty object to say so.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeID = try c.decode(String.self, forKey: .runtimeID)
            cwd = try c.decode(URL.self, forKey: .cwd)
            prompt = try c.decode(String.self, forKey: .prompt)
            attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
            startOptions = try c.decodeIfPresent(StartOptions.self, forKey: .startOptions) ?? .none
            draftID = try c.decodeIfPresent(UUID.self, forKey: .draftID)
            additionalDirectories = try c.decodeIfPresent([URL].self, forKey: .additionalDirectories) ?? []
            mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        }

        /// What goes to the runtime: the words, then whatever was attached.
        public var blocks: [ContentBlock] {
            [.text(prompt)] + attachments.map(\.block)
        }
    }

    public struct AgentRequest: Codable, Sendable {
        public var agentID: UUID
        public init(agentID: UUID) { self.agentID = agentID }
    }

    public struct PromptRequest: Codable, Sendable {
        public var agentID: UUID
        public var text: String
        public var attachments: [Attachment]

        public init(agentID: UUID, text: String, attachments: [Attachment] = []) {
            self.agentID = agentID
            self.text = text
            self.attachments = attachments
        }

        /// An older app sends only the text, so attachments are optional on the way in.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            text = try c.decode(String.self, forKey: .text)
            attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        }

        public var blocks: [ContentBlock] {
            [.text(text)] + attachments.map(\.block)
        }
    }

    /// Take one back off the queue before its turn comes.
    public struct UnqueueRequest: Codable, Sendable {
        public var agentID: UUID
        public var promptID: UUID
        public init(agentID: UUID, promptID: UUID) {
            self.agentID = agentID
            self.promptID = promptID
        }
    }

    /// What the MCP helper sends when an agent calls the suggestion tool.
    ///
    /// The token, not an agent id: the helper is a process the runtime started, and
    /// anything on this Mac can reach the daemon's socket. A token the daemon minted
    /// for one session is the only thing that says which agent this is, and it is
    /// refused the moment that session is over.
    public struct SuggestPromptsRequest: Codable, Sendable {
        public var token: String
        public var prompts: [SuggestedPrompt]

        public init(token: String, prompts: [SuggestedPrompt]) {
            self.token = token
            self.prompts = prompts
        }
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

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            before = try c.decodeIfPresent(Int.self, forKey: .before)
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 200
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

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? true
        }
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

    public struct RuntimeRequest: Codable, Sendable {
        public var runtimeID: String
        public init(runtimeID: String) { self.runtimeID = runtimeID }
    }

    public struct AuthenticateRequest: Codable, Sendable {
        public var runtimeID: String
        public var methodID: String
        public init(runtimeID: String, methodID: String) {
            self.runtimeID = runtimeID
            self.methodID = methodID
        }
    }

    public struct SetProviderRequest: Codable, Sendable {
        public var runtimeID: String
        public var providerID: String
        public init(runtimeID: String, providerID: String) {
            self.runtimeID = runtimeID
            self.providerID = providerID
        }
    }

    public struct SessionsListRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        public init(runtimeID: String, cwd: URL) {
            self.runtimeID = runtimeID
            self.cwd = cwd
        }
    }

    public struct AdoptRequest: Codable, Sendable {
        public var runtimeID: String
        public var sessionID: String
        public var cwd: URL
        public init(runtimeID: String, sessionID: String, cwd: URL) {
            self.runtimeID = runtimeID
            self.sessionID = sessionID
            self.cwd = cwd
        }
    }

    /// The only call in this API that cannot be undone, so it will not happen without
    /// being told twice.
    public struct DeleteSessionRequest: Codable, Sendable {
        public var runtimeID: String
        public var sessionID: String
        public var confirmed: Bool

        public init(runtimeID: String, sessionID: String, confirmed: Bool) {
            self.runtimeID = runtimeID
            self.sessionID = sessionID
            self.confirmed = confirmed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeID = try c.decode(String.self, forKey: .runtimeID)
            sessionID = try c.decode(String.self, forKey: .sessionID)
            confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        }
    }

    public struct ElicitationNotification: Codable, Sendable {
        public var agentID: UUID
        public var requestID: UUID
        /// Nil when the form has been answered or withdrawn.
        public var request: ElicitationRequest?

        public init(agentID: UUID, requestID: UUID, request: ElicitationRequest?) {
            self.agentID = agentID
            self.requestID = requestID
            self.request = request
        }
    }

    public struct TerminalOutputNotification: Codable, Sendable {
        public var agentID: UUID
        public var terminalID: String
        public var chunk: String

        public init(agentID: UUID, terminalID: String, chunk: String) {
            self.agentID = agentID
            self.terminalID = terminalID
            self.chunk = chunk
        }
    }

    public struct AnswerElicitationRequest: Codable, Sendable {
        public var requestID: UUID
        public var action: Action
        public var content: [String: JSONValue]

        public enum Action: String, Codable, Sendable {
            case accept, decline, cancel
        }

        public init(requestID: UUID, action: Action, content: [String: JSONValue] = [:]) {
            self.requestID = requestID
            self.action = action
            self.content = content
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try c.decode(UUID.self, forKey: .requestID)
            action = try c.decodeIfPresent(Action.self, forKey: .action) ?? .cancel
            content = try c.decodeIfPresent([String: JSONValue].self, forKey: .content) ?? [:]
        }
    }

    public struct UsageNotification: Codable, Sendable {
        public var agentID: UUID
        public var usage: Usage
        public init(agentID: UUID, usage: Usage) {
            self.agentID = agentID
            self.usage = usage
        }
    }

    // MARK: Errors the app shows

    // MARK: Shells

    public struct ShellAttachRequest: Codable, Sendable {
        public var agentID: UUID
        public var rows: Int
        public var cols: Int

        public init(agentID: UUID, rows: Int = 24, cols: Int = 80) {
            self.agentID = agentID
            self.rows = rows
            self.cols = cols
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 24
            cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 80
        }
    }

    /// What a window gets on attach: the state, and the bytes to replay.
    ///
    /// Bytes, not a screen. The daemon parses nothing; the window feeds these to its
    /// own emulator and arrives at the screen it would have had if it had been watching
    /// all along (plan decision 2).
    public struct ShellAttachResponse: Codable, Sendable {
        public var state: ShellState
        public var scrollback: Data
        public var dropped: Int
        public var startedAt: Date

        public init(state: ShellState, scrollback: Data, dropped: Int, startedAt: Date) {
            self.state = state
            self.scrollback = scrollback
            self.dropped = dropped
            self.startedAt = startedAt
        }
    }

    public struct ShellInputRequest: Codable, Sendable {
        public var agentID: UUID
        /// What the user typed, as bytes. Never a `String`: a keystroke is not always a
        /// character, and an escape sequence is not text.
        public var bytes: Data

        public init(agentID: UUID, bytes: Data) {
            self.agentID = agentID
            self.bytes = bytes
        }
    }

    public struct ShellResizeRequest: Codable, Sendable {
        public var agentID: UUID
        public var rows: Int
        public var cols: Int

        public init(agentID: UUID, rows: Int, cols: Int) {
            self.agentID = agentID
            self.rows = rows
            self.cols = cols
        }
    }

    public struct ShellSignalRequest: Codable, Sendable {
        public var agentID: UUID
        public var signal: Int32

        public init(agentID: UUID, signal: Int32) {
            self.agentID = agentID
            self.signal = signal
        }
    }

    public struct ShellOutputNotification: Codable, Sendable {
        public var agentID: UUID
        public var bytes: Data

        public init(agentID: UUID, bytes: Data) {
            self.agentID = agentID
            self.bytes = bytes
        }
    }

    public struct ShellStateNotification: Codable, Sendable {
        public var agentID: UUID
        public var state: ShellState

        public init(agentID: UUID, state: ShellState) {
            self.agentID = agentID
            self.state = state
        }
    }

    public enum Failure {
        public static let runtimeNotFound = -32001
        public static let runtimeWillNotStart = -32002
        public static let sessionGone = -32003
        public static let folderGone = -32004
        public static let noSuchAgent = -32005
        /// No longer raised: a prompt sent to a working agent waits its turn rather
        /// than being refused. The number is kept so an older window still reads it.
        public static let alreadyRunning = -32006
        /// The user's login shell is missing, or the agent's folder has gone (FR-024).
        public static let shellWillNotStart = -32010
        /// A restart was asked for on a shell that is still running.
        public static let shellNotLive = -32011
        /// The runtime is installed and will not work until somebody signs in. Its own
        /// auth methods come back in the error's data, including the command Copilot
        /// names for the terminal.
        public static let needsSignIn = -32007
        /// The runtime answered the handshake with a version we do not speak.
        public static let wrongProtocolVersion = -32008
        /// The runtime never said it could do the thing that was asked of it.
        public static let notSupported = -32009
        /// A destructive call that nobody confirmed.
        public static let notConfirmed = -32010
        /// A folder that is not a project, on archive or unarchive.
        public static let noSuchProject = -32012
        /// Archiving a project while one of its agents is still working. Deliberately
        /// unlike archiving an agent, which stops the one it was given: cancelling
        /// several turns because somebody tidied their sidebar is not a small thing,
        /// so this refuses and names them.
        public static let projectHasLiveAgents = -32013
    }
}
