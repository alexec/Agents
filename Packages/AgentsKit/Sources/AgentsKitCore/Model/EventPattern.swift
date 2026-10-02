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
        } else if event.name != name {
            return false
        }
        // A custom event's details are its publisher's, never a set.
        let kind = EventCatalogue.kind(named: event.name)
        return filters.allSatisfy { key, filter in
            filter.matches(event.details[key], isSet: kind?.detail(key)?.isSet ?? false)
        }
    }

    // MARK: Reading one

    /// A pattern checked against the catalogue, or the sentence saying what is wrong
    /// with it, listing what would have been right. An older build's words for a code
    /// are read as the code (073 FR-012); a value a detail cannot have is refused
    /// (FR-019).
    public static func parse(_ given: String, filters: [String: DetailFilter] = [:]) -> Result<EventPattern, EventPatternProblem> {
        let name = given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filters = Dictionary(filters.map { key, filter in
            (key.trimmingCharacters(in: .whitespaces),
             DetailFilter(anyOf: filter.values.map { $0.trimmingCharacters(in: .whitespaces) }) ?? filter)
        }, uniquingKeysWith: { $1 })

        // A whole subject.
        if name.hasSuffix(".*") {
            let subjectName = String(name.dropLast(2))
            guard let subject = EventSubject(rawValue: subjectName) else {
                return .failure(.unknown(name))
            }
            if subject != .custom {
                let carried = Set(EventCatalogue.kinds(in: subject).flatMap(\.details))
                if let bad = filters.keys.sorted().first(where: { !carried.contains($0) }) {
                    return .failure(.badFilter(name: name, key: bad, valid: carried.sorted()))
                }
                return checked(name, filters)
            }
            return .success(EventPattern(name, filters: filters))
        }

        if EventCatalogue.isCustom(name) {
            return .success(EventPattern(name, filters: filters))
        }
        if name.hasPrefix("custom.") {
            return .failure(.badCustomName(name))
        }
        guard let kind = EventCatalogue.kind(named: name) else {
            return .failure(.unknown(name))
        }
        if let bad = filters.keys.sorted().first(where: { !kind.details.contains($0) }) {
            return .failure(.badFilter(name: name, key: bad, valid: kind.details))
        }
        return checked(name, filters)
    }

    /// Old words mapped to codes, then every value checked against its detail's.
    private static func checked(_ name: String, _ filters: [String: DetailFilter]) -> Result<EventPattern, EventPatternProblem> {
        var result: [String: DetailFilter] = [:]
        for key in filters.keys.sorted() {
            guard let filter = filters[key] else { continue }
            guard let detail = EventCatalogue.detail(key, in: name), let valid = detail.values else {
                result[key] = filter
                continue
            }
            var values: [String] = []
            for value in filter.values {
                if valid.contains(value) {
                    values.append(value)
                } else if let code = detail.code(forOldWords: value) {
                    values.append(code)
                } else {
                    return .failure(.badValue(name: name, key: key, valid: valid, given: value))
                }
            }
            result[key] = DetailFilter(anyOf: values) ?? filter
        }
        return .success(EventPattern(name, filters: result))
    }

    /// A stored pattern's old words as codes, without judging anything else: a record
    /// is read, not refused (073 FR-012, research R3).
    func withOldWordsMapped() -> EventPattern {
        var copy = self
        for (key, filter) in filters {
            guard let detail = EventCatalogue.detail(key, in: name), let valid = detail.values else { continue }
            let values = filter.values.map { valid.contains($0) ? $0 : detail.code(forOldWords: $0) ?? $0 }
            copy.filters[key] = DetailFilter(anyOf: values) ?? filter
        }
        return copy
    }

    // MARK: From an event

    /// The pattern that matches this event and ones like it: its name, narrowed by the
    /// event's own details. What Copy as trigger starts from. Not by `agent`, nor by the
    /// agent's labels, runtime or starter (073 FR-025): a copied trigger that fired for
    /// one agent only is rarely what a workflow wants. A custom event keeps every detail
    /// its publisher gave.
    public static func matching(_ event: Event) -> EventPattern {
        let keys: [String]
        if EventCatalogue.isCustom(event.name) {
            keys = Array(event.details.keys)
        } else {
            keys = EventCatalogue.kind(named: event.name)?.detailDescriptions
                .filter { !$0.isContext && $0.key != "agent" }.map(\.key) ?? []
        }
        var filters: [String: DetailFilter] = [:]
        for key in keys { if let value = event.details[key] { filters[key] = DetailFilter(value) } }
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
    /// "An agent in this project ended a turn having done its work (labelled bug, and
    /// parked)". Each filter in its detail's words (073 FR-022); "and …" ones last.
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
        let custom = EventCatalogue.isCustom(name) || wholeSubject == .custom
        let phrases = filters.sorted { $0.key < $1.key }.map { key, filter in
            (custom ? nil : EventCatalogue.detail(key, in: name))?.words(filter.values)
                ?? "\(key) \(filter.values.joined(separator: " or "))"
        }
        let ordered = phrases.filter { !$0.hasPrefix("and ") } + phrases.filter { $0.hasPrefix("and ") }
        var narrowed = ordered.joined(separator: ", ")
        if narrowed.hasPrefix("and ") { narrowed.removeFirst(4) }
        return "\(meaning) (\(narrowed))"
    }

    /// The name with its filters, as the status line writes it:
    /// "workflow.completed workflow nightly", "agent.finished outcome done|nothing_to_do".
    public var label: String {
        var parts = [name]
        for (key, filter) in filters.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key) \(filter.label)")
        }
        return parts.joined(separator: " ")
    }
}

/// Stored inside a wait on an agent's record and inside a run's cause, so a pattern
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
        self = EventPattern(name, filters: filters).withOldWordsMapped()
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
            guard !valid.isEmpty else { return "\(name) carries no details, so it cannot be narrowed by \"\(key)\"." }
            return "\(name) carries \(valid.joined(separator: ", ")); \"\(key)\" is not one of its details."
        case .badValue(let name, let key, let valid, let given):
            return "\(key) on \(name) is one of \(valid.joined(separator: ", ")); \"\(given)\" is not one of them."
        }
    }

    /// The catalogue name nearest to a mistyped one, if any is near enough to suggest.
    static func closest(to name: String) -> String? {
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
