import Foundation

/// The wire shapes we use, and the names of everything either side can call.
///
/// Deliberately thin. Everything a runtime sends that is not listed here stays a
/// `JSONValue` and is either kept whole or ignored, including every `_meta` block:
/// Grok's `x.ai/hooks`, Claude's `jetbrains`, `steering` and `goal`. Reading any of
/// them is how one code path becomes three.
public enum ACP {
    public static let protocolVersion = 1

    // MARK: Methods we call

    public enum Method {
        public static let initialize = "initialize"
        public static let authenticate = "authenticate"
        public static let logout = "logout"
        public static let listProviders = "providers/list"
        public static let setProvider = "providers/set"
        public static let disableProvider = "providers/disable"
        public static let newSession = "session/new"
        public static let loadSession = "session/load"
        public static let resumeSession = "session/resume"
        public static let forkSession = "session/fork"
        public static let deleteSession = "session/delete"
        public static let prompt = "session/prompt"
        public static let cancel = "session/cancel"
        public static let close = "session/close"
        public static let list = "session/list"
        /// Confirmed by handshake against Copilot and the Claude adapter on
        /// 2026-09-18. `session/setConfigOption` and `session/set_option` are both
        /// method-not-found; this spelling is the one that exists.
        public static let setConfigOption = "session/set_config_option"
    }

    /// Named so that "we chose not to" and "we forgot" stay different things. Each of
    /// these is in the spec's Out of Scope section with the reason.
    public enum UnusedMethod {
        public static let setSessionMode = "session/set_mode"
        public static let mcpMessage = "mcp/message"
        public static let cancelRequest = "$/cancel_request"
        public static let nesPrefix = "nes/"
        public static let documentPrefix = "document/did"
    }

    // MARK: Methods we answer

    public enum ClientMethod {
        public static let requestPermission = "session/request_permission"
        public static let sessionUpdate = "session/update"
        public static let readTextFile = "fs/read_text_file"
        public static let writeTextFile = "fs/write_text_file"
        public static let createTerminal = "terminal/create"
        public static let terminalOutput = "terminal/output"
        public static let releaseTerminal = "terminal/release"
        public static let waitForTerminalExit = "terminal/wait_for_exit"
        public static let killTerminal = "terminal/kill"
        public static let createElicitation = "elicitation/create"
        public static let completeElicitation = "elicitation/complete"
    }

    // MARK: What we tell the agent we can do

    /// Advertising a capability is a promise, not a hint. Grok stops doing its own file
    /// reads and writes the moment `fs` is true and has no fallback if we then refuse,
    /// which is why each flag is turned on in the same change that makes it true.
    public struct ClientCapabilities: Hashable, Sendable {
        public var readTextFile: Bool
        public var writeTextFile: Bool
        public var terminal: Bool
        public var booleanConfigOptions: Bool
        public var compaction: Bool
        public var plan: Bool
        public var terminalAuth: Bool
        public var elicitationForm: Bool
        public var elicitationURL: Bool

        public init(readTextFile: Bool = false,
                    writeTextFile: Bool = false,
                    terminal: Bool = false,
                    booleanConfigOptions: Bool = false,
                    compaction: Bool = false,
                    plan: Bool = false,
                    terminalAuth: Bool = false,
                    elicitationForm: Bool = false,
                    elicitationURL: Bool = false) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
            self.terminal = terminal
            self.booleanConfigOptions = booleanConfigOptions
            self.compaction = compaction
            self.plan = plan
            self.terminalAuth = terminalAuth
            self.elicitationForm = elicitationForm
            self.elicitationURL = elicitationURL
        }

        /// What 001 sent. Kept as a named thing so the change that turns a flag on is
        /// visible in one place rather than spread through the handshake.
        public static let none = ClientCapabilities()

        /// What this app actually serves today.
        ///
        /// One place, so that turning a capability on is one line and a review can see
        /// it. A flag here is a promise: a runtime that takes us up on it has no
        /// fallback, so nothing is turned on before the thing behind it works.
        public static let app = ClientCapabilities(
            booleanConfigOptions: true,
            terminalAuth: true)

