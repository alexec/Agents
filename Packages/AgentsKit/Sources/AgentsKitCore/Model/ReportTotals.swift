import Foundation

/// The Reports pane (#1811): a report's rows added up by person, project, folder, machine
/// or runtime, largest first. The window, the Remote and the web page (`Web/src/model/reports.ts`)
/// add up the same way.
public struct ReportTotals: Sendable, Hashable {
    public enum Dimension: String, CaseIterable, Identifiable, Sendable {
        case person = "Person"
        /// The project the folder is in, across machines (#2670).
        case project = "Project"
        case folder = "Folder"
        case machine = "Machine"
        case runtime = "Runtime"
        /// The workflow that started the agents: Reports ▸ Workflows' (#2019).
        case workflow = "Workflow"

        public var id: Self { self }

        /// The ways Spend adds up, and every page's after its own first.
        public static let spend: [Dimension] = [.person, .project, .folder, .machine, .runtime]
    }

    /// One person's, project's, folder's, machine's or runtime's share.
    public struct Group: Identifiable, Sendable, Hashable {
        public var id: String
        public var name: String
        /// Per currency, never added across.
        public var cost: [String: Decimal] = [:]
        /// Input, output, thought and cache-write tokens: UsageBucket.freshTokens.
        public var tokens = 0
        public var turns = 0
        public var unpricedTurns = 0
        public var workingSeconds: Double = 0
        public var waitingSeconds: Double = 0

        mutating func add(_ row: DaemonAPI.ReportRow) {
            for (currency, amount) in row.cost { cost[currency, default: 0] += amount }
            tokens += row.inputTokens + row.outputTokens + row.thoughtTokens + row.cachedWriteTokens
            turns += row.turns
            unpricedTurns += row.unpricedTurns
            workingSeconds += row.workingSeconds
            waitingSeconds += row.waitingSeconds
        }
    }

    public var groups: [Group]
    public var total: Group
    /// The currencies any row has, the one with most spent first.
    public var currencies: [String]
    /// The largest group's cost in the first currency, or its tokens when nothing was
    /// priced: worked out once, not for each row's bar (#2057).
    private var most: Double = 0

    public init(_ rows: [DaemonAPI.ReportRow], by dimension: Dimension,
                runtimeName: (String) -> String = UsageChart.runtimeName) {
        var groups: [String: Group] = [:]
        var total = Group(id: "", name: "Total")
        for row in rows {
            let (id, name) = Self.key(row, dimension, runtimeName)
            groups[id, default: Group(id: id, name: name)].add(row)
            total.add(row)
        }
        let currencies = total.cost.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let first = currencies.first
        self.groups = groups.values.sorted { a, b in
            let ca = first.flatMap { a.cost[$0] } ?? 0, cb = first.flatMap { b.cost[$0] } ?? 0
            if ca != cb { return ca > cb }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            if a.workingSeconds != b.workingSeconds { return a.workingSeconds > b.workingSeconds }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        self.total = total
        self.currencies = currencies
        if let first {
            let top = self.groups.compactMap { $0.cost[first] }.max() ?? 0
            most = NSDecimalNumber(decimal: top).doubleValue
        } else {
            most = Double(self.groups.map(\.tokens).max() ?? 0)
        }
    }

    /// A share of the largest group, 0 to 1, for the bar under each row: by the first
    /// currency's cost, or by tokens when nothing was priced.
    public func share(of group: Group) -> Double {
        guard most > 0 else { return 0 }
        if let currency = currencies.first {
            return NSDecimalNumber(decimal: group.cost[currency] ?? 0).doubleValue / most
        }
        return Double(group.tokens) / most
    }

    static func key(_ row: DaemonAPI.ReportRow, _ dimension: Dimension,
                    _ runtimeName: (String) -> String) -> (String, String) {
        switch dimension {
        case .person:
            return (row.person, row.person.isEmpty ? ReportWords.removedOwner
                    : (row.personName.isEmpty ? row.person : row.personName))
        case .project:
            let project = row.project ?? ""
            return (project, project.isEmpty ? ReportWords.noProject : (row.projectName ?? project))
        case .folder:
            return (row.folder, row.folder.isEmpty ? ReportWords.noFolder : row.folder)
        case .machine:
            return (row.host, row.hostName.isEmpty ? row.host : row.hostName)
        case .runtime:
            return (row.runtime, row.runtime.isEmpty ? ReportWords.noRuntime : runtimeName(row.runtime))
        case .workflow:
            let workflow = row.workflow ?? ""
            return (workflow, workflow.isEmpty ? ReportOutcomeWords.noWorkflow : workflow)
        }
    }
}

/// The Reports pane's words, on all three clients.
public enum ReportWords {
    public static let removedOwner = "A removed machine"
    public static let noFolder = "No folder"
    public static let noProject = "No project"
    public static let noRuntime = "No runtime"
    public static let empty = "Nothing was used in this time. Each machine sends what it used once an hour."
    /// Whose spend the Cost page's Reports pane shows: the caller's own, an admin's too (#2071).
    /// Reports ▸ Spend is named only to someone it offers more than Me: an admin or a group's
    /// lead (#2200).
    public static func meNote(seesMore: Bool) -> String {
        seesMore ? "Your machines. A group’s and everyone’s are in Reports ▸ Spend on the web page." : memberNote
    }
    public static let memberNote = "Your machines. An admin or a group’s lead sees more."
    public static let utcNote = "Hours and days are UTC, so machines in other time zones add up."

    /// D, W, M and 3M, as the Cost page's charts name them.
    public static func short(_ range: DaemonAPI.ReportRange) -> String {
        switch range {
        case .day: "D"
        case .week: "W"
        case .month: "M"
        case .threeMonths: "3M"
        }
    }

    /// The range's name as VoiceOver says it: "D" alone means nothing (#2440).
    public static func spoken(_ range: DaemonAPI.ReportRange) -> String {
        switch range {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .threeMonths: "3 months"
        }
    }

    /// What Spend's bars measure (#2440).
    public static let barCaption = "Each bar is the cost against the largest, or the tokens when nothing has a price."

    /// What the range covers, in words.
    public static func span(_ range: DaemonAPI.ReportRange) -> String {
        switch range {
        case .day: "The last 24 hours"
        case .week: "The last 7 days"
        case .month: "The last 30 days"
        case .threeMonths: "The last 90 days"
        }
    }

    /// The figures under a name: cost, tokens, turns and working time.
    public static func line(_ group: ReportTotals.Group) -> String {
        var parts: [String] = []
        if let cost = Cost.total(of: group.cost), !cost.isEmpty { parts.append(cost) }
        parts.append("\(UsageChart.tokenWords(Double(group.tokens))) tokens")
        parts.append(group.turns == 1 ? "1 turn" : "\(group.turns) turns")
        parts.append("\(TimeChart.words(group.workingSeconds)) working")
        return parts.joined(separator: " · ")
    }

    /// "report-week-2026-10-21.csv".
    public static func exportName(_ range: DaemonAPI.ReportRange, _ format: DaemonAPI.ReportFormat,
                                  _ now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "report-%@-%04d-%02d-%02d.%@", range.rawValue, day.year ?? 0, day.month ?? 0,
                      day.day ?? 0, format.rawValue)
    }

    /// A failure, in a sentence: a control plane before #1811 keeps no reports.
    public static func sentence(_ error: Error) -> String {
        if let error = error as? JSONRPCError {
            return error.code == -32601 ? "This control plane keeps no reports. Update it to see them." : error.message
        }
        return "The control plane can’t be reached."
    }
}
