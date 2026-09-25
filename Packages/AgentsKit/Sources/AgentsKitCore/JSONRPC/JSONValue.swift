import Foundation

/// A JSON value of any shape.
///
/// The protocol is open-ended in the places that matter: tool calls, `_meta`, and the
/// options a runtime advertises are all "whatever the agent sent". Keeping those as
/// values rather than as types is what lets one code path serve three runtimes, and
/// what stops an unfamiliar field from failing a decode and stalling an agent.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Each wrong guess is a thrown `DecodingError`, with its message formatted
        // and its coding path copied, so the order is the order things turn up in
        // what runtimes send: text and objects far ahead of numbers and flags. A
        // string used to cost three misses and an object four; now neither costs one.
        // Whole documents are read without guessing at all: see `parse(_:)`.
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Reading

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v.rounded())
        default: return nil
        }
    }

    public var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: Bridging

    /// Decode a known shape out of an open-ended value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Turn a known shape into an open-ended value.
    public static func encoding(_ value: some Encodable) throws -> JSONValue {
        try parse(try JSONEncoder().encode(value))
    }

    // MARK: Reading a whole document

    /// Read JSON text into a value, without `Decodable`.
    ///
    /// `JSONDecoder` can only find out what a value is by trying each kind in turn,
    /// and every wrong try is a thrown error with a message. Every line on every
    /// wire — a runtime's, the daemon's — comes through here, and a tool's output
    /// can be a hundred kilobytes of it, so it is read the direct way: Foundation's
    /// parser says what each value is, and this writes it down.
    public static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// From what `JSONSerialization` hands back. Anything it never produces is null.
    init(foundation object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if Self.isBoolean(number) {
                self = .bool(number.boolValue)
            } else if number is NSDecimalNumber {
                self = .double(number.doubleValue)
            } else {
                switch UInt8(bitPattern: number.objCType.pointee) {
                case UInt8(ascii: "f"), UInt8(ascii: "d"):
                    self = .double(number.doubleValue)
                case UInt8(ascii: "Q"):
                    // Past what `Int` holds, which a double at least says the size of.
                    let wide = number.uint64Value
                    self = wide <= UInt64(Int.max) ? .int(Int(wide)) : .double(number.doubleValue)
                default:
                    self = .int(number.intValue)
                }
            }
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(foundation:)))
        default:
            self = .null
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue {
    /// Whether `JSONSerialization` meant true or false rather than 1 or 0. The Mac asks
    /// CoreFoundation; the Linux build of `agentsd` has no CFBoolean to ask, and its
    /// Foundation marks a boolean with the Objective-C type code `c` instead (037).
    static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        number.objCType.pointee == CChar(UInt8(ascii: "c"))
        #endif
    }
}
