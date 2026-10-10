import Foundation

/// What makes a workflow run.
///
/// Closed, with one open case. `unrecognised` is what lets the format grow: a file
/// written against a later version, or by hand against next year's documentation, is
/// listed and inert rather than rejected. The triggers this version defers — file and
/// glob changes, git events, CI — arrive as new cases here and change nothing about a
/// file already on disk. The pull-request triggers 038 added left the same way: a file
/// that still names one lists it as inert.
///
/// Running a workflow by hand is deliberately not in here. Run now is offered on every
/// workflow whatever its triggers, including one whose triggers this version cannot
/// act on, so modelling it as a trigger would make it conditional on the very thing it
/// exists to work around.
public enum WorkflowTrigger: Hashable, Sendable {
    /// On a clock.
    case schedule(WorkflowSchedule)
    /// Any event in the catalogue, a whole subject, or `custom.<name>`, narrowed by
    /// details (042 FR-021): the same pattern a wait uses, so the two cannot drift.
    case event(EventPattern)
    /// An MCP server's event (#383), named as the server names it (`checks.failed`),
    /// with the arguments its subscription sends.
    case serverEvent(MCPEventTrigger)
    /// Understood to be a trigger, and not one this version knows. Kept whole so that
    /// writing the file back does not quietly delete it.
    case unrecognised(name: String, keys: [String: JSONValue])

    /// The name this trigger goes by in a file.
    public var name: String {
        switch self {
        case .schedule: return "schedule"
        case .event(let pattern): return pattern.name
        case .serverEvent(let trigger): return trigger.event
        case .unrecognised(let name, _): return name
        }
    }

    /// The events this trigger answers to, as patterns (042 FR-022), so the page and
    /// the log can say which events a workflow watches in one vocabulary. A schedule is
    /// not an event, and answers to none.
    public var patterns: [EventPattern] {
        switch self {
        case .event(let pattern): return [pattern]
        case .serverEvent(let trigger): return [EventPattern(trigger.event)]
        case .schedule, .unrecognised: return []
        }
    }

    /// Whether an event fires this trigger. A schedule fires from the clock instead.
    public func matches(_ event: Event) -> Bool {
        switch self {
        case .event(let pattern): return pattern.matches(event)
        case .serverEvent(let trigger): return trigger.matches(event)
        default: return false
        }
    }

    /// Whether this version can act on it at all.
    public var isSupported: Bool {
        if case .unrecognised = self { return false }
        return true
    }

    /// The schedule this carries, if it is one.
    public var schedule: WorkflowSchedule? {
        if case .schedule(let schedule) = self { return schedule }
        return nil
    }

    /// The trigger in the words the project page uses.
    public var summary: String {
        switch self {
        case .schedule(let schedule): return schedule.summary
        case .event(let pattern): return "When " + Self.lowercasedFirst(pattern.summary)
        case .serverEvent(let trigger): return trigger.summary
        case .unrecognised(let name, _):
            return "Waits for \"\(name)\", which this version does not know about yet" + Self.guess(for: name)
        }
    }
}

extension WorkflowTrigger {
    /// " Did you mean agent.finished?" for a name near one the catalogue has, such as
    /// a trigger name from before events (#575); empty for anything else.
    public static func guess(for name: String) -> String {
        EventPatternProblem.closest(to: name).map { ". Did you mean \($0)?" } ?? ""
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // "One of my …" reads on after "When"; a name or a code does not change.
        return first.isUppercase && !text.hasPrefix("A ") ? first.lowercased() + text.dropFirst() : text
    }

    /// A filter value as the pattern keeps it: a string, whatever the file wrote.
    static func scalar(_ value: JSONValue) -> String? {
        if let text = value.stringValue { return text }
        if let number = value.intValue { return String(number) }
        if let flag = value.boolValue { return String(flag) }
        return nil
    }

