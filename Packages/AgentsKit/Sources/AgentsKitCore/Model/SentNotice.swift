import Foundation

/// What an agent told the person with `notify` (#2805), on the record where it called it:
/// the notification's words, what became of it, and, in the cool-down, when the next can go.
public struct SentNotice: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        /// Sent to where the person is.
        case sent
        /// Not sent: the person was looking at this chat.
        case shownHere
        /// Not sent: the person muted the session (#2003).
        case muted
        /// Not sent: no notice was left until `nextAt`.
        case coolingDown
    }

    public var title: String
    public var body: String?
    public var outcome: Outcome
    public var nextAt: Date?

    public init(title: String, body: String? = nil, outcome: Outcome, nextAt: Date? = nil) {
        self.title = title
        self.body = body
        self.outcome = outcome
        self.nextAt = nextAt
    }

    /// What became of it, in the words every client shows after the time. The cool-down's
    /// are the agent's own: the time it was told.
    public func outcomeText(timeStyle: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
        switch outcome {
        case .sent: return "Sent"
        case .shownHere: return "Shown here"
        case .muted: return "Muted: not sent"
        case .coolingDown:
            guard let nextAt else { return "Not sent: in the cool-down" }
            return "Not sent: the next notice can go at \(timeStyle(nextAt))"
        }
    }
}
