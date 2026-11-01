import Foundation

/// The lineage graph as a session's Lineage pane reads it (#2940): `lineage/walk` from the
/// session, and `lineage/cost` for each issue and PR the walk reached (#2348, #2350).
public extension DaemonAPI {
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
    /// its connector, by ref, for the nodes a connector could resolve (#3089).
    struct LineageGraph: Codable, Sendable, Hashable {
        public var nodes: [LineageNode]
        public var links: [LineageLink]
        public var limited: Bool?
        public var resolved: [String: LineageResolved]?

        public init(nodes: [LineageNode] = [], links: [LineageLink] = [], limited: Bool? = nil,
                    resolved: [String: LineageResolved]? = nil) {
            self.nodes = nodes
            self.links = links
            self.limited = limited
            self.resolved = resolved
        }
    }

    /// A node's title, state and labels from its connector (#3089), resolved and cached on the
    /// daemon: `github:alexec/Agents#12` becomes its real title, not a guess from the ref.
    /// `state` is open, closed or merged (a pull request's; an issue's is open or closed); nil
    /// when the connector did not say. `labels` is empty when it has none. Resolved for a GitHub
    /// or GitLab issue or pull request only; Linear, milestones and releases are not resolved yet.
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
        public var project: String?
        public var banked: LineageCost
        public var fixes: [String]?
        public var partOf: [String]?
        /// A PR's end: merged, closed (waste) or reverted (waste). Absent while open.
        public var outcome: String?
        public var failedChecks: Int?
        public var lastAt: Date

        public init(node: LineageNode, project: String? = nil, banked: LineageCost = .init(), fixes: [String]? = nil,
                    partOf: [String]? = nil, outcome: String? = nil, failedChecks: Int? = nil, lastAt: Date) {
            self.node = node
            self.project = project
            self.banked = banked
            self.fixes = fixes
            self.partOf = partOf
            self.outcome = outcome
            self.failedChecks = failedChecks
            self.lastAt = lastAt
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
}

/// A session's Lineage pane (#2940), as `Web/src/model/lineage.ts` has it on the web page: the
/// nodes the session is linked to, each with its links and, for an issue or a PR, what was banked
/// on it. `LineageLayout` lays them out as a graph (#3019).
public enum LineageList {
    public typealias Node = DaemonAPI.LineageNode

    /// How far the pane walks: issue, its sessions, their PRs.
    public static let depth = 2

    public static func node(ofSession id: UUID) -> Node {
        Node(kind: "session", ref: "session:\(id.uuidString)")
    }

    /// One node in the list.
    public struct Row: Sendable, Hashable, Identifiable {
        public var node: Node
        /// "alexec/agents#12", or the session's title.
        public var name: String
        /// One line per link to it: "This session works on it · from the branch".
        public var links: [String]
        /// "$4.00 · 12m working · merged", for an issue or a PR whose cost has come.
        public var cost: String?
        /// "open · bug, area:lineage", its state and labels from its connector (#3089).
        public var resolved: String?
        /// Where it is on its tracker, for a GitHub issue or PR.
        public var url: URL?
        /// The session it is, for a session node.
        public var session: UUID?

        public var id: String { node.ref }
    }


    /// A row for each node the walk reached, once, in the walk's order, the session itself left out.
    public static func rows(of session: Node, graph: DaemonAPI.LineageGraph,
                            costs: [Node: DaemonAPI.LineageCostRollup],
                            title: @escaping (Node) -> String?) -> [Row] {
        var seen = Set<Node>()
        let nodes = graph.nodes.filter { $0 != session && seen.insert($0).inserted }
        let name = { (n: Node) -> String in
            if n == session { return "This session" }
            return title(n) ?? graph.resolved?[n.ref]?.title ?? ReportValueWords.name(n)
        }
        return nodes.map { n in
            Row(node: n, name: name(n),
                links: graph.links.filter { $0.from == n || $0.to == n }.map { line($0, of: n, session: session, name: name) },
                cost: costs[n].map { costLine($0) },
                resolved: resolvedLine(graph.resolved?[n.ref]),
                url: ReportValueWords.url(n).map { pullRequest(n, $0) },
                session: n.kind == "session" ? UUID(uuidString: String(n.ref.dropFirst("session:".count))) : nil)
        }
    }

    /// "open · bug, area:lineage", from a node's resolved state and labels; nil with neither.
    static func resolvedLine(_ r: DaemonAPI.LineageResolved?) -> String? {
        guard let r else { return nil }
        var parts: [String] = []
        if let state = r.state { parts.append(state) }
        if let labels = r.labels, !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A PR's page, not its issue's: GitHub sends /issues/ to /pull/ but not the other way.
    static func pullRequest(_ node: Node, _ url: URL) -> URL {
        guard node.kind == "pr" else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/issues/", with: "/pull/")) ?? url
    }

    /// "This session works on it · from the branch", or "Fixes alexec/agents#12 · from the PR's text · ended".
    static func line(_ link: DaemonAPI.LineageLink, of node: Node, session: Node, name: (Node) -> String) -> String {
        let verb = relWords(link.rel)
        var parts = [link.to == node
            ? "\(name(link.from)) \(verb) it"
            : "\(verb.prefix(1).uppercased())\(verb.dropFirst()) \(link.to == session ? "this session" : name(link.to))"]
        parts.append(sourceWords(link.source))
        if link.endedAt != nil { parts.append("ended") }
        return parts.joined(separator: " · ")
    }

    static func relWords(_ rel: String) -> String {
        rel.replacingOccurrences(of: "-", with: " ")
    }

    static func sourceWords(_ source: String) -> String {
        switch source {
        case "start": return "when it started"
        case "branch": return "from the branch"
        case "pr-body": return "from the PR's text"
        case "helper": return "as a helper"
        case "agent": return "by the agent"
        case "person": return "by a person"
        default: return "from \(source)"
        }
    }

    /// "$4.00 · 12m working · 1 merged, 1 closed", or for a PR "… · merged". No cost or tokens
    /// when nothing was spent: "0 tokens" says nothing.
    static func costLine(_ r: DaemonAPI.LineageCostRollup) -> String {
        var parts = ReportValueWords.spent(r.total) ? [ReportValueWords.cost(r.total)] : []
        if r.total.workingSeconds > 0 { parts.append("\(TimeChart.words(r.total.workingSeconds)) working") }
        if r.node.kind == "pr" {
            switch r.parts.first(where: { $0.node == r.node })?.outcome {
            case "merged": parts.append("merged")
            case "closed": parts.append("closed without a merge: waste")
            case "reverted": parts.append("reverted: waste")
            case nil: parts.append("open")
            case let other?: parts.append(other)
            }
        } else if r.node.kind == "issue" {
            var ends: [String] = []
            if r.prsMerged > 0 { ends.append("\(r.prsMerged) merged") }
            if r.prsClosed > 0 { ends.append("\(r.prsClosed) closed") }
            if !ends.isEmpty { parts.append(ends.joined(separator: ", ")) }
            if ReportValueWords.spent(r.waste) { parts.append("\(ReportValueWords.cost(r.waste)) wasted") }
        }
        return parts.isEmpty ? "Nothing banked yet" : parts.joined(separator: " · ")
    }

    /// Whether a node's cost is asked for.
    public static func costed(_ node: Node) -> Bool {
        node.kind == "issue" || node.kind == "pr"
    }

    public static let none = "No links yet. A session is linked to an issue when it has a label such as #12, to a pull request when it opens one on its branch, and to the helpers and workflow runs it starts."
    public static let note = "Linked within two steps of this session. An issue’s cost is its own and its pull requests’."
}
