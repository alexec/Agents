import Foundation

/// A question the agent is blocked on.
///
/// It is a request, not a notification: the runtime waits until one of its own options
/// comes back. A typed message is not an answer to it, which is why this exists at all
/// and why the daemon has to hold one while there is no window open.
public struct PermissionRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var agentID: UUID
    public var toolCall: ToolCall
    public var options: [PermissionOption]
    public var askedAt: Date

    public init(id: UUID = UUID(), agentID: UUID, toolCall: ToolCall,
                options: [PermissionOption], askedAt: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.toolCall = toolCall
        self.options = options
        self.askedAt = askedAt
    }
}

public struct PermissionOption: Codable, Hashable, Sendable, Identifiable {
    public var optionID: String
    public var name: String
    public var kind: Kind

    public var id: String { optionID }

    public enum Kind: String, Codable, Hashable, Sendable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
        case unknown

        public init(wire: String?) {
            self = Kind(rawValue: wire ?? "") ?? .unknown
        }

        public var allows: Bool { self == .allowOnce || self == .allowAlways }
    }

    public init(optionID: String, name: String, kind: Kind) {
        self.optionID = optionID
        self.name = name
        self.kind = kind
    }
}

/// What an agent is doing, or wants to do. Kept loosely, because every runtime
/// describes its tools differently and none of that is ours to standardise.
public struct ToolCall: Codable, Hashable, Sendable {
    public var toolCallID: String?
    public var title: String
    public var kind: String?
    public var status: String?
    /// The whole thing as it arrived, for the parts of the UI that want detail.
    public var raw: JSONValue?

    public init(toolCallID: String? = nil, title: String, kind: String? = nil,
                status: String? = nil, raw: JSONValue? = nil) {
        self.toolCallID = toolCallID
        self.title = title
        self.kind = kind
        self.status = status
        self.raw = raw
    }
}
