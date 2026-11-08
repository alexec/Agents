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

        public init(prsMerged: Int = 0, reverts: Int = 0, multiplier: Double? = nil, engineerHours: Double? = nil,
                    agentsWorking: Int = 0, since: Date, baseline: MultiplierBaseline, changedBy: LineageNode? = nil) {
            self.prsMerged = prsMerged
            self.reverts = reverts
            self.multiplier = multiplier
            self.engineerHours = engineerHours
            self.agentsWorking = agentsWorking
            self.since = since
            self.baseline = baseline
            self.changedBy = changedBy
        }
    }

    /// What the Multiplier compares with (#3902): an engineer with no AI in 2025.
    struct MultiplierBaseline: Codable, Sendable, Hashable {
        /// Merged PRs a week: 1.4.
        public var prsPerWeek: Double
        /// The hours of that week: 40.
        public var hoursPerWeek: Double
        /// Where the figure is from: DX 2025.
        public var source: String

        public init(prsPerWeek: Double, hoursPerWeek: Double, source: String) {
            self.prsPerWeek = prsPerWeek
            self.hoursPerWeek = hoursPerWeek
            self.source = source
        }
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
