import Foundation

/// Outcomes, Time, Runtimes and Workflows (#2019, #2183): what the agents did, from the
/// counts each machine adds to its report rows (`ReportCounts`), added up by person, folder,
/// machine, runtime or workflow. A machine before #2019 sends no counts, so its rows count as
/// nothing done. The web page adds up the same way (`Web/src/model/reports.ts`, `outcomeTotals`).
public struct ReportOutcomes: Sendable, Hashable {
    /// A page of counts, as Reports names it.
    public enum Page: String, CaseIterable, Identifiable, Sendable {
        case outcomes = "Outcomes"
        case time = "Time"
        case runtimes = "Runtimes"
        case workflows = "Workflows"

        public var id: Self { self }

        /// The page of counts a page of Reports is; nil for Spend and Adoption.
        public init?(_ page: DaemonAPI.ReportPage) {
            switch page {
            case .outcomes: self = .outcomes
            case .time: self = .time
            case .runtimes: self = .runtimes
            case .workflows: self = .workflows
            case .spend, .adoption, .value: return nil
            }
        }

        /// How the page adds up when it opens.
        public var firstWay: ReportTotals.Dimension {
            switch self {
            case .outcomes, .time: .person
            case .runtimes: .runtime
            case .workflows: .workflow
            }
        }

        /// The ways the page adds up: Workflows by workflow first.
        public var ways: [ReportTotals.Dimension] {
            self == .workflows ? [.workflow] + ReportTotals.Dimension.spend : ReportTotals.Dimension.spend
        }
    }

    /// One person's, folder's, machine's, runtime's or workflow's counts.
    public struct Group: Identifiable, Sendable, Hashable {
        public var id: String
        public var name: String
        /// Per currency, never added across.
        public var cost: [String: Decimal] = [:]
        public var sessions = 0
        public var failed = 0
        public var opened = 0
        public var merged = 0
        public var reverted = 0
        public var mergeSeconds: Double = 0
        public var workingSeconds: Double = 0
        public var waitingSeconds: Double = 0
        public var waits = 0
        /// The waits by length, as `ReportCounts.waitBuckets`.
        public var buckets = [0, 0, 0, 0, 0, 0]
        public var runs = 0
        public var runFailures = 0
        public var turns = 0
        public var unpricedTurns = 0

        mutating func add(_ row: DaemonAPI.ReportRow) {
            for (currency, amount) in row.cost { cost[currency, default: 0] += amount }
            workingSeconds += row.workingSeconds
            waitingSeconds += row.waitingSeconds
            turns += row.turns
            unpricedTurns += row.unpricedTurns
            guard let c = row.counts else { return }
            sessions += c.sessions
            failed += c.failedSessions
            runs += c.workflowRuns
            runFailures += c.workflowFailures
            opened += c.prsOpened
            merged += c.prsMerged
            reverted += c.prsReverted
            mergeSeconds += c.mergeSeconds
            waits += c.waits
            for (i, n) in c.waitBuckets.enumerated() where i < buckets.count { buckets[i] += n }
        }

        /// The share of the agents' time spent waiting for a person, 0 to 1.
        public var waitingShare: Double {
            let all = workingSeconds + waitingSeconds
            return all > 0 ? waitingSeconds / all : 0
        }

        /// The cost in the first currency, for sorting and the bar.
        var firstCost: Double {
            cost.sorted { $0.key < $1.key }.first.map { NSDecimalNumber(decimal: $0.value).doubleValue } ?? 0
        }
    }

    public var page: Page
    public var groups: [Group]
    public var total: Group
    /// The most merged and the largest cost of any group, worked out once for the bars (#2057).
    private var mostMerged = 0
    private var mostCost: Double = 0

