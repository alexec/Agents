import Foundation

/// An agent's one outstanding wait on events (042 FR-006, FR-007).
///
/// Kept on the agent's record, beside 039's block rather than inside it: a block
/// arrives with the report at the end of a turn and goes with it, where a wait is made
/// in the middle of a turn by a tool call and has to outlast whatever that turn then
/// reports (research R3). On the record it also survives a restart for nothing (FR-014).
///
/// It ends once. `ending` and `resumePromptID` are set in the same write, so an agent is
/// resumed at most once for one wait, across a restart as much as within one.
public struct EventWait: Codable, Hashable, Sendable {
    public var id: UUID
    /// Any one of these will do.
    public var patterns: [EventPattern]
    /// Only events after this position count.
    public var from: EventPosition
    public var deadline: Date?
    public var since: Date
    /// `nil` while it is still waiting.
    public var ending: EventWaitEnding?
    /// The prompt queued to resume the agent, set in the same write as `ending`. A
    /// daemon that finds this set and the prompt not yet sent sends it once.
    public var resumePromptID: UUID?

    public init(id: UUID = UUID(), patterns: [EventPattern], from: EventPosition,
                deadline: Date? = nil, since: Date, ending: EventWaitEnding? = nil,
                resumePromptID: UUID? = nil) {
        self.id = id
        self.patterns = patterns
        self.from = from
        self.deadline = deadline
        self.since = since
        self.ending = ending
        self.resumePromptID = resumePromptID
    }

    /// The range a deadline may be given in, the same as 039's check-again.
    public static let deadlineMinutes = 1...1440

    public var isOpen: Bool { ending == nil }

    public func matches(_ event: Event) -> Bool {
        event.position > from && patterns.contains { $0.matches(event) }
    }

    public func isDue(now: Date) -> Bool {
        isOpen && (deadline.map { $0 <= now } ?? false)
    }

    /// The patterns as the status line and the replies write them, joined with "or".
    public var label: String {
        patterns.map(\.label).joined(separator: " or ")
    }
}

/// How a wait ended.
public enum EventWaitEnding: Codable, Hashable, Sendable {
    /// Its event came. `extraMatches` counts any more that came before it resumed.
    case matched(position: EventPosition, extraMatches: Int)
    case timedOut
    case cancelled(by: Canceller)
    case couldNotWake(reason: String)

    public enum Canceller: String, Codable, Hashable, Sendable {
        case agent
        case person
        /// The person's prompt took the turn (FR-013).
        case prompt
        case stopped
        case archived
    }
}
