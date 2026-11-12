import AgentsKitCore
import Charts
import SwiftUI

/// The pull requests that landed, over time (#4595): D / W / M / 3M bars of the PRs the
/// Multiplier counts, the daily average above them, a picked bar's own figure, and the shares
/// by repository, drawn as Cost, Tokens and Time are.
///
/// The Velocity page of the window (#4597) and the Remote (#4758); the web page draws the same
/// in VelocityCharts.tsx (#4598). The bars are worked out in `VelocityChart`, where they are
/// tested; this only draws them.
///
/// The range control and the chart, fetching through `load`, again whenever `refresh` changes.
struct VelocityChartsSection<Refresh: Equatable>: View {
    let load: () async -> VelocityHistory?
    let refresh: Refresh

    @State private var history: VelocityHistory?
    @State private var range: VelocityChart.Range = .week
    @State private var picked: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(VelocityChart.Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let history {
                VelocityChartBody(chart: VelocityChart(history, range: range), picked: $picked)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .onChange(of: range) { picked = nil }
        .task(id: refresh) {
            if let loaded = await load() { history = loaded }
        }
    }
}

private struct VelocityChartBody: View {
    let chart: VelocityChart
    @Binding var picked: Date?

    private var pickedBar: VelocityChart.Bar? {
        guard let picked else { return nil }
        return chart.bars.last { $0.start <= picked }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            if chart.isEmpty {
                Text("No pull requests landed in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                bars
                Text(chart.revertsLine)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                shares
            }
        }
    }

    /// Health's block above the bars: what the figure is, the figure, and when.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((pickedBar == nil ? VelocityChart.headline : "Total").uppercased())
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(VelocityChart.words(pickedBar?.value ?? chart.average))
                .appText(.title).fontWeight(.semibold)
                .monospacedDigit()
            Text(when)
                .appText(.supporting)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var when: String {
        if let bar = pickedBar {
            switch chart.range {
            case .day: return bar.start.formatted(.dateTime.hour())
                + "–" + bar.start.addingTimeInterval(3600).formatted(.dateTime.hour())
            case .week, .month: return bar.start.formatted(.dateTime.weekday(.wide).day().month())
            case .threeMonths: return "Week of " + bar.start.formatted(.dateTime.day().month())
            }
        }
        guard let first = chart.bars.first?.start, let last = chart.bars.last?.start else { return "" }
        if chart.range == .day { return "Today" }
        // 3M's last bar is a week that ends today, not on the day it starts.
        let end = chart.range == .threeMonths ? Calendar.current.date(byAdding: .day, value: 6, to: last) ?? last : last
        return (first ..< end.addingTimeInterval(1)).formatted(.interval.day().month().year())
    }

    private var unit: Calendar.Component {
        switch chart.range {
        case .day: .hour
        case .week, .month: .day
        case .threeMonths: .weekOfYear
        }
    }

    private var bars: some View {
        Chart {
            ForEach(chart.bars) { bar in
                BarMark(x: .value("When", bar.start, unit: unit), y: .value("PRs", bar.value))
                    .foregroundStyle(Paper.accent.opacity(pickedBar == nil || pickedBar == bar ? 1 : 0.35))
                    .cornerRadius(2)
            }
            if chart.range != .day, pickedBar == nil, chart.average > 0 {
                RuleMark(y: .value("Average", perBar(chart.average)))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXSelection(value: $picked)
        .chartYAxis {
            // A PR is whole: no half-PR tick on a quiet day.
            AxisMarks(position: .trailing) { value in
                if let number = value.as(Double.self), number == number.rounded() {
                    AxisGridLine()
                    AxisValueLabel { Text(Int(number).formatted()) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: chart.range == .day ? 4 : 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat)
            }
        }
        .frame(height: 200)
    }

    /// 3M's bars are weeks, so its daily average is drawn as a week's worth.
    private func perBar(_ daily: Double) -> Double { chart.range == .threeMonths ? daily * 7 : daily }

    private var axisFormat: Date.FormatStyle {
        switch chart.range {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month, .threeMonths: .dateTime.day().month(.abbreviated)
        }
    }

    /// Where the range's PRs landed, by repository, most first.
    private var shares: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chart.shares) { share in
                HStack(alignment: .firstTextBaseline) {
                    Text(share.name)
                    Spacer(minLength: 24)
                    Text(share.merged.formatted()).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
