import Foundation

/// A tool's or an event's arguments: an object of named strings, positive integers and booleans,
/// some required and no others allowed. It is listed as JSON Schema and checks what it is given.
public struct Schema: Sendable {
    public struct Property: Sendable {
        public enum Kind: String, Sendable { case string, integer, boolean }
        public var kind: Kind
        public var description: String?
        /// A regular expression the whole string must match, and what to call its shape.
        public var pattern: (regex: String, looksLike: String)?
        public var maxLength: Int?
        /// Extra JSON Schema keys, listed but not checked (such as `enum`).
        public var extra: [String: JSON]

        public static func string(_ description: String? = nil, pattern: (regex: String, looksLike: String)? = nil,
                                  maxLength: Int? = nil, extra: [String: JSON] = [:]) -> Property {
            Property(kind: .string, description: description, pattern: pattern, maxLength: maxLength, extra: extra)
        }

        /// A positive integer.
        public static func integer(_ description: String? = nil) -> Property {
            Property(kind: .integer, description: description, pattern: nil, maxLength: nil, extra: [:])
        }

        public static func boolean(_ description: String? = nil) -> Property {
            Property(kind: .boolean, description: description, pattern: nil, maxLength: nil, extra: [:])
        }

        public var json: JSON {
            var o = extra
            o["type"] = .string(kind.rawValue)
            if let description { o["description"] = .string(description) }
            if let pattern { o["pattern"] = .string(pattern.regex) }
            if let maxLength { o["maxLength"] = .int(maxLength) }
            return .object(o)
        }
    }

    /// In the order they are listed and named in errors.
    public var properties: [(name: String, property: Property)]
    public var required: [String]

    public init(_ properties: KeyValuePairs<String, Property>, required: [String] = []) {
        self.properties = properties.map { ($0.key, $0.value) }
        self.required = required
    }

    public subscript(name: String) -> Property? { properties.first { $0.name == name }?.property }

    public var json: JSON {
        [
            "type": "object",
            "properties": .object(Dictionary(properties.map { ($0.name, $0.property.json) }) { a, _ in a }),
            "required": JSON(required),
            "additionalProperties": false,
        ]
    }

    /// `arguments` (null or missing as `{}`) once checked: required keys, no others, types,
    /// shapes and lengths. Throws -32602 saying what is wrong.
    public func check(_ arguments: JSON?) throws(RPCError) -> [String: JSON] {
        let given: [String: JSON]
        switch arguments {
        case nil, .null?: given = [:]
        case .object(let o)?: given = o
        default: throw .invalidParams("arguments must be an object")
        }
        for key in required where given[key] == nil || given[key] == .null {
            throw .invalidParams("missing \(key)")
        }
        for key in given.keys.sorted() {
            let value = given[key]!
            guard let property = self[key] else {
                throw .invalidParams("unknown argument \(key); takes \(properties.map(\.name).joined(separator: ", "))")
            }
            switch property.kind {
            case .integer:
                guard let i = value.int, i > 0 else { throw .invalidParams("\(key) must be a positive integer") }
            case .boolean:
                guard value.bool != nil else { throw .invalidParams("\(key) must be true or false") }
            case .string:
                guard let s = value.string else { throw .invalidParams("\(key) must be a string") }
                if let pattern = property.pattern, s.range(of: pattern.regex, options: .regularExpression) == nil {
                    throw .invalidParams("\(key) must look like \(pattern.looksLike)")
                }
                if let max = property.maxLength, s.count > max {
                    throw .invalidParams("\(key) is over \(max) characters")
                }
            }
        }
        return given
    }
}
