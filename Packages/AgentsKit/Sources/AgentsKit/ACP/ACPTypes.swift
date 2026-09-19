import Foundation

/// The wire shapes we actually use.
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
        public static let newSession = "session/new"
        public static let loadSession = "session/load"
        public static let resumeSession = "session/resume"
        public static let prompt = "session/prompt"
        public static let cancel = "session/cancel"
        public static let close = "session/close"
        public static let list = "session/list"
        /// Confirmed by handshake against Copilot and the Claude adapter on
        /// 2026-09-18. `session/setConfigOption` and `session/set_option` are both
        /// method-not-found; this spelling is the one that exists.
        public static let setConfigOption = "session/set_config_option"
    }

    // MARK: Methods we answer

    public enum ClientMethod {
        public static let requestPermission = "session/request_permission"
        public static let sessionUpdate = "session/update"
    }

    // MARK: initialize

    public struct InitializeResult: Decodable, Sendable {
        public var protocolVersion: Int?
        public var agentCapabilities: AgentCapabilities?
        public var agentInfo: AgentInfo?
        public var authMethods: [AuthMethod]?

        public var supportsResume: Bool { agentCapabilities?.sessionCapabilities?["resume"] != nil }
        public var supportsLoad: Bool { agentCapabilities?.loadSession ?? false }
    }

    public struct AgentCapabilities: Decodable, Sendable {
        public var loadSession: Bool?
        public var sessionCapabilities: [String: JSONValue]?
    }

    public struct AgentInfo: Decodable, Sendable {
        public var name: String?
        public var title: String?
        public var version: String?
    }

    public struct AuthMethod: Decodable, Sendable {
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
        public var configOptions: [ConfigOption]?
        // `models` and `modes` also arrive from some runtimes. They are inconsistent
        // between the three and the protocol is retiring them, so they are not decoded.
    }

    public struct PromptResult: Decodable, Sendable {
        public var stopReason: String?
    }

    public struct SetConfigOptionResult: Decodable, Sendable {
        public var configOptions: [ConfigOption]?
    }

    public struct SessionListResult: Decodable, Sendable {
        public var sessions: [SessionSummary]?
    }

    public struct SessionSummary: Decodable, Sendable {
        public var sessionId: String
        public var cwd: String?
        public var title: String?
    }
}
