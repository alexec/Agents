import AgentsKitCore
import Charts
import SwiftUI

/// What the work used over time, as Health draws it (#823): D / W / M / 3M, cost or
/// tokens, the daily average above the bars, and a bar picked to read its own figure.
///
/// Drawn on Cost by the window and the Remote; the page draws `UsageCharts` in
/// UsageCharts.tsx. The bars are worked out in `UsageChart`, where they are tested; this
/// only draws them. It fetches through `load`, again whenever `refresh` changes.
struct UsageChartsSection<Refresh: Equatable>: View {
    let load: () async -> UsageHistory?
    let refresh: Refresh

    @State private var history: UsageHistory?
    @State private var range: UsageChart.Range = .week
    @State private var metric: UsageChart.Metric = .cost
    @State private var picked: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $metric) {
                ForEach(UsageChart.Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("Range", selection: $range) {
                ForEach(UsageChart.Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let history {
                UsageChartBody(chart: UsageChart(history, range: range, metric: metric), picked: $picked)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .onChange(of: range) { picked = nil }
        .onChange(of: metric) { picked = nil }
        .task(id: refresh) {
            if let loaded = await load() { history = loaded }
        }
    }
}

private struct UsageChartBody: View {
    let chart: UsageChart
    @Binding var picked: Date?

    private var pickedBar: UsageChart.Bar? {
        guard let picked else { return nil }
        return chart.bars.last { $0.start <= picked }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            if chart.isEmpty {
                Text(chart.metric == .cost ? "Nothing was spent in this range." : "No tokens were used in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                bars
                shares
            }
            notes
        }
    }

    /// Health's block above the bars: what the figure is, the figure, and when.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((pickedBar == nil ? chart.headline : "Total").uppercased())
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(chart.words(pickedBar?.value ?? chart.average))
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
                BarMark(x: .value("When", bar.start, unit: unit), y: .value(chart.metric.rawValue, bar.value))
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
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(chart.words(number)) } }
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

    /// Where the range went, by runtime, largest first.
    private var shares: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chart.shares) { share in
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageChart.runtimeName(share.runtime))
                    Spacer(minLength: 24)
                    Text(chart.words(share.value)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if chart.metric == .tokens, chart.cachedReadTokens > 0 {
                Text("Plus \(UsageChart.tokenWords(Double(chart.cachedReadTokens))) read from cache, not drawn.")
            }
            if chart.metric == .cost, chart.unpricedTurns > 0 {
                Text("At least this much: \(chart.unpricedTurns == 1 ? "1 turn" : "\(chart.unpricedTurns) turns") ran on a runtime that reported no price.")
            }
            if !chart.otherCurrencies.isEmpty {
                Text("Also spent in \(chart.otherCurrencies.formatted(.list(type: .and))), not drawn.")
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
    }
}
