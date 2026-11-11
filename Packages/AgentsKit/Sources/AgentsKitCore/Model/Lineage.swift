import Foundation

/// The lineage graph as the clients read it: `lineage/walk` from a node, and `lineage/cost`
/// for each issue and PR the walk reached (#2348, #2350).
public extension DaemonAPI {
    /// `lineage/sessions` (#3899): a search for `#<number>` asks for the sessions on that issue,
    /// on its sub-issues and on their PRs.
    struct LineageSessionsRequest: Codable, Sendable, Hashable {
        public var number: Int
        public init(number: Int) { self.number = number }
    }

    /// A session on the issue, and the issue it is on: the one asked for or one of its sub-issues.
    struct LineageSessionMatch: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var on: LineageNode
        public init(agentID: UUID, on: LineageNode) {
            self.agentID = agentID
            self.on = on
        }
    }

    /// One heading of a search for an epic (#3900): the epic or one of its sub-issues, and its
    /// title, nil while the host has not resolved it.
    struct LineageSessionIssue: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var title: String?
        public init(node: LineageNode, title: String? = nil) {
            self.node = node
            self.title = title
        }
    }

    struct LineageSessions: Codable, Sendable, Hashable {
        public var matches: [LineageSessionMatch]
        /// The issue asked for, then its sub-issues in the epic's order (#3900); nil from a host
        /// too old to say.
        public var issues: [LineageSessionIssue]?
        public var limited: Bool?
        public init(matches: [LineageSessionMatch], issues: [LineageSessionIssue]? = nil, limited: Bool? = nil) {
            self.matches = matches
            self.issues = issues
            self.limited = limited
        }
    }

    /// `lineage/links` and `lineage/walk`: a node, and for a walk how many links away to go
    /// (1 to 4; 2 when not said: issue, sessions, PRs).
    struct LineageNodeRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var depth: Int?

        public init(node: LineageNode, depth: Int? = nil) {
            self.node = node
            self.depth = depth
        }
    }

    /// A typed link: `from` works-on, opens, fixes, started, reviews, closes or part-of `to`.
    /// `source` is how the host knows it. Both lists are open.
    struct LineageLink: Codable, Sendable, Hashable {
        public var from: LineageNode
        public var to: LineageNode
        public var rel: String
        public var source: String
        public var at: Date
        /// Set when the link stopped being active: a PR merged, a session archived.
        public var endedAt: Date?

        public init(from: LineageNode, to: LineageNode, rel: String, source: String, at: Date, endedAt: Date? = nil) {
            self.from = from
            self.to = to
            self.rel = rel
            self.source = source
            self.at = at
            self.endedAt = endedAt
        }
    }

    /// `lineage/walk`'s answer: the nodes reached and the links gone along. `limited` says the
    /// walk stopped at its limit on nodes. `resolved` is each node's title, state and labels from
    /// its connector, by ref, for the nodes a connector could resolve (#3089). `resolving` says
    /// some nodes are still being resolved in the background: walk again shortly for them (#3102).
    struct LineageGraph: Codable, Sendable, Hashable {
        public var nodes: [LineageNode]
        public var links: [LineageLink]
        public var limited: Bool?
        public var resolving: Bool?
        public var resolved: [String: LineageResolved]?

        public init(nodes: [LineageNode] = [], links: [LineageLink] = [], limited: Bool? = nil,
                    resolving: Bool? = nil, resolved: [String: LineageResolved]? = nil) {
            self.nodes = nodes
            self.links = links
            self.limited = limited
            self.resolving = resolving
            self.resolved = resolved
        }
    }

    /// A node's title, state and labels from its connector (#3089), resolved and cached on the
    /// daemon: `github:alexec/Agents#12` becomes its real title, not a guess from the ref.
    /// `state` is open, closed or merged (a pull request's; an issue's is open or closed); nil
    /// when the connector did not say. `labels` is empty when it has none. Resolved for a GitHub
    /// or GitLab issue or pull request only; Linear and releases are not resolved yet.
    struct LineageResolved: Codable, Sendable, Hashable {
        public var title: String
        public var state: String?
        public var labels: [String]?

        public init(title: String, state: String? = nil, labels: [String]? = nil) {
            self.title = title
            self.state = state
            self.labels = labels
        }
    }

    /// One node's banked cost on a machine, with what its rollups need.
    struct LineageCostNode: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var repo: String?
        public var banked: LineageCost
        public var fixes: [String]?
        public var partOf: [String]?
        /// A PR's end: merged, closed (waste) or reverted (waste). Absent while open.
        public var outcome: String?
        public var failedChecks: Int?
        public var lastAt: Date
        /// An issue's or PR's title, state and labels as the machine's resolve cache had them (#3118).
        public var resolved: LineageResolved?
        /// The sessions that worked on it, by ref, at most 20 (#3118).
        public var sessions: [String]?

        public init(node: LineageNode, repo: String? = nil, banked: LineageCost = .init(), fixes: [String]? = nil,
                    partOf: [String]? = nil, outcome: String? = nil, failedChecks: Int? = nil, lastAt: Date,
                    resolved: LineageResolved? = nil, sessions: [String]? = nil) {
            self.node = node
            self.repo = repo
            self.banked = banked
            self.fixes = fixes
            self.partOf = partOf
            self.outcome = outcome
            self.failedChecks = failedChecks
            self.lastAt = lastAt
            self.resolved = resolved
            self.sessions = sessions
        }
    }

    /// `lineage/cost`'s answer: a node's cost rolled up. An issue's total adds the PRs that fix it.
    struct LineageCostRollup: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var own: LineageCost
        public var total: LineageCost
        public var waste: LineageCost
        public var unlinked: LineageCost
        public var prsMerged: Int
        public var prsClosed: Int
        public var prsReverted: Int
        public var failedChecks: Int
        public var parts: [LineageCostNode]
        public var limited: Bool?

        public init(node: LineageNode, own: LineageCost = .init(), total: LineageCost = .init(), waste: LineageCost = .init(),
                    unlinked: LineageCost = .init(), prsMerged: Int = 0, prsClosed: Int = 0, prsReverted: Int = 0,
                    failedChecks: Int = 0, parts: [LineageCostNode] = [], limited: Bool? = nil) {
            self.node = node
            self.own = own
            self.total = total
            self.waste = waste
            self.unlinked = unlinked
            self.prsMerged = prsMerged
            self.prsClosed = prsClosed
            self.prsReverted = prsReverted
            self.failedChecks = failedChecks
            self.parts = parts
            self.limited = limited
        }
    }

    /// `lineage/estimate`: an issue or an epic, and when work on it starts (now when nil).
    struct LineageEstimateRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var startAt: Date?

        public init(node: LineageNode, startAt: Date? = nil) {
            self.node = node
            self.startAt = startAt
        }
    }

    /// A figure's estimate: the median and the P10 to P90 range.
    struct LineageEstimateRange: Codable, Sendable, Hashable {
        public var median: Double
        public var p10: Double
        public var p90: Double

        public init(median: Double, p10: Double, p90: Double) {
            self.median = median
            self.p10 = p10
            self.p90 = p90
        }
    }

    /// When work lands: the median and the P10 to P90 range.
    struct LineageEstimateDates: Codable, Sendable, Hashable {
        public var median: Date
        public var p10: Date
        public var p90: Date

        public init(median: Date, p10: Date, p90: Date) {
            self.median = median
            self.p10 = p10
            self.p90 = p90
        }
    }

    /// An estimate as it was when work started (#3561): the medians, from the issues merged
    /// before then, and (#4525) the P10 to P90 beside each, the cycle time and landsAt.
    struct LineageEstimateKept: Codable, Sendable, Hashable {
        public var at: Date
        public var matchedBy: String?
        public var matches: Int
        /// Dollars, by currency.
        public var cost: [String: Double]?
        public var costP10: [String: Double]?
        public var costP90: [String: Double]?
        public var outputTokens: Double?
        public var outputTokensP10: Double?
        public var outputTokensP90: Double?
        public var workingSeconds: Double?
        public var workingSecondsP10: Double?
        public var workingSecondsP90: Double?
        public var cycleTimeSeconds: LineageEstimateRange?
        public var landsAt: LineageEstimateDates?

        public init(at: Date, matchedBy: String? = nil, matches: Int = 0, cost: [String: Double]? = nil,
                    costP10: [String: Double]? = nil, costP90: [String: Double]? = nil,
                    outputTokens: Double? = nil, outputTokensP10: Double? = nil, outputTokensP90: Double? = nil,
                    workingSeconds: Double? = nil, workingSecondsP10: Double? = nil, workingSecondsP90: Double? = nil,
                    cycleTimeSeconds: LineageEstimateRange? = nil, landsAt: LineageEstimateDates? = nil) {
            self.at = at
            self.matchedBy = matchedBy
            self.matches = matches
            self.cost = cost
            self.costP10 = costP10
            self.costP90 = costP90
            self.outputTokens = outputTokens
            self.outputTokensP10 = outputTokensP10
            self.outputTokensP90 = outputTokensP90
            self.workingSeconds = workingSeconds
            self.workingSecondsP10 = workingSecondsP10
            self.workingSecondsP90 = workingSecondsP90
            self.cycleTimeSeconds = cycleTimeSeconds
            self.landsAt = landsAt
        }
    }

    /// `lineage/estimate`'s answer (#3559): what an issue or an epic will probably cost and take,
    /// from the closed issues like it. A figure is nil when fewer than 5 matches have it. An epic
    /// has its open children's estimates, and what its closed children spent.
    struct LineageEstimate: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var type: String?
        public var level: String?
        public var step: Int?
        public var closedIssues: Int
        /// level, type or all; nil for an epic, and with too few closed issues.
        public var matchedBy: String?
        public var matches: Int
        /// Dollars, by currency.
        public var cost: [String: LineageEstimateRange]?
        public var inputTokens: LineageEstimateRange?
        public var outputTokens: LineageEstimateRange?
        public var workingSeconds: LineageEstimateRange?
        public var leadTimeSeconds: LineageEstimateRange?
        public var cycleTimeSeconds: LineageEstimateRange?
        public var landsAt: LineageEstimateDates?
        public var openChildren: Int?
        public var closedChildren: Int?
        public var spent: LineageCost?
        public var children: [LineageEstimate]?
        /// The estimate when work on it started, and what a closed one took (#3561).
        public var kept: LineageEstimateKept?
        public var actual: LineageCost?

        public init(node: LineageNode, type: String? = nil, level: String? = nil, step: Int? = nil, closedIssues: Int = 0,
                    matchedBy: String? = nil, matches: Int = 0, cost: [String: LineageEstimateRange]? = nil,
                    inputTokens: LineageEstimateRange? = nil, outputTokens: LineageEstimateRange? = nil,
                    workingSeconds: LineageEstimateRange? = nil, leadTimeSeconds: LineageEstimateRange? = nil,
                    cycleTimeSeconds: LineageEstimateRange? = nil, landsAt: LineageEstimateDates? = nil,
                    openChildren: Int? = nil, closedChildren: Int? = nil, spent: LineageCost? = nil,
                    children: [LineageEstimate]? = nil, kept: LineageEstimateKept? = nil, actual: LineageCost? = nil) {
            self.node = node
            self.type = type
            self.level = level
            self.step = step
            self.closedIssues = closedIssues
            self.matchedBy = matchedBy
            self.matches = matches
            self.cost = cost
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.workingSeconds = workingSeconds
            self.leadTimeSeconds = leadTimeSeconds
            self.cycleTimeSeconds = cycleTimeSeconds
            self.landsAt = landsAt
            self.openChildren = openChildren
            self.closedChildren = closedChildren
            self.spent = spent
            self.children = children
            self.kept = kept
            self.actual = actual
        }
    }
}

