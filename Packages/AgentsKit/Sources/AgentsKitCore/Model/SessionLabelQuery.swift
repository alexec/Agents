import Foundation

/// One interpretation of session search for Mac and Remote. A label token narrows
/// the existing title/report text search; an empty label token matches nothing.
public struct SessionLabelQuery: Hashable, Sendable {
    public var label: String?
    public var text: String

    public init(_ input: String) {
        let pattern = #"(?i)(?:^|\s)label:(?:"([^"]*)"|(\S*))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range, in: input) else {
            label = nil
            text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        label = Range(capture, in: input).map { String(input[$0]) } ?? ""
        var remaining = input
        remaining.removeSubrange(range)
        text = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func matches(_ agent: Agent) -> Bool {
        if let label {
            let wanted = SessionLabelPolicy.key(label)
            guard !wanted.isEmpty,
                  agent.labels.contains(where: { $0.normalizedValue == wanted }) else { return false }
        }
        guard !text.isEmpty else { return true }
        return [agent.title, agent.report?.message].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
