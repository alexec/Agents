import Foundation

/// The two layouts of a session's Lineage pane (#3019), behind the pane's Layout switch, as
/// `Web/src/model/lineage.ts` has them: a tree of the list's rows, and a graph of boxes and lines.
/// Both start at this session. The links are not a tree: a session that works on an issue and on
/// the PR that fixes it makes a triangle. The tree shows each node once, under the first node the
/// walk reached it from, and its other links stay in its lines; the graph draws every link.
public enum LineageLayout {
    public typealias Node = DaemonAPI.LineageNode

    public enum Style: String, CaseIterable, Sendable {
        case tree, graph

        public var title: String { self == .tree ? "Tree" : "Graph" }
    }

    /// One row of the tree: the list's row, how deep it is, and the lines to draw before it.
    public struct TreeRow: Sendable, Hashable, Identifiable {
        public var row: LineageList.Row
        /// 0 for this session (and for a node the walk did not reach from it), 1 for its links, and so on.
        public var depth: Int
        /// For each level from 1 to depth - 1: whether that ancestor has a sibling below, so its line
        /// goes on down past this row.
        public var guides: [Bool]
        /// The last child of its parent: its line stops at this row.
        public var last: Bool
        /// A line goes down from it to its first child.
        public var hasChildren: Bool
        public var id: String { row.id }
    }

    /// The row for this session itself, at the top of the tree and in the graph.
    public static func here(_ session: Node) -> LineageList.Row {
        LineageList.Row(node: session, name: "This session", links: [], cost: nil, url: nil, session: nil)
    }

    /// The tree, depth first, each node's children by kind: issues, PRs, sessions, runs, milestones.
    public static func tree(of session: Node, graph: DaemonAPI.LineageGraph,
                            costs: [Node: DaemonAPI.LineageCostRollup],
                            title: @escaping (Node) -> String?) -> [TreeRow] {
        let rows = LineageList.rows(of: session, graph: graph, costs: costs, title: title)
        guard !rows.isEmpty else { return [] }
        let byNode = Dictionary(rows.map { ($0.node, $0) }, uniquingKeysWith: { a, _ in a })
        let next = neighbours(graph)
        var children: [Node: [Node]] = [:]
        var placed: Set<Node> = [session]
        var queue = [session]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for n in next[parent] ?? [] where byNode[n] != nil && placed.insert(n).inserted {
                children[parent, default: []].append(n)
                queue.append(n)
            }
        }
        for (parent, list) in children { children[parent] = byKind(list) }
        var out: [TreeRow] = []
        func visit(_ node: Node, depth: Int, guides: [Bool], last: Bool) {
            let kids = children[node] ?? []
            out.append(TreeRow(row: node == session ? here(session) : byNode[node]!, depth: depth,
                               guides: guides, last: last, hasChildren: !kids.isEmpty))
            let below = depth == 0 ? guides : guides + [!last]
            for (i, kid) in kids.enumerated() {
                visit(kid, depth: depth + 1, guides: below, last: i == kids.count - 1)
            }
        }
        visit(session, depth: 0, guides: [], last: true)
        // A node the walk did not reach from this session (a walk cut at its limit) goes last, alone.
        for row in rows where !placed.contains(row.node) {
            out.append(TreeRow(row: row, depth: 0, guides: [], last: true, hasChildren: false))
        }
        return out
    }

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

    /// The graph's tier for a kind, so it reads top to bottom: milestone, issue, session, PR.
    static func tier(_ kind: String) -> Int {
        switch kind {
        case "milestone", "workflow": return 0
        case "issue", "workflow-run": return 1
        case "session": return 2
        case "pr": return 3
        default: return 4
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
        let all = [here(session)] + rows
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
                                       detail: ([kindWord(row.node.kind)] + (row.cost.map { [$0] } ?? [])).joined(separator: " · ")))
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

    /// In `LineageList.kinds`' order, the walk's order within a kind.
    static func byKind(_ nodes: [Node]) -> [Node] {
        let rank = { (n: Node) in LineageList.kinds.firstIndex(of: n.kind) ?? LineageList.kinds.count }
        return nodes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}
