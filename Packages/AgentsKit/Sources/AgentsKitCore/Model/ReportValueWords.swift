import Foundation

/// The words for a lineage node and its cost (#2351, #3023), on the Lineage and Work pages, as
/// `Web/src/model/value.ts` has them on the web page.
public enum ReportValueWords {
    /// The cost by currency, "$4.00", or the tokens when nothing had a price.
    public static func cost(_ c: DaemonAPI.LineageCost) -> String {
        let priced = c.cost.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        if !priced.isEmpty {
            return priced.map { $0.value.formatted(.currency(code: $0.key).precision(.fractionLength(2))) }
                .joined(separator: " + ")
        }
        return "\(UsageChart.tokenWords(Double(c.inputTokens + c.outputTokens))) tokens"
    }

    static func spent(_ c: DaemonAPI.LineageCost) -> Bool {
        c.cost.values.contains { $0 > 0 } || c.inputTokens + c.outputTokens > 0
    }

    /// An issue's, a PR's or a release's name without its tracker:
    /// "alexec/agents#12", "ENG-4", "alexec/agents release v0.14.0"
    /// (#3023).
    public static func name(_ node: DaemonAPI.LineageNode) -> String {
        // Read in the old form (#4800): the words are made from it.
        var id = WireRef.legacy(node.ref)
        if let colon = id.firstIndex(of: ":"), id[..<colon].allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) {
            id = String(id[id.index(after: colon)...])
        }
        if let range = id.range(of: "/release/", options: .backwards) {
            return "\(id[..<range.lowerBound]) release \(id[range.upperBound...])"
        }
        return id
    }

    /// Where a GitHub issue, PR or release is; nil for a tracker whose address the
    /// ref does not say.
    public static func url(_ node: DaemonAPI.LineageNode) -> URL? {
        let ref = WireRef.legacy(node.ref)
        guard ref.hasPrefix("github:") else { return nil }
        let id = ref.dropFirst("github:".count)
        if let range = id.range(of: "/release/") {
            return URL(string: "https://github.com/\(id[..<range.lowerBound])/releases/tag/\(id[range.upperBound...])")
        }
        let parts = id.split(separator: "#", maxSplits: 1)
        guard parts.count == 2, Int(parts[1]) != nil else { return nil }
        return URL(string: "https://github.com/\(parts[0])/issues/\(parts[1])")
    }

    public static let notHere = "This control plane does not add up the value of the work yet. Update it to see it."

    /// A failure, in a sentence: a control plane before #2351 has no reports/value.
    public static func sentence(_ error: Error) -> String {
        if let error = error as? JSONRPCError { return error.code == -32601 ? notHere : error.message }
        return "The control plane can’t be reached."
    }
}
