import Foundation

/// One interpretation of session search for Mac and Remote. A label token narrows
/// the existing title/report text search; an empty label token matches nothing.
public struct SessionLabelQuery: Hashable, Sendable {
    public var label: String?
    public var text: String
    /// The sessions whose prompts or replies hold the words, as their hosts found them
    /// (`agents/said`, #1585): they match as their title would.
    public var said: [UUID: String] = [:]

    public init(_ input: String, said: [UUID: String]) {
        self.init(input)
        self.said = said
    }

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

    /// Whether the search asks for this label, so its chip can look chosen (#3898).
    public func asks(for label: String) -> Bool {
        guard let wanted = self.label else { return false }
        return !wanted.isEmpty && SessionLabelPolicy.key(wanted) == SessionLabelPolicy.key(label)
    }

    /// The search after a click on a label's chip (#3898): it asks for that label in place of
    /// any other, and keeps the words. A second click, when it already asks for it, takes the
    /// label out again.
    public static func toggling(_ label: String, in input: String) -> String {
        let query = SessionLabelQuery(input)
        if query.asks(for: label) { return query.text }
        let token = label.contains(where: \.isWhitespace) ? "label:\"\(label)\"" : "label:\(label)"
        return query.text.isEmpty ? token : "\(token) \(query.text)"
    }

    public func matches(_ agent: Agent) -> Bool {
        if let label {
            let wanted = SessionLabelPolicy.key(label)
            guard !wanted.isEmpty,
                  agent.labels.contains(where: { $0.normalizedValue == wanted }) else { return false }
        }
        guard !text.isEmpty else { return true }
        return [agent.title, agent.report?.message].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(text) } || said[agent.id] != nil
    }

    /// A workflow by its name and what it is. Workflows carry no labels, so a query
    /// that asks for one leaves every workflow out.
    public func matches(_ summary: WorkflowSummary) -> Bool {
        guard label == nil else { return false }
        guard !text.isEmpty else { return true }
        return [summary.workflow.name, summary.workflow.summary]
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
