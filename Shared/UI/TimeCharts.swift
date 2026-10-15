import AgentsKitCore
import Charts
import SwiftUI

/// Where the time of running chats went (#852), drawn as the usage charts on Cost are:
/// D / W / M / 3M, each bar stacked by kind of time, the daily average above the bars,
/// and a bar picked to read its own figures.
///
/// The Time page of the window and the Remote; the page draws `TimeCharts` in
/// TimeCharts.tsx. The bars are worked out in `TimeChart`, where they are tested; this
/// only draws them. It fetches through `load` on appearing and every minute after.
struct TimeChartsSection: View {
    let load: () async -> TimeHistory?

    @State private var history: TimeHistory?
    @State private var range: TimeChart.Range = .week
    @State private var picked: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let history {
                TimeRecapSection(recap: TimeRecap(history))
                    .padding(.bottom, 12)
            }
            Picker("Range", selection: $range) {
                ForEach(TimeChart.Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let history {
                TimeChartBody(chart: TimeChart(history, range: range), picked: $picked)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            Text("Chats run side by side, so an hour can hold more than an hour of chat time. Time between turns is not counted.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: range) { picked = nil }
        .task {
            while !Task.isCancelled {
                if let loaded = await load() { history = loaded }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

/// The recap at the top of the Time page (#985): today and the last seven days side by
/// side, then the person's records. Worked out in `TimeRecap`; the page draws
/// `TimeRecapSection` in TimeCharts.tsx. No streaks, nothing about tokens or cost.
struct TimeRecapSection: View {
    let recap: TimeRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Recap").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    heading("Today")
                    heading("Last 7 days")
                }
                row("PRs merged", recap.today.prsMerged.map(String.init) ?? "–",
                    recap.week.prsMerged.map(String.init) ?? "–",
                    help: "Pull requests merged from agents' branches, as gh says")
                row("Turns finished", "\(recap.today.turns)", "\(recap.week.turns)")
                row("Agents run", "\(recap.today.agents)", "\(recap.week.agents)",
                    help: "Agents that ran a turn, counted on each day they ran")
                row("Leverage", TimeRecap.leverageWords(recap.today.leverage),
                    TimeRecap.leverageWords(recap.week.leverage),
                    help: "Agent hours for each hour the agents waited for you")
                row("Peak agents at once", "\(recap.today.peakAgents)", "\(recap.week.peakAgents)")
            }
            if !recap.records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Records").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    if let record = recap.records.mostAgents {
                        recordRow("Most agents at once", "\(Int(record.value))", record)
                    }
                    if let record = recap.records.mostPRs {
                        recordRow("Most PRs merged in a day", "\(Int(record.value))", record)
                    }
                    if let record = recap.records.longestClear {
                        recordRow("Longest stretch with no agent waiting for you",
                                  TimeChart.words(record.value), record)
                    }
                }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func row(_ title: String, _ today: String, _ week: String, help: String? = nil) -> some View {
        GridRow {
            Text(title)
            Text(today).monospacedDigit()
            Text(week).monospacedDigit()
        }
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): today \(today), last 7 days \(week)")
    }

    private func recordRow(_ title: String, _ value: String, _ record: TimeRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 24)
            Text(value).monospacedDigit()
            Text(TimeRecap.dayWords(record.day)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension TimeKind {
    /// The kind's colour: the agent and its tools in the accent, waiting on others in
    /// grey, and waiting for the person in the attention orange, as a chat waiting on
    /// them is drawn.
    var style: AnyShapeStyle {
        switch self {
        case .agent: AnyShapeStyle(Paper.accent)
        case .tools: AnyShapeStyle(Paper.accent.opacity(0.5))
        case .others: AnyShapeStyle(Color.secondary.opacity(0.5))
        case .person: StateTint.attention.style(or: Color.secondary)
        }
    }
}

private struct TimeChartBody: View {
    let chart: TimeChart
    @Binding var picked: Date?

    private var pickedBar: TimeChart.Bar? {
        guard let picked else { return nil }
        return chart.bars.last { $0.start <= picked }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            if chart.isEmpty {
                Text("No chat ran in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                bars
                kinds
                if pickedBar == nil, chart.shares.count > 1 { runtimes }
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((pickedBar == nil ? chart.headline : "Total").uppercased())
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(TimeChart.words(pickedBar?.total ?? chart.average))
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
                ForEach(TimeKind.allCases) { kind in
                    BarMark(x: .value("When", bar.start, unit: unit), y: .value("Time", bar.time[kind]))
                        .foregroundStyle(kind.style)
                        .opacity(pickedBar == nil || pickedBar == bar ? 1 : 0.35)
                }
            }
            if chart.range != .day, pickedBar == nil, chart.average > 0 {
                RuleMark(y: .value("Average", chart.range == .threeMonths ? chart.average * 7 : chart.average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXSelection(value: $picked)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel { if let seconds = value.as(Double.self) { Text(TimeChart.words(seconds)) } }
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

    private var axisFormat: Date.FormatStyle {
        switch chart.range {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month, .threeMonths: .dateTime.day().month(.abbreviated)
        }
    }

    /// Each kind of time, its swatch, its figure and its share: the range's, or the
    /// picked bar's.
    private var kinds: some View {
        let time = pickedBar?.time ?? chart.time
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(TimeKind.allCases) { kind in
                HStack(alignment: .firstTextBaseline) {
                    RoundedRectangle(cornerRadius: 2).fill(kind.style).frame(width: 9, height: 9)
                    Text(kind.title)
                    Spacer(minLength: 24)
                    Text(TimeChart.words(time[kind])).monospacedDigit()
                    Text(time.total > 0 ? "\(Int((time[kind] / time.total * 100).rounded()))%" : "0%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The range by runtime, most time first.
    private var runtimes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By runtime")
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(chart.shares) { share in
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageChart.runtimeName(share.runtime))
                    Spacer(minLength: 24)
                    Text(TimeChart.words(share.time.total)).monospacedDigit()
                }
                .help(TimeKind.allCases.map { "\($0.title) \(TimeChart.words(share.time[$0]))" }.joined(separator: ", "))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 4)
    }
}
