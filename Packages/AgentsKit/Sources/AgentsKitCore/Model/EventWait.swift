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
    /// Its servers' events, each a subscription it holds while it is open (#577). `nil`
    /// on a wait made before then, whose server patterns match on details as they did.
    public var serverEvents: [WaitServerEvent]?

    public init(id: UUID = UUID(), patterns: [EventPattern], from: EventPosition,
                deadline: Date? = nil, since: Date, ending: EventWaitEnding? = nil,
                resumePromptID: UUID? = nil, serverEvents: [WaitServerEvent]? = nil) {
        self.id = id
        self.patterns = patterns
        self.from = from
        self.deadline = deadline
        self.since = since
        self.ending = ending
        self.resumePromptID = resumePromptID
        self.serverEvents = serverEvents
    }

    /// The range a deadline may be given in, the same as 039's check-again.
    public static let deadlineMinutes = 1...1440

    public var isOpen: Bool { ending == nil }

    /// A server's event matches by the subscription that raised it (#577), never by its
    /// details: its `where` went to the server as arguments.
    public func matches(_ event: Event) -> Bool {
        guard event.position > from else { return false }
        if let serverEvents, serverEvents.contains(where: { $0.trigger.matches(event) }) { return true }
        return patterns.contains { pattern in
            (serverEvents == nil || !Self.isServerPattern(pattern.name)) && pattern.matches(event)
        }
    }

    /// Whether a pattern names a server's event, or a server's whole noun (`pr.*`).
    public static func isServerPattern(_ name: String) -> Bool {
        EventCatalogue.isServerEventName(name) || (name.hasSuffix(".*") && EventPattern(name).wholeSubject == nil)
    }

    public func isDue(now: Date) -> Bool {
        isOpen && (deadline.map { $0 <= now } ?? false)
    }

    /// The patterns as the status line and the replies write them, joined with "or".
    public var label: String {
        labels.joined(separator: " or ")
    }

    /// Each pattern's words; a server's event says the servers it was subscribed to.
    public var labels: [String] {
        patterns.map { pattern in
            serverEvents?.first { $0.trigger.event == pattern.name }?.label ?? pattern.label
        }
    }
}

/// One of a wait's servers' events (#577): the subscription it makes, as a trigger
/// makes one, and the servers it was subscribed to when the wait was made.
public struct WaitServerEvent: Codable, Hashable, Sendable {
    /// Its `where` as the subscription's arguments, `server:` taken out.
    public var trigger: MCPEventTrigger
    /// For the words: the servers that offered it then. A server that could not be asked
    /// is subscribed to when it can be, so this may be empty.
    public var servers: [String]

    public init(trigger: MCPEventTrigger, servers: [String]) {
        self.trigger = trigger
        self.servers = servers
    }

    /// "pr.merged on ci (repo alexec/Agents)".
    public var label: String {
        let from = servers.isEmpty ? trigger.servers ?? [] : servers
        let arguments = trigger.arguments.sorted { $0.key < $1.key }
            .map { "\($0.key) \(MCPEventTrigger.words($0.value))" }
        return trigger.event + (from.isEmpty ? "" : " on \(from.joined(separator: " or "))")
            + (arguments.isEmpty ? "" : " (\(arguments.joined(separator: ", ")))")
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
