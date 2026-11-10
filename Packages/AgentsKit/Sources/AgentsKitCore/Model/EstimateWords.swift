import Foundation

/// The words for an estimate (#3560) on Work's issue and epic pages and in an epic's Plan, from
/// `lineage/estimate` (#3559), as `Web/src/model/estimate.ts` has them on the web page. The
/// figures are dollars, output tokens and the agents' working time. The line says a range with its
/// typical value, rounded to one significant figure, as the median is often off by ×1.7 (#4530);
/// lead time shows only as a range, as it varies with the queue (specs/3557-estimates).
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

    /// The page's line: "Estimate: $1 to $10, typically $3; 30 min to 6 hours of agents' compute time
    /// (from 31 closed stories)"; for an epic, "Estimate for 3 open children: …". Output tokens show
    /// only when there is no cost or time. With too little history, "Not enough past work to
    /// estimate" and nothing else.
    public static func line(_ e: Estimate) -> String {
        guard hasFigures(e) else { return notEnough }
        let head = e.openChildren.map { "Estimate for \(plural($0, "open child", "open children"))" } ?? "Estimate"
        var parts: [String] = []
        let priced = (e.cost ?? [:]).sorted { $0.key < $1.key }
        if !priced.isEmpty {
            parts.append(priced.map { code, r in
                let low = rough(r.p10, code), high = rough(r.p90, code), mid = rough(r.median, code)
                return low == high ? "about \(mid)" : "\(low) to \(high), typically \(mid)"
            }.joined(separator: "; "))
        }
        if let w = e.workingSeconds { parts.append("\(roughTime(w.p10, w.p90)) of agents' compute time") }
        if parts.isEmpty, let t = e.outputTokens {
            parts.append("\(UsageChart.tokenWords(t.p10)) to \(UsageChart.tokenWords(t.p90)) output tokens")
        }
        return "\(head): \(parts.joined(separator: "; ")) (from \(source(e)))"
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
        var words = "8 in 10 like it: \(ranges(e).joined(separator: ", "))."
        if let lead = e.leadTimeSeconds {
            words += " Lead time \(TimeChart.words(lead.p10)) to \(TimeChart.words(lead.p90)): it varies with the queue."
        }
        return words
    }

    /// A child's estimate in an epic's Plan, rounded as the line is: "est. $3 · 2 hours"; nil with
    /// no figures.
    public static func childWords(_ e: Estimate) -> String? {
        guard hasFigures(e) else { return nil }
        var parts: [String] = []
        let priced = (e.cost ?? [:]).sorted { $0.key < $1.key }
        if !priced.isEmpty { parts.append(priced.map { rough($0.value.median, $0.key) }.joined(separator: " + ")) }
        if let w = e.workingSeconds { parts.append(roughTime(w.median, w.median)) }
        if parts.isEmpty, let t = e.outputTokens { parts.append("\(UsageChart.tokenWords(t.median)) output tokens") }
        return "est. " + parts.joined(separator: " · ")
    }

    /// A closed issue's or epic's estimate against what it took (#3561): "Estimated $3.20, 2h 10m
    /// of work; actual $4.10, 3h of work". Nil while open, before work started, or when the
    /// estimate then had no figures.
    public static func actualWords(_ e: Estimate) -> String? {
        guard let kept = e.kept, let actual = e.actual else { return nil }
        var said: [String] = []
        let priced = (kept.cost ?? [:]).sorted { $0.key < $1.key }
        if !priced.isEmpty {
            said.append(priced.map { $0.value.formatted(.currency(code: $0.key).precision(.fractionLength(2))) }
                .joined(separator: " + "))
        }
        if let w = kept.workingSeconds { said.append("\(TimeChart.words(w)) of work") }
        guard !said.isEmpty else { return nil }
        var took = [ReportValueWords.cost(actual)]
        if kept.workingSeconds != nil { took.append("\(TimeChart.words(actual.workingSeconds)) of work") }
        return "Estimated \(said.joined(separator: ", ")); actual \(took.joined(separator: ", "))"
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

    private static func ranges(_ e: Estimate) -> [String] {
        let span = { (r: DaemonAPI.LineageEstimateRange, words: (Double) -> String) in "\(words(r.p10)) to \(words(r.p90))" }
        var parts: [String] = []
        if let low = money(e.cost, \.p10), let high = money(e.cost, \.p90) { parts.append("\(low) to \(high)") }
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

    /// A value rounded to one significant figure: 3.2 → 3, 9.8 → 10, 0.42 → 0.4.
    static func roughly(_ v: Double) -> Double {
        guard v > 0, v.isFinite else { return 0 }
        let exp = floor(log10(v))
        return exp < 0 ? (v * pow(10, -exp)).rounded() / pow(10, -exp) : (v / pow(10, exp)).rounded() * pow(10, exp)
    }

    /// Money to one significant figure: "$3", "$10", "$0.4".
    static func rough(_ v: Double, _ code: String) -> String {
        let r = roughly(v)
        return r.formatted(.currency(code: code).precision(.fractionLength(0...max(0, Int(-floor(log10(max(r, 1e-9))))))))
    }

    /// A time range to one significant figure, in one unit when both ends share it: "20 to 90 min",
    /// "30 min to 6 hours", "5 to 20 hours"; "2 hours" when the ends are the same. Minutes below 100,
    /// then hours below 48, then days.
    static func roughTime(_ low: Double, _ high: Double) -> String {
        func split(_ s: Double) -> (Double, String, String) {
            let minutes = s / 60
            if roughly(minutes) < 100 { return (max(1, roughly(minutes)), "min", "min") }
            let hours = s / 3600
            if roughly(hours) < 48 { return (roughly(hours), "hour", "hours") }
            return (roughly(s / 86400), "day", "days")
        }
        let (a, oneA, manyA) = split(low), (b, oneB, manyB) = split(high)
        let n = { (v: Double) in v.formatted(.number.precision(.fractionLength(0...1))) }
        if a == b, manyA == manyB { return "\(n(b)) \(b == 1 ? oneB : manyB)" }
        if manyA == manyB { return "\(n(a)) to \(n(b)) \(manyB)" }
        return "\(n(a)) \(a == 1 ? oneA : manyA) to \(n(b)) \(b == 1 ? oneB : manyB)"
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}