/// The lineage nodes and walks the clients ask for: a lead's epic, an epic's plan, Work's links.
public enum LineageList {
    public typealias Node = DaemonAPI.LineageNode

    /// How far a walk goes: issue, its sessions, their PRs.
    public static let depth = 2

    public static func node(ofSession id: UUID) -> Node {
        Node(kind: "session", ref: "session:\(id.uuidString)")
    }

    /// A PR's page, not its issue's: GitHub sends /issues/ to /pull/ but not the other way.
    static func pullRequest(_ node: Node, _ url: URL) -> URL {
        guard node.kind == "pr" else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/issues/", with: "/pull/")) ?? url
    }
}

/// The places a page went to, and the ones before and after it, as a browser's Back and
/// Forward: Work's and Docs' pages (#3119, #3321).
public struct LineageHistory<Place: Hashable & Sendable>: Hashable, Sendable {
    public private(set) var places: [Place] = []
    public private(set) var at = -1
    /// How many places it keeps: the oldest go first.
    public static var most: Int { 50 }

    public init() {}

    public var current: Place? { places.indices.contains(at) ? places[at] : nil }
    public var canGoBack: Bool { at > 0 }
    public var canGoForward: Bool { at + 1 < places.count }

    /// Go to a place: the places after this one are dropped, as a browser drops them.
    public mutating func go(_ place: Place) {
        guard place != current else { return }
        places = Array(places.prefix(at + 1)) + [place]
        if places.count > Self.most { places.removeFirst(places.count - Self.most) }
        at = places.count - 1
    }

    /// Put a place where the current one is, as the browser's `replaceState` (#3257): Previous and
    /// Next on a Work page, so Back goes to the list and not through each item.
    public mutating func replace(_ place: Place) {
        guard places.indices.contains(at) else { return go(place) }
        places[at] = place
        places = Array(places.prefix(at + 1))
    }

    public mutating func back() { if canGoBack { at -= 1 } }
    public mutating func forward() { if canGoForward { at += 1 } }
}
