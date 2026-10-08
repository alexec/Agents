import Foundation

/// How one server's event trigger is doing, for the line under it on the workflow's page
/// (#383, contracts/wire-status.md).
///
/// One per server a trigger hears, in file order and then by server. A trigger no server
/// offers has one, with no server. "Checked 20 s ago" is worked out by each client from
/// `lastPolledAt`, so the status is pushed when it changes and never on a timer.
public struct MCPTriggerStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        /// Connecting, or waiting for the first answer.
        case pending
        case active
        /// Not reached, trying again after a wait.
        case retrying
        /// Not asked again until the file, the server's events, sign-ins or secrets change.
        case stopped
        /// The workflow runs on another host, which asks for its events.
        case notThisHost
    }

    /// The event, such as `checks.failed`.
    public var name: String
    /// The server this line is about; nil when no server offers the event.
    public var server: String?
    public var state: State
    public var lastPolledAt: Date?
    public var lastEventAt: Date?
    /// Events may have been missed since then (the draft's `truncated`).
    public var missedSince: Date?
    public var failure: MCPTriggerFailure?
    /// When it asks next, while retrying, so a line can say "trying again in 40 s".
    public var retryAt: Date?

    public init(name: String, server: String?, state: State, lastPolledAt: Date? = nil, lastEventAt: Date? = nil,
                missedSince: Date? = nil, failure: MCPTriggerFailure? = nil, retryAt: Date? = nil) {
        self.name = name
        self.server = server
        self.state = state
        self.lastPolledAt = lastPolledAt
        self.lastEventAt = lastEventAt
        self.missedSince = missedSince
        self.failure = failure
        self.retryAt = retryAt
    }
}
