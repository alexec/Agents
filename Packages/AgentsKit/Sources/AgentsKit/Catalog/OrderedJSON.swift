import Foundation

/// JSON that keeps its keys in the order they came, and writes itself the way JavaScript's
/// `JSON.stringify(value, null, 2)` does.
///
/// For the `skills` CLI's lock files (059, contracts/lock-files.md), which the app shares
/// with that tool: the CLI keeps skills in the order they were added and rewrites the whole
/// file each time, so a file the app has touched has to come out as the CLI would have left
/// it. `JSONValue` holds an object as a dictionary and loses the order. Numbers keep the
/// exact text they were read with, so nothing the app does not own is changed by a round
/// trip.
enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number's text, exactly as read or as written by the app.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.number(x), .number(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    // MARK: Reading

    struct ParseError: Error {}

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError() }
        return value
    }

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var intValue: Int? { if case .number(let n) = self { Int(n) } else { nil } }
    var objectPairs: [(String, OrderedJSON)]? { if case .object(let p) = self { p } else { nil } }

    /// Set a key, keeping its place if it is there already and adding it at the end if not,
    /// as assigning to a JavaScript object does.
    mutating func set(_ key: String, _ value: OrderedJSON) {
        guard case .object(var pairs) = self else { return }
        if let at = pairs.firstIndex(where: { $0.0 == key }) { pairs[at].1 = value } else { pairs.append((key, value)) }
        self = .object(pairs)
    }

    mutating func remove(_ key: String) {
        guard case .object(var pairs) = self else { return }
        pairs.removeAll { $0.0 == key }
        self = .object(pairs)
    }

    /// One server entry as canonical JSON: keys sorted, no insignificant whitespace.
    /// Two writings of the same entry share a digest (060, contracts/mcp-json.md).
    func canonicalJSON() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s):
            var out = ""
            Self.quote(s, into: &out)
            return out
        case .array(let items):
            return "[" + items.map { $0.canonicalJSON() }.joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.sorted { $0.0 < $1.0 }.map { key, value in
                var out = ""
                Self.quote(key, into: &out)
                return out + ":" + value.canonicalJSON()
            }.joined(separator: ",") + "}"
        }
    }

    // MARK: Writing, as JSON.stringify(value, null, 2)

    func stringified() -> String {
        var out = ""
        write(into: &out, indent: "")
        return out
    }

    private func write(into out: inout String, indent: String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += Self.javaScriptNumber(n)
        case .string(let s): Self.quote(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            let inner = indent + "  "
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += inner
                item.write(into: &out, indent: inner)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += indent + "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            let inner = indent + "  "
            out += "{\n"
            for (i, pair) in pairs.enumerated() {
                out += inner
                Self.quote(pair.0, into: &out)
                out += ": "
                pair.1.write(into: &out, indent: inner)
                out += i < pairs.count - 1 ? ",\n" : "\n"
            }
            out += indent + "}"
        }
    }

    /// A number as JavaScript writes it back: the CLI parses its file and stringifies it, so
    /// `1.50` comes out `1.5` and `1e3` comes out `1000`, and the app has to do the same to
    /// leave the file as the CLI would. Whole numbers below 10²¹ are written out in full;
    /// anything else takes Swift's shortest round-trip form with JavaScript's exponent
    /// (`1e-7`, not `1e-07`), which covers every number a lock file has held.
    static func javaScriptNumber(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        if value == 0 { return "0" }
        if value.rounded() == value, abs(value) < 1e21 { return String(format: "%.0f", value) }
        var s = value.description
        if let e = s.firstIndex(of: "e") {
            var exponent = String(s[s.index(after: e)...])
            let sign = exponent.hasPrefix("-") ? "-" : "+"
            exponent = String(exponent.drop(while: { $0 == "-" || $0 == "+" || $0 == "0" }))
            s = String(s[..<e]) + "e" + sign + (exponent.isEmpty ? "0" : exponent)
        }
        return s
    }

    /// JavaScript's quoting: `"` and `\` escaped, the short escapes for `\b \f \n \r \t`,
    /// `\u00xx` in lower case for any other control character, everything else as it is.
    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    // MARK: The parser

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipSpace()
            guard index < bytes.count else { throw ParseError() }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else { throw ParseError() }
            index += w.count
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8),
                  Double(text) != nil else { throw ParseError() }
            return .number(text)
        }

        mutating func object() throws -> OrderedJSON {
            index += 1
            var pairs: [(String, OrderedJSON)] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError() }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError() }
                index += 1
                let v = try value()
                // A repeated key keeps its first place and its last value, as JSON.parse does.
                if let at = pairs.firstIndex(where: { $0.0 == key }) { pairs[at].1 = v } else { pairs.append((key, v)) }
                skipSpace()
                guard index < bytes.count else { throw ParseError() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                throw ParseError()
            }
        }

        mutating func array() throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try value())
                skipSpace()
                guard index < bytes.count else { throw ParseError() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ParseError()
            }
        }

        /// A string, decoded through JSONSerialization so every escape means what JSON says.
        mutating func string() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    let slice = Data(bytes[start..<index])
                    guard let s = try JSONSerialization.jsonObject(with: slice, options: .fragmentsAllowed) as? String
                    else { throw ParseError() }
                    return s
                default: index += 1
                }
            }
            throw ParseError()
        }
    }
}
