import AgentsKitCore
import SwiftUI

/// The final share of each past week of a plan, as a row of short bars under the
/// runtime on the Runtimes page (#3438), oldest on the left, with the share under each.
/// A full bar is the whole week's allowance. VoiceOver reads the words instead.
struct PastWeeksChart: View {
    let past: [AllowanceReading]
    let words: String

    private let height: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Past weeks")
                .appText(.fine)
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(past, id: \.self) { week in
                    let used = week.usedFraction ?? 0
                    VStack(spacing: 2) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tint(week, used))
                                .frame(height: max(height * used, 1))
                        }
                        .frame(width: 22, height: height)
                        Text("\(Int((used * 100).rounded()))%")
                            .appText(.fine)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .help(week.resetsAt.map { "Week to \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
    }

    private func tint(_ week: AllowanceReading, _ used: Double) -> Color {
        if week.spent || used >= 1 { return StateTint.failure.color ?? Paper.accent }
        if used >= 0.8 { return StateTint.attention.color ?? Paper.accent }
        return Paper.accent
    }
}
