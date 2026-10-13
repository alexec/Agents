import AgentsKitCore
import Foundation

/// A draft's secrets, taken out of every text bound for its writing agent, its steps and the
/// log (#858, research R4, FR-022): each value becomes `${NAME}`.
///
/// A value of 6 characters or more is replaced wherever it is; a shorter one only as a whole
/// word, so that common text is not broken. Each is also replaced in its URL-encoded and
/// base64 forms, since a server may echo a header.
public struct DraftRedaction: Sendable {
    struct Form: Sendable {
        var text: String
        var name: String
        var wholeWord: Bool
    }

    private let forms: [Form]
    /// What URL encoding leaves as it is (RFC 3986).
    static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    public init(_ secrets: [String: String]) {
        var forms: [Form] = []
        for (name, value) in secrets where !value.isEmpty {
            let short = value.count < 6
            var seen: Set<String> = []
            for text in [value, value.addingPercentEncoding(withAllowedCharacters: Self.unreserved),
                         Data(value.utf8).base64EncodedString()].compactMap({ $0 }) where seen.insert(text).inserted {
                forms.append(Form(text: text, name: name, wholeWord: short))
            }
        }
        // The longest first, so a value that holds another is replaced whole.
        self.forms = forms.sorted { $0.text.count > $1.text.count }
    }

    public var isEmpty: Bool { forms.isEmpty }

    public func callAsFunction(_ text: String) -> String {
        forms.reduce(text) { text, form in
            guard text.contains(form.text) else { return text }
            guard form.wholeWord else { return text.replacingOccurrences(of: form.text, with: "${\(form.name)}") }
            let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: form.text) + "(?![A-Za-z0-9_])"
            return text.replacingOccurrences(of: pattern, with: "\\${\(form.name)}", options: .regularExpression)
        }
    }

    /// Every string in it, keys and values.
    public func callAsFunction(_ json: JSONValue) -> JSONValue {
        switch json {
        case .string(let text): .string(self(text))
        case .array(let items): .array(items.map { self($0) })
        case .object(let object): .object(Dictionary(object.map { (self($0.key), self($0.value)) }) { a, _ in a })
        default: json
        }
    }
}
