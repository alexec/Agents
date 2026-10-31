import AgentsKitCore
import SwiftUI

/// What a session is linked to (#2940), as the web page's Lineage tab: the issues, pull
/// requests, helpers and workflow runs within two links of it, each with its links and, for an
/// issue or a PR, what was banked on it. The links are the session's, not one turn's, so it is a
/// pane of the column and not a part of the turn detail. Two layouts, behind its Layout switch
/// so Alex can compare them (#3019): a tree from this session, and a graph of boxes and lines.
struct LineagePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// In a folder's window there is only its own session to go to (#1089).
    @Environment(\.poppedChat) private var popped
    let agent: Agent
    /// Read again each time the pane is shown: links come as the session works.
    let isVisible: Bool

    @State private var graph: DaemonAPI.LineageGraph?
    @State private var costs: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
    @State private var failure: String?
    @State private var asked = 0
    @AppStorage("lineageLayout", store: WindowDefaults.store) private var layout = LineageLayout.Style.tree

    private var me: LineageList.Node { LineageList.node(ofSession: agent.id) }

    private func title(_ node: LineageList.Node) -> String? {
        guard node.kind == "session", let id = UUID(uuidString: String(node.ref.dropFirst("session:".count))) else { return nil }
        return model.work.agent(id)?.title
    }

    var body: some View {
        Group {
            if let failure {
                message(failure)
            } else if graph == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let graph, !graph.nodes.contains(where: { $0 != me }) {
                message(LineageList.none)
            } else if let graph {
                switch layout {
                case .tree:
                    LineageTreeView(rows: LineageLayout.tree(of: me, graph: graph, costs: costs, title: title), me: me,
                                    open: action(for:), footer: footer)
                case .graph:
                    LineageGraphView(graph: LineageLayout.graph(of: me, graph: graph, costs: costs, title: title),
                                     open: action(for:))
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            footer.padding(.horizontal, 12).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Picker("Layout", selection: $layout) {
                    ForEach(LineageLayout.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the links as a tree from this session, or as a graph of boxes and lines")
                Spacer()
                Button("Refresh") { asked += 1 }
                    .buttonStyle(.link)
                    .help("Read the links and the costs again")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: Ask(visible: isVisible, asked: asked)) {
            guard isVisible else { return }
            await load()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if graph?.limited == true {
                Text("The walk stopped at its limit: there are more links.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            Text(LineageList.note)
                .appText(.fine).foregroundStyle(.tertiary)
        }
    }

    private struct Ask: Equatable {
        var visible: Bool
        var asked: Int
    }

    private func load() async {
        do {
            let walked = try await model.lineageWalk(of: agent.id)
            failure = nil
            graph = walked
            var found: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
            await withTaskGroup(of: DaemonAPI.LineageCostRollup?.self) { group in
                for node in walked.nodes where LineageList.costed(node) {
                    group.addTask { await model.lineageCost(node, of: agent.id) }
                }
                for await rollup in group {
                    if let rollup { found[rollup.node] = rollup }
                }
            }
            guard !Task.isCancelled else { return }
            costs = found
        } catch {
            guard !Task.isCancelled else { return }
            failure = "The links could not be read: \(error.localizedDescription)"
        }
    }

    /// A GitHub issue or PR opens in the browser; a session in this window goes to its chat.
    private func action(for row: LineageList.Row) -> (() -> Void)? {
        if let url = row.url { return { openURL(url) } }
        if popped == nil, let id = row.session, model.work.agent(id) != nil { return { model.selection = id } }
        return nil
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LineageRowView: View {
    let row: LineageList.Row
    let open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .help(row.url != nil ? "Open it on GitHub" : "Show this session")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .appText(.reading).fontWeight(.medium)
                .foregroundStyle(open == nil ? .primary : Paper.accent)
                .lineLimit(1)
                .truncationMode(.middle)
            if let cost = row.cost {
                Text(cost)
                    .appText(.supporting)
                    .monospacedDigit()
            }
            ForEach(row.links, id: \.self) { line in
                Text(line)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The tree (#3019): the list's rows, this session at the top, each indented under the node the
/// walk reached it from, with a line from each to its parent.
private struct LineageTreeView<Footer: View>: View {
    let rows: [LineageLayout.TreeRow]
    let me: LineageList.Node
    let open: (LineageList.Row) -> (() -> Void)?
    let footer: Footer

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { tree in
                    LineageRowView(row: tree.row, open: open(tree.row))
                        .padding(.vertical, 4)
                        .padding(.leading, TreeLines.indent * CGFloat(tree.depth + 1))
                        .background(alignment: .leading) { TreeLines(tree: tree, here: tree.row.node == me) }
                }
                footer.padding(.top, 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// The lines before a row of the tree: an ancestor's line going on down past it, the elbow from
/// its parent's line to its dot, and a line down from its dot to its first child.
private struct TreeLines: View {
    static let indent: CGFloat = 18
    /// Where the elbow meets the dot: the middle of the name's line.
    static let elbow: CGFloat = 15
    let tree: LineageLayout.TreeRow
    let here: Bool

    var body: some View {
        Canvas { context, size in
            let x = { (level: Int) in Self.indent * CGFloat(level) + Self.indent / 2 }
            var lines = Path()
            for (i, goesOn) in tree.guides.enumerated() where goesOn {
                lines.move(to: CGPoint(x: x(i), y: 0))
                lines.addLine(to: CGPoint(x: x(i), y: size.height))
            }
            if tree.depth > 0 {
                let parent = x(tree.depth - 1)
                lines.move(to: CGPoint(x: parent, y: 0))
                lines.addLine(to: CGPoint(x: parent, y: tree.last ? Self.elbow : size.height))
                lines.move(to: CGPoint(x: parent, y: Self.elbow))
                lines.addLine(to: CGPoint(x: x(tree.depth) - 4, y: Self.elbow))
            }
            if tree.hasChildren {
                lines.move(to: CGPoint(x: x(tree.depth), y: Self.elbow + 4))
                lines.addLine(to: CGPoint(x: x(tree.depth), y: size.height))
            }
            context.stroke(lines, with: .color(Paper.rule), lineWidth: 1.5)
            let dot = CGRect(x: x(tree.depth) - 3.5, y: Self.elbow - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(here ? Paper.accent : .secondary))
        }
        .frame(width: TreeLines.indent * CGFloat(tree.depth + 1))
        .accessibilityHidden(true)
    }
}

/// The graph (#3019): a box for each node, in a tier per kind, a line for each link named by its
/// verb, a box's cost on its second line. It starts as wide as the pane, at most actual size.
/// Scroll to move about; pinch or the buttons to zoom.
private struct LineageGraphView: View {
    let graph: LineageLayout.Graph
    let open: (LineageList.Row) -> (() -> Void)?
    /// Nil: as wide as the pane.
    @State private var zoom: Double?
    @GestureState private var pinch = 1.0

    private static func clamp(_ z: Double) -> Double { min(max(z, 0.4), 2.5) }

    var body: some View {
        GeometryReader { pane in
            let fit = Self.clamp(min(1, pane.size.width / max(graph.width, 1)))
            canvas(scale: Self.clamp((zoom ?? fit) * pinch), fit: fit)
        }
    }

    private func canvas(scale: Double, fit: Double) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in lines(&context) }
                    .frame(width: graph.width, height: graph.height)
                    .accessibilityHidden(true)
                ForEach(graph.nodes) { node in
                    LineageBox(node: node, open: open(node.row))
                        .frame(width: LineageLayout.boxWidth, height: LineageLayout.boxHeight)
                        .offset(x: node.x, y: node.y)
                }
                // The verbs over the boxes: a line that skips a tier passes under one.
                Canvas { context, _ in labels(&context) }
                    .frame(width: graph.width, height: graph.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: graph.width, height: graph.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: graph.width * scale, height: graph.height * scale, alignment: .topLeading)
        }
        .gesture(MagnifyGesture()
            .updating($pinch) { value, pinch, _ in pinch = value.magnification }
            .onEnded { zoom = Self.clamp((zoom ?? fit) * $0.magnification) })
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                Button { zoom = Self.clamp(scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button("\(Int((scale * 100).rounded()))%") { zoom = nil }
                    .monospacedDigit()
                    .help("Fit the pane's width")
                Button { zoom = Self.clamp(scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
            }
            .buttonStyle(.borderless)
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Paper.Radius.control))
            .padding(8)
        }
    }

    /// Each link's line, and an arrowhead where it ends.
    private func lines(_ context: inout GraphicsContext) {
        for edge in graph.edges {
            guard let curve = graph.curve(edge) else { continue }
            let p = { (q: LineageLayout.Point) in CGPoint(x: q.x, y: q.y) }
            var line = Path()
            line.move(to: p(curve.start))
            line.addCurve(to: p(curve.end), control1: p(curve.c1), control2: p(curve.c2))
            context.stroke(line, with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 1.2, dash: edge.ended ? [4, 3] : []))
            let angle = atan2(curve.end.y - curve.c2.y, curve.end.x - curve.c2.x)
            var head = Path()
            head.move(to: p(curve.end))
            for turn in [2.6, -2.6] {
                head.addLine(to: CGPoint(x: curve.end.x + 7 * cos(angle + turn), y: curve.end.y + 7 * sin(angle + turn)))
            }
            head.closeSubpath()
            context.fill(head, with: .color(.secondary))
        }
    }

    /// Each link's verb, halfway along its line.
    private func labels(_ context: inout GraphicsContext) {
        for edge in graph.edges {
            guard let curve = graph.curve(edge) else { continue }
            let label = context.resolve(Text(edge.label).font(.caption2).foregroundStyle(.secondary))
            let size = label.measure(in: CGSize(width: 160, height: 40))
            let at = CGPoint(x: curve.mid.x, y: curve.mid.y)
            context.fill(Path(roundedRect: CGRect(x: at.x - size.width / 2 - 3, y: at.y - size.height / 2 - 1,
                                                  width: size.width + 6, height: size.height + 2), cornerRadius: 3),
                         with: .color(Paper.ground))
            context.draw(label, at: at)
        }
    }
}

/// One box of the graph: the node's name, and its kind and cost.
private struct LineageBox: View {
    let node: LineageLayout.GraphNode
    let open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .help(node.row.url != nil ? "Open it on GitHub" : "Show this session")
        } else {
            content.help(node.row.name)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.row.name)
                .appText(.supporting).fontWeight(.medium)
                .foregroundStyle(open == nil ? .primary : Paper.accent)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(node.detail)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card)
            .strokeBorder(node.here ? Paper.accent : Paper.rule, lineWidth: node.here ? 2 : 1))
        .contentShape(Rectangle())
    }
}
