import AgentsKitCore
import SwiftUI

/// A Mermaid diagram (#853), drawn from the boxes, lines and labels `MermaidDiagram` laid
/// out: in the Files pane, in a ```` ```mermaid ```` fence on a page, and small on the
/// chat's card. The page draws the same diagram as an SVG in MermaidView.tsx.
///
/// Fitted to the width it is offered, never drawn larger than its own size, so a
/// small diagram stays small and a wide one shrinks to fit.
struct MermaidView: View {
    /// A page's zoom (#1419): the diagram is drawn larger as a whole, because its
    /// boxes are sized for words at `MermaidDiagram.fontSize`.
    @Environment(\.textZoom) private var zoom
    let diagram: MermaidDiagram

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / diagram.width, size.height / diagram.height)
            context.scaleBy(x: scale, y: scale)
            draw(&context)
        }
        .aspectRatio(diagram.width / diagram.height, contentMode: .fit)
        .frame(maxWidth: diagram.width * zoom, maxHeight: diagram.height * zoom)
        .accessibilityElement()
        .accessibilityLabel("\(diagram.summary): \(diagram.labels.flatMap(\.lines).joined(separator: ", "))")
    }

    private func draw(_ context: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(.primary.opacity(0.7))
        for box in diagram.boxes where box.shape == .frame {
            context.stroke(path(box), with: .color(.primary.opacity(0.35)), lineWidth: 1)
        }
        for line in diagram.lines {
            var path = Path()
            path.addLines(line.points.map(\.cgPoint))
            context.stroke(path, with: ink, style: StrokeStyle(
                lineWidth: line.stroke == .thick ? 2.5 : 1.2, lineJoin: .round,
                dash: line.stroke == .dashed ? [4, 3] : []))
            for head in line.heads {
                var shape = Path()
                shape.addLines(head.points.map(\.cgPoint))
                if head.filled {
                    shape.closeSubpath()
                    context.fill(shape, with: ink)
                } else {
                    context.stroke(shape, with: ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        for box in diagram.boxes where box.shape != .frame {
            let shape = path(box)
            context.fill(shape, with: .style(.background))
            context.fill(shape, with: box.shape == .note ? .color(.yellow.opacity(0.2)) : .color(.accentColor.opacity(0.12)))
            context.stroke(shape, with: ink, lineWidth: 1)
        }
        let lineHeight = MermaidDiagram.lineHeight
        for label in diagram.labels {
            if label.backed {
                context.fill(Path(CGRect(x: label.x - 3, y: label.y, width: label.width + 6, height: label.height)),
                             with: .style(.background))
            }
            for (index, words) in label.lines.enumerated() {
                let y = label.y + lineHeight * (Double(index) + 0.5)
                // MermaidDiagram sizes every box for words at this size, so a scale step
                // would spill them out of their shapes. Decorative: part of the picture.
                context.draw(Text(words).font(.system(size: MermaidDiagram.fontSize)).foregroundStyle(.primary),
                             at: CGPoint(x: label.leading ? label.x : label.x + label.width / 2, y: y),
                             anchor: label.leading ? .leading : .center)
            }
        }
    }

    private func path(_ box: MermaidDiagram.Box) -> Path {
        let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        switch box.shape {
        case .rectangle: return Path(roundedRect: rect, cornerRadius: 3)
        case .rounded: return Path(roundedRect: rect, cornerRadius: 10)
        case .stadium: return Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .circle: return Path(ellipseIn: rect)
        case .note: return Path(roundedRect: rect, cornerRadius: 2)
        case .frame: return Path(rect)
        case .diamond:
            var path = Path()
            path.addLines([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                           CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)])
            path.closeSubpath()
            return path
        }
    }
}

private extension MermaidDiagram.Point {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// A Mermaid file in the Files pane (#853): the diagram, or why it is not drawn, with
/// its source a toggle away. As `ChartPage` is for a chart.
struct MermaidPage: View {
    let text: String
    let url: URL
    let line: Int?

    @State private var diagram: Result<MermaidDiagram, MermaidProblem>?
    @State private var showsSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(summary).appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Picker("Show", selection: $showsSource) {
                    Text("Diagram").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch diagram {
            case .success(let drawn) where !showsSource:
                ScrollView {
                    MermaidView(diagram: drawn)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                }
            case .failure(let problem) where !showsSource:
                VStack(alignment: .leading, spacing: 0) {
                    Text(problem.words).appText(.fine).foregroundStyle(.secondary).padding(10)
                    Divider()
                    FileLines(text: text, line: line, path: url.path)
                }
            case nil where !showsSource:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                FileLines(text: text, line: line, path: url.path)
            }
        }
        .task(id: text) {
            diagram = MermaidDiagram.read(text)
        }
    }

    private var summary: String {
        switch diagram {
        case .success(let drawn): return drawn.summary
        case .failure: return "Not drawn"
        case nil: return ""
        }
    }
}

/// A ```` ```mermaid ```` fence on a page or in a message (#853): the diagram in the
/// fence's well, or, when it does not read, the fence as code with the reason above it.
struct MermaidFence<Code: View>: View {
    let text: String
    @ViewBuilder let code: () -> Code

    var body: some View {
        // Read as it is drawn, not after: a fence that showed its code first and then
        // the diagram would move everything below it.
        switch MermaidDiagram.read(text) {
        case .success(let drawn):
            MermaidView(diagram: drawn)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperWell(in: RoundedRectangle(cornerRadius: 8))
        case .failure(let problem):
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.words).appText(.fine).foregroundStyle(.secondary)
                code()
            }
        }
    }
}
