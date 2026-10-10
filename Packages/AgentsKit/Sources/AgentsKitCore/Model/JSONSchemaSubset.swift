import Foundation

/// The little of JSON Schema an event's filters need (#383, research R8): `type`,
/// `properties`, `required`, `enum`, `additionalProperties: false` and `items`. Anything
/// else in a schema is ignored. The server checks its own arguments too; this is here to
/// say what is wrong in the app's words, before the first poll.
public enum JSONSchemaSubset {
    /// What is wrong with `value` against `schema`, as a sentence, or `nil` when it fits.
    /// `name` is what the sentence calls the whole, such as "ci's checks.failed".
    public static func check(_ value: JSONValue, against schema: JSONValue, name: String) -> String? {
        guard let problem = problem(value, schema, path: nil) else { return nil }
        if let properties = schema["properties"]?.objectValue, problem.isKey {
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let keys = properties.keys.sorted().map { required.contains($0) ? "\($0) (required)" : $0 }
            let takes = keys.isEmpty ? "takes no settings" : "takes \(keys.joined(separator: ", "))"
            return "\(name) \(takes); \(problem.words)."
        }
        return "\(name): \(problem.words)."
    }

    private struct Problem {
        var words: String
        /// About which keys are there, so the sentence lists the ones it takes.
        var isKey: Bool = false
    }

    private static func problem(_ value: JSONValue, _ schema: JSONValue, path: String?) -> Problem? {
        let here = path.map { "\($0) " } ?? ""
        if let type = schema["type"] {
            let types = type.stringValue.map { [$0] } ?? type.arrayValue?.compactMap(\.stringValue) ?? []
            if !types.isEmpty, !types.contains(where: { fits(value, $0) }) {
                return Problem(words: "\(here)should be \(types.map(article).joined(separator: " or "))")
            }
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(where: { equal($0, value) }) {
            let words = allowed.map(text).joined(separator: ", ")
            return Problem(words: "\(here)is one of \(words), not \(text(value))")
        }
        if case .object(let object) = value {
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
                return Problem(words: "\(key) is needed", isKey: path == nil)
            }
            if schema["additionalProperties"]?.boolValue == false,
               let extra = object.keys.sorted().first(where: { properties[$0] == nil }) {
                return Problem(words: "\"\(extra)\" is not one of its arguments", isKey: path == nil)
            }
            for key in object.keys.sorted() {
                guard let inner = properties[key], let value = object[key] else { continue }
                if let problem = problem(value, inner, path: path.map { "\($0).\(key)" } ?? key) { return problem }
            }
        }
        if case .array(let items) = value, let inner = schema["items"], inner.objectValue != nil {
            for (index, item) in items.enumerated() {
                if let problem = problem(item, inner, path: "\(path ?? "the list")[\(index)]") { return problem }
            }
        }
        return nil
    }

    private static func fits(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null),
             ("integer", .int), ("number", .int), ("number", .double):
            return true
        case ("integer", .double(let number)):
            return number.rounded() == number
        default:
            return false
        }
    }

    private static func article(_ type: String) -> String {
        switch type {
        case "integer", "object", "array": return "an \(type)"
        case "null": return "null"
        case "string": return "text"
        case "boolean": return "true or false"
        default: return "a \(type)"
        }
    }

    private static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .double(let y)), (.double(let y), .int(let x)): return Double(x) == y
        default: return a == b
        }
    }

    private static func text(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return MCPEventTrigger.canonicalJSON(value)
    }
}
