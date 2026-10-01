/// A Swift type as written in a declaration, parsed from its text: enough of the grammar for
/// what crosses the wire (071, research R6).
indirect enum TypeRef: Equatable, CustomStringConvertible {
    /// A possibly dotted name: `String`, `DaemonAPI.ClientAnnounce`, `ClientRecord.Kind`.
    case named([String])
    case array(TypeRef)
    case dictionary(TypeRef, TypeRef)
    case optional(TypeRef)
    /// `Range` or `ClosedRange`, which Swift encodes as `[lower, upper]`.
    case range(TypeRef)

    var description: String {
        switch self {
        case .named(let path): path.joined(separator: ".")
        case .array(let element): "[\(element)]"
        case .dictionary(let key, let value): "[\(key): \(value)]"
        case .optional(let wrapped): "\(wrapped)?"
        case .range(let bound): "ClosedRange<\(bound)>"
        }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// `[String: [Agent]]?`, `Optional<Set<UUID>>`, `DaemonAPI.Agent` and the like. Anything
    /// else (a tuple, a closure, a generic of our own) is refused by name.
    static func parse(_ text: String) throws -> TypeRef {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("any ") || text.hasPrefix("some ") { throw Failure(description: "\(text) is existential") }
        if text.hasSuffix("?") || text.hasSuffix("!") {
            text.removeLast()
            return .optional(try parse(text))
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            if let colon = topLevel(":", in: inner) {
                return .dictionary(try parse(String(inner[..<colon])), try parse(String(inner[inner.index(after: colon)...])))
            }
            return .array(try parse(inner))
        }
        if let open = text.firstIndex(of: "<"), text.hasSuffix(">") {
            let base = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            let arguments = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            let parts = split(arguments)
            switch (base, parts.count) {
            case ("Optional", 1), ("Swift.Optional", 1): return .optional(try parse(parts[0]))
            case ("Array", 1), ("Set", 1), ("Swift.Array", 1), ("Swift.Set", 1): return .array(try parse(parts[0]))
            case ("Dictionary", 2), ("Swift.Dictionary", 2): return .dictionary(try parse(parts[0]), try parse(parts[1]))
            case ("Range", 1), ("ClosedRange", 1): return .range(try parse(parts[0]))
            default: throw Failure(description: "\(text) is a generic type")
            }
        }
        let path = text.split(separator: ".").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !path.isEmpty, path.allSatisfy({ $0.first.map { $0.isLetter || $0 == "_" } == true
            && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) else {
            throw Failure(description: "\(text) has no TypeScript form")
        }
        return .named(path.first == "Swift" && path.count > 1 ? Array(path.dropFirst()) : path)
    }

    private static func topLevel(_ character: Character, in text: String) -> String.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case character where depth == 0: return index
            default: break
            }
        }
        return nil
    }

    private static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            switch character {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            default: break
            }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
