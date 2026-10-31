import Foundation

/// Reports ▸ Value (#2351): what the work cost and what it delivered, added up on the control
/// plane from the lineage nodes each machine sends (#2350): cost per merged PR, per issue and
/// per milestone, waste and lead time.
public extension DaemonAPI {
    /// A node of the lineage graph (#2348): an issue, a PR, a session, a milestone. `ref` names it
    /// apart from any tracker, as `github:alexec/agents#12` or `linear:ENG-4`.
    struct LineageNode: Codable, Sendable, Hashable {
        public var kind: String
        public var ref: String

        public init(kind: String, ref: String) {
            self.kind = kind
            self.ref = ref
        }
    }

    /// What was banked under lineage nodes (#2350): a turn's cost, tokens and time, split among
    /// the links active when it ended.
    struct LineageCost: Codable, Sendable, Hashable {
        /// Per currency, never added across.
        public var cost: [String: Decimal]
        public var inputTokens: Int
        public var outputTokens: Int
        public var limitTokens: Int?
        /// A share of turns: a turn on two nodes is half a turn on each.
        public var turns: Double
        public var workingSeconds: Double
        public var waitingSeconds: Double

        public init(cost: [String: Decimal] = [:], inputTokens: Int = 0, outputTokens: Int = 0, limitTokens: Int? = nil,
                    turns: Double = 0, workingSeconds: Double = 0, waitingSeconds: Double = 0) {
            self.cost = cost
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.limitTokens = limitTokens
            self.turns = turns
            self.workingSeconds = workingSeconds
            self.waitingSeconds = waitingSeconds
        }
    }

    /// One issue or milestone on Reports ▸ Value: its cost from every machine in the scope, and
    /// how its PRs ended.
    struct ReportValueRow: Codable, Sendable, Hashable, Identifiable {
        public var node: LineageNode
        public var total: LineageCost
        public var waste: LineageCost
        public var prsMerged: Int
        public var prsClosed: Int
        public var prsReverted: Int
        public var failedChecks: Int
        /// From the first work on it to its last PR merged; nil before a merge.
        public var leadTimeSeconds: Double?

        public var id: String { node.ref }

        public init(node: LineageNode, total: LineageCost = .init(), waste: LineageCost = .init(), prsMerged: Int = 0,
                    prsClosed: Int = 0, prsReverted: Int = 0, failedChecks: Int = 0, leadTimeSeconds: Double? = nil) {
            self.node = node
            self.total = total
            self.waste = waste
            self.prsMerged = prsMerged
            self.prsClosed = prsClosed
            self.prsReverted = prsReverted
            self.failedChecks = failedChecks
            self.leadTimeSeconds = leadTimeSeconds
        }
    }

    /// `reports/value`'s answer. `total` is the work on issues and PRs, `waste` the PRs closed
    /// without a merge and merged reverts, `unlinked` the turns with no issue or PR.
    /// `leadTimeSeconds` is the median of the issues'. The lists are the most costly first, at
    /// most 100 each.
    struct ReportValue: Codable, Sendable, Hashable {
        public var range: ReportRange
        public var scope: ReportScope
        public var total: LineageCost
        public var waste: LineageCost
        public var unlinked: LineageCost
        /// `total` by the PRs merged, per currency; empty with none merged.
        public var perMergedPR: [String: Decimal]
        public var prsMerged: Int
        public var prsClosed: Int
        public var prsReverted: Int
        public var failedChecks: Int
        public var leadTimeSeconds: Double?
        public var issues: [ReportValueRow]
        public var milestones: [ReportValueRow]
        public var limited: Bool?

        public init(range: ReportRange, scope: ReportScope, total: LineageCost = .init(), waste: LineageCost = .init(),
                    unlinked: LineageCost = .init(), perMergedPR: [String: Decimal] = [:], prsMerged: Int = 0,
                    prsClosed: Int = 0, prsReverted: Int = 0, failedChecks: Int = 0, leadTimeSeconds: Double? = nil,
                    issues: [ReportValueRow] = [], milestones: [ReportValueRow] = [], limited: Bool? = nil) {
            self.range = range
            self.scope = scope
            self.total = total
            self.waste = waste
            self.unlinked = unlinked
            self.perMergedPR = perMergedPR
            self.prsMerged = prsMerged
            self.prsClosed = prsClosed
            self.prsReverted = prsReverted
            self.failedChecks = failedChecks
            self.leadTimeSeconds = leadTimeSeconds
            self.issues = issues
            self.milestones = milestones
            self.limited = limited
        }
    }
}

public extension DaemonAPI.Method {
    /// `ReportQuery` → `ReportValue` (#2351).
    static let reportsValue = "reports/value"
}
