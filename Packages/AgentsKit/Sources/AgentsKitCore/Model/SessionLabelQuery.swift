import Foundation

/// One interpretation of session search for Mac and Remote. A label token narrows
/// the existing title/report text search; an empty label token matches nothing.
public struct SessionLabelQuery: Hashable, Sendable {
    public var label: String?
    /// The issue the search names (#3899): `#3465`, `issue:#3465` or `issue:3465`, as a word of its own.
    public var issue: Int?
    public var text: String
    /// The sessions whose prompts or replies hold the words, as their hosts found them
    /// (`agents/said`, #1585): they match as their title would.
    public var said: [UUID: String] = [:]
    /// The sessions Lineage links to the issue, to its sub-issues or to their PRs, as their hosts
    /// found them (`lineage/sessions`, #3899): they match as its `#<n>` label would.
    public var onIssue: [UUID: DaemonAPI.LineageNode] = [:]

    public init(_ input: String, said: [UUID: String], onIssue: [UUID: DaemonAPI.LineageNode] = [:]) {
        self.init(input)
        self.said = said
        self.onIssue = onIssue
    }

    public init(_ input: String) {
        var remaining = input
        label = Self.take(#"(?i)(?:^|\s)label:(?:"([^"]*)"|(\S*))"#, from: &remaining)
        issue = Self.take(#"(?i)(?:^|\s)(?:issue:#?|#)([0-9]{1,9})(?=\s|$)"#, from: &remaining).flatMap { Int($0) }
        text = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first match of `pattern` in `input`, taken out of it: its first capture that matched, or "".
    private static func take(_ pattern: String, from input: inout String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range, in: input) else { return nil }
        let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        let value = Range(capture, in: input).map { String(input[$0]) } ?? ""
        input.removeSubrange(range)
        return value
    }

    /// The issue a search names, for `lineage/sessions` (#3899), or nil.
    public static func issue(in input: String) -> Int? { SessionLabelQuery(input).issue }

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
        if let issue {
            let mark = "#\(issue)"
            guard onIssue[agent.id] != nil || agent.labels.contains(where: { $0.normalizedValue == mark })
                    || agent.title.map({ Self.names($0, mark) }) == true else { return false }
        }
        if let label {
            let wanted = SessionLabelPolicy.key(label)
            guard !wanted.isEmpty,
                  agent.labels.contains(where: { $0.normalizedValue == wanted }) else { return false }
        }
        guard !text.isEmpty else { return true }
        return [agent.title, agent.report?.message].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(text) } || said[agent.id] != nil
    }

    /// Whether text holds `#<n>` as a number of its own: `#38` is not in "#3899".
    static func names(_ text: String, _ mark: String) -> Bool {
        var rest = text[...]
        while let found = rest.range(of: mark) {
            if found.upperBound == rest.endIndex || !rest[found.upperBound].isASCII || !rest[found.upperBound].isNumber {
                return true
            }
            rest = rest[found.upperBound...]
        }
        return false
    }

    /// A workflow by its name and what it is. Workflows carry no labels or issues, so a query
    /// that asks for one leaves every workflow out.
    public func matches(_ summary: WorkflowSummary) -> Bool {
        guard label == nil, issue == nil else { return false }
        guard !text.isEmpty else { return true }
        return [summary.workflow.name, summary.workflow.summary]
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
