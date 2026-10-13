import AgentsKitCore
import Charts
import SwiftUI

/// A chart from a file (#836), drawn with Swift Charts: in the Files pane, and small on
/// the chat's card. The page draws the same `ChartSpec` as an SVG in ChartView.tsx.
///
/// Compact is the card's: no title, no legend, axes reduced to their marks, so it reads
/// as a picture of the chart and a tap opens it whole.
struct ChartView: View {
    let spec: ChartSpec
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact, let title = spec.title {
                Text(title).appText(.reading).fontWeight(.semibold)
            }
            chart
                .chartLegend(compact || spec.series.isEmpty ? .hidden : .visible)
                .chartXAxis(compact ? .hidden : .automatic)
                .chartYAxis(compact ? .hidden : .automatic)
                .chartXAxisLabel(compact ? "" : spec.xField)
                .chartYAxisLabel(compact ? "" : spec.yField)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spec.title ?? spec.mark.words), \(spec.yField) by \(spec.xField)")
    }

    private var chart: some View {
        Chart(Array(spec.points.enumerated()), id: \.offset) { _, point in
            mark(point)
                .foregroundStyle(by: .value(spec.colorField ?? "Series", point.series ?? spec.yField))
        }
    }

    @ChartContentBuilder
    private func mark(_ point: ChartSpec.Point) -> some ChartContent {
        let y = PlottableValue.value(spec.yField, point.y)
        switch point.x {
        case .name(let name): marks(.value(spec.xField, name), y)
        case .number(let number): marks(.value(spec.xField, number), y)
        case .date(let date): marks(.value(spec.xField, date), y)
        }
    }

    @ChartContentBuilder
    private func marks<X: Plottable>(_ x: PlottableValue<X>, _ y: PlottableValue<Double>) -> some ChartContent {
        switch spec.mark {
        case .bar: BarMark(x: x, y: y)
        case .line: LineMark(x: x, y: y)
        case .point: PointMark(x: x, y: y)
        case .area: AreaMark(x: x, y: y)
        }
    }
}

/// A chart file in the Files pane (#836): the chart, or why it is not drawn, with its
/// source a toggle away. `neighbour` reads a file a spec's `data.url` names.
struct ChartPage: View {
    let text: String
    let url: URL
    let hint: ChartHint?
    let line: Int?
    let neighbour: (URL) async -> String?

    @State private var spec: Result<ChartSpec, ChartProblem>?
    @State private var showsSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(summary).appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Picker("Show", selection: $showsSource) {
                    Text("Chart").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch spec {
            case .success(let chart) where !showsSource:
                ChartView(spec: chart)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task(id: [text, hint?.x, hint?.y, hint?.mark.rawValue].compactMap { $0 }) {
            spec = await Self.read(text, url: url, hint: hint, neighbour: neighbour)
        }
    }

    private var summary: String {
        switch spec {
        case .success(let chart): return chart.summary
        case .failure: return "Not drawn"
        case nil: return ""
        }
    }

    /// The spec, with the one file its `data.url` names read first.
    static func read(_ text: String, url: URL, hint: ChartHint?,
                     neighbour: (URL) async -> String?) async -> Result<ChartSpec, ChartProblem> {
        var beside: [String: String] = [:]
        if ChartSpec.isVegaLite(url), let name = ChartSpec.dataURL(in: text),
           let named = ChartSpec.neighbourURL(name, of: url) {
            beside[name] = await neighbour(named)
        }
        return ChartSpec.read(text, url: url, hint: hint, neighbour: { beside[$0] })
    }
}
