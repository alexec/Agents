import Foundation

/// A session's Lineage pane, and the Lineage page (#3087), as a graph of boxes and lines (#3019), as
/// `Web/src/model/lineage.ts` has it: the start and the nodes it is linked to, a line for every link. The links are not a
/// tree: a session that works on an issue and on the PR that fixes it makes a triangle.
public enum LineageLayout {
    public typealias Node = DaemonAPI.LineageNode

    /// One box of the graph, its top-left corner in points.
    public struct GraphNode: Sendable, Hashable, Identifiable {
        public var row: LineageList.Row
        public var x: Double
        public var y: Double
        public var here: Bool
        /// The box's second line: "Issue · $4.00 · 12m working · merged".
        public var detail: String
        public var id: String { row.id }
    }

    /// One line of the graph: a link, from one box to another, named by its verb.
    public struct GraphEdge: Sendable, Hashable, Identifiable {
        public var from: String
        public var to: String
        /// "works on", "fixes", "started".
        public var label: String
        /// The link stopped being active: a PR merged, a session archived.
        public var ended: Bool
        public var id: String { "\(from)\n\(rel)\n\(to)" }
        var rel: String
    }

    public struct Graph: Sendable, Hashable {
        public var nodes: [GraphNode]
        public var edges: [GraphEdge]
        public var width: Double
        public var height: Double

        public func node(_ id: String) -> GraphNode? { nodes.first { $0.id == id } }

        /// Where an edge's line goes: from the bottom or top of one box to the top or bottom of the
        /// other, or below a tier for two boxes in it, with `mid` the point halfway for its label.
        public func curve(_ edge: GraphEdge) -> Curve? {
            guard let a = node(edge.from), let b = node(edge.to) else { return nil }
            let h = LineageLayout.boxHeight, ax = a.x + LineageLayout.boxWidth / 2, bx = b.x + LineageLayout.boxWidth / 2
            let start: Point, end: Point, c1: Point, c2: Point
            if a.y == b.y {
                start = Point(x: ax, y: a.y + h); end = Point(x: bx, y: b.y + h)
                c1 = Point(x: ax, y: start.y + LineageLayout.arc); c2 = Point(x: bx, y: end.y + LineageLayout.arc)
            } else {
                let down = a.y < b.y
                start = Point(x: ax, y: down ? a.y + h : a.y); end = Point(x: bx, y: down ? b.y : b.y + h)
                let dy = (end.y - start.y) / 2
                c1 = Point(x: ax, y: start.y + dy); c2 = Point(x: bx, y: end.y - dy)
            }
            let mid = Point(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8, y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8)
            return Curve(start: start, c1: c1, c2: c2, end: end, mid: mid)
        }
    }

    public struct Point: Sendable, Hashable {
        public var x: Double
        public var y: Double
    }

    /// A cubic curve, and the point halfway along it.
    public struct Curve: Sendable, Hashable {
        public var start: Point
        public var c1: Point
        public var c2: Point
        public var end: Point
        public var mid: Point
    }

    /// "Issue", "Pull request": the first words of a box's second line.
    public static func kindWord(_ kind: String) -> String {
        switch kind {
        case "issue": return "Issue"
        case "pr": return "Pull request"
        case "session": return "Session"
        case "workflow-run": return "Workflow run"
        case "workflow": return "Workflow"
        case "milestone": return "Milestone"
        case "release": return "Release"
        default: return kind
        }
    }

    /// A box's size and the room between them, in points (pixels on the web page).
    public static let boxWidth = 180.0
    public static let boxHeight = 52.0
    /// Between tiers: room for a line's verb.
    public static let tierGap = 56.0
    /// Between two boxes of a tier.
    public static let gap = 16.0
    public static let margin = 16.0
    /// How far a line between two boxes of one tier bends down below it.
    public static let arc = 40.0

    /// The graph's tier for a kind, so it reads top to bottom: milestone, issue, session, PR,
    /// release (#3023: what shipped it, last).
    static func tier(_ kind: String) -> Int {
        switch kind {
        case "milestone", "workflow": return 0
        case "issue", "workflow-run": return 1
        case "session": return 2
        case "pr": return 3
        case "release": return 4
        default: return 5
        }
    }

    /// The graph: a tier per kind, top to bottom, empty tiers left out, each tier in the order of the
    /// boxes it links to above it, so fewer lines cross. Tiers are centred on the widest. Top to
    /// bottom, so that it fits the side column: a walk has few tiers and few boxes in each.
    public static func graph(of session: Node, graph walked: DaemonAPI.LineageGraph,
                             costs: [Node: DaemonAPI.LineageCostRollup],
                             title: @escaping (Node) -> String?) -> Graph {
        let rows = LineageList.rows(of: session, graph: walked, costs: costs, title: title)
        guard !rows.isEmpty else { return Graph(nodes: [], edges: [], width: 0, height: 0) }
        let all = [LineageList.start(session, graph: walked, costs: costs, title: title)] + rows
        let next = neighbours(walked)
        var index: [Node: Int] = [:]
        var tiers: [[LineageList.Row]] = []
        for kind in Set(all.map { tier($0.node.kind) }).sorted() {
            let these = all.enumerated().filter { tier($0.element.node.kind) == kind }
            let ordered = these.map { (i, row) -> (Double, Int, LineageList.Row) in
                let above = (next[row.node] ?? []).compactMap { index[$0] }
                return (above.isEmpty ? .infinity : Double(above.reduce(0, +)) / Double(above.count), i, row)
            }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
            for (i, row) in ordered.enumerated() { index[row.node] = i }
            tiers.append(ordered)
        }
        let span = { (n: Int) in Double(n) * (boxWidth + gap) - gap }
        let wide = span(tiers.map(\.count).max() ?? 0)
        var nodes: [GraphNode] = []
        for (t, tier) in tiers.enumerated() {
            for (i, row) in tier.enumerated() {
                nodes.append(GraphNode(row: row, x: margin + (wide - span(tier.count)) / 2 + Double(i) * (boxWidth + gap),
                                       y: margin + Double(t) * (boxHeight + tierGap),
                                       here: row.node == session,
                                       detail: ([kindWord(row.node.kind)] + (row.cost.map { [$0] } ?? [])
                                           + (row.resolved.map { [$0] } ?? [])).joined(separator: " · ")))
            }
        }
        var seen = Set<String>()
        let edges = walked.links.compactMap { link -> GraphEdge? in
            guard index[link.from] != nil, index[link.to] != nil else { return nil }
            let edge = GraphEdge(from: link.from.ref, to: link.to.ref, label: LineageList.relWords(link.rel),
                                 ended: link.endedAt != nil, rel: link.rel)
            return seen.insert(edge.id).inserted ? edge : nil
        }
        // A line below the last tier needs room for its bend.
        let last = tiers.count - 1
        let bends = edges.contains { e in
            [e.from, e.to].allSatisfy { id in tiers[last].contains { $0.id == id } }
        }
        let height = 2 * margin + Double(tiers.count) * boxHeight + Double(last) * tierGap + (bends ? arc : 0)
        return Graph(nodes: nodes, edges: edges, width: 2 * margin + wide, height: height)
    }

    /// Each node's links, either way, in the order the walk gave them.
    static func neighbours(_ graph: DaemonAPI.LineageGraph) -> [Node: [Node]] {
        var next: [Node: [Node]] = [:]
        for link in graph.links {
            next[link.from, default: []].append(link.to)
            next[link.to, default: []].append(link.from)
        }
        return next
    }

}
