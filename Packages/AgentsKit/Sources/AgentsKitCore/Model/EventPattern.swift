import Foundation

/// Which events something is listening for: a name, or a whole subject, narrowed by
/// details (042 FR-006, FR-021).
///
/// The one matcher. A wait and a workflow trigger are both made of these and both ask
/// `matches`, which is what makes "the same names, the same details" true rather than
/// hoped for.
public struct EventPattern: Hashable, Sendable {
    /// A catalogue name, `subject.*`, or `custom.<name>`.
    public var name: String
    /// Detail keys and the values they may have: one, or any of a list (073). Compared
    /// as strings, so a number written as 41 matches the detail "41".
    public var filters: [String: DetailFilter]

    public init(_ name: String, filters: [String: DetailFilter] = [:]) {
        self.name = name
        self.filters = filters
    }

    /// The subject a `subject.*` pattern names; `nil` for a single name.
    public var wholeSubject: EventSubject? {
        guard name.hasSuffix(".*") else { return nil }
        return EventSubject(rawValue: String(name.dropLast(2)))
    }

    public func matches(_ event: Event) -> Bool {
        if let subject = wholeSubject {
            guard event.subject == subject else { return false }
        } else if name.hasSuffix(".*") {
            // A server's noun (#383): any of its events, never one of the app's.
            guard event.name.hasPrefix(String(name.dropLast())), EventCatalogue.isServerEventName(event.name) else {
                return false
            }
        } else if event.name != name {
            return false
        }
        // Any key at all: a wait stored before #574 keeps matching as it was written.
        return filters.allSatisfy { key, filter in filter.matches(event.details[key]) }
    }

    // MARK: Reading one

    /// A pattern checked against the catalogue, or the sentence saying what is wrong
    /// with it. Only a filter may narrow it (#574): `branch` on `branch.moved`, `why` on
    /// `person.away` and `person.back`. The filters are checked against the kind's
    /// `inputSchema` by `JSONSchemaSubset`, as a server's event's arguments are (#579), so
    /// a refusal reads the same for both. A server's event is not checked here: its keys
    /// are the server's (#383, #577). An old name is unknown like any other (#575).
    public static func parse(_ given: String, filters: [String: DetailFilter] = [:]) -> Result<EventPattern, EventPatternProblem> {
        let name = given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filters = Dictionary(filters.map { key, filter in
            (key.trimmingCharacters(in: .whitespaces),
             DetailFilter(anyOf: filter.values.map { $0.trimmingCharacters(in: .whitespaces) }) ?? filter)
        }, uniquingKeysWith: { $1 })

        if name.hasSuffix(".*") {
            guard EventSubject(rawValue: String(name.dropLast(2))) != nil else {
                // A server's noun (#383): its details are the server's, so none is checked.
                if EventCatalogue.isServerEventName(String(name.dropLast(2)) + ".any") {
                    return .success(EventPattern(name, filters: filters))
                }
                return .failure(.unknown(name))
            }
        } else if !EventCatalogue.isCustom(name) {
            if name.hasPrefix("custom.") { return .failure(.badCustomName(name)) }
            guard EventCatalogue.kind(named: name) != nil else {
                // A server's event (#383): its details are open, as its trigger's keys are.
                if EventCatalogue.isServerEventName(name) { return .success(EventPattern(name, filters: filters)) }
                return .failure(.unknown(name))
            }
        }
        if let problem = Self.problem(filters, against: EventCatalogue.inputSchema(for: name), name: name) {
            return .failure(.badArguments(name: name, message: problem))
        }
        return .success(EventPattern(name, filters: filters))
    }

    /// What is wrong with filters against a schema, as `JSONSchemaSubset` says it. A
    /// list is checked a value at a time, so `why: [locked, asleep]` names `asleep`.
    static func problem(_ filters: [String: DetailFilter], against schema: JSONValue, name: String) -> String? {
        let first = filters.mapValues { JSONValue.string($0.values[0]) }
        if let problem = JSONSchemaSubset.check(.object(first), against: schema, name: name) { return problem }
        for (key, filter) in filters.sorted(by: { $0.key < $1.key }) {
            for value in filter.values.dropFirst() {
                if let problem = JSONSchemaSubset.check([key: .string(value)], against: schema, name: name) {
                    return problem
                }
            }
        }
        return nil
    }

    // MARK: From an event

    /// The pattern that matches this event and ones like it: its name, narrowed by the
    /// event's own values of the filters its kind takes, and nothing else (#574). What
    /// Copy as trigger starts from, so what it copies reads back.
    public static func matching(_ event: Event) -> EventPattern {
        var filters: [String: DetailFilter] = [:]
        for key in EventCatalogue.filterKeys(for: event.name) {
            if let value = event.details[key] { filters[key] = DetailFilter(value) }
        }
        return EventPattern(event.name, filters: filters)
    }