    /// The rows added up by a way, sorted as the page wants: merged first for Outcomes,
    /// waiting for Time, cost for Runtimes and failing for Workflows. Workflows reads only the
    /// rows of a workflow's agents.
    public init(_ rows: [DaemonAPI.ReportRow], page: Page, by way: ReportTotals.Dimension,
                runtimeName: (String) -> String = UsageChart.runtimeName) {
        var groups: [String: Group] = [:]
        var total = Group(id: "", name: "Total")
        for row in rows where page != .workflows || !(row.workflow ?? "").isEmpty {
            let (id, name) = ReportTotals.key(row, way, runtimeName)
            groups[id, default: Group(id: id, name: name)].add(row)
            total.add(row)
        }
        self.page = page
        self.total = total
        self.groups = groups.values.sorted { a, b in
            switch Self.order(a, b, page) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        mostMerged = self.groups.map(\.merged).max() ?? 0
        mostCost = self.groups.map(\.firstCost).max() ?? 0
    }

    /// Ascending means `a` comes first.
    private static func order(_ a: Group, _ b: Group, _ page: Page) -> ComparisonResult {
        func larger<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult? {
            x == y ? nil : (x > y ? .orderedAscending : .orderedDescending)
        }
        let result: ComparisonResult? = switch page {
        case .outcomes: larger(a.merged, b.merged) ?? larger(a.opened, b.opened) ?? larger(a.sessions, b.sessions)
        case .time: larger(a.waitingShare, b.waitingShare) ?? larger(a.waits, b.waits)
        case .runtimes: larger(a.firstCost, b.firstCost) ?? larger(a.sessions, b.sessions)
        case .workflows: larger(a.runFailures, b.runFailures) ?? larger(a.runs, b.runs)
        }
        return result ?? .orderedSame
    }

    /// Whether there is nothing to show for the page.
    public var isEmpty: Bool {
        switch page {
        case .outcomes: total.sessions + total.opened == 0
        case .time: total.workingSeconds + total.waitingSeconds == 0
        case .runtimes: total.turns + total.sessions == 0
        case .workflows: total.runs + total.turns == 0
        }
    }

    /// The bar under a group, 0 to 1: its merged share of the most for Outcomes, the share of
    /// time waiting for Time, its cost against the most for Runtimes, its failed runs for Workflows.
    public func bar(_ group: Group) -> Double {
        func fraction(_ part: Double, _ all: Double) -> Double { all > 0 ? part / all : 0 }
        switch page {
        case .outcomes: return fraction(Double(group.merged), Double(mostMerged))
        case .time: return group.waitingShare
        case .runtimes: return fraction(group.firstCost, mostCost)
        case .workflows: return fraction(Double(group.runFailures), Double(group.runs))
        }
    }

    /// The figures under a name, as the page says them.
    public func line(_ group: Group) -> String {
        switch page {
        case .outcomes: ReportOutcomeWords.outcomeLine(group)
        case .time: ReportOutcomeWords.timeLine(group)
        case .runtimes: ReportOutcomeWords.runtimeLine(group)
        case .workflows: ReportOutcomeWords.workflowLine(group)
        }
    }
}

/// Reports ▸ Adoption (#2019, #2183): each week's active people, sessions, runtimes and
/// workflows in use, newest first.
public struct ReportAdoptionWeek: Identifiable, Sendable, Hashable {
    /// The Monday the week starts on (UTC), "2026-10-19".
    public var week: String
    /// People and bots with a turn or a session; nil when nobody is named.
    public var people: Int?
    public var sessions: Int
    public var runtimes: Int
    public var workflows: Int

    public var id: String { week }

