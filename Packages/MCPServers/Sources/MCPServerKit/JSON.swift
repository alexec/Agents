import Foundation

/// A JSON value: what JSON-RPC carries, and what a server reads its arguments from and
/// answers with. Integers stay integers, so `1` and `1.5` can be told apart.
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

// MARK: Reading

extension JSON {
    public subscript(key: String) -> JSON? {
        get { if case .object(let o) = self { o[key] } else { nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { a[index] } else { nil }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var int: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: Int(d)
        default: nil
        }
    }
    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }
    public var isNull: Bool { self == .null }

    /// Its kind, as `typeof` would say it.
    public var kind: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .int, .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// This object with `other`'s keys laid over it.
    public func merging(_ other: [String: JSON]) -> JSON {
        guard case .object(let o) = self else { return self }
        return .object(o.merging(other) { _, new in new })
    }
}

// MARK: Literals

// Not ExpressibleByNilLiteral: `json["key"] == nil` has to mean the key is missing, not null.
extension JSON: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}

extension JSON {
    public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    public init(_ value: Int?) { self = value.map(JSON.int) ?? .null }
    public init(_ values: [String]) { self = .array(values.map(JSON.string)) }
}

// MARK: Text

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Parses `data`; anything that is not JSON throws.
    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    /// One line of JSON: keys sorted, slashes as they are.
    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Nothing in a JSON value fails to encode but a non-finite double, which no parse makes.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data, as: UTF8.self) }

    /// Indented, for a file a person reads and edits.
    public var prettyText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return String(decoding: (try? encoder.encode(self)) ?? Data("null".utf8), as: UTF8.self)
    }
}
