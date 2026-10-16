import Foundation

/// Channels (#1012): chat apps that reach the person's agents, answered by the control plane
/// itself. The first is Slack (#1009), and only for Needs You: a waiting question goes out
/// with its options as buttons, and a button or a reply in its thread answers it.
public extension DaemonAPI.Method {
    /// `ChannelsState`: how each channel is set and how it stands. Never a token.
    static let channelsGet = "channels/get"
    /// `ChannelsSet`: what to change. A token is written and never read back.
    static let channelsSet = "channels/set"
}

public extension DaemonAPI.Notification {
    /// `ChannelsState`: a channel was set, or connected, or stopped.
    static let controlChannelsChanged = "control/channelsChanged"
}

/// `control.json`'s channels: what is set, with no secret in it. The tokens are in the
/// control plane's secrets folder (#1035), never the store.
public struct ChannelSettings: Codable, Hashable, Sendable {
    public var slack: SlackChannelSettings?

    public init(slack: SlackChannelSettings? = nil) {
        self.slack = slack
    }
}

public struct SlackChannelSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// The one Slack member tied to the grant (#111): its questions go to this member's
    /// direct messages, and only this member's buttons and replies answer them.
    public var memberID: String

    public init(enabled: Bool = false, memberID: String = "") {
        self.enabled = enabled
        self.memberID = memberID
    }

    /// A Slack member ID: `U` or `W`, then capitals and digits.
    public static func isMemberID(_ text: String) -> Bool {
        text.range(of: #"^[UW][A-Z0-9]{2,}$"#, options: .regularExpression) != nil
    }
}

public extension DaemonAPI {
    /// `channels/get`, and `control/channelsChanged`.
    struct ChannelsState: Codable, Sendable, Hashable {
        public var slack: SlackState

        public init(slack: SlackState) {
            self.slack = slack
        }
    }

    struct SlackState: Codable, Sendable, Hashable {
        public var enabled: Bool
        public var memberID: String
        /// Whether each token is set. The value is never sent.
        public var appTokenSet: Bool
        public var botTokenSet: Bool
        /// `off`, `connecting`, `connected` or `failed`.
        public var status: String
        /// What went wrong, in words, when it failed or can't start.
        public var detail: String?
        /// False where channels can't run: a control plane of several copies, or one with
        /// nowhere to keep secrets.
        public var available: Bool

        public init(enabled: Bool, memberID: String, appTokenSet: Bool, botTokenSet: Bool, status: String,
                    detail: String? = nil, available: Bool = true) {
            self.enabled = enabled
            self.memberID = memberID
            self.appTokenSet = appTokenSet
            self.botTokenSet = botTokenSet
            self.status = status
            self.detail = detail
            self.available = available
        }

        public static let off = "off"
        public static let connecting = "connecting"
        public static let connected = "connected"
        public static let failed = "failed"
    }

    /// `channels/set`.
    struct ChannelsSet: Codable, Sendable, Hashable {
        public var slack: SlackSet?

        public init(slack: SlackSet?) {
            self.slack = slack
        }
    }

    /// Only what is given changes. A token given empty is taken away.
    struct SlackSet: Codable, Sendable, Hashable {
        public var enabled: Bool?
        public var memberID: String?
        /// `xapp-…`, with `connections:write`: Socket Mode's.
        public var appToken: String?
        /// `xoxb-…`: the bot's, for sending and changing messages.
        public var botToken: String?

        public init(enabled: Bool? = nil, memberID: String? = nil, appToken: String? = nil, botToken: String? = nil) {
            self.enabled = enabled
            self.memberID = memberID
            self.appToken = appToken
            self.botToken = botToken
        }
    }
}

/// The control plane's channels, handed to `ControlMethods` by the service that runs them.
public protocol ChannelHandling: Sendable {
    func state() async -> DaemonAPI.ChannelsState
    func set(_ request: DaemonAPI.ChannelsSet) async throws -> DaemonAPI.ChannelsState
}

public extension DaemonAPI.ChannelsState {
    /// Where no channel can run: a control plane of several copies, or with nowhere for secrets.
    static let unavailable = DaemonAPI.ChannelsState(slack: .init(
        enabled: false, memberID: "", appTokenSet: false, botTokenSet: false, status: DaemonAPI.SlackState.off,
        detail: "Channels need a control plane with one copy, for now.", available: false))
}
