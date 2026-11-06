import Foundation

/// The words for an estimate (#3560) on Work's issue and epic pages and in an epic's Plan, from
/// `lineage/estimate` (#3559), as `Web/src/model/estimate.ts` has them on the web page. The
/// figures are dollars, output tokens and the agents' working time; lead time shows only as a
/// range, as it varies with the queue (specs/3557-estimates).
public enum EstimateWords {
    public typealias Estimate = DaemonAPI.LineageEstimate

    public static let notEnough = "Not enough past work to estimate"

    /// Whether the estimate has a figure to show.
    public static func hasFigures(_ e: Estimate) -> Bool {
        !(e.cost ?? [:]).isEmpty || e.outputTokens != nil || e.workingSeconds != nil
    }

    /// Whether the page shows an estimate for it: an issue, or an epic with open children.
    public static func shows(_ e: Estimate) -> Bool {
        e.openChildren.map { $0 > 0 } ?? true
    }

    /// The page's line: "Estimate: about $3.20, 45K output tokens, 2h 10m of work (from 31 closed
    /// stories)"; for an epic, "Estimate for 3 open children: …". With too little history,
    /// "Not enough past work to estimate" and nothing else.
    public static func line(_ e: Estimate) -> String {
        guard hasFigures(e) else { return notEnough }
        let head = e.openChildren.map { "Estimate for \(plural($0, "open child", "open children"))" } ?? "Estimate"
        return "\(head): about \(figures(e, median: true).joined(separator: ", ")) (from \(source(e)))"
    }

    /// What an epic's closed children spent: "Spent $4.10 on 2 closed children"; nil for an issue
    /// or with nothing spent.
    public static func spentWords(_ e: Estimate) -> String? {
        guard let spent = e.spent, ReportValueWords.spent(spent) else { return nil }
        let on = e.closedChildren.map { " on \(plural($0, "closed child", "closed children"))" } ?? ""
        return "Spent \(ReportValueWords.cost(spent))\(on)"
    }

    /// The range, for the line's help: "8 in 10 like it: $1.10 to $9.80, 12K to 140K output
    /// tokens, 30m to 6h of work. Lead time 3h to 2d: it varies with the queue."
    public static func rangeWords(_ e: Estimate) -> String? {
        guard hasFigures(e) else { return nil }
        var words = "8 in 10 like it: \(figures(e, median: false).joined(separator: ", "))."
        if let lead = e.leadTimeSeconds {
            words += " Lead time \(TimeChart.words(lead.p10)) to \(TimeChart.words(lead.p90)): it varies with the queue."
        }
        return words
    }

    /// A child's estimate in an epic's Plan: "est. $3.20 · 2h 10m"; nil with no figures.
    public static func childWords(_ e: Estimate) -> String? {
        guard hasFigures(e) else { return nil }
        var parts: [String] = []
        if let money = money(e.cost, \.median) { parts.append(money) }
        if let w = e.workingSeconds { parts.append(TimeChart.words(w.median)) }
        if parts.isEmpty, let t = e.outputTokens { parts.append("\(UsageChart.tokenWords(t.median)) output tokens") }
        return "est. " + parts.joined(separator: " · ")
    }

    /// The closed issues it was made from: "31 closed stories", "12 closed bugs", "40 closed issues".
    static func source(_ e: Estimate) -> String {
        let kind: (String, String) = switch e.matchedBy {
        case "level": levelWords[e.level ?? ""] ?? ("issue", "issues")
        case "type": typeWords[e.type ?? ""] ?? ("issue", "issues")
        default: ("issue", "issues")
        }
        return plural(e.matches, "closed \(kind.0)", "closed \(kind.1)")
    }

    private static let levelWords = ["story": ("story", "stories"), "task": ("task", "tasks"), "spike": ("spike", "spikes"),
                                     "bug": ("bug", "bugs")]
    private static let typeWords = ["bug": ("bug", "bugs"), "enhancement": ("enhancement", "enhancements")]

    private static func figures(_ e: Estimate, median: Bool) -> [String] {
        let span = { (r: DaemonAPI.LineageEstimateRange, words: (Double) -> String) in
            median ? words(r.median) : "\(words(r.p10)) to \(words(r.p90))"
        }
        var parts: [String] = []
        if median, let money = money(e.cost, \.median) {
            parts.append(money)
        } else if !median, let low = money(e.cost, \.p10), let high = money(e.cost, \.p90) {
            parts.append("\(low) to \(high)")
        }
        if let t = e.outputTokens { parts.append("\(span(t, UsageChart.tokenWords)) output tokens") }
        if let w = e.workingSeconds { parts.append("\(span(w, TimeChart.words)) of work") }
        return parts
    }

    private static func money(_ cost: [String: DaemonAPI.LineageEstimateRange]?,
                              _ at: KeyPath<DaemonAPI.LineageEstimateRange, Double>) -> String? {
        let priced = (cost ?? [:]).sorted { $0.key < $1.key }
        guard !priced.isEmpty else { return nil }
        return priced.map { $0.value[keyPath: at].formatted(.currency(code: $0.key).precision(.fractionLength(2))) }
            .joined(separator: " + ")
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}
