import Foundation

/// One detail a kind of event carries, as the catalogue describes it (073): whether a
/// wait or a trigger may narrow the event by it, and the values it can have when they
/// are fixed.
///
/// Every detail is shown (the events page, a woken agent's message, a workflow agent's
/// prompt) and is in the kind's `payloadSchema`; only a few are filters (#574), in its
/// `inputSchema`: `branch` on `branch.moved` and `why` on `person.away` and
/// `person.back` (#579).
public struct EventDetail: Hashable, Sendable {
    public var key: String
    /// Whether a wait or a trigger may narrow the event by it.
    public var isFilter: Bool
    /// The values it can have, or `nil` when any text will do.
    public var values: [String]?

    public init(_ key: String, isFilter: Bool = false, values: [String]? = nil) {
        self.key = key
        self.isFilter = isFilter
        self.values = values
    }

    /// As JSON Schema: every detail is text, and one with fixed values says them.
    public var schema: JSONValue {
        var object: [String: JSONValue] = ["type": "string"]
        if let values { object["enum"] = .array(values.map(JSONValue.string)) }
        return .object(object)
    }
}