    public static func weeks(_ rows: [DaemonAPI.ReportRow], hidden: Bool = false) -> [ReportAdoptionWeek] {
        struct Week {
            var people: Set<String> = []
            var sessions = 0
            var runtimes: Set<String> = []
            var workflows: Set<String> = []
        }
        var weeks: [String: Week] = [:]
        for row in rows {
            let sessions = row.counts?.sessions ?? 0
            guard let key = weekOf(row.at) else { continue }
            weeks[key, default: Week()].sessions += sessions
            guard row.turns > 0 || sessions > 0 else { continue }
            if !row.person.isEmpty { weeks[key]?.people.insert(row.person) }
            if !row.runtime.isEmpty { weeks[key]?.runtimes.insert(row.runtime) }
            if let workflow = row.workflow, !workflow.isEmpty { weeks[key]?.workflows.insert(workflow) }
        }
        return weeks.sorted { $0.key > $1.key }.map { key, w in
            ReportAdoptionWeek(week: key, people: hidden ? nil : w.people.count, sessions: w.sessions,
                               runtimes: w.runtimes.count, workflows: w.workflows.count)
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The Monday (UTC) of a row's hour or day.
    public static func weekOf(_ at: String) -> String? {
        let parts = at.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let weekday = utc.component(.weekday, from: day) // 1 is Sunday
        guard let monday = utc.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) else { return nil }
        let c = utc.dateComponents([.year, .month, .day], from: monday)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "The week of 19 Oct".
    public var title: String {
        let parts = week.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return week }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "The week of \(parts[2]) \(months[max(0, min(11, parts[1] - 1))])"
    }

    /// "4 active people · 2.5 sessions a person · 3 runtimes · 2 workflows".
    public var line: String {
        var parts: [String] = []
        if let people {
            parts.append(ReportOutcomeWords.plural(people, "active person", "active people"))
            if people > 0 {
                let each = (Double(sessions) / Double(people) * 10).rounded() / 10
                parts.append("\(each.formatted(.number.precision(.fractionLength(0...1)))) sessions a person")
            }
        } else {
            parts.append(ReportOutcomeWords.plural(sessions, "session", "sessions"))
        }
        parts.append(ReportOutcomeWords.plural(runtimes, "runtime", "runtimes"))
        parts.append(ReportOutcomeWords.plural(workflows, "workflow", "workflows"))
        return parts.joined(separator: " · ")
    }
}

/// The words of Outcomes, Time, Runtimes, Adoption and Workflows, on all three clients.
public enum ReportOutcomeWords {
    public static let noWorkflow = "No workflow"
    public static let noOutcomes = "No sessions or pull requests in this time. Each machine sends what its agents did once an hour."
    public static let noWorkflows = "No workflow ran in this time."
    public static let outcomesNote = "A pull or merge request counts when an agent made it on its own branch, and the machine heard of it: a workflow or a wait on pr.opened or pr.merged. A revert is one whose title starts with “Revert”. The time is from the agent’s start to the merge."
    public static let timeNote = "Working is the agent, its tools and waiting on others. Waiting is a question, a form or a permission that waits for its person. When the agents wait a lot, the fix may be people, not machines."
    public static let runtimesNote = "A session fails when it ends in an error that nobody chose, such as a crash, a refused sign-in or a spent allowance. Use this page to choose the runtimes and models a team starts with."
    public static let workflowsNote = "The workflows with the most failed runs come first. A run fails when its agent ends in an error. By Person shows each bot’s runs under its name."
    public static let adoptionNote = "A person is active in a week when one of their machines, or a bot’s, ran a turn. Weeks start on Monday, UTC."

    /// What each of `ReportCounts.waitBuckets` holds.
    public static let waitBuckets = ["under 1 minute", "1 to 5 minutes", "5 to 15 minutes", "15 to 60 minutes", "1 to 4 hours", "over 4 hours"]

    /// A page's name, as the web page's Reports names it.
    public static func title(_ page: DaemonAPI.ReportPage) -> String {
        switch page {
        case .spend: "Spend"
        case .outcomes: "Outcomes"
        case .time: "Time"
        case .runtimes: "Runtimes"
        case .adoption: "Adoption"
        case .workflows: "Workflows"
        case .value: "Value"
        }
    }

    /// What the page says when there is nothing to show.
    public static func none(_ page: ReportOutcomes.Page) -> String {
        switch page {
        case .outcomes: noOutcomes
        case .time, .runtimes: ReportWords.empty
        case .workflows: noWorkflows
        }
    }

    /// The note under the page.
    public static func note(_ page: ReportOutcomes.Page) -> String {
        switch page {
        case .outcomes: outcomesNote
        case .time: timeNote
        case .runtimes: runtimesNote
        case .workflows: workflowsNote
        }
    }

