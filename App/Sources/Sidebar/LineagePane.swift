import AgentsKitCore
import SwiftUI

/// What a session is linked to (#2940), as the web page's Lineage tab: the issues, pull
/// requests, helpers and workflow runs within two links of it, each with its links and, for an
/// issue or a PR, what was banked on it. The links are the session's, not one turn's, so it is a
/// pane of the column and not a part of the turn detail. A graph of boxes and lines (#3019).
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
                LineageGraphView(graph: LineageLayout.graph(of: me, graph: graph, costs: costs, title: title),
                                 open: action(for:))
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        footer.padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
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
            // The daemon resolves issues' and PRs' titles in the background (#3102): walk
            // again while it says some are still to come.
            var latest = walked
            for _ in 0 ..< LineageList.resolvingAsks where latest.resolving == true {
                try await Task.sleep(for: .seconds(1))
                latest = try await model.lineageWalk(of: agent.id)
                guard !Task.isCancelled else { return }
                graph = latest
            }
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
                ForEach(graph.edges) { edge in
                    if let mid = graph.curve(edge)?.mid {
                        Text(edge.label)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .background(Paper.ground, in: RoundedRectangle(cornerRadius: 3))
                            .fixedSize()
                            .position(x: mid.x, y: mid.y)
                    }
                }
                .frame(width: graph.width, height: graph.height, alignment: .topLeading)
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
}

/// One box of the graph: the node's name, and its kind and cost; its links, one a line, in its help.
private struct LineageBox: View {
    let node: LineageLayout.GraphNode
    let open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .help(([node.row.name] + node.row.links + [node.row.url != nil ? "Open it on GitHub" : "Show this session"])
                    .joined(separator: "\n"))
        } else {
            content.help(([node.row.name] + node.row.links).joined(separator: "\n"))
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
