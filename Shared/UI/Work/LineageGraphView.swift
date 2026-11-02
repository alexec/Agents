import AgentsKitCore
import SwiftUI

/// The graph (#3019): a box for each node, in a tier per kind, a line for each link named by its
/// verb, a box's cost on its second line. It starts as wide as the pane, at most actual size.
/// Scroll to move about; pinch or the buttons to zoom.
struct LineageGraphView: View {
    let graph: LineageLayout.Graph
    let open: (LineageList.Row) -> (() -> Void)?
    /// What a box's help says a click does: "Open it on GitHub", "Start from it".
    var verb: (LineageList.Row) -> String = { $0.url != nil ? "Open it on GitHub" : "Show this session" }
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
            LineageDrawing(graph: graph, open: open, verb: verb)
                .equatable()
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
}

/// The boxes, lines and verbs of the graph at actual size. Equatable on the graph alone, so a
/// pinch, which only scales it, does not draw it again on each frame (#3112).
private struct LineageDrawing: View, Equatable {
    let graph: LineageLayout.Graph
    let open: (LineageList.Row) -> (() -> Void)?
    let verb: (LineageList.Row) -> String

    nonisolated static func == (a: Self, b: Self) -> Bool { a.graph == b.graph }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in lines(&context) }
                .frame(width: graph.width, height: graph.height)
                .accessibilityHidden(true)
            ForEach(graph.nodes) { node in
                LineageBox(node: node, open: open(node.row), verb: verb(node.row))
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

/// One box of the graph: the node's name, and its kind and cost; its name, ref, the whole of that
/// line and its links, one a line, in its help (#3159).
private struct LineageBox: View {
    let node: LineageLayout.GraphNode
    let open: (() -> Void)?
    let verb: String

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .help(([node.row.name] + [node.row.ref].compactMap { $0 } + [node.detail] + node.row.links + [verb])
                    .joined(separator: "\n"))
        } else {
            content.help(([node.row.name] + [node.row.ref].compactMap { $0 } + [node.detail] + node.row.links)
                .joined(separator: "\n"))
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
