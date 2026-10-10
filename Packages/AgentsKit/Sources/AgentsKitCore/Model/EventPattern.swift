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
    /// with it. An event's old name is read as its new one (#372). Only a filter may
    /// narrow it (#574): `branch` on `branch.moved`, `why` on `person.away` and
    /// `person.back`; any other key, a custom event's own details included, is refused
    /// naming the ones it takes, and a value a filter cannot have names the ones it can.
    /// A server's event is the exception: its keys are the server's to check (#383).
    public static func parse(_ given: String, filters: [String: DetailFilter] = [:]) -> Result<EventPattern, EventPatternProblem> {
        // An old name is read as today's (#372), so a file written before a rename
        // keeps firing.
        let name = EventCatalogue.currentName(given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
        let allowed = EventCatalogue.filters(for: name)
        for key in filters.keys.sorted() {
            guard let detail = allowed.first(where: { $0.key == key }) else {
                return .failure(.badFilter(name: name, key: key, valid: allowed.map(\.key)))
            }
            if let valid = detail.values, let given = filters[key]?.values.first(where: { !valid.contains($0) }) {
                return .failure(.badValue(name: name, key: key, valid: valid, given: given))
            }
        }
        return .success(EventPattern(name, filters: filters))
    }

    // MARK: From an event

    /// The pattern that matches this event and ones like it: its name, narrowed by the
    /// event's own values of the filters its kind takes, and nothing else (#574). What
    /// Copy as trigger starts from, so what it copies reads back.
    public static func matching(_ event: Event) -> EventPattern {
        var filters: [String: DetailFilter] = [:]
        for detail in EventCatalogue.filters(for: event.name) {
            if let value = event.details[detail.key] { filters[detail.key] = DetailFilter(value) }
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
        self = EventPattern(EventCatalogue.currentName(name), filters: filters)
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
    case badFilter(name: String, key: String, valid: [String])
    /// A value a detail with fixed values cannot have (073 FR-019). For a list, the
    /// first wrong one.
    case badValue(name: String, key: String, valid: [String], given: String)

    public var isBadFilter: Bool {
        if case .badFilter = self { return true }
        return false
    }

    public var isBadValue: Bool {
        if case .badValue = self { return true }
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
        case .badFilter(let name, let key, let valid):
            guard !valid.isEmpty else {
                let agents = EventSubject(name: name) == .agent
                    ? " To wait for particular agents, use wait_for_event with agents." : ""
                return "\(name) can't be narrowed, by \"\(key)\" or anything else.\(agents)"
            }
            return "\(name) can be narrowed only by \(valid.joined(separator: ", ")), not by \"\(key)\"."
        case .badValue(let name, let key, let valid, let given):
            return "\(key) on \(name) is one of \(valid.joined(separator: ", ")); \"\(given)\" is not one of them."
        }
    }

    /// The catalogue name nearest to a mistyped one, if any is near enough to suggest.
    public static func closest(to name: String) -> String? {
        let scored = EventCatalogue.all.map { ($0.name, distance(name, $0.name)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(2, name.count / 4) else { return nil }
        return best.0
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