    /// One value or a list of them (073 FR-014), or `nil` for anything else: an
    /// object, a list holding one, an empty list.
    public static func filter(_ value: JSONValue) -> DetailFilter? {
        if let one = scalar(value) { return DetailFilter(one) }
        guard let items = value.arrayValue else { return nil }
        let values = items.compactMap(scalar)
        guard values.count == items.count else { return nil }
        return DetailFilter(anyOf: values)
    }
}

/// Written by hand so that event triggers go over the wire in the shape `.unrecognised`
/// has (042 FR-025). An older Mac or phone then reads one as a trigger it does not know
/// yet, and lists it as inert, rather than failing to read the whole project's
/// workflows. Every other case keeps exactly the shape the compiler gave it, through
/// `Stored`.
extension WorkflowTrigger: Codable {
    private enum Stored: Codable {
        case schedule(WorkflowSchedule)
        case unrecognised(name: String, keys: [String: JSONValue])
    }

    /// The hyphenated triggers a run's cause or an older peer may still carry, by the key
    /// they were stored under (#575). Read as the unknown names they now are, so the
    /// record still loads and matches nothing.
    private static let removed = [
        "agentFinished": "agent-finished", "agentAskedPermission": "agent-asked-permission",
        "agentAskedForm": "agent-asked-form", "agentStopped": "agent-stopped",
        "workflowCompleted": "workflow-completed",
    ]

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let stored: Stored
        do {
            stored = try Stored(from: decoder)
        } catch {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let key = c.allKeys.first, let name = Self.removed[key.stringValue] else { throw error }
            let keys = (try? c.decode([String: JSONValue].self, forKey: key)) ?? [:]
            self = .unrecognised(name: name, keys: keys)
            return
        }
        switch stored {
        case .schedule(let schedule): self = .schedule(schedule)
        case .unrecognised(let name, let keys):
            // A server's event (#383) goes as an unknown trigger does, and is read back
            // as one by its name.
            if EventCatalogue.isServerEventName(name), let trigger = MCPEventTrigger(event: name, keys: keys) {
                self = .serverEvent(trigger)
                return
            }
            // A key whose value is not one value or a list is not dropped: the trigger
            // is then one this version cannot read, and says so (073 SC-002).
            let filters = keys.compactMapValues(Self.filter)
            if name.contains("."), filters.count == keys.count,
                      case .success(let pattern) = EventPattern.parse(name, filters: filters) {
                self = .event(pattern)
            } else {
                self = .unrecognised(name: name, keys: keys)
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let stored: Stored
        switch self {
        case .schedule(let schedule): stored = .schedule(schedule)
        // An older Mac or phone reads it as a trigger it does not know yet, and lists it
        // as inert (042 FR-025).
        case .event(let pattern):
            // A list goes as an array, which an older reader drops (073 research R2).
            stored = .unrecognised(name: pattern.name, keys: pattern.filters.mapValues { filter in
                filter.single.map(JSONValue.string) ?? .array(filter.values.map(JSONValue.string))
            })
        // The same for a server's event: an older reader lists it as inert.
        case .serverEvent(let trigger): stored = .unrecognised(name: trigger.event, keys: trigger.keys)
        case .unrecognised(let name, let keys): stored = .unrecognised(name: name, keys: keys)
        }
        try stored.encode(to: encoder)
    }
}

/// Which agent a fired workflow's prompt goes to.
public enum WorkflowMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// A fresh agent, every fire.
    case new
    /// One long-lived agent belonging to this workflow, resumed each time so it
    /// accumulates context. A standing agent that has gone is replaced, and the
    /// replacement adopted.
    case standing
    /// The agent whose event fired this workflow. When there is no such agent, or it
    /// can no longer take a prompt, the fire is refused rather than sent somewhere else:
    /// substituting would send words meant for one conversation into another.
    case triggering

    public var summary: String {
        switch self {
        case .new: return "in a new agent"
        case .standing: return "in its own standing agent"
        case .triggering: return "in the agent that triggered it"
        }
    }
}
