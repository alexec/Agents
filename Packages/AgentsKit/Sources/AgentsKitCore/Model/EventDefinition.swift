import Foundation

/// One event as `events/list` describes it (#383): a server's, or since #579 one of the
/// app's own, so an agent learns both in one shape.
public struct EventDefinition: Equatable, Sendable {
    public var name: String
    public var description: String?
    /// How it can be delivered: `poll`, `push`, `webhook`. Empty for the app's own.
    public var delivery: [String]
    /// Its filters, as JSON Schema. Checked with `JSONSchemaSubset`.
    public var inputSchema: JSONValue?
    /// What its `data` holds. Not enforced: a payload is untrusted data whatever it says.
    public var payloadSchema: JSONValue?

    public init(name: String, description: String? = nil, delivery: [String] = ["poll"],
                inputSchema: JSONValue? = nil, payloadSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.delivery = delivery
        self.inputSchema = inputSchema
        self.payloadSchema = payloadSchema
    }

    public init?(_ raw: JSONValue) {
        guard let name = raw["name"]?.stringValue else { return nil }
        self.init(name: name, description: raw["description"]?.stringValue,
                  delivery: raw["delivery"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                  inputSchema: raw["inputSchema"], payloadSchema: raw["payloadSchema"])
    }

    public var wire: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name), "delivery": .array(delivery.map(JSONValue.string))]
        if let description { object["description"] = .string(description) }
        if let inputSchema { object["inputSchema"] = inputSchema }
        if let payloadSchema { object["payloadSchema"] = payloadSchema }
        return .object(object)
    }

    public var offersPoll: Bool { delivery.contains("poll") }
}
