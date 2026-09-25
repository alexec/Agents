import Foundation

/// Which events something is listening for: a name, or a whole subject, narrowed by
/// details (042 FR-006, FR-021).
///
/// The one matcher. A wait and a workflow trigger are both made of these and both ask
/// `matches`, which is what makes "the same names, the same details" true rather than
/// hoped for.
public struct EventPattern: Codable, Hashable, Sendable {
    /// A catalogue name, `subject.*`, or `custom.<name>`.
    public var name: String
    /// Detail keys and the values they must have. Compared as strings, so a number
    /// written as 41 matches the detail "41".
    public var filters: [String: String]

    public init(_ name: String, filters: [String: String] = [:]) {
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
        return filters.allSatisfy { event.details[$0.key] == $0.value }
    }

    // MARK: Reading one

    /// A pattern checked against the catalogue, or the sentence saying what is wrong
    /// with it, listing what would have been right.
    public static func parse(_ given: String, filters: [String: String] = [:]) -> Result<EventPattern, EventPatternProblem> {
        let name = given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filters = Dictionary(uniqueKeysWithValues: filters.map {
            ($0.key.trimmingCharacters(in: .whitespaces), $0.value.trimmingCharacters(in: .whitespaces))
        })

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
        return .success(EventPattern(name, filters: filters))
    }

    // MARK: From an event

    /// The pattern that matches this event and ones like it: its name, narrowed by the
    /// details its kind lets a trigger filter on. What Copy as trigger starts from.
    public static func matching(_ event: Event) -> EventPattern {
        let keys: [String]
        if EventCatalogue.isCustom(event.name) {
            keys = Array(event.details.keys)
        } else {
            keys = EventCatalogue.kind(named: event.name)?.details ?? []
        }
        var filters: [String: String] = [:]
        for key in keys { if let value = event.details[key] { filters[key] = value } }
        return EventPattern(event.name, filters: filters)
    }

    /// The pattern as a workflow file's `on:` says it, ready to paste (042 wireframes §1).
    public var asTrigger: String {
        guard !filters.isEmpty else { return "on:\n  - \(name)" }
        let lines = filters.sorted { $0.key < $1.key }.map { "      \($0.key): \(Self.yamlScalar($0.value))" }
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
    /// "One of my pull requests was merged (number 41)".
    public var summary: String {
        let meaning: String
        if let subject = wholeSubject {
            meaning = "Anything about \(subject == .pullRequest ? "my pull requests" : "\(subject.rawValue)s")"
        } else if EventCatalogue.isCustom(name) {
            meaning = "When an agent here publishes \(name)"
        } else {
            meaning = EventCatalogue.kind(named: name).map { String($0.meaning.dropLast()) } ?? name
        }
        guard !filters.isEmpty else { return meaning }
        let narrowed = filters.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "\(meaning) (\(narrowed))"
    }

    /// The name with its filters, as the status line writes it: "pull_request.merged #41".
    public var label: String {
        var parts = [name]
        for (key, value) in filters.sorted(by: { $0.key < $1.key }) {
            parts.append(key == "number" ? "#\(value)" : "\(key) \(value)")
        }
        return parts.joined(separator: " ")
    }
}

/// What was wrong with a pattern, in the sentence the agent (or the workflow page) reads.
public enum EventPatternProblem: Error, Hashable, Sendable {
    case unknown(String)
    case badCustomName(String)
    case badFilter(name: String, key: String, valid: [String])

    public var message: String {
        switch self {
        case .unknown(let name):
            let guess = Self.closest(to: name).map { " Did you mean \($0)?" } ?? ""
            let names = EventCatalogue.all.map(\.name).joined(separator: ", ")
            return "\"\(name)\" is not an event.\(guess) Events you can wait on: \(names), custom.<name>, "
                + "or a subject with .* such as pull_request.*."
        case .badCustomName(let name):
            return "\"\(name)\" is not a custom event name: after custom. it is lowercase letters, digits "
                + "and _, up to 40 characters."
        case .badFilter(let name, let key, let valid):
            guard !valid.isEmpty else { return "\(name) carries no details, so it cannot be narrowed by \"\(key)\"." }
            return "\(name) carries \(valid.joined(separator: ", ")); \"\(key)\" is not one of its details."
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
