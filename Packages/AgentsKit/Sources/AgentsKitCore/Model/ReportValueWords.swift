import Foundation

/// Reports ▸ Value's words (#2351), as `Web/src/model/value.ts` has them on the web page.
public enum ReportValueWords {
    private typealias Words = ReportOutcomeWords

    /// The cost by currency, "$4.00", or the tokens when nothing had a price.
    public static func cost(_ c: DaemonAPI.LineageCost) -> String {
        let priced = c.cost.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        if !priced.isEmpty { return priced.map { Words.each($0.value, in: $0.key) }.joined(separator: " + ") }
        return "\(UsageChart.tokenWords(Double(c.inputTokens + c.outputTokens))) tokens"
    }

    static func spent(_ c: DaemonAPI.LineageCost) -> Bool {
        c.cost.values.contains { $0 > 0 } || c.inputTokens + c.outputTokens > 0
    }

    /// An issue's, a PR's, a milestone's or a release's name without its tracker:
    /// "alexec/agents#12", "ENG-4", "alexec/agents milestone 15", "alexec/agents release v0.14.0"
    /// (#3023).
    public static func name(_ node: DaemonAPI.LineageNode) -> String {
        var id = node.ref
        if let colon = id.firstIndex(of: ":"), id[..<colon].allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) {
            id = String(id[id.index(after: colon)...])
        }
        if let range = id.range(of: "/milestone/", options: .backwards) {
            return "\(id[..<range.lowerBound]) milestone \(id[range.upperBound...])"
        }
        if let range = id.range(of: "/release/", options: .backwards) {
            return "\(id[..<range.lowerBound]) release \(id[range.upperBound...])"
        }
        return id
    }

    /// Where a GitHub issue, PR, milestone or release is; nil for a tracker whose address the
    /// ref does not say.
    public static func url(_ node: DaemonAPI.LineageNode) -> URL? {
        guard node.ref.hasPrefix("github:") else { return nil }
        let id = node.ref.dropFirst("github:".count)
        if let range = id.range(of: "/milestone/") {
            return URL(string: "https://github.com/\(id[..<range.lowerBound])/milestone/\(id[range.upperBound...])")
        }
        if let range = id.range(of: "/release/") {
            return URL(string: "https://github.com/\(id[..<range.lowerBound])/releases/tag/\(id[range.upperBound...])")
        }
        let parts = id.split(separator: "#", maxSplits: 1)
        guard parts.count == 2, Int(parts[1]) != nil else { return nil }
        return URL(string: "https://github.com/\(parts[0])/issues/\(parts[1])")
    }

    /// "$12.40 on issues and pull requests · 3 merged · $4.13 a merged pull request".
    public static func headline(_ v: DaemonAPI.ReportValue) -> String {
        var parts = ["\(cost(v.total)) on issues and pull requests", "\(v.prsMerged) merged"]
        for (currency, amount) in v.perMergedPR.sorted(by: { $0.key < $1.key }) {
            parts.append("\(Words.each(amount, in: currency)) a merged pull request")
        }
        return parts.joined(separator: " · ")
    }

    /// "$3.00 wasted: 1 closed without a merge, 1 revert · 2 failed CI rounds", or that nothing was wasted.
    public static func waste(_ v: DaemonAPI.ReportValue) -> String {
        var why: [String] = []
        if v.prsClosed > 0 { why.append("\(v.prsClosed) closed without a merge") }
        if v.prsReverted > 0 { why.append(Words.plural(v.prsReverted, "revert", "reverts")) }
        var parts = [why.isEmpty ? "Nothing wasted" : "\(cost(v.waste)) wasted: \(why.joined(separator: ", "))"]
        if v.failedChecks > 0 { parts.append(Words.plural(v.failedChecks, "failed CI round", "failed CI rounds")) }
        return parts.joined(separator: " · ")
    }

    /// "19h from the first work on an issue to its merge (the median)".
    public static func lead(_ v: DaemonAPI.ReportValue) -> String? {
        v.leadTimeSeconds.map { "\(TimeChart.words($0)) from the first work on an issue to its merge (the median)" }
    }

    /// The turns that had no issue or pull request, or nil when there were none.
    public static func unlinked(_ v: DaemonAPI.ReportValue) -> String? {
        spent(v.unlinked) ? "\(cost(v.unlinked)) on turns with no issue or pull request" : nil
    }

    /// "$10.00 · 1 merged, 1 closed · $3.00 wasted · 2 failed CI rounds · 19h to merge".
    public static func line(_ r: DaemonAPI.ReportValueRow) -> String {
        var parts = [cost(r.total)]
        var ends: [String] = []
        if r.prsMerged > 0 { ends.append("\(r.prsMerged) merged") }
        if r.prsClosed > 0 { ends.append("\(r.prsClosed) closed") }
        if r.prsReverted > 0 { ends.append("\(r.prsReverted) reverted") }
        parts.append(ends.isEmpty ? "Not merged yet" : ends.joined(separator: ", "))
        if spent(r.waste) { parts.append("\(cost(r.waste)) wasted") }
        if r.failedChecks > 0 { parts.append(Words.plural(r.failedChecks, "failed CI round", "failed CI rounds")) }
        if let lead = r.leadTimeSeconds { parts.append("\(TimeChart.words(lead)) to merge") }
        return parts.joined(separator: " · ")
    }

    /// Whether there is anything to show.
    public static func isEmpty(_ v: DaemonAPI.ReportValue) -> Bool {
        v.issues.isEmpty && v.prsMerged + v.prsClosed == 0
    }

    public static let none = "No work on issues or pull requests in this time. A session works on one when it has a label such as #12 or P#34, or opens a pull request on its branch."
    public static let note = "An issue’s cost is its own and its pull requests’, from every machine. A pull request closed without a merge, and a merged revert, is waste. A node counts in the range when it last changed in it, with all of its cost. The lead time is from the first work on an issue to its last pull request merged."
    public static let notHere = "This control plane does not add up the value of the work yet. Update it to see it."

    /// A failure, in a sentence: a control plane before #2351 has no reports/value.
    public static func sentence(_ error: Error) -> String {
        if let error = error as? JSONRPCError, error.code == -32601 { return notHere }
        return ReportWords.sentence(error)
    }
}
