import Foundation

/// The Multiplier (#3901, #3903; method in specs/3901-multiplier/spec.md): the PRs the
/// person's agents merged in the last 7 days, less the merged reverts, against the PRs an
/// average engineer merged in a week in 2025. The host counts it; the Mac window's hero
/// page (#3904) draws it.
public extension DaemonAPI {
    struct Multiplier: Codable, Sendable, Hashable {
        /// The PRs counted: merged in the range, less the merged reverts, never below 0.
        public var prsMerged: Int
        public var reverts: Int
        /// To one decimal. Nil when nothing is counted: the page shows — ×, not 0×.
        public var multiplier: Double?
        /// To the whole hour. Nil when nothing is counted.
        public var engineerHours: Double?
        /// The host's agents with a turn running when it counted.
        public var agentsWorking: Int
        /// The start of the range: 7 days before it was counted.
        public var since: Date
        public var baseline: MultiplierBaseline
        /// On `multiplier/changed`: the PR whose merge or revert changed it.
        public var changedBy: LineageNode?
        /// The highest Multiplier of a calendar week, Monday to Sunday, this week too (#3988).
        /// Nil until the first counted merge is 7 days old: the page shows no bests.
        public var bestWeek: Double?
        /// The most of the host's agents in a turn at the same time, ever (#3988).
        public var mostAtOnce: Int?

        public init(prsMerged: Int = 0, reverts: Int = 0, multiplier: Double? = nil, engineerHours: Double? = nil,
                    agentsWorking: Int = 0, since: Date, baseline: MultiplierBaseline, changedBy: LineageNode? = nil,
                    bestWeek: Double? = nil, mostAtOnce: Int? = nil) {
            self.prsMerged = prsMerged
            self.reverts = reverts
            self.multiplier = multiplier
            self.engineerHours = engineerHours
            self.agentsWorking = agentsWorking
            self.since = since
            self.baseline = baseline
            self.changedBy = changedBy
            self.bestWeek = bestWeek
            self.mostAtOnce = mostAtOnce
        }
    }

    /// What the Multiplier compares with (#3902): an engineer with no AI in 2025, or the
    /// person's own figure and line (#3991), from Settings ▸ Cost ▸ Multiplier.
    struct MultiplierBaseline: Codable, Sendable, Hashable {
        /// Merged PRs a week: 1.4 unless the person set their own.
        public var prsPerWeek: Double
        /// The hours of that week: 40.
        public var hoursPerWeek: Double
        /// Where the figure is from: DX 2025.
        public var source: String
        /// The person's own line under the figures; nil is `defaultLine`.
        public var line: String?

        public init(prsPerWeek: Double, hoursPerWeek: Double, source: String, line: String? = nil) {
            self.prsPerWeek = prsPerWeek
            self.hoursPerWeek = hoursPerWeek
            self.source = source
            self.line = line
        }

        /// The line the page shows when the person has none of their own.
        public var defaultLine: String {
            "An average engineer merged \(prsPerWeek.formatted()) PRs a week (\(source))"
        }

        /// The line under the figures: the person's, else the default.
        public var shownLine: String { line ?? defaultLine }
    }
}

public extension DaemonAPI.LineageNode {
    /// The PR's number as people write it, `#1234`, from a ref such as
    /// `github:alexec/agents#1234`; the whole ref when it has no number.
    var shortName: String {
        guard let hash = ref.lastIndex(of: "#") else { return ref }
        return String(ref[hash...])
    }
}