        public var wire: JSONValue {
            var caps: [String: JSONValue] = [
                "fs": ["readTextFile": .bool(readTextFile), "writeTextFile": .bool(writeTextFile)],
                "terminal": .bool(terminal),
            ]
            var session: [String: JSONValue] = [:]
            if booleanConfigOptions { session["configOptions"] = ["boolean": .object([:])] }
            if compaction { session["compaction"] = .object([:]) }
            if !session.isEmpty { caps["session"] = .object(session) }
            if plan { caps["plan"] = .object([:]) }
            if terminalAuth { caps["auth"] = ["terminal": .bool(true)] }
            var elicitation: [String: JSONValue] = [:]
            if elicitationForm { elicitation["form"] = .object([:]) }
            if elicitationURL { elicitation["url"] = .object([:]) }
            if !elicitation.isEmpty { caps["elicitation"] = .object(elicitation) }
            return .object(caps)
        }
    }

    // MARK: initialize

    public struct InitializeResult: Decodable, Sendable {
        public var protocolVersion: Int?
        public var agentCapabilities: AgentCapabilities?
        public var agentInfo: AgentInfo?
        public var authMethods: [AuthMethod]?

        /// Whether the version the agent answered with is one we speak. An agent that
        /// omits it is taken at its word, which is what every runtime here does.
        public var speaksOurVersion: Bool { (protocolVersion ?? ACP.protocolVersion) == ACP.protocolVersion }

        public var supportsResume: Bool { agentCapabilities?.sessionCapabilities?.resume != nil }
        public var supportsLoad: Bool { agentCapabilities?.loadSession ?? false }
        public var supportsList: Bool { agentCapabilities?.sessionCapabilities?.list != nil }
        public var supportsFork: Bool { agentCapabilities?.sessionCapabilities?.fork != nil }
        public var supportsDelete: Bool { agentCapabilities?.sessionCapabilities?.delete != nil }
        public var supportsClose: Bool { agentCapabilities?.sessionCapabilities?.close != nil }
        public var supportsAdditionalDirectories: Bool {
            agentCapabilities?.sessionCapabilities?.additionalDirectories != nil
        }
        public var supportsLogout: Bool { agentCapabilities?.auth?.logout != nil }
        public var supportsProviders: Bool { agentCapabilities?.providers != nil }

        public var accepts: PromptCapabilities { agentCapabilities?.promptCapabilities ?? PromptCapabilities() }
    }

    public struct AgentCapabilities: Decodable, Sendable {
        public var loadSession: Bool?
        public var promptCapabilities: PromptCapabilities?
        public var mcpCapabilities: MCPCapabilities?
        public var sessionCapabilities: SessionCapabilities?
        public var auth: AgentAuthCapabilities?
        public var providers: JSONValue?
    }

    /// The protocol's own rule: text and resource links are baseline, everything else
    /// is opted in to.
    public struct PromptCapabilities: Decodable, Sendable {
        public var image: Bool?
        public var audio: Bool?
        public var embeddedContext: Bool?

        public init(image: Bool? = nil, audio: Bool? = nil, embeddedContext: Bool? = nil) {
            self.image = image
            self.audio = audio
            self.embeddedContext = embeddedContext
        }

        public func allows(_ requirement: ContentBlock.Requirement?) -> Bool {
            switch requirement {
            case nil: return true
            case .image: return image ?? false
            case .audio: return audio ?? false
            case .embeddedContext: return embeddedContext ?? false
            }
        }
    }

    public struct MCPCapabilities: Decodable, Sendable {
        public var http: Bool?
        public var sse: Bool?
    }

    /// Each of these is `{}` when supported and absent when not, so presence is the
    /// answer and the shape inside is reserved for later.
    public struct SessionCapabilities: Decodable, Sendable {
        public var list: JSONValue?
        public var delete: JSONValue?
        public var additionalDirectories: JSONValue?
        public var fork: JSONValue?
        public var resume: JSONValue?
        public var close: JSONValue?
    }

    public struct AgentAuthCapabilities: Decodable, Sendable {
        public var logout: JSONValue?
    }

    public struct AgentInfo: Decodable, Sendable {
        public var name: String?
        public var title: String?
        public var version: String?
    }

    public struct AuthMethod: Decodable, Hashable, Sendable {
        public var id: String
        public var name: String?
        public var description: String?
        public var _meta: JSONValue?

        /// Copilot puts the command that fixes it in `_meta.terminal-auth`, which is
        /// worth showing verbatim rather than inventing advice of our own.
        public var terminalCommand: String? {
            guard let auth = _meta?["terminal-auth"] else { return nil }
            let command = auth["command"]?.stringValue
            let args = auth["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard let command else { return nil }
            return ([command] + args).joined(separator: " ")
        }
    }

    // MARK: session/new

    public struct NewSessionResult: Decodable, Sendable {
        public var sessionId: String
        // `models` and `modes` also arrive from some runtimes. They are inconsistent
        // between the three and the protocol is retiring them, so they are not decoded.
        //
        // `configOptions` is deliberately NOT decoded here. A shape we cannot read
        // inside the options list must cost that option and never the session, and a
        // field on a `Decodable` struct cannot fail softly. It is read separately from
        // the raw value by `ConfigOption.list(in:)`.
    }

    public struct PromptResult: Decodable, Sendable {
        public var stopReason: String?
    }

    public struct SessionListResult: Decodable, Sendable {
        public var sessions: [SessionSummary]?
        public var nextCursor: String?
    }

    public struct SessionSummary: Decodable, Sendable {
        public var sessionId: String
        public var cwd: String?
        public var title: String?
        public var updatedAt: Date?
        public var additionalDirectories: [String]?

        enum CodingKeys: String, CodingKey {
            case sessionId, cwd, title, updatedAt, additionalDirectories
        }

        /// The runtimes send ISO 8601 with fractional seconds. A date we cannot read is
        /// not worth failing a listing over.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            additionalDirectories = try c.decodeIfPresent([String].self, forKey: .additionalDirectories)
            updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt))
                .flatMap { $0 }
                .flatMap(ACP.timestamp(from:))
        }
    }

    public struct ForkSessionResult: Decodable, Sendable {
        public var sessionId: String
    }

    public struct ProvidersResult: Decodable, Sendable {
        public var providers: [ProviderInfo]?
        public var currentProviderId: String?
    }

    public struct ProviderInfo: Decodable, Hashable, Sendable {
        public var id: String
        public var name: String?
        public var `protocol`: String?
        public var configured: Bool?
    }

    static func timestamp(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