    /// The pattern as a workflow file's `on:` says it, ready to paste (042 wireframes §1).
    /// A list is written inline, and reads back as the same pattern (073 FR-024).
    public var asTrigger: String {
        guard !filters.isEmpty else { return "on:\n  - \(name)" }
        let lines = filters.sorted { $0.key < $1.key }.map { "      \($0.key): \($0.value.yaml)" }
        return (["on:", "  - \(name):"] + lines).joined(separator: "\n")
    }

    /// A value as YAML reads it back as the same string: a number stays bare, and
    /// anything YAML might take for something else is quoted.
    static func yamlScalar(_ value: String) -> String {
        if Int(value) != nil { return value }
        let plain = value.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil
        let reserved = ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(value.lowercased())
        if plain && !reserved { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Words

    /// The kind's meaning, narrowed by what it is filtered on, for the project page:
    /// "A branch moved: the default branch, or one an agent works on (branch main)".
    public var summary: String {
        let meaning: String
        if let subject = wholeSubject {
            meaning = "Anything about \(subject.rawValue)s"
        } else if EventCatalogue.isCustom(name) {
            meaning = "An agent here publishes \(name)"
        } else {
            meaning = EventCatalogue.kind(named: name).map { String($0.meaning.dropLast()) } ?? name
        }
        guard !filters.isEmpty else { return meaning }
        let narrowed = filters.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.values.joined(separator: " or "))" }
        return "\(meaning) (\(narrowed.joined(separator: ", ")))"
    }

    /// The name with its filters, as the status line writes it:
    /// "branch.moved branch main", "person.away why locked|idle".
    public var label: String {
        var parts = [name]
        for (key, filter) in filters.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key) \(filter.label)")
        }
        return parts.joined(separator: " ")
    }
}

/// Stored inside a wait on an agent's record and inside a run's cause, read as written
/// whatever its keys (#574): a record is read, not refused. So a pattern
/// with only single values is written exactly as it always was (073 FR-028). A list
/// is written twice (research R1): joined by `|` under `filters`, which an older build
/// reads as one value that matches nothing rather than as a record it cannot read
/// (FR-029), and whole under `anyOf`, which this build reads.
extension EventPattern: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, filters, anyOf
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        var filters = try c.decode([String: String].self, forKey: .filters).mapValues { DetailFilter($0) }
        for (key, values) in try c.decodeIfPresent([String: [String]].self, forKey: .anyOf) ?? [:] {
            if let filter = DetailFilter(anyOf: values) { filters[key] = filter }
        }
        self = EventPattern(name, filters: filters)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(filters.mapValues(\.label), forKey: .filters)
        let lists = filters.filter { $0.value.single == nil }.mapValues(\.values)
        if !lists.isEmpty { try c.encode(lists, forKey: .anyOf) }
    }
}

/// What was wrong with a pattern, in the sentence the agent (or the workflow page) reads.
public enum EventPatternProblem: Error, Hashable, Sendable {
    case unknown(String)
    case badCustomName(String)
    /// Filters its `inputSchema` does not take: a key it cannot be narrowed by, or a
    /// value a filter cannot have (073 FR-019), in `JSONSchemaSubset`'s words (#579).
    case badArguments(name: String, message: String)

    public var isBadFilter: Bool {
        if case .badArguments = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .unknown(let name):
            let guess = Self.closest(to: name).map { " Did you mean \($0)?" } ?? ""
            let names = EventCatalogue.all.map(\.name).joined(separator: ", ")
            return "\"\(name)\" is not an event.\(guess) Events you can wait on: \(names), custom.<name>, "
                + "or a subject with .* such as agent.*."
        case .badCustomName(let name):
            return "\"\(name)\" is not a custom event name: after custom. it is lowercase letters, digits "
                + "and _, up to 40 characters."
        case .badArguments(let name, let message):
            let agents = EventSubject(name: name) == .agent
                ? " To wait for particular agents, use wait_for_event with agents." : ""
            return message + agents
        }
    }

    /// The catalogue name nearest to a mistyped one, if any is near enough to suggest:
    /// a few letters off (`agent-finished`), or, under another of the app's own nouns,
    /// the one event with the same verb (`mac.disk_low` for `machine.disk_low`). A
    /// server's noun is its own, so `ci.failed` is never `agent.failed`.
    public static func closest(to name: String) -> String? {
        let scored = EventCatalogue.all.map { ($0.name, distance(name, $0.name)) }
        if let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(2, name.count / 4) { return best.0 }
        guard let dot = name.firstIndex(of: "."), name.index(after: dot) < name.endIndex,
              EventCatalogue.reservedNouns.contains(String(name[..<dot])) else { return nil }
        let verb = name[dot...]
        let same = EventCatalogue.all.filter { $0.name.hasSuffix(verb) }
        return same.count == 1 ? same[0].name : nil
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