    /// What the page's bars measure: each page's bar is a different thing (#2440).
    public static func barCaption(_ page: ReportOutcomes.Page) -> String {
        switch page {
        case .outcomes: "Each bar is the merged pull requests against the most."
        case .time: "Each bar is the part of the time that waits for a person."
        case .runtimes: "Each bar is the cost against the largest."
        case .workflows: "Each bar is the part of the runs that failed."
        }
    }

    public static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// An amount for each of something: to the cent, as an average is.
    public static func each(_ amount: Decimal, in currency: String) -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }

    private static func costs(_ group: ReportOutcomes.Group) -> [(String, Decimal)] {
        group.cost.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The bucket the middle wait is in, or nil with no waits.
    public static func medianWait(_ buckets: [Int]) -> String? {
        let all = buckets.reduce(0, +)
        guard all > 0 else { return nil }
        var seen = 0
        for (i, n) in buckets.enumerated() {
            seen += n
            if seen * 2 >= all { return i < waitBuckets.count ? waitBuckets[i] : nil }
        }
        return nil
    }

    /// "3 merged of 4 opened · 1 revert · $7.90 a merged pull request · 2h 10m from start to merge · 5 sessions".
    public static func outcomeLine(_ g: ReportOutcomes.Group) -> String {
        var parts = ["\(g.merged) merged of \(g.opened) opened"]
        if g.reverted > 0 { parts.append(plural(g.reverted, "revert", "reverts")) }
        if g.merged > 0 {
            for (c, v) in costs(g) { parts.append("\(each(v / Decimal(g.merged), in: c)) a merged pull request") }
            parts.append("\(TimeChart.words(g.mergeSeconds / Double(g.merged))) from start to merge")
        }
        parts.append(plural(g.sessions, "session", "sessions"))
        return parts.joined(separator: " · ")
    }

    /// "Waiting for a person 38% of the time · 12 waits, the middle one 5 to 15 minutes · 6h 10m working".
    public static func timeLine(_ g: ReportOutcomes.Group) -> String {
        var parts = ["Waiting for a person \(Int((g.waitingShare * 100).rounded()))% of the time"]
        if let middle = medianWait(g.buckets) {
            parts.append("\(plural(g.waits, "wait", "waits")), the middle one \(middle)")
        } else {
            parts.append("no waits")
        }
        parts.append("\(TimeChart.words(g.workingSeconds)) working")
        return parts.joined(separator: " · ")
    }

    /// "$12.40 · 7 merged · $1.77 a merged pull request · 1 of 11 sessions failed (9%) · 3 turns not priced".
    public static func runtimeLine(_ g: ReportOutcomes.Group) -> String {
        let costs = costs(g)
        var parts = costs.map { each($0.1, in: $0.0) }
        parts.append("\(g.merged) merged")
        if g.merged > 0 {
            for (c, v) in costs { parts.append("\(each(v / Decimal(g.merged), in: c)) a merged pull request") }
        }
        let percent = g.sessions > 0 ? Int((Double(g.failed) / Double(g.sessions) * 100).rounded()) : 0
        parts.append("\(g.failed) of \(plural(g.sessions, "session", "sessions")) failed (\(percent)%)")
        if g.unpricedTurns > 0 { parts.append("\(plural(g.unpricedTurns, "turn", "turns")) not priced") }
        return parts.joined(separator: " · ")
    }

    /// "2 of 7 runs failed · $0.40 a run · 12m working a run".
    public static func workflowLine(_ g: ReportOutcomes.Group) -> String {
        var parts = ["\(g.runFailures) of \(plural(g.runs, "run", "runs")) failed"]
        if g.runs > 0 {
            for (c, v) in costs(g) { parts.append("\(each(v / Decimal(g.runs), in: c)) a run") }
            parts.append("\(TimeChart.words(g.workingSeconds / Double(g.runs))) working a run")
        }
        return parts.joined(separator: " · ")
    }
}
