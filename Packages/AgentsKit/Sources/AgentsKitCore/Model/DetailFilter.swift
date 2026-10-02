import Foundation

/// The values one detail of an event must have for a pattern to match it (073 FR-014):
/// one value, as every filter was before, or a list meaning any of them.
///
/// A list of one is the single value, so `outcome: [done]` and `outcome: done` are the
/// same filter, stored and sent the same way.
public struct DetailFilter: Hashable, Sendable, ExpressibleByStringLiteral {
    /// Never empty.
    public let values: [String]

    public init(_ value: String) {
        values = [value]
    }

    /// `nil` for an empty list, which would match nothing and say nothing.
    public init?(anyOf values: [String]) {
        guard !values.isEmpty else { return nil }
        self.values = values
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The one value, when it is not a list.
    public var single: String? { values.count == 1 ? values[0] : nil }

    /// Whether an event's detail has one of these values. A detail the event does not
    /// carry never matches. A set detail (`labels`) is the event's members, comma-joined,
    /// and matches when it holds any of these, compared the way labels are compared for
    /// sameness (073 FR-002).
    public func matches(_ detail: String?, isSet: Bool) -> Bool {
        guard let detail else { return false }
        guard isSet else { return values.contains(detail) }
        let members = Set(detail.split(separator: ",").map { SessionLabelPolicy.key(String($0)) })
        return values.contains { members.contains(SessionLabelPolicy.key($0)) }
    }

    // MARK: Words

    /// As the status line and a run's cause write it: `done|nothing_to_do`.
    public var label: String { values.joined(separator: "|") }

    /// As the Triggers section's capsule writes it: `done | nothing_to_do`.
    public var capsule: String { values.joined(separator: " | ") }

    /// As a workflow file writes it: `done`, or the inline list `[done, nothing_to_do]`.
    public var yaml: String {
        if let single { return EventPattern.yamlScalar(single) }
        return "[" + values.map(EventPattern.yamlScalar).joined(separator: ", ") + "]"
    }
}

/// A string for one value and an array for a list, which is what the wait tool's
/// `where` sends. `EventPattern` stores its filters its own way (073 research R1).
extension DetailFilter: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(String.self) {
            self.init(one)
            return
        }
        let many = try container.decode([String].self)
        guard let filter = DetailFilter(anyOf: many) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "An empty list of values")
        }
        self = filter
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let single { try container.encode(single) } else { try container.encode(values) }
    }
}
