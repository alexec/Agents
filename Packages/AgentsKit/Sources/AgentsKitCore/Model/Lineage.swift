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

    /// `lineage/figures` (#4427): a release's Lineage panel, from this machine's totals. `cost` is
    /// its rollup's total; `sessions` the sessions on it and its parts, each once, of which
    /// `running` run now; `runtimes` those this machine has, the most sessions first;
    /// `leadTimeSeconds` from the first work on its parts to its tag.
    struct LineageFigures: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var cost: LineageCost
        public var sessions: Int
        public var running: Int
        public var runtimes: [LineageRuntimeCount]
        public var leadTimeSeconds: Double?
        public var limited: Bool?

        public init(node: LineageNode, cost: LineageCost = .init(), sessions: Int = 0, running: Int = 0,
                    runtimes: [LineageRuntimeCount] = [], leadTimeSeconds: Double? = nil, limited: Bool? = nil) {
            self.node = node
            self.cost = cost
            self.sessions = sessions
            self.running = running
            self.runtimes = runtimes
            self.leadTimeSeconds = leadTimeSeconds
            self.limited = limited
        }
    }

    /// A runtime of `lineage/figures`' sessions, and how many of them it ran (#4427).
    struct LineageRuntimeCount: Codable, Sendable, Hashable {
        public var runtimeID: String
        public var sessions: Int

        public init(runtimeID: String, sessions: Int) {
            self.runtimeID = runtimeID
            self.sessions = sessions
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

    /// `lineage/forecast` (#4526): an epic, for when it lands and its estimate to complete; or a
    /// milestone by name, in folder's repo (#4620); neither for only the spend, the burn and the
    /// service levels.
    struct LineageForecastRequest: Codable, Sendable, Hashable {
        public var node: LineageNode?
        public var milestone: String?
        public var folder: String?

        public init(node: LineageNode? = nil, milestone: String? = nil, folder: String? = nil) {
            self.node = node
            self.milestone = milestone
            self.folder = folder
        }
    }

    /// When an epic lands (#4526): P50 and P85, from the hourly throughput of the last 14 days and
    /// the closed epics' median share, with the children as the plan says them now.
    struct LineageForecastLands: Codable, Sendable, Hashable {
        public var p50: Date
        public var p85: Date
        public var open: Int
        public var closed: Int
        public var stepsLeft: Int
        public var share: Double
        public var groups: Int
        /// A milestone with less than half of its items landed (#4620): its scope is still growing.
        public var growing: Bool?
    }

    /// An epic's first landing forecast, kept on its node to score when it lands (#4526).
    struct LineageForecastKept: Codable, Sendable, Hashable {
        public var at: Date
        public var p50: Date
        public var p85: Date
        public var windowDays: Int
        public var share: Double
        public var open: Int
    }

    /// An epic's estimate to complete (#4526): dollars by currency, P10 to P90.
    struct LineageForecastToComplete: Codable, Sendable, Hashable {
        public var cost: [String: LineageEstimateRange]
        public var ratio: Double
        public var closed: Int
        public var leadRatio: Double
    }

    /// What a week and a month cost at the window's pace (#4526): dollars by currency.
    struct LineageForecastSpend: Codable, Sendable, Hashable {
        public var week: [String: LineageEstimateRange]
        public var month: [String: LineageEstimateRange]
    }

    /// A weekly allowance's pace (#4526): when it runs out, or that it lasts to the reset.
    struct LineageForecastBurn: Codable, Sendable, Hashable {
        public var credentialKey: String
        public var window: String
        public var used: Double
        public var at: Date
        public var resetsAt: Date
        public var runsOutAt: Date?
        public var lasts: Bool
    }

    /// How long a level's issues took in the window (#4526): half by p50Seconds, 85% by p85Seconds.
    struct LineageForecastServiceLevel: Codable, Sendable, Hashable {
        public var level: String
        public var closed: Int
        public var p50Seconds: Double
        public var p85Seconds: Double
    }

    /// `lineage/forecast`'s answer (#4526): what comes next, from this machine's totals.
    struct LineageForecast: Codable, Sendable, Hashable {
        public var node: LineageNode?
        public var milestone: String?
        public var at: Date
        public var windowDays: Int
        public var landings: Int
        public var lands: LineageForecastLands?
        /// Why there is no landing date.
        public var noForecast: String?
        public var toComplete: LineageForecastToComplete?
        public var kept: LineageForecastKept?
        public var spend: LineageForecastSpend?
        public var burn: [LineageForecastBurn]
        public var serviceLevels: [LineageForecastServiceLevel]
    }

    /// A session node's state now (#4274): working, waiting, needs-you, stopped, archived or
    /// deleted, and when it changed to it. A state this build does not know is kept as it is.
    struct LineageSessionState: Codable, Sendable, Hashable {
        public var state: String
        public var at: Date

        public init(state: String, at: Date) {
            self.state = state
            self.at = at
        }

        /// In a turn now.
        public var working: Bool { state == "working" }
    }

    /// A session node's change of state, and when (#4275).
    struct LineageStateChange: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var state: String
        public var at: Date

        public init(node: LineageNode, state: String, at: Date) {
            self.node = node
            self.state = state
            self.at = at
        }
    }

    /// `lineage/walkAll` (#4276): `lineage/walk` over the control plane's merged copy of every
    /// machine's lineage in the scope (`me` when nil for a member, the organisation for an admin).
    struct LineageWalkAllRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var depth: Int?
        public var scope: ReportScope?

        public init(node: LineageNode, depth: Int? = nil, scope: ReportScope? = nil) {
            self.node = node
            self.depth = depth
            self.scope = scope
        }
    }

    /// `lineage/sessionsOn` (#4276): the nodes (at most 500) whose sessions to say, over every
    /// machine's copy in the scope.
    struct LineageSessionsOnRequest: Codable, Sendable, Hashable {
        public var nodes: [LineageNode]
        public var scope: ReportScope?

        public init(nodes: [LineageNode], scope: ReportScope? = nil) {
            self.nodes = nodes
            self.scope = scope
        }
    }

    /// A session lineage links to nodes asked for, on any machine: its machine, the nodes it is
    /// on, when its first link to them started, and its state now when its machine sent one.
    struct LineageSessionOn: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var host: String
        public var on: [LineageNode]
        public var at: Date
        public var state: LineageSessionState?

        public init(node: LineageNode, host: String, on: [LineageNode], at: Date, state: LineageSessionState? = nil) {
            self.node = node
            self.host = host
            self.on = on
            self.at = at
            self.state = state
        }
    }

    /// `lineage/sessionsOn`'s answer: each session once, the earliest link first.
    struct LineageSessionsOn: Codable, Sendable, Hashable {
        public var sessions: [LineageSessionOn]
        public var limited: Bool?

        public init(sessions: [LineageSessionOn] = [], limited: Bool? = nil) {
            self.sessions = sessions
            self.limited = limited
        }
    }

    /// `control/lineageChanged` (#4276): a machine sent lineage the merged copy did not have:
    /// its sessions' changes of state, and `links` when links changed too.
    struct LineageChanged: Codable, Sendable, Hashable {
        public var host: String
        public var states: [LineageStateChange]
        public var links: Bool?

        public init(host: String, states: [LineageStateChange] = [], links: Bool? = nil) {
            self.host = host
            self.states = states
            self.links = links
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

public extension DaemonAPI.Method {
    /// `LineageWalkAllRequest` → `LineageGraph`, from the control plane's merged copy (#4276).
    static let lineageWalkAll = "lineage/walkAll"
    /// `LineageSessionsOnRequest` → `LineageSessionsOn`, from the control plane's merged copy (#4276).
    static let lineageSessionsOn = "lineage/sessionsOn"
}

public extension DaemonAPI.Notification {
    /// `LineageChanged`: a machine sent new lineage to the control plane (#4276).
    static let controlLineageChanged = "control/lineageChanged"
}
